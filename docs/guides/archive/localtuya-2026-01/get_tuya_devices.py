#!/usr/bin/env python3
"""
Tuya Device Discovery Script
Gets all devices with their local keys for LocalTuya setup
"""
import json
import sys

try:
    from tuya_iot import TuyaOpenAPI, AuthType
except ImportError:
    print("ERROR: tuya-iot-py-sdk not installed")
    print("Run: pip3 install tuya-iot-py-sdk")
    sys.exit(1)

# TODO: Replace with your credentials from https://iot.tuya.com
ACCESS_ID = "YOUR_ACCESS_ID_HERE"
ACCESS_SECRET = "YOUR_ACCESS_SECRET_HERE"

# Select your data center endpoint
# US: https://openapi.tuyaus.com
# EU: https://openapi.tuyaeu.com
# CN: https://openapi.tuyacn.com
API_ENDPOINT = "https://openapi.tuyaus.com"

def main():
    if ACCESS_ID == "YOUR_ACCESS_ID_HERE":
        print("=" * 80)
        print("SETUP REQUIRED")
        print("=" * 80)
        print()
        print("1. Go to https://iot.tuya.com/")
        print("2. Create account with same email as Smart Life app")
        print("3. Create a Cloud Project")
        print("4. Get credentials:")
        print("   - Click Cloud → Development → Your Project")
        print("   - Copy 'Access ID' and 'Access Secret'")
        print()
        print("5. Link your devices:")
        print("   - Cloud → Link Devices → Link to App Account")
        print("   - Scan QR code with Smart Life app")
        print()
        print("6. Edit this script and replace:")
        print(f"   ACCESS_ID = \"{ACCESS_ID}\"")
        print(f"   ACCESS_SECRET = \"{ACCESS_SECRET}\"")
        print()
        print("7. Run again: python3 /tmp/get_tuya_devices.py")
        print("=" * 80)
        return

    print("=" * 80)
    print("TUYA DEVICE DISCOVERY")
    print("=" * 80)
    print(f"API Endpoint: {API_ENDPOINT}")
    print()

    # Initialize API
    print("Connecting to Tuya Cloud...")
    openapi = TuyaOpenAPI(API_ENDPOINT, ACCESS_ID, ACCESS_SECRET)
    openapi.connect()

    # Get all devices
    print("Fetching devices...")
    response = openapi.get("/v1.0/iot-03/devices", dict())

    if not response.get('success'):
        print(f"ERROR: {response}")
        return

    devices = response['result']
    print(f"Found {len(devices)} devices\n")
    print("=" * 80)

    for idx, device in enumerate(devices, 1):
        print(f"\n[{idx}] {device['name']}")
        print("-" * 80)
        print(f"Device ID:     {device['id']}")
        print(f"Local Key:     {device.get('local_key', 'NOT AVAILABLE')}")
        print(f"IP Address:    {device.get('ip', 'Unknown - check router')}")
        print(f"Product ID:    {device['product_id']}")
        print(f"Category:      {device['category']}")
        print(f"Online:        {device.get('online', 'Unknown')}")
        print(f"Protocol:      {device.get('protocol', '3.3')}")

        # Get device specifications
        spec_response = openapi.get(f"/v1.0/devices/{device['id']}/specifications")
        if spec_response.get('success'):
            specs = spec_response['result']
            if 'functions' in specs:
                print(f"\nFunctions:")
                for func in specs['functions']:
                    print(f"  - {func['code']}: {func.get('desc', 'No description')}")

        # Get device status
        status_response = openapi.get(f"/v1.0/devices/{device['id']}/status")
        if status_response.get('success'):
            status = status_response['result']
            if status:
                print(f"\nCurrent Status:")
                for s in status:
                    print(f"  - {s['code']}: {s['value']}")

    print("\n" + "=" * 80)
    print("SUMMARY FOR LOCALTUYA SETUP")
    print("=" * 80)
    print("\nFor each device, you'll need:")
    print("  1. Host (IP Address) - If 'Unknown', check your router's DHCP leases")
    print("  2. Device ID - Use the 'Device ID' above")
    print("  3. Local Key - Use the 'Local Key' above")
    print("  4. Protocol Version - Usually 3.3 (shown above)")
    print("\nIMPORTANT: Keep local keys secure - anyone with these can control your devices!")
    print("=" * 80)

if __name__ == '__main__':
    main()
