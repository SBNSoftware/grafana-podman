import sys

try:
    import requests
    import json
    import os
    import argparse
    from dotenv import load_dotenv
    from urllib3.exceptions import InsecureRequestWarning
    from time import sleep
    from typing import Dict, List
    import getpass
    import socket
    from datetime import datetime
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
        "EXPERIMENT_NAME": os.getenv("EXPERIMENT_NAME", "")
    }

def get_headers(api_key: str) -> Dict[str, str]:
    return {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }

def make_api_request(method: str, url: str, headers: Dict[str, str], json_data: Dict = None, verify: bool = True, retry_count: int = 3) -> requests.Response:
    for attempt in range(retry_count):
        try:
            response = requests.request(method, url, headers=headers, json=json_data, verify=verify)
            response.raise_for_status()
            return response
        except requests.RequestException as e:
            if retry_count > 1:
                print(f"Request failed (attempt {attempt + 1}/{retry_count})\nError: {e}")
                #print(f"Method: {method}")
                #print(f"Response body: {e.response.text if e.response else 'No response body'}")
            if attempt < retry_count - 1:
                sleep(0.25)
            else:
                raise
    raise Exception("All retry attempts failed")

def get_dashboards(grafana_url: str, headers: Dict[str, str], verify: bool, retry_count: int) -> List[Dict]:
    search_url = f"{grafana_url}/api/search?type=dash-db"
    response = make_api_request("GET", search_url, headers, verify=verify, retry_count=retry_count)
    return json.loads(response.text)

def get_datasources(grafana_url: str, headers: Dict[str, str], verify: bool, retry_count: int) -> List[Dict]:
    datasources_url = f"{grafana_url}/api/datasources"
    response = make_api_request("GET", datasources_url, headers, verify=verify, retry_count=retry_count)
    return json.loads(response.text)

def get_alert_rules(grafana_url: str, headers: Dict[str, str], verify: bool, retry_count: int) -> List[Dict]:
    alert_rules_url = f"{grafana_url}/api/v1/provisioning/alert-rules"
    response = make_api_request("GET", alert_rules_url, headers, verify=verify, retry_count=retry_count)
    return json.loads(response.text)

def get_contact_points(grafana_url: str, headers: Dict[str, str], verify: bool, retry_count: int) -> List[Dict]:
    contact_points_url = f"{grafana_url}/api/v1/provisioning/contact-points"
    response = make_api_request("GET", contact_points_url, headers, verify=verify, retry_count=retry_count)
    return json.loads(response.text)

def get_notification_policies(grafana_url: str, headers: Dict[str, str], verify: bool, retry_count: int) -> Dict:
    notification_policies_url = f"{grafana_url}/api/v1/provisioning/policies"
    response = make_api_request("GET", notification_policies_url, headers, verify=verify, retry_count=retry_count)
    return json.loads(response.text)

def get_folders(grafana_url: str, headers: Dict[str, str], verify: bool, retry_count: int) -> List[Dict]:
    folders_url = f"{grafana_url}/api/folders"
    response = make_api_request("GET", folders_url, headers, verify=verify, retry_count=retry_count)
    return json.loads(response.text)

def get_mute_timings(grafana_url: str, headers: Dict[str, str], verify: bool, retry_count: int) -> List[Dict]:
    mute_timings_url = f"{grafana_url}/api/v1/provisioning/mute-timings"
    response = make_api_request("GET", mute_timings_url, headers, verify=verify, retry_count=retry_count)
    return json.loads(response.text)

def export_item(item_type: str, item_data: Dict, export_dir: str):
    try:
        if item_type == 'dashboard':
            item_name = item_data['dashboard']['title']
        elif item_type == 'datasource':
            item_name = item_data['name']
        elif item_type in ['alert_rule', 'folder', 'contact_point', 'notification_policy','mute-timings' ]:
            item_name = item_data.get('title', item_data.get('name', 'unnamed'))
        else:
            raise ValueError(f"Unsupported item_type: {item_type}")

        filename = os.path.join(export_dir, f"{item_type}_{item_name.replace(' ', '_')}.json")
        with open(filename, 'w') as f:
            json.dump(item_data, f, indent=2)
        print(f"Exported {item_type}: {item_name}")
    except Exception as e:
        print(f"Error exporting item: {e}")

