cat > /usr/local/bin/proxyveth_mp.py << 'PYEOF'
#!/usr/bin/env python3
"""
ProxyVethMP v1.0
SOCKS5 → namespace + tun2socks → veth → mp.space source routing.
"""
import os, sys, json, time, subprocess, csv, io, signal
from pathlib import Path
from datetime import datetime

SHEET_CSV_URL   = os.getenv("SHEET_CSV_URL", "")
SHEET_ID        = os.getenv("SHEET_ID", "")
SHEET_GID       = int(os.getenv("SHEET_GID", "0"))
CONFIG_DIR      = Path(os.getenv("PROXYVETHMP_DIR", "/etc/proxyvethmp"))
CONFIG_FILE     = CONFIG_DIR / "config.json"
ENV_FILE        = CONFIG_DIR / "env"
LOG_DIR         = CONFIG_DIR / "logs"
WATCHDOG_LOG    = LOG_DIR / "watchdog.log"
SCRIPT_PATH     = Path("/usr/local/bin/proxyveth_mp.py")
TUN2SOCKS_BIN   = "/usr/local/bin/tun2socks"
TUN2SOCKS_VER   = "2.5.2"
TUN2SOCKS_URL   = (f"https://github.com/xjasonlyu/tun2socks/releases/download/"
                   f"v{TUN2SOCKS_VER}/tun2socks-linux-amd64.zip")
ETH_WAN         = "eth0"
DNS_SERVERS     = ["8.8.8.8", "8.8.4.4"]
DNS_SERVER      = "8.8.8.8"
RT_TABLE_BASE   = 100
TUN2SOCKS_WAIT  = 3
CURL_TIMEOUT    = 10
WATCHDOG_INTERVAL    = int(os.getenv("WATCHDOG_INTERVAL",    "60"))
WATCHDOG_WAN_EVERY   = int(os.getenv("WATCHDOG_WAN_EVERY",   "10"))
WATCHDOG_MAX_RESTART = int(os.getenv("WATCHDOG_MAX_RESTART", "3"))

R="\033[0m"; G="\033[32m"; RD="\033[31m"; Y="\033[33m"; C="\033[36m"; B="\033[1m"; D="\033[2m"
def log_ok(m):   print(f"  {G}✓{R} {m}")
def log_fail(m): print(f"  {RD}✗{R} {m}")
def log_info(m): print(f"  {C}ℹ{R} {m}")
def log_warn(m): print(f"  {Y}⚠{R} {m}")
def log_step(m): print(f"  {D}→{R} {m}")
def header(m):   print(f"\n{B}{'═'*60}\n  {m}\n{'═'*60}{R}")

def wlog(msg):
    ts=datetime.now().strftime("%Y-%m-%d %H:%M:%S"); line=f"[{ts}] {msg}"; print(line)
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        open(WATCHDOG_LOG,"a").write(line+"\n")
    except: pass

def run(cmd, ns=None, check=True, capture=True, quiet=False):
    if ns is not None: cmd=f"ip netns exec ns_{ns} {cmd}"
    r=subprocess.run(cmd, shell=True, capture_output=capture, text=True)
    if check and r.returncode!=0:
        if not quiet:
            log_fail(f"CMD: {cmd}")
            if r.stderr.strip(): log_fail(f"  stderr: {r.stderr.strip()}")
        raise RuntimeError(f"rc={r.returncode}: {cmd}")
    return r

def run_safe(cmd, **kw): return run(cmd, check=False, **kw)

def is_ns_exists(n):
    r=run_safe("ip netns list", capture=True)
    for line in r.stdout.strip().split("\n"):
        if line.split()[0] if line.strip() else ""==f"ns_{n}": return True
    return f"ns_{n}" in r.stdout

def is_process_running(pattern):
    return run_safe(f"pgrep -f '{pattern}'", capture=True).returncode==0

def get_active_ns_list():
    r=run_safe("ip netns list", capture=True); result=[]
    for line in r.stdout.strip().split("\n"):
        name=line.split()[0] if line.strip() else ""
        if name.startswith("ns_"):
            try: result.append(int(name.split("_")[1]))
            except: pass
    return sorted(result)

