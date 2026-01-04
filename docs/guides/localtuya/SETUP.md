# LocalTuya Setup Guide - Complete Local Control

## Overview
LocalTuya allows you to control all your Tuya devices **locally** without cloud dependency:
- ✅ **Zero latency** - Direct communication with devices
- ✅ **Works offline** - No internet required
- ✅ **More reliable** - No cloud sync delays
- ✅ **Privacy** - No data sent to Tuya cloud

## Prerequisites

You need to obtain **local keys** for each device. This requires:
1. Tuya Developer account
2. Link your Tuya/Smart Life app to the developer account
3. Extract device IDs and local keys

## Step 1: Get Tuya Developer Credentials

### 1.1 Create Tuya IoT Platform Account
```bash
# Visit: https://iot.tuya.com/
# Sign up with the same email as your Smart Life app
# Create a cloud project
```

### 1.2 Get API Credentials
- Go to Cloud → Development → Your Project
- Note down:
  - **Access ID** (Client ID)
  - **Access Secret** (Client Secret)
  - **Data Center**: Based on your region (US = us-east-1)

### 1.3 Link Your App Devices
- Cloud → API Group → Add API Group (if needed)
- Cloud → Link Devices → Link to App Account
- Select "Smart Life" or "Tuya Smart"
- Scan QR code with your mobile app

## Step 2: Extract Device Information

### Method 1: Using Tuya Debug Tool (Recommended)

Install the Tuya IoT Core Python library:
```bash
# On your Mac or any machine with Python
pip3 install tuya-iot-py-sdk
```

Create a script to list all devices:
```python
#!/usr/bin/env python3
"""
Get Tuya device information including local keys
"""
import json
from tuya_iot import TuyaOpenAPI

# Your credentials from Step 1.2
ACCESS_ID = "your_access_id_here"
ACCESS_SECRET = "your_access_secret_here"
API_ENDPOINT = "https://openapi.tuyaus.com"  # US endpoint

# Initialize API
openapi = TuyaOpenAPI(API_ENDPOINT, ACCESS_ID, ACCESS_SECRET)
openapi.connect()

# Get all devices
response = openapi.get("/v1.0/iot-03/devices", dict())

if response['success']:
    devices = response['result']

    print(f"Found {len(devices)} devices:\n")

    for device in devices:
        print(f"Device: {device['name']}")
        print(f"  ID: {device['id']}")
        print(f"  Local Key: {device['local_key']}")
        print(f"  IP: {device.get('ip', 'Unknown')}")
        print(f"  Product ID: {device['product_id']}")
        print(f"  Category: {device['category']}")
        print()
else:
    print(f"Error: {response}")
```

Save as `/tmp/get_tuya_devices.py` and run:
```bash
python3 /tmp/get_tuya_devices.py > /tmp/tuya_devices.txt
cat /tmp/tuya_devices.txt
```

### Method 2: Using tinytuya (Alternative)

```bash
pip3 install tinytuya
python3 -m tinytuya wizard
# Follow prompts to enter credentials
# This will generate devices.json with all device info
```

## Step 3: Install LocalTuya in Home Assistant

### 3.1 Install HACS (if not already installed)
```bash
# In Home Assistant UI:
# Settings → Add-ons → Add-on Store → Search for "HACS"
# Or follow: https://hacs.xyz/docs/setup/download
```

### 3.2 Install LocalTuya via HACS
1. Home Assistant → HACS → Integrations
2. Search for "LocalTuya"
3. Click Install
4. Restart Home Assistant

### 3.3 Configure LocalTuya
1. Settings → Devices & Services → Add Integration
2. Search for "LocalTuya"
3. For each device, you'll need:
   - **Host**: Device IP address (from Step 2)
   - **Device ID**: Device ID (from Step 2)
   - **Local Key**: Local key (from Step 2)
   - **Protocol Version**: Usually 3.3 (try 3.1 if issues)

## Step 4: Configure Your Landscape Lighting

Based on your entity registry, you have:
- **Landscape Lighting** (3-channel switch)
  - Device ID: `ebdc1aa3cfd5438376ktom`
  - Switch 1: Path Lights
  - Switch 2: Wall Lights

### 4.1 Find the IP Address

From Home Assistant, you can check the Tuya integration device info, or:
```bash
# SSH to a cluster node and scan your IoT network
nmap -sn 10.10.204.0/24 | grep -B 2 "Tuya"
```

Or check your router's DHCP leases for the device MAC address.

### 4.2 Add to LocalTuya

1. Settings → Devices & Services → LocalTuya → Add Device
2. Enter device information:
   - **Friendly Name**: Landscape Lighting
   - **Host**: 10.10.204.XXX (from scan)
   - **Device ID**: ebdc1aa3cfd5438376ktom
   - **Local Key**: (from Step 2)
   - **Protocol Version**: 3.3
   - **Scan Interval**: 30 seconds

3. Configure entities:
   - **Switch 1** (DPS 1): Path Lights
   - **Switch 2** (DPS 2): Wall Lights
   - **Switch 3** (DPS 3): Unused

## Step 5: Remove Cloud Tuya Integration

Once LocalTuya is working:
1. Settings → Devices & Services
2. Find "Tuya" integration
3. Click ... → Delete
4. This removes cloud dependency

## Step 6: Update Automations

Your existing automations will continue to work with the same entity IDs:
- `light.landscape_lighting_switch_1` (Path Lights)
- `light.landscape_lighting_switch_2` (Wall Lights)

LocalTuya creates identical entity IDs, so no automation changes needed!

## Troubleshooting

### Device Won't Connect
1. **Check Protocol Version**: Try 3.3, 3.1, or 3.2
2. **Verify Local Key**: Keys change if device is reset or re-paired
3. **Check Network**: Ensure Home Assistant can reach IoT VLAN (10.10.204.0/24)
4. **Firewall**: Device port 6668 must be accessible

### Getting New Local Keys After Device Reset
If you reset a device, the local key changes:
1. Re-pair device in Smart Life app
2. Wait 24 hours (or use tuya-cli to force sync)
3. Re-run Step 2 to get new local key

### Testing Connection
```bash
# From Home Assistant pod
kubectl exec -n home-automation home-assistant-5c4d6dbb66-v8k4h -- \
  python3 -c "
import socket
s = socket.socket()
s.settimeout(2)
try:
    s.connect(('10.10.204.XXX', 6668))
    print('✅ Device reachable')
except:
    print('❌ Cannot reach device')
"
```

## Benefits You'll See

### Before (Cloud Tuya):
- Command → HA → Tuya Cloud → Device (500-2000ms)
- Requires internet
- Cloud sync delays cause state revert issues

### After (LocalTuya):
- Command → HA → Device (10-50ms)
- Works offline
- Instant state updates
- No sync conflicts

## Next Steps

1. Run the device discovery script (Step 2)
2. Share the output (remove sensitive keys when sharing!)
3. I'll help configure each device in LocalTuya
4. Test and verify all devices work locally
5. Remove cloud Tuya integration

Would you like me to create the device discovery script for you now?
