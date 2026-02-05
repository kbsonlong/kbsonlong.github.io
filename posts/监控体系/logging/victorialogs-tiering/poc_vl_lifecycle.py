#!/usr/bin/env python3
import json
import datetime
import urllib.request
import urllib.error
import os
import subprocess
import argparse

# Configuration
HOT_URL = "http://localhost:9428"
WARN_URL = "http://localhost:9429"
HOT_DATA_DIR = "./data/vl7d"
WARN_DATA_DIR = "./data/vl180d"

# Ensure absolute paths for rsync
HOT_DATA_DIR = os.path.abspath(HOT_DATA_DIR)
WARN_DATA_DIR = os.path.abspath(WARN_DATA_DIR)

def get_partitions_hot():
    """List partitions from Hot node using API or filesystem."""
    partitions = []
    # Try API first
    try:
        url = f"{HOT_URL}/internal/partition/list"
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode())
            # API returns structured data, need to parse
            # Expected format: {"partitions": [{"name": "20231001", ...}]}
            if "partitions" in data:
                return [p["name"] for p in data["partitions"]]
    except Exception as e:
        print(f"Warning: Could not list partitions via API ({e}). Falling back to filesystem.")

    # Fallback to filesystem
    partition_path = os.path.join(HOT_DATA_DIR, "partitions")
    if os.path.exists(partition_path):
        for name in os.listdir(partition_path):
            if name.isdigit() and len(name) == 8: # YYYYMMDD
                partitions.append(name)
    return partitions

def backfill_data():
    """Generate and ingest 7 days of historical data."""
    print(">>> Starting Backfill (7 days)...")
    now = datetime.datetime.now(datetime.timezone.utc)

    for day_offset in range(14, -1, -1):
        date = now - datetime.timedelta(days=day_offset)
        print(f"Generating data for {date.strftime('%Y-%m-%d')}...")

        # Generate 10 logs per hour for this day
        for hour in range(24):
            # Construct a timestamp for this specific hour
            log_time = date.replace(hour=hour, minute=0, second=0, microsecond=0)

            # Check if log_time is in the future
            if log_time > now:
                continue

            lines = []
            for i in range(10):
                log_entry = {
                    "_time": log_time.isoformat(),
                    "_msg": f"Simulated log message {i} for backfill",
                    "level": "info",
                    "host": "poc-host",
                    "env": "prod",
                    "offset": day_offset,
                    "batch": i
                }
                lines.append(json.dumps(log_entry))

            # Send batch
            data = "\n".join(lines)
            try:
                req = urllib.request.Request(
                    f"{HOT_URL}/insert/jsonline",
                    data=data.encode('utf-8'),
                    headers={'Content-Type': 'application/stream+json'}
                )
                with urllib.request.urlopen(req) as response:
                    pass
            except urllib.error.URLError as e:
                print(f"Error inserting data: {e}")
                return

    print(">>> Backfill complete.")

