#!/bin/bash
set -o errexit
set -o nounset

# ─── 1. Install Compilation & Network Dependencies ───
apt-get update && apt-get install -y build-essential libgmp-dev libssl-dev iptables iproute2 wget bzip2

# ─── 2. Compile strongSwan 6 from Source (with ML-KEM Support) ───
cd /tmp
wget -q https://download.strongswan.org/strongswan-6.0.7.tar.bz2
tar -xjf strongswan-6.0.7.tar.bz2
cd strongswan-6.0.7

./configure --prefix=/usr --sysconfdir=/etc --enable-ml --enable-openssl
make -j$(nproc)
make install

cd /tmp
rm -rf strongswan-6.0.7 strongswan-6.0.7.tar.bz2

# ─── 3. Configure /etc/strongswan.conf ───
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

# ─── 4. Configure /etc/ipsec.conf ───
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

# ─── 5. Configure /etc/ipsec.secrets ───
cat > /etc/ipsec.secrets << 'EOF'
${tunnel_1_id}.${cloudflare_account_id}.ipsec.cloudflare.com ${cf_anycast_1}/32 : PSK "${psk_1}"
${tunnel_2_id}.${cloudflare_account_id}.ipsec.cloudflare.com ${cf_anycast_2}/32 : PSK "${psk_2}"
EOF

# ─── 6. Define Explicit Policy Routing Table ───
if ! grep -q "viatunicmp" /etc/iproute2/rt_tables; then
  echo "200 viatunicmp" >> /etc/iproute2/rt_tables
fi

# ─── 7. Configure /etc/strongswan.d/ipsec-vti.sh ───
mkdir -p /etc/strongswan.d
cat > /etc/strongswan.d/ipsec-vti.sh << 'VTISCRIPT'
#!/bin/bash
set -o nounset
set -o errexit

# Evaluates the strongSwan system environment identifier
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
echo "executed"
VTISCRIPT

chmod +x /etc/strongswan.d/ipsec-vti.sh

# ─── 8. Apply Firewall TCP MSS Clamping ───
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1387 2>/dev/null || true
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1387

# ─── 9. Boot strongSwan Daemon ───
/usr/sbin/ipsec restart
