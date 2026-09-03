# Переменные путей установки
PREFIX        ?= /etc
EXEC_PREFIX   ?= /usr

SYSTEMD_DIR         = $(DESTDIR)$(PREFIX)/systemd/system
NETWORK_DIR         = $(DESTDIR)$(PREFIX)/systemd/network
NSPAWN_DIR          = $(DESTDIR)$(PREFIX)/systemd/nspawn
NFTABLES_CONF       = $(DESTDIR)$(PREFIX)/nftables.conf
NFTABLES_DIR        = $(DESTDIR)$(PREFIX)/nftables.d
NSBOX_DIR           = $(DESTDIR)/var/lib/nsbox
POLKIT_DIR          = $(DESTDIR)/etc/polkit-1/rules.d
SUDOERSDIR          = $(DESTDIR)/etc/sudoers.d

BIN_DIR             = $(DESTDIR)$(EXEC_PREFIX)/bin
BASH_COMPLETION_DIR = $(DESTDIR)$(EXEC_PREFIX)/share/bash-completion/completions

INSTALL_DATA = install -m 0644 -D
INSTALL_EXEC = install -m 0755 -D

.PHONY: all install install-bin install-completion install-service install-network install-templates install-nftables install-polkit-rules install-sudoers reload check deb clean help

all: help

# Установка всех компонентов, настройка nftables и перезапуск службы
install: install-bin install-completion install-service install-network install-templates install-nftables install-polkit-rules install-sudoers reload

# Установка утилит управления
install-bin:
	$(INSTALL_EXEC) nsbox $(BIN_DIR)/nsbox

# Установка bash-completion
install-completion:
	$(INSTALL_DATA) nsbox.completion $(BASH_COMPLETION_DIR)/nsbox

# Установка шаблонного юнита nsbox@.service
install-service:
	$(INSTALL_DATA) nsbox@.service $(SYSTEMD_DIR)/nsbox@.service
	@if [ -z "$(DESTDIR)" ]; then systemctl daemon-reload; fi

# Установка сетевой конфигурации systemd-networkd
install-network:
	$(INSTALL_DATA) 10-nsbox-veth.network $(NETWORK_DIR)/10-nsbox-veth.network
	$(INSTALL_DATA) 20-nsbox-vbridge.netdev $(NETWORK_DIR)/20-nsbox-vbridge.netdev
	$(INSTALL_DATA) 21-nsbox-vbridge.network $(NETWORK_DIR)/21-nsbox-vbridge.network
	$(INSTALL_DATA) 22-nsbox-containers.network $(NETWORK_DIR)/22-nsbox-containers.network

# Установка шаблонов
install-templates:
	$(INSTALL_DATA) config.tmpl $(NSPAWN_DIR)/config.tmpl
	$(INSTALL_EXEC) entrypoint.sh $(NSBOX_DIR)/entrypoint.sh

# Установка модуля nsbox-nat.conf и привязка include (только при живой установке)
install-nftables:
	$(INSTALL_DATA) nsbox-nat.conf $(NFTABLES_DIR)/nsbox-nat.conf
	@if [ -z "$(DESTDIR)" ]; then \
		grep -qxF 'include "$(NFTABLES_DIR)/*.conf"' $(NFTABLES_CONF) || \
			echo 'include "$(NFTABLES_DIR)/*.conf"' >> $(NFTABLES_CONF); \
	fi

# Установка правил polkit
install-polkit-rules:
	$(INSTALL_DATA) 10-nsbox.rules $(POLKIT_DIR)/10-nsbox.rules

# Установка прав для утилиты nsbox на монтирование и размонтирование OverlayFS
install-sudoers:
	install -m 0440 -D nsbox.sudoers $(SUDOERSDIR)/nsbox

# Проверка синтаксиса изолированного модуля nftables
check:
	-/usr/sbin/nft --check --file nsbox-nat.conf

# Перезапуск networkd, применение правила nftables и обновление юнитов
reload:
	@if [ -z "$(DESTDIR)" ]; then \
		nft -f $(NFTABLES_CONF) 2>/dev/null || true; \
		systemctl reload-or-restart systemd-networkd 2>/dev/null || true; \
	fi

# Сборка DEB-пакета
deb: clean check
	@echo "Чтение шаблона deb-пакета..."
	$(eval PKG_NAME := $(shell awk '/^Package:/ {print $$2}' control))
	$(eval BASE_VER  := $(shell awk '/^Version:/ {print $$2}' control))
	$(eval PKG_ARCH := $(shell awk '/^Architecture:/ {print $$2}' control))
	$(eval GIT_REV  := $(shell git rev-list --count HEAD 2>/dev/null || echo 0))
	$(eval PKG_VER  := $(BASE_VER).$(GIT_REV))
	$(eval TMP_BUILD_DIR := $(shell mktemp -d /tmp/deb-build.XXXXXX))

	@echo "Подготовка структуры deb-пакета..."
	@mkdir -p $(TMP_BUILD_DIR)/DEBIAN
	@sed "s/^Version:.*/Version: $(PKG_VER)/" control > $(TMP_BUILD_DIR)/DEBIAN/control

	@if [ -f postinst ]; then $(INSTALL_EXEC) postinst $(TMP_BUILD_DIR)/DEBIAN/postinst; fi
	@if [ -f postrm ]; then $(INSTALL_EXEC) postrm $(TMP_BUILD_DIR)/DEBIAN/postrm; fi

	@$(MAKE) --no-print-directory install DESTDIR=$(TMP_BUILD_DIR) EXEC_PREFIX=/usr

	@echo "Сборка deb-пакета..."
	@dpkg-deb --root-owner-group --build $(TMP_BUILD_DIR) $(PKG_NAME)_$(PKG_VER)_$(PKG_ARCH).deb
	@rm -rf $(TMP_BUILD_DIR)
	@echo "Пакет успешно собран: $(PKG_NAME)_$(PKG_VER)_$(PKG_ARCH).deb"

# Очистка временных файлов сборки и старых пакетов
clean:
	@$(eval PKG_NAME := $(shell awk '/^Package:/ {print $$2}' control 2>/dev/null))
	@if [ -n "$(PKG_NAME)" ]; then rm -f $(PKG_NAME)_*.deb; fi

help:
	@echo "Использование: make [цель]"
	@echo ""
	@echo "Цели:"
	@echo "  deb     - Собрать готовый .deb пакет проекта"
	@echo "  clean   - Удалить собранные deb-пакеты"
	@echo "  install - Установить в систему напрямую (требует sudo, ставит в /usr/local)"
