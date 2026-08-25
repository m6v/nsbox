# Инструменты для управления контейнерами `systemd-nspawn`

- `nsbox` - скрипт для управления контейнерами `systemd-nspawn`
- `nsbox@.service` - шаблон службы для запуска контейнеров `systemd-nspawn`
- `d2r` - скрипт для создания контейнеров на базе образов docker
- `nsbox.sh` и `nsinit.sh` - старая реализация контейнеров в чистом bash, без использования systemd-nspawn

Пи запуске nsbox проверяет наличие каталога /var/lib/machines/<container_name> и при отсутствии создает оверлей в каталоге `/var/lib/nsbox/<container_name>` и обычной структурой подкаталогов: `lower`, `upper`, `work`, `merged`. В `lower` монтируется корень хоста. После создания оверлея в /var/lib/machines/ создается симлинк на каталог `merged`

Для создания файловой системы контейнера в /var/lib/machines/<container_name> можно использовать утилиты типа `debootstrap` или срипт `d2r`, автоматизирующий процесс загрузки и развертывания образов docker.

Пример использования
```bash
sudo -i
mkdir -p /var/lib/machines/debian-container
d2r debian /var/lib/machines/debian-container
```

При запуске службы `nsbox@<container_name>.service`, утилита `systemd-nspawn` проверяет, наличие файла конфигурации имя которого задано в параметре `--machine=<container_name>`, а расширение `.nspawn` в каталоге `/etc/systemd/nspawn`.

Режим сети, используемый для контейнера, определяется настройками файла `/etc/systemd/nspawn/<container_name>.nspawn`. При отсутствии файла используется сеть хоста.
> NB! Подсеть контейнеров 192.168.100.0/24 в явном виде указана в файлах `/etc/systemd/network/*.conf` и `/etc/nftables.d/nsbox-nat.conf`. Изменения настроек сети делать делать синхронизированно.

> В Astra Linux 1.7.6.15 динамическое выделение адресов в режиме `VirtualEthernet` не работает. Проблема в systemd v.241, в котором есть баг с сопоставлением правила конфигурации с динамически созданными интерфейсами veth и отказом запускать на них DHCP-клиент, так как по умолчанию systemd считает, что у veth-пары «нет физического носителя» (NO-CARRIER).

С параметром `Boot=yes`, запускается программа `/sbin/init`, которой передаются `Parameters` (если заданы). С параметром `Boot=no`, запускается команда, указаннная в `Parameters`, при отсутствии `Parameters` в контейнере запускается дефолтная командная оболочка, но так как у нее нет интерактивного вовода, она сразу закроется вместе с контейнером.

## Легковесные окружения для использования в контейнерах

### busybox
Для создания собственного минималистичного окружения с `busybox` выполнить следующие действия:

1. Создание корневой директории контейнера
```bash
LOWERDIR="/var/lib/<container_name>/lower"
mkdir -p $LOWERDIR
cd $LOWERDIR
mkdir -p bin sbin usr/bin usr/sbin proc sys dev etc etc/init.d
```

2. Копирование статической сборки `busybox` и создание симлинков команд
```bash
apt install busybox-static
cp /bin/busybox $LOWERDIR/bin/
cd $LOWERDIR/bin/
for app in $(sudo ./busybox --list); do sudo ln -sf busybox "$app"; done
cd ..
```

3. Создание минимального скрипта инициализации
systemd-nspawn при старте по умолчанию ищет исполняемый файл `/sbin/init` или `/bin/sh`.
```bash
cat << EOF > $LOWERDIR/sbin/init
#!/bin/sh

# Монтирование виртуальных файловых систем
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Запуск командного интерпретатора
exec /bin/sh
EOF
chmod +x $LOWERDIR/sbin/init
```

4. Создание минимального `/etc/passwd` и каталога `/root` (опционально)
```bash
echo "root:x:0:0:root:/root:/bin/sh" > $LOWERDIR/etc/passwd
mkdir -p $LOWERDIR/root
```

5. Настройка промпта командной строки (опционально)
```bash
cat << 'EOF' > $LOWERDIR/etc/profile
PS1='$(whoami)@$(hostname):$(pwd)\$ '
EOF
```

