#!/usr/bin/env python3
"""
ProxyVeth Manager v2.0
======================
SOCKS5 → virtual NIC. Google Sheets → namespaces → Win10 VM.

ПЕРВЫЙ ЗАПУСК (без аргументов):
  python3 /usr/local/bin/proxyveth.py
  → install → sync → init → up all → systemd → PATH → готово

КОМАНДЫ:
  (без аргументов)        Полная установка / первый запуск
  sync                    Google Sheets → config.json
  autosync                Sync + пересоздать изменённые NS
  init                    br_mgmt + NAT + eth1
  up    [N|all]           Поднять namespace(ы)
  down  [N|all]           Опустить namespace(ы)
  restart [N|all]         Перезапустить namespace(ы)
  status [--wan]          Таблица статусов
  check  N                Полная проверка одного NS
  watchdog                Один проход мониторинга
  watchdog-loop           Бесконечный цикл (для systemd)
  cleanup                 Полная очистка
  show-config             Показать конфиг
"""

import os
import sys
import json
import time
import subprocess
import csv
import io
import signal
from pathlib import Path
from datetime import datetime

# ==================== Google Sheets ====================
SHEET_ID       = os.getenv("SHEET_ID", "1fd1ZhR4jMcJGWe3gU0-aH5jc_rrOHeq2xpmbll6gpxg")
GID            = int(os.getenv("SHEET_GID", "0"))
WORKSHEET_TITLE = os.getenv("SHEET_TAB", "")
GSHEET_MODE    = os.getenv("GSHEET_MODE", "csv").strip().lower()
GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY", "AIzaSyBMyLkZ1Gh4DCsdoTQmXG7Xb3AGFESNf4U")
SERVICE_ACCOUNT_JSON = os.getenv("GOOGLE_APPLICATION_CREDENTIALS", "service_account.json")
# Прямая ссылка на CSV (pubhtml). Если задана — используется вместо SHEET_ID.
SHEET_CSV_URL  = os.getenv("SHEET_CSV_URL",
    "https://docs.google.com/spreadsheets/d/e/"
    "2PACX-1vRpX9Ms_SGyJPPIlmRJPX3pkFzHzSLAvKnHE2-ulRAqLdNmQIsq2plb7"
    "_jpDBhYmE2SQuYOqBAfiY73/pub?gid=0&single=true&output=csv")

# ==================== Paths ====================
CONFIG_DIR     = Path(os.getenv("PROXYVETH_DIR", "/etc/proxyveth"))
CONFIG_FILE    = CONFIG_DIR / "config.json"
LOG_DIR        = CONFIG_DIR / "logs"
WATCHDOG_LOG   = LOG_DIR / "watchdog.log"
SCRIPT_PATH    = Path("/usr/local/bin/proxyveth.py")
TUN2SOCKS_BIN  = "/usr/local/bin/tun2socks"
TUN2SOCKS_VER  = "2.5.2"
TUN2SOCKS_URL  = (f"https://github.com/xjasonlyu/tun2socks/releases/download/"
                   f"v{TUN2SOCKS_VER}/tun2socks-linux-amd64.zip")
DNSMASQ_BIN    = "dnsmasq"

# ==================== Network ====================
MGMT_BRIDGE    = "br_mgmt"
MGMT_SUBNET    = "10.255.0"
MGMT_GW        = f"{MGMT_SUBNET}.1"
ETH_TRUNK      = "eth1"
ETH_WAN        = "eth0"
DNS_SERVER     = "8.8.8.8"
VLAN_OFFSET    = 100
TUN2SOCKS_WAIT = 3
CURL_TIMEOUT   = 10

# ==================== Watchdog ====================
WATCHDOG_INTERVAL    = int(os.getenv("WATCHDOG_INTERVAL", "60"))
WATCHDOG_WAN_EVERY   = int(os.getenv("WATCHDOG_WAN_EVERY", "10"))
WATCHDOG_MAX_RESTART = int(os.getenv("WATCHDOG_MAX_RESTART", "3"))

# ==================== Autosync ====================
AUTOSYNC_INTERVAL = int(os.getenv("AUTOSYNC_INTERVAL", "300"))  # 5 мин

# ==================== Formatting ====================
R  = "\033[0m"
G  = "\033[32m"
RD = "\033[31m"
Y  = "\033[33m"
C  = "\033[36m"
B  = "\033[1m"
D  = "\033[2m"

def log_ok(msg):    print(f"  {G}✓{R} {msg}")
def log_fail(msg):  print(f"  {RD}✗{R} {msg}")
def log_info(msg):  print(f"  {C}ℹ{R} {msg}")
def log_warn(msg):  print(f"  {Y}⚠{R} {msg}")
def log_step(msg):  print(f"  {D}→{R} {msg}")
def header(msg):    print(f"\n{B}{'═'*60}\n  {msg}\n{'═'*60}{R}")

