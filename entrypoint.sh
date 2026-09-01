#!/bin/sh
# Дефолтная точка входа для контейнеров nsbox (systemd-nspawn)

on_exit() {
    echo "Stopping background processes..."
    # Здесь выполнить необходимые действия для корректного завершения работы
    # и/или отправить сигнал SIGTERM (15) для мягкого завершения всех фоновых процессов
    kill $(jobs -p) 2>/dev/null
    
    # Ожидание завершения фоновых процессов или
    # таймаута, установленного в TimeoutStopSec, или 90 секунд по дефолту
    wait
    
    exit 0
}
# Так как /bin/sh не понимает сигналы с префиксом SIG (SIGTERM, SIGINT)
# используем POSIX-совместимые TERM INT
trap "on_exit" EXIT TERM INT

# Включение виртуального интерфейса, если настройки указаны в /etc/network/interfaces
# ifup host0
# Включение виртуального интерфейса
# ip link set dev host0 up
# Добавление адреса, если на хосте нет DHCP-сервера
# ip addr add 192.168.100.2/24 dev host0

# Запуск sleep в фоне и ожидание с помощью wait, который перехватывает сигналы завершения работы
sleep infinity &
wait $!