def export_grafana_data(config: Dict[str, str]):
    headers = get_headers(config["GRAFANA_API_KEY"])
    verify = not config["GRAFANA_URL"].startswith("https://")
    retry_count = int(config["RETRY_COUNT"])

    export_dir = config["EXPORT_DIR"]
    if config["EXPERIMENT_NAME"]:
        export_dir = os.path.join(export_dir, config["EXPERIMENT_NAME"])
    os.makedirs(export_dir, exist_ok=True)

    datasources = get_datasources(config["GRAFANA_URL"], headers, verify, retry_count)
    for datasource in datasources:
        export_item("datasource", datasource, export_dir)

    dashboards = get_dashboards(config["GRAFANA_URL"], headers, verify, retry_count)
    for dashboard in dashboards:
        dashboard_url = f"{config['GRAFANA_URL']}/api/dashboards/uid/{dashboard['uid']}"
        response = make_api_request("GET", dashboard_url, headers, verify=verify, retry_count=retry_count)
        export_item("dashboard", response.json(), export_dir)

    folders = get_folders(config["GRAFANA_URL"], headers, verify, retry_count)
    for folder in folders:
        export_item("folder", folder, export_dir)

    alert_rules = get_alert_rules(config["GRAFANA_URL"], headers, verify, retry_count)
    for alert_rule in alert_rules:
        export_item("alert_rule", alert_rule, export_dir)

    contact_points = get_contact_points(config["GRAFANA_URL"], headers, verify, retry_count)
    for contact_point in contact_points:
        export_item("contact_point", contact_point, export_dir)

    notification_policies = get_notification_policies(config["GRAFANA_URL"], headers, verify, retry_count)
    export_item("notification_policy", notification_policies, export_dir)

    mute_timings = get_mute_timings(config["GRAFANA_URL"], headers, verify, retry_count)
    for mute_timing in mute_timings:
        export_item("mute_timing", mute_timing, export_dir)

    print("All items exported.")

def delete_dashboard(grafana_url: str, headers: Dict[str, str], uid: str, verify: bool, retry_count: int):
    delete_url = f"{grafana_url}/api/dashboards/uid/{uid}"
    make_api_request("DELETE", delete_url, headers, verify=verify, retry_count=retry_count)
    print(f"Deleted dashboard with UID: {uid}")

def delete_datasource(grafana_url: str, headers: Dict[str, str], uid: str, verify: bool, retry_count: int):
    delete_url = f"{grafana_url}/api/datasources/uid/{uid}"
    make_api_request("DELETE", delete_url, headers, verify=verify, retry_count=retry_count)
    print(f"Deleted datasource with UID: {uid}")

def delete_alert_rule(grafana_url: str, headers: Dict[str, str], uid: str, verify: bool, retry_count: int):
    delete_url = f"{grafana_url}/api/v1/provisioning/alert-rules/{uid}"
    make_api_request("DELETE", delete_url, headers, verify=verify, retry_count=retry_count)
    print(f"Deleted alert rule with UID: {uid}")

def delete_contact_point(grafana_url: str, headers: Dict[str, str], uid: str, verify: bool, retry_count: int):
    delete_url = f"{grafana_url}/api/v1/provisioning/contact-points/{uid}"
    make_api_request("DELETE", delete_url, headers, verify=verify, retry_count=retry_count)
    print(f"Deleted contact point with UID: {uid}")

