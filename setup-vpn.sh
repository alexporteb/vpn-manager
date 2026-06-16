#!/bin/bash
# ============================================================================
# setup-vpn.sh — Установка VPN-сервера и TUI-менеджера vpn-manager
# Протоколы: IKEv2, IKEv1, L2TP/IPsec, PPTP
# ОС: Ubuntu / Debian
# Запуск: sudo bash setup-vpn.sh
# ============================================================================

set -e

# ── Цвета ANSI ──────────────────────────────────────────────────────────────
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
MAGENTA='\e[35m'
CYAN='\e[36m'
WHITE='\e[97m'
BOLD='\e[1m'
DIM='\e[2m'
RESET='\e[0m'

# ── Проверка root ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}${BOLD}Ошибка: скрипт нужно запускать от root (sudo bash setup-vpn.sh)${RESET}"
    exit 1
fi

# ── Константы и пути ─────────────────────────────────────────────────────────
VPN_MANAGER_DIR="/etc/vpn-manager"
USERS_DB="${VPN_MANAGER_DIR}/users.db"
VPN_MANAGER_BIN="/usr/local/bin/vpn-manager"
PKI_DIR="/etc/ipsec.d"
CA_KEY="${PKI_DIR}/private/caKey.pem"
CA_CERT="${PKI_DIR}/cacerts/caCert.pem"
SERVER_KEY="${PKI_DIR}/private/serverKey.pem"
SERVER_CERT="${PKI_DIR}/certs/serverCert.pem"

# ── Определение внешнего IP ──────────────────────────────────────────────────
detect_external_ip() {
    local ip=""
    # Пробуем несколько сервисов для определения внешнего IP
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    # Если не удалось — берём IP с основного интерфейса
    ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    echo "$ip"
}

SERVER_IP=$(detect_external_ip)
if [[ -z "$SERVER_IP" ]]; then
    echo -e "${RED}Не удалось определить внешний IP-адрес. Введите вручную:${RESET}"
    read -r SERVER_IP
fi

echo -e "${CYAN}${BOLD}Обнаружен внешний IP: ${WHITE}${SERVER_IP}${RESET}"

# ── Генерация случайного PSK ────────────────────────────────────────────────
generate_psk() {
    # Если PSK уже сохранён, используем его (идемпотентность)
    if [[ -f "${VPN_MANAGER_DIR}/psk.conf" ]]; then
        cat "${VPN_MANAGER_DIR}/psk.conf"
    else
        openssl rand -base64 24 | tr -d '/+=' | head -c 20
    fi
}

# ============================================================================
# ФАЗА 1: УСТАНОВКА ПАКЕТОВ
# ============================================================================
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}${BOLD}  ФАЗА 1: Установка необходимых пакетов${RESET}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

# Установка пакетов (если уже установлены — пропускаются)
apt-get install -y -qq \
    strongswan \
    strongswan-pki \
    libcharon-extra-plugins \
    libcharon-extauth-plugins \
    libstrongswan-extra-plugins \
    xl2tpd \
    pptpd \
    iptables \
    iptables-persistent \
    ufw \
    curl \
    openssl \
    > /dev/null 2>&1

echo -e "${GREEN}✅ Все пакеты установлены${RESET}"

# ============================================================================
# ФАЗА 2: СОЗДАНИЕ ДИРЕКТОРИЙ
# ============================================================================
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}${BOLD}  ФАЗА 2: Подготовка директорий и базы пользователей${RESET}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"

mkdir -p "${VPN_MANAGER_DIR}"
mkdir -p "${PKI_DIR}/private"
mkdir -p "${PKI_DIR}/cacerts"
mkdir -p "${PKI_DIR}/certs"
mkdir -p "${PKI_DIR}/aacerts"
mkdir -p "${PKI_DIR}/ocspcerts"
mkdir -p "${PKI_DIR}/crls"

# Создаём файл базы пользователей если не существует
touch "${USERS_DB}"
chmod 600 "${USERS_DB}"

echo -e "${GREEN}✅ Директории готовы${RESET}"

# ============================================================================
# ФАЗА 3: ГЕНЕРАЦИЯ PKI СЕРТИФИКАТОВ ДЛЯ IKEv2
# ============================================================================
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}${BOLD}  ФАЗА 3: Генерация PKI сертификатов (IKEv2)${RESET}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"

# Генерация CA ключа и сертификата (если не существует — идемпотентность)
if [[ ! -f "${CA_KEY}" ]]; then
    echo -e "${DIM}  Генерация CA ключа...${RESET}"
    ipsec pki --gen --type rsa --size 4096 --outform pem > "${CA_KEY}"
    chmod 600 "${CA_KEY}"
else
    echo -e "${DIM}  CA ключ уже существует, пропускаем${RESET}"
fi

if [[ ! -f "${CA_CERT}" ]]; then
    echo -e "${DIM}  Генерация CA сертификата...${RESET}"
    ipsec pki --self --ca --lifetime 3650 \
        --in "${CA_KEY}" \
        --type rsa \
        --dn "CN=VPN Root CA" \
        --outform pem > "${CA_CERT}"
else
    echo -e "${DIM}  CA сертификат уже существует, пропускаем${RESET}"
fi

# Генерация серверного ключа и сертификата
if [[ ! -f "${SERVER_KEY}" ]]; then
    echo -e "${DIM}  Генерация серверного ключа...${RESET}"
    ipsec pki --gen --type rsa --size 4096 --outform pem > "${SERVER_KEY}"
    chmod 600 "${SERVER_KEY}"
