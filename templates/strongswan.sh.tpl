#!/bin/bash
set -o errexit
set -o nounset

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
  apt-get update
  apt-get install -y build-essential libgmp-dev libssl-dev iptables iproute2 wget bzip2 tar

  if command -v ufw >/dev/null 2>&1; then
    echo "Configuring UFW to ALLOW default transit forwarding and IPsec..."
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    ufw allow 500,4500/udp || true
    ufw reload || true
  fi

elif [[ "$OS_ID" == "ol" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" || "$OS_ID" == "centos" ]]; then
  dnf install -y gcc make gmp-devel openssl-devel iptables iproute wget bzip2 tar

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    echo "Configuring Firewalld to ALLOW transit forwarding and IPsec..."
    firewall-cmd --permanent --add-port=500/udp 2>/dev/null || true
    firewall-cmd --permanent --add-port=4500/udp 2>/dev/null || true
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

# ─── 2. Kernel IP Forwarding ───
echo "Enabling Kernel IP Forwarding..."
sysctl -w net.ipv4.ip_forward=1
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# ─── 3. Idempotent strongSwan 6 Installation Gating & Swap Allocation ───
if command -v ipsec >/dev/null 2>&1 && ipsec --version 2>&1 | grep -q "6.0.7" && command -v swanctl >/dev/null 2>&1; then
  echo "strongSwan 6.0.7 and swanctl utility are already installed and optimized. Skipping compilation phase."
else
  echo "strongSwan 6.0.7 or swanctl utility missing or mismatched. Proceeding with compilation from source..."
  
  TRIGGERED_SWAP=false
  if [ ! -f /swapfile ] && [ $(free -m | awk '/Mem:/ {print $2}') -le 2048 ]; then
    echo "Low physical memory profile detected. Engineering a temporary 2GB swap space to stabilize GCC..."
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    TRIGGERED_SWAP=true
  fi

  cd /tmp
  wget -q https://download.strongswan.org/strongswan-6.0.7.tar.bz2
  tar -xjf strongswan-6.0.7.tar.bz2
  cd strongswan-6.0.7

  ./configure --prefix=/usr --sysconfdir=/etc --enable-ml --enable-openssl --enable-stroke --enable-swanctl
  make
  make install

  cd /tmp
  rm -rf strongswan-6.0.7 strongswan-6.0.7.tar.bz2

  if [ "$TRIGGERED_SWAP" = true ]; then
    echo "Compilation secure. De-allocating temporary swap safety valve..."
    swapoff /swapfile || true
    rm -f /swapfile || true
  fi
fi

# ─── 4. Configure /etc/strongswan.conf ───
WAN_IF_1=$(ip -o addr show | grep "${remote_wan_ip_1}" | awk '{print $2}' | head -n 1 || true)
%{ if num_of_tunnels == 4 ~}
WAN_IF_2=$(ip -o addr show | grep "${remote_wan_ip_2}" | awk '{print $2}' | head -n 1 || true)
INTERFACES="$${WAN_IF_1},$${WAN_IF_2}"
%{ else ~}
INTERFACES="$${WAN_IF_1}"
%{ endif ~}

INTERFACES=$(echo "$INTERFACES" | sed 's/^,//;s/,$//')

cat > /etc/strongswan.conf << EOF
charon {
  install_routes = no
  install_virtual_ip = no
EOF

if [ -n "$INTERFACES" ]; then
  echo "  interfaces_use = $INTERFACES" >> /etc/strongswan.conf
fi

cat >> /etc/strongswan.conf << EOF
}
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
  keyingtries=%forever

%{ for i, t in tunnels ~}
conn strongSwan-vpn-IKEv2-${i+1}
  auto=start
  type=tunnel
  fragmentation=yes
  leftauth=psk
  left=%any
  leftid=@vpn${i+1}.${cloudflare_internal_account_id}.custom.ipsec.cloudflare.com
  leftsubnet=0.0.0.0/0
  right=${t.remote_ip}
  rightid=${t.remote_ip}
  rightsubnet=0.0.0.0/0
  rightauth=psk
  ike=aes256gcm16-sha256-ecp384-ke1_mlkem768!
  esp=aes256gcm16-ecp384!
  replay_window=0
  mark_in=${t.mark}
  mark_out=${t.mark}
  leftupdown=/etc/strongswan.d/ipsec-vti.sh

%{ endfor ~}
EOF

# ─── 6. Configure /etc/ipsec.secrets ───
cat > /etc/ipsec.secrets << 'EOF'
%{ for i, t in tunnels ~}
@vpn${i+1}.${cloudflare_internal_account_id}.custom.ipsec.cloudflare.com : PSK "${t.psk}"
%{ endfor ~}
EOF

# ─── 7. Define Explicit Policy Routing Table & SSH Protection ───
ip rule add ipproto tcp sport 22 lookup main priority 5 2>/dev/null || true

%{ for i, t in tunnels ~}
ip rule add to ${t.remote_ip} lookup main priority 20 2>/dev/null || true
%{ endfor ~}

# ─── 8. Configure /etc/strongswan.d/ipsec-vti.sh ───
mkdir -p /etc/strongswan.d
cat > /etc/strongswan.d/ipsec-vti.sh << 'VTISCRIPT'
#!/bin/bash
set -o nounset
set -o errexit

case "$${PLUTO_CONNECTION}" in
%{ for i, t in tunnels ~}
  *vpn-IKEv2-${i+1}*)
    VTI_IF="${t.vti_if}"
    LOCAL_WAN_IP="${t.local_ip}"
    CUSTOMER_IP="${t.customer_ip}"
    RT_TABLE="${t.rt_table}"
    VTI_MARK="${t.mark}"
    PRIORITY_NUM=$((80 + ${i}))
    ;;
%{ endfor ~}
  *)
    VTI_IF="vti1"
    LOCAL_WAN_IP="${remote_wan_ip_1}"
    CUSTOMER_IP="${tunnels[0].customer_ip}"
    RT_TABLE="${tunnels[0].rt_table}"
    VTI_MARK="${tunnels[0].mark}"
    PRIORITY_NUM=80
    ;;
