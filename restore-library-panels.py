#!/usr/bin/env python3
"""Recreate Grafana library panels.

Usage:
    ./env/bin/python restore-library-panels.py --config grafana-service.env [--dry-run]
"""

import argparse
import copy
import json
import ssl
import sys
import urllib.error
import urllib.request

# uid -> (library name, donor dashboard export, donor panel title, transform)
RESTORE_MAP = {
    "c271b987-3954-460b-ba8c-6aba4a4ad09d": (
        "TDC Sample Rate",
        "exported_grafana_data/sbnd/dashboard_Tutorial.json",
        "TDC Sample Rate",
        None,
    ),
    "d6c4db28-155e-4ec7-bbf0-6a892538d195": (
        "Empty Fragments",
        "exported_grafana_data/sbnd/dashboard_Tutorial.json",
        "Empty Fragments",
        None,
    ),
    "fe3debcc-0bcf-4446-9477-779cb28e4557": (
        "Missing Fragments",
        "exported_grafana_data/sbnd/dashboard_Tutorial.json",
        "Missing Fragments",
        None,
    ),
    "e5fecf22-78dd-4be4-9f64-807303c4b9d5": (
        "Fragment Watcher",
        "exported_grafana_data/sbnd/dashboard_Tutorial.json",
        "Fragment Watcher",
        None,
    ),
    "f828045b-5ef0-4744-9656-72af2b2e82d4": (
        "Run Number",
        "exported_grafana_data/sbnd/dashboard_PMT_Monitoring.json",
        "Run Number (P 6)",
        None,
    ),
    "a6bff43c-81ea-4f34-8910-8c2b9653f640": (
        "EVB  Pending Buffers Time Series",
        "exported_grafana_data/sbnd/dashboard_Tutorial.json",
        "EVB  Full Buffers",
        "full_to_pending",
    ),
    "b0f6a53d-2a8e-48bd-8ffa-02e2167a1e91": (
        "EVB  Full Buffers",
        "exported_grafana_data/sbnd/dashboard_Tutorial.json",
        "EVB  Full Buffers",
        None,
    ),
}


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def api(base, key, ctx, path, method="GET", body=None):
    req = urllib.request.Request(
        base + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, context=ctx) as r:
        return json.load(r)


def walk(panel):
    yield panel
    for child in panel.get("panels") or []:
        yield from walk(child)


def find_donor(export_file, title):
    with open(export_file) as f:
        dash = json.load(f)
    dash = dash.get("dashboard", dash)
    for p in (x for top in dash.get("panels", []) for x in walk(top)):
        if p.get("title") == title and p.get("targets"):
            return p
    sys.exit(f"ERROR: donor panel {title!r} not found in {export_file}")


def build_model(donor, name, transform):
    model = copy.deepcopy(donor)
    for key in ("gridPos", "id", "libraryPanel"):
        model.pop(key, None)
    if transform == "full_to_pending":
        model["title"] = "EVB  Pending Buffers"
        for t in model.get("targets", []):
            if "target" in t:
                t["target"] = t["target"].replace(
                    "Shared_Memory_Full_Buffers", "Shared_Memory_Pending_Buffers"
                )
    return model


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--config", default="grafana-service.env")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    env = load_env(args.config)
    base, key = env["GRAFANA_URL"], env["GRAFANA_API_KEY"]
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    created = skipped = 0
    for uid, (name, export_file, donor_title, transform) in RESTORE_MAP.items():
        try:
            existing = api(base, key, ctx, f"/api/library-elements/{uid}")
            print(f"SKIP   {name!r} (uid={uid}) already exists: "
                  f"{existing['result']['name']!r}")
            skipped += 1
            continue
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
        donor = find_donor(export_file, donor_title)
        model = build_model(donor, name, transform)
        if args.dry_run:
            print(f"DRYRUN would create {name!r} (uid={uid}) type={model['type']} "
                  f"from {export_file}:{donor_title!r}")
            continue
        api(base, key, ctx, "/api/library-elements", method="POST",
            body={"uid": uid, "name": name, "kind": 1, "model": model})
        print(f"CREATE {name!r} (uid={uid}) type={model['type']} "
              f"from {export_file}:{donor_title!r}")
        created += 1

    print(f"\ndone: {created} created, {skipped} already present")

    if not args.dry_run:
        print("\nverifying dashboard references:")
        bad = 0
        for f in ("dashboard_X-ARAPUCA_Monitoring.json",
                  "dashboard_PMT_Monitoring.json",
                  "dashboard_WR-TDC_Artdaq_Driver.json"):
            with open(f"exported_grafana_data/sbnd/{f}") as fh:
                dash = json.load(fh)
            dash = dash.get("dashboard", dash)
            for p in (x for top in dash.get("panels", []) for x in walk(top)):
                lp = p.get("libraryPanel")
                if not lp:
                    continue
                try:
                    api(base, key, ctx, f"/api/library-elements/{lp['uid']}")
                    print(f"  OK   {dash['title']} / {p.get('title')!r}")
                except urllib.error.HTTPError:
                    print(f"  FAIL {dash['title']} / {p.get('title')!r} "
                          f"uid={lp['uid']} still missing")
                    bad += 1
        sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
