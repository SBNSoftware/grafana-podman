import sys

try:
    import requests
    import json
    import os
    import re
    import argparse
    from dotenv import load_dotenv
    from urllib3.exceptions import InsecureRequestWarning
    from time import sleep
    from typing import Dict, List, Optional
except ImportError as e:
    print(f"Error: Required library not found: {e.name}")
    print("Please ensure you have a Python virtual environment set up and activated.")
    print("To set up a virtual environment, run:")
    print("    python3 -m venv env")
    print("To activate the virtual environment, use:")
    print("    source env/bin/activate")
    print("Please install the missing libraries using pip:")
    print("    pip install --upgrade pip")
    print("    pip install requests python-dotenv urllib3")
    sys.exit(1)


def load_config(config_file: str) -> Dict[str, str]:
    load_dotenv(config_file)
    return {
        "GRAFANA_URL": os.getenv("GRAFANA_URL", ""),
        "GRAFANA_API_KEY": os.getenv("GRAFANA_API_KEY", ""),
        "EXPORT_DIR": os.getenv("EXPORT_DIR", "exported_grafana_data"),
        "RETRY_COUNT": os.getenv("RETRY_COUNT", "3"),
        "EXPERIMENT_NAME": os.getenv("EXPERIMENT_NAME", ""),
        "GRAFANA_INSECURE": os.getenv("GRAFANA_INSECURE", "false"),
    }


def get_headers(api_key: str, disable_provenance: bool = False) -> Dict[str, str]:
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    if disable_provenance:
        headers["X-Disable-Provenance"] = "true"
    return headers


def make_api_request(method: str, url: str, headers: Dict[str, str], json_data: Dict = None,
                     verify: bool = True, retry_count: int = 3) -> requests.Response:
    for attempt in range(retry_count):
        try:
            response = requests.request(method, url, headers=headers, json=json_data, verify=verify)
            response.raise_for_status()
            return response
        except requests.RequestException as e:
            if retry_count > 1:
                print(f"Request failed (attempt {attempt + 1}/{retry_count})\nError: {e}")
            if attempt < retry_count - 1:
                sleep(0.25)
            else:
                raise
    raise Exception("All retry attempts failed")


# --------------------------------------------------------------------------- #
# GET helpers
# --------------------------------------------------------------------------- #
def _get_json(grafana_url: str, path: str, headers: Dict[str, str], verify: bool, retry_count: int):
    response = make_api_request("GET", f"{grafana_url}{path}", headers, verify=verify, retry_count=retry_count)
    return response.json()


def get_dashboards(grafana_url, headers, verify, retry_count) -> List[Dict]:
    return _get_json(grafana_url, "/api/search?type=dash-db", headers, verify, retry_count)


def get_datasources(grafana_url, headers, verify, retry_count) -> List[Dict]:
    return _get_json(grafana_url, "/api/datasources", headers, verify, retry_count)


def get_alert_rules(grafana_url, headers, verify, retry_count) -> List[Dict]:
    return _get_json(grafana_url, "/api/v1/provisioning/alert-rules", headers, verify, retry_count)


def get_contact_points(grafana_url, headers, verify, retry_count) -> List[Dict]:
    """Contact points WITH decrypted secrets.

    The plain list endpoint redacts secure settings (Slack url/token show as
    "[REDACTED]"), which makes restore produce broken notifications. The export
    endpoint returns decrypted secrets (when the token has
    alerting.provisioning.secrets:read) grouped by contact point -> receivers.
    We flatten that back into the per-receiver shape the create endpoint expects.
    """
    data = _get_json(
        grafana_url,
        "/api/v1/provisioning/contact-points/export?decrypt=true&format=json",
        headers, verify, retry_count,
    )
    items: List[Dict] = []
    for cp in data.get("contactPoints", []):
        for recv in cp.get("receivers", []):
            items.append({
                "uid": recv.get("uid"),
                "name": cp.get("name"),
                "type": recv.get("type"),
                "settings": recv.get("settings", {}),
                "disableResolveMessage": recv.get("disableResolveMessage", False),
            })
    return items


def get_notification_policies(grafana_url, headers, verify, retry_count) -> Dict:
    return _get_json(grafana_url, "/api/v1/provisioning/policies", headers, verify, retry_count)


