# Firewall Zones and Policy

This document describes the zone-based firewall architecture for the homelab network, implemented on the UDM Pro using **UniFi Network Application v10.x**.

> **Note**: UniFi Network v10.x introduced a new zone-based firewall UI under **Settings > Security > Firewall**. The legacy firewall API still works but is not reflected in the new UI. This documentation covers the new zone-based approach.

## Network Architecture Overview

The homelab network uses a **dual-router architecture** with routing responsibilities split between the UDM Pro ("Windroute") and an L3 switch ("Switch Rack PoE"). This architecture has important implications for firewall policy.

### Dual-Router Architecture

```
                              ┌──────────────────────────────────────────────────────────────┐
                              │                     INTERNET (WAN)                            │
                              └──────────────────────────────────────────────────────────────┘
                                                          │
                                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                         UDM Pro ("Windroute")                                            │
│                                    Primary Router / Firewall / NAT                                       │
│                                                                                                          │
│   Routes: Default (1), Management (200), IoT (204), Security (205), Guest (206), Unifi (212)            │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────┘
       │           │           │           │           │           │           │
       ▼           ▼           ▼           ▼           ▼           ▼           ▼
 ┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐
 │ Untagged ││ VLAN 200 ││ VLAN 204 ││ VLAN 205 ││ VLAN 206 ││ VLAN 212 ││ VLAN 4040│
 │ Default  ││Management││   IoT    ││ Security ││  Guest   ││  Unifi   ││ Transit  │
 │  LEGACY  ││ TRUSTED  ││   IOT    ││ ISOLATED ││  GUEST   ││  INFRA   ││  INFRA   │
 │10.10.199 ││10.10.200 ││10.10.204 ││10.10.205 ││10.10.206 ││10.10.212 ││10.255.253│
 └──────────┘└──────────┘└──────────┘└──────────┘└──────────┘└──────────┘└────┬─────┘
                                                                              │
                                         Inter-VLAN Transit (VLAN 4040)       │
                                         UDM: 10.255.253.1 ◄─────────────────►│
                                         L3 Switch: 10.255.253.3              │
                                                                              │
                ┌─────────────────────────────────────────────────────────────┘
                │
                ▼
 ┌────────────────────────────────────────────────────────────────────────────────────────┐
 │                           L3 Switch ("Switch Rack PoE")                                 │
 │                              Secondary Router                                           │
 │                                                                                         │
 │   Routes: Servers (201), Clients (202), vSAN (209)                                     │
 │   Static routes to AWS via 10.255.253.3                                                 │
 └────────────────────────────────────────────────────────────────────────────────────────┘
                │              │              │
                ▼              ▼              ▼
          ┌──────────┐   ┌──────────┐   ┌──────────┐
          │ VLAN 201 │   │ VLAN 202 │   │ VLAN 209 │
          │ Servers  │   │ Clients  │   │   vSAN   │
          │ TRUSTED  │   │ TRUSTED  │   │  INFRA   │
          │10.10.201 │   │10.10.202 │   │10.10.209 │
          └──────────┘   └──────────┘   └──────────┘

                               AWS/WireGuard Routes (via L3 Switch)
                               ─────────────────────────────────────
                               10.10.100.0/22   - AWS Environment
                               10.255.255.0/29 - WireGuard tunnel endpoint
                               10.254.0.0/24   - WireGuard client tunnel
```

### Firewall Implications of Dual-Router Architecture

**Critical Understanding**: The UDM Pro firewall only sees traffic that traverses the UDM Pro. Traffic between networks routed by the L3 switch **never** passes through the UDM Pro firewall.

| Traffic Path | Firewall Applies? | Example |
|--------------|-------------------|---------|
| Servers (201) <-> Clients (202) | **No** - L3 switch only | User laptop accessing K8s services |
| Servers (201) <-> vSAN (209) | **No** - L3 switch only | Proxmox host accessing vSAN storage |
| Servers (201) <-> IoT (204) | **Yes** - crosses UDM | Server accessing IoT device |
| Clients (202) <-> Internet | **Yes** - crosses UDM | Web browsing |
| IoT (204) <-> Security (205) | **Yes** - crosses UDM | Should be blocked |
| Any <-> Internet | **Yes** - crosses UDM | All internet traffic |

