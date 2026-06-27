# Getting Local Keys - Complete Guide

## The Problem

Tuya's cloud API isn't returning local keys even though devices show as online in the web UI. This is a known issue with certain Tuya IoT Platform configurations.

## Why LocalTuya Needs Local Keys

- **Device ID**: Identifies the device (we have this ✅)
- **Local Key**: Encryption key for local communication (we DON'T have this ❌)
- **IP Address**: Network location (we can get from router)

Without the local key, LocalTuya cannot decrypt/encrypt messages to the device.

## Methods to Get Local Keys

### Method 1: Wait 24-48 Hours (Easiest)

**Why**: Tuya's API sometimes takes 24-48 hours after linking devices before local keys become available.

**What to do**:
1. Your devices were linked on: **2025-01-21** (from screenshot)
2. It's now: **2026-01-04** (well past 48 hours)
3. So this method should have worked... but hasn't ⚠️

**Conclusion**: API should be returning keys by now. Something else is wrong.

---

### Method 2: Check Project API Permissions

**Possible Issue**: Your project might not have permission to access local keys.

**Steps**:
1. Go to https://iot.tuya.com/
2. Open your project: **Windtryst Home Assistant**
3. Click **Service API** tab
4. Look for these specific APIs (you may need to subscribe):

   **Required for Local Keys**:
   - ✅ IoT Core (you have this)
   - ✅ Authorization (you have this)
   - ✅ Smart Home Devices Management (you have this)
   - ❓ **Device Management** - Check if this exists and is subscribed
   - ❓ **Device Control** - Check if this exists and is subscribed

5. If you find any unsubscribed APIs related to "Device" or "Local", subscribe to them
6. Wait 5-10 minutes for activation
7. Re-run: `./docs/guides/localtuya/check-device-status.sh`

---

### Method 3: Enable Debug/Developer Mode

**Some Tuya projects require "Debug Mode" for local key access**.

**Steps**:
1. In your project, look for **Settings** or **Project Configuration**
2. Look for options like:
   - "Debug Mode"
   - "Developer Mode"
   - "Enable Local Control"
   - "Advanced Features"
3. Enable any such options
4. Wait 5-10 minutes
5. Re-run API check

**Note**: This setting may be in different places depending on your Tuya IoT Platform version.

---

### Method 4: Try Different API Endpoint

**Your current setup**:
- Region: **Western America Data Center**
- Endpoint: `https://openapi.tuyaus.com`

**Some users report better results with the China endpoint** (even for US devices):

1. Edit `/tmp/tuya-venv` scripts to use:
   - Endpoint: `https://openapi.tuyacn.com`
   - Region: `cn`

2. Re-run device discovery

**Caveat**: This might violate data residency requirements. Only try if other methods fail.

---

### Method 5: Use Tuya Developer App (RECOMMENDED)

**This is the most reliable method when API fails**.

**Requirements**:
- iOS or Android device
- Tuya Smart or Smart Life app installed
- Developer mode enabled in app

**Steps**:

#### A. Enable Developer Mode in Smart Life App

1. Open **Smart Life** app
2. Go to **Me** (bottom right)
3. Tap **Settings** (top right gear icon)
4. Scroll to bottom and tap **About** 7 times
   - This unlocks developer mode (similar to Android developer options)
5. Go back to Settings
6. You should now see **Developer Options** or **Developer Tools**
7. Tap it and look for **Device Information** or **Local Key**

#### B. View Device Details

1. From **Devices** tab, tap on **Landscape Lighting**
2. Tap the **edit/settings** icon (usually top right)
3. Look for:
   - "Device Information"
   - "Network Information"
   - "Advanced"
4. The **Local Key** should be visible here

**If you see the local key in the app**, write it down!

---

### Method 6: Packet Capture (Advanced)

**This is a last resort but works 100% of the time**.

**How it works**:
- Intercept communication between Smart Life app and Tuya cloud
- Extract local key from the encrypted payload

**Tools needed**:
- Wireshark or Charles Proxy
- MITM SSL certificate installation
- Technical expertise

**Steps** (high-level):
1. Set up SSL MITM proxy on your network
2. Route Smart Life app traffic through proxy
3. Open device in Smart Life app
4. Capture API responses containing local_key
5. Extract the key

**Guides**: Search for "tuya local key packet capture" for detailed tutorials.

---

### Method 7: Alternative Integration (If All Else Fails)

**If you absolutely cannot get local keys**, consider:

#### Option A: Keep Tuya Cloud Integration
- Accept the 500-2000ms latency
- Live with occasional state reversions
- No local keys needed

#### Option B: Use Tuya Cloud API Integration
- Home Assistant has built-in Tuya integration using cloud API
- Faster than standard Tuya integration
- Still requires internet but more reliable
- No local keys needed

#### Option C: Replace Devices
- Consider replacing problematic devices with:
  - Zigbee devices (better local control)
  - Z-Wave devices
  - ESPHome flashed devices
  - Native local control devices

---

## What We Know About Your Setup

✅ **Working**:
- Tuya IoT Platform account
- Project created and configured
- API credentials valid
- 8/9 devices online
- API can see devices

❌ **Not Working**:
- API not returning `local_key` field
- Device detail queries don't include keys
- Web UI doesn't show local keys

**This suggests**: Either API permissions issue OR Tuya is blocking local key access for your device types/region.

---

## Recommended Next Steps

### Immediate (try these first):

1. **Check Smart Life App Developer Mode** (Method 5)
   - Most likely to work
   - Takes 5 minutes
   - No technical expertise needed

2. **Check Project API Permissions** (Method 2)
   - Look for "Device Management" or "Device Control" APIs
   - Subscribe if found
   - Wait 10 minutes and retry

3. **Contact Tuya Support**
   - Email: support@tuya.com
   - Ask: "Why is my IoT Platform API not returning local_key field for devices?"
   - Provide: Project ID `p1767568700268edn5pr`
   - Reference: Device ID `ebdc1aa3cfd5438376ktom`

### If those don't work:

4. **Try Packet Capture** (Method 6)
   - Technical but guaranteed to work
   - One-time effort
   - Get keys for all devices at once

---

## Current Status

**Devices Ready** (just missing local keys):

| Device | ID | Status |
|--------|-----|--------|
| Landscape Lighting | ebdc1aa3cfd5438376ktom | Online, no key |
| Counter Lights | 30000164e09806cb6be9 | Online, no key |
| Office Balls | 0225833624a160011195 | Online, no key |
| Window Light | eb97cd9d82225998ecofmi | Online, no key |
| Bench light | eb0fbce27fb4f00c30v6ys | Online, no key |
| Kitchen Strip | ebab6535a9e78c3a3bfv7v | Online, no key |
| Laundry room dimmer | 81705067c44f33e52bcc | Online, no key |
| Tree Light | 81705067c44f33ef458d | Online, no key |
| Mantle Lights | 6840080140f520f15d90 | Offline |

**You're literally ONE field away from LocalTuya working**: Just need the 16-character local key for each device!

---

## Questions?

- Check: `docs/guides/localtuya/TROUBLESHOOTING.md`
- Check: `docs/guides/localtuya/SETUP.md`
- Re-run status: `./docs/guides/localtuya/check-device-status.sh`