def wlog(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with open(WATCHDOG_LOG, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ══════════════════════════════════════════════════════════════
#  Shell helpers
# ══════════════════════════════════════════════════════════════

def run(cmd, ns=None, check=True, capture=True, quiet=False):
    if ns is not None:
        cmd = f"ip netns exec ns_{ns} {cmd}"
    r = subprocess.run(cmd, shell=True, capture_output=capture, text=True)
    if check and r.returncode != 0:
        if not quiet:
            log_fail(f"CMD: {cmd}")
            if r.stderr.strip():
                log_fail(f"  stderr: {r.stderr.strip()}")
        raise RuntimeError(f"Command failed (rc={r.returncode}): {cmd}")
    return r

def run_safe(cmd, **kw):
    return run(cmd, check=False, **kw)

def is_ns_exists(n):
    r = run_safe("ip netns list", capture=True)
    for line in r.stdout.strip().split("\n"):
        name = line.split()[0] if line.strip() else ""
        if name == f"ns_{n}":
            return True
    return False

def is_process_running(pattern):
    r = run_safe(f"pgrep -f '{pattern}'", capture=True)
    return r.returncode == 0

def is_bridge_exists(name):
    return run_safe(f"ip link show {name}", capture=True, quiet=True).returncode == 0

def eth1_exists():
    return run_safe(f"ip link show {ETH_TRUNK}", capture=True, quiet=True).returncode == 0

def get_active_ns_list():
    r = run_safe("ip netns list", capture=True)
    ns_list = []
    for line in r.stdout.strip().split("\n"):
        name = line.split()[0] if line.strip() else ""
        if name.startswith("ns_"):
            try:
                ns_list.append(int(name.split("_")[1]))
            except ValueError:
                pass
    ns_list.sort()
    return ns_list

def get_ct_id():
    """Попробовать определить CT ID контейнера."""
    try:
        with open("/etc/hostname") as f:
            hostname = f.read().strip()
        # Типичный формат: proxyveth1 → ищем в pct list
        return hostname
    except Exception:
        return "???"


# ══════════════════════════════════════════════════════════════
#  Config
# ══════════════════════════════════════════════════════════════

def load_config():
    if not CONFIG_FILE.exists():
        log_fail(f"Конфиг не найден: {CONFIG_FILE}")
        log_info("Запусти: proxyveth sync")
        sys.exit(1)
    with open(CONFIG_FILE) as f:
        return json.load(f)

def save_config(data):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def get_enabled_modems(config):
    modems = []
    for n_str, m in config.get("modems", {}).items():
        if m.get("enabled", True):
            modems.append((int(n_str), m))
    modems.sort(key=lambda x: x[0])
    return modems

def get_modem(config, n):
    m = config.get("modems", {}).get(str(n))
    if not m:
        log_fail(f"Модем N={n} не найден в конфиге")
        sys.exit(1)
    return m


# ══════════════════════════════════════════════════════════════
#  Google Sheets → config.json
# ══════════════════════════════════════════════════════════════

def fetch_sheet_csv():
    """CSV export — pubhtml URL или из SHEET_ID."""
    import urllib.request
    if SHEET_CSV_URL:
        url = SHEET_CSV_URL
    else:
        url = f"https://docs.google.com/spreadsheets/d/{SHEET_ID}/export?format=csv&gid={GID}"
    log_step(f"CSV: {url[:70]}...")
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=15) as resp:
            text = resp.read().decode("utf-8-sig")
        reader = csv.reader(io.StringIO(text))
        return [row for row in reader]
    except Exception as e:
        log_fail(f"CSV download error: {e}")
        raise

def fetch_sheet_api_key():
    import urllib.request, urllib.error
    sheet_range = f"'{WORKSHEET_TITLE}'!A1:Z1000" if WORKSHEET_TITLE else "A1:Z1000"
    url = (f"https://sheets.googleapis.com/v4/spreadsheets/{SHEET_ID}"
           f"/values/{sheet_range}?key={GOOGLE_API_KEY}")
    log_step(f"Sheets API: {SHEET_ID[:20]}...")
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=15) as resp:
            data = json.loads(resp.read().decode())
        rows = data.get("values", [])
        if not rows:
            raise ValueError("Таблица пустая")
        return rows
    except urllib.error.HTTPError as e:
        log_fail(f"HTTP {e.code}: {e.reason}")
        raise

def fetch_sheet_service_account():
    try:
        import gspread
        from google.oauth2.service_account import Credentials
    except ImportError:
        log_fail("pip install gspread google-auth --break-system-packages")
        sys.exit(1)
    scopes = ["https://www.googleapis.com/auth/spreadsheets.readonly"]
    creds = Credentials.from_service_account_file(SERVICE_ACCOUNT_JSON, scopes=scopes)
    gc = gspread.authorize(creds)
    sh = gc.open_by_key(SHEET_ID)
    ws = sh.worksheet(WORKSHEET_TITLE) if WORKSHEET_TITLE else sh.sheet1
    return ws.get_all_values()

def parse_sheet_rows(rows):
    if len(rows) < 2:
        raise ValueError("Таблица: заголовок + данные")
    headers_raw = [h.strip().lower().replace(" ", "_") for h in rows[0]]
    log_step(f"Заголовки: {headers_raw}")
    alt_map = {"host":"proxy_host","ip":"proxy_host","server":"proxy_host",
               "port":"proxy_port","user":"login","username":"login",
               "pass":"password","pwd":"password"}
    headers = [alt_map.get(h, h) for h in headers_raw]
    # Определяем формат: "proxy" (одна колонка) или отдельные колонки
    # Также поддерживаем заголовок вида "proxy_(host:port:login:pass)" → "proxy"
    has_proxy_col = any(h.startswith("proxy") and h != "proxy_host" and h != "proxy_port"
                        for h in headers)
    has_separate = all(h in headers for h in ("proxy_host","proxy_port","login","password"))
    if has_proxy_col:
        # Найти индекс колонки proxy (может называться "proxy_(host:port:login:pass)")
        proxy_idx = None
        for i, h in enumerate(headers):
            if h.startswith("proxy") and h not in ("proxy_host", "proxy_port"):
                proxy_idx = i
                break
    if not has_proxy_col and not has_separate:
        log_fail("Формат таблицы не распознан")
        log_info("Нужны колонки: (n, proxy) или (n, proxy_host, proxy_port, login, password)")
        sys.exit(1)

    modems = {}
    skipped = 0
    for row_idx, row in enumerate(rows[1:], start=2):
        if len(row) < 2 or not row[0].strip():
            skipped += 1
            continue
        rd = {}
        for i, h in enumerate(headers):
            rd[h] = row[i].strip() if i < len(row) else ""
        try:
            n = int(rd.get("n", "0"))
        except ValueError:
            skipped += 1
            continue
        if n < 1 or n > 253:
            skipped += 1
            continue

        if has_proxy_col:
            proxy_val = row[proxy_idx].strip() if proxy_idx < len(row) else ""
            parts = proxy_val.split(":")
            if len(parts) < 4:
                log_warn(f"Строка {row_idx}: N={n}, формат proxy host:port:login:pass")
                skipped += 1
                continue
            proxy_host, proxy_port, login = parts[0], parts[1], parts[2]
            password = ":".join(parts[3:])
        else:
            proxy_host = rd.get("proxy_host","")
            proxy_port = rd.get("proxy_port","")
            login = rd.get("login","")
            password = rd.get("password","")

        if not all([proxy_host, proxy_port, login, password]):
            skipped += 1
            continue

        en_val = rd.get("enabled", "1").strip().lower()
        enabled = en_val not in ("0","false","no","off","нет","выкл","disabled","")

        modems[str(n)] = {
            "proxy_host": proxy_host,
            "proxy_port": int(proxy_port),
            "login": login,
            "password": password,
            "enabled": enabled,
        }

    log_ok(f"Модемов: {len(modems)}, пропущено: {skipped}")
    return modems

