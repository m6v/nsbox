# Переменные путей установки
PREFIX ?= /etc
EXEC_PREFIX ?= /usr/local

SYSTEMD_DIR        = $(PREFIX)/systemd/system
NETWORK_DIR        = $(PREFIX)/systemd/network
NSPAWN_DIR         = $(PREFIX)/systemd/nspawn
NFTABLES_CONF      = $(PREFIX)/nftables.conf
NFTABLES_DIR       = $(PREFIX)/nftables.d

BIN_DIR            = $(EXEC_PREFIX)/bin
BASH_COMPLETION_DIR = $(EXEC_PREFIX)/share/bash-completion/completions

INSTALL_DATA = install -m 0644 -D
INSTALL_EXEC = install -m 0755 -D

.PHONY: all install install-bin install-completion install-service install-network install-nspawn install-nftables reload check help

all: help

## Установить бинарники, автодополнение, конфиги, настроить nftables и перезапустить службы
install: install-bin install-completion install-service install-network install-nspawn install-nftables reload

## Установить утилиту управления rigger в /usr/local/bin
install-bin:
	$(INSTALL_EXEC) rigger $(BIN_DIR)/rigger

## Установить bash-completion для rigger
install-completion:
	$(INSTALL_DATA) rigger-completion.bash $(BASH_COMPLETION_DIR)/rigger

## Установить шаблонный юнит rigger@.service
install-service:
	$(INSTALL_DATA) rigger@.service $(SYSTEMD_DIR)/rigger@.service
	systemctl daemon-reload

## Установить сетевую конфигурацию systemd-networkd
install-network:
	$(INSTALL_DATA) -t $(NETWORK_DIR) 10-rigger-veth.network 20-rigger-vbridge.netdev 21-rigger-vbridge.network 22-rigger-containers.network

## Установить шаблон конфигурационного файла .nspawn
install-nspawn:
	$(INSTALL_DATA) config.tmpl $(NSPAWN_DIR)/config.tmpl

## Установить модуль rigger-nat.conf и привязать include
install-nftables:
	mkdir -p $(NFTABLES_DIR)
	$(INSTALL_DATA) rigger-nat.conf $(NFTABLES_DIR)/rigger-nat.conf
	@grep -qxF 'include "$(NFTABLES_DIR)/*.conf"' $(NFTABLES_CONF) || \
		echo 'include "$(NFTABLES_DIR)/*.conf"' >> $(NFTABLES_CONF)

## Проверить синтаксис изолированного модуля nftables
check:
	nft -c -f rigger-nat.conf

## Перезапустить networkd, применить правила nftables и обновить юниты
reload:
	nft -f $(NFTABLES_CONF)
	systemctl reload-or-restart systemd-networkd

help:
	@echo "Использование: sudo make [цель]"
	@echo ""
	@echo "Цели:"
	@echo "  install            - Полный деплой всех компонентов системы"
	@echo "  install-bin        - Установка только rigger"
	@echo "  install-completion - Установка только автодополнения bash"
	@echo "  install-service    - Деплой rigger@.service и daemon-reload"
	@echo "  install-network    - Деплой systemd-networkd файлов"
	@echo "  install-nspawn     - Деплой .nspawn файлов"
	@echo "  install-nftables   - Деплой rigger-nat.conf и привязка include"
	@echo "  check              - Проверка синтаксиса nftables"
	@echo "  reload             - Перезапуск networkd и применение nftables"