6. Копирование `musl-bash` (опционально)
> Оболочка `ash` (Almquist shell), используемая в `busybox`, работает в «слепом» 8-битном режиме — она не анализирует символы, а просто пропускает сквозь себя сырые UTF-8 байты кириллицы (из-за чего ломается управление курсором и Backspace). Как только принудительно выставляется LANG=C.UTF-8, ash пытается валидировать ввод, признает кириллицу недопустимой и заменяет каждую русскую букву на знак вопроса. Самое простое решение это использование `musl-bash` в которой поддержка UTF-8 зашита по умолчанию на уровне исходного кода.
```bash
wget https://github.com/robxu9/bash-static/releases/latest/download/bash-linux-x86_64
cp bash-linux-x86_64 $LOWERDIR/bin/bash
chmod +x $LOWERDIR/bin/bash

# Промпт будет работать тот же, что в ash, но лучше заменить на "родной" для bash
cat << 'EOF' > $LOWERDIR/etc/profile
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
EOF
```

### alpine-minirootfs
1. Распаковка архива в каталог нижнего слоя

На сайте [dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/] найти самый свежий файл `alpine-minirootfs-x.xx.x-x86_64.tar.gz`, скачать и распаковать его в каталог нижнего уровня оверлея.
```bash
wget https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-minirootfs-3.24.1-x86_64.tar.gz
# Важно использовать флаг --numeric-owner, чтобы сопоставление UID/GID пользователей внутри архива не нарушилось правами хоста
tar -xzvf alpine-minirootfs-*.tar.gz -C $LOWERDIR --numeric-owner
```

2. Обновление индексов репозиториев и установка пакетов
```bash
apk update
apk add mc nano htop
```

3. Настройка сетевого адптера (при изолированном пространстве сети)
```bash
cat << EOF > $LOWERDIR/etc/network/interfaces
auto lo
iface lo inet loopback

auto host0
iface host0 inet dhcp

# Статический IP-адрес
# iface host0 inet static
#     address 192.168.100.2
#     netmask 255.255.255.0
#     gateway 192.168.100.1
EOF
```
> После запуска контейнера нужно поднять интерфейс, выполнив команду `ifup -a`, потому, что сам по себе в режиме `Boot=no` он не поднимется.

> В Astra Linux 1.7.6.15 динамическое выделение адресов в режиме VirtualEthernet не работает. Проблема в systemd v.241, в котором есть баг с сопоставлением правила конфигурации с динамически созданными интерфейсами veth и отказом запускать на них DHCP-клиент, так как по умолчанию systemd считает, что у veth-пары «нет физического носителя» (NO-CARRIER).gi

4. Поднятие простейшего веб-сервиса для проверки проброса портов
```bash
apk add busybox-extras
mkdir -p /var/www/localhost/htdocs
echo "<h1>Hello world!</h1>" > /var/www/localhost/htdocs/index.html
httpd -h /var/www/localhost/htdocs -p 80
```

5. Запуск со средой инициазции

Зайдите в контейнер в режиме chroot, выполнив команду
```
systemd-nspawn -D /var/lib/machines/alpine /bin/sh
```
Подготовка контейнера к полноценной загрузке
```
# Обновляем репозитории и ставим менеджер инициализации
apk update
apk add openrc
# Разрешаем запуск служб в контейнерах (отключаем прямую работу с железом)
sed -i 's/#rc_sys=""/rc_sys="nspawn"/' /etc/rc.conf
Сбрасываем пароль root (делаем его пустым)
sed -i 's/^root:[^:]*:/root::/' /etc/shadow
# Добавляем виртуальные терминалы в разрешенные для входа root
for i in 0 1 2 3 4; do echo "pts/$i" >> /etc/securetty; done
echo "console" >> /etc/securetty
# Комментируем строки, отвечающие за запуск консолей
sed -i 's/^\(tty[0-9].*getty\)/#\1/g' /etc/inittab
# Добавляем универсальную строку для контейнеров, которая привяжет вход к /dev/console
sed -i '/#.*getty/a console::respawn:/sbin/getty 38400 console' /etc/inittab
```

Полноценная загрузка ОС
```
systemd-nspawn -D /tmp/alpine -b
```

### debootstrap
>TODO Добавить сюда краткое описание