def do_sync(quiet=False):
    """Скачать таблицу → config.json. Возвращает config dict."""
    if not quiet:
        header("SYNC: Google Sheets → config.json")
        log_info(f"Режим: {GSHEET_MODE}")

    if GSHEET_MODE == "csv":
        rows = fetch_sheet_csv()
    elif GSHEET_MODE == "api_key":
        rows = fetch_sheet_api_key()
    elif GSHEET_MODE == "service_account":
        rows = fetch_sheet_service_account()
    else:
        log_fail(f"Неизвестный GSHEET_MODE: {GSHEET_MODE}"); sys.exit(1)

    modems = parse_sheet_rows(rows)
    if not modems:
        log_fail("Ни одного модема!"); sys.exit(1)

    config = {
        "modems": modems,
        "last_sync": datetime.now().isoformat(timespec="seconds"),
        "source": f"google_sheets ({GSHEET_MODE})",
        "sheet_id": SHEET_ID,
    }

    if CONFIG_FILE.exists() and not quiet:
        old = json.loads(CONFIG_FILE.read_text())
        old_n = set(old.get("modems",{}).keys())
        new_n = set(modems.keys())
        if new_n - old_n:
            log_info(f"Новые: {sorted(int(x) for x in new_n - old_n)}")
        if old_n - new_n:
            log_warn(f"Удалённые: {sorted(int(x) for x in old_n - new_n)}")

    save_config(config)
    enabled = sum(1 for m in modems.values() if m.get("enabled", True))
    if not quiet:
        log_ok(f"Сохранено: {enabled} активных, {len(modems)-enabled} отключённых")
    return config


# ══════════════════════════════════════════════════════════════
#  INSTALL
# ══════════════════════════════════════════════════════════════

def cmd_install():
    header("INSTALL: зависимости")

    log_step("apt update + install...")
    run("apt update -qq", capture=True)
    pkgs = "wget unzip curl iproute2 iptables dnsmasq tcpdump procps"
    run(f"apt install -y -qq {pkgs}", capture=True)
    log_ok(f"Пакеты: {pkgs}")

    run_safe("systemctl disable dnsmasq", quiet=True)
    run_safe("systemctl stop dnsmasq", quiet=True)
    log_ok("dnsmasq глобальный отключён")

    if Path(TUN2SOCKS_BIN).exists():
        log_ok(f"tun2socks уже установлен")
    else:
        log_step(f"Скачивание tun2socks v{TUN2SOCKS_VER}...")
        run(f"wget -q -O /tmp/tun2socks.zip '{TUN2SOCKS_URL}'", capture=True)
        run("unzip -o /tmp/tun2socks.zip -d /tmp/", capture=True)
        run(f"mv /tmp/tun2socks-linux-amd64 {TUN2SOCKS_BIN}")
        run(f"chmod +x {TUN2SOCKS_BIN}")
        run("rm -f /tmp/tun2socks.zip")
        log_ok("tun2socks установлен")

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    if not Path("/dev/net/tun").exists():
        log_fail("/dev/net/tun НЕ НАЙДЕН!")
        log_info("В конфиге LXC нужно: lxc.mount.entry: /dev/net/tun ...")
    else:
        log_ok("/dev/net/tun доступен")


# ══════════════════════════════════════════════════════════════
#  INIT
# ══════════════════════════════════════════════════════════════

def check_lxc_requirements():
    """Проверить все требования LXC. Если что-то не так — инструкция и выход."""
    has_eth1 = eth1_exists()
    has_tun = Path("/dev/net/tun").exists()

    if has_eth1 and has_tun:
        return True

    hostname = get_ct_id()
    problems = []
    if not has_tun:
        problems.append(f"{RD}✗{R} /dev/net/tun не найден (нужен для tun2socks)")
    if not has_eth1:
        problems.append(f"{RD}✗{R} {ETH_TRUNK} не найден (нужен trunk-порт на VLAN-мост)")

    print(f"""
{RD}{'━'*60}
  ОШИБКА: контейнер не готов к работе!
{'━'*60}{R}
""")
    for p in problems:
        print(f"  {p}")

    print(f"""
  Выполни на {B}хосте Proxmox{R} (не в контейнере!):

  {B}# 0. Узнать CT ID:{R}
  {G}pct list{R}

  {B}# 1. Остановить контейнер:{R}
  {G}pct stop <CT_ID>{R}
""")

    if not has_tun:
        print(f"""\
  {B}# 2. Настроить LXC (privileged + nesting + tun):{R}
  {G}cat >> /etc/pve/lxc/<CT_ID>.conf << 'EOF'
unprivileged: 0
features: nesting=1
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file 0 0
EOF{R}

  {Y}⚠ Проверь что эти строки не дублируются:{R}
  {G}cat /etc/pve/lxc/<CT_ID>.conf{R}
""")

    print(f"""\
  {B}# 3. Создать VLAN-aware мост (если ещё нет):{R}
  {G}grep -q vmbr101 /etc/network/interfaces || cat >> /etc/network/interfaces << 'EOF'

auto vmbr101
iface vmbr101 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 1-100
EOF
  ifup vmbr101{R}
""")

    if not has_eth1:
        print(f"""\
  {B}# 4. Добавить eth1 в контейнер:{R}
  {G}pct set <CT_ID> -net1 name=eth1,bridge=vmbr101,type=veth{R}
""")

    print(f"""\
  {B}# 5. Запустить контейнер:{R}
  {G}pct start <CT_ID>{R}

  {D}Hostname контейнера: {hostname}
  Узнать CT ID: pct list | grep {hostname}{R}

  После этого запусти скрипт ещё раз.
""")
    sys.exit(1)