esac

case "$${PLUTO_VERB}" in
  up-client)
    ip tunnel del "$${VTI_IF}" 2>/dev/null || true
    ip tunnel add "$${VTI_IF}" local "$${PLUTO_ME}" remote "$${PLUTO_PEER}" mode vti key "$${VTI_MARK}"
    ip link set "$${VTI_IF}" up
    
    ip addr add "$${CUSTOMER_IP}/31" dev "$${VTI_IF}" || true
    ip addr add "$${LOCAL_WAN_IP}/32" dev "$${VTI_IF}" || true
    
    sysctl -w "net.ipv4.conf.$${VTI_IF}.disable_policy=1"
    sysctl -w "net.ipv4.conf.$${VTI_IF}.rp_filter=0"
    sysctl -w "net.ipv4.conf.all.rp_filter=0"
    
    if ! grep -q "$${RT_TABLE} table_$${VTI_IF}" /etc/iproute2/rt_tables; then
      echo "$${RT_TABLE} table_$${VTI_IF}" >> /etc/iproute2/rt_tables
    fi
    
    # Core Health Check Rule
    ip rule add from $${LOCAL_WAN_IP} lookup "$${RT_TABLE}" priority 100 2>/dev/null || true
    ip route add default dev "$${VTI_IF}" table "$${RT_TABLE}" 2>/dev/null || true
    
    # ─── Dynamic Condition Selector Logic ───
    if [ "${tunnel_flow_traffic_only}" = "true" ]; then
      # Mode 1: Intercept ONLY Flow Telemetry Traffic (Anycast Target IP)
      echo "Routing configuration: Directing ONLY flow logging destination 162.159.65.1 to $${VTI_IF}"
      ip rule add to 162.159.65.1/32 lookup "$${RT_TABLE}" priority "$${PRIORITY_NUM}" 2>/dev/null || true
    else
      # Mode 2: Intercept ALL traffic from local LAN subnet (Acts as local default gateway)
      echo "Routing configuration: Directing ALL transit traffic from LAN 192.168.15.0/24 to $${VTI_IF}"
      ip rule add from 192.168.15.0/24 lookup "$${RT_TABLE}" priority "$${PRIORITY_NUM}" 2>/dev/null || true
    fi
    ;;
  down-client)
    ip tunnel del "$${VTI_IF}" || true
    ip rule del from $${LOCAL_WAN_IP} lookup "$${RT_TABLE}" priority 100 2>/dev/null || true
    
    if [ "${tunnel_flow_traffic_only}" = "true" ]; then
      ip rule del to 162.159.65.1/32 lookup "$${RT_TABLE}" priority "$${PRIORITY_NUM}" 2>/dev/null || true
    else
      ip rule del from 192.168.15.0/24 lookup "$${RT_TABLE}" priority "$${PRIORITY_NUM}" 2>/dev/null || true
    fi
    sudo sed -i "/table_$${VTI_IF}/d" /etc/iproute2/rt_tables || true
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
IPSEC_BIN=$(command -v ipsec || echo "/usr/local/sbin/ipsec")
$IPSEC_BIN stop || true
sleep 1
$IPSEC_BIN start
sleep 5

# ─── 11. Synchronous Operational Health Check Gate ───
echo "============================================================"
echo "Terraform Verification: Waiting for IPsec tunnels to establish..."
echo "============================================================"

TIMEOUT=300
INTERVAL=5
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
  CURRENT_STATUS=$($IPSEC_BIN status 2>&1 || true)
  ALL_ESTABLISHED=true
  
  %{ for i, t in tunnels ~}
  if ! echo "$CURRENT_STATUS" | grep -q "strongSwan-vpn-IKEv2-${i+1}.*ESTABLISHED"; then
    ALL_ESTABLISHED=false
  fi
  %{ endfor ~}

  if [ "$ALL_ESTABLISHED" = true ]; then
    echo "------------------------------------------------------------"
    echo "SUCCESS: All Post-Quantum tunnels are securely ESTABLISHED!"
    echo "------------------------------------------------------------"
    $IPSEC_BIN status
    echo ""
    echo "--- swanctl Modern Status Map ---"
    swanctl --list-sas || true
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