**Where to apply security policies:**

| Traffic Flow | Where to Configure |
|--------------|-------------------|
| Between L3-switch VLANs (201, 202, 209) | L3 switch ACLs |
| Between UDM VLANs (200, 204, 205, 206, 212) | UDM Zone-Based Firewall |
| Between L3-switch and UDM VLANs | UDM Zone-Based Firewall (on transit VLAN 4040) |
| To/from Internet | UDM Zone-Based Firewall |

## Complete VLAN Inventory

### Networks Routed by UDM Pro (Windroute)

| VLAN | Name | Subnet | Zone | Purpose |
|------|------|--------|------|---------|
| 1 | Default | 10.10.199.0/24 | Legacy | Legacy/unused - should be empty |
| 200 | Management | 10.10.200.0/24 | Trusted | Network equipment (UDM, switches, APs) |
| 204 | IoT | 10.10.204.0/24 | IoT | Smart home devices |
| 205 | Security | 10.10.205.0/24 | Security | Cameras, NVR |
| 206 | Guest | 10.10.206.0/24 | Guest | Guest WiFi (Network Isolation enabled) |
| 212 | Unifi | 10.10.212.0/24 | Infrastructure | UniFi devices (APs, readers, cameras, IP phones) |
| 4040 | Inter-VLAN Routing | 10.255.253.0/24 | Infrastructure | Transit between UDM and L3 switch |

### Networks Routed by L3 Switch (Switch Rack PoE)

| VLAN | Name | Subnet | Zone | Purpose |
|------|------|--------|------|---------|
| 201 | Servers | 10.10.201.0/24 | Trusted | K8s nodes, DNS, infrastructure services (includes Ceph storage) |
| 202 | Clients | 10.10.202.0/24 | Trusted | User laptops, phones |
| 209 | vSAN | 10.10.209.0/24 | Infrastructure | Storage network (Proxmox/NAS) |

### Static Routes (via L3 Switch at 10.255.253.3)

| Destination | Purpose |
|-------------|---------|
| 10.10.100.0/22 | AWS Environment |
| 10.255.255.0/29 | WireGuard tunnel endpoint |
| 10.254.0.0/24 | WireGuard client tunnel |

## Zone Definitions

The network is organized into six security zones based on trust level and function:

| Zone | Trust Level | Networks | Description |
|------|-------------|----------|-------------|
| **Trusted** | High | Management (200), Servers (201), Clients (202) | Full inter-zone access, primary work networks |
| **Infrastructure** | High (Restricted) | vSAN (209), Unifi (212), Inter-VLAN (4040) | Critical infrastructure, access restricted to specific systems |
| **IoT** | Low | IoT (204) | Smart home devices, limited access |
| **Security** | Isolated | Security (205) | Cameras, NVR, highly restricted |
| **Guest** | Untrusted | Guest (206) | Guest WiFi, internet-only access |
| **Legacy** | None | Default (1) | Legacy network, should be empty |

## Default Policies

### Zone-to-Zone Default Actions

| Source Zone | Trusted | Infrastructure | IoT | Security | Guest | Internet |
|-------------|---------|----------------|-----|----------|-------|----------|
| **Trusted** | Allow | Allow | Allow | Allow | Deny | Allow |
| **Infrastructure** | Allow* | Allow* | Deny | Deny | Deny | Deny** |
| **IoT** | Deny | Deny | Allow | Deny | Deny | Allow |
| **Security** | Deny | Deny | Deny | Allow | Deny | Deny |
| **Guest** | Deny | Deny | Deny | Deny | Deny | Allow |
| **Legacy** | Deny | Deny | Deny | Deny | Deny | Deny |

**Notes:**
- `*` Infrastructure to Trusted: Only for management/monitoring purposes
- `**` Infrastructure to Internet: Generally denied; storage networks should not reach internet

### Detailed Zone Policies

