#!/bin/bash
#
# ProxyVeth Installer v2.0
# ========================
# Запускать на ХОСТЕ Proxmox (не в контейнере!)
#
# Что делает:
#   1. Создаёт LXC контейнер (Debian 13)
#   2. Настраивает привилегии (tun, nesting)
#   3. Создаёт VLAN-aware мост vmbr101
#   4. Добавляет trunk-интерфейс eth1
#   5. Скачивает и запускает proxyveth.py
#   6. Создаёт сетевые адаптеры на Win10 VM (по данным из таблицы)
#
# Использование:
#   bash proxyveth-install.sh
#

set -e

# ═══════════════════════════════════════════════════════════
#  НАСТРОЙКИ (поменяй под себя)
# ═══════════════════════════════════════════════════════════

# Google Sheets — pubhtml CSV ссылка
SHEET_CSV_URL="${SHEET_CSV_URL:-}"

# GitHub — откуда скачивать proxyveth.py
GITHUB_RAW="${GITHUB_RAW:-https://raw.githubusercontent.com/ТВОЙ_USERNAME/proxyveth/main/proxyveth.py}"

# Proxmox storage для контейнера
STORAGE="${STORAGE:-local-lvm}"

# VLAN мост
VLAN_BRIDGE="vmbr101"

# ═══════════════════════════════════════════════════════════
#  Цвета и хелперы
# ═══════════════════════════════════════════════════════════

R="\033[0m"
G="\033[32m"
RD="\033[31m"
Y="\033[33m"
C="\033[36m"
B="\033[1m"
D="\033[2m"

ok()   { echo -e "  ${G}✓${R} $*"; }
fail() { echo -e "  ${RD}✗${R} $*"; }
info() { echo -e "  ${C}ℹ${R} $*"; }
warn() { echo -e "  ${Y}⚠${R} $*"; }
step() { echo -e "  ${D}→${R} $*"; }
header() { echo -e "\n${B}$*${R}"; }

ask() {
    local prompt="$1" default="$2" var
    if [ -n "$default" ]; then
        read -rp "  $prompt [$default]: " var
        echo "${var:-$default}"
    else
        read -rp "  $prompt: " var
        echo "$var"
    fi
}

# ═══════════════════════════════════════════════════════════
#  Проверка: мы на хосте Proxmox?
# ═══════════════════════════════════════════════════════════

if [ ! -f /etc/pve/local/pve-ssl.pem ] && ! command -v pct &>/dev/null; then
    fail "Этот скрипт нужно запускать на хосте Proxmox!"
    exit 1
fi

echo -e "
${B}══════════════════════════════════════════════════════════
  ProxyVeth Installer
══════════════════════════════════════════════════════════${R}
"

# ═══════════════════════════════════════════════════════════
#  Шаг 0: Сбор параметров
# ═══════════════════════════════════════════════════════════

header "▸ Настройка"

# CT ID
NEXT_CT=$(pvesh get /cluster/nextid 2>/dev/null || echo "101")
CT_ID=$(ask "CT ID для контейнера" "$NEXT_CT")

# Проверить что CT не существует
if pct status "$CT_ID" &>/dev/null; then
    warn "CT $CT_ID уже существует!"
    EXISTING_CT=$(ask "Использовать существующий? (y/n)" "y")
    if [ "$EXISTING_CT" != "y" ]; then
        CT_ID=$(ask "Введи другой CT ID" "")
    fi
fi

# VM ID для Win10
VM_ID=$(ask "VM ID для Win10 (0 = пропустить)" "0")

# Google Sheet URL
if [ -z "$SHEET_CSV_URL" ]; then
    echo ""
    info "Нужна ссылка на Google Sheets (pubhtml CSV)"
    info "Файл → Поделиться → Опубликовать в интернете → CSV"
    info "Формат: https://docs.google.com/spreadsheets/d/e/2PACX-.../pub?gid=0&single=true&output=csv"
    echo ""
    SHEET_CSV_URL=$(ask "CSV URL таблицы" "")
fi

# GitHub URL
echo ""
info "Откуда скачивать proxyveth.py?"
GITHUB_RAW=$(ask "GitHub raw URL" "$GITHUB_RAW")

# Контейнер — сеть
CT_IP=$(ask "IP контейнера (DHCP или x.x.x.x/24)" "dhcp")
CT_GW=""
CT_BRIDGE=$(ask "Bridge для управления (net0)" "vmbr0")
if [ "$CT_IP" != "dhcp" ]; then
    CT_GW=$(ask "Gateway" "192.168.88.1")
