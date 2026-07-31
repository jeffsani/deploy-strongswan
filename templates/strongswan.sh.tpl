#!/bin/bash
set -o errexit
set -o nounset

# Ensure all standard and local binary paths are explicitly available to the script
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "Starting Post-Quantum IPsec Tunnel Deployment..."

# ─── 1. OS Detection & Dependency Installation ───
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID=$ID
else
  echo "ERROR: Unsupported OS. Cannot determine distribution."
  exit 1
fi

echo "Detected OS: $OS_ID"

if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
  # Ubuntu / Debian Path
  apt-get update
  apt-get install -y build-essential libgmp-dev libssl-dev iptables iproute2 wget bzip2 tar

  # UFW NetFlow Gateway Forwarding Logic
  if command -v ufw >/dev/null 2>&1; then
    echo "Configuring UFW to ALLOW default transit forwarding..."
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    ufw reload || true
  fi

elif [[ "$OS_ID" == "ol" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" || "$OS_ID" == "centos" ]]; then
  # Oracle Linux 9 / RHEL 9 Path
  dnf install -y gcc make gmp-devel openssl-devel iptables iproute wget bzip2 tar

  # Firewalld NetFlow Gateway Forwarding Logic
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    echo "Configuring Firewalld to ALLOW transit forwarding..."
    firewall-cmd --permanent --add-forward-port=port=500:proto=udp:toport=500 2>/dev/null || true
    firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -j ACCEPT 2>/dev/null || true
    firewall-cmd --reload || true
  else
    iptables -P FORWARD ACCEPT || true
  fi
else
  echo "ERROR: Unsupported Linux distribution: $OS_ID"
  exit 1
fi

# ─── 2. Kernel IP Forwarding (NetFlow Gateway Requirement) ───
echo "Enabling Kernel IP Forwarding..."
sysctl -w net.ipv4.ip_forward=1
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# ─── 3. Compile strongSwan 6 from Source (with ML-KEM Support) ───
echo "Compiling strongSwan 6..."
cd /tmp
wget -q https://download.strongswan.org/strongswan-6.0.7.tar.bz2
tar -xjf strongswan-6.0.7.tar.bz2
cd strongswan-6.0.7

./configure --prefix=/usr --sysconfdir=/etc --enable-ml --enable-openssl --enable-stroke
make -j$(nproc)
make install

cd /tmp
rm -rf strongswan-6.0.7 strongswan-6.0.7.tar.bz2

# ─── 4. Configure /etc/strongswan.conf ───
cat > /etc/strongswan.conf << 'EOF'
charon {
  load_modular = yes
  install_routes = no
  install_virtual_ip = no
  plugins {
    include strongswan.d/charon/*.conf
  }
}
include strongswan.d/*.conf
EOF

# ─── 5. Configure /etc/ipsec.conf ───
cat > /etc/ipsec.conf << 'EOF'
config setup
  charondebug="all"
  uniqueids = yes

conn %default
  ikelifetime=24h
  rekey=yes
  reauth=no
  keyexchange=ikev2
  authby=secret
  dpdaction=restart
  closeaction=restart

conn strongSwan-vpn-1
  auto=start
  type=tunnel
  fragmentation=yes
  leftauth=psk
  left=%any
  leftid=${tunnel_1_id}.${cloudflare_account_id}.ipsec.cloudflare.com
  leftsubnet=0.0.0.0/0
  right=${cf_anycast_1}
  rightid=${cf_anycast_1}/32
  rightsubnet=0.0.0.0/0
  rightauth=psk
  ike=aes256-sha256-ecp384-ke1_mlkem768!
  esp=aes256gcm16-ecp384!
  replay_window=0
  mark_in=41
  mark_out=41
  leftupdown=/etc/strongswan.d/ipsec-vti.sh

conn strongSwan-vpn-2
  auto=start
  type=tunnel
  fragmentation=yes
  leftauth=psk
  left=%any
  leftid=${tunnel_2_id}.${cloudflare_account_id}.ipsec.cloudflare.com
  leftsubnet=0.0.0.0/0
  right=${cf_anycast_2}
  rightid=${cf_anycast_2}/32
  rightsubnet=0.0.0.0/0
  rightauth=psk
  ike=aes256-sha256-ecp384-ke1_mlkem768!
  esp=aes256gcm16-ecp384!
  replay_window=0
  mark_in=42
  mark_out=42
  leftupdown=/etc/strongswan.d/ipsec-vti.sh
EOF

# ─── 6. Configure /etc/ipsec.secrets ───
cat > /etc/ipsec.secrets << 'EOF'
${tunnel_1_id}.${cloudflare_account_id}.ipsec.cloudflare.com ${cf_anycast_1}/32 : PSK "${psk_1}"
${tunnel_2_id}.${cloudflare_account_id}.ipsec.cloudflare.com ${cf_anycast_2}/32 : PSK "${psk_2}"
EOF

# ─── 7. Define Explicit Policy Routing Table ───
if ! grep -q "viatunicmp" /etc/iproute2/rt_tables; then
  echo "200 viatunicmp" >> /etc/iproute2/rt_tables
fi

# ─── 8. Configure /etc/strongswan.d/ipsec-vti.sh ───
mkdir -p /etc/strongswan.d
cat > /etc/strongswan.d/ipsec-vti.sh << 'VTISCRIPT'
#!/bin/bash
set -o nounset
set -o errexit

case "$${PLUTO_CONNECTION}" in
  *vpn-1*)
    VTI_IF="vti0"
    ;;
  *vpn-2*)
    VTI_IF="vti1"
    ;;
  *)
    VTI_IF="vti0"
    ;;
esac

case "$${PLUTO_VERB}" in
  up-client)
    ip tunnel add "$${VTI_IF}" local "$${PLUTO_ME}" remote "$${PLUTO_PEER}" mode vti key "$${PLUTO_MARK_OUT%%/*}"
    ip link set "$${VTI_IF}" up
    ip addr add ${ubuntu_wan_ip}/32 dev "$${VTI_IF}"
    
    sysctl -w "net.ipv4.conf.$${VTI_IF}.disable_policy=1"
    sysctl -w "net.ipv4.conf.$${VTI_IF}.rp_filter=0"
    sysctl -w "net.ipv4.conf.all.rp_filter=0"
    
    ip rule add from ${ubuntu_wan_ip} lookup viatunicmp 2>/dev/null || true
    ip route add default dev "$${VTI_IF}" table viatunicmp 2>/dev/null || true
    ;;
  down-client)
    ip tunnel del "$${VTI_IF}"
    ip route del default dev "$${VTI_IF}" table viatunicmp 2>/dev/null || true
    
    if [ ! -d /sys/class/net/vti0 ] && [ ! -d /sys/class/net/vti1 ]; then
      ip rule del from ${ubuntu_wan_ip} lookup viatunicmp 2>/dev/null || true
    fi
    ;;
esac
echo "VTI interface status changed successfully"
VTISCRIPT

chmod +x /etc/strongswan.d/ipsec-vti.sh
if command -v chcon >/dev/null 2>&1; then
  chcon -t bin_t /etc/strongswan.d/ipsec-vti.sh 2>/dev/null || true
fi

# ─── 9. Apply Firewall TCP MSS Clamping ───
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1387 2>/dev/null || true
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1387

# ─── 10. Boot strongSwan Daemon ───
# Dynamically find the ipsec binary in the system PATH
IPSEC_BIN=$(command -v ipsec || echo "/usr/local/sbin/ipsec")

$IPSEC_BIN restart

# ─── 11. Synchronous Operational Health Check Gate ───
echo "============================================================"
echo "Terraform Verification: Waiting for IPsec tunnels to establish..."
echo "============================================================"

TIMEOUT=60
INTERVAL=5
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
  CURRENT_STATUS=$($IPSEC_BIN status 2>&1 || true)
  
  if echo "$CURRENT_STATUS" | grep -q "strongSwan-vpn-1.*ESTABLISHED" && \
     echo "$CURRENT_STATUS" | grep -q "strongSwan-vpn-2.*ESTABLISHED"; then
    echo "------------------------------------------------------------"
    echo "SUCCESS: Both Post-Quantum tunnels are securely ESTABLISHED!"
    echo "------------------------------------------------------------"
    $IPSEC_BIN status
    exit 0
  fi
  
  echo "Handshake pending... Retrying in $${INTERVAL}s ($${ELAPSED}/$${TIMEOUT}s)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "============================================================"
echo "CRITICAL ERROR: Tunnels failed to establish within $${TIMEOUT} seconds."
echo "Halting Terraform deployment state."
echo "============================================================"
echo "--- Diagnostic Log Dump ---"
$IPSEC_BIN statusall || true
echo "----------------------------"

exit 1
