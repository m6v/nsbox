# Инструменты для управления контейнерами `systemd-nspawn`

- `nsbox` - скрипт для управления контейнерами `systemd-nspawn`
- `nsbox@.service` - шаблон службы для запуска контейнеров `systemd-nspawn`
- `d2r` - скрипт для создания контейнеров на базе образов docker
- `nsbox.sh` и `nsinit.sh` - старая реализация контейнеров в чистом bash, без использования systemd-nspawn

Пи запуске nsbox проверяет наличие каталога `/var/lib/machines/<container_name>` и при отсутствии создает оверлей в каталоге `/var/lib/nsbox/<container_name>` и обычной структурой подкаталогов: `lower`, `upper`, `work`, `merged`. В `lower` монтируется корень хоста. После создания оверлея в /var/lib/machines/ создается симлинк на каталог `merged`

Для создания файловой системы контейнера в `/var/lib/machines/<container_name>` можно использовать команду `load` для загрузки и развертывания образов docker или утилиты типа `debootstrap`.

При запуске службы `nsbox@<container_name>.service`, утилита `systemd-nspawn` проверяет, наличие файла конфигурации имя которого задано в параметре `--machine=<container_name>`, а расширение `.nspawn` в каталоге `/etc/systemd/nspawn`.

Режим сети, используемый для контейнера, определяется настройками файла `/etc/systemd/nspawn/<container_name>.nspawn`. При отсутствии файла или настроек в секции `[Network]`используется сеть хоста.

> NB! Подсеть контейнеров 192.168.100.0/24 в явном виде указана в файлах `/etc/systemd/network/*.conf` и `/etc/nftables.d/nsbox-nat.conf`. Изменения настроек сети делать делать синхронизированно.
> В Astra Linux 1.7.6.15 динамическое выделение адресов в режиме `VirtualEthernet` не работает. Проблема в systemd v.241, в котором есть баг с сопоставлением правила конфигурации с динамически созданными интерфейсами veth и отказом запускать на них DHCP-клиент, так как по умолчанию systemd считает, что у veth-пары «нет физического носителя» (NO-CARRIER).

С параметром `Boot=yes`, запускается программа `/sbin/init`, которой передаются `Parameters` (если заданы). С параметром `Boot=no`, запускается команда, указаннная в `Parameters`, а при отсутствии `Parameters`, в контейнере запускается дефолтная командная оболочка, но так как у нее нет интерактивного ввода, она сразу закроется вместе с контейнером.

## Монтирование внутри контейнера
Монтирование внутри контейнера даже с правами root ограничено. Для монтирования iso-образов можно использовать archivemount
```
archivemount image.iso target_dir 
```
предварительно пробросив /dev/fuse в контейнер.

## Ограничения

При запуске контейнера в режиме `Boot=no` (без флага `-b`) утилита `systemd-nspawn` обрабатывает секцию `[Exec]` крайне избирательно. Значительная часть параметров, управляющих окружением, игнорируется, но некоторые критические системные директивы продолжают работать.

Из секции `[Exec]` при отключенной загрузке системы читаются следующие параметры:

1. Параметры запуска процесса
`Parameters=` — определяет исполняемый файл и его аргументы, которые запустятся внутри контейнера вместо дефолтного /bin/sh.

2. Ограничения ресурсов и безопасности
`Capability=` и `DropCapability=` — управляют привилегиями ядра (POSIX capabilities) для процессов в контейнере (например, разрешение на управление сетью CAP_NET_ADMIN или сырыми сокетами).
`MemoryLimit=`, `CPUAffinity=`, `TasksMax=` — задают жесткие лимиты на оперативную память, ядра процессора и максимальное количество процессов/потоков внутри контейнера.
`SystemCallFilter=` — позволяет заблокировать определенные системные вызовы (syscalls) ядра хоста для приложений внутри контейнера ради безопасности.

3. Пользовательские контексты
`User=` — указывает, от имени какого UID/пользователя (например, nobody или созданного вами user) должен стартовать процесс внутри контейнера.
`WorkingDirectory=` — задает стартовую рабочую директорию внутри контейнера для запускаемого процесса.

Из секции `[Exec]` при отключенной загрузке системы ИГНОРИРУЕЮТСЯ следующие параметры:
`Environment=` — переменные окружения.
`Hostname=` — сетевое имя машины (оно сбрасывается на дефолтное, так как сетевой стек инициализируется стандартно).
`NotifyReady=` — уведомления о готовности системы для systemd хоста.

## Настройка удаленного подключения к рабочему столу

### Использование RDP
В debian из коробки работает следующий вариант (в режиме Boot=yes с настроенной сетью)
```
apt-get update && apt-get install -y xrdp
echo "startxfce4" > ~/.xsession
chmod +x ~/.xsession
passwd root
/usr/sbin/xrdp
/usr/sbin/xrdp-sesman
```
Подключение любым rdp-клиентом, например, remmina. В настройках указать "Использовать клиентское разрешение (Use client resolution)" или "Задать пользовательское" и указать разрешение монитора (например, 192.168.0.1 -> 1920x1080). Чтобы рабочий стол контейнера сам перестраивал свое разрешение под размер окна коиента, внутри контейнера должен стоять модуль xorgxrdp.

