# Tuya Local Key Retrieval - Status & Next Steps

**Status**: All 9 devices discovered but showing as **OFFLINE** ❌
**Impact**: Tuya API won't return local keys for offline devices

## Device Discovery Results

✅ Successfully connected to Tuya IoT Platform
✅ Found all 9 devices including **Landscape Lighting** (the problematic device)
❌ All devices showing as `Online: False`
❌ No local keys returned from API

### Discovered Devices

1. **Kitchen Strip** (ebab6535a9e78c3a3bfv7v) - LED Strip
2. **Window Light** (eb97cd9d82225998ecofmi) - LED Strip
3. **Landscape Lighting** (ebdc1aa3cfd5438376ktom) - **TARGET DEVICE** - 3-Zone Transformer
4. **Bench light** (eb0fbce27fb4f00c30v6ys) - LED Strip
5. **Counter Lights** (30000164e09806cb6be9) - Smart Plug
6. **Office Balls** (0225833624a160011195) - Smart Plug
7. **Tree Light** (81705067c44f33ef458d) - Dimmer Switch
8. **Laundry room dimmer** (81705067c44f33e52bcc) - Dimmer Switch
9. **Mantle Lights** (6840080140f520f15d90) - Smart Plug

## Why Local Keys Are Missing

The Tuya Cloud API requires devices to be **online** to return local keys because:
1. Local keys are generated when devices first connect
2. Keys are cached on the device and synced to cloud when online
3. Offline devices don't have their keys in the cloud API cache

## Next Steps - 3 Approaches

### Approach 1: Get Devices Online (Recommended)

**Steps:**
1. Open Smart Life app on your phone
2. Check device status - tap each device to see if it responds
3. For offline devices:
   - Check power supply (especially landscape lighting transformer)
   - Verify WiFi connectivity
   - May need to power cycle devices
4. Wait 2-3 minutes for devices to sync to cloud
5. Re-run discovery script:
   ```bash
   source /tmp/tuya-venv/bin/activate
   python3 -c "
   import tinytuya
   cloud = tinytuya.Cloud(apiRegion='us', apiKey='<TUYA_ACCESS_ID>', apiSecret='<TUYA_ACCESS_SECRET>')
   devices = cloud.getdevices()
   for d in devices:
       if d.get('online'):
           print(f\"{d['name']}: {d.get('local_key', 'N/A')}\")
   "
   ```

### Approach 2: Tuya IoT Platform Web Interface

**Steps:**
1. Go to https://iot.tuya.com/
2. Select your project: **p1767568700268edn5pr**
3. Click **Cloud** → **Development** → **Devices** tab
4. For each online device:
   - Click on the device name
   - Look for **Device Information** section
   - Local Key should be displayed (if device is online)
5. Manually copy Device ID and Local Key for each device

### Approach 3: Network Scan (If on same network as devices)

If you're on the same local network as your Tuya devices:

```bash
# This requires devices to be powered on and on WiFi
source /tmp/tuya-venv/bin/activate
python3 <<'EOF'
import tinytuya
import json

# Scan local network for Tuya devices
print("Scanning network for Tuya devices...")
devices = tinytuya.deviceScan()

print(f"\nFound {len(devices)} devices on local network:")
for ip, data in devices.items():
    print(f"  IP: {ip}")
    print(f"  ID: {data.get('gwId', 'Unknown')}")
    print(f"  Version: {data.get('version', 'Unknown')}")
    print()
EOF
```

**Note**: This won't give you local keys directly, but confirms which devices are reachable on your network.

## Checking Device Status

### In Smart Life App
1. Open Smart Life app
2. Check if devices show as "Online" or "Offline"
3. Try controlling a device (turn on/off)
4. If offline, check:
   - Device power
   - WiFi connection strength
   - Router logs

### Common Offline Causes
- **Landscape Lighting**: May have timer/schedule that keeps it powered off
- **LED Strips**: Check power adapters
- **Smart Plugs**: May have hardware switch turned off
- **Dimmers**: Check circuit breaker

## Alternative: Skip Offline Devices Initially

You can set up LocalTuya for **only the online devices** first:
1. Get devices online one by one
2. Run discovery script after each device comes online
3. Set up LocalTuya incrementally
4. Come back to offline devices later

## Landscape Lighting Specific Notes

Your **Landscape Lighting** device (ebdc1aa3cfd5438376ktom) is a **3-Zone Transformer**:
- Product: "Low Voltage Transformer with 3 Zones"
- Category: kg (switch)
- This is likely the device causing state reversion issues

**Immediate Check:**
1. Is the transformer powered on? (check physical device)
2. Does it have a timer/schedule in Smart Life app?
3. Can you control it manually in the app?

If it's on a schedule, it may be powering off at certain times, causing it to appear offline.

## When You Get Local Keys

Once devices are online and you have local keys, the LocalTuya setup is straightforward:

1. Install LocalTuya in Home Assistant (via HACS)
2. Add each device with:
   - Device ID (from discovery results)
   - Local Key (from API once online)
   - IP address (from router DHCP or network scan)
   - Protocol: 3.3
3. Test local control
4. Remove Tuya cloud integration

This will fix the state reversion issue permanently by bypassing the cloud.

## Need Help?

Let me know:
- Current status of devices in Smart Life app (online/offline count)
- Any specific devices that won't come online
- If you need help with the IoT Platform web interface approach