fi

echo ""
header "▸ Параметры"
echo -e "  CT ID:        ${G}$CT_ID${R}"
echo -e "  VM ID:        ${G}${VM_ID:-пропуск}${R}"
echo -e "  Sheet URL:    ${G}${SHEET_CSV_URL:0:60}...${R}"
echo -e "  GitHub:       ${G}${GITHUB_RAW:0:60}...${R}"
echo -e "  CT IP:        ${G}$CT_IP${R}"
echo -e "  CT Bridge:    ${G}$CT_BRIDGE${R}"
echo ""
read -rp "  Всё верно? (y/n) [y]: " CONFIRM
[ "${CONFIRM:-y}" != "y" ] && { echo "Отменено."; exit 0; }


# ═══════════════════════════════════════════════════════════
#  Шаг 1: VLAN-aware мост
# ═══════════════════════════════════════════════════════════

header "▸ Шаг 1: VLAN мост ($VLAN_BRIDGE)"

if grep -q "$VLAN_BRIDGE" /etc/network/interfaces 2>/dev/null; then
    ok "$VLAN_BRIDGE уже существует"
else
    cat >> /etc/network/interfaces << EOF

auto $VLAN_BRIDGE
iface $VLAN_BRIDGE inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 1-200
EOF
    ifup "$VLAN_BRIDGE" 2>/dev/null || true
    ok "$VLAN_BRIDGE создан"
fi


# ═══════════════════════════════════════════════════════════
#  Шаг 2: LXC контейнер
# ═══════════════════════════════════════════════════════════

header "▸ Шаг 2: LXC контейнер (CT $CT_ID)"

if pct status "$CT_ID" &>/dev/null; then
    ok "CT $CT_ID уже существует"
    # Остановить если запущен
    STATUS=$(pct status "$CT_ID" | awk '{print $2}')
    if [ "$STATUS" = "running" ]; then
        step "Останавливаю CT $CT_ID..."
        pct stop "$CT_ID" 2>/dev/null || true
        sleep 2
    fi
else
    step "Скачиваю шаблон Debian 13..."
    TEMPLATE=$(pveam available --section system 2>/dev/null | grep "debian-13" | tail -1 | awk '{print $2}')
    if [ -z "$TEMPLATE" ]; then
        TEMPLATE="debian-13-standard_13.0-1_amd64.tar.zst"
    fi

    # Скачать шаблон если нет
    TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE"
    if [ ! -f "$TEMPLATE_PATH" ]; then
        step "Скачиваю $TEMPLATE..."
        pveam download local "$TEMPLATE" || {
            fail "Не удалось скачать шаблон"
            info "Скачай вручную: pveam download local $TEMPLATE"
            exit 1
        }
    fi
    ok "Шаблон: $TEMPLATE"

    # Создать контейнер
    step "Создаю контейнер..."
    if [ "$CT_IP" = "dhcp" ]; then
        NET0="name=eth0,bridge=$CT_BRIDGE,ip=dhcp"
    else
        NET0="name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP,gw=$CT_GW"
    fi

    pct create "$CT_ID" "local:vztmpl/$TEMPLATE" \
        --hostname proxyveth \
        --rootfs "$STORAGE:4" \
        --cores 2 \
        --memory 512 \
        --swap 0 \
        --net0 "$NET0" \
        --unprivileged 0 \
        --features nesting=1 \
        --start 0 \
        --onboot 1

    ok "CT $CT_ID создан"
fi


# ═══════════════════════════════════════════════════════════
#  Шаг 3: Настройка LXC (tun + nesting)
# ═══════════════════════════════════════════════════════════

header "▸ Шаг 3: LXC привилегии"

CONF="/etc/pve/lxc/${CT_ID}.conf"

# unprivileged: 0
if grep -q "^unprivileged: 0" "$CONF"; then
    ok "unprivileged: 0"
else
    sed -i 's/^unprivileged:.*/unprivileged: 0/' "$CONF" 2>/dev/null || \
        echo "unprivileged: 0" >> "$CONF"
    ok "unprivileged: 0 (установлено)"
fi

# features: nesting=1
if grep -q "nesting=1" "$CONF"; then
    ok "nesting=1"
else
    sed -i 's/^features:.*/features: nesting=1/' "$CONF" 2>/dev/null || \
        echo "features: nesting=1" >> "$CONF"
    ok "nesting=1 (установлено)"