def cmd_init():
    header("INIT: br_mgmt + NAT + eth1")

    check_lxc_requirements()

    if is_bridge_exists(MGMT_BRIDGE):
        log_warn(f"{MGMT_BRIDGE} уже есть, пропуск")
    else:
        run(f"ip link add {MGMT_BRIDGE} type bridge")
        run(f"ip addr add {MGMT_GW}/24 dev {MGMT_BRIDGE}")
        run(f"ip link set {MGMT_BRIDGE} up")
        log_ok(f"{MGMT_BRIDGE} создан ({MGMT_GW}/24)")

    run("sysctl -w net.ipv4.ip_forward=1", capture=True)
    log_ok("ip_forward=1")

    r = run_safe("iptables -t nat -C POSTROUTING -s 10.255.0.0/24 -o eth0 -j MASQUERADE",
                 capture=True, quiet=True)
    if r.returncode != 0:
        run(f"iptables -t nat -A POSTROUTING -s {MGMT_SUBNET}.0/24 -o {ETH_WAN} -j MASQUERADE")
        log_ok(f"NAT: {MGMT_SUBNET}.0/24 → {ETH_WAN}")
    else:
        log_warn("NAT уже настроен")

    run(f"ip link set {ETH_TRUNK} up")
    log_ok(f"{ETH_TRUNK} поднят (trunk)")

    if not Path(TUN2SOCKS_BIN).exists():
        log_fail(f"tun2socks не найден! Запусти: proxyveth install")
    else:
        log_ok(f"tun2socks OK")

def ensure_init():
    if not is_bridge_exists(MGMT_BRIDGE):
        cmd_init()


# ══════════════════════════════════════════════════════════════
#  PATH + Symlink + Systemd
# ══════════════════════════════════════════════════════════════

def setup_path():
    """Добавить /usr/local/bin в PATH + создать symlink."""
    # Symlink
    link = Path("/usr/local/bin/proxyveth")
    if not link.exists() or not link.is_symlink():
        link.unlink(missing_ok=True)
        link.symlink_to(SCRIPT_PATH)
        log_ok("Symlink: proxyveth → proxyveth.py")

    # bashrc PATH
    bashrc = Path("/root/.bashrc")
    marker = "# proxyveth PATH"
    if bashrc.exists():
        content = bashrc.read_text()
    else:
        content = ""
    if marker not in content:
        bashrc.write_text(content + f'\n{marker}\nexport PATH="/usr/local/bin:$PATH"\n')
        log_ok("PATH добавлен в ~/.bashrc")

    # Для текущей сессии
    os.environ["PATH"] = f"/usr/local/bin:{os.environ.get('PATH','')}"


def setup_systemd():
    """Создать systemd units для proxyveth + watchdog + autosync."""
    header("SYSTEMD: создание сервисов")

    py = "/usr/bin/python3"
    script = str(SCRIPT_PATH)

    # 1. Main service
    Path("/etc/systemd/system/proxyveth.service").write_text(f"""\
[Unit]
Description=ProxyVeth - namespace manager
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre={py} {script} sync
ExecStart={py} {script} init
ExecStart={py} {script} up all
ExecStop={py} {script} down all

[Install]
WantedBy=multi-user.target
""")
    log_ok("proxyveth.service")

    # 2. Watchdog
    Path("/etc/systemd/system/proxyveth-watchdog.service").write_text(f"""\
[Unit]
Description=ProxyVeth Watchdog
After=proxyveth.service
Requires=proxyveth.service

[Service]
Type=simple
ExecStart={py} {script} watchdog-loop
Restart=always
RestartSec=10
Environment=WATCHDOG_INTERVAL=60
Environment=WATCHDOG_WAN_EVERY=10
Environment=WATCHDOG_MAX_RESTART=3

[Install]
WantedBy=multi-user.target
""")
    log_ok("proxyveth-watchdog.service")

    # 3. Autosync timer
    Path("/etc/systemd/system/proxyveth-autosync.service").write_text(f"""\
[Unit]
Description=ProxyVeth Autosync
After=proxyveth.service

[Service]
Type=oneshot
ExecStart={py} {script} autosync
""")

    Path("/etc/systemd/system/proxyveth-autosync.timer").write_text(f"""\
[Unit]
Description=ProxyVeth Autosync Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
""")
    log_ok("proxyveth-autosync.timer (каждые 5 мин)")

    # Enable
    run("systemctl daemon-reload", capture=True)
    run("systemctl enable proxyveth.service", capture=True)
    run("systemctl enable proxyveth-watchdog.service", capture=True)
    run("systemctl enable proxyveth-autosync.timer", capture=True)
    log_ok("Все сервисы enabled")

    # Start watchdog + timer
    run_safe("systemctl start proxyveth-watchdog.service", capture=True, quiet=True)
    run_safe("systemctl start proxyveth-autosync.timer", capture=True, quiet=True)
    log_ok("Watchdog и autosync запущены")


# ══════════════════════════════════════════════════════════════
#  SETUP — полный первый запуск
# ══════════════════════════════════════════════════════════════