def _ensure_rt_table(table_id, name):
    rt=Path("/etc/iproute2/rt_tables")
    if not rt.exists() or str(table_id) in rt.read_text(): return
    open(rt,"a").write(f"{table_id}\t{name}\n")

def _load_env_file():
    global SHEET_CSV_URL, SHEET_ID, SHEET_GID
    if not ENV_FILE.exists(): return
    for line in ENV_FILE.read_text().splitlines():
        line=line.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        k,v=line.split("=",1); os.environ.setdefault(k.strip(),v.strip())
    SHEET_CSV_URL=os.getenv("SHEET_CSV_URL",SHEET_CSV_URL)
    SHEET_ID=os.getenv("SHEET_ID",SHEET_ID)

def load_config():
    if not CONFIG_FILE.exists():
        log_fail(f"Конфиг не найден: {CONFIG_FILE}"); log_info("Запусти: proxyveth sync"); sys.exit(1)
    return json.loads(CONFIG_FILE.read_text())

def save_config(data):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    open(CONFIG_FILE,"w").write(json.dumps(data, indent=2, ensure_ascii=False))

def get_enabled_modems(config):
    return sorted([(int(k),v) for k,v in config.get("modems",{}).items() if v.get("enabled",True)], key=lambda x:x[0])

def get_modem(config, n):
    m=config.get("modems",{}).get(str(n))
    if not m: log_fail(f"Модем N={n} не найден"); sys.exit(1)
    return m

def fetch_sheet_csv():
    import urllib.request
    if not SHEET_CSV_URL and not SHEET_ID:
        log_fail("Задай SHEET_CSV_URL или SHEET_ID"); sys.exit(1)
    url=(SHEET_CSV_URL or f"https://docs.google.com/spreadsheets/d/{SHEET_ID}/export?format=csv&gid={SHEET_GID}")
    log_step(f"CSV: {url[:70]}...")
    with urllib.request.urlopen(urllib.request.Request(url), timeout=15) as resp:
        return list(csv.reader(io.StringIO(resp.read().decode("utf-8-sig"))))

def parse_sheet_rows(rows):
    if len(rows)<2: raise ValueError("Таблица пустая")
    alt={"host":"proxy_host","ip":"proxy_host","server":"proxy_host","port":"proxy_port",
         "user":"login","username":"login","pass":"password","pwd":"password"}
    headers=[alt.get(h.strip().lower().replace(" ","_"),h.strip().lower().replace(" ","_")) for h in rows[0]]
    log_step(f"Заголовки: {headers}")
    has_proxy_col=any(h.startswith("proxy") and h not in ("proxy_host","proxy_port") for h in headers)
    has_separate=all(h in headers for h in ("proxy_host","proxy_port","login","password"))
    proxy_idx=None
    if has_proxy_col:
        for i,h in enumerate(headers):
            if h.startswith("proxy") and h not in ("proxy_host","proxy_port"): proxy_idx=i; break
    if not has_proxy_col and not has_separate:
        log_fail("Формат не распознан. Колонки: (n,proxy) или (n,proxy_host,proxy_port,login,password)"); sys.exit(1)
    modems={}; skipped=0
    for row_idx,row in enumerate(rows[1:],start=2):
        if not row or not row[0].strip(): skipped+=1; continue
        rd={headers[i]:row[i].strip() for i in range(min(len(headers),len(row)))}
        try: n=int(rd.get("n","0"))
        except: skipped+=1; continue
        if n<1 or n>200: skipped+=1; continue
        if has_proxy_col and proxy_idx is not None:
            parts=(row[proxy_idx].strip() if proxy_idx<len(row) else "").split(":")
            if len(parts)<4: log_warn(f"Строка {row_idx}: N={n} — неверный формат"); skipped+=1; continue
            proxy_host,proxy_port,login,password=parts[0],parts[1],parts[2],":".join(parts[3:])
        else:
            proxy_host=rd.get("proxy_host",""); proxy_port=rd.get("proxy_port","")
            login=rd.get("login",""); password=rd.get("password","")
        if not all([proxy_host,proxy_port,login,password]): skipped+=1; continue
        en=rd.get("enabled","1").strip().lower() not in ("0","false","no","off","нет","выкл","disabled")
        modems[str(n)]={"proxy_host":proxy_host,"proxy_port":int(proxy_port),"login":login,"password":password,"enabled":en}
    log_ok(f"Модемов: {len(modems)}, пропущено: {skipped}"); return modems

