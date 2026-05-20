# ProxyVethMP

Конвертация SOCKS5 прокси в виртуальные сетевые интерфейсы для [mobileproxy.space](https://mobileproxy.space).

Модификация [ProxyVeth](https://github.com/Tovarish666/ProxyVeth) под работу совместно с mp.space на одной VM — без дополнительных контейнеров и без ограничения в 31 мост Proxmox.

---

## Как это работает

Каждый SOCKS5 прокси (реальный мобильный модем на мини-сервере) превращается в виртуальный сетевой интерфейс, который mp.space видит как настоящий HiLink модем.

```
Мини-серверы (5 шт × 20 модемов)
  └── 3proxy → 100 SOCKS5 портов (gen1)
        │
        ▼
  Ubuntu VM (Proxmox)
  ├── ProxyVethMP
  │     Для каждого модема N:
  │     ┌─ network namespace ns_N ──────────────┐
  │     │  tun2socks → SOCKS5 → реальный модем  │
  │     │  192.168.N.1 ← Huawei API (через tun) │
  │     └───────────────────────────────────────┘
  │           ↕ veth пара (без ограничения Proxmox)
  │     veth_extN_host = 192.168.N.100/24
  │
  └── mobileproxy.space
        source-based routing (table 100+N)
        mp.space видит: 192.168.N.100 = модем N
        Huawei API: http://192.168.N.1 — работает ✓
```

**IP схема для каждого модема N:**

| Адрес | Роль |
|---|---|
| `192.168.N.100` | Хост — mp.space видит как IP модема |
| `192.168.N.254` | Namespace — шлюз для хоста |
| `192.168.N.1` | Huawei web API (через tun → SOCKS5) |
| `10.0.N.1/30` | tun интерфейс внутри namespace |

**Ключевое правило mp.space (железное):** если IP модема `192.168.N.100`, то адрес управления `192.168.N.1`. Поэтому номер модема в таблице `n` — это реальный номер (1–200), не порядковый.

---

## Отличия от оригинального ProxyVeth

| | ProxyVeth | ProxyVethMP |
|---|---|---|
| Назначение | SOCKS5 → Windows VM | SOCKS5 → mp.space |
| eth1 / VLAN | ✓ (trunk к Windows) | ✗ не нужен |
| br\_mgmt bridge | ✓ | ✗ не нужен |
| dnsmasq | ✓ (DHCP для Windows) | ✗ не нужен |
| veth к хосту | ✗ | ✓ veth\_extN\_host |
| DNS через хост | ✗ | ✓ bypass tun (иначе петля) |
| UDP DROP на tun | ✓ | ✓ критично: защищает 3proxy |
| Source routing | ✗ | ✓ table 100+N |
| Ограничение мостов | 31 (Proxmox net0–net31) | без ограничений |
| Отдельный LXC | ✓ | ✗ та же VM что mp.space |

---

## Быстрый деплой

На хосте Proxmox:

```bash
bash <(curl -s https://raw.githubusercontent.com/Tovarish666/ProxyVeth/main/deploy.sh)
```

Скрипт задаст вопросы и за ~20 минут:
1. Создаст Ubuntu 24.04 VM через cloud-init
2. Установит mp.space (install.sh + setup-modem-management.sh)
3. Запишет auth.mp
4. Установит ProxyVethMP
5. Поднимет все NS из Google Sheets
6. Настроит systemd (автостарт + watchdog + autosync)

После деплоя — настроить сервер в ЛК mobileproxy.space (см. ниже).

---

## Установка вручную

### Требования

- Proxmox 7+ на хосте
- Ubuntu 24.04 VM (8GB RAM, 8 CPU, 50GB диск)
- mp.space аккаунт с сервером
- Google Sheets с列ком прокси (публичный CSV)

### 1. mp.space

```bash
# Внутри Ubuntu VM:
wget -O - https://mobileproxy.space/downloads/sp/install.sh | bash
wget -O - https://mobileproxy.space/downloads/sp/setup-modem-management.sh | bash

# Записать реальный auth.mp (скачать на сайте mp.space)
echo '{"auth":"KEY:KEY","port":1800}' > /home/nodejs/work/auth.mp

reboot
```

### 2. ProxyVethMP

```bash
wget -O /usr/local/bin/proxyveth_mp.py \
  https://raw.githubusercontent.com/Tovarish666/ProxyVeth/main/proxyveth_mp.py
chmod +x /usr/local/bin/proxyveth_mp.py
ln -sf /usr/local/bin/proxyveth_mp.py /usr/local/bin/proxyveth

# Сохранить URL таблицы
mkdir -p /etc/proxyvethmp
echo 'SHEET_CSV_URL=https://docs.google.com/...' > /etc/proxyvethmp/env

# Установить зависимости, синхронизировать, запустить
proxyveth install
proxyveth sync
proxyveth up all
```

### 3. Настройка в ЛК mobileproxy.space

```
Мой прокси-бизнес → Сервера → ✏ Редактировать

  Статический IP : (curl -s 2ip.ru)
  LocalIP        : (hostname -I | awk '{print $1}')
  Root login     : root
  Пароль Root    : ****
  OS             : Unix
```

После сохранения нажать на домен сервера → обновление конфига.

---

## Формат Google Sheets

Таблица должна быть опубликована (Файл → Опубликовать → CSV).

**Вариант A — одна колонка proxy:**

| n | proxy |
|---|---|
| 41 | 95.165.86.25:12001:login:password |
| 42 | 95.165.86.25:12004:login:password |

**Вариант B — раздельные колонки:**

| n | proxy\_host | proxy\_port | login | password |
|---|---|---|---|---|
| 41 | 95.165.86.25 | 12001 | login | password |

Дополнительная колонка `enabled` (0/1) — для отключения отдельных модемов.

---

## Команды

```bash
proxyveth status              # статус всех namespace
proxyveth status --wan        # + проверка WAN IP (медленно)
proxyveth check N             # полная диагностика одного NS
proxyveth up N                # поднять namespace N
proxyveth up all              # поднять все
proxyveth down N              # остановить namespace N
proxyveth down all            # остановить все
proxyveth restart N           # перезапустить namespace N
proxyveth restart all         # перезапустить все
proxyveth sync                # обновить конфиг из Google Sheets
proxyveth autosync            # sync + пересоздать изменённые NS
proxyveth show-config         # показать текущий конфиг
proxyveth watchdog            # один проход мониторинга
proxyveth cleanup             # полная очистка (осторожно)
```

---

## Systemd сервисы

| Сервис | Роль |
|---|---|
| `proxyvethmp` | запуск всех NS при загрузке VM |
| `proxyvethmp-watchdog` | мониторинг каждые 60с, рестарт при падении |
| `proxyvethmp-autosync.timer` | синхронизация таблицы каждые 5 мин |

```bash
systemctl status proxyvethmp
systemctl status proxyvethmp-watchdog
journalctl -u proxyvethmp-watchdog -f
tail -f /etc/proxyvethmp/logs/watchdog.log
```

---

## Ручная настройка одного модема

Для отладки или первого запуска без скрипта:

```bash
N=60
PROXY="socks5://login:password@host:port"
ETH_WAN="eth0"
RT_TABLE=$((100 + N))

# Namespace + DNS
ip netns add ns_${N}
ip netns exec ns_${N} ip link set lo up
mkdir -p /etc/netns/ns_${N}
echo "nameserver 8.8.8.8" > /etc/netns/ns_${N}/resolv.conf

# veth пара
ip link add veth_ext${N}_host type veth peer name veth_ext${N}_ns
ip link set veth_ext${N}_ns netns ns_${N}
ip addr add 192.168.${N}.100/24 dev veth_ext${N}_host
ip link set veth_ext${N}_host up
ip netns exec ns_${N} ip addr add 192.168.${N}.254/24 dev veth_ext${N}_ns
ip netns exec ns_${N} ip link set veth_ext${N}_ns up

# tun2socks
ip netns exec ns_${N} tun2socks -device tun${N} -proxy ${PROXY} -loglevel silent &
sleep 3
ip netns exec ns_${N} ip addr add 10.0.${N}.1/30 dev tun${N}
ip netns exec ns_${N} ip link set tun${N} up

# Маршруты внутри ns
ip netns exec ns_${N} ip route add default dev tun${N}
ip netns exec ns_${N} ip route add 192.168.${N}.1/32 dev tun${N}  # Huawei API
ip netns exec ns_${N} ip route add PROXY_HOST/32 via 192.168.${N}.100  # bypass tun!
ip netns exec ns_${N} ip route add 8.8.8.8/32 via 192.168.${N}.100    # DNS bypass tun!
ip netns exec ns_${N} ip route add 8.8.4.4/32 via 192.168.${N}.100

# iptables — UDP DROP критичен: без него mproxy флудит 3proxy через tun
ip netns exec ns_${N} iptables -A OUTPUT  -o tun${N} -p udp -j DROP
ip netns exec ns_${N} iptables -A FORWARD -o tun${N} -p udp -j DROP
ip netns exec ns_${N} sysctl -w net.ipv4.ip_forward=1
ip netns exec ns_${N} iptables -t nat -A POSTROUTING -o tun${N} -j MASQUERADE
ip netns exec ns_${N} iptables -A FORWARD -i veth_ext${N}_ns -o tun${N} -j ACCEPT
ip netns exec ns_${N} iptables -A FORWARD -i tun${N} -o veth_ext${N}_ns -j ACCEPT

# Хост: NAT + source routing
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 192.168.${N}.0/24 -o ${ETH_WAN} -j MASQUERADE
ip rule add from 192.168.${N}.100 table ${RT_TABLE}
ip route add default via 192.168.${N}.254 dev veth_ext${N}_host table ${RT_TABLE}

# Проверка
curl --interface 192.168.${N}.100 -s 2ip.ru                                      # WAN IP модема
curl --interface 192.168.${N}.100 -s http://192.168.${N}.1/api/webserver/SesTokInfo  # Huawei API
```

---

## Важные нюансы

**DNS и SOCKS5 обязаны обходить tun:**
tun2socks сам использует SOCKS5 для исходящих соединений. Если DNS (8.8.8.8) и адрес SOCKS5 прокси идут через tun → они попадают обратно в tun2socks → бесконечная петля. Маршруты через хост (`via 192.168.N.100`) решают проблему.

**UDP DROP на tun:**
mproxy на хосте биндится на все интерфейсы включая `veth_extN_host`. Его UDP трафик попадает в namespace через source routing и заваливает 3proxy на мини-серверах тысячами пакетов в секунду. Блок UDP на tun устраняет проблему.

**N = реальный номер модема:**
Номер строки в таблице не равен N. N определяет IP: `192.168.N.100`. mp.space управляет модемом по адресу `192.168.N.1` — это жёсткое правило, которое нельзя обойти.

---

## Файлы

```
/usr/local/bin/proxyveth_mp.py    основной скрипт
/usr/local/bin/proxyveth          symlink → proxyveth_mp.py
/etc/proxyvethmp/config.json      конфиг модемов (из Google Sheets)
/etc/proxyvethmp/env              переменные окружения (SHEET_CSV_URL)
/etc/proxyvethmp/logs/            логи watchdog
/etc/netns/ns_N/resolv.conf       DNS для каждого namespace
```

---

## Зависимости

- `tun2socks` v2.5.2 (устанавливается автоматически)
- `python3`, `iproute2`, `iptables`, `curl`
- mobileproxy.space: `install.sh` + `setup-modem-management.sh`

---

## Лицензия

MIT
