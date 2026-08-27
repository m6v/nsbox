#!/bin/sh
# Дефолтная точка входа для контейнеров nsbox (systemd-nspawn)

on_exit() {
    echo "Stopping background processes..."
    # Здесь выполнять необходимые действия для корректного завершения работы
    # и/или отправка сигнала SIGTERM (15) для мягкого завершения всех фоновых процессов
    kill $(jobs -p) 2>/dev/null
    
    # Ожидание завершения фоновых процессов (Graceful Shutdown) или таймаута
    # (90 секунд по дефолту или значения, установленного в TimeoutStopSec)
    wait
    
    exit 0
}
# Так как /bin/sh не понимает сигналы с префиксом SIG (SIGTERM, SIGINT)
# используем POSIX-совместимые TERM INT
trap "on_exit" EXIT TERM INT

# Включение виртуального интерфейса с настройками в /etc/network/interfaces
# ifup host0
# Включение виртуального интерфейса с явно указанными настройками
# ip link set dev host0 up
# ip addr add 192.168.100.2/24 dev host0

# Запуск sleep в фоне и ожидание с помощью wait, который перехватывает сигналы завершения работы
sleep infinity &
wait $!