def do_sync(quiet=False):
    if not quiet: header("SYNC: Google Sheets → config.json")
    rows=fetch_sheet_csv(); modems=parse_sheet_rows(rows)
    if not modems: log_fail("Ни одного модема!"); sys.exit(1)
    if CONFIG_FILE.exists() and not quiet:
        old=json.loads(CONFIG_FILE.read_text()); old_n=set(old.get("modems",{}).keys()); new_n=set(modems.keys())
        if new_n-old_n: log_info(f"Новые: {sorted(int(x) for x in new_n-old_n)}")
        if old_n-new_n: log_warn(f"Удалены: {sorted(int(x) for x in old_n-new_n)}")
    config={"modems":modems,"last_sync":datetime.now().isoformat(timespec="seconds")}
    save_config(config)
    if not quiet: log_ok(f"Сохранено: {sum(1 for m in modems.values() if m.get('enabled',True))} активных")
    return config

def cmd_install():
    header("INSTALL")
    run("apt update -qq", capture=True)
    run("apt install -y -qq wget unzip curl iproute2 iptables python3", capture=True)
    log_ok("Пакеты установлены")
    Path("/etc/sysctl.d/99-proxyvethmp.conf").write_text("net.ipv4.ip_forward = 1\n")
    run("sysctl -w net.ipv4.ip_forward=1", capture=True); log_ok("ip_forward=1")
    if not Path("/dev/net/tun").exists(): log_fail("/dev/net/tun не найден!")
    else: log_ok("/dev/net/tun OK")
    if Path(TUN2SOCKS_BIN).exists(): log_ok("tun2socks уже есть")
    else:
        log_step(f"Скачиваем tun2socks v{TUN2SOCKS_VER}...")
        run(f"wget -q -O /tmp/tun2socks.zip '{TUN2SOCKS_URL}'", capture=True)
        run("unzip -o /tmp/tun2socks.zip -d /tmp/", capture=True)
        run(f"mv /tmp/tun2socks-linux-amd64 {TUN2SOCKS_BIN}")
        run(f"chmod +x {TUN2SOCKS_BIN}"); run("rm -f /tmp/tun2socks.zip")
        log_ok(f"tun2socks v{TUN2SOCKS_VER} установлен")
    CONFIG_DIR.mkdir(parents=True, exist_ok=True); LOG_DIR.mkdir(parents=True, exist_ok=True)

def cmd_init():
    header("INIT")
    if not Path("/dev/net/tun").exists(): log_fail("/dev/net/tun не найден!"); sys.exit(1)
    run("sysctl -w net.ipv4.ip_forward=1", capture=True); log_ok("ip_forward=1"); log_ok("INIT готов")