else
    echo -e "${DIM}  Серверный ключ уже существует, пропускаем${RESET}"
fi

if [[ ! -f "${SERVER_CERT}" ]]; then
    echo -e "${DIM}  Генерация серверного сертификата...${RESET}"
    ipsec pki --pub --in "${SERVER_KEY}" --type rsa | \
    ipsec pki --issue --lifetime 1825 \
        --cacert "${CA_CERT}" \
        --cakey "${CA_KEY}" \
        --dn "CN=${SERVER_IP}" \
        --san "${SERVER_IP}" \
        --san "@${SERVER_IP}" \
        --flag serverAuth \
        --flag ikeIntermediate \
        --outform pem > "${SERVER_CERT}"
else
    echo -e "${DIM}  Серверный сертификат уже существует, пропускаем${RESET}"
fi

echo -e "${GREEN}✅ PKI сертификаты готовы${RESET}"

# ============================================================================
# ФАЗА 4: КОНФИГУРАЦИЯ strongSwan (IKEv2 / IKEv1)
# ============================================================================
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}${BOLD}  ФАЗА 4: Конфигурация strongSwan (IKEv2 / IKEv1)${RESET}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"

# Сохраняем PSK (идемпотентно)
PSK=$(generate_psk)
echo -n "${PSK}" > "${VPN_MANAGER_DIR}/psk.conf"
chmod 600 "${VPN_MANAGER_DIR}/psk.conf"

# Сохраняем IP сервера
echo -n "${SERVER_IP}" > "${VPN_MANAGER_DIR}/server_ip.conf"

# Конфигурация ipsec.conf
cat > /etc/ipsec.conf << 'IPSECCONF'
# ============================================================================
# /etc/ipsec.conf — конфигурация strongSwan (IKEv2 + IKEv1 + L2TP)
# Сгенерировано setup-vpn.sh
# ============================================================================

config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

# ── IKEv2 ──────────────────────────────────────────────────────────────────
conn ikev2-vpn
    auto=add
    compress=no
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    dpdaction=clear
    dpddelay=300s
    rekey=no
    left=%any
    leftid=SERVER_IP_PLACEHOLDER
    leftcert=serverCert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0
    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=10.10.10.0/24
    rightdns=8.8.8.8,8.8.4.4
    rightsendcert=never
    eap_identity=%identity
    ike=chacha20poly1305-sha512-curve25519-prfsha512,aes256gcm16-sha384-prfsha384-ecp384,aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024!
    esp=chacha20poly1305-sha512,aes256gcm16-ecp384,aes256-sha256,aes256-sha1,3des-sha1!

# ── IKEv1 (для совместимости) ──────────────────────────────────────────────
conn ikev1-vpn
    auto=add
    keyexchange=ikev1
    type=tunnel
    left=%any
    leftid=SERVER_IP_PLACEHOLDER
    leftcert=serverCert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0
    right=%any
    rightauth=psk
    rightauth2=xauth
    rightsourceip=10.10.11.0/24
    rightdns=8.8.8.8,8.8.4.4
    ike=aes256-sha1-modp1024!
    esp=aes256-sha1!

# ── L2TP/IPsec ────────────────────────────────────────────────────────────
conn l2tp-vpn
    auto=add
    keyexchange=ikev1
    type=transport
    left=%any
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    authby=secret
    rekey=no
    forceencaps=yes
IPSECCONF

# Подставляем реальный IP сервера
sed -i "s/SERVER_IP_PLACEHOLDER/${SERVER_IP}/g" /etc/ipsec.conf

# Конфигурация ipsec.secrets
# Формируем файл с нуля, но сохраняем пользователей из базы
cat > /etc/ipsec.secrets << IPSECSECRETS
# ============================================================================
# /etc/ipsec.secrets — учётные данные strongSwan
# Сгенерировано setup-vpn.sh. Управляется через vpn-manager.
# ============================================================================

# Серверный ключ
: RSA serverKey.pem

# PSK для L2TP/IKEv1
: PSK "${PSK}"

IPSECSECRETS

# Добавляем существующих пользователей из базы (для идемпотентности)
if [[ -s "${USERS_DB}" ]]; then
    while IFS=: read -r username password _psk; do
        [[ -z "$username" ]] && continue
        echo "${username} : EAP \"${password}\"" >> /etc/ipsec.secrets
        echo "${username} : XAUTH \"${password}\"" >> /etc/ipsec.secrets
    done < "${USERS_DB}"
fi

chmod 600 /etc/ipsec.secrets

echo -e "${GREEN}✅ strongSwan сконфигурирован${RESET}"

# ============================================================================
# ФАЗА 5: КОНФИГУРАЦИЯ xl2tpd (L2TP)
# ============================================================================
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}${BOLD}  ФАЗА 5: Конфигурация xl2tpd (L2TP)${RESET}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"

cat > /etc/xl2tpd/xl2tpd.conf << 'XL2TPDCONF'
; ============================================================================
; /etc/xl2tpd/xl2tpd.conf — конфигурация L2TP
; Сгенерировано setup-vpn.sh
; ============================================================================

[global]
ipsec saref = yes
saref refinfo = 30
port = 1701

[lns default]
ip range = 10.10.12.2-10.10.12.254
local ip = 10.10.12.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
XL2TPDCONF

