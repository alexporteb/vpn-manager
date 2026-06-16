#!/bin/bash

# Скрипт для управления пользователями VPN (IKEv2, IKEv1, L2TP, PPTP)
# Работает с /etc/ipsec.secrets и /etc/ppp/chap-secrets

if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт необходимо запускать от имени root (используйте sudo)"
   exit 1
fi

ACTION=$1
USER=$2
PASS=$3

show_help() {
    echo "Использование:"
    echo "  $0 add <username> <password>  - Добавить нового пользователя"
    echo "  $0 del <username>             - Удалить пользователя"
    echo "  $0 list                       - Показать всех пользователей"
}

if [ -z "$ACTION" ]; then
    show_help
    exit 1
fi

case "$ACTION" in
    add)
        if [ -z "$USER" ] || [ -z "$PASS" ]; then
            echo "Ошибка: Укажите имя пользователя и пароль."
            show_help
            exit 1
        fi

        # Удаляем, если уже есть, чтобы обновить пароль
        sed -i "/^$USER /d" /etc/ppp/chap-secrets
        sed -i "/^$USER /d" /etc/ipsec.secrets

        # Добавляем для L2TP/PPTP
        echo "$USER l2tpd $PASS *" >> /etc/ppp/chap-secrets
        echo "$USER pptpd $PASS *" >> /etc/ppp/chap-secrets
        # Добавляем для IKEv2
        echo "$USER : EAP \"$PASS\"" >> /etc/ipsec.secrets

        # Применяем настройки (только для ipsec, ppp подхватит на лету)
        ipsec secrets > /dev/null 2>&1
        
        echo "Пользователь $USER успешно добавлен!"
        ;;
    del)
        if [ -z "$USER" ]; then
            echo "Ошибка: Укажите имя пользователя."
            show_help
            exit 1
        fi

        sed -i "/^$USER /d" /etc/ppp/chap-secrets
        sed -i "/^$USER /d" /etc/ipsec.secrets
        
        ipsec secrets > /dev/null 2>&1
        echo "Пользователь $USER успешно удален!"
        ;;
    list)
        echo "Список пользователей VPN:"
        echo "--------------------------"
        awk '{print $1}' /etc/ppp/chap-secrets | grep -v '^#' | sort -u
        ;;
    *)
        echo "Неизвестная команда."
        show_help
        exit 1
        ;;
esac