def ns_up(n, modem):
    ph=modem["proxy_host"]; pp=modem["proxy_port"]
    proxy_url=f"socks5://{modem['login']}:{modem['password']}@{ph}:{pp}"
    rt_table=RT_TABLE_BASE+n
    print(f"\n  {B}── NS {n} ──{R}  {ph}:{pp}")
    if is_ns_exists(n): log_warn(f"ns_{n} уже существует — пропуск"); return True
    try:
        # 1. Namespace + DNS
        run(f"ip netns add ns_{n}")
        run(f"ip netns exec ns_{n} ip link set lo up")
        ns_dns=Path(f"/etc/netns/ns_{n}"); ns_dns.mkdir(parents=True, exist_ok=True)
        (ns_dns/"resolv.conf").write_text(f"nameserver {DNS_SERVER}\n")
        # 2. veth пара
        run(f"ip link add veth_ext{n}_host type veth peer name veth_ext{n}_ns")
        run(f"ip link set veth_ext{n}_ns netns ns_{n}")
        run(f"ip addr add 192.168.{n}.100/24 dev veth_ext{n}_host")
        run(f"ip link set veth_ext{n}_host up")
        run(f"ip addr add 192.168.{n}.254/24 dev veth_ext{n}_ns", ns=n)
        run(f"ip link set veth_ext{n}_ns up", ns=n)
        log_step(f"ns_{n}: veth OK")
        # 3. tun2socks
        run(f"nohup {TUN2SOCKS_BIN} -device tun{n} -proxy {proxy_url} -loglevel silent > /dev/null 2>&1 &",
            ns=n, capture=False)
        time.sleep(TUN2SOCKS_WAIT)
        if run_safe(f"ip link show tun{n}", ns=n, quiet=True).returncode!=0:
            raise RuntimeError(f"tun{n} не создан")
        run(f"ip addr add 10.0.{n}.1/30 dev tun{n}", ns=n)
        run(f"ip link set tun{n} up", ns=n)
        log_step(f"ns_{n}: tun2socks OK")
        # 4. Маршруты в ns
        run(f"ip route add default dev tun{n}", ns=n)
        run(f"ip route add 192.168.{n}.1/32 dev tun{n}", ns=n)        # Huawei API
        run(f"ip route add {ph}/32 via 192.168.{n}.100", ns=n)        # SOCKS5 bypass tun!
        for dns in DNS_SERVERS:
            run_safe(f"ip route add {dns}/32 via 192.168.{n}.100", ns=n)  # DNS bypass tun!
        # 5. iptables в ns
        # КРИТИЧНО: UDP DROP — без него mproxy флудит через tun2socks → убивает 3proxy
        run(f"iptables -A OUTPUT  -o tun{n} -p udp -j DROP", ns=n)
        run(f"iptables -A FORWARD -o tun{n} -p udp -j DROP", ns=n)
        run("sysctl -w net.ipv4.ip_forward=1", ns=n)
        run(f"iptables -t nat -A POSTROUTING -o tun{n} -j MASQUERADE", ns=n)
        run(f"iptables -A FORWARD -i veth_ext{n}_ns -o tun{n} -j ACCEPT", ns=n)
        run(f"iptables -A FORWARD -i tun{n} -o veth_ext{n}_ns -j ACCEPT", ns=n)
        # 6. Хост: NAT + source routing
        r=run_safe(f"iptables -t nat -C POSTROUTING -s 192.168.{n}.0/24 -o {ETH_WAN} -j MASQUERADE", quiet=True)
        if r.returncode!=0: run(f"iptables -t nat -A POSTROUTING -s 192.168.{n}.0/24 -o {ETH_WAN} -j MASQUERADE")
        _ensure_rt_table(rt_table, f"modem_{n}")
        run_safe(f"ip rule del from 192.168.{n}.100 table {rt_table}", quiet=True)
        run(f"ip rule add from 192.168.{n}.100 table {rt_table}")
        run(f"ip route add default via 192.168.{n}.254 dev veth_ext{n}_host table {rt_table}")
        log_ok(f"ns_{n} ГОТОВ | 192.168.{n}.100 → {ph}:{pp} | Huawei: 192.168.{n}.1")
        return True
    except Exception as e:
        log_fail(f"ns_{n}: {e}"); ns_down(n, quiet=True); return False

