# Network Scanning Guide

## Step 1: Connect to IoT Network

Switch your Mac's WiFi to the IoT network (if wireless) or connect via Ethernet to a switch on the IoT VLAN.

**Verify connection**:
```bash
ipconfig getifaddr en0  # WiFi
ipconfig getifaddr en1  # Ethernet
```

Expected: `10.10.204.x`

## Step 2: Run tinytuya Scanner

```bash
cd /Users/grahamsmith/Projects/homelab-infra
./docs/guides/localtuya/scan-iot-network.sh
```

This will:
- Scan for Tuya devices on 10.10.204.0/24
- Map IPs to device names
- Save results to `devices-with-ips.json`

**What you'll get**:
- ✅ IP addresses for each device
- ✅ Device IDs (confirmation)
- ✅ Protocol versions
- ❌ NOT local keys (need different method)

## Step 3: Use lanscan (Alternative/Supplement)

If tinytuya doesn't find all devices, use lanscan:

```bash
lanscan -s -f 10.10.204.0/24
```

**Look for**:
- Manufacturer: "Tuya", "Espressif", "Hangzhou BroadLink"
- Open ports: 6668 (Tuya protocol)
- Hostnames containing device names

**Export results**:
```bash
lanscan -s -f 10.10.204.0/24 > /tmp/lanscan-results.txt
```

## Step 4: Match IPs to Device Names

### Known Devices (from API):

| Device Name | Device ID | Expected on Network |
|-------------|-----------|---------------------|
| Landscape Lighting | ebdc1aa3cfd5438376ktom | Yes (Online) |
| Counter Lights | 30000164e09806cb6be9 | Yes (Online) |
| Office Balls | 0225833624a160011195 | Yes (Online) |
| Window Light | eb97cd9d82225998ecofmi | Yes (Online) |
| Bench light | eb0fbce27fb4f00c30v6ys | Yes (Online) |
| Kitchen Strip | ebab6535a9e78c3a3bfv7v | Yes (Online) |
| Laundry room dimmer | 81705067c44f33e52bcc | Yes (Online) |
| Tree Light | 81705067c44f33ef458d | Yes (Online) |
| Mantle Lights | 6840080140f520f15d90 | No (Offline) |

### Manual Matching (if needed):

If devices don't show IDs, identify by:
1. **Testing**: Unplug/replug devices one at a time, see which IP disappears
2. **Ports**: Tuya devices typically have port 6668 open
3. **MAC vendor**: Check MAC address OUI (first 6 hex digits)

## Step 5: Static DHCP Reservations (Recommended)

**When to do this**: AFTER LocalTuya is working

**Why**:
- IP changes break LocalTuya configuration
- Must reconfigure if device gets new IP
- Static IPs = set and forget

### How to Set Up (Example for your network):

**On your router/DHCP server**:

1. Find DHCP settings
2. Add reservation for each device:

```
Device: Landscape Lighting
MAC: (from lanscan)
IP: 10.10.204.20  (or any unused IP)

Device: Counter Lights
MAC: (from lanscan)
IP: 10.10.204.21

... etc
```

**Recommended IP scheme**:
```
10.10.204.20-29: Tuya Lights
10.10.204.30-39: Tuya Switches
10.10.204.40-49: Tuya Dimmers
```

**After setting reservations**:
1. Reboot each device (or wait for DHCP lease renewal)
2. Verify new IPs: `lanscan -s -f 10.10.204.0/24`
3. Update LocalTuya configuration with static IPs

## Expected Scan Results

### If tinytuya finds devices:
```
IP Address: 10.10.204.x
  Device ID: ebdc1aa3cfd5438376ktom
  Version:   3.3

Landscape Lighting
  IP:        10.10.204.x
  Device ID: ebdc1aa3cfd5438376ktom
```

### If tinytuya finds nothing:

**Possible reasons**:
1. Firewall blocking UDP broadcasts
2. Devices in deep sleep mode
3. Network segmentation issues

**Solutions**:
- Use lanscan instead
- Check router firewall rules
- Try nmap: `nmap -sn 10.10.204.0/24`
- Check if devices respond to ping

## Troubleshooting

### "No devices found"

Try:
```bash
# Ping sweep
for i in {1..254}; do ping -c 1 -t 1 10.10.204.$i & done

# Port scan specific device (if you know IP)
nmap -p 6668 10.10.204.x

# ARP scan
arp -a | grep 10.10.204
```

### "Wrong network" warning

Make sure you're actually on 10.10.204.0/24:
```bash
ifconfig | grep "inet 10.10.204"
```

If not, check:
- WiFi SSID (are you on IoT network?)
- Ethernet connection (right VLAN?)
- VPN (disconnect if active)

### Devices found but can't identify

Use process of elimination:
1. Note all IPs found: `10.10.204.15, .16, .17, etc`
2. Unplug Landscape Lighting
3. Re-scan: which IP disappeared?
4. That's Landscape Lighting's IP!
5. Repeat for each device

## What This Gets You

✅ **IP Addresses**: Needed for LocalTuya configuration
✅ **Device IDs**: Confirmation of which devices are reachable
✅ **Network confirmation**: Proves devices are accessible

❌ **Still Missing**: Local Keys (see `GETTING-LOCAL-KEYS.md`)

## Next Steps After Scan

1. **If you have IPs**: Great! Save them.
2. **Get local keys**: Try Smart Life app developer mode
3. **Set up LocalTuya**: Use IPs + Device IDs + Local Keys
4. **Test**: Verify local control works
5. **Then set static IPs**: Lock in the working configuration

## Commands Reference

```bash
# Run scanner
./docs/guides/localtuya/scan-iot-network.sh

# lanscan (if installed)
lanscan -s -f 10.10.204.0/24

# nmap
nmap -sn 10.10.204.0/24

# Check your IP
ipconfig getifaddr en0

# Ping specific device
ping 10.10.204.x

# Check if Tuya port open
nc -zv 10.10.204.x 6668
```

## Files Generated

- `docs/guides/localtuya/network-scan-results.json` - Raw scan results
- `docs/guides/localtuya/devices-with-ips.json` - Matched devices with IPs

These files will be used by LocalTuya setup once you have local keys!