### Использование вложенного X-сервера (Nested X Server)
Xephyr — это легкий X-сервер, который запускается на хосте как обычное окно, но внутри этого окна предоставляет чистый X-дисплей (например, :1) специально для контейнера.
1. Разрешить локальным подключениям (из контейнеров и других пространства имён) подключаться к X-серверу хоста (не совсем секьюрно)
```
xhost +local:
```

2. Запустить `Xephyr` на хосте, который откроется черное окно заданного размера с дисплеем `:1`
```
apt install xserver-xephyr
Xephyr -ac -screen 1280x720 -br :1 &
```

3. Пробросить X11-сокет в .nspawn
```
[Files]
Bind=/tmp/.X11-unix
```

4. Запустить рабочий стол из контейнера внутри окна Xephyr на хосте
```
apt-get install -y dbus-x11
export DISPLAY=:1
dbus-launch --exit-with-session startxfce4  # или fly-wm / startlxde
```
- `dbus-launch` автоматически создаст сессионный D-Bus сокет для оконного менеджера, панелей и сервисов Xfce в контейнере.
- `--exit-with-session` аккуратно завершит все фоновые процессы D-Bus, при закрытии рабочего стола Xfce.

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

### debian:trixie-slim с рабочим столом xfce4 и vnc
```
# На хосте выполнить
nsbox load debian:trixie-slim
nsbox exec debian

# В контейнере выполнить
apt update
apt install procps  # ps, top, kill, pkill, free, sysctl

apt install xfce4 tigervnc-standalone-server novnc websockify ca-certificates net-tools
cat << EOF > /entrypoint.sh
#!/bin/sh
rm -f /tmp/.X11-unix/X1
echo '127.0.0.1 localhost debian' > /etc/hosts
echo 'debian' > /etc/hostname
vncserver :1 -geometry 1280x720 -depth 16 -SecurityTypes None --I-KNOW-THIS-IS-INSECURE
websockify --web=/usr/share/novnc 8080 localhost:5901
EOF
chmod +x /entrypoint.sh

mkdir -p /root/.vnc
echo -e "#\!/bin/sh\nstartxfce4 &" > /root/.vnc/xstartup
chmod +x /root/.vnc/xstartup

/entrypoint.sh
```

На хосте в браузере открыть страницу `http://localhost:8080/vnc.html`. Откроется рабочий стол с окном настроек "VNC config", где включить все переключатели.

Не работает буфер обмена, выпонено несколько попыток починить, но не помогли
```
#apt install autocutsel  # Что-то для работы буфера обмена, но не помогло

# Была версия, что https-соединение может решить проблему, но не помогло!
# Создайте SSL-сертификат одной командой
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /root/novnc.pem -out /root/novnc.pem -subj "/CN=localhost"
# В /entrypoint.sh измените строку запуска
websockify --web=/usr/share/novnc --cert=/root/novnc.pem 8080 localhost:5901
```

### debootstrap
>TODO Добавить сюда краткое описание

## Образы docker
skopeo + umoci 