#### Trusted Zone (Management, Servers, Clients)

| Policy | Description |
|--------|-------------|
| Inter-zone | Full access between Trusted networks |
| To IoT | Allow (for management and Home Assistant) |
| To Security | Allow (for NVR access and camera management) |
| To Infrastructure | Allow (for storage and switch management) |
| To Guest | Deny (no reason to access guest devices) |
| To Internet | Allow |

#### Infrastructure Zone (vSAN, Unifi, Inter-VLAN)

| Network | Allowed Sources | Allowed Destinations |
|---------|-----------------|---------------------|
| vSAN (209) | Proxmox hosts, NAS (from Servers VLAN) | Storage targets only |
| Unifi (212) | Management (200), UDM | UniFi Controller, APs |
| Inter-VLAN (4040) | UDM (10.255.253.1), L3 Switch (10.255.253.3) | Routing traffic only |

#### IoT Zone

| Policy | Description |
|--------|-------------|
| To DNS (Servers) | Allow UDP/53, TCP/53 to 10.10.201.5, 10.10.201.6 |
| To Home Assistant | Allow TCP/8123 to 10.10.204.25 (if in IoT VLAN) |
| To NTP | Allow UDP/123 to router gateway |
| To Internet | Allow (for cloud services, updates) |
| To all other internal | Deny |

#### Security Zone

| Policy | Description |
|--------|-------------|
| To DNS (Servers) | Allow UDP/53, TCP/53 to 10.10.201.5, 10.10.201.6 |
| Internal to NVR | Allow cameras (10.10.205.0/24) to NVR (10.10.205.10) |
| To Internet | Deny by default; optionally allow NVR (10.10.205.10) to TCP/443 for cloud backup |
| To all other internal | Deny |

#### Guest Zone

| Policy | Description |
|--------|-------------|
| Network Isolation | **Enabled** - Uses UDM built-in DNS and DHCP isolation |
| To Internet | Allow |
| To all internal | Deny (enforced by Network Isolation) |

> **Note**: Guest network should use UniFi's built-in Network Isolation feature rather than zone-based firewall rules. This provides complete isolation at a lower level and includes captive portal support.

#### Legacy Zone (Default — untagged native, 10.10.199.0/24)

| Policy | Description |
|--------|-------------|
| All traffic | Deny - this VLAN should have no devices |

## Explicit Allow Rules

These rules permit specific cross-zone traffic that would otherwise be denied by default policies.

### IoT Zone Rules

| Rule Name | Source | Destination | Protocol/Port | Purpose |
|-----------|--------|-------------|---------------|---------|
| IoT-to-DNS | 10.10.204.0/24 | 10.10.201.5, 10.10.201.6 | UDP/53, TCP/53 | DNS resolution |
| IoT-to-HomeAssistant | 10.10.204.0/24 | 10.10.204.25 | TCP/8123 | Home Assistant API |
| IoT-to-NTP | 10.10.204.0/24 | 10.10.200.1 | UDP/123 | Time sync via router |
| IoT-to-MQTT | 10.10.204.0/24 | 10.10.201.x | TCP/1883, TCP/8883 | MQTT broker (if applicable) |

### Security Zone Rules

| Rule Name | Source | Destination | Protocol/Port | Purpose |
|-----------|--------|-------------|---------------|---------|
| Security-to-DNS | 10.10.205.0/24 | 10.10.201.5, 10.10.201.6 | UDP/53, TCP/53 | DNS resolution |
| Security-to-NVR | 10.10.205.0/24 | 10.10.205.10 | TCP/7443, TCP/554 (RTSP) | UniFi Protect NVR |
| NVR-to-Internet | 10.10.205.10 | 0.0.0.0/0 | TCP/443 | Cloud backup (optional) |

### Infrastructure Zone Rules

| Rule Name | Source | Destination | Protocol/Port | Purpose |
|-----------|--------|-------------|---------------|---------|
| Unifi-Adoption | 10.10.212.0/24 | 10.10.200.1 | TCP/8080 | UniFi device adoption |
| Unifi-STUN | 10.10.212.0/24 | 10.10.200.1 | UDP/3478 | STUN for UniFi |
| vSAN-to-vSAN | 10.10.209.0/24 | 10.10.209.0/24 | All | vSAN/storage cluster traffic |

