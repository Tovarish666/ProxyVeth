#!/bin/bash
# =============================================================
#  deploy.sh — ProxyVethMP полный деплой
#  Репозиторий: https://github.com/Tovarish666/ProxyVeth
#
#  Запуск на хосте Proxmox:
#    bash <(curl -s https://raw.githubusercontent.com/Tovarish666/ProxyVeth/main/deploy.sh)
#
#  Время: ~20 минут
# =============================================================
set -euo pipefail

GITHUB_RAW="https://raw.githubusercontent.com/Tovarish666/ProxyVeth/main"
PROXYVETHMP_URL="${GITHUB_RAW}/proxyveth_mp.py"
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_IMG_PATH="/var/lib/vz/template/iso/ubuntu-24.04.img"

# ── Цвета ───────────────────────────────────────────────────
R="\033[0m"; G="\033[32m"; RD="\033[31m"; Y="\033[33m"
C="\033[36m"; B="\033[1m"; D="\033[2m"

ok()     { echo -e "  ${G}✓${R} $*"; }
fail()   { echo -e "\n  ${RD}✗ ОШИБКА:${R} $*\n"; exit 1; }
info()   { echo -e "  ${C}ℹ${R} $*"; }
warn()   { echo -e "  ${Y}⚠${R} $*"; }
step()   { echo -e "  ${D}→${R} $*"; }
hdr()    { echo -e "\n${B}══════════════════════════════════════════\n  $*\n══════════════════════════════════════════${R}"; }
ask()    { echo -ne "  ${C}?${R} $* "; }
confirm(){ ask "$1 (yes/no):"; read -r _c; [[ "$_c" == "yes" ]] || { echo "Прервано"; exit 0; }; }

# ── SSH к VM ────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"
vm_exec()  { ssh $SSH_OPTS root@"$VM_IP" "$@"; }
vm_run()   { ssh $SSH_OPTS root@"$VM_IP" bash -s <<< "$1"; }

# ════════════════════════════════════════════════════════════
#  ПРОВЕРКИ
# ════════════════════════════════════════════════════════════
[[ $EUID -eq 0 ]]              || fail "Запускай от root на хосте Proxmox"
command -v qm    &>/dev/null   || fail "qm не найден — это не хост Proxmox"
command -v pvesm &>/dev/null   || fail "pvesm не найден"

# ════════════════════════════════════════════════════════════
#  Q&A
# ════════════════════════════════════════════════════════════
echo -e "\n${B}  ProxyVethMP — Деплой новой VM${R}"
echo -e "  ${D}github.com/Tovarish666/ProxyVeth${R}\n"

hdr "Параметры VM"

# VM ID
ask "VM ID [200]:"; read -r VM_ID;         VM_ID=${VM_ID:-200}
if qm status "$VM_ID" &>/dev/null; then
    warn "VM ${VM_ID} уже существует!"
    confirm "Удалить и пересоздать?"
    qm stop "$VM_ID" --skiplock 2>/dev/null || true; sleep 3
    qm destroy "$VM_ID" --destroy-unreferenced-disks 1 --purge 1
    ok "Старая VM удалена"
fi

# Имя
ask "Имя VM [proxyvethmp]:"; read -r VM_NAME;     VM_NAME=${VM_NAME:-proxyvethmp}

# Ресурсы
ask "RAM в MB [8192]:";      read -r VM_RAM;       VM_RAM=${VM_RAM:-8192}
ask "CPU ядра [8]:";         read -r VM_CORES;     VM_CORES=${VM_CORES:-8}
ask "Диск в GB [50]:";       read -r VM_DISK;      VM_DISK=${VM_DISK:-50}

# Хранилище
echo ""
step "Доступные хранилища:"
pvesm status 2>/dev/null | awk 'NR>1{printf "    %-20s %s\n", $1, $2}' || true
ask "Хранилище [local-lvm]:"; read -r VM_STORAGE;  VM_STORAGE=${VM_STORAGE:-local-lvm}

# Мост
step "Доступные мосты:"
ip -o link show | awk -F': ' '/vmbr/{print "    " $2}' || true
ask "Сетевой мост [vmbr0]:"; read -r VM_BRIDGE;    VM_BRIDGE=${VM_BRIDGE:-vmbr0}

