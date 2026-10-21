import curses
import _locale            # C-level locale module (the 'locale' package drags in 're')
import time
import os
import select
from _collections import deque   # C implementation, skips importing the collections package

REFRESH = 2.0      # seconds between updates
PROC_EVERY = 4     # seconds between scans of running programs
HIST = 300         # samples kept for graphs
BLOCKS = " ▁▂▃▄▅▆▇█"

# ───────────── data functions ─────────────
def read_stat():
    """Returns ((total, idle) for whole CPU, [(total, idle) per core])."""
    whole, cores = (0, 0), []
    with open("/proc/stat") as f:
        for line in f:
            if not line.startswith("cpu"):
                break
            v = [int(x) for x in line.split()[1:]]
            pair = (sum(v[:8]), v[3] + v[4])          # total, idle+iowait
            if line[3] == " ":
                whole = pair
            else:
                cores.append(pair)
    return whole, cores

def cpct(cur, prev):
    dt, di = cur[0] - prev[0], cur[1] - prev[1]
    if dt <= 0:
        return 0.0
    return max(0.0, min(100.0, 100 * (1 - di / dt)))

def read_mem():
    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, _, rest = line.partition(":")
            info[key] = int(rest.split()[0]) * 1024   # kB -> bytes
    total, avail = info["MemTotal"], info["MemAvailable"]
    st, sf = info.get("SwapTotal", 0), info.get("SwapFree", 0)
    return {"total": total, "avail": avail, "used": total - avail,
            "swap_total": st, "swap_used": st - sf}

def read_disk(path="/"):
    s = os.statvfs(path)
    total = s.f_blocks * s.f_frsize
    free = s.f_bavail * s.f_frsize
    used = (s.f_blocks - s.f_bfree) * s.f_frsize
    pct = 100 * used / (used + free)
    return total, used, free, pct

def read_sys():
    with open("/proc/uptime") as f:
        up = float(f.read().split()[0])
    with open("/proc/loadavg") as f:
        l1, l5, l15 = f.read().split()[:3]
    return up, l1, l5, l15

def ls(path):
    try:
        return sorted(os.listdir(path))
    except OSError:
        return []

def read_cpu_temp():
    for h in ls("/sys/class/hwmon"):
        if not h.startswith("hwmon"):
            continue
        hw = "/sys/class/hwmon/" + h
        try:
            with open(hw + "/name") as f:
                if f.read().strip() != "coretemp":
                    continue
            best = None
            for fn in ls(hw):
                if not (fn.startswith("temp") and fn.endswith("_input")):
                    continue
                tf = hw + "/" + fn
                with open(tf) as f:
                    c = int(f.read()) / 1000          # millidegrees -> °C
                with open(tf.replace("_input", "_label")) as f:
                    label = f.read().strip()
                if label.startswith("Package"):
                    return c                          # whole-CPU temp
                best = c if best is None else max(best, c)
            return best
        except (OSError, ValueError):
            continue
    return None

freq_files = [f"/sys/devices/system/cpu/{n}/cpufreq/scaling_cur_freq"
              for n in ls("/sys/devices/system/cpu")
              if n.startswith("cpu") and n[3:].isdigit()]

def read_freq():
    vals = []
    for p in freq_files:
        try:
            with open(p) as f:
                vals.append(int(f.read()) / 1000)     # kHz -> MHz
        except (OSError, ValueError):
            pass
    return sum(vals) / len(vals) if vals else None

def cpu_model():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    name = line.split(":", 1)[1].strip()
                    break
            else:
                return "CPU"
    except OSError:
        return "CPU"
    for junk in ("(R)", "(TM)", "CPU"):
        name = name.replace(junk, "")
    return " ".join(name.split("@")[0].split())

def read_battery():
    base = "/sys/class/power_supply/BAT0/"
    try:
        with open(base + "capacity") as f:
            cap = int(f.read())
        with open(base + "status") as f:
            status = f.read().strip()        # Charging / Discharging / Full
    except (OSError, ValueError):
        return None, None
    return cap, status

def read_procs():
    """Private RAM per program name, biggest first: [(name, bytes, process count)].
    Private = resident pages minus shared pages (from /proc/PID/statm), so shared
    libraries are not counted again for every process."""
    page = os.sysconf("SC_PAGE_SIZE")
    tot = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/statm") as f:
                parts = f.read().split()
            priv = (int(parts[1]) - int(parts[2])) * page
            if priv <= 0:                              # kernel threads etc.
                continue
            with open(f"/proc/{pid}/comm") as f:
                name = f.read().strip()
        except (OSError, ValueError, IndexError):
            continue
        b, n = tot.get(name, (0, 0))
        tot[name] = (b + priv, n + 1)
    return sorted(((k, b, n) for k, (b, n) in tot.items()), key=lambda t: -t[1])

