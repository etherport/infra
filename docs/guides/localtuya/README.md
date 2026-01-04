# LocalTuya Setup - Local Control for Tuya Devices

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

## Files

- **QUICKSTART.md** - Quick reference checklist
- **SETUP.md** - Detailed setup guide
- **get_tuya_devices.py** - Device discovery script

## Current Issue Being Solved

Your landscape lighting (Path Lights and Wall Lights) is reverting to default state when changed in Home Assistant. This is caused by:

1. Tuya cloud sync latency (500-2000ms)
2. Cloud polling returning old state before device updates
3. Race condition causing Home Assistant to revert changes

LocalTuya eliminates this by communicating directly with devices locally.
