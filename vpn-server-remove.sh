#!/bin/bash
# VPN Server Remover
# Удостоверьтесь, что скрипт запущен от root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт необходимо запускать от имени root (используйте sudo)" 
   exit 1
fi

echo "Начинаем удаление VPN сервера..."

# 1. Stop services
systemctl stop strongswan-starter 2>/dev/null || ipsec stop 2>/dev/null
systemctl stop xl2tpd 2>/dev/null
systemctl stop pptpd 2>/dev/null

# 2. Remove packages
apt-get remove --purge -y strongswan strongswan-pki libcharon-extra-plugins libcharon-extauth-plugins xl2tpd pptpd
apt-get autoremove -y

# 3. Clean up config files and certs
rm -rf /etc/ipsec.d/
rm -f /etc/ipsec.conf /etc/ipsec.secrets
rm -rf /etc/xl2tpd/
rm -rf ~/pki
rm -f /etc/pptpd.conf /etc/ppp/pptpd-options
rm -f /etc/ppp/chap-secrets /etc/ppp/options.xl2tpd
rm -f /usr/local/bin/vpn-manage-users

# 4. Remove iptables rules (Assuming we added simple MASQUERADE rules)
# Get main interface
ETH=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o $ETH -j MASQUERADE 2>/dev/null
iptables -t nat -D POSTROUTING -s 10.10.20.0/24 -o $ETH -j MASQUERADE 2>/dev/null
iptables -t nat -D POSTROUTING -s 10.10.30.0/24 -o $ETH -j MASQUERADE 2>/dev/null
netfilter-persistent save 2>/dev/null

echo "======================================================"
echo "VPN сервер и все его компоненты успешно удалены!"
echo "======================================================"