def ns_down(n, quiet=False):
    if not quiet: print(f"  {D}↓ ns_{n}{R}", end="", flush=True)
    rt_table=RT_TABLE_BASE+n
    run_safe(f"pkill -f 'tun2socks.*tun{n}[^0-9]'", quiet=True)
    run_safe(f"pkill -f 'tun2socks.*tun{n}$'", quiet=True)
    time.sleep(0.3)
    run_safe(f"ip netns del ns_{n}", quiet=True)
    run_safe(f"ip link del veth_ext{n}_host", quiet=True)
    run_safe(f"ip rule del from 192.168.{n}.100 table {rt_table}", quiet=True)
    run_safe(f"ip route flush table {rt_table}", quiet=True)
    run_safe(f"iptables -t nat -D POSTROUTING -s 192.168.{n}.0/24 -o {ETH_WAN} -j MASQUERADE", quiet=True)
    dns_dir=Path(f"/etc/netns/ns_{n}")
    if dns_dir.exists():
        for f in dns_dir.iterdir(): f.unlink()
        dns_dir.rmdir()
    if not quiet: print(f" {G}✓{R}")

def cmd_autosync():
    old=json.loads(CONFIG_FILE.read_text()) if CONFIG_FILE.exists() else {}
    om=old.get("modems",{}); new=do_sync(quiet=True); nm=new.get("modems",{})
    to_add=set(nm)-set(om); to_remove=set(om)-set(nm); to_restart=set()
    for k in set(om)&set(nm):
        o,n2=om[k],nm[k]
        if any(o.get(f)!=n2.get(f) for f in ("proxy_host","proxy_port","login","password")): to_restart.add(k)
        if not n2.get("enabled",True) and o.get("enabled",True): to_remove.add(k); to_restart.discard(k)
        if n2.get("enabled",True) and not o.get("enabled",True): to_add.add(k); to_restart.discard(k)
    if not (to_add or to_remove or to_restart): return
    wlog(f"AUTOSYNC: +{len(to_add)} -{len(to_remove)} ~{len(to_restart)}")
    for k in to_remove:
        n=int(k)
        if is_ns_exists(n): wlog(f"  REMOVE ns_{n}"); ns_down(n, quiet=True)
    for k in to_restart:
        n=int(k); m=nm[k]
        if m.get("enabled",True): wlog(f"  RESTART ns_{n}"); ns_down(n,quiet=True); time.sleep(0.5); ns_up(n,m)
    for k in to_add:
        n=int(k); m=nm[k]
        if m.get("enabled",True) and not is_ns_exists(n): wlog(f"  ADD ns_{n}"); ns_up(n,m)
    wlog("AUTOSYNC done")

def watchdog_check_ns(n, modem, check_wan=False):
    if not is_ns_exists(n): return "ns_missing"
    if not is_process_running(f"tun2socks.*tun{n}"): return "tun_dead"
    if check_wan:
        r=run_safe(f"curl -s --max-time {CURL_TIMEOUT} --interface 192.168.{n}.100 2ip.ru", capture=True, quiet=True)
        if r.returncode!=0 or not r.stdout.strip(): return "wan_dead"
    return "ok"

def watchdog_pass(config, pass_number):
    modems=get_enabled_modems(config); check_wan=(pass_number%WATCHDOG_WAN_EVERY==0)
    ok_count=restarted=failed=0
    rc_file=CONFIG_DIR/"restart_counts.json"; restart_counts={}
    if rc_file.exists():
        try: restart_counts=json.loads(rc_file.read_text())
        except: pass
    for n,modem in modems:
        status=watchdog_check_ns(n,modem,check_wan=check_wan)
        if status=="ok": ok_count+=1; restart_counts.pop(str(n),None); continue
        n_str=str(n); rc=restart_counts.get(n_str,0)
        if rc>=WATCHDOG_MAX_RESTART: wlog(f"  ✗ ns_{n}: {status} — MAX RESTARTS"); failed+=1; continue
        wlog(f"  ⚠ ns_{n}: {status} — перезапуск ({rc+1}/{WATCHDOG_MAX_RESTART})")
        ns_down(n,quiet=True); time.sleep(1); success=ns_up(n,modem)
        if success: restarted+=1; restart_counts.pop(n_str,None)
        else: failed+=1; restart_counts[n_str]=rc+1
    try: rc_file.write_text(json.dumps(restart_counts))
    except: pass
    return ok_count, restarted, failed

def cmd_watchdog():
    header("WATCHDOG"); config=load_config()
    ok,re,fa=watchdog_pass(config,1); log_info(f"OK:{ok} Restart:{re} Fail:{fa}")

