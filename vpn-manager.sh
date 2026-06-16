#!/bin/bash
# VPN Server Manager (IKEv2, L2TP, PPTP)
# Поддерживает Debian/Ubuntu и RHEL/CentOS/AlmaLinux

# Авто-эскалация прав (если запущен не под root)
if [[ $EUID -ne 0 ]]; then
   echo "Запуск скрипта требует прав root. Запрашиваем sudo..."
   exec sudo "$0" "$@"
fi

function press_enter() {
    echo ""
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

# Определение ОС
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
    OS_ID_LIKE=$ID_LIKE
else
    echo "Не удалось определить ОС. Скрипт поддерживает только современные Linux дистрибутивы с /etc/os-release."
    exit 1
fi

if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$OS_ID_LIKE" == *"debian"* ]]; then
    OS_FAMILY="debian"
elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "almalinux" || "$OS_ID" == "rocky" || "$OS_ID_LIKE" == *"rhel"* || "$OS_ID_LIKE" == *"centos"* || "$OS_ID_LIKE" == *"fedora"* ]]; then
    OS_FAMILY="rhel"
else
    echo "Ваша операционная система ($OS_ID) пока не поддерживается."
    exit 1
fi

function install_vpn() {
    clear
    echo "Начинаем установку VPN сервера для ОС семейства: $OS_FAMILY"
    
    # 1. Установка пакетов в зависимости от ОС
    if [ "$OS_FAMILY" == "debian" ]; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            strongswan strongswan-pki libcharon-extra-plugins libcharon-extauth-plugins \
            xl2tpd pptpd ppp iptables iptables-persistent curl openssl
    elif [ "$OS_FAMILY" == "rhel" ]; then
        dnf install -y epel-release
        # On RHEL 8+, PowerTools/CRB might be needed for some packages, but epel usually suffices for pptpd and xl2tpd.
        dnf install -y strongswan xl2tpd pptpd ppp firewalld curl openssl tar
        systemctl enable firewalld --now
    fi

    PUBLIC_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)
    if [ -z "$PUBLIC_IP" ]; then
        read -p "Не удалось определить публичный IP. Введите IP сервера: " PUBLIC_IP
    fi
    PSK=$(openssl rand -base64 16 | tr -d '+/' | cut -c 1-16)

    echo "$PUBLIC_IP" > /etc/vpn-ip.txt
    echo "$PSK" > /etc/vpn-psk.txt

    # IP Forwarding
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p

    # StrongSwan конфиги (общие)
cat > /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

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

conn IKEv1-XAUTH
    keyexchange=ikev1
    left=%any
    leftauth=psk
    leftsubnet=0.0.0.0/0
    right=%any
    rightauth=psk
    rightauth2=xauth
    rightsourceip=10.10.40.0/24
    rightdns=8.8.8.8,8.8.4.4
    auto=add
EOF

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

    # Пути сертификатов зависят от ОС (в rhel иногда /etc/strongswan/)
    IPSEC_D="/etc/ipsec.d"
    if [ -d /etc/strongswan/ipsec.d ]; then
        IPSEC_D="/etc/strongswan/ipsec.d"
        # Симлинки для конфигов RHEL если нужно
        ln -sf /etc/ipsec.conf /etc/strongswan/ipsec.conf
        ln -sf /etc/ipsec.secrets /etc/strongswan/ipsec.secrets
    fi

    cp ~/pki/cacerts/ca-cert.pem $IPSEC_D/cacerts/
    cp ~/pki/certs/server-cert.pem $IPSEC_D/certs/
    cp ~/pki/private/server-key.pem $IPSEC_D/private/

cat > /etc/ipsec.secrets <<EOF
: RSA "server-key.pem"
%any %any : PSK "$PSK"
EOF

    # xl2tpd конфиг
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

    # pptpd конфиг
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

    # Фаервол и NAT
    if [ "$OS_FAMILY" == "debian" ]; then
        ETH=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
        iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o $ETH -j MASQUERADE
        iptables -t nat -A POSTROUTING -s 10.10.20.0/24 -o $ETH -j MASQUERADE
        iptables -t nat -A POSTROUTING -s 10.10.30.0/24 -o $ETH -j MASQUERADE
        iptables -t nat -A POSTROUTING -s 10.10.40.0/24 -o $ETH -j MASQUERADE
        netfilter-persistent save
    elif [ "$OS_FAMILY" == "rhel" ]; then
        firewall-cmd --permanent --add-masquerade
        # Разрешаем службы
        firewall-cmd --permanent --add-service=ipsec
        firewall-cmd --permanent --add-port=1701/udp
        firewall-cmd --permanent --add-port=500/udp
        firewall-cmd --permanent --add-port=4500/udp
        firewall-cmd --permanent --add-port=1723/tcp
        firewall-cmd --reload
    fi

    # Запуск служб
    systemctl enable xl2tpd pptpd --now
    systemctl restart xl2tpd pptpd

    if systemctl is-active --quiet strongswan-starter; then
        systemctl enable strongswan-starter --now
        systemctl restart strongswan-starter
    elif systemctl is-active --quiet strongswan; then
        systemctl enable strongswan --now
        systemctl restart strongswan
    else
        ipsec restart 2>/dev/null
    fi

    echo "УСТАНОВКА ЗАВЕРШЕНА!"
    press_enter
}