def cmd_setup():
    """Полная установка: install → sync → init → up all → systemd → PATH."""
    header("ProxyVeth — ПОЛНАЯ УСТАНОВКА")
    print(f"""
  {D}Этот скрипт выполнит:{R}
  1. Установка зависимостей (tun2socks, dnsmasq, ...)
  2. Загрузка прокси из Google Sheets
  3. Проверка eth1 (инструкция если нет)
  4. Настройка br_mgmt + NAT
  5. Поднятие всех namespace
  6. Настройка systemd (автостарт + watchdog + autosync)
  7. Настройка PATH
""")

    # 1. Install
    cmd_install()

    # 2. Sync
    config = do_sync()

    # 3+4. Init (проверит eth1 внутри)
    cmd_init()

    # 5. Up all
    cmd_up("all")

    # 6. Systemd
    setup_systemd()

    # 7. PATH
    setup_path()

    # Summary
    enabled = len(get_enabled_modems(config))
    active = len(get_active_ns_list())
    print(f"""
{G}{'═'*60}
  УСТАНОВКА ЗАВЕРШЕНА!
{'═'*60}{R}

  {G}✓{R} Namespace поднято: {active}/{enabled}
  {G}✓{R} Watchdog: запущен (проверка каждые 60с)
  {G}✓{R} Autosync: запущен (проверка таблицы каждые 5 мин)
  {G}✓{R} Автостарт: при перезагрузке контейнера

  {B}Команды:{R}
    proxyveth status          — статус всех NS
    proxyveth status --wan    — с проверкой WAN IP (медленно)
    proxyveth check N         — полная проверка одного NS
    proxyveth restart N       — перезапуск одного NS
    proxyveth restart all     — перезапуск всех NS
    proxyveth down all        — остановить всё

  {B}Логи:{R}
    journalctl -u proxyveth-watchdog -f
    cat {WATCHDOG_LOG}

  {D}Перезайди в терминал чтобы PATH обновился,
  или выполни: export PATH="/usr/local/bin:$PATH"{R}
""")


# ══════════════════════════════════════════════════════════════
#  NS UP
# ══════════════════════════════════════════════════════════════

def ns_up(n, modem):
    vlan_id = VLAN_OFFSET + n
    ph = modem["proxy_host"]
    pp = modem["proxy_port"]
    proxy_url = f"socks5://{modem['login']}:{modem['password']}@{ph}:{pp}"
    mgmt_ip = f"{MGMT_SUBNET}.{n + 1}"

    print(f"\n  {B}── NS {n} ──{R}  VLAN={vlan_id}  proxy={ph}:{pp}")

    if is_ns_exists(n):
        log_warn(f"ns_{n} уже есть — пропуск (используй restart)")
        return True

    try:
        # 1. VLAN
        run(f"ip link add link {ETH_TRUNK} name {ETH_TRUNK}.{vlan_id} type vlan id {vlan_id}")
        # 2. Namespace
        run(f"ip netns add ns_{n}")
        run(f"ip netns exec ns_{n} ip link set lo up")
        ns_dns = Path(f"/etc/netns/ns_{n}")
        ns_dns.mkdir(parents=True, exist_ok=True)
        (ns_dns / "resolv.conf").write_text(f"nameserver {DNS_SERVER}\n")
        # 3. VLAN → ns
        run(f"ip link set {ETH_TRUNK}.{vlan_id} netns ns_{n}")
        run(f"ip addr add 192.168.{n}.2/24 dev {ETH_TRUNK}.{vlan_id}", ns=n)
        run(f"ip link set {ETH_TRUNK}.{vlan_id} up", ns=n)
        # 4. veth
        run(f"ip link add veth_m{n}_host type veth peer name veth_m{n}_ns")
        run(f"ip link set veth_m{n}_host master {MGMT_BRIDGE}")
        run(f"ip link set veth_m{n}_host up")
        run(f"ip link set veth_m{n}_ns netns ns_{n}")
        run(f"ip addr add {mgmt_ip}/24 dev veth_m{n}_ns", ns=n)
        run(f"ip link set veth_m{n}_ns up", ns=n)
        # 5. Маршруты mgmt
        run(f"ip route add {ph}/32 via {MGMT_GW}", ns=n)
        run(f"ip route add {DNS_SERVER}/32 via {MGMT_GW}", ns=n)
        log_step(f"ns_{n}: VLAN + veth + маршруты")
        # 6. (iptables FORWARD — после создания tun, см. шаг 8b)
        # 7. tun2socks
        run(f"nohup {TUN2SOCKS_BIN} -device tun{n} -proxy {proxy_url} "
            f"-loglevel silent > /dev/null 2>&1 &", ns=n, capture=False)
        time.sleep(TUN2SOCKS_WAIT)
        r = run_safe(f"ip link show tun{n}", ns=n, quiet=True)
        if r.returncode != 0:
            raise RuntimeError(f"tun{n} не создан! tun2socks не запустился?")
        # 8. tun маршруты
        run(f"ip addr add 10.0.{n}.1/30 dev tun{n}", ns=n)
        run(f"ip link set tun{n} up", ns=n)
        run(f"ip route add default dev tun{n}", ns=n)
        run(f"ip route add 192.168.{n}.1/32 dev tun{n}", ns=n)  # КРИТИЧНО!
        # 8b. iptables: блокируем ВЕСЬ UDP через tun (DNS идёт через mgmt, не через tun)
        run(f"iptables -A OUTPUT  -o tun{n} -p udp -j DROP", ns=n)
        run(f"iptables -A FORWARD -o tun{n} -p udp -j DROP", ns=n)
        # 8c. DNS перехват: любой UDP:53 от Win10 → локальный dnsmasq
        #     3proxy может слать на 1.1.1.1/8.8.8.8 — всё равно попадёт в dnsmasq
        run(f"iptables -t nat -A PREROUTING -i {ETH_TRUNK}.{vlan_id} -p udp --dport 53 "
            f"-j DNAT --to-destination 192.168.{n}.2:53", ns=n)
        # 10. sysctl
        run("sysctl -w net.ipv4.ip_forward=1", ns=n)
        run("sysctl -w net.ipv4.conf.all.proxy_arp=1", ns=n)
        # 11. DHCP + DNS (dnsmasq как DNS-форвардер)
        lease = f"/tmp/dnsmasq_ns{n}.leases"
        pid = f"/run/dnsmasq_ns{n}.pid"
        Path(lease).unlink(missing_ok=True)
        run(f"nohup {DNSMASQ_BIN} "
            f"--interface={ETH_TRUNK}.{vlan_id} --bind-interfaces "
            f"--listen-address=192.168.{n}.2 "
            f"--server={DNS_SERVER} "
            f"--dhcp-range=192.168.{n}.100,192.168.{n}.100,255.255.255.0,60s "
            f"--dhcp-option=3,192.168.{n}.2 "
            f"--dhcp-option=6,192.168.{n}.2 "
            f"--dhcp-leasefile={lease} --dhcp-authoritative "
            f"--pid-file={pid} --no-daemon > /dev/null 2>&1 &", ns=n, capture=False)

        log_ok(f"ns_{n} ГОТОВ  192.168.{n}.100 gw .2 | модем .1")
        return True
    except Exception as e:
        log_fail(f"ns_{n}: {e}")
        ns_down(n, quiet=True)
        return False