# Пароль
echo ""
ask "Пароль root для VM:"; read -rs VM_PASSWORD;   echo ""
[[ -n "$VM_PASSWORD" ]] || fail "Пароль не может быть пустым"

# ── mp.space ────────────────────────────────────────────────
hdr "mobileproxy.space"

echo -e "  ${Y}auth.mp:${R} скачать на сайте:"
echo -e "  Мой прокси-бизнес → Сервера → иконка ↓ у нужного сервера"
echo -e "  Формат: {\"auth\":\"KEY:KEY\",\"port\":1800}\n"
ask "Содержимое auth.mp:"; read -r AUTH_MP_CONTENT
[[ -n "$AUTH_MP_CONTENT" ]] || fail "auth.mp не может быть пустым"

# ── ProxyVethMP ─────────────────────────────────────────────
hdr "ProxyVethMP — Google Sheets"

echo -e "  Таблица должна содержать колонки: ${B}n${R} | ${B}proxy${R} (host:port:login:pass)"
echo -e "  или: ${B}n${R} | ${B}proxy_host${R} | ${B}proxy_port${R} | ${B}login${R} | ${B}password${R}"
echo -e "  ${B}n${R} — реальный номер модема (1-200), определяет IP: 192.168.N.100\n"
ask "SHEET_CSV_URL (Enter = настроить позже):"; read -r SHEET_CSV_URL

# ── Подтверждение ───────────────────────────────────────────
hdr "Подтверждение"
echo -e "  VM ID:      ${B}${VM_ID}${R}"
echo -e "  Имя:        ${B}${VM_NAME}${R}"
echo -e "  RAM:        ${B}${VM_RAM} MB${R}"
echo -e "  CPU:        ${B}${VM_CORES} ядра${R}"
echo -e "  Диск:       ${B}${VM_DISK} GB${R}"
echo -e "  Хранилище:  ${B}${VM_STORAGE}${R}"
echo -e "  Мост:       ${B}${VM_BRIDGE}${R}"
echo -e "  auth.mp:    ${B}$(echo "$AUTH_MP_CONTENT" | cut -c1-45)${R}"
if [[ -n "$SHEET_CSV_URL" ]]; then
    echo -e "  Sheet URL:  ${B}${SHEET_CSV_URL:0:55}...${R}"
else
    warn "Sheet URL не задан — настроить позже"
fi
echo ""
confirm "Всё верно? Начинаем деплой"

# ════════════════════════════════════════════════════════════
#  ШАГ 1: Ubuntu cloud image
# ════════════════════════════════════════════════════════════
hdr "1/8 Ubuntu 24.04 cloud image"

if [[ -f "$UBUNTU_IMG_PATH" ]]; then
    ok "Образ уже есть: $UBUNTU_IMG_PATH"
else
    step "Скачиваем образ (~600MB)..."
    wget -q --show-progress -O "$UBUNTU_IMG_PATH" "$UBUNTU_IMG_URL"
    ok "Образ скачан"
fi

# ════════════════════════════════════════════════════════════
#  ШАГ 2: Создание VM
# ════════════════════════════════════════════════════════════
hdr "2/8 Создание VM"

# SSH ключ хоста
[[ -f /root/.ssh/id_rsa ]] || {
    step "Генерируем SSH ключ хоста..."
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa -q
    ok "SSH ключ создан"
}

step "Создаём VM..."
qm create "$VM_ID" \
    --name      "$VM_NAME" \
    --memory    "$VM_RAM" \
    --cores     "$VM_CORES" \
    --cpu       host \
    --net0      "virtio,bridge=${VM_BRIDGE}" \
    --ostype    l26 \
    --machine   q35 \
    --scsihw    virtio-scsi-pci \
    --serial0   socket \
    --agent     enabled=1 \
    --onboot    1
ok "VM создана (ID=${VM_ID})"

step "Импортируем диск..."
qm importdisk "$VM_ID" "$UBUNTU_IMG_PATH" "$VM_STORAGE" --format qcow2
# Подбираем имя диска (unused0 → scsi0)
DISK_NAME=$(qm config "$VM_ID" | grep "^unused0:" | awk '{print $2}')
[[ -n "$DISK_NAME" ]] || DISK_NAME="${VM_STORAGE}:vm-${VM_ID}-disk-0"
qm set "$VM_ID" --scsi0 "$DISK_NAME"
qm set "$VM_ID" --boot order=scsi0
qm resize "$VM_ID" scsi0 "${VM_DISK}G"
ok "Диск готов (${VM_DISK}GB)"