def cmd_watchdog_loop():
    wlog("ProxyVethMP WATCHDOG STARTED"); stop=[False]
    signal.signal(signal.SIGTERM, lambda s,f: stop.__setitem__(0,True))
    signal.signal(signal.SIGINT,  lambda s,f: stop.__setitem__(0,True))
    config=load_config(); p=0
    while not stop[0]:
        p+=1
        try:
            ok,re,fa=watchdog_pass(config,p)
            if re>0 or fa>0: wlog(f"Pass #{p}: OK={ok} RESTART={re} FAIL={fa}")
            elif p%10==0: wlog(f"Pass #{p}: все {ok} OK")
        except Exception as e: wlog(f"Pass #{p} ERROR: {e}")
        for _ in range(WATCHDOG_INTERVAL):
            if stop[0]: break
            time.sleep(1)
    wlog("ProxyVethMP WATCHDOG STOPPED")

def cmd_status(check_wan=False):
    header("STATUS"); config=load_config(); modems=config.get("modems",{}); active_ns=set(get_active_ns_list())
    print(f"\n  {'N':>3} │ {'Proxy':^28} │ {'NS':^6} │ {'tun':^5}{'  WAN IP' if check_wan else ''}")
    print(f"  {'─'*3}─┼─{'─'*28}─┼─{'─'*6}─┼─{'─'*5}")
    up=down=disabled=0
    for n_str in sorted(modems,key=lambda x:int(x)):
        n=int(n_str); m=modems[n_str]; en=m.get("enabled",True); ps=f"{m['proxy_host']}:{m['proxy_port']}"
        if not en: disabled+=1; print(f"  {n:>3} │ {ps:<28} │ {D}{'—':^6}{R} │ {D}{'—':^5}{R}"); continue
        if n in active_ns:
            up+=1; ns_m=f"{G}{'UP':^6}{R}"; t=is_process_running(f"tun2socks.*tun{n}"); tm=f"{G}{'✓':^5}{R}" if t else f"{RD}{'✗':^5}{R}"
            w=""
            if check_wan:
                wr=run_safe(f"curl -s --max-time {CURL_TIMEOUT} --interface 192.168.{n}.100 2ip.ru", capture=True, quiet=True)
                w=f"  {wr.stdout.strip() if wr.returncode==0 else '—'}"
        else: down+=1; ns_m=f"{RD}{'DOWN':^6}{R}"; tm=f"{D}{'—':^5}{R}"; w=""
        print(f"  {n:>3} │ {ps:<28} │ {ns_m} │ {tm}{w}")
    print(); log_info(f"UP:{up} DOWN:{down} Disabled:{disabled} Total:{len(modems)}")
    if config.get("last_sync"): log_info(f"Sync: {config['last_sync']}")

def cmd_check(target):
    n=int(target); header(f"CHECK ns_{n}")
    if not is_ns_exists(n): log_fail(f"ns_{n} не существует"); return
    r=run_safe(f"curl -s --max-time {CURL_TIMEOUT} --interface 192.168.{n}.100 2ip.ru", capture=True, quiet=True)
    (log_ok if r.returncode==0 and r.stdout.strip() else log_fail)(f"WAN IP (хост):  {r.stdout.strip() or 'недоступен'}")
    r=run_safe(f"curl -s --max-time {CURL_TIMEOUT} 2ip.ru", ns=n, capture=True, quiet=True)
    (log_ok if r.returncode==0 and r.stdout.strip() else log_fail)(f"WAN IP (ns):    {r.stdout.strip() or 'недоступен'}")
    r=run_safe(f"curl -s --max-time 5 --interface 192.168.{n}.100 http://192.168.{n}.1/api/webserver/SesTokInfo", capture=True, quiet=True)
    (log_ok if "SesInfo" in r.stdout else log_fail)(f"Huawei API .1:  {'OK' if 'SesInfo' in r.stdout else 'недоступен'}")
    t=is_process_running(f"tun2socks.*tun{n}")
    (log_ok if t else log_fail)(f"tun2socks:      {'OK' if t else 'DEAD'}")
    log_step("Маршруты в ns:")
    for line in run_safe("ip route",ns=n,capture=True).stdout.strip().split("\n"): print(f"    {D}{line}{R}")

