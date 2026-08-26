#!/bin/sh
# Дефолтная точка входа для контейнеров nsbox (systemd-nspawn)

on_exit() {
    echo "Stopping background processes..."
    # Здесь выполнять необходимые действия для корректного завершения работы
    exit 0
}
trap "on_exit" EXIT SIGTERM SIGINT

# Включение виртуального интерфейса с настройками в /etc/network/interfaces
# ifup host0
# Включение виртуального интерфейса с явно указанными настройками
# ip link set dev host0 up
# ip addr add 192.168.100.2/24 dev host0

# Запуск sleep в фоне и ожидание с помощью wait, который перехватывает сигналы завершения работы
sleep infinity &
wait $!