step "Cloud-init (DHCP + пароль + SSH ключ)..."
qm set "$VM_ID" \
    --ide2      "${VM_STORAGE}:cloudinit" \
    --ciuser    root \
    --cipassword "$VM_PASSWORD" \
    --ipconfig0 ip=dhcp \
    --sshkeys   /root/.ssh/id_rsa.pub
ok "Cloud-init настроен"

# ════════════════════════════════════════════════════════════
#  ШАГ 3: Запуск и получение IP
# ════════════════════════════════════════════════════════════
hdr "3/8 Запуск VM"

qm start "$VM_ID"
ok "VM запущена, ожидаем guest agent..."

# Ждём agent (cloud image может не иметь его → см. шаг 4)
elapsed=0; echo -n "  "
while ! qm guest cmd "$VM_ID" network-get-interfaces &>/dev/null 2>&1; do
    sleep 5; elapsed=$((elapsed+5)); echo -n "."
    if [[ $elapsed -eq 90 ]]; then
        echo ""
        warn "Guest agent не отвечает — возможно не установлен в образе"
        step "Ожидаем появления login prompt (ещё 30с)..."
        sleep 30
        # Устанавливаем agent через qm guest exec если vm уже загружена
        qm guest exec "$VM_ID" -- bash -c "apt install -y -qq qemu-guest-agent && systemctl enable --now qemu-guest-agent" 2>/dev/null || true
        sleep 10; echo -n "  "
    fi
    [[ $elapsed -ge 180 ]] && { echo ""; fail "VM не загрузилась за 3 мин. Проверь через: qm terminal ${VM_ID}"; }
done
echo ""

