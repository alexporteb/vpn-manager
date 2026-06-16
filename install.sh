#!/bin/bash
# Загрузчик интерактивного меню VPN (vpn-manager)

if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт необходимо запускать от имени root (используйте sudo)" 
   exit 1
fi

echo "Скачивание VPN Manager..."
curl -sL https://raw.githubusercontent.com/alexporteb/vpn/main/vpn-manager.sh -o /usr/local/bin/vpn
chmod +x /usr/local/bin/vpn

echo "Готово! Теперь в любой момент вы можете ввести команду:"
echo "  sudo vpn"
echo "Чтобы открыть интерактивное меню настройки."

# Сразу запускаем меню после скачивания
echo "Запуск интерфейса..."
if [ -t 0 ]; then
    /usr/local/bin/vpn
elif [ -c /dev/tty ]; then
    /usr/local/bin/vpn </dev/tty
else
    echo "Не удалось открыть интерактивное меню."
    echo "Пожалуйста, введите в терминале команду: sudo vpn"
fi