gpu_cache = {"t": 0, "temp": None, "util": None}

def run_nvidia():
    """Runs nvidia-smi without importing subprocess (saves ~1 MiB). Returns text or None."""
    r, w = os.pipe()
    try:
        pid = os.posix_spawnp(
            "nvidia-smi",
            ["nvidia-smi", "--query-gpu=temperature.gpu,utilization.gpu",
             "--format=csv,noheader,nounits"],
            os.environ,
            file_actions=[(os.POSIX_SPAWN_DUP2, w, 1),
                          (os.POSIX_SPAWN_CLOSE, r), (os.POSIX_SPAWN_CLOSE, w),
                          (os.POSIX_SPAWN_OPEN, 2, os.devnull, os.O_WRONLY, 0)])
    except OSError:
        os.close(r)
        os.close(w)
        return None
    os.close(w)
    out, deadline = b"", time.time() + 2
    try:
        while time.time() < deadline:
            if select.select([r], [], [], 0.2)[0]:
                chunk = os.read(r, 4096)
                if not chunk:
                    break
                out += chunk
        else:
            os.kill(pid, 9)                          # timed out
    finally:
        os.close(r)
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    return out.decode(errors="ignore")

def read_nvidia():
    if time.time() - gpu_cache["t"] < 3:              # only ask every 3s
        return gpu_cache["temp"], gpu_cache["util"]
    gpu_cache["t"] = time.time()
    try:
        t, u = run_nvidia().split(",")
        gpu_cache["temp"], gpu_cache["util"] = float(t), float(u)
    except (AttributeError, ValueError):
        gpu_cache["temp"] = gpu_cache["util"] = None
    return gpu_cache["temp"], gpu_cache["util"]

def find_intel_card():
    for n in ls("/sys/class/drm"):
        if not (len(n) == 5 and n.startswith("card") and n[4].isdigit()):
            continue
        try:
            drv = os.path.basename(os.readlink(f"/sys/class/drm/{n}/device/driver"))
        except OSError:
            continue
        if drv == "i915":
            return "/sys/class/drm/" + n
    return None

intel_card = find_intel_card()
intel_prev = {"rc6": None, "t": None}

def read_intel():
    if intel_card is None:
        return None, None
    base = intel_card + "/gt/gt0/"
    try:
        with open(base + "rc6_residency_ms") as f:
            rc6 = int(f.read())
        with open(base + "rps_cur_freq_mhz") as f:
            freq = int(f.read())
    except (OSError, ValueError):
        return None, None
    now = time.time()
    usage = None
    if intel_prev["rc6"] is not None:                  # needs two readings
        wall = (now - intel_prev["t"]) * 1000
        if wall > 0:
            idle = (rc6 - intel_prev["rc6"]) / wall * 100
            usage = max(0, min(100, 100 - idle))
    intel_prev["rc6"], intel_prev["t"] = rc6, now
    return usage, freq

# ───────────── formatting helpers ─────────────
def gib(n):
    return f"{n / 1024**3:.1f} GiB"

def fmt_uptime(s):
    d, s = divmod(int(s), 86400)
    h, s = divmod(s, 3600)
    m = s // 60
    return (f"{d}d " if d else "") + f"{h}h {m:02d}m"

def fmt_pct(p):
    return f"{p:.0f}%" if p is not None else "n/a"

def fmt_temp(t):
    return f"{t:.0f}°C" if t is not None else "n/a"

# ───────────── drawing helpers ─────────────
def put(scr, y, x, text, attr=0):
    h, w = scr.getmaxyx()
    if 0 <= y < h and 0 <= x < w:
        try:
            scr.addstr(y, x, text[:w - x], attr)
        except curses.error:
            pass

ACCENT = 1          # color pair of the section being drawn (its "ok" color)

def set_accent(pair):
    global ACCENT
    ACCENT = pair

def lvl(p, warn, crit, invert=False):
    """Color pair for a value: the section color when fine, gold when warm, pink when hot.
    invert=True means low is bad (battery)."""
    level = 100 - p if invert else p
    return curses.color_pair(3 if level >= crit else 2 if level >= warn else ACCENT)