def cmd_up(target):
    config=load_config(); cmd_init()
    if target=="all":
        header("UP ALL"); modems=get_enabled_modems(config); log_info(f"Модемов: {len(modems)}")
        ok=fail=0; t0=time.time()
        for n,m in modems:
            if ns_up(n,m): ok+=1
            else: fail+=1
        header(f"РЕЗУЛЬТАТ: {ok} ✓ поднято, {fail} ✗ ошибок ({time.time()-t0:.0f}с)")
    else: ns_up(int(target), get_modem(config, int(target)))

def cmd_down(target):
    if target=="all":
        header("DOWN ALL"); ns_list=get_active_ns_list()
        if not ns_list: log_info("Нет активных NS"); return
        for n in ns_list: ns_down(n)
        log_ok(f"Удалено: {len(ns_list)}")
    else: ns_down(int(target))

def cmd_restart(target):
    config=load_config()
    if target=="all": header("RESTART ALL"); cmd_down("all"); time.sleep(1); cmd_up("all")
    else:
        n=int(target); ns_down(n); time.sleep(1); ns_up(n, get_modem(config,n))

def cmd_cleanup():
    header("CLEANUP"); run_safe("pkill -f tun2socks", quiet=True); time.sleep(1)
    for n in get_active_ns_list(): ns_down(n, quiet=True)
    run_safe("iptables -t nat -F", quiet=True)
    import glob
    for path in glob.glob("/etc/netns/ns_*"):
        pp=Path(path)
        if pp.is_dir():
            for f in pp.iterdir(): f.unlink()
            pp.rmdir()
    (CONFIG_DIR/"restart_counts.json").unlink(missing_ok=True); log_ok("Очистка завершена")

def cmd_show_config():
    config=load_config(); modems=config.get("modems",{}); en=sum(1 for m in modems.values() if m.get("enabled",True))
    print(f"\n  {CONFIG_FILE}  |  Sync: {config.get('last_sync','—')}")
    print(f"  Модемов: {len(modems)} (активных: {en})\n")
    for k in sorted(modems,key=lambda x:int(x)):
        m=modems[k]; e=f"{G}✓{R}" if m.get("enabled",True) else f"{RD}✗{R}"
        print(f"  {e} {int(k):>3}  {m['proxy_host']}:{m['proxy_port']}  {m['login']}")

def setup_systemd():
    header("SYSTEMD"); py="/usr/bin/python3"; script=str(SCRIPT_PATH); envf=str(ENV_FILE)
    Path("/etc/systemd/system/proxyvethmp.service").write_text(f"""[Unit]
Description=ProxyVethMP
After=network-online.target mproxy.service nodejs-server.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-{envf}
ExecStart={py} {script} init
ExecStart={py} {script} up all
ExecStop={py} {script} down all
TimeoutStartSec=300
[Install]
WantedBy=multi-user.target
""")
    Path("/etc/systemd/system/proxyvethmp-watchdog.service").write_text(f"""[Unit]
Description=ProxyVethMP Watchdog
After=proxyvethmp.service
Requires=proxyvethmp.service
[Service]
Type=simple
EnvironmentFile=-{envf}
ExecStart={py} {script} watchdog-loop
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
""")
    Path("/etc/systemd/system/proxyvethmp-autosync.service").write_text(f"""[Unit]
Description=ProxyVethMP Autosync
[Service]
Type=oneshot
EnvironmentFile=-{envf}
ExecStart={py} {script} autosync
""")
    Path("/etc/systemd/system/proxyvethmp-autosync.timer").write_text("""[Unit]
Description=ProxyVethMP Autosync Timer
[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
""")
    run("systemctl daemon-reload", capture=True)
    run("systemctl enable proxyvethmp.service", capture=True)
    run("systemctl enable proxyvethmp-watchdog.service", capture=True)
    run("systemctl enable proxyvethmp-autosync.timer", capture=True)
    log_ok("Все сервисы enabled")

