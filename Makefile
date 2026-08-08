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

## Установить утилиту управления nspawnctl в /usr/local/bin
install-bin:
	$(INSTALL_EXEC) nspawnctl $(BIN_DIR)/nspawnctl

## Установить bash-completion для nspawnctl
install-completion:
	$(INSTALL_DATA) nspawnctl-completion.bash $(BASH_COMPLETION_DIR)/nspawnctl

## Установить шаблонный юнит nspawn@.service
install-service:
	$(INSTALL_DATA) nspawn@.service $(SYSTEMD_DIR)/nspawn@.service
	systemctl daemon-reload

## Установить сетевую конфигурацию systemd-networkd
install-network:
	$(INSTALL_DATA) 10-nspawn-veth.network $(NETWORK_DIR)/10-nspawn-veth.network

## Установить шаблон конфигурационного файла .nspawn
install-nspawn:
	$(INSTALL_DATA) config.tmpl $(NSPAWN_DIR)/config.tmpl

## Установить модуль nspawn-nat.conf и привязать include
install-nftables:
	mkdir -p $(NFTABLES_DIR)
	$(INSTALL_DATA) nspawn-nat.conf $(NFTABLES_DIR)/nspawn-nat.conf
	@grep -qxF 'include "$(NFTABLES_DIR)/*.conf"' $(NFTABLES_CONF) || \
		echo 'include "$(NFTABLES_DIR)/*.conf"' >> $(NFTABLES_CONF)

## Проверить синтаксис изолированного модуля nftables
check:
	nft -c -f nspawn-nat.conf

## Перезапустить networkd, применить правила nftables и обновить юниты
reload:
	nft -f $(NFTABLES_CONF)
	systemctl reload-or-restart systemd-networkd

help:
	@echo "Использование: sudo make [цель]"
	@echo ""
	@echo "Цели:"
	@echo "  install            - Полный деплой всех компонентов системы"
	@echo "  install-bin        - Установка только nspawnctl"
	@echo "  install-completion - Установка только автодополнения bash"
	@echo "  install-service    - Деплой nspawn@.service и daemon-reload"
	@echo "  install-network    - Деплой systemd-networkd файлов"
	@echo "  install-nspawn     - Деплой .nspawn файлов"
	@echo "  install-nftables   - Деплой nspawn-nat.conf и привязка include"
	@echo "  check              - Проверка синтаксиса nftables"
	@echo "  reload             - Перезапуск networkd и применение nftables"
