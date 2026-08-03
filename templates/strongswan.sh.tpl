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
  dnf install -y gcc make gmp-devel openssl-devel iptables iproute wget bzip2 tar perl

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

# ─── 2. Kernel IP Forwarding & Module Activation ───
echo "Enabling Kernel IP Forwarding..."
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-strongswan.conf
sysctl --system

echo "Loading VTI kernel modules..."
modprobe ip_vti

if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
  if ! grep -q "ip_vti" /etc/modules 2>/dev/null; then
    echo "ip_vti" >> /etc/modules
  fi
elif [[ "$OS_ID" == "ol" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" || "$OS_ID" == "centos" ]]; then
  echo "ip_vti" > /etc/modules-load.d/ip_vti.conf
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
  leftid=@${t.fqdn_id}
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
@${t.fqdn_id} : PSK "${t.psk}"
%{ endfor ~}
EOF

# ─── 7. Base Safety Gate Policies ───
ip rule add ipproto tcp sport 22 lookup main priority 5 2>/dev/null || true
%{ for i, t in tunnels ~}
ip rule add to ${t.remote_ip} lookup main priority 20 2>/dev/null || true
%{ endfor ~}

# ─── 8. Declarative Network Framework Initialization ───
%{ for i, t in tunnels ~}
ip tunnel del "${t.vti_if}" 2>/dev/null || true
ip tunnel add "${t.vti_if}" mode vti local "${t.local_ip}" remote "${t.remote_ip}" key "${t.mark}"
ip link set "${t.vti_if}" up
ip addr add "${t.customer_ip}/31" dev "${t.vti_if}"

sysctl -w "net.ipv4.conf.${t.vti_if}.disable_policy=1"
sysctl -w "net.ipv4.conf.${t.vti_if}.rp_filter=0"

if ! grep -q "${t.rt_table} table_${t.vti_if}" /etc/iproute2/rt_tables; then
  echo "${t.rt_table} table_${t.vti_if}" >> /etc/iproute2/rt_tables
fi
ip route replace default dev "${t.vti_if}" table "${t.rt_table}"

# High-priority symmetric check reply pinning rule
ip rule add from "${t.customer_ip}/32" lookup "${t.rt_table}" priority $((70 + ${i})) 2>/dev/null || true

if [ "${tunnel_flow_traffic_only}" = "true" ]; then
  ip rule add to 162.159.65.1/32 lookup "${t.rt_table}" priority $((80 + ${i})) 2>/dev/null || true
else
  ip rule add from 192.168.15.0/24 lookup "${t.rt_table}" priority $((80 + ${i})) 2>/dev/null || true
fi
%{ endfor ~}

# ─── 9. Build Runtime Up/Down Dynamic Link Failure Bouncer ───
mkdir -p /etc/strongswan.d
cat > /etc/strongswan.d/ipsec-vti.sh << 'VTISCRIPT'
#!/bin/bash
set -o nounset

# FIX: Applied double dollar escapes ($$) to keep Bash engine vars clear of Terraform interpolation
case "$${PLUTO_CONNECTION}" in
%{ for i, t in tunnels ~}
  *vpn-IKEv2-${i+1}*)
    VTI_IF="${t.vti_if}"
    CUSTOMER_IP="${t.customer_ip}"
    RT_TABLE="${t.rt_table}"
    RULE_PRIORITY_HC=$((70 + ${i}))
    RULE_PRIORITY_DP=$((80 + ${i}))
%{ if tunnel_flow_traffic_only == "true" ~}
    DP_RULE_MATCH="to 162.159.65.1/32"
%{ else ~}
    DP_RULE_MATCH="from 192.168.15.0/24"
%{ endif ~}
    ;;
%{ endfor ~}
  *)
    exit 0
    ;;
esac

case "$${PLUTO_VERB}" in
  up-client)
    ip link set "$${VTI_IF}" up || true
    # Re-add routing rules for this tunnel
    ip rule add from "$${CUSTOMER_IP}/32" lookup "$${RT_TABLE}" priority "$${RULE_PRIORITY_HC}" 2>/dev/null || true
    ip rule add $${DP_RULE_MATCH} lookup "$${RT_TABLE}" priority "$${RULE_PRIORITY_DP}" 2>/dev/null || true
    ;;
  down-client)
    ip link set "$${VTI_IF}" down || true
    # Remove routing rules so traffic falls through to WAN
    ip rule del from "$${CUSTOMER_IP}/32" lookup "$${RT_TABLE}" priority "$${RULE_PRIORITY_HC}" 2>/dev/null || true
    ip rule del $${DP_RULE_MATCH} lookup "$${RT_TABLE}" priority "$${RULE_PRIORITY_DP}" 2>/dev/null || true
    ;;
esac
VTISCRIPT

chmod +x /etc/strongswan.d/ipsec-vti.sh
if command -v chcon >/dev/null 2>&1; then
  chcon -t bin_t /etc/strongswan.d/ipsec-vti.sh 2>/dev/null || true
fi