def delete_notification_policies(grafana_url: str, headers: Dict[str, str], verify: bool, retry_count: int):
    delete_url = f"{grafana_url}/api/v1/provisioning/policies"
    make_api_request("DELETE", delete_url, headers, verify=verify, retry_count=retry_count)
    print("Deleted all notification policies")

def delete_folder(grafana_url: str, headers: Dict[str, str], uid: str, verify: bool, retry_count: int):
    delete_url = f"{grafana_url}/api/folders/{uid}"
    make_api_request("DELETE", delete_url, headers, verify=verify, retry_count=retry_count)
    print(f"Deleted folder with UID: {uid}")

def delete_mute_timing(grafana_url: str, headers: Dict[str, str], name: str, verify: bool, retry_count: int):
    delete_url = f"{grafana_url}/api/v1/provisioning/mute-timings/{name}"
    make_api_request("DELETE", delete_url, headers, verify=verify, retry_count=retry_count)
    print(f"Deleted mute timing: {name}")

def create_find_folder_uid(grafana_url: str, headers: Dict[str, str], name: str ,verify: bool, retry_count: int) -> str:
    try:
        folders = get_folders(grafana_url, headers, verify, retry_count)
        general_folder = next((folder for folder in folders if folder['title'] == name), None)

        if general_folder:
            return general_folder['uid']
    except Exception:

        pass

    create_folder_url = f"{grafana_url}/api/folders"

    folder_data = {
        "title": name
    }

    response = make_api_request("POST", create_folder_url, headers, json_data=folder_data, verify=verify, retry_count=retry_count)
    created_folder = json.loads(response.text)
    return created_folder['uid']