# PPP опции для xl2tpd
cat > /etc/ppp/options.xl2tpd << 'PPPOPTIONS'
# ============================================================================
# /etc/ppp/options.xl2tpd — PPP опции для L2TP
# Сгенерировано setup-vpn.sh
# ============================================================================
ipcp-accept-local
ipcp-accept-remote
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 8.8.4.4
noccp
auth
hide-password
idle 1800
mtu 1410
mru 1410
nodefaultroute
debug
proxyarp
connect-delay 5000
PPPOPTIONS

# Добавляем пользователей L2TP из базы (файл chap-secrets)
# Формат: username * password *
# Не перезаписываем весь файл — очищаем только управляемый блок
# Удаляем старый управляемый блок
sed -i '/^# VPN-MANAGER-START/,/^# VPN-MANAGER-END/d' /etc/ppp/chap-secrets 2>/dev/null || true

{
    echo "# VPN-MANAGER-START"
    if [[ -s "${USERS_DB}" ]]; then
        while IFS=: read -r username password _psk; do
            [[ -z "$username" ]] && continue
            echo "${username} * ${password} *"
        done < "${USERS_DB}"
    fi
    echo "# VPN-MANAGER-END"
} >> /etc/ppp/chap-secrets

chmod 600 /etc/ppp/chap-secrets

echo -e "${GREEN}✅ xl2tpd сконфигурирован${RESET}"

# ============================================================================
# ФАЗА 6: КОНФИГУРАЦИЯ pptpd (PPTP)
# ============================================================================
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}${BOLD}  ФАЗА 6: Конфигурация pptpd (PPTP)${RESET}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"

cat > /etc/pptpd.conf << 'PPTPDCONF'
# ============================================================================
# /etc/pptpd.conf — конфигурация PPTP
# Сгенерировано setup-vpn.sh
# ============================================================================
option /etc/ppp/options.pptpd
logwtmp
localip 10.10.13.1
remoteip 10.10.13.2-254
PPTPDCONF

cat > /etc/ppp/options.pptpd << 'PPTPDPPP'
# ============================================================================
# /etc/ppp/options.pptpd — PPP опции для PPTP
# Сгенерировано setup-vpn.sh
# ============================================================================
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
PPTPDPPP

echo -e "${GREEN}✅ pptpd сконфигурирован${RESET}"

# ============================================================================
# ФАЗА 7: IP FORWARDING И SYSCTL
# ============================================================================
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}${BOLD}  ФАЗА 7: Настройка IP forwarding и sysctl${RESET}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"

# Включаем IP forwarding (идемпотентно)
SYSCTL_CONF="/etc/sysctl.d/99-vpn.conf"
cat > "${SYSCTL_CONF}" << 'SYSCTL'
# IP forwarding для VPN
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_ignore_bogus_error_responses = 1
SYSCTL

sysctl -p "${SYSCTL_CONF}" > /dev/null 2>&1

echo -e "${GREEN}✅ IP forwarding включён${RESET}"

# ============================================================================
# ФАЗА 8: НАСТРОЙКА FIREWALL (UFW + IPTABLES)
# ============================================================================
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}${BOLD}  ФАЗА 8: Настройка Firewall${RESET}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"

# Определяем основной сетевой интерфейс
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
if [[ -z "$DEFAULT_IFACE" ]]; then
    DEFAULT_IFACE="eth0"
fi
echo -e "${DIM}  Основной интерфейс: ${DEFAULT_IFACE}${RESET}"

# Настройка UFW — разрешаем VPN порты
ufw allow 500/udp   > /dev/null 2>&1  # IKE
ufw allow 4500/udp  > /dev/null 2>&1  # IPsec NAT-T
ufw allow 1701/udp  > /dev/null 2>&1  # L2TP
ufw allow 1723/tcp  > /dev/null 2>&1  # PPTP
ufw allow 22/tcp    > /dev/null 2>&1  # SSH (чтобы не потерять доступ)

# Добавляем NAT правила в UFW before.rules (идемпотентно)
UFW_BEFORE="/etc/ufw/before.rules"
if ! grep -q "VPN-MANAGER-NAT" "${UFW_BEFORE}" 2>/dev/null; then
    # Вставляем NAT-правила в начало файла (перед *filter)
    cat > /tmp/vpn-ufw-nat.tmp << UFWNAT
# VPN-MANAGER-NAT — BEGIN
*nat
-A POSTROUTING -s 10.10.10.0/24 -o ${DEFAULT_IFACE} -m policy --dir out --pol ipsec -j ACCEPT
-A POSTROUTING -s 10.10.10.0/24 -o ${DEFAULT_IFACE} -j MASQUERADE
-A POSTROUTING -s 10.10.11.0/24 -o ${DEFAULT_IFACE} -j MASQUERADE
-A POSTROUTING -s 10.10.12.0/24 -o ${DEFAULT_IFACE} -j MASQUERADE
-A POSTROUTING -s 10.10.13.0/24 -o ${DEFAULT_IFACE} -j MASQUERADE
COMMIT
# VPN-MANAGER-NAT — END