# ══════════════════════════════════════════════════════════════
#  NS DOWN
# ══════════════════════════════════════════════════════════════

def ns_down(n, quiet=False):
    if not quiet:
        print(f"  {D}↓ ns_{n}{R}", end="")

    # Kill tun2socks + dnsmasq
    run_safe(f"pkill -f 'tun2socks.*-device.tun{n}[^0-9]'", quiet=True)
    run_safe(f"pkill -f 'tun2socks.*-device.tun{n}$'", quiet=True)
    pid_file = Path(f"/run/dnsmasq_ns{n}.pid")
    if pid_file.exists():
        try:
            run_safe(f"kill {int(pid_file.read_text().strip())}", quiet=True)
        except (ValueError, OSError):
            pass
    run_safe(f"pkill -f 'dnsmasq.*ns{n}\\.leases'", quiet=True)
    time.sleep(0.3)

    run_safe(f"ip netns del ns_{n}", quiet=True)

    Path(f"/tmp/dnsmasq_ns{n}.leases").unlink(missing_ok=True)
    pid_file.unlink(missing_ok=True)
    dns_dir = Path(f"/etc/netns/ns_{n}")
    if dns_dir.exists():
        for f in dns_dir.iterdir():
            f.unlink()
        dns_dir.rmdir()
    run_safe(f"ip link del veth_m{n}_host", quiet=True)

    if not quiet:
        print(f" {G}✓{R}")
    return True


# ══════════════════════════════════════════════════════════════
#  AUTOSYNC — sync + пересоздание изменённых NS
# ══════════════════════════════════════════════════════════════

def cmd_autosync():
    """Скачать таблицу, сравнить с текущим конфигом, пересоздать изменённые."""
    old_config = {}
    if CONFIG_FILE.exists():
        old_config = json.loads(CONFIG_FILE.read_text())
    old_modems = old_config.get("modems", {})

    new_config = do_sync(quiet=True)
    new_modems = new_config.get("modems", {})

    old_keys = set(old_modems.keys())
    new_keys = set(new_modems.keys())

    to_add = new_keys - old_keys
    to_remove = old_keys - new_keys
    to_check = old_keys & new_keys

    # Найти изменённые (proxy данные или enabled поменялись)
    to_restart = set()
    for k in to_check:
        om, nm = old_modems[k], new_modems[k]
        if (om.get("proxy_host") != nm.get("proxy_host") or
            om.get("proxy_port") != nm.get("proxy_port") or
            om.get("login") != nm.get("login") or
            om.get("password") != nm.get("password")):
            to_restart.add(k)
        # Если стал disabled — удалить
        if nm.get("enabled", True) == False and om.get("enabled", True) == True:
            to_remove.add(k)
            to_restart.discard(k)
        # Если стал enabled — добавить
        if nm.get("enabled", True) == True and om.get("enabled", True) == False:
            to_add.add(k)
            to_restart.discard(k)

    changes = len(to_add) + len(to_remove) + len(to_restart)
    if changes == 0:
        return  # Тихо, ничего не делаем

    wlog(f"AUTOSYNC: +{len(to_add)} -{len(to_remove)} ~{len(to_restart)}")

    ensure_init()

    # Удалить
    for k in to_remove:
        n = int(k)
        if is_ns_exists(n):
            wlog(f"  REMOVE ns_{n}")
            ns_down(n, quiet=True)

    # Перезапустить изменённые
    for k in to_restart:
        n = int(k)
        m = new_modems[k]
        if m.get("enabled", True):
            wlog(f"  RESTART ns_{n} (proxy changed)")
            ns_down(n, quiet=True)
            time.sleep(0.5)
            ns_up(n, m)

    # Добавить новые
    for k in to_add:
        n = int(k)
        m = new_modems[k]
        if m.get("enabled", True) and not is_ns_exists(n):
            wlog(f"  ADD ns_{n}")
            ns_up(n, m)

    wlog(f"AUTOSYNC done: +{len(to_add)} -{len(to_remove)} ~{len(to_restart)}")


# ══════════════════════════════════════════════════════════════
#  WATCHDOG
# ══════════════════════════════════════════════════════════════

def watchdog_check_ns(n, modem, check_wan=False):
    if not is_ns_exists(n):
        return "ns_missing"
    tun_ok = is_process_running(f"tun2socks.*-device.tun{n}")
    dns_ok = is_process_running(f"dnsmasq.*ns{n}")
    if not tun_ok and not dns_ok: return "both_dead"
    if not tun_ok: return "tun_dead"
    if not dns_ok: return "dns_dead"
    if check_wan:
        r = run_safe(f"curl -s --max-time {CURL_TIMEOUT} http://ip-api.com/line/?fields=query",
                     ns=n, capture=True, quiet=True)
        if r.returncode != 0 or not r.stdout.strip():
            return "wan_dead"
    return "ok"

def watchdog_restart_dnsmasq(n):
    vlan_id = VLAN_OFFSET + n
    lease = f"/tmp/dnsmasq_ns{n}.leases"
    pid = f"/run/dnsmasq_ns{n}.pid"
    Path(lease).unlink(missing_ok=True)
    run_safe(f"nohup {DNSMASQ_BIN} "
             f"--interface={ETH_TRUNK}.{vlan_id} --bind-interfaces "
             f"--listen-address=192.168.{n}.2 "
             f"--server={DNS_SERVER} "
             f"--dhcp-range=192.168.{n}.100,192.168.{n}.100,255.255.255.0,60s "
             f"--dhcp-option=3,192.168.{n}.2 "
             f"--dhcp-option=6,192.168.{n}.2 "
             f"--dhcp-leasefile={lease} --dhcp-authoritative "
             f"--pid-file={pid} --no-daemon > /dev/null 2>&1 &", ns=n, capture=False, quiet=True)
    time.sleep(0.5)
    ok = is_process_running(f"dnsmasq.*ns{n}")
    if ok: wlog(f"  ✓ ns_{n}: dnsmasq restart OK")
    return ok

