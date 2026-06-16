#!/bin/bash
# VPN Server Installer (IKEv2, IKEv1, L2TP, PPTP)
# Designed for Ubuntu/Debian

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт необходимо запускать от имени root (используйте sudo)" 
   exit 1
fi

echo "Начинаем установку VPN сервера..."

# 1. Update and install packages
echo "[1/6] Обновление системы и установка пакетов..."
apt-get update
# Prevent interactive prompts during apt install
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    strongswan \
    strongswan-pki \
    libcharon-extra-plugins \
    libcharon-extauth-plugins \
    xl2tpd \
    pptpd \
    ppp \
    iptables \
    iptables-persistent \
    curl \
    openssl

# 2. Get public IP and generate PSK
PUBLIC_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)
if [ -z "$PUBLIC_IP" ]; then
    read -p "Не удалось определить публичный IP. Введите публичный IP-адрес сервера: " PUBLIC_IP
fi
PSK=$(openssl rand -base64 16 | tr -d '+/' | cut -c 1-16)

echo "[2/6] Публичный IP: $PUBLIC_IP, Сгенерирован PSK: $PSK"

# 3. Configure IP Forwarding
echo "[3/6] Настройка переадресации IPv4..."
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
sysctl -p

# 4. Configure StrongSwan (IKEv2, IKEv1, L2TP/IPsec)
echo "[4/6] Настройка StrongSwan (IPsec)..."
cat > /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

# L2TP/IPsec (IKEv1)
conn L2TP-PSK
    authby=secret
    pfs=no
    auto=add
    keyingtries=3
    dpddelay=30
    dpdtimeout=120
    dpdaction=clear
    rekey=no
    ikelifetime=8h
    keylife=1h
    type=transport
    left=%any
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any

# IKEv2
conn IKEv2
    keyexchange=ikev2
    dpdaction=clear
    dpddelay=300s
    rekey=no
    left=%any
    leftid=$PUBLIC_IP
    leftsubnet=0.0.0.0/0
    leftauth=pubkey
    leftcert=server-cert.pem
    leftsendcert=always
    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=10.10.10.0/24
    rightdns=8.8.8.8,8.8.4.4
    rightsendcert=never
    eap_identity=%identity
    auto=add
EOF

# Generating Certificates for IKEv2
mkdir -p ~/pki/{cacerts,certs,private}
chmod 700 ~/pki
ipsec pki --gen --type rsa --size 4096 --outform pem > ~/pki/private/ca-key.pem
ipsec pki --self --ca --lifetime 3650 --in ~/pki/private/ca-key.pem \
          --type rsa --dn "CN=VPN root CA" --outform pem > ~/pki/cacerts/ca-cert.pem
ipsec pki --gen --type rsa --size 4096 --outform pem > ~/pki/private/server-key.pem
ipsec pki --pub --in ~/pki/private/server-key.pem --type rsa | \
    ipsec pki --issue --lifetime 1825 --cacert ~/pki/cacerts/ca-cert.pem \
              --cakey ~/pki/private/ca-key.pem \
              --dn "CN=$PUBLIC_IP" --san $PUBLIC_IP \
              --flag serverAuth --flag ikeIntermediate \
              --outform pem > ~/pki/certs/server-cert.pem

cp ~/pki/cacerts/ca-cert.pem /etc/ipsec.d/cacerts/
cp ~/pki/certs/server-cert.pem /etc/ipsec.d/certs/
cp ~/pki/private/server-key.pem /etc/ipsec.d/private/

# Secret config
cat > /etc/ipsec.secrets <<EOF
: RSA "server-key.pem"
%any %any : PSK "$PSK"
EOF

# 5. Configure xl2tpd & PPTP
echo "[5/6] Настройка L2TP и PPTP..."

# xl2tpd
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
ipsec saref = yes
[lns default]
ip range = 10.10.20.10-10.10.20.250
local ip = 10.10.20.1
require chap = yes
refuse pap = yes
require authentication = yes
name = LinuxVPN
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

cat > /etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 8.8.4.4
auth
mtu 1200
mru 1000
nodefaultroute
lock
nobsdcomp
novj
novjccomp
nologfd
EOF

# pptpd
cat > /etc/pptpd.conf <<EOF
option /etc/ppp/pptpd-options
logwtmp
localip 10.10.30.1
remoteip 10.10.30.10-250
EOF

cat > /etc/ppp/pptpd-options <<EOF
name pptpd
refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2
require-mppe-128
ms-dns 8.8.8.8
ms-dns 8.8.4.4
proxyarp
nodefaultroute
lock
nobsdcomp
novj
novjccomp
nologfd
EOF

# 6. Setup iptables rules
echo "[6/6] Настройка Iptables (NAT)..."
# Find main network interface
ETH=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

# Apply rules
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o $ETH -j MASQUERADE # IKEv2
iptables -t nat -A POSTROUTING -s 10.10.20.0/24 -o $ETH -j MASQUERADE # L2TP
iptables -t nat -A POSTROUTING -s 10.10.30.0/24 -o $ETH -j MASQUERADE # PPTP

# Save rules
netfilter-persistent save

# Restart services
systemctl restart strongswan-starter || ipsec restart
systemctl restart xl2tpd
systemctl restart pptpd

echo "======================================================"
echo "УСТАНОВКА ЗАВЕРШЕНА!"
echo "Ваш IP сервера: $PUBLIC_IP"
echo "Общий ключ (IPsec PSK): $PSK"
echo "Корневой сертификат для IKEv2 сохранен в: /etc/ipsec.d/cacerts/ca-cert.pem"
echo ""

# Download user management script
curl -sL https://raw.githubusercontent.com/alexporteb/vpn/main/vpn-manage-users.sh -o /usr/local/bin/vpn-manage-users
chmod +x /usr/local/bin/vpn-manage-users

echo "Для управления пользователями теперь доступна глобальная команда:"
echo "  sudo vpn-manage-users add <user> <pass>"
echo "  sudo vpn-manage-users del <user>"
echo "  sudo vpn-manage-users list"
echo "======================================================"