### Trusted Zone Cross-Access Rules

| Rule Name | Source | Destination | Protocol/Port | Purpose |
|-----------|--------|-------------|---------------|---------|
| Mgmt-to-Servers | 10.10.200.0/24 | 10.10.201.0/24 | All | Network management access |
| Clients-to-Servers | 10.10.202.0/24 | 10.10.201.0/24 | All | User access to services |
| Clients-to-IoT | 10.10.202.0/24 | 10.10.204.0/24 | All | Control IoT devices |

### Return Traffic

| Rule Name | Source | Destination | Protocol/Port | Purpose |
|-----------|--------|-------------|---------------|---------|
| Established-Return | Any | Any | Established/Related | Return traffic for allowed connections |

## UDM Pro Configuration (UniFi Network v10.x)

UniFi Network v10.x uses a **Zone-Based Firewall** with a visual **Zone Matrix** interface. This replaces the legacy LAN In/Out/Local rule types with a more intuitive zone-to-zone policy model.

### Prerequisites: Disable Network Isolation

> **IMPORTANT**: Before creating firewall rules to allow specific traffic between zones, you **must** disable Network Isolation on any networks where you want granular firewall control. Network Isolation blocks inter-VLAN traffic at a lower level than firewall rules - if it's enabled, your allow rules will have no effect.

**What is Network Isolation?**

Network Isolation is a UniFi feature that provides a simple "all or nothing" block of inter-VLAN traffic. When enabled:
- All traffic to/from other VLANs is blocked at the switch/network level
- This blocking happens **before** firewall rules are evaluated
- Firewall allow rules cannot override Network Isolation

**When to use Network Isolation vs. Zone-Based Firewall:**

| Use Case | Recommended Approach |
|----------|---------------------|
| Complete isolation (no inter-VLAN traffic needed) | Network Isolation ON |
| Selective traffic allowed (e.g., IoT to DNS only) | Network Isolation OFF + Zone-Based Firewall rules |
| Guest network with internet-only access | Network Isolation ON |

**How to Disable Network Isolation:**

**Navigation**: `Settings` > `Networks` > `[Select Network]` > `Advanced` (expand if collapsed)

1. Go to **Settings** > **Networks**
2. Click on the network you want to modify (e.g., **IoT** or **Security**)
3. Scroll down and expand the **Advanced** section (click "Advanced" or the expand arrow)
4. Find the **Network Isolation** toggle
5. Set it to **OFF** (disabled)
6. Click **Save** or **Apply Changes**

Network Isolation settings by network:

| Network | VLAN | Disable Network Isolation? | Reason |
|---------|------|---------------------------|--------|
| Default | 1 | No | Legacy, should have no devices |
| Management | 200 | No (leave default) | Trusted zone, typically not isolated |
| Servers | 201 | No (leave default) | Trusted zone, L3 switch routed |
| Clients | 202 | No (leave default) | Trusted zone, L3 switch routed |
| IoT | 204 | **Yes** | Need to allow DNS traffic to Servers zone |
| Security | 205 | **Yes** | Need to allow DNS traffic to Servers zone |
| Guest | 206 | **No** | Keep isolation enabled for complete guest isolation |
| vSAN | 209 | No | L3 switch routed, restricted at switch level |
| Unifi | 212 | **Yes** | Need to allow adoption/management traffic |
| Inter-VLAN | 4040 | No | Transit network, restrict at switch level |

> **Warning**: After disabling Network Isolation, the network will rely entirely on your zone-based firewall rules for security. Make sure you have proper deny-by-default policies in place before disabling isolation. Custom zones (IoT, Security, Infrastructure) are blocked from Internal zone by default, so your security posture is maintained.

---

### Step-by-Step Configuration

Once you have disabled Network Isolation on the relevant networks, proceed with the following steps to configure zone-based firewall rules.

### Understanding the Zone Matrix

