# ProxyVethWin

SOCKS5 прокси → виртуальные сетевые адаптеры для Win10 VM в Proxmox.

Каждый USB-модем (Huawei E3372) превращается в отдельный Ethernet-адаптер внутри Windows — со своим IP, DNS и доступом к веб-интерфейсу модема.

## Как это работает

```
Win10 (192.168.N.100)
  ↕ VLAN
LXC контейнер (Debian 13)
  ├── tun2socks → SOCKS5 прокси → модем → интернет
  ├── dnsmasq (DHCP + DNS)
  └── namespace изоляция (каждый модем = отдельная сеть)
```

## Быстрый старт

На **хосте Proxmox**:

```bash
curl -fsSL https://raw.githubusercontent.com/Tovarish666/ProxyVethWin/main/proxyvethwin-install.sh -o install.sh
bash install.sh
```

Скрипт спросит параметры и сделает всё сам: контейнер, мост, адаптеры VM.

## Ручная установка

```bash
# 1. Создать LXC контейнер (Debian 13)
# 2. Настроить: privileged, nesting, /dev/net/tun, eth1 на vmbr101
# 3. В контейнере:
curl -fsSL https://raw.githubusercontent.com/Tovarish666/ProxyVethWin/main/proxyvethwin.py \
  -o /usr/local/bin/proxyvethwin.py && chmod +x /usr/local/bin/proxyvethwin.py
python3 /usr/local/bin/proxyvethwin.py
```

Если чего-то не хватает (eth1, tun) — скрипт покажет инструкцию.

## Команды

| Команда | Описание |
|---------|----------|
| `proxyvethwin` | Полная установка (первый запуск) |
| `proxyvethwin status` | Статус всех namespace |
| `proxyvethwin status --wan` | С проверкой WAN IP |
| `proxyvethwin check N` | Полная проверка одного модема |
| `proxyvethwin restart all` | Перезапуск всех |
| `proxyvethwin sync` | Обновить конфиг из Google Sheets |
| `proxyvethwin show-config` | Показать конфиг |

## Обновление

```bash
curl -fsSL https://raw.githubusercontent.com/Tovarish666/ProxyVethWin/main/proxyvethwin.py \
  -o /usr/local/bin/proxyvethwin.py && proxyvethwin restart all
```

## Лимиты

- 31 модем на VM (net0 = управление + net1–net31)
- 253 модема максимум
- Для >31 — дополнительные VM