UFWNAT
    # Вставляем перед первой строкой *filter (или в начало файла)
    if grep -q '^\*filter' "${UFW_BEFORE}"; then
        sed -i "/^\*filter/r /tmp/vpn-ufw-nat.tmp" "${UFW_BEFORE}"
        # Перемещаем вставленный блок перед *filter
        # Проще: вставляем в самое начало
        sed -i '/^# VPN-MANAGER-NAT — BEGIN/,/^# VPN-MANAGER-NAT — END/{H;d}' "${UFW_BEFORE}"
        sed -i '1{x;s/^\n//;r /dev/stdin
        }' "${UFW_BEFORE}" < /dev/null || true
        # Упрощённый подход: просто добавляем в начало
        cp "${UFW_BEFORE}" "${UFW_BEFORE}.bak"
        cat /tmp/vpn-ufw-nat.tmp "${UFW_BEFORE}.bak" > "${UFW_BEFORE}"
    else
        cat /tmp/vpn-ufw-nat.tmp >> "${UFW_BEFORE}"
    fi
    rm -f /tmp/vpn-ufw-nat.tmp
fi

# Добавляем правила FORWARD в UFW before.rules (идемпотентно)
if ! grep -q "VPN-MANAGER-FORWARD" "${UFW_BEFORE}" 2>/dev/null; then
    # Вставляем перед строкой COMMIT в секции *filter
    sed -i '/^COMMIT$/i \
# VPN-MANAGER-FORWARD — BEGIN\
-A ufw-before-forward --match policy --pol ipsec --dir in --proto esp -s 10.10.10.0\/24 -j ACCEPT\
-A ufw-before-forward --match policy --pol ipsec --dir out --proto esp -d 10.10.10.0\/24 -j ACCEPT\
-A ufw-before-forward -s 10.10.11.0\/24 -j ACCEPT\
-A ufw-before-forward -s 10.10.12.0\/24 -j ACCEPT\
-A ufw-before-forward -s 10.10.13.0\/24 -j ACCEPT\
-A ufw-before-forward -d 10.10.11.0\/24 -j ACCEPT\
-A ufw-before-forward -d 10.10.12.0\/24 -j ACCEPT\
-A ufw-before-forward -d 10.10.13.0\/24 -j ACCEPT\
# VPN-MANAGER-FORWARD — END' "${UFW_BEFORE}" 2>/dev/null || true
fi

# Разрешаем forwarding в UFW
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/g' /etc/default/ufw 2>/dev/null || true

# Включаем UFW (если ещё не включён)
echo "y" | ufw enable > /dev/null 2>&1 || true
ufw reload > /dev/null 2>&1 || true

# Дополнительные iptables правила (на случай если UFW не обработает)
iptables -t nat -C POSTROUTING -s 10.10.10.0/24 -o "${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o "${DEFAULT_IFACE}" -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.10.11.0/24 -o "${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 10.10.11.0/24 -o "${DEFAULT_IFACE}" -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.10.12.0/24 -o "${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 10.10.12.0/24 -o "${DEFAULT_IFACE}" -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.10.13.0/24 -o "${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 10.10.13.0/24 -o "${DEFAULT_IFACE}" -j MASQUERADE

# Сохраняем iptables правила
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

echo -e "${GREEN}✅ Firewall настроен (UDP 500, 4500, 1701 / TCP 1723 / SSH 22)${RESET}"

# ============================================================================
# ФАЗА 9: ЗАПУСК СЛУЖБ
# ============================================================================
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}${BOLD}  ФАЗА 9: Запуск и активация служб${RESET}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"

# strongSwan
systemctl enable strongswan-starter 2>/dev/null || systemctl enable strongswan 2>/dev/null || systemctl enable ipsec 2>/dev/null || true
systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null || systemctl restart ipsec 2>/dev/null || true

# xl2tpd
systemctl enable xl2tpd 2>/dev/null || true
systemctl restart xl2tpd 2>/dev/null || true

# pptpd
systemctl enable pptpd 2>/dev/null || true
systemctl restart pptpd 2>/dev/null || true

echo -e "${GREEN}✅ Все службы запущены${RESET}"

# ============================================================================
# ФАЗА 10: УСТАНОВКА TUI-МЕНЕДЖЕРА vpn-manager
# ============================================================================
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}${BOLD}  ФАЗА 10: Установка vpn-manager${RESET}"
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${RESET}"

cat > "${VPN_MANAGER_BIN}" << 'VPNMANAGER'
#!/bin/bash
# ============================================================================
# vpn-manager — TUI-менеджер VPN-сервера
# Версия: 1.0
# ============================================================================

# ── Цвета ANSI ──────────────────────────────────────────────────────────────
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
MAGENTA='\e[35m'
CYAN='\e[36m'
WHITE='\e[97m'
BOLD='\e[1m'
DIM='\e[2m'
RESET='\e[0m'

# ── Константы ────────────────────────────────────────────────────────────────
VPN_MANAGER_DIR="/etc/vpn-manager"
USERS_DB="${VPN_MANAGER_DIR}/users.db"
PKI_DIR="/etc/ipsec.d"
CA_KEY="${PKI_DIR}/private/caKey.pem"
CA_CERT="${PKI_DIR}/cacerts/caCert.pem"

# ── Проверка root ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}${BOLD}Ошибка: vpn-manager требует root-права (sudo vpn-manager)${RESET}"
    exit 1
fi

# ── Загрузка конфигурации ────────────────────────────────────────────────────
SERVER_IP=$(cat "${VPN_MANAGER_DIR}/server_ip.conf" 2>/dev/null || echo "UNKNOWN")
PSK=$(cat "${VPN_MANAGER_DIR}/psk.conf" 2>/dev/null || echo "UNKNOWN")

# ── Утилиты ──────────────────────────────────────────────────────────────────
clear_screen() {
    clear
}