The Zone Matrix displays traffic flow between zones as a grid:
- **Rows** = Source zones (where traffic originates)
- **Columns** = Destination zones (where traffic is headed)
- **Cells** = Policies controlling traffic between those zones

Built-in zones in UniFi v10.x:
| Zone | Purpose |
|------|---------|
| **Internal** | Default zone for trusted LAN networks |
| **External** | Untrusted traffic (WAN/Internet) |
| **Gateway** | Traffic to/from the UDM Pro itself (DHCP, DNS, management) |
| **VPN** | VPN client and site-to-site traffic |

### Step 1: Create Custom Zones

For proper network segmentation, create custom zones for each security zone.

**Navigation**: `Settings` > `Security` > `Firewall` > `Zones` tab

1. Click **Create Zone**
2. Enter zone name (e.g., `IoT`)
3. Select the network to assign (e.g., IoT VLAN 204)
4. Click **Create**

Create the following zones:

| Zone Name | Assigned Networks | Purpose |
|-----------|------------------|---------|
| `IoT` | VLAN 204 (10.10.204.0/24) | Smart home devices |
| `Security` | VLAN 205 (10.10.205.0/24) | Cameras, NVR |
| `Infrastructure` | VLAN 212 (10.10.212.0/24), VLAN 4040 (10.255.253.0/24) | UniFi devices, transit |

> **Note**: Networks in custom zones are **blocked by default** from accessing other custom zones and the Internal zone. They can reach External (internet) and Gateway by default.

> **Note**: Guest (VLAN 206) should remain in the default Internal zone with Network Isolation enabled, rather than a custom zone.

> **Note**: Management (VLAN 200) should remain in the Internal zone as it's a trusted network.

### Step 2: Create Network Objects (IP Groups)

Network Objects define reusable IP addresses and subnets for use in firewall policies.

**Navigation**: `Settings` > `Profiles` > `Network Objects`

1. Click **Create New**
2. Configure:
   - **Object Name**: `DNS-Servers`
   - **Type**: `IPv4 Address/Subnet`
   - **Address**: `10.10.201.5` (click Add, then add `10.10.201.6`)
3. Click **Add** to save

Create the following Network Objects:

| Object Name | Type | Addresses |
|-------------|------|-----------|
| `DNS-Servers` | IPv4 Address/Subnet | 10.10.201.5, 10.10.201.6 |
| `Management-Network` | IPv4 Address/Subnet | 10.10.200.0/24 |
| `Servers-Network` | IPv4 Address/Subnet | 10.10.201.0/24 |
| `Client-Network` | IPv4 Address/Subnet | 10.10.202.0/24 |
| `IoT-Network` | IPv4 Address/Subnet | 10.10.204.0/24 |
| `Security-Network` | IPv4 Address/Subnet | 10.10.205.0/24 |
| `Guest-Network` | IPv4 Address/Subnet | 10.10.206.0/24 |
| `vSAN-Network` | IPv4 Address/Subnet | 10.10.209.0/24 |
| `Unifi-Network` | IPv4 Address/Subnet | 10.10.212.0/24 |
| `NVR-Server` | IPv4 Address/Subnet | 10.10.205.10 |
| `Home-Assistant` | IPv4 Address/Subnet | 10.10.204.25 |
| `Router-Gateway` | IPv4 Address/Subnet | 10.10.200.1 |
| `AWS-Networks` | IPv4 Address/Subnet | 10.10.100.0/22, 10.255.255.0/29, 10.254.0.0/24 |

### Step 3: Create Port Groups

**Navigation**: `Settings` > `Profiles` > `Port Groups`

1. Click **Create New**
2. Configure:
   - **Name**: `DNS-Ports`
   - **Port**: `53`
3. Click **Add**

| Group Name | Ports | Purpose |
|------------|-------|---------|
| `DNS-Ports` | 53 | DNS queries |
| `NTP-Port` | 123 | Time synchronization |
| `HomeAssistant-Port` | 8123 | Home Assistant web UI |
| `UniFi-Adoption-Ports` | 8080, 3478 | UniFi device adoption/STUN |
| `NVR-Ports` | 7443, 554 | UniFi Protect NVR, RTSP |

