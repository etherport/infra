# LocalTuya Quick Start Guide

## What You'll Get
- **Zero latency** - Direct local control (10-50ms vs 500-2000ms)
- **Works offline** - No internet dependency
- **Fixes state revert issues** - No more cloud sync conflicts
- **Better privacy** - No data to Tuya cloud

## Prerequisites
- [ ] Tuya/Smart Life app installed and working
- [ ] All devices working in the app
- [ ] Python 3 installed on your Mac

## Step 1: Get Tuya Developer Credentials (10 minutes)

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

## Step 2: Run Device Discovery Script

1. **Install Required Library**
   ```bash
   pip3 install tuya-iot-py-sdk
   ```

2. **Edit the Discovery Script**
   ```bash
   nano /tmp/get_tuya_devices.py
   ```
   
   Replace these two lines with your credentials from Step 1:
   ```python
   ACCESS_ID = "your_access_id_here"      # Replace with your Access ID
   ACCESS_SECRET = "your_access_secret_here"  # Replace with your Access Secret
   ```
   
   Save and exit (Ctrl+X, Y, Enter)

3. **Run the Script**
   ```bash
   python3 /tmp/get_tuya_devices.py > /tmp/tuya_devices.txt
   cat /tmp/tuya_devices.txt
   ```

4. **Share Results**
   The output will show all your devices with:
   - Device Name
   - Device ID (needed for LocalTuya)
   - Local Key (needed for LocalTuya)
   - IP Address (if available)
   - Functions/capabilities

   **IMPORTANT**: The local keys are sensitive. When sharing results, you can redact them if needed.

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
