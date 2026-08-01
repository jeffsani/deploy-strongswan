<p align="center">
  <img src="strongswan.png" alt="strongSwan" />
</p>

# Cloudflare WAN Multi-ISP for strongSwan 6 

This Terraform module automates the deployment of a highly available, multi-ISP, Anycast-routed network topology connecting an on-premises Linux edge gateway running **strongSwan 6** directly to **Cloudflare Magic WAN**. 

The configuration utilizes next-generation **Post-Quantum Hybrid Cryptography** to safeguard data transit tunnels against future decryption vectors.

## 🏗️ Architecture Blueprint

The module orchestrates a mesh of dynamic IPsec tunnels utilizing standard Linux Virtual Tunnel Interfaces (VTIs) and policy routing configurations:

* **Tunnel 1:** Primary ISP Interface ──> Cloudflare Anycast Endpoint 1
* **Tunnel 2:** Primary ISP Interface ──> Cloudflare Anycast Endpoint 2
* **Tunnel 3:** Secondary ISP Interface ──> Cloudflare Anycast Endpoint 1 (If `num_of_tunnels = 4`)
* **Tunnel 4:** Secondary ISP Interface ──> Cloudflare Anycast Endpoint 2 (If `num_of_tunnels = 4`)

## ⚡ Post-Quantum Cryptographic Suite

Handshakes are negotiated natively via the `stroke` backend using strict state-of-the-art parameters:
* **IKE Phase 1:** `aes256gcm16-sha256-ecp384-ke1_mlkem768!` (NIST Round 4 Post-Quantum ML-KEM Key Exchange)
* **ESP Phase 2:** `aes256gcm16-ecp384!` (Authenticated GCM-mode Encryption)

---

## ⚠️ Critical Deployment Requirements & Gotchas

### 1. How to Find Your Internal Numeric Account ID (`cloudflare_internal_account_id`)
Cloudflare requires Custom Remote FQDN Identities to match a backend schema incorporating your legacy, numeric account ID. This is separate from your standard 32-character hex account ID. To retrieve it:
1. Log into the Cloudflare Dashboard.
2. Select your account and go to **Manage Account** > **Billing**.
3. Look at your browser's URL bar. The numeric string following `/billing/` (e.g., `29336597`) is your internal account identifier.

### 2. Tunnel Interface Subnet Constraints
The Cloudflare network API strictly validates the inner interface transit address space block provided via `tunnel_interface_prefix_base`.
* **Private Range Validation:** The target subnet **must** fall inside valid RFC 1918 private blocks (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) or Link-Local space (`169.254.0.0/16`).
* **Example Failure:** Providing a public block such as `172.120.15.2/31` will trigger an immediate `400 Bad Request` from Cloudflare checkers. Use an explicitly private layout like `172.20.15.2/31`.

### 3. Bidirectional Tunnel Health Probing
Tunnels utilize **bidirectional health checks** (`type = "reply"`). Cloudflare bypasses external tracking and probes the *inner customer-side private IP* directly within the encrypted VTI tunnel.
* The module mathematically extracts the inner host IP (e.g., the odd IP `.3` within a `/31` layout) and binds it natively to the `vtiX` interfaces.
* **Do not remove or overlay these bound private addresses.** If the Linux kernel cannot explicitly resolve these IPs inside the VTIs, the prober will report 100% packet loss and flag the link as dead.

### 4. Policy Routing Asymmetry & SSH Protection
Because the installation script places a broad routing table rule (`from <public_ip> lookup viatunicmp`) on the edge server to route data plane packets through Magic WAN, it risks intercepting management plane traffic.
* **The Safety Gate:** To prevent your active SSH deployment session from being broken or swallowed by the tunnel payload, the script establishes a top-tier safety rule inside the kernel database at **Priority 5**:
  ```bash
  ip rule add ipproto tcp sport 22 lookup main priority 5