### Step 4: Create Firewall Policies via Zone Matrix

**Navigation**: `Settings` > `Security` > `Firewall`

The Zone Matrix shows all zones. Click on a cell (intersection of source and destination zones) to view or create policies for that traffic flow.

---

#### Policy 1: Allow IoT to DNS Servers

This policy allows IoT devices (10.10.204.0/24) to reach DNS servers (10.10.201.5, 10.10.201.6) on port 53.

1. In the Zone Matrix, click the cell at **IoT** (row) -> **Internal** (column)
2. Click **Create Policy** at the bottom of the policy list
3. Configure the policy:

| Field | Value |
|-------|-------|
| **Name** | Allow IoT to DNS |
| **Action** | Allow |
| **Source Zone** | IoT |
| **Specific Source** | Type: IP, Object: `IoT-Network` |
| **Destination Zone** | Internal |
| **Specific Destination** | Type: IP, Object: `DNS-Servers` |
| **Port** | Object: `DNS-Ports` |
| **IP Version** | IPv4 |
| **Protocol** | TCP/UDP |
| **Connection State** | All |
| **Schedule** | Always |

4. Click **Add Policy**

---

#### Policy 2: Allow Security to DNS Servers

1. Click the cell at **Security** -> **Internal**
2. Click **Create Policy**
3. Configure:

| Field | Value |
|-------|-------|
| **Name** | Allow Security to DNS |
| **Action** | Allow |
| **Source Zone** | Security |
| **Specific Source** | Type: IP, Object: `Security-Network` |
| **Destination Zone** | Internal |
| **Specific Destination** | Type: IP, Object: `DNS-Servers` |
| **Port** | Object: `DNS-Ports` |
| **IP Version** | IPv4 |
| **Protocol** | TCP/UDP |
| **Connection State** | All |
| **Schedule** | Always |

4. Click **Add Policy**

---

#### Policy 3: Allow Infrastructure (Unifi) to Management

1. Click the cell at **Infrastructure** -> **Internal**
2. Click **Create Policy**
3. Configure:

| Field | Value |
|-------|-------|
| **Name** | Allow Unifi Adoption |
| **Action** | Allow |
| **Source Zone** | Infrastructure |
| **Specific Source** | Type: IP, Object: `Unifi-Network` |
| **Destination Zone** | Internal |
| **Specific Destination** | Type: IP, Object: `Router-Gateway` |
| **Port** | Object: `UniFi-Adoption-Ports` |
| **IP Version** | IPv4 |
| **Protocol** | TCP/UDP |
| **Connection State** | All |
| **Schedule** | Always |

4. Click **Add Policy**

---

#### Policy 4: Block Security Zone Internet Access

If you want to block the Security zone from reaching the internet (except for allowed rules):

1. Click the cell at **Security** -> **External**
2. The default may be "Allow All" - click to view policies
3. Click **Create Policy**
4. Configure:

| Field | Value |
|-------|-------|
| **Name** | Block Security to Internet |
| **Action** | Block |
| **Source Zone** | Security |
| **Specific Source** | Any |
| **Destination Zone** | External |
| **Specific Destination** | Any |
| **Protocol** | All |

5. Click **Add Policy**

---

#### Policy 5: Allow NVR Cloud Backup (Optional)

If you want to allow the NVR to reach the internet for cloud backup:

1. Click the cell at **Security** -> **External**
2. Click **Create Policy**
3. Configure:

| Field | Value |
|-------|-------|
| **Name** | Allow NVR Cloud Backup |
| **Action** | Allow |
| **Source Zone** | Security |
| **Specific Source** | Type: IP, Object: `NVR-Server` |
| **Destination Zone** | External |
| **Specific Destination** | Any |
| **Port** | 443 |
| **IP Version** | IPv4 |
| **Protocol** | TCP |
| **Connection State** | All |
| **Schedule** | Always |

