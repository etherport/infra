# LocalTuya Quick Start Guide

## What You'll Get
- **Zero latency** - Direct local control (10-50ms vs 500-2000ms)
- **Works offline** - No internet dependency
- **Fixes state revert issues** - No more cloud sync conflicts
- **Better privacy** - No data to Tuya cloud

## Prerequisites
- [x] Tuya/Smart Life app installed and working
- [x] All devices working in the app
- [x] Python 3 installed on your Mac

## Current Status

✅ **COMPLETED:**
- [x] Tuya IoT Platform account created
- [x] Cloud project created (p1767568700268edn5pr)
- [x] API credentials stored in 1Password
- [x] Smart Life app linked to project
- [x] Device discovery completed - **9 devices found**

⚠️ **IN PROGRESS:**
- [ ] Devices currently showing as OFFLINE in Tuya cloud
- [ ] Local keys not available until devices are online
- [ ] Need to verify device power and WiFi status

**Next Step**: Check device status in Smart Life app and get devices online

## Step 1: Get Tuya Developer Credentials (COMPLETED ✅)

1. **Create Tuya IoT Account**
   - Visit: https://iot.tuya.com/
   - Sign up with the **same email** as your Smart Life app
   - Verify your email

2. **Create Cloud Project**
   - After login, go to: Cloud → Development
   - Click "Create Cloud Project"
   - Name: "Home Assistant Local Control"
   - Industry: Smart Home
   - Data Center: **United States** (important!)
   - Click "Create"

3. **Get API Credentials**
   - Click on your new project
   - You'll see:
     - **Access ID** (looks like: xxxxxxxxx)
     - **Access Secret** (looks like: yyyyyyyy)
   - Copy both somewhere safe

4. **Link Your Devices**
   - In your project, go to: Devices → Link Tuya App Account
   - Click "Add App Account"
   - A QR code will appear
   - Open Smart Life app → Me → Scan QR code
   - Scan the QR code from the website
   - Your devices should now appear in the Tuya IoT dashboard

## Step 2: Run Device Discovery Script (COMPLETED ✅)

**Result**: Found 9 devices but all showing as OFFLINE ⚠️

### Discovered Devices:
1. Kitchen Strip (ebab6535a9e78c3a3bfv7v) - LED Strip
2. Window Light (eb97cd9d82225998ecofmi) - LED Strip
3. **Landscape Lighting** (ebdc1aa3cfd5438376ktom) - 3-Zone Transformer ⭐
4. Bench light (eb0fbce27fb4f00c30v6ys) - LED Strip
5. Counter Lights (30000164e09806cb6be9) - Smart Plug
6. Office Balls (0225833624a160011195) - Smart Plug
7. Tree Light (81705067c44f33ef458d) - Dimmer Switch
8. Laundry room dimmer (81705067c44f33e52bcc) - Dimmer Switch
9. Mantle Lights (6840080140f520f15d90) - Smart Plug

### Check Current Status

Run this anytime to see which devices are online and ready:
```bash
cd /Users/grahamsmith/Projects/homelab-infra
./docs/guides/localtuya/check-device-status.sh
```

This will show:
- Online vs Offline count
- Local keys for any online devices
- IP addresses
- Which devices are ready for LocalTuya setup

### Troubleshooting Offline Devices

**Why all devices show offline:**
- Devices may be powered off (check especially Landscape Lighting transformer)
- WiFi connectivity issues
- Need to open Smart Life app to trigger sync

**To fix:**
1. Open Smart Life app on your phone
2. Check each device - tap to see if it responds
3. For offline devices, verify power and WiFi
4. Power cycle if needed
5. Wait 2-3 minutes for cloud sync
6. Re-run `check-device-status.sh`

See: `docs/guides/localtuya/TROUBLESHOOTING.md` for detailed help

## Step 3: Install LocalTuya in Home Assistant

1. **Install via HACS**
   - Home Assistant → HACS → Integrations
   - Click "+ Explore & Download Repositories"
   - Search for "LocalTuya"
   - Click "Download"
   - Restart Home Assistant

2. **Add LocalTuya Integration**
   - Settings → Devices & Services → Add Integration
   - Search "LocalTuya"
   - Click to add

## Step 4: Configure Your Landscape Lighting

Based on your entity registry, you have:
- **Device ID**: `ebdc1aa3cfd5438376ktom`
- **Switches**:
  - DPS 1: Path Lights
  - DPS 2: Wall Lights

In LocalTuya setup:
1. Enter Friendly Name: "Landscape Lighting"
2. Host: (from discovery script or router DHCP)
3. Device ID: `ebdc1aa3cfd5438376ktom`
4. Local Key: (from discovery script)
5. Protocol Version: 3.3 (try 3.1 if issues)
6. Configure entities:
   - Switch 1 (DPS 1) → Path Lights
   - Switch 2 (DPS 2) → Wall Lights

## Step 5: Test & Remove Cloud Integration

1. **Test Local Control**
   - Try turning lights on/off in Home Assistant
   - Should be instant (10-50ms)
   - No more state reversions!

2. **Remove Cloud Tuya** (once everything works)
   - Settings → Devices & Services
   - Find "Tuya" integration
   - Click "..." → Delete
   - Your automations will continue to work with same entity IDs!

## Troubleshooting

### Can't Get Local Key?
- Wait 24 hours after linking app to Tuya IoT
- Make sure devices are linked (check Devices tab in Tuya IoT)
- Try re-running the discovery script

### Device Won't Connect?
- Try protocol versions: 3.3, 3.1, 3.2
- Check IP address (scan router DHCP leases)
- Ensure Home Assistant can reach IoT VLAN (10.10.204.0/24)
- Verify port 6668 is accessible

### IP Address Shows "Unknown"?
- Check your router's DHCP leases for device MAC
- Or run from Home Assistant node:
  ```bash
  nmap -sn 10.10.204.0/24 | grep -B 2 "Tuya"
  ```

## Expected Results

**Before (Cloud Tuya):**
- Command latency: 500-2000ms
- Internet required
- State sync delays cause reversions
- Cloud polling conflicts

**After (LocalTuya):**
- Command latency: 10-50ms
- Works offline
- Instant state updates
- No sync conflicts
- **Landscape lighting state reversions FIXED!**

## Files You Need
- `/tmp/get_tuya_devices.py` - Device discovery script (edit credentials first)
- `/tmp/localtuya-setup-guide.md` - Detailed setup guide
- This file - Quick reference

---

**Ready to Start?**
1. Go to https://iot.tuya.com/ and create account
2. Get your Access ID and Access Secret
3. Run the discovery script
4. Install LocalTuya via HACS
5. Configure devices

Once you run the discovery script, you'll have everything needed to eliminate those landscape lighting state issues!