def cmd_setup():
    header("ProxyVethMP — УСТАНОВКА")
    if not SHEET_CSV_URL and not SHEET_ID:
        print(f"\n  {Y}SHEET_CSV_URL не задан.{R}")
        url=input("  Введи CSV ссылку на Google Sheet: ").strip()
        if not url: log_fail("URL не введён"); sys.exit(1)
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        open(ENV_FILE,"w").write(f"SHEET_CSV_URL={url}\n")
        log_ok(f"Сохранено в {ENV_FILE}"); os.environ["SHEET_CSV_URL"]=url
        global SHEET_CSV_URL; SHEET_CSV_URL=url
    cmd_install(); config=do_sync(); cmd_init(); cmd_up("all"); setup_systemd()
    link=Path("/usr/local/bin/proxyveth"); link.unlink(missing_ok=True); link.symlink_to(SCRIPT_PATH)
    log_ok("Symlink: proxyveth → proxyveth_mp.py")
    active=len(get_active_ns_list()); enabled=len(get_enabled_modems(config))
    wan_ip=run_safe("curl -s --max-time 5 2ip.ru",capture=True).stdout.strip()
    loc_ip=run_safe("hostname -I",capture=True).stdout.split()[0]
    print(f"""
{G}{'═'*60}
  ProxyVethMP УСТАНОВЛЕН: {active}/{enabled} NS активно
{'═'*60}{R}
  proxyveth status / check N / restart N / down all

  {Y}⚠ Настрой в ЛК mobileproxy.space → Сервера → ✏{R}
    Статический IP : {wan_ip}
    LocalIP        : {loc_ip}
    Root login     : root   |   OS: Unix
""")

USAGE=f"""{B}ProxyVethMP v1.0{R}
Команды: sync / autosync / init / up [N|all] / down [N|all]
         restart [N|all] / status [--wan] / check N
         watchdog / watchdog-loop / cleanup / show-config"""

def main():
    _load_env_file()
    if len(sys.argv)<2: cmd_setup(); return
    cmd=sys.argv[1].lower().replace("-","_"); arg=sys.argv[2] if len(sys.argv)>2 else None; flags=sys.argv[2:]
    dispatch={"setup":cmd_setup,"install":cmd_install,"init":cmd_init,"sync":do_sync,
              "autosync":cmd_autosync,"watchdog":cmd_watchdog,"watchdog_loop":cmd_watchdog_loop,
              "cleanup":cmd_cleanup,"show_config":cmd_show_config}
    try:
        if cmd in dispatch: dispatch[cmd]()
        elif cmd=="up":
            if not arg: log_fail("proxyveth up [N|all]"); sys.exit(1)
            cmd_up(arg)
        elif cmd=="down":
            if not arg: log_fail("proxyveth down [N|all]"); sys.exit(1)
            cmd_down(arg)
        elif cmd=="restart":
            if not arg: log_fail("proxyveth restart [N|all]"); sys.exit(1)
            cmd_restart(arg)
        elif cmd=="status": cmd_status(check_wan="--wan" in flags)
        elif cmd=="check":
            if not arg: log_fail("proxyveth check N"); sys.exit(1)
            cmd_check(arg)
        else: log_fail(f"Неизвестная команда: {cmd}"); print(USAGE); sys.exit(1)
    except KeyboardInterrupt: print(f"\n{Y}Прервано{R}"); sys.exit(130)
    except SystemExit: raise
    except Exception as e: log_fail(f"Ошибка: {e}"); sys.exit(1)

if __name__=="__main__": main()
PYEOF

chmod +x /usr/local/bin/proxyveth_mp.py
ln -sf /usr/local/bin/proxyveth_mp.py /usr/local/bin/proxyveth
echo ""
echo "✓ /usr/local/bin/proxyveth_mp.py"
echo "✓ symlink: proxyveth"
echo ""
echo "Запуск: proxyveth"