4. Click **Add Policy**
5. **Important**: Ensure this rule is ordered ABOVE the "Block Security to Internet" rule (Policy 4)

> **Note**: In v10.x, custom zones like IoT and Security are blocked from accessing Internal by default. You only need explicit allow rules for specific traffic (like DNS). Block rules are primarily needed for zone-to-zone traffic that is allowed by default.

### Step 5: Verify Zone Matrix

After creating policies, the Zone Matrix will show:
- **IoT -> Internal**: Shows policy count (e.g., "Policies (1)")
- **Security -> Internal**: Shows policy count
- **Infrastructure -> Internal**: Shows policy count

Click on any cell to view the policies applied to that zone pair.

### Zone Matrix Quick Reference

| Source Zone | Destination Zone | Default Behavior | Custom Policy |
|-------------|------------------|------------------|---------------|
| Internal | Internal | Allow All | - |
| Internal | External | Allow All | - |
| Internal | IoT | Allow All | - |
| Internal | Security | Allow All | - |
| Internal | Infrastructure | Allow All | - |
| IoT | Internal | **Block All** | Allow to DNS only |
| IoT | External | Allow All | - |
| IoT | Security | **Block All** | - |
| Security | Internal | **Block All** | Allow to DNS only |
| Security | External | Allow All | Block (except NVR) |
| Security | IoT | **Block All** | - |
| Infrastructure | Internal | **Block All** | Allow UniFi adoption |
| Infrastructure | External | Allow All | Block (recommended) |
| Any | Gateway | Allow All | - |

## L3 Switch ACL Configuration

Since the L3 switch routes traffic between Servers (201), Clients (202), and vSAN (209), you must configure ACLs on the switch to enforce security between these networks.

### Recommended L3 Switch ACLs

| ACL Name | Source | Destination | Action | Purpose |
|----------|--------|-------------|--------|---------|
| Deny-Clients-to-vSAN | 10.10.202.0/24 | 10.10.209.0/24 | Deny | Client devices should not access storage |
| Allow-Servers-to-vSAN | 10.10.201.0/24 | 10.10.209.0/24 | Allow | Proxmox hosts need vSAN access |
| Allow-Clients-to-Servers | 10.10.202.0/24 | 10.10.201.0/24 | Allow | Users access services |
| Allow-Servers-to-Clients | 10.10.201.0/24 | 10.10.202.0/24 | Allow | Services respond to users |

> **Note**: The specific configuration syntax depends on your L3 switch vendor (e.g., UniFi Switch, Cisco, etc.). Consult your switch documentation for ACL configuration commands.

## Testing

After configuring policies, verify from devices in each zone:

### From an IoT device (10.10.204.x):

```bash
# Should work - DNS resolution via internal DNS servers
nslookup google.com 10.10.201.5
nslookup google.com 10.10.201.6
dig @10.10.201.5 google.com

# Should work - Internet access
ping 8.8.8.8
curl -I https://google.com

# Should be blocked - Direct access to servers network (except DNS)
ping 10.10.201.50  # K8s control plane
curl http://10.10.201.1  # Should fail

# Should be blocked - Access to client network
ping 10.10.202.x  # Client devices

# Should be blocked - Access to security network
ping 10.10.205.10  # NVR
```

### From a Security zone device (10.10.205.x):

```bash
# Should work - DNS resolution
nslookup google.com 10.10.201.5

# Should work - Access to NVR within security zone
ping 10.10.205.10

# Should be blocked (if Policy 6 is configured)
ping 8.8.8.8  # Internet access

# Should be blocked - Access to other networks
ping 10.10.204.x  # IoT devices
ping 10.10.202.x  # Client devices
```

### From a Guest device (10.10.206.x):

```bash
# Should work - Internet access (via UDM DNS)
ping 8.8.8.8
curl -I https://google.com

# Should be blocked - All internal networks
ping 10.10.201.x  # Servers
ping 10.10.202.x  # Clients
ping 10.10.204.x  # IoT
ping 10.10.205.x  # Security
```

## Troubleshooting

### View Firewall Logs

**Navigation**: `Settings` > `System` > `System Log`

