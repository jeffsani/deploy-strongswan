# Cloudflare Magic WAN Post-Quantum IPsec Deployment

This Terraform module automates the deployment of 2 or 4 Cloudflare Magic WAN IPsec tunnels to a remote Linux instance (Ubuntu, Debian, RHEL, or Oracle Linux). It securely negotiates hybrid post-quantum cryptography (ML-KEM / ECP384) with strict AES-GCM Phase 1 and Phase 2 encryption.

## Architecture

This deployment supports dynamic scaling based on your ISP links:
*   **2 Tunnels:** For a single public WAN connection, establishing primary and secondary Anycast connections.
*   **4 Tunnels:** For dual public WAN connections (discrete ISP links), establishing redundant connections across both WANs.

The deployment handles all inner VTI (Virtual Tunnel Interface) routing, TCP MSS clamping, and kernel-level IP forwarding dynamically.

## Prerequisites

*   Terraform v1.0+
*   A Cloudflare account with Magic WAN provisioned.
*   A target Linux machine reachable via SSH.
*   The target machine must allow inbound UDP port 500 and 4500 from the Cloudflare Anycast IPs.

## Host Preparation

Terraform utilizes a remote-exec provisioner over SSH to build strongSwan from source and configure the routing table. Because the script executes root-level networking commands, the `ssh_user` you define **must** have passwordless sudo privileges and key-based authentication pre-configured.

### Option A: Cloud-Init (Recommended)
If you are deploying your Linux instances in a cloud environment (AWS, GCP, Azure, Oracle), inject this User-Data payload at boot to properly stage the `terraform` user:

```yaml
#cloud-config
users:
  - name: terraform
    groups: [wheel, sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC... (Your Public Key Here)
