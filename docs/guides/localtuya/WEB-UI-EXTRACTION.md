# Extract Local Keys from Tuya Web UI

The API is returning cached "offline" status, but your web UI shows 8/9 devices as **online**. You can get the local keys directly from the web interface.

## Quick Method: Click "Debug Device"

From your Devices tab screenshot, each device has a "Debug Device" link on the right side.

### Steps:

1. Open https://iot.tuya.com/
2. Go to: **Cloud** → **Development** → **Windtryst Home Assistant** project
3. Click **Devices** tab (you're already there based on screenshot)
4. For each online device, click **"Debug Device"** on the right

This will show full device information including:
- Device ID (you already have this)
- Local Key (this is what you need!)
- IP Address
- Current status/state

## Devices to Extract (Priority Order)

Start with **Landscape Lighting** (your target device):

### 1. Landscape Lighting ⭐ (PRIORITY!)
- **Device ID**: `ebdc1aa3cfd5438376ktom`
- **Product**: Low Voltage Transformer with 3 Zones
- **Status**: Online ✅
- **Local Key**: ??? ← Get from Debug Device

### 2. Counter Lights
- **Device ID**: `30000164e09806cb6be9`
- **Product**: WP3_C-AR
- **Status**: Online ✅
- **Local Key**: ??? ← Get from Debug Device

### 3. Office Balls
- **Device ID**: `0225833624a160011195`
- **Product**: WP3_C-AR
- **Status**: Online ✅
- **Local Key**: ??? ← Get from Debug Device

### 4. Window Light
- **Device ID**: `eb97cd9d82225998ecofmi`
- **Product**: Strip Light
- **Status**: Online ✅
- **Local Key**: ??? ← Get from Debug Device

### 5. Bench light
- **Device ID**: `eb0fbce27fb4f00c30v6ys`
- **Product**: LST04-F RGBW (Feit)
- **Status**: Online ✅
- **Local Key**: ??? ← Get from Debug Device

### 6. Kitchen Strip
- **Device ID**: `ebab6535a9e78c3a3bfv7v`
- **Product**: LST04-F RGBW (Feit)
- **Status**: Online ✅
- **Local Key**: ??? ← Get from Debug Device

### 7. Laundry room dimmer
- **Device ID**: `81705067c44f33e52bcc`
- **Product**: Dimmer Switch
- **Status**: Online ✅
- **Local Key**: ??? ← Get from Debug Device

### 8. Tree Light
- **Device ID**: `81705067c44f33ef458d`
- **Product**: Dimmer Switch
- **Status**: Online ✅
- **Local Key**: ??? ← Get from Debug Device

### 9. Mantle Lights (SKIP - Offline)
- **Device ID**: `6840080140f520f15d90`
- **Status**: Offline ❌
- Can add later when online

## What a Local Key Looks Like

Local keys are **16 character** alphanumeric strings, like:
- `a1b2c3d4e5f6g7h8`
- `Ab12Cd34Ef56Gh78`

## Collecting the Keys

### Option 1: Manual Collection
Just click through each device's "Debug Device" and copy the local keys to a text file.

### Option 2: Use Helper Script
Run this script and paste keys as you find them:
```bash
cd /Users/grahamsmith/Projects/homelab-infra
./docs/guides/localtuya/extract-from-web-ui.sh
```

The script will:
- Prompt you for each device's local key
- Optionally collect IP addresses
- Generate the JSON file for LocalTuya setup

## Expected Output

Once you have the local keys, you'll have a file like:
```json
[
  {
    "name": "Landscape Lighting",
    "id": "ebdc1aa3cfd5438376ktom",
    "local_key": "abc123def456gh78",
    "ip": "10.10.204.15",
    "online": true
  },
  ...
]
```

## IP Addresses

You also need IP addresses for LocalTuya. Options:

### From Tuya Web UI
- The "Debug Device" page may show the IP

### From Router
- Check your router's DHCP lease table
- Look for devices with these names
- IoT VLAN: `10.10.204.0/24`

### Network Scan
If you're on the same network:
```bash
nmap -sn 10.10.204.0/24
```

Or from Home Assistant:
```bash
kubectl exec -it -n home-assistant deployment/home-assistant -- nmap -sn 10.10.204.0/24
```

## Once You Have Local Keys

1. **Install LocalTuya** in Home Assistant (via HACS)
   - HACS → Integrations → Search "LocalTuya"
   - Download → Restart HA

2. **Add LocalTuya Integration**
   - Settings → Devices & Services → Add Integration
   - Search "LocalTuya"

3. **Configure Landscape Lighting** (first priority)
   - Friendly Name: "Landscape Lighting"
   - Host: (IP address from router/scan)
   - Device ID: `ebdc1aa3cfd5438376ktom`
   - Local Key: (from web UI)
   - Protocol Version: 3.3
   - Add DPS entities:
     - DPS 1: Path Lights (switch)
     - DPS 2: Wall Lights (switch)

4. **Test**
   - Turn lights on/off
   - Should be instant (10-50ms vs 500-2000ms cloud)
   - No more state reversions!

5. **Add Other Devices**
   - Repeat for Counter Lights, Office Balls, etc.

6. **Remove Tuya Cloud** (once all working)
   - Settings → Devices & Services → Tuya → Delete

## Why This Happened

The Tuya Cloud API has caching layers:
- **Web UI**: Direct database query (real-time)
- **Public API**: Cached (15-30 minute delay)

Your devices ARE online (web UI is authoritative), but the API cache hasn't refreshed yet.

## Alternative: Wait for API Cache

If you don't want to manually extract keys, wait 30-60 minutes and run:
```bash
./docs/guides/localtuya/check-device-status.sh
```

The API cache will eventually catch up to the web UI.

But since you're looking at the web UI right now, it's faster to just click "Debug Device" and grab the keys!