VM_IP=$(qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null | python3 -c "
import sys,json
for iface in json.load(sys.stdin):
    if iface.get('name')=='eth0':
        for a in iface.get('ip-addresses',[]):
            if a['ip-address-type']=='ipv4' and not a['ip-address'].startswith('127'):
                print(a['ip-address']); sys.exit()
" 2>/dev/null || echo "")
[[ -n "$VM_IP" ]] || fail "Не удалось получить IP VM. Проверь: qm guest cmd ${VM_ID} network-get-interfaces"
ok "VM IP: ${VM_IP}"

# ════════════════════════════════════════════════════════════
#  ШАГ 4: Фикс SSH
#  ВАЖНО: Ubuntu 24.04 cloud image запрещает password auth
#  через /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
#  Этот файл нужно удалить через qm guest exec ДО того
#  как пробуем SSH
# ════════════════════════════════════════════════════════════
hdr "4/8 Фикс SSH аутентификации"

step "Убираем 60-cloudimg-settings.conf..."
qm guest exec "$VM_ID" -- bash -c \
    "rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf && \
     printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' \
       > /etc/ssh/sshd_config.d/99-allow-password.conf && \
     systemctl restart ssh" 2>/dev/null || true
sleep 3
ok "SSH password auth включён"

# Ждём SSH
step "Ожидание SSH..."
elapsed=0; echo -n "  "
while ! vm_exec true 2>/dev/null; do
    sleep 5; elapsed=$((elapsed+5)); echo -n "."
    [[ $elapsed -ge 60 ]] && { echo ""; fail "SSH недоступен на ${VM_IP}"; }
done
echo ""; ok "SSH доступен"

# ════════════════════════════════════════════════════════════
#  ШАГ 5: Базовая настройка Ubuntu
# ════════════════════════════════════════════════════════════
hdr "5/8 Базовая настройка Ubuntu"

vm_run "
export DEBIAN_FRONTEND=noninteractive
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget mc net-tools qemu-guest-agent
systemctl enable --now qemu-guest-agent
hostnamectl set-hostname ${VM_NAME}
grep -q ${VM_NAME} /etc/hosts || echo '127.0.1.1 ${VM_NAME}' >> /etc/hosts
"
ok "Ubuntu обновлена, базовые пакеты установлены"

# ════════════════════════════════════════════════════════════
#  ШАГ 6: Установка mp.space
#  ВАЖНО: оба скрипта запускать ВНУТРИ VM через SSH!
#  Из практики: setup-modem-management.sh был случайно
#  запущен на хосте Proxmox — это создало проблемы
# ════════════════════════════════════════════════════════════
hdr "6/8 Установка mobileproxy.space"

step "install.sh..."
vm_exec "wget -O - https://mobileproxy.space/downloads/sp/install.sh | bash"
ok "install.sh завершён"

step "setup-modem-management.sh..."
vm_exec "wget -O - https://mobileproxy.space/downloads/sp/setup-modem-management.sh | bash"
ok "setup-modem-management.sh завершён"

# Записываем реальный auth.mp
# ВАЖНО: install.sh создаёт /home/nodejs/work/auth.mp с рандомным токеном!
# Нужно ПЕРЕЗАПИСАТЬ его реальным ключом с сайта mp.space
# Путь: /home/nodejs/work/ (НЕ /home/3p/work/)
step "Записываем auth.mp в /home/nodejs/work/..."
vm_exec "echo '${AUTH_MP_CONTENT}' > /home/nodejs/work/auth.mp"
vm_exec "cat /home/nodejs/work/auth.mp"
ok "auth.mp записан"

# ════════════════════════════════════════════════════════════
#  ШАГ 7: Перезагрузка (рекомендуется install.sh)
# ════════════════════════════════════════════════════════════
hdr "7/8 Перезагрузка VM"

vm_exec "reboot" || true
step "Ждём перезагрузки..."
sleep 20

elapsed=0; echo -n "  "
while ! vm_exec true 2>/dev/null; do
    sleep 5; elapsed=$((elapsed+5)); echo -n "."
    [[ $elapsed -ge 120 ]] && { echo ""; fail "VM не поднялась после ребута"; }
done
echo ""; ok "VM перезагружена"

# Проверяем mp.space сервисы
vm_run "systemctl is-active mproxy nodejs-server 2>/dev/null || true" | while read -r s; do
    [[ "$s" == "active" ]] && ok "Сервис active" || warn "Сервис: $s"
done

# ════════════════════════════════════════════════════════════
#  ШАГ 8: ProxyVethMP
# ════════════════════════════════════════════════════════════
hdr "8/8 Установка ProxyVethMP"

# Скачиваем proxyveth_mp.py с GitHub
step "Скачиваем proxyveth_mp.py..."
vm_run "
wget -q -O /usr/local/bin/proxyveth_mp.py '${PROXYVETHMP_URL}'
chmod +x /usr/local/bin/proxyveth_mp.py
ln -sf /usr/local/bin/proxyveth_mp.py /usr/local/bin/proxyveth
"
ok "proxyveth_mp.py установлен"

# Сохранить SHEET_CSV_URL
vm_run "mkdir -p /etc/proxyvethmp && mkdir -p /etc/proxyvethmp/logs"
if [[ -n "$SHEET_CSV_URL" ]]; then
    vm_exec "echo 'SHEET_CSV_URL=${SHEET_CSV_URL}' > /etc/proxyvethmp/env"
    ok "SHEET_CSV_URL сохранён в /etc/proxyvethmp/env"
else
    vm_exec "touch /etc/proxyvethmp/env"
    warn "SHEET_CSV_URL не задан. Позже: echo 'SHEET_CSV_URL=...' > /etc/proxyvethmp/env"
fi

# Установка (tun2socks + пакеты)
step "Установка зависимостей (tun2socks)..."
vm_exec "proxyveth install"
ok "Зависимости установлены"

# Sync + Up
if [[ -n "$SHEET_CSV_URL" ]]; then
    step "Синхронизация с Google Sheets..."
    vm_exec "SHEET_CSV_URL='${SHEET_CSV_URL}' proxyveth sync"
    ok "Конфиг загружен"

    step "Поднимаем все NS..."
    vm_exec "proxyveth up all"
    ok "NS подняты"
else
    info "Sync пропущен — нет Sheet URL"
    info "Позже запусти: proxyveth sync && proxyveth up all"
fi

# Systemd автостарт
step "Настройка systemd..."
vm_run "
ENVF='/etc/proxyvethmp/env'
PY='/usr/bin/python3'
SC='/usr/local/bin/proxyveth_mp.py'

cat > /etc/systemd/system/proxyvethmp.service << 'EOF'
[Unit]
Description=ProxyVethMP - SOCKS5 to veth for mp.space
After=network-online.target mproxy.service nodejs-server.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-/etc/proxyvethmp/env
ExecStart=/usr/bin/python3 /usr/local/bin/proxyveth_mp.py init
ExecStart=/usr/bin/python3 /usr/local/bin/proxyveth_mp.py up all
ExecStop=/usr/bin/python3 /usr/local/bin/proxyveth_mp.py down all
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/proxyvethmp-watchdog.service << 'EOF'
[Unit]
Description=ProxyVethMP Watchdog
After=proxyvethmp.service
Requires=proxyvethmp.service

[Service]
Type=simple
EnvironmentFile=-/etc/proxyvethmp/env
ExecStart=/usr/bin/python3 /usr/local/bin/proxyveth_mp.py watchdog-loop
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/proxyvethmp-autosync.service << 'EOF'
[Unit]
Description=ProxyVethMP Autosync

[Service]
Type=oneshot
EnvironmentFile=-/etc/proxyvethmp/env
ExecStart=/usr/bin/python3 /usr/local/bin/proxyveth_mp.py autosync
EOF

cat > /etc/systemd/system/proxyvethmp-autosync.timer << 'EOF'
[Unit]
Description=ProxyVethMP Autosync every 5 min

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable proxyvethmp.service
systemctl enable proxyvethmp-watchdog.service
systemctl enable proxyvethmp-autosync.timer
systemctl start  proxyvethmp-watchdog.service
systemctl start  proxyvethmp-autosync.timer
"
ok "Systemd: автостарт + watchdog + autosync настроены"

# ════════════════════════════════════════════════════════════
#  ИТОГ
# ════════════════════════════════════════════════════════════
WAN_IP=$(vm_exec "curl -s --max-time 5 2ip.ru" 2>/dev/null || echo "—")
PV_STATUS=$(vm_exec "proxyveth status" 2>/dev/null || echo "нет данных")

hdr "ДЕПЛОЙ ЗАВЕРШЁН"

echo -e "
  ${G}VM:${R}
    ID:           ${VM_ID}
    Имя:          ${VM_NAME}
    Локальный IP: ${VM_IP}
    Внешний IP:   ${WAN_IP}

  ${G}Доступ:${R}
    ssh root@${VM_IP}

  ${G}ProxyVethMP статус:${R}"
echo "$PV_STATUS" | sed 's/^/    /'

echo -e "
  ${G}Полезные команды (на VM):${R}
    proxyveth status          — статус всех NS
    proxyveth status --wan    — + проверка WAN IP каждого
    proxyveth check N         — полная диагностика NS N
    proxyveth restart N       — перезапустить NS N
    proxyveth restart all     — перезапустить все
    proxyveth sync            — обновить конфиг из таблицы
    proxyveth show-config     — показать текущий конфиг

  ${G}Логи:${R}
    journalctl -u proxyvethmp -f
    journalctl -u proxyvethmp-watchdog -f
    tail -f /etc/proxyvethmp/logs/watchdog.log

  ${Y}══════════════════════════════════════════════════${R}
  ${Y}  ОБЯЗАТЕЛЬНО настрой в ЛК mobileproxy.space:${R}
  ${Y}══════════════════════════════════════════════════${R}

  Мой прокси-бизнес → Сервера → ✏ (редактировать)

    Статический IP:   ${WAN_IP}
    LocalIP:          ${VM_IP}
    Root login:       root
    Пароль Root:      (твой пароль)
    OS:               Unix

  После сохранения → нажми на домен сервера
  → получишь сообщение об обновлении конфига ✓
  ${Y}══════════════════════════════════════════════════${R}
"

[[ -z "$SHEET_CSV_URL" ]] && echo -e "  ${Y}⚠ Не забудь добавить Sheet URL:${R}
    echo 'SHEET_CSV_URL=https://...' > /etc/proxyvethmp/env
    proxyveth sync
    proxyveth up all
"