function manage_users() {
    while true; do
        clear
        echo "======================================"
        echo "        УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ      "
        echo "======================================"
        echo " 1. Добавить пользователя"
        echo " 2. Удалить пользователя"
        echo " 3. Список пользователей"
        echo " 0. Назад"
        echo "======================================"
        read -p "Выберите: " u_choice
        case $u_choice in
            1)
                read -p "Имя пользователя: " USER
                read -p "Пароль: " PASS
                sed -i "/^$USER /d" /etc/ppp/chap-secrets 2>/dev/null || true
                sed -i "/^$USER /d" /etc/ipsec.secrets 2>/dev/null || true
                echo "$USER l2tpd $PASS *" >> /etc/ppp/chap-secrets
                echo "$USER pptpd $PASS *" >> /etc/ppp/chap-secrets
                echo "$USER : EAP \"$PASS\"" >> /etc/ipsec.secrets
                echo "$USER : XAUTH \"$PASS\"" >> /etc/ipsec.secrets
                ipsec secrets > /dev/null 2>&1 || true
                echo "Пользователь $USER добавлен."
                press_enter
                ;;
            2)
                read -p "Имя пользователя для удаления: " USER
                sed -i "/^$USER /d" /etc/ppp/chap-secrets 2>/dev/null || true
                sed -i "/^$USER /d" /etc/ipsec.secrets 2>/dev/null || true
                ipsec secrets > /dev/null 2>&1 || true
                echo "Пользователь $USER удален."
                press_enter
                ;;
            3)
                echo "Список пользователей:"
                if [ -f /etc/ppp/chap-secrets ]; then
                    awk '{print $1}' /etc/ppp/chap-secrets | grep -v '^#' | sort -u
                fi
                press_enter
                ;;
            0) break ;;
            *) ;;
        esac
    done
}

function server_info() {
    clear
    echo "======================================"
    echo "          ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ       "
    echo "======================================"
    if [ -f /etc/vpn-ip.txt ]; then
        echo "IP-адрес сервера: $(cat /etc/vpn-ip.txt)"
        echo "IPsec Общий ключ (PSK): $(cat /etc/vpn-psk.txt)"
    else
        echo "VPN еще не установлен."
    fi
    press_enter
}

function remove_vpn() {
    clear
    read -p "Вы уверены, что хотите удалить VPN? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo "Удаление..."
        systemctl stop strongswan-starter strongswan xl2tpd pptpd 2>/dev/null
        
        if [ "$OS_FAMILY" == "debian" ]; then
            apt-get remove --purge -y strongswan strongswan-pki libcharon-extra-plugins libcharon-extauth-plugins xl2tpd pptpd
            apt-get autoremove -y
            ETH=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
            iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o $ETH -j MASQUERADE 2>/dev/null
            iptables -t nat -D POSTROUTING -s 10.10.20.0/24 -o $ETH -j MASQUERADE 2>/dev/null
            iptables -t nat -D POSTROUTING -s 10.10.30.0/24 -o $ETH -j MASQUERADE 2>/dev/null
            iptables -t nat -D POSTROUTING -s 10.10.40.0/24 -o $ETH -j MASQUERADE 2>/dev/null
            netfilter-persistent save 2>/dev/null
        elif [ "$OS_FAMILY" == "rhel" ]; then
            dnf remove -y strongswan xl2tpd pptpd
            dnf autoremove -y
            firewall-cmd --permanent --remove-masquerade
            firewall-cmd --permanent --remove-service=ipsec
            firewall-cmd --permanent --remove-port=1701/udp
            firewall-cmd --permanent --remove-port=500/udp
            firewall-cmd --permanent --remove-port=4500/udp
            firewall-cmd --permanent --remove-port=1723/tcp
            firewall-cmd --reload
        fi

        rm -rf /etc/ipsec.d/ /etc/strongswan/ipsec.d/ /etc/xl2tpd/ ~/pki /etc/vpn-ip.txt /etc/vpn-psk.txt
        rm -f /etc/ipsec.conf /etc/ipsec.secrets /etc/strongswan/ipsec.conf /etc/strongswan/ipsec.secrets
        rm -f /etc/pptpd.conf /etc/ppp/pptpd-options /etc/ppp/chap-secrets /etc/ppp/options.xl2tpd
        
        echo "Удалено."
    else
        echo "Отменено."
    fi
    press_enter
}

# Главное меню
while true; do
    clear
    echo "======================================="
    echo "        VPN SERVER MANAGER v1.1        "
    echo "    (ОС: $OS_ID_LIKE $OS_ID - $OS_FAMILY)  "
    echo "======================================="
    echo " 1. Установить VPN сервер"
    echo " 2. Управление пользователями"
    echo " 3. Данные сервера (IP, PSK)"
    echo " 4. Удалить VPN сервер"
    echo " 0. Выход"
    echo "======================================="
    read -p "Выберите действие (0-4): " choice

    case $choice in
        1) install_vpn ;;
        2) manage_users ;;
        3) server_info ;;
        4) remove_vpn ;;
        0) clear; exit 0 ;;
        *) echo "Неверный выбор!"; sleep 1 ;;
    esac
done