press_enter() {
    echo ""
    echo -e "${DIM}  Нажмите Enter для продолжения...${RESET}"
    read -r
}

# Получить статус службы (✅ или ❌)
get_service_status() {
    local service_name="$1"
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        echo -e "${GREEN}✅${RESET}"
    else
        echo -e "${RED}❌${RESET}"
    fi
}

# Определяем имя сервиса strongswan
get_strongswan_service() {
    if systemctl list-unit-files | grep -q "strongswan-starter"; then
        echo "strongswan-starter"
    elif systemctl list-unit-files | grep -q "strongswan.service"; then
        echo "strongswan"
    else
        echo "ipsec"
    fi
}

STRONGSWAN_SVC=$(get_strongswan_service)

# ── Генерация клиентского сертификата IKEv2 ──────────────────────────────────
generate_client_cert() {
    local username="$1"
    local client_key="${PKI_DIR}/private/${username}Key.pem"
    local client_cert="${PKI_DIR}/certs/${username}.crt"

    # Генерируем ключ клиента
    ipsec pki --gen --type rsa --size 2048 --outform pem > "${client_key}" 2>/dev/null
    chmod 600 "${client_key}"

    # Генерируем сертификат клиента
    ipsec pki --pub --in "${client_key}" --type rsa | \
    ipsec pki --issue --lifetime 730 \
        --cacert "${CA_CERT}" \
        --cakey "${CA_KEY}" \
        --dn "CN=${username}" \
        --san "${username}" \
        --outform pem > "${client_cert}" 2>/dev/null

    echo "${client_cert}"
}

# ── Добавление пользователя во все протоколы ─────────────────────────────────
add_user_to_protocols() {
    local username="$1"
    local password="$2"

    # 1. Сохраняем в базу (users.db)
    echo "${username}:${password}:${PSK}" >> "${USERS_DB}"

    # 2. strongSwan (IKEv2 EAP + IKEv1 XAUTH)
    echo "${username} : EAP \"${password}\"" >> /etc/ipsec.secrets
    echo "${username} : XAUTH \"${password}\"" >> /etc/ipsec.secrets

    # 3. Генерируем клиентский сертификат IKEv2
    generate_client_cert "${username}" > /dev/null 2>&1

    # 4. L2TP (chap-secrets) — добавляем внутри управляемого блока
    # Удаляем старый блок и пересоздаём
    sed -i '/^# VPN-MANAGER-START/,/^# VPN-MANAGER-END/d' /etc/ppp/chap-secrets 2>/dev/null || true
    {
        echo "# VPN-MANAGER-START"
        while IFS=: read -r u p _psk; do
            [[ -z "$u" ]] && continue
            echo "${u} * ${p} *"
        done < "${USERS_DB}"
        echo "# VPN-MANAGER-END"
    } >> /etc/ppp/chap-secrets

    # 5. Перезагружаем strongSwan для применения
    ipsec rereadall 2>/dev/null || true
    ipsec reload 2>/dev/null || true
}

# ── Удаление пользователя из всех протоколов ─────────────────────────────────
remove_user_from_protocols() {
    local username="$1"

    # 1. Удаляем из базы
    sed -i "/^${username}:/d" "${USERS_DB}"

    # 2. Удаляем из ipsec.secrets
    sed -i "/^${username} : EAP/d" /etc/ipsec.secrets
    sed -i "/^${username} : XAUTH/d" /etc/ipsec.secrets

    # 3. Удаляем сертификат
    rm -f "${PKI_DIR}/private/${username}Key.pem"
    rm -f "${PKI_DIR}/certs/${username}.crt"

    # 4. Пересоздаём chap-secrets
    sed -i '/^# VPN-MANAGER-START/,/^# VPN-MANAGER-END/d' /etc/ppp/chap-secrets 2>/dev/null || true
    {
        echo "# VPN-MANAGER-START"
        while IFS=: read -r u p _psk; do
            [[ -z "$u" ]] && continue
            echo "${u} * ${p} *"
        done < "${USERS_DB}"
        echo "# VPN-MANAGER-END"
    } >> /etc/ppp/chap-secrets

    # 5. Перезагружаем конфиги
    ipsec rereadall 2>/dev/null || true
    ipsec reload 2>/dev/null || true
}

