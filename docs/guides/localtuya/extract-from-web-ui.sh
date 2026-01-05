#!/bin/bash
# Extract Local Keys from Tuya Web UI
# This script helps you manually collect local keys from the Tuya IoT Platform web interface
#
# Usage:
#   1. Open https://iot.tuya.com/ in your browser
#   2. Go to your project → Devices tab
#   3. Click on each device to see its details
#   4. Run this script and paste the local key when prompted

set -euo pipefail

OUTPUT_FILE="/Users/grahamsmith/Projects/homelab-infra/docs/guides/localtuya/devices-ready.json"

echo "=" * 80
echo "TUYA LOCAL KEY COLLECTION FROM WEB UI"
echo "=" * 80
echo ""
echo "The API is cached, but you can get local keys from the web UI:"
echo "  1. Open: https://iot.tuya.com/"
echo "  2. Go to: Cloud → Development → Your Project → Devices"
echo "  3. Click on each device name to see details"
echo "  4. Look for 'Local Key' field and copy it"
echo ""
echo "We'll collect local keys for your 8 online devices."
echo ""

# Known devices from discovery (excluding offline Mantle Lights)
declare -A DEVICES=(
    ["Counter Lights"]="30000164e09806cb6be9"
    ["Office Balls"]="0225833624a160011195"
    ["Landscape Lighting"]="ebdc1aa3cfd5438376ktom"
    ["Window Light"]="eb97cd9d82225998ecofmi"
    ["Bench light"]="eb0fbce27fb4f00c30v6ys"
    ["Kitchen Strip"]="ebab6535a9e78c3a3bfv7v"
    ["Laundry room dimmer"]="81705067c44f33e52bcc"
    ["Tree Light"]="81705067c44f33ef458d"
)

# Priority order - Landscape Lighting first
PRIORITY_ORDER=(
    "Landscape Lighting"
    "Counter Lights"
    "Office Balls"
    "Window Light"
    "Bench light"
    "Kitchen Strip"
    "Laundry room dimmer"
    "Tree Light"
)

JSON_OUTPUT="["

for DEVICE_NAME in "${PRIORITY_ORDER[@]}"; do
    DEVICE_ID="${DEVICES[$DEVICE_NAME]}"

    echo "─────────────────────────────────────────────────────────────────────────────"
    echo "Device: $DEVICE_NAME"
    echo "ID:     $DEVICE_ID"
    echo "─────────────────────────────────────────────────────────────────────────────"
    echo ""

    read -p "Enter Local Key (or 'skip' to skip, 'done' when finished): " LOCAL_KEY

    if [ "$LOCAL_KEY" = "done" ]; then
        break
    fi

    if [ "$LOCAL_KEY" = "skip" ]; then
        echo "Skipped."
        echo ""
        continue
    fi

    # Validate local key format (should be 16 characters)
    if [ ${#LOCAL_KEY} -ne 16 ]; then
        echo "⚠️  Warning: Local key should be 16 characters. Got ${#LOCAL_KEY}."
        read -p "Continue anyway? (y/n): " CONFIRM
        if [ "$CONFIRM" != "y" ]; then
            continue
        fi
    fi

    read -p "Enter IP Address (or press Enter to skip): " IP_ADDRESS

    if [ -z "$IP_ADDRESS" ]; then
        IP_ADDRESS="Unknown - check router DHCP"
    fi

    # Add to JSON (with comma separator)
    if [ "$JSON_OUTPUT" != "[" ]; then
        JSON_OUTPUT+=","
    fi

    JSON_OUTPUT+="
  {
    \"name\": \"$DEVICE_NAME\",
    \"id\": \"$DEVICE_ID\",
    \"local_key\": \"$LOCAL_KEY\",
    \"ip\": \"$IP_ADDRESS\",
    \"online\": true
  }"

    echo "✅ Added $DEVICE_NAME"
    echo ""
done

JSON_OUTPUT+="
]"

# Save to file
echo "$JSON_OUTPUT" > "$OUTPUT_FILE"

echo ""
echo "=" * 80
echo "✅ SAVED DEVICE CONFIGURATION"
echo "=" * 80
echo ""
echo "File: $OUTPUT_FILE"
echo ""
cat "$OUTPUT_FILE"
echo ""
echo "=" * 80
echo "NEXT STEPS"
echo "=" * 80
echo ""
echo "1. Install LocalTuya in Home Assistant (via HACS)"
echo "2. Add integration: Settings → Devices & Services → Add LocalTuya"
echo "3. Configure each device using the information above"
echo "4. Test local control"
echo "5. Remove Tuya cloud integration"
echo ""
echo "See: docs/guides/localtuya/SETUP.md for detailed instructions"
echo "=" * 80