def import_grafana_data(config: Dict[str, str], force: bool):
    headers = get_headers(config["GRAFANA_API_KEY"])
    verify = not config["GRAFANA_URL"].startswith("https://")
    retry_count = int(config["RETRY_COUNT"])
    general_folder_name = 'Dashboards'

    existing_dashboards = {d['title']: d['uid'] for d in get_dashboards(config["GRAFANA_URL"], headers, verify, retry_count) if d['uid'] and d['uid'] != ''}
    existing_datasources = {d['name']: d['uid'] for d in get_datasources(config["GRAFANA_URL"], headers, verify, retry_count) if d['uid'] and d['uid'] != ''}
    existing_alert_rules = {d['title']: d['uid'] for d in get_alert_rules(config["GRAFANA_URL"], headers, verify, retry_count) if d['uid'] and d['uid'] != ''}
    existing_contact_points = {d['name']: d['uid'] for d in get_contact_points(config["GRAFANA_URL"], headers, verify, retry_count) if d['uid'] and d['uid'] != ''}
    existing_folders = {d['title']: d['uid'] for d in get_folders(config["GRAFANA_URL"], headers, verify, retry_count) if d['uid'] and d['uid'] != ''}
    existing_mute_timings = {d['name']: d['name'] for d in get_mute_timings(config["GRAFANA_URL"], headers, verify, retry_count)}

    import_dir = config["EXPORT_DIR"]
    if config["EXPERIMENT_NAME"]:
        import_dir = os.path.join(import_dir, config["EXPERIMENT_NAME"])

    if force:
        delete_order = [
            ("dashboard", existing_dashboards),
            ("alert_rule", existing_alert_rules),
            ("notification_policy", None),
            ("contact_point", existing_contact_points),
            ("datasource", existing_datasources),
            ("folder",existing_folders),
            ("mute_timing", existing_mute_timings)
        ]

        for item_type, items in delete_order:
            if item_type == "notification_policy":
                try:
                    delete_notification_policies(config["GRAFANA_URL"], headers, verify, retry_count)
                except Exception as e:
                    print(f"Failed to delete notification policies: {e}")
            elif items:
                for uid in items.values():
                    try:
                        if item_type == "dashboard":
                            delete_dashboard(config["GRAFANA_URL"], headers, uid, verify, retry_count)
                        elif item_type == "mute_timing":
                            delete_mute_timing(config["GRAFANA_URL"], headers, uid, verify, retry_count)
                        elif item_type == "contact_point":
                            delete_contact_point(config["GRAFANA_URL"], headers, uid, verify, retry_count)
                        elif item_type == "folder":
                            delete_folder(config["GRAFANA_URL"], headers, uid, verify, retry_count)
                        elif item_type == "alert_rule":
                            delete_alert_rule(config["GRAFANA_URL"], headers, uid, verify, retry_count)
                        elif item_type == "datasource":
                            delete_datasource(config["GRAFANA_URL"], headers, uid, verify, retry_count)
                    except Exception as e:
                        print(f"Failed to delete {item_type} with UID {uid}: {e}")
                        continue

    import_order = [ "datasource_", "folder_", "dashboard_", "mute_timing_", "contact_point_", "notification_policy_", "alert_rule_" ]

    general_folder_uid = create_find_folder_uid(config['GRAFANA_URL'], headers, general_folder_name , verify, retry_count)

    for prefix in import_order:
        for filename in os.listdir(import_dir):
            if filename.endswith(".json") and filename.startswith(prefix):
                with open(os.path.join(import_dir, filename), 'r') as f:
                    item_data = json.load(f)

                method='POST'
                if prefix == "datasource_":
                    import_url = f"{config['GRAFANA_URL']}/api/datasources"
                elif prefix == "folder_":
                     if  item_data['title'] == general_folder_name:
                         continue
                     import_url = f"{config['GRAFANA_URL']}/api/folders"
                     item_data['id'] = None
                elif prefix == "dashboard_":
                     import_url = f"{config['GRAFANA_URL']}/api/dashboards/db"
                     item_data['dashboard']['id'] = None
                     item_data['folderUid'] = general_folder_uid
                elif prefix == "contact_point_":
                    import_url = f"{config['GRAFANA_URL']}/api/v1/provisioning/contact-points"
                elif prefix == "notification_policy_":
                    import_url = f"{config['GRAFANA_URL']}/api/v1/provisioning/policies"
                    method='PUT'
                elif prefix == "alert_rule_":
                    import_url = f"{config['GRAFANA_URL']}/api/v1/provisioning/alert-rules"


                try:
                    make_api_request(method, import_url, headers, json_data=item_data, verify=verify, retry_count=retry_count)
                    print(f"Imported: {filename}")
                except requests.RequestException as e:
                    print(f"Failed to import {filename}: {e}")

    print("All items imported.")

def usage():
    print("Grafana Configuration Management Tool")
    print("\nDescription:")
    print("  This program allows you to export or import Grafana configurations including")
    print("  dashboards, datasources, alert rules, contact points, notification policies,")
    print("  folders, and mute timings.")
    print("\nUsage:")
    print("  python3 grafana-ninja.py --config <config_file> --mode <export|import> [--wipe-existing-data]")
    print("\nOptions:")
    print("  --config <file>     Path to the configuration file (required)")
    print("  --mode <mode>       Operation mode: 'export' or 'import' (required)")
    print("  --wipe-existing-data  All existing configuration settings will be deleted")
    print("  --token-instructions  Print instructions for creating a Grafana API token")
    print("  -h, /?, --help      Show this help message and exit")
    print("\nExamples:")
    print("  Export:  python3 grafana-ninja.py --config config.env --mode export")
    print("  Import:  python3 grafana-ninja.py --config config.env --mode import")
    print("  Wipe and Import: python3 grafana-ninja.py --config config.env --mode import --wipe-existing-data")
    print("  Token Instructions: python3 grafana-ninja.py --token-instructions")

