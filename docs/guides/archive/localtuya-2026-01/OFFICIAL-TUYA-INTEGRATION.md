# Official Tuya Integration Setup

**Goal**: Fix landscape lighting state reversion using Tuya's official Cloud API integration

**Advantage over current setup**: Better cloud sync, faster response, proper state management

## Prerequisites

✅ You already have:
- Tuya IoT Platform account
- Project created with API services authorized
- Credentials stored in 1Password
- Devices linked in Smart Life app

## Setup Steps

### 1. Remove Old Tuya Integration (if exists)

**Check if you have old Tuya integration**:
1. Open Home Assistant
2. Go to **Settings** → **Devices & Services**
3. Look for "Tuya" integration
4. If found:
   - Click the **three dots** (⋮)
   - Click **Delete**
   - Confirm deletion

⚠️ **IMPORTANT**: Note your automation entity IDs first! The new integration should use the same IDs, but verify after setup.

### 2. Add Official Tuya Integration

1. In Home Assistant: **Settings** → **Devices & Services**
2. Click **+ Add Integration** (bottom right)
3. Search for **"Tuya"**
4. Select **"Tuya"** (should show Tuya Smart logo)

### 3. Configure with IoT Platform Credentials

When prompted, enter:

**Account Type**: Choose **"Smart Home PaaS"**

**Configuration**:
- **Access ID**: `<TUYA_ACCESS_ID>`
- **Access Secret**: `<TUYA_ACCESS_SECRET>`
- **Country/Region**: **United States**
- **Data Center**: **Western America** (or Americas/US)

(Credentials are in 1Password → "Tuya API")

### 4. Device Discovery

After submitting:
- Integration will connect to Tuya Cloud
- Should auto-discover all 9 devices from Smart Life app
- Devices will appear in Home Assistant

**Expected devices**:
1. ✅ Landscape Lighting (3-zone transformer)
2. ✅ Kitchen Strip (LED)
3. ✅ Window Light (LED)
4. ✅ Bench light (LED)
5. ✅ Counter Lights (Smart Plug)
6. ✅ Office Balls (Smart Plug)
7. ✅ Tree Light (Dimmer)
8. ✅ Laundry room dimmer
9. ⚠️ Mantle Lights (might not appear if offline)

### 5. Verify Landscape Lighting

1. Go to **Settings** → **Devices & Services** → **Tuya**
2. Click on **Landscape Lighting** device
3. You should see:
   - **Switch 1**: Path Lights (DPS 1)
   - **Switch 2**: Wall Lights (DPS 2)
   - **Switch 3**: (DPS 3 - if exists)

### 6. Test State Persistence

**The moment of truth**:
1. Turn on **Path Lights** via Home Assistant
2. Wait 30 seconds
3. Check if it stays on (no reversion!)
4. Turn off via Home Assistant
5. Turn on via Smart Life app
6. Check Home Assistant - should update immediately

**Expected improvement**:
- ✅ State changes persist
- ✅ No more reversions to default
- ✅ Faster cloud sync (100-300ms vs 500-2000ms)
- ✅ Bidirectional updates (app ↔ HA)

## Troubleshooting

### "Failed to connect" or "Invalid credentials"

**Check**:
1. Access ID and Secret are correct (copy/paste from 1Password)
2. Selected correct region (Western America)
3. API services still authorized in IoT Platform

**Fix**:
- Go to https://iot.tuya.com/
- Check **Service API** tab
- Verify all services show as "Authorized"

### Devices not discovered

**Possible causes**:
1. Devices offline
2. Smart Life app not linked to project
3. Wrong data center selected

**Fix**:
1. Open Smart Life app - verify devices show as online
2. In IoT Platform: **Devices** tab - verify devices listed
3. Try removing and re-adding integration with different data center

### Wrong entity IDs

If entity IDs changed from old integration:

**Before** (old Tuya):
```
switch.landscape_lighting_path_lights
switch.landscape_lighting_wall_lights
```

**After** (official Tuya):
```
switch.landscape_lighting_switch_1
switch.landscape_lighting_switch_2
```

**Fix**:
1. Update automations to use new entity IDs
2. Or rename entities in Home Assistant to match old IDs

## Performance Comparison

### Current Setup (Old Tuya Integration)
- Latency: 500-2000ms
- State reversion: **YES** (the problem!)
- Works offline: No
- Reliability: Poor

### Official Tuya Integration
- Latency: 100-300ms
- State reversion: **NO** ✅
- Works offline: No
- Reliability: Good

### LocalTuya (Future - if we get keys)
- Latency: 10-50ms
- State reversion: **NO** ✅
- Works offline: **YES**
- Reliability: Excellent

## After Setup

### Update Automations

Check your automations that control landscape lighting:
1. Go to **Settings** → **Automations & Scenes**
2. Search for automations using landscape lighting
3. Verify entity IDs are correct
4. Test each automation

### Monitor for Issues

Watch for:
- ✅ State changes persist (main goal!)
- ✅ Automations work correctly
- ✅ Manual control via app syncs to HA
- ✅ No random state reversions

### Remove Old Integration

Once verified working:
1. **Settings** → **Devices & Services**
2. Find old Tuya integration (if still present)
3. Delete it
4. Restart Home Assistant

## Success Criteria

**You'll know it works when**:
1. ✅ Turn on landscape lights via HA → stays on
2. ✅ Automation runs → lights stay in commanded state
3. ✅ No random reversions to "off" or default
4. ✅ Smart Life app changes sync to HA instantly
5. ✅ Can control all 3 zones independently

## If It Works

**Celebrate!** 🎉 Your landscape lighting issue is fixed!

You can:
- Keep using official Tuya integration (it works!)
- Continue using LocalTuya for other devices if you get keys later
- Gradually migrate other devices to official integration

## If It Doesn't Work

**Fallback options**:
1. Contact Tuya support for local keys
2. Try packet capture method (advanced)
3. Replace devices with Zigbee/Z-Wave alternatives
4. Live with current setup until local keys available

## Files for Reference

- IoT Platform: https://iot.tuya.com/
- Project ID: p1767568700268edn5pr
- Credentials: 1Password → "Tuya API"
- Device IDs: `docs/guides/localtuya/devices-with-ips.json`

## Next Steps After Successful Setup

1. Monitor for 24-48 hours
2. Verify automations run correctly
3. Check for any state reversion issues
4. If all good → problem solved!
5. If issues persist → contact Tuya support for local keys

---

**Ready to start?**

Go to Home Assistant → Settings → Devices & Services → Add Integration → Tuya

Good luck! Let me know how it goes.