# ── Показ карточки пользователя ──────────────────────────────────────────────
show_user_card() {
    local username="$1"
    local password="$2"
    local user_psk="$3"
    local client_cert="${PKI_DIR}/certs/${username}.crt"

    local title="ПОЛЬЗОВАТЕЛЬ: ${username}"
    local width=56

    clear_screen
    echo ""
    # Верхняя рамка
    printf "  ${CYAN}╔"
    printf '═%.0s' $(seq 1 $width)
    printf "╗${RESET}\n"

    # Заголовок с именем пользователя
    printf "  ${CYAN}║${RESET}${BOLD}${WHITE}"
    printf "%*s" $(( (width + ${#title}) / 2 )) "$title"
    printf "%*s" $(( (width - ${#title}) / 2 )) ""
    printf "${CYAN}║${RESET}\n"

    # Разделитель
    printf "  ${CYAN}╠"
    printf '═%.0s' $(seq 1 $width)
    printf "╣${RESET}\n"

    # ── IKEv2 / IKEv1 ──
    printf "  ${CYAN}║${RESET}                                                        ${CYAN}║${RESET}\n"
    printf "  ${CYAN}║${RESET}  ${MAGENTA}${BOLD}── IKEv2 / IKEv1 ──${RESET}%-*s${CYAN}║${RESET}\n" $((width - 21)) ""
    printf "  ${CYAN}║${RESET}  ${DIM}Сервер:${RESET}      ${WHITE}%-*s${CYAN}║${RESET}\n" $((width - 17)) "${SERVER_IP}"
    printf "  ${CYAN}║${RESET}  ${DIM}Логин:${RESET}       ${GREEN}%-*s${CYAN}║${RESET}\n" $((width - 17)) "${username}"
    printf "  ${CYAN}║${RESET}  ${DIM}Пароль:${RESET}      ${YELLOW}%-*s${CYAN}║${RESET}\n" $((width - 17)) "${password}"
    if [[ -f "${client_cert}" ]]; then
        printf "  ${CYAN}║${RESET}  ${DIM}Сертификат:${RESET}  ${BLUE}%-*s${CYAN}║${RESET}\n" $((width - 17)) "${client_cert}"
    fi
    printf "  ${CYAN}║${RESET}                                                        ${CYAN}║${RESET}\n"

    # ── L2TP/IPsec ──
    printf "  ${CYAN}║${RESET}  ${MAGENTA}${BOLD}── L2TP/IPsec ──${RESET}%-*s${CYAN}║${RESET}\n" $((width - 18)) ""
    printf "  ${CYAN}║${RESET}  ${DIM}Сервер:${RESET}      ${WHITE}%-*s${CYAN}║${RESET}\n" $((width - 17)) "${SERVER_IP}"
    printf "  ${CYAN}║${RESET}  ${DIM}PSK:${RESET}         ${YELLOW}%-*s${CYAN}║${RESET}\n" $((width - 17)) "${user_psk}"
    printf "  ${CYAN}║${RESET}  ${DIM}Логин:${RESET}       ${GREEN}%-*s${CYAN}║${RESET}\n" $((width - 17)) "${username}"
    printf "  ${CYAN}║${RESET}  ${DIM}Пароль:${RESET}      ${YELLOW}%-*s${CYAN}║${RESET}\n" $((width - 17)) "${password}"
    printf "  ${CYAN}║${RESET}                                                        ${CYAN}║${RESET}\n"

    # ── PPTP ──
    printf "  ${CYAN}║${RESET}  ${MAGENTA}${BOLD}── PPTP ──${RESET}%-*s${CYAN}║${RESET}\n" $((width - 12)) ""
    printf "  ${CYAN}║${RESET}  ${DIM}Сервер:${RESET}      ${WHITE}%-*s${CYAN}║${RESET}\n" $((width - 17)) "${SERVER_IP}"
    printf "  ${CYAN}║${RESET}  ${DIM}Логин:${RESET}       ${GREEN}%-*s${CYAN}║${RESET}\n" $((width - 17)) "${username}"
    printf "  ${CYAN}║${RESET}  ${DIM}Пароль:${RESET}      ${YELLOW}%-*s${CYAN}║${RESET}\n" $((width - 17)) "${password}"
    printf "  ${CYAN}║${RESET}  ${DIM}Шифрование:${RESET}  ${WHITE}%-*s${CYAN}║${RESET}\n" $((width - 17)) "MPPE 128-bit"
    printf "  ${CYAN}║${RESET}                                                        ${CYAN}║${RESET}\n"

    # Разделитель
    printf "  ${CYAN}╠"
    printf '═%.0s' $(seq 1 $width)
    printf "╣${RESET}\n"

    # Действия
    printf "  ${CYAN}║${RESET}  ${WHITE}[1]${RESET} Удалить пользователя%-*s${CYAN}║${RESET}\n" $((width - 25)) ""
    printf "  ${CYAN}║${RESET}  ${WHITE}[0]${RESET} Назад%-*s${CYAN}║${RESET}\n" $((width - 11)) ""

    # Нижняя рамка
    printf "  ${CYAN}╚"
    printf '═%.0s' $(seq 1 $width)
    printf "╝${RESET}\n"
    echo ""

    echo -ne "  ${BOLD}Выберите действие: ${RESET}"
    read -r action
    case "$action" in
        1)
            echo ""
            echo -ne "  ${RED}Вы уверены? Удалить пользователя '${username}'? (y/N): ${RESET}"
            read -r confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                remove_user_from_protocols "${username}"
                echo -e "  ${GREEN}✅ Пользователь '${username}' удалён из всех протоколов${RESET}"
            else
                echo -e "  ${DIM}Отменено${RESET}"
            fi
            press_enter
            ;;
        0|"")
            return
            ;;
        *)
            return
            ;;
    esac
}

# ── МЕНЮ: Добавить пользователя ──────────────────────────────────────────────
menu_add_user() {
    clear_screen
    echo ""
    echo -e "  ${CYAN}${BOLD}═══ ДОБАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ ═══${RESET}"
    echo ""

    # Ввод логина
    echo -ne "  ${WHITE}Логин: ${RESET}"
    read -r username

    # Валидация
    if [[ -z "$username" ]]; then
        echo -e "  ${RED}Ошибка: логин не может быть пустым${RESET}"
        press_enter
        return
    fi

    # Проверка на существование
    if grep -q "^${username}:" "${USERS_DB}" 2>/dev/null; then
        echo -e "  ${RED}Ошибка: пользователь '${username}' уже существует${RESET}"
        press_enter
        return
    fi

    # Ввод пароля
    echo -ne "  ${WHITE}Пароль: ${RESET}"
    read -r password

    if [[ -z "$password" ]]; then
        echo -e "  ${RED}Ошибка: пароль не может быть пустым${RESET}"
        press_enter
        return
    fi

    echo ""
    echo -e "  ${DIM}Добавление пользователя '${username}' во все протоколы...${RESET}"

    add_user_to_protocols "${username}" "${password}"

    echo -e "  ${GREEN}${BOLD}✅ Пользователь '${username}' успешно добавлен!${RESET}"
    echo ""
    press_enter

    # Показываем карточку пользователя
    show_user_card "${username}" "${password}" "${PSK}"
}

# ── МЕНЮ: Список пользователей ───────────────────────────────────────────────
menu_list_users() {
    while true; do
        clear_screen
        echo ""
        echo -e "  ${CYAN}${BOLD}═══ СПИСОК ПОЛЬЗОВАТЕЛЕЙ ═══${RESET}"
        echo ""

        # Проверяем, есть ли пользователи
        if [[ ! -s "${USERS_DB}" ]]; then
            echo -e "  ${DIM}Нет добавленных пользователей${RESET}"
            press_enter
            return
        fi

        # Выводим нумерованный список
        local i=1
        local users=()
        while IFS=: read -r username password user_psk; do
            [[ -z "$username" ]] && continue
            users+=("${username}:${password}:${user_psk}")
            echo -e "  ${WHITE}[${i}]${RESET} ${GREEN}${username}${RESET}"
            ((i++))
        done < "${USERS_DB}"

        echo ""
        echo -e "  ${WHITE}[0]${RESET} Назад в меню"
        echo ""
        echo -ne "  ${BOLD}Выберите пользователя: ${RESET}"
        read -r choice

        if [[ "$choice" == "0" || -z "$choice" ]]; then
            return
        fi

        # Проверяем валидность выбора
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#users[@]} )); then
            local selected="${users[$((choice-1))]}"
            IFS=: read -r sel_user sel_pass sel_psk <<< "$selected"
            show_user_card "${sel_user}" "${sel_pass}" "${sel_psk}"
        else
            echo -e "  ${RED}Неверный выбор${RESET}"
            press_enter
        fi
    done
}

# ── МЕНЮ: Статус служб ───────────────────────────────────────────────────────
menu_service_status() {
    clear_screen
    echo ""

    local sw_status=$(get_service_status "${STRONGSWAN_SVC}")
    local xl2_status=$(get_service_status "xl2tpd")
    local pptp_status=$(get_service_status "pptpd")
    local ufw_status
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw_status="${GREEN}✅${RESET}"
    else
        ufw_status="${RED}❌${RESET}"
    fi

    local width=42

    # Верхняя рамка
    printf "  ${CYAN}╔"
    printf '═%.0s' $(seq 1 $width)
    printf "╗${RESET}\n"

    # Заголовок
    printf "  ${CYAN}║${RESET}${BOLD}${WHITE}          СТАТУС СЛУЖБ                    ${CYAN}║${RESET}\n"

    # Разделитель
    printf "  ${CYAN}╠"
    printf '═%.0s' $(seq 1 $width)
    printf "╣${RESET}\n"

    # Статусы
    echo -e "  ${CYAN}║${RESET}  strongSwan (IKEv2/IKEv1):  ${sw_status}           ${CYAN}║${RESET}"
    echo -e "  ${CYAN}║${RESET}  xl2tpd     (L2TP):         ${xl2_status}           ${CYAN}║${RESET}"
    echo -e "  ${CYAN}║${RESET}  pptpd      (PPTP):         ${pptp_status}           ${CYAN}║${RESET}"
    echo -e "  ${CYAN}║${RESET}  Firewall   (ufw):          ${ufw_status}           ${CYAN}║${RESET}"

    # Нижняя рамка
    printf "  ${CYAN}╚"
    printf '═%.0s' $(seq 1 $width)
    printf "╝${RESET}\n"
    echo ""

    press_enter
}

# ── МЕНЮ: Перезапуск служб ───────────────────────────────────────────────────
menu_restart_services() {
    clear_screen
    echo ""
    echo -e "  ${CYAN}${BOLD}═══ ПЕРЕЗАПУСК СЛУЖБ ═══${RESET}"
    echo ""

    echo -e "  ${DIM}Перезапуск strongSwan...${RESET}"
    systemctl restart "${STRONGSWAN_SVC}" 2>/dev/null && \
        echo -e "  ${GREEN}✅ strongSwan перезапущен${RESET}" || \
        echo -e "  ${RED}❌ Ошибка перезапуска strongSwan${RESET}"

    echo -e "  ${DIM}Перезапуск xl2tpd...${RESET}"
    systemctl restart xl2tpd 2>/dev/null && \
        echo -e "  ${GREEN}✅ xl2tpd перезапущен${RESET}" || \
        echo -e "  ${RED}❌ Ошибка перезапуска xl2tpd${RESET}"

    echo -e "  ${DIM}Перезапуск pptpd...${RESET}"
    systemctl restart pptpd 2>/dev/null && \
        echo -e "  ${GREEN}✅ pptpd перезапущен${RESET}" || \
        echo -e "  ${RED}❌ Ошибка перезапуска pptpd${RESET}"

    echo -e "  ${DIM}Перезагрузка Firewall...${RESET}"
    ufw reload 2>/dev/null && \
        echo -e "  ${GREEN}✅ Firewall перезагружен${RESET}" || \
        echo -e "  ${RED}❌ Ошибка перезагрузки Firewall${RESET}"

    echo ""
    echo -e "  ${GREEN}${BOLD}Все службы перезапущены!${RESET}"

    press_enter
}

# ── ГЛАВНОЕ МЕНЮ ─────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear_screen

        # Определяем статусы для шапки
        local ikev2_flag
        local l2tp_flag
        local pptp_flag

        if systemctl is-active --quiet "${STRONGSWAN_SVC}" 2>/dev/null; then
            ikev2_flag="${GREEN}✅${RESET}"
        else
            ikev2_flag="${RED}❌${RESET}"
        fi
        if systemctl is-active --quiet xl2tpd 2>/dev/null; then
            l2tp_flag="${GREEN}✅${RESET}"
        else
            l2tp_flag="${RED}❌${RESET}"
        fi
        if systemctl is-active --quiet pptpd 2>/dev/null; then
            pptp_flag="${GREEN}✅${RESET}"
        else
            pptp_flag="${RED}❌${RESET}"
        fi

        local width=46
        echo ""

        # Верхняя рамка
        printf "  ${CYAN}╔"
        printf '═%.0s' $(seq 1 $width)
        printf "╗${RESET}\n"

        # Заголовок
        printf "  ${CYAN}║${RESET}${BOLD}${WHITE}         🔒 VPN MANAGER v1.0                ${CYAN}║${RESET}\n"
        echo -e "  ${CYAN}║${RESET}  Сервер: ${WHITE}${SERVER_IP}${RESET}$(printf '%*s' $((width - 12 - ${#SERVER_IP})) '')${CYAN}║${RESET}"
        echo -e "  ${CYAN}║${RESET}  IKEv2 ${ikev2_flag}  L2TP ${l2tp_flag}  PPTP ${pptp_flag}                  ${CYAN}║${RESET}"

        # Разделитель
        printf "  ${CYAN}╠"
        printf '═%.0s' $(seq 1 $width)
        printf "╣${RESET}\n"

        # Пункты меню
        printf "  ${CYAN}║${RESET}  ${WHITE}[1]${RESET} Добавить пользователя%-*s${CYAN}║${RESET}\n" $((width - 27)) ""
        printf "  ${CYAN}║${RESET}  ${WHITE}[2]${RESET} Список пользователей%-*s${CYAN}║${RESET}\n" $((width - 26)) ""
        printf "  ${CYAN}║${RESET}  ${WHITE}[3]${RESET} Статус служб%-*s${CYAN}║${RESET}\n" $((width - 17)) ""
        printf "  ${CYAN}║${RESET}  ${WHITE}[4]${RESET} Перезапустить службы%-*s${CYAN}║${RESET}\n" $((width - 25)) ""
        printf "  ${CYAN}║${RESET}  ${WHITE}[0]${RESET} Выход%-*s${CYAN}║${RESET}\n" $((width - 11)) ""

        # Нижняя рамка
        printf "  ${CYAN}╚"
        printf '═%.0s' $(seq 1 $width)
        printf "╝${RESET}\n"
        echo ""

        echo -ne "  ${BOLD}Выберите пункт: ${RESET}"
        read -r choice

        case "$choice" in
            1) menu_add_user ;;
            2) menu_list_users ;;
            3) menu_service_status ;;
            4) menu_restart_services ;;
            0) clear_screen; echo -e "\n  ${GREEN}${BOLD}До свидания! 👋${RESET}\n"; exit 0 ;;
            *) echo -e "  ${RED}Неверный выбор${RESET}"; sleep 1 ;;
        esac
    done
}

