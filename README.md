<div align="center">
  <img src="strongswan.png" alt="strongSwan" width="50%" />
</div>

# Cloudflare WAN Multi-ISP for strongSwan 6 

This Terraform module automates the deployment of a highly available, multi-ISP, Anycast-routed network topology connecting an on-premises Linux edge gateway running **strongSwan 6** directly to **Cloudflare Magic WAN**. 

The configuration utilizes next-generation **Post-Quantum Hybrid Cryptography** to safeguard data transit tunnels against future decryption vectors.

## 🏗️ Architecture Blueprint

The module orchestrates a mesh of dynamic IPsec tunnels utilizing standard Linux Virtual Tunnel Interfaces (VTIs) and policy routing configurations:

* **Tunnel 1:** Primary ISP Interface ──> Cloudflare Anycast Endpoint 1
* **Tunnel 2:** Primary ISP Interface ──> Cloudflare Anycast Endpoint 2
* **Tunnel 3:** Secondary ISP Interface ──> Cloudflare Anycast Endpoint 1 (If `num_of_tunnels = 4`)
* **Tunnel 4:** Secondary ISP Interface ──> Cloudflare Anycast Endpoint 2 (If `num_of_tunnels = 4`)

## Supported Operating Systems

The installation script auto-detects the Linux distribution and adapts package management, firewall configuration, and kernel module persistence accordingly. The following distributions are tested and supported:

| Distribution Family | Supported Versions |
|---|---|
| **Ubuntu** | 22.04 LTS (Jammy Jellyfish), 24.04 LTS |
| **Debian** | 11 (Bullseye), 12 (Bookworm) |
| **RHEL** | 9.x |
| **Rocky Linux** | 9.x |
| **AlmaLinux** | 9.x |
| **Oracle Linux** | 9.x |
| **CentOS Stream** | 9 |

**Distro-specific behavior:**
* **Debian/Ubuntu:** Dependencies installed via `apt-get`. Firewall managed through `ufw` (if present). Kernel module persistence via `/etc/modules`.
* **RHEL-family:** Dependencies installed via `dnf`. Firewall managed through `firewalld` (if active) with `iptables` fallback. Kernel module persistence via `/etc/modules-load.d/`. SELinux contexts applied automatically where applicable.
* **Both:** strongSwan 6.0.7 is compiled from source. IP forwarding persisted via `/etc/sysctl.d/99-strongswan.conf`.

## ⚡ Post-Quantum Cryptographic Suite

Handshakes are negotiated natively via the `stroke` backend using strict state-of-the-art parameters:
* **IKE Phase 1:** `aes256gcm16-sha256-ecp384-ke1_mlkem768!` (NIST Round 4 Post-Quantum ML-KEM Key Exchange)
* **ESP Phase 2:** `aes256gcm16-ecp384!` (Authenticated GCM-mode Encryption)

---

## ⚠️ Critical Deployment Requirements & Gotchas

### 1. Tunnel Interface Subnet Constraints
The Cloudflare network API strictly validates the inner interface transit address space block provided via `tunnel_interface_prefix_base`.
* **Private Range Validation:** The target subnet **must** fall inside valid RFC 1918 private blocks (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) or Link-Local space (`169.254.240.0/20`).

### 2. Bidirectional Tunnel Health Probing
Tunnels utilize **bidirectional health checks** (`type = "request"`). Cloudflare probes the *inner customer-side private IP* directly within the encrypted VTI tunnel. Request-style checks are used because reply-style checks are bounced by the Linux kernel.
* The module mathematically extracts the inner host IP (e.g., the odd IP `.3` within a `/31` layout) and binds it natively to the `vtiX` interfaces.
* **Do not remove or overlay these bound private addresses.** If the Linux kernel cannot explicitly resolve these IPs inside the VTIs, the prober will report 100% packet loss and flag the link as dead.

### 3. Policy Routing Asymmetry & SSH Protection
Because the installation script places a broad routing table rule (`from <public_ip> lookup viatunicmp`) on the edge server to route data plane packets through Magic WAN, it risks intercepting management plane traffic.
* **The Safety Gate:** To prevent your active SSH deployment session from being broken or swallowed by the tunnel payload, the script establishes a top-tier safety rule inside the kernel database at **Priority 5**:
  ```bash
  ip rule add ipproto tcp sport 22 lookup main priority 5
  ```
* This ensures all outbound TCP traffic from port 22 (SSH replies) always uses the `main` routing table instead of being redirected through the VTI tunnels.
* **Do not remove this rule** while managing the server remotely over SSH. If it is deleted, your SSH session will be captured by the tunnel routing and you will lose connectivity to the host.

### 4. WAN Fallback & Tunnel Resilience
The deployment includes two complementary mechanisms that ensure data-plane traffic automatically falls back to the WAN default gateway when IPsec tunnels are unavailable:

* **Event-Driven Failover (`ipsec-vti.sh`):** The strongSwan `leftupdown` script reacts to SA state changes in real time. When a tunnel's CHILD_SA goes down (detected via Dead Peer Detection), the script removes the corresponding `ip rule` entries (priority 70+ and 80+) for that tunnel. With the policy routing rules removed, the Linux kernel falls through to the `main` routing table, which contains the original WAN default gateway. When the tunnel re-establishes, the rules are automatically re-added.

* **Poll-Based Watchdog (`tunnel-watchdog.service`):** A systemd service polls `ipsec status` every 15 seconds to verify that `ip rule` state matches actual tunnel SA state. This acts as a safety net for edge cases where the updown script may not fire (e.g., strongSwan daemon crash, silent SA expiry). State transitions are logged via syslog (`tunnel-watchdog` tag) for operational visibility.

**Failover behavior:**
| Scenario | Result |
|---|---|
| Single tunnel down | Traffic shifts to the next available tunnel (inter-tunnel failover) |
| All tunnels down | Traffic falls back to the WAN default gateway |
| Tunnel recovers | Traffic is automatically steered back through the tunnel |
| strongSwan daemon crash | Watchdog detects all tunnels as down, removes rules for WAN fallback |

> **Note:** There is a brief black-hole window (up to ~30-150 seconds) between when a tunnel actually fails and when DPD detects the failure and triggers the updown script. The watchdog's 15-second poll interval provides a secondary detection path. To monitor failover events, check syslog: `journalctl -t tunnel-watchdog`.

### 5. Source NAT for Magic Transit Network Flow Collection
When `tunnel_flow_traffic_only = true`, the tunnels are used exclusively to encrypt outbound network flow telemetry (NetFlow/IPFIX and sFlow) to the Cloudflare flow collector at `162.159.65.1`. In this mode, Cloudflare expects flow traffic to originate from a customer-owned **Magic Transit protected prefix** IP.

Set `tunnel_flow_nat_ip` to an IP within your protected prefix. The module will install iptables SNAT rules in the `nat` POSTROUTING chain to rewrite the source address of:
* **NetFlow/IPFIX:** UDP destination port 2055
* **sFlow:** UDP destination port 6343

```hcl
tunnel_flow_traffic_only = true
tunnel_flow_nat_ip       = "203.0.113.10"  # Must be within your Magic Transit protected prefix
```

When `tunnel_flow_traffic_only = false` (the default Magic WAN / Zero Trust use case), no SNAT rules are created. To verify the NAT rules are active:
```bash
sudo iptables -t nat -L POSTROUTING -v -n
```

---

## Diagnostics & Monitoring

> All commands below require `sudo` unless you are running as root.

### Tunnel SA Status
View the current IKE/CHILD_SA state for all tunnels:
```bash
sudo ipsec status
```

For detailed output including rekey timers, SA lifetimes, and byte counters:
```bash
sudo swanctl --list-sas
```

### Watchdog Health Probe Log
The `tunnel-watchdog` service continuously probes each tunnel's SA state every 15 seconds and logs state transitions to syslog. Check the service is running:
```bash
sudo systemctl status tunnel-watchdog.service
```

View the full log history:
```bash
sudo journalctl -t tunnel-watchdog
```

Follow state changes in real time:
```bash
sudo journalctl -t tunnel-watchdog -f
```

> **Note:** The watchdog only logs on **state transitions** (e.g., a tunnel going from UP to DOWN or vice versa). If all tunnels have been stable since the service started, the log will be empty. A quiet log means no failover events have occurred.

### Policy Routing Rules
Inspect the active `ip rule` entries to verify which tunnels have their data-plane steering rules installed:
```bash
sudo ip rule show
```
When a tunnel is healthy, you should see its priority 70+ (health-check pinning) and priority 80+ (data-plane steering) rules present. When a tunnel is down, these rules are removed to allow WAN fallback.

### VTI Interface State
Check whether each VTI interface is up or down:
```bash
ip -brief link show type vti
```

### Network Flow SNAT Verification
When `tunnel_flow_traffic_only = true` and `tunnel_flow_nat_ip` is set, verify the SNAT rules are active and firing:

Check the iptables NAT rules and their packet/byte counters:
```bash
sudo iptables -t nat -L POSTROUTING -v -n
```
Non-zero counters on the SNAT rules confirm NAT is active.

Capture NATed flow traffic on the VTI interfaces to verify the source IP is rewritten:
```bash
sudo tcpdump -i vti1 -n udp port 2055 or udp port 6343
```

To monitor both tunnels simultaneously:
```bash
sudo tcpdump -i any -n udp port 2055 or udp port 6343
```

### strongSwan Daemon Logs
For deep debugging of IKE negotiation, DPD events, and SA lifecycle:
```bash
sudo journalctl -u strongswan -f
```