def migrate_partitions():
    """Check for partitions older than 2 days and migrate them."""
    print(">>> Checking for partitions to migrate...")
    partitions = get_partitions_hot()
    print(f"Found partitions on Hot: {partitions}")

    now = datetime.datetime.now(datetime.timezone.utc)
    cutoff_date = now - datetime.timedelta(days=6)
    cutoff_str = cutoff_date.strftime("%Y%m%d")
    print(f"Migration cutoff: Partitions older than {cutoff_str} (approx 2 days ago)")

    migrated = False

    for part_name in partitions:
        # Check format YYYYMMDD
        if len(part_name) != 8 or not part_name.isdigit():
            continue

        if part_name < cutoff_str:
            print(f"--- Migrating Partition: {part_name} ---")

            # 1. Create Snapshot
            print("1. Creating snapshot...")
            try:
                snap_url = f"{HOT_URL}/internal/partition/snapshot/create?name={part_name}"
                with urllib.request.urlopen(snap_url) as resp:
                    res_json = json.loads(resp.read().decode())
                    print(res_json)
                    if len(res_json) == 0:
                        print("Error: No snapshot path returned.")
                        continue
                    # API returns: {"snapshotPath": "..."}
                    # The path is inside the container, e.g., /data/vl/snapshots/YYYYMMDD...
                    container_snap_path = res_json[0]
                    if not container_snap_path:
                        print("Error: No snapshot path returned.")
                        continue
                    print(f"   Snapshot created at: {container_snap_path}")
            except Exception as e:
                print(f"   Error creating snapshot: {e}")
                continue

            # 2. Translate Path (Container -> Host)
            # Assumption: Container /data/vl maps to Host HOT_DATA_DIR
            # snapshot path: /data/vl/snapshots/YYYYMMDD...
            rel_path = container_snap_path.replace("/data/vl/", "", 1)
            host_snap_path = os.path.join(HOT_DATA_DIR, rel_path)

            if not os.path.exists(host_snap_path):
                print(f"   Error: Host snapshot path not found: {host_snap_path}")
                print("   (Ensure docker volumes are mapped as ./data/vl2d:/data/vl)")
                continue

            # 3. Rsync to Warn
            dest_dir = os.path.join(WARN_DATA_DIR, "partitions")
            # Ensure dest dir exists
            os.makedirs(dest_dir, exist_ok=True)

            print(f"2. Rsyncing to Warn node ({dest_dir})...")
            # rsync -a source/ destination/ (source/ contents go to destination)
            # We want source (the partition dir) to be a SUBDIR in destination.
            # host_snap_path is .../snapshots/YYYYMMDD_UUID
            # We want to rename it to YYYYMMDD in destination?
            # VictoriaLogs partitions are YYYYMMDD.
            # Snapshots usually have a suffix.
            # Let's check the content of host_snap_path. It contains parts.
            # We should sync to WARN_DATA_DIR/partitions/YYYYMMDD

            target_partition_dir = os.path.join(dest_dir, part_name)

            # rsync command
            # Using --delete to ensure clean copy
            cmd = ["rsync", "-av", "--delete", f"{host_snap_path}/", target_partition_dir]
            try:
                subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                print("   Rsync successful.")
            except subprocess.CalledProcessError as e:
                print(f"   Rsync failed: {e}")
                continue

            # 4. Detach from Hot
            print("3. Detaching from Hot...")
            try:
                detach_url = f"{HOT_URL}/internal/partition/detach?name={part_name}"
                with urllib.request.urlopen(detach_url) as resp:
                    print("   Detached successfully.")
            except Exception as e:
                print(f"   Error detaching: {e}")

            # 5. Attach to Warn
            print(f"5. Attaching to Warn node ({part_name})...")
            try:
                attach_url = f"{WARN_URL}/internal/partition/attach?name={part_name}"
                with urllib.request.urlopen(attach_url) as resp:
                    print("   Attached successfully.")
            except Exception as e:
                print(f"   Error attaching: {e}")

            # 6. Cleanup Snapshot
            # There isn't a snapshot delete API explicitly documented widely,
            # but we should clean up the filesystem.
            # Or assume retention handles it? No, snapshots are usually separate.
            # We can rm -rf the snapshot dir on host.
            print("6. Cleaning up snapshot...")
            subprocess.run(["rm", "-rf", host_snap_path])

            migrated = True

    if migrated:
        print(">>> Migration actions performed.")
    else:
        print(">>> No partitions need migration.")

def main():
    parser = argparse.ArgumentParser(description="VictoriaLogs Lifecycle POC")
    parser.add_argument("action", choices=["backfill", "migrate"], help="Action to perform: 'backfill' for data generation, 'migrate' for partition movement")
    args = parser.parse_args()

    print(f"=== VictoriaLogs Lifecycle POC: {args.action.upper()} ===")

    # Check if services are reachable
    try:
        urllib.request.urlopen(f"{HOT_URL}/ping", timeout=1)
    except Exception:
        print("Error: victorialogs-hot is not reachable at localhost:9428. Is Docker running?")
        print("Continuing anyway to demonstrate logic (will fail on connection)...")

    if args.action == "backfill":
        backfill_data()
    elif args.action == "migrate":
        migrate_partitions()

    print("=== POC Complete ===")

if __name__ == "__main__":
    main()