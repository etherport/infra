# Tuya IoT Platform Setup Checklist

The API is returning "token invalid" which typically means the project needs additional configuration.

## Required Steps in Tuya IoT Platform

Visit: https://iot.tuya.com/

### 1. Authorize API Services (CRITICAL)

Your project needs API permissions:

1. Go to: **Cloud** → **Development** → **Your Project** (p1767568700268edn5pr)
2. Click **Service API** tab
3. Subscribe to these APIs (all FREE):
   - **IoT Core** - Required for device access
   - **Authorization** - Required for API calls
   - **Smart Home Devices Management** - For device control
4. Click **Subscribe** for each one
5. Wait 2-3 minutes for activation

### 2. Link Smart Life App Account (REQUIRED)

Your devices must be linked to the project:

1. In your project, go to: **Devices** → **Link Tuya App Account**
2. Click **Add App Account**
3. Select **Smart Life** app
4. A QR code will appear
5. Open Smart Life app → **Me** → **Scan QR code**
6. Scan the QR code from the Tuya IoT website
7. Approve the authorization
8. Your devices should appear in the **Devices** tab

### 3. Verify Setup

After completing above:
1. Go to **Devices** tab in your project
2. You should see all your Smart Life devices listed
3. Each device will show its Device ID and Local Key

### 4. Re-run Discovery Script

Once devices are linked and APIs authorized, run:
```bash
python3 docs/guides/localtuya/get_tuya_devices.py
```

## Current Project Details

From 1Password:
- **Access ID (username)**: <TUYA_ACCESS_ID>
- **Access Secret (credential)**: <TUYA_ACCESS_SECRET>
- **Project Code**: p1767568700268edn5pr
- **Data Center**: Western America Data Center
- **API Endpoint**: https://openapi.tuyaus.com
- **Created**: 2026-01-04 15:18:20 (Today!)

## Common Issues

**"token invalid"** → API services not subscribed OR app account not linked
**"device list empty"** → App account not linked
**"permission denied"** → API services not authorized

## After Setup

You'll get:
- Device IDs for all your Tuya devices
- Local keys for LocalTuya integration
- IP addresses (if devices are online)
- Device capabilities and current status

This will fix your landscape lighting state reversion issue by enabling direct local control!
