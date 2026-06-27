# LocalTuya Setup - Local Control for Tuya Devices

> ⚠️ **ARCHIVED (2026-01 setup saga, historical).** LocalTuya is now **live** — installed via the
> Home Assistant deployment init-container (`platform/kubernetes/home-automation/`). This dir is the
> original (incomplete-at-the-time) setup struggle; kept for reference only. **Any Tuya API
> credentials in these files were scrubbed to placeholders** — the originally-committed secret must
> be treated as compromised (in git history) and rotated at iot.tuya.com.

This guide helps you set up LocalTuya for direct local control of all your Tuya/Smart Life devices.

## Benefits

- **10-50ms latency** (vs 500-2000ms cloud)
- **Works offline** (no internet required)
- **Fixes state reversions** (no cloud polling conflicts)
- **Better privacy** (no data to Tuya cloud)

## Quick Start

See [QUICKSTART.md](./QUICKSTART.md) for a step-by-step checklist.

## Detailed Guide

See [SETUP.md](./SETUP.md) for comprehensive instructions.

## Device Discovery

Use `get_tuya_devices.py` to discover all your devices and get their local keys:

```bash
# 1. Install SDK
pip3 install tuya-iot-py-sdk

# 2. Edit script with your Tuya IoT credentials
nano get_tuya_devices.py

# 3. Run discovery
python3 get_tuya_devices.py > tuya_devices.txt
```

## Documentation Files

| Document | Description |
|----------|-------------|
| [QUICKSTART.md](QUICKSTART.md) | Quick reference checklist |
| [SETUP.md](SETUP.md) | Detailed setup guide |
| [TUYA-IOT-SETUP.md](TUYA-IOT-SETUP.md) | Tuya IoT Platform configuration |
| [GETTING-LOCAL-KEYS.md](GETTING-LOCAL-KEYS.md) | Methods to obtain local keys |
| [NETWORK-SCANNING.md](NETWORK-SCANNING.md) | Network scanning guide |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Troubleshooting common issues |
| [OFFICIAL-TUYA-INTEGRATION.md](OFFICIAL-TUYA-INTEGRATION.md) | Alternative official integration setup |

## Problem Being Solved

Landscape lighting (Path Lights and Wall Lights) reverting to default state when changed in Home Assistant.

**Root Cause:**
1. Tuya cloud sync latency (500-2000ms)
2. Cloud polling returning old state before device updates
3. Race condition causing Home Assistant to revert changes

**Solution:** LocalTuya eliminates this by communicating directly with devices locally.