Статически собранные утилиты для загрузки и распаковки docker-образов
[https://github.com/lework/skopeo-binary/releases]
[https://github.com/opencontainers/umoci/releases]

Пример скачивания docker-образа
```
skopeo --insecure-policy copy docker://alpine:latest oci:/tmp/alpine:latest
skopeo --insecure-policy copy docker://alpine:latest oci-archive:/tmp/alpine.tar:alpine:latest

# Флаг --rootless, если не хотим назначать на распаковываемые файлы права root'а
umoci raw unpack --rootless --image /tmp/alpine-oci:latest /var/lib/machines/alpine-root
```

## Контейнер Astra Linux SE
```
mount /astra-1.7_x86-64.iso /srv/repo/alse/main
mkdir -p /var/lib/machines/astra
debootstrap --no-check-gpg --components=main,contrib,non-free 1.7_x86-64 /var/lib/machines/astra file:/srv/repo/alse/main
```
Со стандартным шаблоном настроек на хосте с Астрой запускается без ошибок как с заглушкой, так и с systemd.
```
# ps ax
    PID TTY      STAT   TIME COMMAND
      1 ?        Ss     0:00 /usr/lib/systemd/systemd
     20 ?        Ss     0:00 /lib/systemd/systemd-journald
     40 ?        Ssl    0:00 /usr/sbin/rsyslogd -n -iNONE
     41 ?        Ss     0:00 /usr/sbin/cron -f
     42 console  Ss+    0:00 /sbin/agetty -o -p -- \u --noclear --keep-baud console 115200,38400,9600 vt220
     47 ?        S      0:00 /bin/sh -l

# journalctl
-- Logs begin at Wed 2026-09-02 17:41:25 MSK, end at Wed 2026-09-02 17:42:38 MSK. --
Sep 02 17:41:25 hp-260 systemd-journald[18]: Journal started
Sep 02 17:41:25 hp-260 systemd-journald[18]: Runtime journal (/run/log/journal/cd0bc3568876414395b1a1f97c90ced2) is 8.0M, max 792.5M, 784.5M free.
Sep 02 17:41:25 hp-260 systemd-sysusers[21]: Creating group systemd-coredump with gid 999.
Sep 02 17:41:25 hp-260 systemd-sysusers[21]: Creating user systemd-coredump (systemd Core Dumper) with uid 999 and gid 999.
Sep 02 17:41:25 hp-260 systemd[1]: Starting Flush Journal to Persistent Storage...
Sep 02 17:41:25 hp-260 systemd[1]: PARSEC-UNIT: [systemd-journald.service] pdp_get_pid(22) return NULL, Success
Sep 02 17:41:25 hp-260 systemd-journald[18]: Time spent on flushing to /var is 1.663ms for 6 entries.
Sep 02 17:41:25 hp-260 systemd-journald[18]: System journal (/var/log/journal/cd0bc3568876414395b1a1f97c90ced2) is 8.0M, max 4.0G, 3.9G free.
Sep 02 17:41:25 hp-260 systemd[1]: PARSEC-UNIT: [systemd-journald.service] first pdpl_get_pid(18) error, Success
Sep 02 17:41:25 hp-260 systemd[1]: Started Flush Journal to Persistent Storage.
Sep 02 17:41:25 hp-260 systemd[1]: Started Create System Users.
Sep 02 17:41:25 hp-260 systemd[1]: Starting Create Static Device Nodes in /dev...
Sep 02 17:41:25 hp-260 systemd[1]: Started Create Static Device Nodes in /dev.
Sep 02 17:41:25 hp-260 systemd[1]: Reached target Local File Systems (Pre).
Sep 02 17:41:25 hp-260 systemd[1]: Reached target Local File Systems.
Sep 02 17:41:25 hp-260 systemd[1]: Starting Create Volatile Files and Directories...
Sep 02 17:41:25 hp-260 systemd[1]: Condition check resulted in Commit a transient machine-id on disk being skipped.
Sep 02 17:41:25 hp-260 systemd[1]: Starting Raise network interfaces...
Sep 02 17:41:25 hp-260 systemd[1]: Condition check resulted in udev Kernel Device Manager being skipped.
Sep 02 17:41:25 hp-260 systemd[1]: Started Raise network interfaces.
Sep 02 17:41:25 hp-260 systemd[1]: Reached target Network.
Sep 02 17:41:25 hp-260 systemd[1]: Started Create Volatile Files and Directories.
Sep 02 17:41:25 hp-260 systemd[1]: Condition check resulted in Network Time Synchronization being skipped.
Sep 02 17:41:25 hp-260 systemd[1]: Reached target System Time Synchronized.
Sep 02 17:41:25 hp-260 systemd[1]: Starting Update UTMP about System Boot/Shutdown...
Sep 02 17:41:25 hp-260 systemd[1]: PARSEC: pdp_get_pid(38) return NULL, Success
Sep 02 17:41:25 hp-260 systemd[1]: PARSEC: pdp_get_pid(1) return NULL, Success
Sep 02 17:41:25 hp-260 systemd[1]: Started Update UTMP about System Boot/Shutdown.
Sep 02 17:41:25 hp-260 systemd[1]: Reached target System Initialization.
Sep 02 17:41:25 hp-260 systemd[1]: Started Daily apt download activities.
Sep 02 17:41:25 hp-260 systemd[1]: Started Daily apt upgrade and clean activities.
Sep 02 17:41:25 hp-260 systemd[1]: Started Daily Cleanup of Temporary Directories.
Sep 02 17:41:25 hp-260 systemd[1]: Reached target Basic System.
Sep 02 17:41:25 hp-260 systemd[1]: Condition check resulted in Login Service being skipped.
Sep 02 17:41:25 hp-260 systemd[1]: Started Regular background program processing daemon.
Sep 02 17:41:25 hp-260 systemd[1]: Starting Permit User Sessions...
Sep 02 17:41:25 hp-260 systemd[1]: Started Daily rotation of log files.
Sep 02 17:41:25 hp-260 systemd[1]: Started Daily man-db regeneration.
Sep 02 17:41:25 hp-260 systemd[1]: Reached target Timers.
Sep 02 17:41:25 hp-260 systemd[1]: Condition check resulted in getty on tty2-tty6 if dbus and logind are not available being skipped.
Sep 02 17:41:25 hp-260 cron[39]: (CRON) INFO (pidfile fd = 3)
Sep 02 17:41:25 hp-260 systemd[1]: Starting System Logging Service...
```
