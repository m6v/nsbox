# Коллекция шаблонов и инструментов для создания и управления контейнерами systemd-nspawn

## `nspawn@.service` и `nspawnctl`
Юнит и скрипт управления контейнерами `systemd-nspawn`.

Контейнер использует оверлей, создаваемый в каталоге `/var/lib/nspawn/<container_name>`. В качестве нижнего слоя используется подкаталог `/var/lib/nspawn/<container_name>/lower`. Если при запуске контейнера каталог нижнего слоя отсутствует или пустой в него автоматически монтируется корень файловой системы хоста.

При старте контейнера в качестве команды, запускаемой как `pid=1`, указывается `/entrypoint.sh`, которая выполняет начальные настройки (в простейшем случае поднятие сетевого интерфейса) и запускает бесконечное ожидание `sleep infinity` которое становится `pid=1`.

При запуске службы `nspawn@alpine-container.service`, бинарник `systemd-nspawn` проверяет, есть ли на хосте файл конфигурации, чье имя совпадает с флагом `--machine=alpine-container`. В данном случае это файл `/etc/systemd/nspawn/alpine-container.nspawn`.
В него можно записать,например, настройки проброса портов
```bash
mkdir -p /etc/systemd/nspawn
cat << EOF > /etc/systemd/nspawn/alpine-container.nspawn
[Network]
VirtualEthernet=yes

Port=tcp:8080:80
Port=tcp:4443:443
Port=udp:5000:5000

[Exec]
# Программа, запускаемая при старте контейнера
Boot=no
Parameters=/bin/sleep infinity
# Parameters=/entrypoint.sh
EOF
```
Режим сети, используемый для контейнера определяется настройками файла /etc/systemd/nspawn/container_name.nspawn. При отсутствии файла используется сеть хоста.
Если указан параметр `Boot=yes`, то запускается программа `/sbin/init` и ей передаются Parameters, если заданы.
Если указан параметр `Boot=no`, то запускается команда, указаннная в Parameters. При отсутствии Parameters контейнер не запускается (или запускаетс я и тут же закрывается)

### Режим сети "виртуальный Ethernet" (`--network-veth`)
Используется режим сети "виртуальный Ethernet" (`--network-veth`), в котором создается изолированное сетевое пространство имен, а между хостом и контейнером прокладывается пара виртуальных интерфейсов. Внутри контейнера интерфейс всегда называется `host0`, а на хосте имя интерфейса формируется динамически по шаблону ve-<имя_контейнера> (например, ve-debian). В связке с systemd-networkd обеспечивается работа встроенногой DHCP, маршрутизация и проброс портов. Чтобы systemd-networkd управлял только интерфейсами контейнеров и игнорировал основную физическую сеть указывается соответствующий шаблон (ve-*). Имя интерфейса можно задать вручную с помощью параметра --network-veth-extra=myif:host0 (в данном примере на хосте создастся интерфейс с фиксированным именем myif)

```bash
cat << EOF > /etc/systemd/network/10-nspawn-veth.network
[Match]
Name=ve-*

[Network]
# IP хоста (шлюза) для всех контейнеров
Address=192.168.100.1/24
# Настройка маскарадинга и форвардинга пакетов
IPMasquerade=ipv4
IPv4Forwarding=yes

# Включение встроенного DHCP-сервера
DHCPServer=yes

[DHCPServer]
# Определение пула динамических IP-адресов
PoolOffset=100
PoolSize=150

systemctl enable --now systemd-networkd
```
> В systemd v.241 (Astra Linux SE 1.7.6.15) из-за бага dhcp в режиме veth не работает, после многих попыток способа победить не нашлось! В debian 13.5 все работает!

### Режим сети "виртуальный мост" (--network-bridge)
В режиме "виртуальный мост" все контейнеры, подключенные к одному мосту, находятся в одном виртуальном «коммутаторе» и могут общаться друг с другом напрямую по своим IP-адресам без ограничений. Проброс портов наружу продолжит работать, хост будет принимать трафик из внешней сети и перенаправлять его в контейнеры, даже если они объединены мостом.

>Дальнейшие действия не проверялись!

1 Создайте мост, который будет существовать только внутри хоста (без привязки к физической карте), так вы изолируете контейнеры, но сохраните им доступ в сеть через хост
```bash
cat << EOF > /etc/systemd/network/20-nspawn-vbridge.netdev
[NetDev]
Name=br0
Kind=bridge
EOF
```
2 Создайте файл конфигурации для этого моста
```bash
cat << EOF > /etc/systemd/network/21-nspawn-vbridge.network
[Match]
Name=br0

[Network]
# IP хоста (шлюза) теперь назначен самому мосту
Address=192.168.100.1/24
# Включаем DHCP-сервер на мосту
DHCPServer=yes
# Включаем NAT, чтобы у контейнеров был интернет через хост
IPMasquerade=ipv4
IPv4Forwarding=yes

[DHCPServer]
# Настройки пула адресов
PoolOffset=100
PoolSize=150
EOF
```

