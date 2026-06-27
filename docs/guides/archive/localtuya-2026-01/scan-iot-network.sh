#!/bin/bash
# Tuya Device Network Scanner
# Run this while connected to IoT network (10.10.204.0/24)

set -euo pipefail

echo "=" \* 80
echo "TUYA DEVICE NETWORK SCANNER"
echo "=" \* 80
echo ""
echo "This will:"
echo "  1. Scan IoT network for Tuya devices"
echo "  2. Map IPs to device IDs"
echo "  3. Save results for LocalTuya setup"
echo ""
echo "Prerequisites:"
echo "  - Connected to IoT network (10.10.204.0/24)"
echo "  - Python virtual environment at /tmp/tuya-venv"
echo ""

# Check if on IoT network
CURRENT_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "unknown")
echo "Your current IP: $CURRENT_IP"

if [[ ! "$CURRENT_IP" =~ ^10\.10\.204\. ]]; then
    echo ""
    echo "⚠️  WARNING: You don't appear to be on the IoT network (10.10.204.0/24)"
    echo ""
    read -p "Continue anyway? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        exit 1
    fi
fi

echo ""
echo "Starting scan..."
echo ""

# Activate Python venv
source /tmp/tuya-venv/bin/activate

# Run tinytuya scanner
python3 <<'PYTHON'
import tinytuya
import json
import socket

print("=" * 80)
print("STEP 1: TINYTUYA NETWORK SCAN")
print("=" * 80)
print()
print("Scanning for Tuya devices on local network...")
print("This may take 30-60 seconds...")
print()

# Scan for devices
devices = tinytuya.deviceScan(verbose=False, maxretry=5, color=False)

if not devices:
    print("❌ No Tuya devices found via tinytuya scan")
    print()
    print("This could mean:")
    print("  1. Devices are powered off")
    print("  2. Not on same network segment")
    print("  3. Firewall blocking UDP port 6666/6667")
    print()
    print("Try using lanscan to find devices instead (see below)")
else:
    print(f"✅ Found {len(devices)} Tuya device(s)!")
    print("=" * 80)
    print()

    results = []

    for ip, data in devices.items():
        device_id = data.get('gwId', data.get('id', 'Unknown'))
        version = data.get('version', 'Unknown')

        print(f"IP Address: {ip}")
        print(f"  Device ID: {device_id}")
        print(f"  Version:   {version}")

        # Try to get hostname
        try:
            hostname = socket.gethostbyaddr(ip)[0]
            print(f"  Hostname:  {hostname}")
        except:
            print(f"  Hostname:  (reverse DNS failed)")

        results.append({
            'ip': ip,
            'device_id': device_id,
            'version': version
        })

        print()

    # Save results
    output_file = '/Users/grahamsmith/Projects/homelab-infra/docs/guides/localtuya/network-scan-results.json'
    with open(output_file, 'w') as f:
        json.dump(results, f, indent=2)

    print("=" * 80)
    print(f"✅ Results saved to: {output_file}")
    print("=" * 80)

print()
print("=" * 80)
print("STEP 2: MAP TO KNOWN DEVICES")
print("=" * 80)
print()

# Known devices from API discovery
known_devices = {
    'ebdc1aa3cfd5438376ktom': 'Landscape Lighting',
    '30000164e09806cb6be9': 'Counter Lights',
    '0225833624a160011195': 'Office Balls',
    'eb97cd9d82225998ecofmi': 'Window Light',
    'eb0fbce27fb4f00c30v6ys': 'Bench light',
    'ebab6535a9e78c3a3bfv7v': 'Kitchen Strip',
    '81705067c44f33e52bcc': 'Laundry room dimmer',
    '81705067c44f33ef458d': 'Tree Light',
    '6840080140f520f15d90': 'Mantle Lights'
}

if devices:
    print("Device Mapping:")
    print("-" * 80)

    matched = []

    for ip, data in devices.items():
        device_id = data.get('gwId', data.get('id', ''))
        name = known_devices.get(device_id, '❓ Unknown Device')

        print(f"{name}")
        print(f"  IP:        {ip}")
        print(f"  Device ID: {device_id}")

        if name != '❓ Unknown Device':
            matched.append({
                'name': name,
                'ip': ip,
                'device_id': device_id
            })

        print()

    print(f"Matched {len(matched)} out of {len(known_devices)} known devices")

    if matched:
        # Save matched devices
        matched_file = '/Users/grahamsmith/Projects/homelab-infra/docs/guides/localtuya/devices-with-ips.json'
        with open(matched_file, 'w') as f:
            json.dump(matched, f, indent=2)
        print(f"✅ Saved matched devices to: {matched_file}")

print()
print("=" * 80)
print("NEXT STEPS")
print("=" * 80)
print()

if devices:
    print("✅ Network scan successful!")
    print()
    print("You now have IP addresses for your devices.")
    print()
    print("Still needed:")
    print("  ❌ Local Keys (16-character encryption keys)")
    print()
    print("To get local keys:")
    print("  1. Try Smart Life app developer mode (recommended)")
    print("  2. Check project API permissions")
    print("  3. Contact Tuya support")
    print()
    print("See: docs/guides/localtuya/GETTING-LOCAL-KEYS.md")
else:
    print("⚠️  tinytuya scan found no devices")
    print()
    print("Try using lanscan instead:")
    print("  lanscan -s -f 10.10.204.0/24")
    print()
    print("Or nmap:")
    print("  nmap -sn 10.10.204.0/24")
    print()
    print("Look for devices with manufacturers:")
    print("  - Tuya")
    print("  - Espressif (ESP chips used in Tuya devices)")
    print("  - Hangzhou BroadLink")

print()
print("=" * 80)
PYTHON

echo ""
echo "Scan complete!"
