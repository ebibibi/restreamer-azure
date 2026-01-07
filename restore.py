#!/usr/bin/env python3
"""Restore Restreamer configuration from backup via API."""

import json
import sys
import urllib.request
import urllib.error

def api_login(base_url, username, password):
    """Login and get access token."""
    url = f"{base_url}/api/login"
    data = json.dumps({"username": username, "password": password}).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.load(resp)
            return result.get("access_token")
    except Exception as e:
        print(f"Login failed: {e}")
        return None

def api_request(base_url, token, method, endpoint, data=None):
    """Make authenticated API request."""
    url = f"{base_url}{endpoint}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }

    if data is not None:
        data = json.dumps(data).encode()

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            if resp.status in (200, 201, 204):
                try:
                    return json.load(resp)
                except:
                    return True
    except urllib.error.HTTPError as e:
        print(f"  API error {e.code}: {e.reason}")
        return None
    except Exception as e:
        print(f"  Request failed: {e}")
        return None

def restore_from_backup(base_url, username, password, backup_file):
    """Restore processes and metadata from backup file."""

    # Load backup
    try:
        with open(backup_file, 'r') as f:
            backup = json.load(f)
    except Exception as e:
        print(f"Failed to load backup: {e}")
        return False

    # Login
    print("Logging in to API...")
    token = api_login(base_url, username, password)
    if not token:
        print("Failed to login")
        return False
    print("Login successful")

    # Restore processes
    processes = backup.get("process", {})
    print(f"\nRestoring {len(processes)} processes...")

    for proc_id, proc_data in processes.items():
        print(f"  Creating process: {proc_id}")
        config = proc_data.get("config", {})
        result = api_request(base_url, token, "POST", "/api/v3/process", config)
        if result:
            print(f"    OK")
        else:
            print(f"    Failed (may already exist)")

    # Restore metadata
    metadata = backup.get("metadata", {})

    # System metadata
    system_meta = metadata.get("system", {})
    for key, value in system_meta.items():
        print(f"  Setting system metadata: {key}")
        result = api_request(base_url, token, "PUT", f"/api/v3/metadata/{key}", value)
        if result:
            print(f"    OK")

    # Process metadata
    process_meta = metadata.get("process", {})
    for proc_id, meta_value in process_meta.items():
        if meta_value is None:
            continue
        # Extract the metadata key (usually "restreamer-ui")
        for meta_key, meta_data in meta_value.items():
            print(f"  Setting process metadata: {proc_id}/{meta_key}")
            result = api_request(base_url, token, "PUT", f"/api/v3/process/{proc_id}/metadata/{meta_key}", meta_data)
            if result:
                print(f"    OK")

    print("\nRestore completed!")
    return True

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} <base_url> <username> <password> <backup_file>")
        sys.exit(1)

    base_url = sys.argv[1]
    username = sys.argv[2]
    password = sys.argv[3]
    backup_file = sys.argv[4]

    success = restore_from_backup(base_url, username, password, backup_file)
    sys.exit(0 if success else 1)