def get_folders(grafana_url, headers, verify, retry_count) -> List[Dict]:
    return _get_json(grafana_url, "/api/folders", headers, verify, retry_count)


def get_mute_timings(grafana_url, headers, verify, retry_count) -> List[Dict]:
    return _get_json(grafana_url, "/api/v1/provisioning/mute-timings", headers, verify, retry_count)


# --------------------------------------------------------------------------- #
# Export
# --------------------------------------------------------------------------- #
def _safe(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", (name or "unnamed"))


def _name_uid(item_type: str, item_data: Dict):
    if item_type == "dashboard":
        d = item_data.get("dashboard", {})
        return d.get("title", "unnamed"), d.get("uid")
    if item_type == "datasource":
        return item_data.get("name", "unnamed"), item_data.get("uid")
    if item_type in ("folder", "alert_rule", "contact_point"):
        return item_data.get("title", item_data.get("name", "unnamed")), item_data.get("uid")
    if item_type == "mute_timing":
        return item_data.get("name", "unnamed"), None
    if item_type == "notification_policy":
        return "root", None
    raise ValueError(f"Unsupported item_type: {item_type}")


def export_item(item_type: str, item_data: Dict, export_dir: str):
    """Write one item to <item_type>_<name>__<uid>.json.

    Including the uid guarantees uniqueness even when two items share a title/name
    (e.g. dashboards with the same title in different folders, or a contact point
    with multiple integrations) — naming by title alone silently overwrote them.
    """
    try:
        name, uid = _name_uid(item_type, item_data)
        stem = f"{item_type}_{_safe(name)}"
        if uid:
            stem += f"__{_safe(uid)}"
        filename = os.path.join(export_dir, f"{stem}.json")
        with open(filename, "w") as f:
            json.dump(item_data, f, indent=2)
        print(f"Exported {item_type}: {name}")
    except Exception as e:
        print(f"Error exporting {item_type}: {e}")


def _warn_redacted(export_dir: str):
    hits = []
    for fn in os.listdir(export_dir):
        if not fn.endswith(".json"):
            continue
        with open(os.path.join(export_dir, fn)) as f:
            if "[REDACTED]" in f.read():
                hits.append(fn)
    if hits:
        print()
        print("WARNING: these exports still contain '[REDACTED]' secrets (the token may lack")
        print("         alerting.provisioning.secrets:read, or the field is a datasource secret):")
        for h in sorted(hits):
            print(f"           - {h}")
        print("         Restoring them will produce non-functional resources until secrets are supplied.")


def export_grafana_data(config: Dict[str, str], verify: bool):
    headers = get_headers(config["GRAFANA_API_KEY"])
    retry_count = int(config["RETRY_COUNT"])
    url = config["GRAFANA_URL"]

    export_dir = config["EXPORT_DIR"]
    if config["EXPERIMENT_NAME"]:
        export_dir = os.path.join(export_dir, config["EXPERIMENT_NAME"])
    os.makedirs(export_dir, exist_ok=True)

    datasources = get_datasources(url, headers, verify, retry_count)
    ds_secret_warn = []
    for datasource in datasources:
        export_item("datasource", datasource, export_dir)
        if datasource.get("basicAuth") or datasource.get("secureJsonFields"):
            ds_secret_warn.append(datasource.get("name"))

    dashboards = get_dashboards(url, headers, verify, retry_count)
    for dashboard in dashboards:
        dashboard_url = f"{url}/api/dashboards/uid/{dashboard['uid']}"
        response = make_api_request("GET", dashboard_url, headers, verify=verify, retry_count=retry_count)
        export_item("dashboard", response.json(), export_dir)

    folders = get_folders(url, headers, verify, retry_count)
    for folder in folders:
        export_item("folder", folder, export_dir)

    alert_rules = get_alert_rules(url, headers, verify, retry_count)
    for alert_rule in alert_rules:
        export_item("alert_rule", alert_rule, export_dir)

    contact_points = get_contact_points(url, headers, verify, retry_count)
    for contact_point in contact_points:
        export_item("contact_point", contact_point, export_dir)

    notification_policies = get_notification_policies(url, headers, verify, retry_count)
    export_item("notification_policy", notification_policies, export_dir)

    mute_timings = get_mute_timings(url, headers, verify, retry_count)
    for mute_timing in mute_timings:
        export_item("mute_timing", mute_timing, export_dir)

    print("All items exported.")

    if ds_secret_warn:
        print()
        print("NOTE: Grafana cannot export datasource secrets. These datasources have")
        print("      basicAuth/secure fields that will be EMPTY on restore — supply them")
        print("      with `--secrets-file` on import:")
        for n in ds_secret_warn:
            print(f"        - {n}")
    _warn_redacted(export_dir)


# --------------------------------------------------------------------------- #
# Delete helpers (for --wipe-existing-data)
# --------------------------------------------------------------------------- #
def _delete(grafana_url, headers, path, verify, retry_count):
    make_api_request("DELETE", f"{grafana_url}{path}", headers, verify=verify, retry_count=retry_count)


def create_find_folder_uid(grafana_url, headers, name, verify, retry_count) -> str:
    try:
        folders = get_folders(grafana_url, headers, verify, retry_count)
        general_folder = next((f for f in folders if f["title"] == name), None)
        if general_folder:
            return general_folder["uid"]
    except Exception:
        pass
    response = make_api_request("POST", f"{grafana_url}/api/folders", headers,
                                json_data={"title": name}, verify=verify, retry_count=retry_count)
    return json.loads(response.text)["uid"]


# --------------------------------------------------------------------------- #
# Import
# --------------------------------------------------------------------------- #
def import_grafana_data(config: Dict[str, str], force: bool, verify: bool,
                        secrets: Dict[str, Dict], dry_run: bool):
    url = config["GRAFANA_URL"]
    retry_count = int(config["RETRY_COUNT"])
    headers = get_headers(config["GRAFANA_API_KEY"])
    prov_headers = get_headers(config["GRAFANA_API_KEY"], disable_provenance=True)
    general_folder_name = "Dashboards"

    import_dir = config["EXPORT_DIR"]
    if config["EXPERIMENT_NAME"]:
        import_dir = os.path.join(import_dir, config["EXPERIMENT_NAME"])
    if not os.path.isdir(import_dir):
        print(f"Error: import directory not found: {import_dir}")
        sys.exit(1)

    if force:
        _wipe(url, headers, prov_headers, verify, retry_count, dry_run)

    import_order = ["datasource_", "folder_", "dashboard_", "mute_timing_",
                    "contact_point_", "notification_policy_", "alert_rule_"]

    general_folder_uid = None
    folder_uids = None
    existing_cps = None
    failed = 0

    files = sorted(os.listdir(import_dir))
    for prefix in import_order:
        for filename in files:
            if not (filename.endswith(".json") and filename.startswith(prefix)):
                continue
            with open(os.path.join(import_dir, filename)) as f:
                item_data = json.load(f)

            method = "POST"
            req_headers = headers
            upsert = None

            if prefix == "datasource_":
                import_url = f"{url}/api/datasources"
                item_data["id"] = None
                _inject_ds_secret(item_data, secrets)
                if item_data.get("uid"):
                    upsert = ("PUT", f"{url}/api/datasources/uid/{item_data['uid']}")

            elif prefix == "folder_":
                if item_data.get("title") == general_folder_name:
                    continue
                import_url = f"{url}/api/folders"
                item_data["id"] = None
                item_data["overwrite"] = True
                if item_data.get("uid"):
                    upsert = ("PUT", f"{url}/api/folders/{item_data['uid']}")

            elif prefix == "dashboard_":
                if folder_uids is None:
                    folder_uids = {f["uid"] for f in get_folders(url, headers, verify, retry_count)}
                import_url = f"{url}/api/dashboards/db"
                orig_folder = (item_data.get("meta") or {}).get("folderUid", "") or ""
                if orig_folder and orig_folder in folder_uids:
                    target_folder = orig_folder
                elif orig_folder == "":
                    target_folder = ""
                else:
                    if general_folder_uid is None:
                        general_folder_uid = create_find_folder_uid(url, headers, general_folder_name, verify, retry_count)
                    target_folder = general_folder_uid
                item_data["dashboard"]["id"] = None
                item_data["folderUid"] = target_folder
                item_data["overwrite"] = True
                item_data.pop("meta", None)

            elif prefix == "mute_timing_":
                import_url = f"{url}/api/v1/provisioning/mute-timings"
                req_headers = prov_headers
                if item_data.get("name"):
                    upsert = ("PUT", f"{url}/api/v1/provisioning/mute-timings/{item_data['name']}")

            elif prefix == "contact_point_":
                req_headers = prov_headers
                import_url = f"{url}/api/v1/provisioning/contact-points"
                if existing_cps is None:
                    existing_cps = _get_json(url, "/api/v1/provisioning/contact-points",
                                             headers, verify, retry_count)
                cp_uid = item_data.get("uid") or ""
                if cp_uid and any(c.get("uid") == cp_uid for c in existing_cps):
                    method = "PUT"
                    import_url = f"{url}/api/v1/provisioning/contact-points/{cp_uid}"
                elif not cp_uid and any(c.get("name") == item_data.get("name")
                                        and c.get("type") == item_data.get("type")
                                        for c in existing_cps):
                    print(f"Skipped (same name/type already exists, no uid to update): {filename}")
                    continue

            elif prefix == "notification_policy_":
                import_url = f"{url}/api/v1/provisioning/policies"
                method = "PUT"
                req_headers = prov_headers

            elif prefix == "alert_rule_":
                import_url = f"{url}/api/v1/provisioning/alert-rules"
                req_headers = prov_headers
                if item_data.get("uid"):
                    upsert = ("PUT", f"{url}/api/v1/provisioning/alert-rules/{item_data['uid']}")
            else:
                continue

            if dry_run:
                print(f"[dry-run] {method} {import_url}  <- {filename}")
                continue
            try:
                make_api_request(method, import_url, req_headers, json_data=item_data,
                                 verify=verify, retry_count=retry_count)
                print(f"Imported: {filename}")
            except requests.RequestException as e:
                status = getattr(getattr(e, "response", None), "status_code", None)
                if upsert and status in (409, 412):
                    try:
                        make_api_request(upsert[0], upsert[1], req_headers, json_data=item_data,
                                         verify=verify, retry_count=retry_count)
                        print(f"Imported (updated existing): {filename}")
                        continue
                    except requests.RequestException as e2:
                        e = e2
                failed += 1
                print(f"Failed to import {filename}: {e}")

    if dry_run:
        print("Dry run complete (no changes made).")
    elif failed:
        print(f"Import finished with {failed} failure(s).")
        sys.exit(1)
    else:
        print("All items imported.")


def _inject_ds_secret(item_data: Dict, secrets: Dict[str, Dict]):
    """Merge operator-supplied datasource secrets (secureJsonData) before POST.

    secrets is keyed by datasource name or uid, e.g. {"artdaq": {"basicAuthPassword": "..."}}.
    """
    if not secrets:
        return
    key = None
    if item_data.get("name") in secrets:
        key = item_data["name"]
    elif item_data.get("uid") in secrets:
        key = item_data["uid"]
    if key:
        merged = dict(item_data.get("secureJsonData") or {})
        merged.update(secrets[key])
        item_data["secureJsonData"] = merged
        print(f"  injected secret(s) for datasource '{item_data.get('name')}'")


def _wipe(url, headers, prov_headers, verify, retry_count, dry_run):
    def safe(fn, label):
        try:
            if dry_run:
                print(f"[dry-run] would delete {label}")
            else:
                fn()
        except Exception as e:
            print(f"Failed to delete {label}: {e}")

    for d in get_dashboards(url, headers, verify, retry_count):
        if d.get("uid"):
            safe(lambda d=d: _delete(url, headers, f"/api/dashboards/uid/{d['uid']}", verify, retry_count),
                 f"dashboard {d['uid']}")
    for r in get_alert_rules(url, headers, verify, retry_count):
        if r.get("uid"):
            safe(lambda r=r: _delete(url, prov_headers, f"/api/v1/provisioning/alert-rules/{r['uid']}", verify, retry_count),
                 f"alert_rule {r['uid']}")
    safe(lambda: _delete(url, prov_headers, "/api/v1/provisioning/policies", verify, retry_count),
         "notification policy tree")
    for c in get_contact_points(url, headers, verify, retry_count):
        if c.get("uid"):
            safe(lambda c=c: _delete(url, prov_headers, f"/api/v1/provisioning/contact-points/{c['uid']}", verify, retry_count),
                 f"contact_point {c['uid']}")
    for m in get_mute_timings(url, headers, verify, retry_count):
        if m.get("name"):
            safe(lambda m=m: _delete(url, prov_headers, f"/api/v1/provisioning/mute-timings/{m['name']}", verify, retry_count),
                 f"mute_timing {m['name']}")
    for ds in get_datasources(url, headers, verify, retry_count):
        if ds.get("uid"):
            safe(lambda ds=ds: _delete(url, headers, f"/api/datasources/uid/{ds['uid']}", verify, retry_count),
                 f"datasource {ds['uid']}")
    for fo in get_folders(url, headers, verify, retry_count):
        if fo.get("uid"):
            safe(lambda fo=fo: _delete(url, headers, f"/api/folders/{fo['uid']}", verify, retry_count),
                 f"folder {fo['uid']}")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def load_secrets(path: Optional[str]) -> Dict[str, Dict]:
    if not path:
        return {}
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("secrets file must be a JSON object keyed by datasource name/uid")
    return data


def usage():
    print("Grafana Configuration Management Tool (grafana-ninja)")
    print("\nBackup/restore dashboards, datasources, folders, alert rules, contact points,")
    print("notification policies, and mute timings.")
    print("\nUsage:")
    print("  python3 grafana-ninja.py --config <file> --mode <export|import> [options]")
    print("\nOptions:")
    print("  --config <file>        Path to the configuration file (required)")
    print("  --mode <export|import> Operation mode (required)")
    print("  --wipe-existing-data   Delete all existing configuration before import")
    print("  --secrets-file <file>  JSON of datasource secrets to inject on import,")
    print("                         keyed by datasource name/uid -> secureJsonData")
    print("  --insecure             Skip TLS verification (self-signed endpoints);")
    print("                         also settable via GRAFANA_INSECURE=true in the config")
    print("  --dry-run              Show what import would do without changing anything")
    print("  --token-instructions   Print how to create a Grafana API token")
    print("  -h, --help             Show this help and exit")


def print_token_creation_instructions():
    print("""
Create a Grafana service-account token for grafana-ninja:

1. Log in to Grafana as an admin.
2. Administration -> Users and access -> Service accounts.
3. "Add service account", role Admin, Create.
4. "Add service account token", copy it (shown once).
5. Put it in your config file:
     GRAFANA_API_KEY=<token>
     GRAFANA_URL=https://your-grafana:3000
   For self-signed TLS, also set GRAFANA_INSECURE=true (or pass --insecure).

Note: exporting decrypted alerting secrets requires the token to have the
'alerting.provisioning.secrets:read' permission (Admin role has it).
""")


def main():
    if len(sys.argv) == 1 or sys.argv[1] in ["-h", "--help", "/?"]:
        usage()
        sys.exit(0)
    if sys.argv[1] == "--token-instructions":
        print_token_creation_instructions()
        sys.exit(0)

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--config", required=True)
    parser.add_argument("--mode", choices=["export", "import"], required=True)
    parser.add_argument("--wipe-existing-data", action="store_true")
    parser.add_argument("--secrets-file")
    parser.add_argument("--insecure", action="store_true")
    parser.add_argument("--dry-run", action="store_true")

    try:
        args = parser.parse_args()
    except SystemExit:
        usage()
        sys.exit(1)

    config = load_config(args.config)

    insecure = args.insecure or config["GRAFANA_INSECURE"].strip().lower() in ("1", "true", "yes", "on")
    verify = not insecure
    if not verify:
        requests.packages.urllib3.disable_warnings(category=InsecureRequestWarning)

    try:
        get_folders(config["GRAFANA_URL"], get_headers(config["GRAFANA_API_KEY"]),
                    verify, int(config["RETRY_COUNT"]))
    except Exception as e:
        print(f"\nError: Unable to connect to Grafana or authenticate.\n Details: {e}")
        print(f"\nCheck GRAFANA_URL / GRAFANA_API_KEY in '{args.config}'.")
        if verify and str(config["GRAFANA_URL"]).startswith("https://"):
            print("If the endpoint uses a self-signed certificate, pass --insecure "
                  "or set GRAFANA_INSECURE=true.")
        print("Run with --token-instructions for help creating a valid API token.")
        sys.exit(1)

    if args.mode == "export":
        export_grafana_data(config, verify)
    else:
        secrets = load_secrets(args.secrets_file)
        import_grafana_data(config, args.wipe_existing_data, verify, secrets, args.dry_run)


if __name__ == "__main__":
    main()