def watchdog_pass(config, pass_number):
    modems = get_enabled_modems(config)
    check_wan = (pass_number % WATCHDOG_WAN_EVERY == 0)
    ok_count, restarted, failed = 0, 0, 0

    rc_file = CONFIG_DIR / "restart_counts.json"
    restart_counts = {}
    if rc_file.exists():
        try: restart_counts = json.loads(rc_file.read_text())
        except: pass

    for n, modem in modems:
        status = watchdog_check_ns(n, modem, check_wan=check_wan)
        if status == "ok":
            ok_count += 1
            restart_counts.pop(str(n), None)
            continue

        n_str = str(n)
        rc = restart_counts.get(n_str, 0)
        if rc >= WATCHDOG_MAX_RESTART:
            wlog(f"  ✗ ns_{n}: {status} — MAX RESTARTS ({rc})")
            failed += 1
            continue

        wlog(f"  ⚠ ns_{n}: {status} ({rc+1}/{WATCHDOG_MAX_RESTART})")

        if status == "ns_missing":
            ensure_init()
            success = ns_up(n, modem)
        elif status == "dns_dead":
            success = watchdog_restart_dnsmasq(n)
        else:
            ns_down(n, quiet=True); time.sleep(1)
            success = ns_up(n, modem)

        if success:
            restarted += 1; restart_counts.pop(n_str, None)
        else:
            failed += 1; restart_counts[n_str] = rc + 1

    try: rc_file.write_text(json.dumps(restart_counts))
    except: pass
    return ok_count, restarted, failed

def cmd_watchdog():
    header("WATCHDOG: проверка")
    config = load_config()
    ok, restarted, failed = watchdog_pass(config, 1)
    log_info(f"OK: {ok}  Restart: {restarted}  Fail: {failed}")

def cmd_watchdog_loop():
    wlog("WATCHDOG STARTED")
    stop = [False]
    def handler(s, f): stop[0] = True
    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)
    config = load_config()
    p = 0
    while not stop[0]:
        p += 1
        try:
            ok, re, fa = watchdog_pass(config, p)
            if re > 0 or fa > 0:
                wlog(f"Pass #{p}: OK={ok} RESTART={re} FAIL={fa}")
            elif p % 10 == 0:
                wlog(f"Pass #{p}: all {ok} OK")
        except Exception as e:
            wlog(f"Pass #{p} ERROR: {e}")
        for _ in range(WATCHDOG_INTERVAL):
            if stop[0]: break
            time.sleep(1)
    wlog("WATCHDOG STOPPED")


# ══════════════════════════════════════════════════════════════
#  Прочие команды
# ══════════════════════════════════════════════════════════════

def cmd_up(target):
    config = load_config()
    ensure_init()
    if target == "all":
        header("UP ALL")
        modems = get_enabled_modems(config)
        log_info(f"Модемов: {len(modems)}")
        ok, fail = 0, 0
        t0 = time.time()
        for n, m in modems:
            if ns_up(n, m):
                ok += 1
            else:
                fail += 1
        elapsed = time.time() - t0
        header(f"РЕЗУЛЬТАТ: {ok} ✓ поднято, {fail} ✗ ошибок ({elapsed:.0f}с)")
    else:
        ns_up(int(target), get_modem(config, int(target)))

def cmd_down(target):
    if target == "all":
        header("DOWN ALL")
        ns_list = get_active_ns_list()
        if not ns_list:
            log_info("Нет активных NS"); return
        for n in ns_list:
            ns_down(n)
        log_ok(f"Удалено: {len(ns_list)}")
    else:
        ns_down(int(target))

def cmd_restart(target):
    config = load_config()
    ensure_init()
    if target == "all":
        header("RESTART ALL")
        cmd_down("all"); time.sleep(1); cmd_up("all")
    else:
        n = int(target)
        ns_down(n); time.sleep(1); ns_up(n, get_modem(config, n))

def cmd_status(check_wan=False):
    header("STATUS")
    config = load_config()
    modems = config.get("modems", {})
    active_ns = set(get_active_ns_list())

    wh = "  WAN IP" if check_wan else ""
    print(f"\n  {'N':>3} │ {'Proxy':^24} │ {'NS':^6} │ {'tun':^5} │ {'dhcp':^5} │ {'En':^3}{wh}")
    print(f"  {'─'*3}─┼─{'─'*24}─┼─{'─'*6}─┼─{'─'*5}─┼─{'─'*5}─┼─{'─'*3}"
          f"{'─┼─'+'─'*15 if check_wan else ''}")

    up, down, disabled = 0, 0, 0
    for n_str in sorted(modems.keys(), key=lambda x: int(x)):
        n = int(n_str)
        m = modems[n_str]
        en = m.get("enabled", True)
        ps = f"{m['proxy_host']}:{m['proxy_port']}"
        if not en:
            disabled += 1
            print(f"  {n:>3} │ {ps:<24} │ {D}{'—':^6}{R} │ {D}{'—':^5}{R} │ {D}{'—':^5}{R} │ {D}off{R}")
            continue
        if n in active_ns:
            up += 1
            ns_m = f"{G}{'UP':^6}{R}"
            t = is_process_running(f"tun2socks.*-device.tun{n}")
            d = is_process_running(f"dnsmasq.*ns{n}")
            tm = f"{G}{'✓':^5}{R}" if t else f"{RD}{'✗':^5}{R}"
            dm = f"{G}{'✓':^5}{R}" if d else f"{RD}{'✗':^5}{R}"
            w = ""
            if check_wan:
                wr = run_safe(f"curl -s --max-time {CURL_TIMEOUT} http://ip-api.com/line/?fields=query",
                              ns=n, capture=True, quiet=True)
                w = f" │ {(wr.stdout.strip() if wr.returncode==0 else '—'):<15}"
        else:
            down += 1
            ns_m = f"{RD}{'DOWN':^6}{R}"
            tm = f"{D}{'—':^5}{R}"; dm = f"{D}{'—':^5}{R}"
            w = f" │ {'—':<15}" if check_wan else ""
        em = f"{G}✓{R}  "
        print(f"  {n:>3} │ {ps:<24} │ {ns_m} │ {tm} │ {dm} │ {em}{w}")

    print()
    log_info(f"UP: {up}  DOWN: {down}  Disabled: {disabled}  Total: {len(modems)}")
    if config.get("last_sync"):
        log_info(f"Sync: {config['last_sync']}")