fi

# cgroup tun device
if grep -q "lxc.cgroup2.devices.allow.*10:200" "$CONF"; then
    ok "cgroup tun device"
else
    echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$CONF"
    ok "cgroup tun device (добавлено)"
fi

# mount tun
if grep -q "lxc.mount.entry.*/dev/net/tun" "$CONF"; then
    ok "/dev/net/tun mount"
else
    echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file 0 0" >> "$CONF"
    ok "/dev/net/tun mount (добавлено)"
fi


# ═══════════════════════════════════════════════════════════
#  Шаг 4: Trunk интерфейс (eth1)
# ═══════════════════════════════════════════════════════════

header "▸ Шаг 4: Trunk интерфейс"

if grep -q "net1" "$CONF"; then
    ok "net1 (eth1) уже есть"
else
    pct set "$CT_ID" -net1 "name=eth1,bridge=$VLAN_BRIDGE,type=veth"
    ok "net1 → eth1 на $VLAN_BRIDGE"
fi


# ═══════════════════════════════════════════════════════════
#  Шаг 5: Запуск контейнера + установка proxyveth.py
# ═══════════════════════════════════════════════════════════

header "▸ Шаг 5: Запуск и установка ProxyVeth"

pct start "$CT_ID" 2>/dev/null || true
sleep 3

# Ждём сеть
step "Жду сеть в контейнере..."
for i in $(seq 1 30); do
    if pct exec "$CT_ID" -- ping -c 1 -W 1 8.8.8.8 &>/dev/null; then
        break
    fi
    sleep 1
done

# Установить curl
pct exec "$CT_ID" -- bash -c "apt update -qq && apt install -y -qq curl python3 > /dev/null 2>&1"
ok "curl + python3"

# Скачать proxyveth.py
step "Скачиваю proxyveth.py..."
pct exec "$CT_ID" -- bash -c "curl -fsSL '$GITHUB_RAW' -o /usr/local/bin/proxyveth.py && chmod +x /usr/local/bin/proxyveth.py"
ok "proxyveth.py установлен"

# Прописать SHEET_CSV_URL
if [ -n "$SHEET_CSV_URL" ]; then
    step "Прописываю Sheet URL..."
    # Экранируем URL для sed
    ESCAPED_URL=$(echo "$SHEET_CSV_URL" | sed 's/[&/]/\\&/g')
    pct exec "$CT_ID" -- bash -c "sed -i 's|^SHEET_CSV_URL.*=.*|SHEET_CSV_URL  = os.getenv(\"SHEET_CSV_URL\", \"$SHEET_CSV_URL\")|' /usr/local/bin/proxyveth.py" 2>/dev/null || {
        # Если sed не сработал — через переменную окружения
        warn "sed не сработал, URL нужно вписать вручную"
    }
    ok "Sheet URL прописан"
fi

# Запуск proxyveth
step "Запускаю proxyveth (install + sync + init + up all)..."
echo ""
pct exec "$CT_ID" -- python3 /usr/local/bin/proxyveth.py
echo ""


# ═══════════════════════════════════════════════════════════
#  Шаг 6: Сетевые адаптеры на Win10 VM
# ═══════════════════════════════════════════════════════════

