#!/bin/bash
set -e

echo "Starting StrongSwan installation..."

apt-get update
apt-get install -y strongswan strongswan-pki libcharon-extra-plugins iproute2

cat << 'EOF' > /etc/strongswan.conf
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

cat << 'EOF' > /etc/strongswan.d/ipsec-vti.sh
#!/bin/bash
set -o nounset
set -o errexit

VTI_IF="vti$${PLUTO_REQID}"

case "$${PLUTO_VERB}" in
    up-client)
        ip tunnel add "$${VTI_IF}" local "$${PLUTO_ME}" remote "$${PLUTO_PEER}" mode vti key "$${PLUTO_MARK_OUT%%/*}"
        ip link set "$${VTI_IF}" up
        
        if [ "$${PLUTO_CONNECTION}" = "cf-tunnel-1" ]; then
            ip addr add ${tunnel_1_inner_ip}/31 dev "$${VTI_IF}"
        elif [ "$${PLUTO_CONNECTION}" = "cf-tunnel-2" ]; then
            ip addr add ${tunnel_2_inner_ip}/31 dev "$${VTI_IF}"
        fi
        
        sysctl -w "net.ipv4.conf.$${VTI_IF}.disable_policy=1"
        ;;
    down-client)
        ip tunnel del "$${VTI_IF}"
        ;;
esac
EOF
chmod +x /etc/strongswan.d/ipsec-vti.sh

cat << EOF > /etc/ipsec.conf
config setup
    charondebug="all"
    uniqueids=yes

conn %default
    ikelifetime=24h
    rekey=yes
    reauth=no
    keyexchange=ikev2
    authby=secret
    dpdaction=restart
    closeaction=restart
    ike=aes256-sha256-ecp384!
    esp=aes256-sha256-ecp384!
    fragmentation=no
    replay_window=0
    leftsubnet=0.0.0.0/0
    rightsubnet=0.0.0.0/0
    leftupdown=/etc/strongswan.d/ipsec-vti.sh

conn cf-tunnel-1
    left=${ubuntu_wan_ip}
    leftid=${ubuntu_wan_ip}
    right=${cf_anycast_1}
    rightid=${cf_anycast_1}
    mark_in=42
    mark_out=42
    reqid=1
    auto=start

conn cf-tunnel-2
    left=${ubuntu_wan_ip}
    leftid=${ubuntu_wan_ip}
    right=${cf_anycast_2}
    rightid=${cf_anycast_2}
    mark_in=43
    mark_out=43
    reqid=2
    auto=start
EOF

cat << EOF > /etc/ipsec.secrets
${ubuntu_wan_ip} ${cf_anycast_1} : PSK "${psk_1}"
${ubuntu_wan_ip} ${cf_anycast_2} : PSK "${psk_2}"
EOF

systemctl restart strongswan-starter
systemctl enable strongswan-starter