def meter(scr, y, x, w, pct, warn=60, crit=85, invert=False):
    if w <= 0:
        return
    if pct is None:
        put(scr, y, x, "■" * w, curses.A_DIM)
        return
    n = int(round(max(0, min(100, pct)) / 100 * w))
    put(scr, y, x, "■" * n, lvl(pct, warn, crit, invert))
    put(scr, y, x + n, "■" * (w - n), curses.A_DIM)

def tag(scr, y, x, text, attr):
    """Draws ┤ text ├ on a border line. Returns its width."""
    s = f" {text} "
    put(scr, y, x, "┤", attr)
    put(scr, y, x + 1, s, attr | curses.A_BOLD)
    put(scr, y, x + 1 + len(s), "├", attr)
    return len(s) + 2

def box(scr, y, x, h, w, title, pair):
    a = curses.color_pair(pair)
    put(scr, y, x, "╭" + "─" * (w - 2) + "╮", a)
    for r in range(1, h - 1):
        put(scr, y + r, x, "│", a)
        put(scr, y + r, x + w - 1, "│", a)
    put(scr, y + h - 1, x, "╰" + "─" * (w - 2) + "╯", a)
    tag(scr, y, x + 2, title, a)

def graph(scr, y, x, h, w, data):
    """Area graph, newest sample on the right. Values are 0-100."""
    vals = list(data)[-w:]
    off = w - len(vals)
    for i, v in enumerate(vals):
        total = max(1, int(v / 100 * h * 8 + 0.5))
        attr = lvl(v, 60, 85)
        for r in range(h):
            lev = total - r * 8
            if lev <= 0:
                break
            put(scr, y + h - 1 - r, x + off + i, BLOCKS[min(lev, 8)], attr)

def sparkline(scr, y, x, w, data):
    vals = list(data)[-w:]
    off = w - len(vals)
    for i, v in enumerate(vals):
        idx = max(1, int(round(v / 100 * 8)))
        put(scr, y, x + off + i, BLOCKS[idx], lvl(v, 60, 85))

ART = [
    "..............##..................",
    "..............##..................",
    "..............##..................",
    ".............####.................",
    ".............####..............##.",
    "............#####..............##.",
    "............#####.............###.",
    "...........######............####.",
    "...........######...........#####.",
    "...........######..........######.",
    "...........######.........######..",
    "..........#######.........######..",
    "..........#######........#######..",
    "..........#######.......########..",
    ".........########.......########..",
    ".........#########.....#########..",
    "........#############.##########..",
    ".......#########################..",
    "......#########################...",
    "......#########################...",
    "......####...##################...",
    ".....###.....##################...",
    ".....###....#.################....",
    ".....##.....#.#######....#####....",
    ".....###...##.######..#...#####...",
    "####.###...##.######.##....####...",
    ".....####.....#####..#.....####...",
    "......#####.#######..#.....####...",
    ".###...#############.#....#####...",
    "##......#############.....####....",
    ".........####################.....",
    "..........###################.....",
    ".............##############.......",
    "...............###########....##..",
    "................................##",
    "..................................",
    "............................#.....",
    ".............................#....",
]
ART_W, ART_H = len(ART[0]), len(ART)
art_cache = {}

def art_cells(w, h):
    """Braille rows of the ART bitmap, scaled to fit inside w x h cells."""
    if (w, h) in art_cache:
        return art_cache[(w, h)]
    scale = min(2 * w / ART_W, 4 * h / ART_H, 2.0)
    tw, th = int(ART_W * scale), int(ART_H * scale)
    def dot(tx, ty):
        sx, sy = int(tx / scale), int(ty / scale)
        return sx < ART_W and sy < ART_H and ART[sy][sx] == "#"
    bits = ((0, 0, 0), (0, 1, 1), (0, 2, 2), (1, 0, 3), (1, 1, 4), (1, 2, 5), (0, 3, 6), (1, 3, 7))
    lines = []
    for cy in range(0, th, 4):
        line = ""
        for cx in range(0, tw, 2):
            code = 0
            for dx, dy, b in bits:
                if cx + dx < tw and cy + dy < th and dot(cx + dx, cy + dy):
                    code |= 1 << b
            line += chr(0x2800 + code)
        lines.append(line)
    art_cache[(w, h)] = lines
    return lines

def draw_art(scr, y, x, h, w, attr):
    """Dotted cat drawn dim behind the graph, centered in the area."""
    lines = art_cells(w, h)
    if not lines:
        return
    oy = y + (h - len(lines)) // 2
    ox = x + (w - len(lines[0])) // 2
    for r, line in enumerate(lines):
        put(scr, oy + r, ox, line, attr)