def print_token_creation_instructions():
    instructions = """

Below is a guide on creating a Grafana API Token for the grafana-ninja.py program and instructions for adding it to your configuration:

1. Logging into Grafana web interface as admin user:
   - Open your web browser and navigate to your Grafana instance URL.
   - Enter your admin username and password on the login page.
   - Click "Log In" to access the Grafana dashboard.

2. Expanding the home panel on the left:
   - Look for the hamburger menu icon (≡) in the top-left corner of the interface.
   - Click on it to expand the left-side navigation panel.

3. Expanding the Administration, and then Users and access drop-down:
   - In the expanded left panel, scroll down to find "Administration".
   - Click on "Administration" to expand its sub-menu.
   - Look for "Users and access" and click to expand its options.

4. Clicking the "Service accounts" menu and adding a new API user account:
   - In the "Users and access" sub-menu, click on "Service accounts".
   - On the Service accounts page, click the "Add service account" button.
   - Fill in the required details:
     - Display name: Give your service account a descriptive name.
     - Role: Select the appropriate role (e.g., Admin for full access).
   - Click "Create" to create the service account.

5. Clicking on the "Add Service account token" and creating a token:
   - After creating the service account, you'll be redirected to its details page.
   - Click on the "Add service account token" button.
   - In the dialog that appears:
     - Token name: Give your token a descriptive name.
     - Expiration: Set an expiration date if desired, or leave it as "No expiration" for a permanent token.
   - Click "Generate token" to create the API token.

6. Copying the token and exiting the interface:
   - The newly generated token will be displayed on the screen.
   - IMPORTANT: Copy this token immediately and save it securely. It will only be shown once.
   - After copying, click "Close" or navigate away from the page.

Adding the token to config.env:

1. Open your config.env file in a text editor.
2. Add a new line or modify an existing line to include the GRAFANA_API_KEY:
   GRAFANA_API_KEY=your_copied_token_her
3. Save the file.

Also, ensure that your config.env file includes the GRAFANA_URL variable, which should point to your Grafana server instance. It should look something like this:
GRAFANA_URL=https://your-grafana-server:3000

Replace "https://your-grafana-server:3000" with the actual URL of your Grafana instance.

Remember to keep your config.env file secure, as it contains sensitive information. Never share your API token or include it in version control systems.
    """
    print(instructions)

def main():
    if len(sys.argv) == 1 or sys.argv[1] in ["-h", "/?", "--help"]:
        usage()
        sys.exit(0)
    if len(sys.argv) == 1 or sys.argv[1] in ["--token-instructions"]:
        print_token_creation_instructions()
        sys.exit(0)

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--config", required=True, help="Path to configuration file")
    parser.add_argument("--mode", choices=["export", "import"], required=True, help="Operation mode")
    parser.add_argument("--wipe-existing-data", action="store_true", help="All existing configuration settings will be deleted")

    try:
        args = parser.parse_args()
    except SystemExit:
        usage()
        sys.exit(1)

    config = load_config(args.config)

    if config["GRAFANA_URL"].startswith("https://"):
        requests.packages.urllib3.disable_warnings(category=InsecureRequestWarning)

    try:
        get_folders(config["GRAFANA_URL"], get_headers(config["GRAFANA_API_KEY"]), not config["GRAFANA_URL"].startswith("https://"), int(config["RETRY_COUNT"]))
    except Exception as e:
        print()
        print()
        print(f"Error: Unable to connect to Grafana or authenticate.\n Details: {e}")
        print("This could be due to an invalid GRAFANA_URL or GRAFANA_API_KEY in your configuration.")
        print()
        print(f"Please check the following in your config file '{args.config}':")
        print("1. GRAFANA_URL is correct and Grafana is accessible from this machine.")
        print("2. GRAFANA_API_KEY is valid and has the necessary permissions.")
        print("3. Your network configuration allows this connection.")
        print()
        print("\nFor help creating a valid API token, run this program with the --token-instructions option.")
        print("If the problem persists, check Grafana's logs for more information.")
        sys.exit(1)

    if args.mode == "export":
        export_grafana_data(config)
    elif args.mode == "import":
        import_grafana_data(config, args.wipe_existing_data)

if __name__ == "__main__":
    main()