3 Настройте правила для интерфейсов контейнеров
При использовании моста systemd-nspawn создает на хосте интерфейсы с префиксом `vb-*`, поэтому в настройки добавляем соответствующий шаблон
```bash
cat << EOF > /etc/systemd/network/25-containers.network
[Match]
Name=ve-* vb-*

[Network]
Bridge=br0
EOF
```

4 Применение настроек
```
systemctl restart systemd-networkd
```

##  Включение NAT (маскарадинга) в nftables на хосте
```bash
# Маскарадинг (NAT)
sudo nft add rule ip nat postrouting ip saddr 192.168.100.0/24 masquerade

# Защита от блокировок Docker / Libvirt (фильтрация)
sudo nft insert rule ip filter FORWARD iifname "ve-*" accept
sudo nft insert rule ip filter FORWARD oifname "ve-*" ct state established,related accept

# Сохранение результата в постоянную конфигурацию
nft list ruleset | sudo tee /etc/nftables.conf

# Активация службы nftables, чтобы при загрузке хоста ядро поднимало NAT для контейнеров
systemctl enable nftables.service
```

### Окружение busybox
Для создания собственного минималистичного окружения с busybox выполнить следующие действия:

1. Создание корневой директории контейнера
```bash
LOWERDIR="/var/lib/<container_name>/lower"
mkdir -p $LOWERDIR
cd $LOWERDIR
mkdir -p bin sbin usr/bin usr/sbin proc sys dev etc etc/init.d
```

2. Копирование статической сборки busybox и создание симлинков команд
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

4. Создание минимального `etc/passwd` и каталога `/root` (опционально)
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

6. Копирование musl-bash (опционально)
> Оболочка ash (Almquist shell), используемая в busybox работает в «слепом» 8-битном режиме — она не анализирует символы, а просто пропускает сквозь себя сырые UTF-8 байты кириллицы (из-за чего ломается управление курсором и Backspace). Как только принудительно выставляется LANG=C.UTF-8, ash пытается валидировать ввод, признает кириллицу недопустимой и заменяет каждую русскую букву на знак вопроса. Самое простое решение это использование musl-bash в которой поддержка UTF-8 зашита по умолчанию на уровне исходного кода.
```bash
wget https://github.com/robxu9/bash-static/releases/latest/download/bash-linux-x86_64
cp bash-linux-x86_64 $LOWERDIR/bin/bash
chmod +x $LOWERDIR/bin/bash

# Промпт будет работать тот же, что в ash, но лучше заменить на "родной" для bash
cat << 'EOF' > $LOWERDIR/etc/profile
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
EOF
```

### Окружение alpine-minirootfs
1. Распаковка архива в каталог нижнего слоя
На сайте [dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/] найти самый свежий файл `alpine-minirootfs-x.xx.x-x86_64.tar.gz`
```bash
wget https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-minirootfs-3.24.1-x86_64.tar.gz
# Важно использовать флаг --numeric-owner, чтобы сопоставление UID/GID пользователей внутри архива не нарушилось правами хоста
tar -xzvf alpine-minirootfs-*.tar.gz -C $LOWERDIR --numeric-owner
```

3. Обновление индексов репозиториев и установка пакетов
```bash
apk update
apk add mc nano htop
```

4. Настройка сетевого адптера (при изолированном пространстве сети)
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
> После запуска контейнера нужно поднять интерфейс, выполнив команду `ifup -a`, потому, что сам по себе в режиме `Boot=no` он не поднимется
  В Astra Linux 1.7.6.15 динамическое выделение адресов не работает. Проблема в systemd v.241, в которой есть баг с сопоставлением правила конфигурации с динамически созданными интерфейсами veth и отказои запускать на них DHCP-клиент, так как по умолчанию systemd считает, что у veth-пары «нет физического носителя» (NO-CARRIER). Решением может быть добавление параметра ConfigureWithoutCarrier=true в секцию [Network] файла .network на хосте. Нужно проверять!
  В debian 13.5 динамическое выделение адресов работает!
  

5. Поднятие простейшего веб-сервиса для проверки проброса портов
```bash
apk add busybox-extras
mkdir -p /var/www/localhost/htdocs
echo "<h1>Hello world!</h1>" > /var/www/localhost/htdocs/index.html
httpd -h /var/www/localhost/htdocs -p 80
```


### Окружение debootstrap
>TODO Добавить сюда краткое описание