# ─── 10. Apply Firewall TCP MSS Clamping ───
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1387 2>/dev/null || true
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1387

# ─── 11. Boot strongSwan Daemon ───
IPSEC_BIN=$(command -v ipsec || echo "/usr/local/sbin/ipsec")
$IPSEC_BIN stop || true
sleep 1
$IPSEC_BIN start
sleep 5

# ─── 12. Deploy Tunnel Health Watchdog Daemon ───
cat > /etc/strongswan.d/tunnel-watchdog.sh << 'WATCHDOG'
#!/bin/bash
set -o nounset

IPSEC_BIN=$(command -v ipsec || echo "/usr/local/sbin/ipsec")
CHECK_INTERVAL=15
LOG_TAG="tunnel-watchdog"

# Tunnel definitions (baked in by Terraform template)
declare -A TUNNEL_VTI TUNNEL_CUSTOMER_IP TUNNEL_RT_TABLE TUNNEL_HC_PRIO TUNNEL_DP_PRIO TUNNEL_DP_MATCH TUNNEL_STATE

%{ for i, t in tunnels ~}
TUNNEL_VTI[${i+1}]="${t.vti_if}"
TUNNEL_CUSTOMER_IP[${i+1}]="${t.customer_ip}"
TUNNEL_RT_TABLE[${i+1}]="${t.rt_table}"
TUNNEL_HC_PRIO[${i+1}]=$((70 + ${i}))
TUNNEL_DP_PRIO[${i+1}]=$((80 + ${i}))
%{ if tunnel_flow_traffic_only == "true" ~}
TUNNEL_DP_MATCH[${i+1}]="to 162.159.65.1/32"
%{ else ~}
TUNNEL_DP_MATCH[${i+1}]="from 192.168.15.0/24"
%{ endif ~}
TUNNEL_STATE[${i+1}]="unknown"
%{ endfor ~}

NUM_TUNNELS=${num_of_tunnels}

remove_rules() {
  local idx=$1
  ip rule del from "$${TUNNEL_CUSTOMER_IP[$idx]}/32" lookup "$${TUNNEL_RT_TABLE[$idx]}" priority "$${TUNNEL_HC_PRIO[$idx]}" 2>/dev/null || true
  ip rule del $${TUNNEL_DP_MATCH[$idx]} lookup "$${TUNNEL_RT_TABLE[$idx]}" priority "$${TUNNEL_DP_PRIO[$idx]}" 2>/dev/null || true
}

add_rules() {
  local idx=$1
  ip rule add from "$${TUNNEL_CUSTOMER_IP[$idx]}/32" lookup "$${TUNNEL_RT_TABLE[$idx]}" priority "$${TUNNEL_HC_PRIO[$idx]}" 2>/dev/null || true
  ip rule add $${TUNNEL_DP_MATCH[$idx]} lookup "$${TUNNEL_RT_TABLE[$idx]}" priority "$${TUNNEL_DP_PRIO[$idx]}" 2>/dev/null || true
}

while true; do
  STATUS=$($IPSEC_BIN status 2>&1 || true)

  for idx in $(seq 1 $NUM_TUNNELS); do
    if echo "$STATUS" | grep -q "strongSwan-vpn-IKEv2-$${idx}.*ESTABLISHED"; then
      if [ "$${TUNNEL_STATE[$idx]}" != "up" ]; then
        logger -t "$LOG_TAG" "Tunnel $${idx} (VTI=$${TUNNEL_VTI[$idx]}) is ESTABLISHED — ensuring rules are active"
        ip link set "$${TUNNEL_VTI[$idx]}" up 2>/dev/null || true
        add_rules "$idx"
        TUNNEL_STATE[$idx]="up"
      fi
    else
      if [ "$${TUNNEL_STATE[$idx]}" != "down" ]; then
        logger -t "$LOG_TAG" "Tunnel $${idx} (VTI=$${TUNNEL_VTI[$idx]}) is DOWN — removing rules for WAN fallback"
        ip link set "$${TUNNEL_VTI[$idx]}" down 2>/dev/null || true
        remove_rules "$idx"
        TUNNEL_STATE[$idx]="down"
      fi
    fi
  done

  sleep $CHECK_INTERVAL
done
WATCHDOG

chmod +x /etc/strongswan.d/tunnel-watchdog.sh
if command -v chcon >/dev/null 2>&1; then
  chcon -t bin_t /etc/strongswan.d/tunnel-watchdog.sh 2>/dev/null || true
fi

cat > /etc/systemd/system/tunnel-watchdog.service << 'SVCUNIT'
[Unit]
Description=IPsec Tunnel Health Watchdog
After=network.target

[Service]
Type=simple
ExecStart=/etc/strongswan.d/tunnel-watchdog.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCUNIT

systemctl daemon-reload
systemctl enable --now tunnel-watchdog.service

# ─── 13. Synchronous Operational Health Check Gate ───
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
echo "================────────────────────────────────────────────"
echo "--- Diagnostic Log Dump ---"
$IPSEC_BIN statusall || true
echo "----------------------------"

exit 1
