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

### 1. Internal Numeric Account ID (`cloudflare_internal_account_id`)
Cloudflare requires Custom Remote FQDN Identities to match a backend schema incorporating your legacy, numeric account ID. This is **not** the standard 32-character hex account ID visible in dashboard URLs.
* In the previous Terraform provider (v4.x and earlier), the `cloudflare_ipsec_tunnel` resource exposed computed `remote_id` and `user_id` attributes after tunnel creation. These contained the auto-generated FQDN identity (including the numeric account ID), so it never needed to be provided manually.
* In the current provider (v5.x), the resource was renamed to `cloudflare_magic_wan_ipsec_tunnel` and these computed attributes were **removed**. The FQDN identity must now be constructed manually via the `custom_remote_identities.fqdn_id` input, which requires knowing the numeric account ID upfront.
* The numeric account ID is not readily discoverable from the Cloudflare Dashboard. Contact your Cloudflare account team or support to obtain this value.

### 2. Tunnel Interface Subnet Constraints
The Cloudflare network API strictly validates the inner interface transit address space block provided via `tunnel_interface_prefix_base`.
* **Private Range Validation:** The target subnet **must** fall inside valid RFC 1918 private blocks (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) or Link-Local space (`169.254.0.0/16`).

### 3. Bidirectional Tunnel Health Probing
Tunnels utilize **bidirectional health checks** (`type = "request"`). Cloudflare probes the *inner customer-side private IP* directly within the encrypted VTI tunnel. Request-style checks are used because reply-style checks are bounced by the Linux kernel.
* The module mathematically extracts the inner host IP (e.g., the odd IP `.3` within a `/31` layout) and binds it natively to the `vtiX` interfaces.
* **Do not remove or overlay these bound private addresses.** If the Linux kernel cannot explicitly resolve these IPs inside the VTIs, the prober will report 100% packet loss and flag the link as dead.

### 4. Policy Routing Asymmetry & SSH Protection
Because the installation script places a broad routing table rule (`from <public_ip> lookup viatunicmp`) on the edge server to route data plane packets through Magic WAN, it risks intercepting management plane traffic.
* **The Safety Gate:** To prevent your active SSH deployment session from being broken or swallowed by the tunnel payload, the script establishes a top-tier safety rule inside the kernel database at **Priority 5**:
  ```bash
  ip rule add ipproto tcp sport 22 lookup main priority 5
  ```
* This ensures all outbound TCP traffic from port 22 (SSH replies) always uses the `main` routing table instead of being redirected through the VTI tunnels.
* **Do not remove this rule** while managing the server remotely over SSH. If it is deleted, your SSH session will be captured by the tunnel routing and you will lose connectivity to the host.