# ── Запуск ───────────────────────────────────────────────────────────────────
main_menu
VPNMANAGER

chmod +x "${VPN_MANAGER_BIN}"

echo -e "${GREEN}✅ vpn-manager установлен в ${VPN_MANAGER_BIN}${RESET}"

# ============================================================================
# ЗАВЕРШЕНИЕ УСТАНОВКИ
# ============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║          ✅ УСТАНОВКА VPN-СЕРВЕРА ЗАВЕРШЕНА!            ║${RESET}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}                                                          ${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}  ${WHITE}Сервер IP:${RESET}    ${CYAN}${SERVER_IP}${RESET}$(printf '%*s' $((34 - ${#SERVER_IP})) '')${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}  ${WHITE}PSK:${RESET}          ${YELLOW}${PSK}${RESET}$(printf '%*s' $((34 - ${#PSK})) '')${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}                                                          ${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}  ${WHITE}Протоколы:${RESET}    IKEv2, IKEv1, L2TP/IPsec, PPTP          ${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}  ${WHITE}Менеджер:${RESET}     ${CYAN}sudo vpn-manager${RESET}                       ${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}                                                          ${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}  ${WHITE}Подсети VPN:${RESET}                                          ${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}    IKEv2:  ${DIM}10.10.10.0/24${RESET}                                  ${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}    IKEv1:  ${DIM}10.10.11.0/24${RESET}                                  ${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}    L2TP:   ${DIM}10.10.12.0/24${RESET}                                  ${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}    PPTP:   ${DIM}10.10.13.0/24${RESET}                                  ${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}║${RESET}                                                          ${GREEN}${BOLD}║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""

echo -e "${CYAN}${BOLD}Запуск vpn-manager...${RESET}"
sleep 2

# Запускаем TUI-менеджер
exec "${VPN_MANAGER_BIN}"
