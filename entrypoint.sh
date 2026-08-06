#!/bin/sh
# Точка входа для контейнеров systemd-nspawn

# Включение виртуального интерфейса, с настройками в /etc/network/interfaces
ifup host0

# Бесконечное ожидание
exec sleep infinity
