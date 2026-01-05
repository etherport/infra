#!/bin/bash
# Quick Tuya Device Status Checker
# Run this to see which devices are online and ready for LocalTuya setup
#
# Usage: ./check-device-status.sh

set -euo pipefail

# Check if virtual environment exists
if [ ! -d "/tmp/tuya-venv" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv /tmp/tuya-venv
    source /tmp/tuya-venv/bin/activate
    echo "Installing tinytuya..."
    pip install -q tinytuya
else
    source /tmp/tuya-venv/bin/activate
fi

echo "Retrieving credentials from 1Password..."
ACCESS_ID=$(op item get "Tuya API" --fields username 2>/dev/null)
ACCESS_SECRET=$(op item get "Tuya API" --fields credential 2>/dev/null)

if [ -z "$ACCESS_ID" ] || [ -z "$ACCESS_SECRET" ]; then
    echo "❌ Error: Could not retrieve credentials from 1Password"
    echo "Make sure you're logged in: op signin"
    exit 1
fi

echo ""
echo "Checking device status..."
echo ""

python3 <<PYTHON
import tinytuya
from datetime import datetime

ACCESS_ID = "${ACCESS_ID}"
ACCESS_SECRET = "${ACCESS_SECRET}"

cloud = tinytuya.Cloud(
    apiRegion="us",
    apiKey=ACCESS_ID,
    apiSecret=ACCESS_SECRET
)

devices = cloud.getdevices()

if not devices:
    print("❌ No devices found")
    exit(1)

online_count = sum(1 for d in devices if d.get('online'))
offline_count = len(devices) - online_count

print("=" * 80)
print(f"TUYA DEVICE STATUS - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
print("=" * 80)
print(f"\nTotal devices: {len(devices)}")
print(f"✅ Online:     {online_count}")
print(f"❌ Offline:    {offline_count}")
print()

if online_count > 0:
    print("=" * 80)
    print("READY FOR LOCALTUYA (Online devices with local keys)")
    print("=" * 80)
    print()

    ready_count = 0
    for device in devices:
        if device.get('online'):
            local_key = device.get('local_key', '')
            name = device.get('name', 'Unknown')
            device_id = device.get('id', '')
            ip = device.get('ip', 'Unknown')

            if local_key:
                ready_count += 1
                print(f"[{ready_count}] {name}")
                print(f"    Device ID:  {device_id}")
                print(f"    Local Key:  {local_key}")
                print(f"    IP Address: {ip}")
                print(f"    Product:    {device.get('product_name', 'N/A')}")
                print()

    if ready_count == 0:
        print("⚠️  Online devices found but no local keys available yet.")
        print("   Wait 2-3 minutes for cloud sync, then run this script again.")
        print()

if offline_count > 0:
    print("=" * 80)
    print("OFFLINE DEVICES")
    print("=" * 80)
    print()

    for device in devices:
        if not device.get('online'):
            print(f"  • {device.get('name', 'Unknown')}")
            print(f"    ID: {device.get('id', '')}")
            print(f"    Product: {device.get('product_name', 'N/A')}")
            print()

    print("Action needed:")
    print("  1. Check Smart Life app to see device status")
    print("  2. Verify devices are powered on")
    print("  3. Check WiFi connectivity")
    print("  4. Power cycle if necessary")
    print()

print("=" * 80)

if online_count > 0 and ready_count > 0:
    print("\n✅ You can proceed with LocalTuya setup for the ready devices!")
    print("   See: docs/guides/localtuya/SETUP.md")
elif online_count > 0:
    print("\n⏳ Devices are online but local keys not synced yet.")
    print("   Wait a few minutes and run this script again.")
else:
    print("\n❌ All devices offline - check Smart Life app and power status")
    print("   See: docs/guides/localtuya/TROUBLESHOOTING.md")

print("=" * 80)
PYTHON