def row(scr, y, ix, iw, label, pct, warn, crit, text, invert=False):
    """label + meter + right-aligned value, inside a box starting at ix."""
    put(scr, y, ix + 1, f"{label:<8}")
    mx, px = ix + 9, ix + iw - 6
    meter(scr, y, mx, px - mx - 1, pct, warn, crit, invert)
    attr = curses.A_DIM if pct is None else lvl(pct, warn, crit, invert)
    put(scr, y, px, text.rjust(6), attr | curses.A_BOLD)

# ───────────── panels ─────────────
def draw_cpu(scr, y, x, h, w, S):
    set_accent(4)
    box(scr, y, x, h, w, "cpu", 4)
    ix, iy, iw, ih = x + 1, y + 1, w - 2, h - 2
    gw = iw * 2 // 5
    if S["art"]:
        draw_art(scr, iy, ix, ih - 1, gw, lvl(S["usage"], 60, 85) | curses.A_DIM)
    graph(scr, iy, ix, ih - 1, gw, S["cpu_hist"])
    put(scr, iy + ih - 1, ix + 1, f"up {fmt_uptime(S['up'])}", curses.A_DIM)

    bx, bw = ix + gw + 1, iw - gw - 1                 # inner info box
    a = curses.color_pair(4)
    box(scr, iy, bx, ih, bw, S["model"][:max(4, bw - 18)], 4)
    if S["freq"]:
        t = f"{S['freq']:.0f} MHz"
        tag(scr, iy, bx + bw - len(t) - 5, t, a)

    cx, cwid, cy, ch = bx + 2, bw - 4, iy + 1, ih - 2
    # total row
    mw = cwid - 4 - 5 - 6
    put(scr, cy, cx, "CPU", curses.A_BOLD)
    meter(scr, cy, cx + 4, mw, S["usage"], 60, 85)
    put(scr, cy, cx + 4 + mw, f" {S['usage']:3.0f}%", lvl(S["usage"], 60, 85) | curses.A_BOLD)
    ct = S["ct"]
    put(scr, cy, cx + 9 + mw, f" {ct:3.0f}°C" if ct is not None else "   n/a",
        (lvl(ct, 70, 85) if ct is not None else curses.A_DIM) | curses.A_BOLD)
    # per-core grid
    rows_avail = ch - 2
    cols = max(1, min(4, cwid // 16))
    cw = cwid // cols
    for i, u in enumerate(S["cores"]):
        r, c = divmod(i, cols)
        if r >= rows_avail:
            break
        px = cx + c * cw
        bwid = cw - 3 - 5 - 1
        put(scr, cy + 1 + r, px, f"C{i:<2}", curses.A_DIM)
        meter(scr, cy + 1 + r, px + 3, bwid, u, 60, 85)
        put(scr, cy + 1 + r, px + 3 + bwid, f" {u:3.0f}%", lvl(u, 60, 85))
    put(scr, cy + ch - 1, cx, f"LAV: {S['l1']} {S['l5']} {S['l15']}", curses.A_DIM)

def fmt_size(b):
    return gib(b) if b >= 1024**3 else f"{b / 1024**2:.0f} MiB"

def mini(scr, y, x, w, label, pct, warn, crit, text, pair, invert=False):
    """Compact one-line meter (label, bar, value) in a column w cells wide, in its own color."""
    set_accent(pair)
    put(scr, y, x, f"{label:<6}")
    mx, px = x + 7, x + w - 5
    meter(scr, y, mx, px - mx - 1, pct, warn, crit, invert)
    attr = curses.A_DIM if pct is None else lvl(pct, warn, crit, invert)
    put(scr, y, px, text.rjust(5), attr | curses.A_BOLD)

def draw_mem(scr, y, x, h, w, S):
    """CPU, RAM and both GPUs side by side, compact, then the top apps by RAM."""
    box(scr, y, x, h, w, "cpu / ram / gpu", 6)
    ix, iy, iw, ih = x + 1, y + 1, w - 2, h - 2
    m = S["mem"]
    dt_, du, df, dp = S["disk"]
    ram = 100 * m["used"] / m["total"]
    left = [("CPU", S["usage"], 60, 85, fmt_pct(S["usage"]), 4),
            ("RAM", ram, 70, 90, fmt_pct(ram), 6)]
    if m["swap_total"]:
        sw = 100 * m["swap_used"] / m["swap_total"]
        left.append(("Swap", sw, 30, 70, fmt_pct(sw), 6))
    left.append(("Disk", dp, 75, 90, fmt_pct(dp), 6))
    gpus = [("GPU 1", S["iu"], 60, 85, fmt_pct(S["iu"]), 5),
            ("GPU 2", S["gu"], 60, 85, fmt_pct(S["gu"]), 5)]
    ifreq = f"{S['ifreq']} MHz" if S["ifreq"] is not None else "n/a"

    if iw >= 52:                                   # two columns: CPU/RAM left, GPUs right
        cw = (iw - 5) // 2
        rx = ix + 1 + cw + 3                       # 3 cells between the columns
        for i, it in enumerate(left):
            if i < ih:
                mini(scr, iy + i, ix + 1, cw, *it)
        for i, it in enumerate(gpus):
            if 2 * i < ih:
                mini(scr, iy + 2 * i, rx, cw, *it)
        if ih > 1:
            put(scr, iy + 1, rx + 7, f"Intel iGPU  {ifreq}", curses.A_DIM)
        if ih > 3:
            set_accent(5)
            put(scr, iy + 3, rx + 7, f"NVIDIA  {fmt_temp(S['gt'])}",
                (lvl(S["gt"], 70, 85) if S["gt"] is not None else curses.A_DIM))
        cy = iy + max(len(left), 4)
    else:                                          # narrow window: one column
        for i, it in enumerate(left + gpus):
            if i < ih:
                mini(scr, iy + i, ix + 1, iw - 2, *it)
        cy = iy + len(left) + len(gpus)

    lines = [f"RAM {gib(m['used'])} / {gib(m['total'])}  avail {gib(m['avail'])}"]
    swap = f"Swap {gib(m['swap_used'])} / {gib(m['swap_total'])}   " if m["swap_total"] else ""
    lines.append(f"{swap}Disk {gib(du)} / {gib(dt_)}  free {gib(df)}")
    for line in lines:
        if cy < iy + ih:
            put(scr, cy, ix + 1, line[:iw - 2], curses.A_DIM)
            cy += 1

    # which programs hold the RAM
    if S["procs"] and cy + 1 < iy + ih:
        set_accent(9)                              # top apps get their own color
        put(scr, cy, ix + 1, "top apps by RAM", curses.color_pair(ACCENT) | curses.A_BOLD)
        nw = 16
        mx = ix + 1 + nw + 1
        bw = max(4, min(20, ix + iw - 11 - mx))
        vx = mx + bw + 1
        for i, (name, b, n) in enumerate(S["procs"][:iy + ih - cy - 1]):
            ry = cy + 1 + i
            label = name[:nw] if n == 1 else f"{name[:nw - 4]} x{n}"
            pct = 100 * b / m["total"]
            put(scr, ry, ix + 1, label)
            meter(scr, ry, mx, bw, pct, 15, 30)
            put(scr, ry, vx, fmt_size(b).rjust(9), lvl(pct, 15, 30) | curses.A_BOLD)

def draw_gpu(scr, y, x, h, w, S):
    set_accent(5)
    box(scr, y, x, h, w, "gpu / power", 5)
    ix, iy, iw, ih = x + 1, y + 1, w - 2, h - 2
    mw = iw - 16
    sw = max(0, mw - 10)
    ifreq = f"{S['ifreq']} MHz" if S["ifreq"] is not None else "n/a"
    items = [
        ("GPU 1", S["iu"], 60, 85, fmt_pct(S["iu"]), S["intel_hist"], f"Intel {ifreq}", None),
        ("GPU 2", S["gu"], 60, 85, fmt_pct(S["gu"]), S["nv_hist"], f"NVIDIA {fmt_temp(S['gt'])}", S["gt"]),
        ("Battery", S["bat"], 30, 70, fmt_pct(S["bat"]), None, S["bstat"] or "n/a", "bat"),
    ]
    gap = 1 if ih >= len(items) * 3 - 1 else 0
    cy = iy
    for label, p, wn, cr, txt, hist, det, extra in items:
        if cy + 1 >= iy + ih:
            break
        row(scr, cy, ix, iw, label, p, wn, cr, txt, invert=(extra == "bat"))
        if hist is not None:
            sparkline(scr, cy + 1, ix + 9, sw, hist)
            dattr = lvl(extra, 70, 85) if extra is not None else curses.A_DIM
            put(scr, cy + 1, ix + 9 + sw + 1, det, dattr)
        else:
            put(scr, cy + 1, ix + 9, det, curses.A_DIM)
        cy += 2 + gap

# ───────────── main screen ─────────────
def sample(S):
    tot, cores = read_stat()
    ptot, pcores = S["prev"]
    S["usage"] = cpct(tot, ptot)
    S["cores"] = [cpct(c, p) for c, p in zip(cores, pcores)]
    S["prev"] = (tot, cores)
    S["cpu_hist"].append(S["usage"])
    S["freq"] = read_freq()
    S["ct"] = read_cpu_temp()
    S["mem"] = read_mem()
    S["disk"] = read_disk("/")
    S["up"], S["l1"], S["l5"], S["l15"] = read_sys()
    S["iu"], S["ifreq"] = read_intel()
    if S["iu"] is not None:
        S["intel_hist"].append(S["iu"])
    S["gt"], S["gu"] = read_nvidia()
    if S["gu"] is not None:
        S["nv_hist"].append(S["gu"])
    S["bat"], S["bstat"] = read_battery()
    if time.time() - S["procs_t"] >= PROC_EVERY:
        S["procs"], S["procs_t"] = read_procs(), time.time()

def draw(scr, S):
    scr.erase()
    h, w = scr.getmaxyx()
    if h < 24 or w < 80:
        put(scr, 0, 0, "Terminal too small (need 80x24)")
        scr.refresh()
        return

    left = " Fedora Monitor "
    bat = f"BAT {S['bat']}% {S['bstat']}" if S["bat"] is not None else "BAT n/a"
    right = f" {bat} │ {time.strftime('%H:%M:%S')} "
    put(scr, 0, 0, left + " " * (w - len(left) - len(right)) + right,
        curses.color_pair(7) | curses.A_BOLD)

    bh = h - 2
    cpu_h = max(12, bh * 2 // 5)
    bot_h = bh - cpu_h
    if bot_h < 10:
        cpu_h, bot_h = bh - 10, 10
    draw_cpu(scr, 1, 0, cpu_h, w, S)
    half = w // 2
    draw_mem(scr, 1 + cpu_h, 0, bot_h, half, S)
    draw_gpu(scr, 1 + cpu_h, half, bot_h, w - half, S)

    put(scr, h - 1, 0, f" q quit │ a art on/off │ refresh {REFRESH:g}s ", curses.A_DIM)
    scr.refresh()

def main(scr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    # Each section has its own color. Pairs 1-3: ok / warm / hot status colors.
    # Pairs 4-6: section colors (cpu, gpu, mem) for borders, titles, bars and graphs.
    if curses.COLORS >= 256:
        colors = (141, 221, 205, 141, 75, 79)       # violet, gold, hot pink | violet, sky blue, teal
        header = (231, 98)                          # white on a violet bar
    else:                                           # plain 8-color terminals
        colors = (curses.COLOR_MAGENTA, curses.COLOR_YELLOW, curses.COLOR_RED,
                  curses.COLOR_MAGENTA, curses.COLOR_CYAN, curses.COLOR_GREEN)
        header = (curses.COLOR_WHITE, curses.COLOR_MAGENTA)
    for i, c in enumerate(colors, 1):
        curses.init_pair(i, c, -1)
    curses.init_pair(7, *header)
    curses.init_pair(9, 155 if curses.COLORS >= 256 else curses.COLOR_WHITE, -1)   # top apps: lime

    S = {"cpu_hist": deque(maxlen=HIST), "intel_hist": deque(maxlen=HIST),
         "nv_hist": deque(maxlen=HIST), "model": cpu_model(), "prev": read_stat(),
         "art": True, "procs": [], "procs_t": 0}
    time.sleep(0.3)                     # first CPU reading needs a small gap
    last = 0

    while True:
        now = time.time()
        if now - last >= REFRESH - 0.05:    # resize/keypress redraws reuse old values
            sample(S)
            last = now
        draw(scr, S)
        remaining = last + REFRESH - time.time()
        scr.timeout(max(50, int(remaining * 1000)))   # getch() waits: no busy loop
        key = scr.getch()               # -1 on timeout, KEY_RESIZE on resize
        if key in (ord("q"), ord("Q"), 27):
            break
        if key in (ord("a"), ord("A")):
            S["art"] = not S["art"]

_locale.setlocale(_locale.LC_ALL, "")
os.environ.setdefault("ESCDELAY", "25")
try:
    curses.wrapper(main)
except KeyboardInterrupt:
    pass