def cmd_check(target):
    n = int(target)
    header(f"CHECK ns_{n}")
    if not is_ns_exists(n):
        log_fail(f"ns_{n} не существует"); return

    r = run_safe(f"curl -s --max-time {CURL_TIMEOUT} http://ip-api.com/line/?fields=query",
                 ns=n, capture=True, quiet=True)
    (log_ok if r.returncode==0 and r.stdout.strip() else log_fail)(
        f"WAN IP: {r.stdout.strip() if r.returncode==0 else 'недоступен'}")

    r = run_safe(f"curl -s --max-time 5 http://192.168.{n}.1/api/webserver/SesTokInfo",
                 ns=n, capture=True, quiet=True)
    (log_ok if r.returncode==0 and 'SesInfo' in r.stdout else log_fail)(
        f"Модем 192.168.{n}.1: {'OK' if r.returncode==0 and 'SesInfo' in r.stdout else 'недоступен'}")

    t = is_process_running(f"tun2socks.*-device.tun{n}")
    d = is_process_running(f"dnsmasq.*ns{n}")
    (log_ok if t else log_fail)(f"tun2socks: {'OK' if t else 'DEAD'}")
    (log_ok if d else log_fail)(f"dnsmasq: {'OK' if d else 'DEAD'}")

    log_step("Маршруты:")
    r = run_safe("ip route", ns=n, capture=True)
    for line in r.stdout.strip().split("\n"):
        print(f"    {D}{line}{R}")

def cmd_cleanup():
    header("CLEANUP")
    run_safe("pkill tun2socks", quiet=True)
    run_safe("pkill -f 'dnsmasq.*dhcp-leasefile=/tmp/dnsmasq_ns'", quiet=True)
    time.sleep(1)
    for n in get_active_ns_list():
        run_safe(f"ip netns del ns_{n}", quiet=True)
    if is_bridge_exists(MGMT_BRIDGE):
        run_safe(f"ip link del {MGMT_BRIDGE}", quiet=True)
    run_safe("iptables -t nat -F", quiet=True)
    import glob
    for p in ["/etc/netns/ns_*", "/tmp/dnsmasq_ns*", "/run/dnsmasq_ns*"]:
        for path in glob.glob(p):
            pp = Path(path)
            if pp.is_dir():
                for f in pp.iterdir(): f.unlink()
                pp.rmdir()
            else: pp.unlink()
    (CONFIG_DIR / "restart_counts.json").unlink(missing_ok=True)
    log_ok("Очистка завершена. Перезагрузи контейнер.")

def cmd_show_config():
    config = load_config()
    modems = config.get("modems", {})
    en = sum(1 for m in modems.values() if m.get("enabled", True))
    print(f"\n  {CONFIG_FILE}  |  Sync: {config.get('last_sync','—')}")
    print(f"  Модемов: {len(modems)} (en: {en}, dis: {len(modems)-en})\n")
    for k in sorted(modems.keys(), key=lambda x: int(x)):
        m = modems[k]
        e = f"{G}✓{R}" if m.get("enabled",True) else f"{RD}✗{R}"
        print(f"  {e} {int(k):>3}  {m['proxy_host']}:{m['proxy_port']}  {m['login']}")


# ══════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════

USAGE = f"""{B}ProxyVeth v2.0{R}

{C}Первый запуск:{R}
  python3 /usr/local/bin/proxyveth.py      (без аргументов = полная установка)

{C}Команды:{R}
  sync                    Google Sheets → config.json
  autosync                Sync + пересоздать изменённые NS
  init                    br_mgmt + NAT + eth1
  up    [N|all]           Поднять
  down  [N|all]           Опустить
  restart [N|all]         Перезапустить
  status [--wan]          Статус
  check  N                Проверка одного NS
  watchdog                Один проход
  watchdog-loop           Бесконечный цикл
  cleanup                 Полная очистка
  show-config             Конфиг
"""

def main():
    if len(sys.argv) < 2:
        cmd_setup()
        return

    cmd = sys.argv[1].lower().replace("-", "_")
    arg = sys.argv[2] if len(sys.argv) > 2 else None
    flags = sys.argv[2:]

    try:
        if cmd == "setup":          cmd_setup()
        elif cmd == "install":      cmd_install()
        elif cmd == "sync":         do_sync()
        elif cmd == "autosync":     cmd_autosync()
        elif cmd == "init":         cmd_init()
        elif cmd == "up":
            if not arg: log_fail("proxyveth up [N|all]"); sys.exit(1)
            cmd_up(arg)
        elif cmd == "down":
            if not arg: log_fail("proxyveth down [N|all]"); sys.exit(1)
            cmd_down(arg)
        elif cmd == "restart":
            if not arg: log_fail("proxyveth restart [N|all]"); sys.exit(1)
            cmd_restart(arg)
        elif cmd == "status":       cmd_status(check_wan="--wan" in flags)
        elif cmd == "check":
            if not arg: log_fail("proxyveth check N"); sys.exit(1)
            cmd_check(arg)
        elif cmd == "watchdog":       cmd_watchdog()
        elif cmd == "watchdog_loop":  cmd_watchdog_loop()
        elif cmd == "cleanup":        cmd_cleanup()
        elif cmd == "show_config":    cmd_show_config()
        else:
            log_fail(f"Неизвестная команда: {cmd}"); print(USAGE); sys.exit(1)
    except KeyboardInterrupt:
        print(f"\n{Y}Прервано{R}"); sys.exit(130)
    except SystemExit:
        raise
    except Exception as e:
        log_fail(f"Ошибка: {e}"); sys.exit(1)

if __name__ == "__main__":
    main()
