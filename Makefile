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

# Права доступа
INSTALL_DATA = install -m 0644 -D
INSTALL_EXEC = install -m 0755 -D

.PHONY: all install install-bin install-completion install-service install-network install-nspawn install-nftables reload check help

all: help

## install: Установить бинарники, автодополнение, конфиги, настроить nftables и перезапустить службы
install: install-bin install-completion install-service install-network install-nspawn install-nftables reload

## install-bin: Установить утилиту управления nspawnctl в /usr/local/bin
install-bin:
	@echo "==> Установка утилиты nspawnctl в $(BIN_DIR)..."
	$(INSTALL_EXEC) nspawnctl $(BIN_DIR)/nspawnctl

## install-completion: Установить bash-completion для nspawnctl
install-completion:
	@echo "==> Установка bash-completion в $(BASH_COMPLETION_DIR)..."
	$(INSTALL_DATA) nspawnctl-completion.bash $(BASH_COMPLETION_DIR)/nspawnctl

## install-service: Установить шаблонный юнит nspawn@.service
install-service:
	@echo "==> Установка шаблонного юнита nspawn@.service в $(SYSTEMD_DIR)..."
	$(INSTALL_DATA) nspawn@.service $(SYSTEMD_DIR)/nspawn@.service
	@echo "==> Обновление конфигурации systemd (daemon-reload)..."
	systemctl daemon-reload

## install-network: Установить сетевую конфигурацию systemd-networkd
install-network:
	@echo "==> Установка сетевых конфигов в $(NETWORK_DIR)..."
	$(INSTALL_DATA) 10-nspawn-veth.network $(NETWORK_DIR)/10-nspawn-veth.network

## install-nspawn: Установить шаблон конфигурационного файла .nspawn
install-nspawn:
	@echo "==> Установка шаблона конфигурационного файла .nspawn в $(NSPAWN_DIR)..."
	$(INSTALL_DATA) template.nspawn $(NSPAWN_DIR)/template.nspawn

## install-nftables: Установить модуль nspawn-nat.conf и привязать include
install-nftables:
	@echo "==> Создание директории $(NFTABLES_DIR)..."
	mkdir -p $(NFTABLES_DIR)
	@echo "==> Копирование модуля nspawn-nat.conf..."
	$(INSTALL_DATA) nspawn-nat.conf $(NFTABLES_DIR)/nspawn-nat.conf
	@echo "==> Проверка наличия include в $(NFTABLES_CONF)..."
	@grep -qxF 'include "$(NFTABLES_DIR)/*.conf"' $(NFTABLES_CONF) || \
		(echo 'include "$(NFTABLES_DIR)/*.conf"' >> $(NFTABLES_CONF) && \
		 echo "==> Добавлена строка include в $(NFTABLES_CONF)")

## check: Проверить синтаксис изолированного модуля nftables
check:
	@echo "==> Проверка синтаксиса nspawn-nat.conf..."
	nft -c -f nspawn-nat.conf
	@echo "==> Синтаксис корректен."

## reload: Перезапустить networkd, применить правила nftables и обновить юниты
reload:
	@echo "==> Применение правил nftables..."
	nft -f $(NFTABLES_CONF)
	@echo "==> Перезапуск systemd-networkd..."
	systemctl reload-or-restart systemd-networkd
	@echo "==> Деплой успешно завершен!"

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
