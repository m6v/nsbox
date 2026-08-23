# Переменные путей установки
PREFIX        ?= /etc
EXEC_PREFIX   ?= /usr/local

SYSTEMD_DIR         = $(DESTDIR)$(PREFIX)/systemd/system
NETWORK_DIR         = $(DESTDIR)$(PREFIX)/systemd/network
NSPAWN_DIR          = $(DESTDIR)$(PREFIX)/systemd/nspawn
NFTABLES_CONF       = $(DESTDIR)$(PREFIX)/nftables.conf
NFTABLES_DIR        = $(DESTDIR)$(PREFIX)/nftables.d

BIN_DIR             = $(DESTDIR)$(EXEC_PREFIX)/bin
BASH_COMPLETION_DIR = $(DESTDIR)$(EXEC_PREFIX)/share/bash-completion/completions

INSTALL_DATA = install -m 0644 -D
INSTALL_EXEC = install -m 0755 -D

# Параметры пакета
PKG_NAME    = nsbox
PKG_VERSION = 0.1.$(shell git rev-list --count HEAD 2>/dev/null || echo "0")
PKG_ARCH    = all
PKG_DIR     = build_deb

.PHONY: all install install-bin install-completion install-service install-network install-nspawn install-nftables reload check deb clean help

all: help

## Установка всех компонентов, настройка nftables и перезапуск службы
install: install-bin install-completion install-service install-network install-nspawn install-nftables reload

## Установка утилит управления
install-bin:
	$(INSTALL_EXEC) nsbox $(BIN_DIR)/nsbox
	$(INSTALL_EXEC) d2r.py $(BIN_DIR)/d2r

## Установка bash-completion
install-completion:
	$(INSTALL_DATA) nsbox-completion.bash $(BASH_COMPLETION_DIR)/nsbox

## Установка шаблонного юнита nsbox@.service
install-service:
	$(INSTALL_DATA) nsbox@.service $(SYSTEMD_DIR)/nsbox@.service
	@if [ -z "$(DESTDIR)" ]; then systemctl daemon-reload; fi

## Установка сетевой конфигурации systemd-networkd
install-network:
	@mkdir -p $(NETWORK_DIR)
	$(INSTALL_DATA) 10-nsbox-veth.network $(NETWORK_DIR)/10-nsbox-veth.network
	$(INSTALL_DATA) 20-nsbox-vbridge.netdev $(NETWORK_DIR)/20-nsbox-vbridge.netdev
	$(INSTALL_DATA) 21-nsbox-vbridge.network $(NETWORK_DIR)/21-nsbox-vbridge.network
	$(INSTALL_DATA) 22-nsbox-containers.network $(NETWORK_DIR)/22-nsbox-containers.network

## Установка шаблона конфигурационного файла .nspawn
install-nspawn:
	$(INSTALL_DATA) config.tmpl $(NSPAWN_DIR)/config.tmpl

## Установка модуля nsbox-nat.conf и привязка include (только при живой установке)
install-nftables:
	@mkdir -p $(NFTABLES_DIR)
	$(INSTALL_DATA) nsbox-nat.conf $(NFTABLES_DIR)/nsbox-nat.conf
	@if [ -z "$(DESTDIR)" ]; then \
		grep -qxF 'include "$(NFTABLES_DIR)/*.conf"' $(NFTABLES_CONF) || \
			echo 'include "$(NFTABLES_DIR)/*.conf"' >> $(NFTABLES_CONF); \
	fi

## Проверка синтаксиса изолированного модуля nftables
check:
	-/usr/sbin/nft --check --file nsbox-nat.conf

## Перезапуск networkd, применение правила nftables и обновление юнитов
reload:
	@if [ -z "$(DESTDIR)" ]; then \
		nft -f $(NFTABLES_CONF); \
		systemctl reload-or-restart systemd-networkd; \
	fi

## Сборка DEB-пакета
deb: clean check
	@mkdir -p $(PKG_DIR)/DEBIAN
	@echo "Package: $(PKG_NAME)" > $(PKG_DIR)/DEBIAN/control
	@echo "Version: $(PKG_VERSION)" >> $(PKG_DIR)/DEBIAN/control
	@echo "Section: utils" >> $(PKG_DIR)/DEBIAN/control
	@echo "Priority: optional" >> $(PKG_DIR)/DEBIAN/control
	@echo "Architecture: $(PKG_ARCH)" >> $(PKG_DIR)/DEBIAN/control
	@echo "Depends: systemd-container, python3, nftables" >> $(PKG_DIR)/DEBIAN/control
	@echo "Maintainer: Sergey Maksimov <m6v@mail.ru>" >> $(PKG_DIR)/DEBIAN/control
	@echo "Description: Инструмент управления контейнерами systemd-nspawn" >> $(PKG_DIR)/DEBIAN/control
	@echo " Автоматизация развертывания, сетевой конфигурации veth/vbridge" >> $(PKG_DIR)/DEBIAN/control
	@echo " и интеграция с правилами трансляции адресов nftables." >> $(PKG_DIR)/DEBIAN/control
	@if [ -f postinst ]; then $(INSTALL_EXEC) postinst $(PKG_DIR)/DEBIAN/postinst; fi
	@if [ -f postrm ]; then $(INSTALL_EXEC) postrm $(PKG_DIR)/DEBIAN/postrm; fi
	@$(MAKE) --no-print-directory install DESTDIR=$(CURDIR)/$(PKG_DIR)
	dpkg-deb --build $(PKG_DIR) $(PKG_NAME)_$(PKG_VERSION)_$(PKG_ARCH).deb
	@rm -rf $(PKG_DIR)

## Очистка временных файлов сборки и старых пакетов
clean:
	rm -rf $(PKG_DIR)
	rm -f $(PKG_NAME)_*.deb

help:
	@echo "Использование: make [цель]"
	@echo ""
	@echo "Цели:"
	@echo "  deb     - Собрать готовый .deb пакет проекта"
	@echo "  clean   - Удалить временные директории сборки"
	@echo "  install - Установить в систему (требует sudo)"