1. Click the **Triggers** tab
2. Look for blocked traffic entries
3. Filter by source IP to see what is being blocked

### Common Issues

| Symptom | Possible Cause | Solution |
|---------|----------------|----------|
| IoT devices cannot resolve DNS | Policy not created or wrong zone assignment | Verify network is in correct zone, check policy exists |
| **Firewall allow rules have no effect** | **Network Isolation is enabled** | **Disable Network Isolation on the source network (Settings > Networks > [Network] > Advanced > Network Isolation OFF). See Prerequisites section.** |
| Policy created but not working | Zone assignment issue | Check that the VLAN is assigned to the correct custom zone |
| Return traffic blocked | Missing return policy | In v10.x, return traffic is usually auto-allowed; check Connection State is set to "All" |
| Cannot access UDM Pro management | Gateway zone blocked | Ensure Gateway zone access is not blocked |
| Traffic between L3-switch VLANs not filtered | Wrong device | UDM firewall does not see L3-switch routed traffic; configure ACLs on L3 switch |
| Guest can access internal networks | Network Isolation disabled | Re-enable Network Isolation on Guest network |

### Verify Zone Assignment

1. Go to `Settings` > `Networks`
2. Click on your network (e.g., IoT, Security, Unifi)
3. Look for the **Zone** field - ensure it shows your custom zone name

### Verify Traffic Path

To determine if traffic passes through the UDM firewall:

1. Identify source and destination VLANs
2. Check which device routes each VLAN:
   - VLANs 1, 200, 204, 205, 206, 212, 4040: UDM Pro
   - VLANs 201, 202, 209: L3 Switch
3. If both VLANs are routed by the same device, UDM firewall rules may not apply

## Legacy Configuration (Pre-v10.x)

<details>
<summary>Click to expand legacy firewall rule configuration (for reference only)</summary>

The legacy firewall used LAN In/Out/Local rule types with IP Groups. This configuration is preserved for reference but should not be used on UniFi Network v10.x.

### Legacy Navigation
- IP Groups: `Settings` > `Profiles` > `IP Groups`
- Firewall Rules: `Settings` > `Firewall & Security` > `Firewall Rules`

### Legacy Rule Types
- **LAN In**: Traffic entering from LAN interface
- **LAN Out**: Traffic exiting to LAN interface
- **LAN Local**: Traffic destined for the UDM Pro itself

If you have legacy rules, you can migrate to zone-based firewall:
1. Navigate to `Security` > `Traffic & Firewall Rules`
2. Click **Upgrade** to migrate to Zone-Based Firewall

</details>

## Future Considerations

1. **mDNS Reflector**: If IoT devices need to discover each other across VLANs, enable mDNS reflector in UniFi settings (`Settings` > `Networks` > Advanced)
2. **IGMP Proxy**: For multicast traffic (some smart home protocols)
3. **Logging**: Enable syslog logging on block policies for troubleshooting
4. **Auto Allow Return Traffic**: When creating allow policies, enable this option if bidirectional communication is needed
5. **AWS Network Access**: Configure policies to allow appropriate traffic to/from AWS networks (10.10.100.0/22) via the WireGuard tunnel
6. **L3 Switch ACL Automation**: Consider using Ansible or similar to manage L3 switch ACLs consistently
7. **Network Segmentation Review**: Periodically review zone assignments and policies as the network evolves

## References

- [UniFi Zone-Based Firewalls - Ubiquiti Help Center](https://help.ui.com/hc/en-us/articles/115003173168-Zone-Based-Firewalls-in-UniFi)
- [UniFi Gateway - Advanced Firewall Rules](https://help.ui.com/hc/en-us/articles/27699646208279-UniFi-Gateway-Advanced-Firewall-Rules)
- [Migrating to Zone-Based Firewalls](https://help.ui.com/hc/en-us/articles/28223082254743-Migrating-to-Zone-Based-Firewalls-in-UniFi)
- [Traffic & Policy Management in UniFi](https://help.ui.com/hc/en-us/articles/5546542486551-Traffic-Policy-Management-in-UniFi)