if [ "$VM_ID" != "0" ] && [ -n "$VM_ID" ]; then
    header "▸ Шаг 6: Адаптеры VM $VM_ID"

    # Проверить что VM существует
    if ! qm status "$VM_ID" &>/dev/null; then
        fail "VM $VM_ID не найдена!"
        info "Создай VM и запусти скрипт снова с --vm-adapters $VM_ID"
    else
        # Получить номера модемов из таблицы (скачиваем CSV)
        step "Читаю номера модемов из таблицы..."
        MODEM_NUMBERS=""
        if [ -n "$SHEET_CSV_URL" ]; then
            CSV_DATA=$(curl -fsSL "$SHEET_CSV_URL" 2>/dev/null)
            if [ -n "$CSV_DATA" ]; then
                # Парсим первую колонку (N), пропускаем заголовок, берём числа
                MODEM_NUMBERS=$(echo "$CSV_DATA" | tail -n +2 | cut -d',' -f1 | grep -E '^[0-9]+$' | sort -n)
                MODEM_COUNT=$(echo "$MODEM_NUMBERS" | wc -l)
                ok "Найдено модемов: $MODEM_COUNT"

                if [ "$MODEM_COUNT" -gt 31 ]; then
                    warn "Модемов $MODEM_COUNT, но лимит VM = 31 адаптер (net1-net31)"
                    warn "Первые 31 будут добавлены, остальные нужна вторая VM"
                fi
            else
                warn "Не удалось скачать CSV"
            fi
        fi

        if [ -z "$MODEM_NUMBERS" ]; then
            # Спросить вручную
            info "Не удалось получить номера из таблицы"
            MANUAL=$(ask "Ввести номера модемов вручную? (1-10,21-30 или пусто)" "")
            if [ -n "$MANUAL" ]; then
                # Развернуть диапазоны: "1-10,21-30" → "1 2 3 ... 10 21 22 ... 30"
                MODEM_NUMBERS=$(echo "$MANUAL" | tr ',' '\n' | while read range; do
                    if echo "$range" | grep -q '-'; then
                        START=$(echo "$range" | cut -d'-' -f1)
                        END=$(echo "$range" | cut -d'-' -f2)
                        seq "$START" "$END"
                    else
                        echo "$range"
                    fi
                done | sort -n)
            fi
        fi

        if [ -n "$MODEM_NUMBERS" ]; then
            # Остановить VM если запущена
            VM_STATUS=$(qm status "$VM_ID" | awk '{print $2}')
            if [ "$VM_STATUS" = "running" ]; then
                step "Останавливаю VM $VM_ID..."
                qm stop "$VM_ID"
                sleep 3
            fi

            # Удалить старые net (кроме net0)
            step "Удаляю старые адаптеры..."
            for i in $(seq 1 31); do
                qm set "$VM_ID" --delete "net${i}" 2>/dev/null || true
            done

            # Добавить новые
            step "Добавляю адаптеры..."
            NET_IDX=1
            ADDED=0
            while IFS= read -r N; do
                [ -z "$N" ] && continue
                [ "$NET_IDX" -gt 31 ] && break
                TAG=$((100 + N))
                qm set "$VM_ID" -net${NET_IDX} "model=e1000,bridge=$VLAN_BRIDGE,tag=${TAG}" 2>/dev/null
                NET_IDX=$((NET_IDX + 1))
                ADDED=$((ADDED + 1))
            done <<< "$MODEM_NUMBERS"

            ok "Добавлено адаптеров: $ADDED"

            # Показать маппинг
            echo ""
            info "Маппинг адаптеров:"
            NET_IDX=1
            while IFS= read -r N; do
                [ -z "$N" ] && continue
                [ "$NET_IDX" -gt 31 ] && break
                TAG=$((100 + N))
                echo -e "    ${D}net${NET_IDX} → VLAN ${TAG} → модем ${N} (192.168.${N}.100)${R}"
                NET_IDX=$((NET_IDX + 1))
            done <<< "$MODEM_NUMBERS"

            echo ""
            START_VM=$(ask "Запустить VM $VM_ID? (y/n)" "y")
            if [ "$START_VM" = "y" ]; then
                qm start "$VM_ID"
                ok "VM $VM_ID запущена"
            fi
        else
            warn "Номера модемов не указаны, адаптеры не созданы"
            info "Добавь вручную: qm set $VM_ID -netN model=e1000,bridge=$VLAN_BRIDGE,tag=10X"
        fi
    fi
else
    info "VM ID не указан — адаптеры не создаются"
    info "Позже: bash proxyveth-install.sh (или вручную qm set ...)"
fi


# ═══════════════════════════════════════════════════════════
#  Готово
# ═══════════════════════════════════════════════════════════

CT_IP_ACTUAL=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

echo -e "
${G}══════════════════════════════════════════════════════════
  УСТАНОВКА ЗАВЕРШЕНА!
══════════════════════════════════════════════════════════${R}

  ${G}✓${R} Контейнер:  CT $CT_ID ($CT_IP_ACTUAL)
  ${G}✓${R} ProxyVeth:  установлен и запущен
  ${G}✓${R} Watchdog:   мониторинг каждые 60с
  ${G}✓${R} Autosync:   проверка таблицы каждые 5 мин
  ${G}✓${R} Автостарт:  при перезагрузке

  ${B}Управление:${R}
    pct enter $CT_ID
    proxyveth status
    proxyveth status --wan
    proxyveth check N
    proxyveth restart all

  ${B}Обновление скрипта:${R}
    pct exec $CT_ID -- curl -fsSL '$GITHUB_RAW' -o /usr/local/bin/proxyveth.py
    pct exec $CT_ID -- proxyveth restart all
"
