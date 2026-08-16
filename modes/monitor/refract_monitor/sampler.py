"""Readers for CPU, GPU, memory and power. No GUI code lives here.

EVERY READER RETURNS None OR A PARTIAL DICT RATHER THAN RAISING. A system
monitor runs on hardware nobody tested it against: desktops with no battery,
machines with no discrete GPU, kernels that expose a sysfs file this year and
rename it next year. A monitor that crashes on a missing file is worse than one
that shows a dash, so every read is guarded and every caller must handle None.

Nothing here needs root. Where a metric genuinely requires privilege (Intel GPU
utilisation needs intel_gpu_top as root) it is reported as unavailable rather
than silently shown as zero — a flat zero line is indistinguishable from an idle
GPU and would be a lie.
"""
import os
import glob
import subprocess

PROC = "/proc"
SYS = "/sys"


def _read(path, default=None):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except (OSError, ValueError):
        return default


def _read_int(path, default=None):
    v = _read(path)
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


# --------------------------------------------------------------------------- CPU
class CpuSampler:
    """Per-core utilisation from /proc/stat deltas.

    Utilisation is a RATE, so it needs two samples. The first call therefore has
    nothing meaningful to report and returns zeros rather than a fabricated
    number derived from uptime — which would show a bogus spike on launch.
    """

    def __init__(self):
        self._prev = {}

    def _stat(self):
        out = {}
        txt = _read(f"{PROC}/stat", "")
        for line in txt.splitlines():
            if not line.startswith("cpu"):
                continue
            parts = line.split()
            name = parts[0]
            if name == "cpu" or name[3:].isdigit():
                try:
                    vals = [int(x) for x in parts[1:]]
                except ValueError:
                    continue
                out[name] = vals
        return out

    def sample(self):
        cur = self._stat()
        result = {"total": 0.0, "cores": []}
        names = sorted(
            (n for n in cur if n != "cpu"),
            key=lambda n: int(n[3:]),
        )
        for name in ["cpu"] + names:
            vals = cur.get(name)
            prev = self._prev.get(name)
            pct = 0.0
            if vals and prev and len(vals) >= 4 and len(prev) >= 4:
                idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
                pidle = prev[3] + (prev[4] if len(prev) > 4 else 0)
                total = sum(vals)
                ptotal = sum(prev)
                dt = total - ptotal
                di = idle - pidle
                if dt > 0:
                    pct = max(0.0, min(100.0, (dt - di) * 100.0 / dt))
            if name == "cpu":
                result["total"] = pct
            else:
                result["cores"].append(pct)
        self._prev = cur

        result["loadavg"] = None
        la = _read(f"{PROC}/loadavg", "")
        if la:
            bits = la.split()
            if len(bits) >= 3:
                result["loadavg"] = tuple(bits[:3])

        result["mhz"] = None
        freqs = []
        for p in glob.glob(f"{SYS}/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"):
            v = _read_int(p)
            if v:
                freqs.append(v / 1000.0)
        if not freqs:
            for line in _read(f"{PROC}/cpuinfo", "").splitlines():
                if line.lower().startswith("cpu mhz"):
                    try:
                        freqs.append(float(line.split(":", 1)[1]))
                    except (IndexError, ValueError):
                        pass
        if freqs:
            result["mhz"] = sum(freqs) / len(freqs)

        result["temp_c"] = cpu_temperature()
        result["model"] = cpu_model()
        result["governor"] = _read(
            f"{SYS}/devices/system/cpu/cpu0/cpufreq/scaling_governor"
        )
        return result


def cpu_model():
    for line in _read(f"{PROC}/cpuinfo", "").splitlines():
        if line.lower().startswith("model name"):
            return line.split(":", 1)[1].strip()
    return None


def cpu_temperature():
    """Package temperature in °C.

    hwmon naming is not stable across drivers, so the sensor is chosen by LABEL
    (coretemp's "Package id 0", k10temp's "Tctl") and only falls back to a bare
    temp1_input for a known-CPU driver. Picking the first hwmon on the system
    would happily report the NVMe drive's temperature as the CPU's.
    """
    best = None
    for hw in glob.glob(f"{SYS}/class/hwmon/hwmon*"):
        name = (_read(f"{hw}/name") or "").lower()
        if name not in ("coretemp", "k10temp", "zenpower", "cpu_thermal", "acpitz"):
            continue
        for lbl in glob.glob(f"{hw}/temp*_label"):
            label = (_read(lbl) or "").lower()
            if "package" in label or "tctl" in label or "tdie" in label:
                v = _read_int(lbl.replace("_label", "_input"))
                if v:
                    return v / 1000.0
        if best is None:
            v = _read_int(f"{hw}/temp1_input")
            if v:
                best = v / 1000.0
    return best


# --------------------------------------------------------------------------- RAM
def memory():
    info = {}
    for line in _read(f"{PROC}/meminfo", "").splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        try:
            info[k.strip()] = int(v.strip().split()[0]) * 1024
        except (ValueError, IndexError):
            continue
    total = info.get("MemTotal")
    if not total:
        return None
    # MemAvailable, not MemFree: free excludes cache the kernel would hand back
    # on demand, and reporting it as "used" is the classic way to convince
    # someone their machine is out of memory when it is fine.
    avail = info.get("MemAvailable", info.get("MemFree", 0))
    swap_total = info.get("SwapTotal", 0)
    swap_free = info.get("SwapFree", 0)
    return {
        "total": total,
        "available": avail,
        "used": total - avail,
        "cached": info.get("Cached", 0) + info.get("SReclaimable", 0),
        "buffers": info.get("Buffers", 0),
        "swap_total": swap_total,
        "swap_used": swap_total - swap_free,
    }


def top_processes(limit=8):
    """Largest RSS consumers. Unreadable /proc entries are skipped: processes
    die mid-scan constantly, and that is normal, not an error."""
    procs = []
    for pid in os.listdir(PROC):
        if not pid.isdigit():
            continue
        status = _read(f"{PROC}/{pid}/status")
        if not status:
            continue
        name = None
        rss = None
        for line in status.splitlines():
            if line.startswith("Name:"):
                name = line.split(":", 1)[1].strip()
            elif line.startswith("VmRSS:"):
                try:
                    rss = int(line.split()[1]) * 1024
                except (ValueError, IndexError):
                    pass
            if name and rss is not None:
                break
        if name and rss:
            procs.append((name, rss, pid))
    procs.sort(key=lambda p: p[1], reverse=True)
    return procs[:limit]


# ----------------------------------------------------------------- Processes
# WHY THIS EXISTS, AND WHY IT HAD TO BEFORE ANYTHING WAS HIDDEN.
#
# Refract Monitor and GNOME's System Monitor sat in the app grid as two entries
# that look like the same tool, which is what got reported ("2 activity
# monitors"). Hiding one is the obvious fix, and hiding the WRONG one silently
# removes the only graphical way to end a stuck program — which is the single
# thing people open a system monitor to do. So the process list and the ability
# to end a process are built here first, and only then is the stock one hidden.
#
# Everything comes from /proc/<pid>/stat in ONE read per process: name, CPU
# jiffies and RSS pages all live in that line, so a full scan is one open() per
# process rather than the three the naive version would take.
_UID_NAMES = {}


def _uid_name(uid):
    if uid not in _UID_NAMES:
        try:
            import pwd
            _UID_NAMES[uid] = pwd.getpwuid(uid).pw_name
        except (KeyError, ImportError, OSError):
            _UID_NAMES[uid] = str(uid)
    return _UID_NAMES[uid]


def _total_jiffies():
    line = (_read(f"{PROC}/stat") or "").split("\n", 1)[0].split()
    if not line or line[0] != "cpu":
        return None
    try:
        return sum(int(x) for x in line[1:])
    except ValueError:
        return None


def _proc_line(pid):
    """One process from /proc/<pid>/stat, or None if it vanished mid-scan."""
    stat = _read(f"{PROC}/{pid}/stat")
    if not stat:
        return None
    # comm is parenthesised and MAY CONTAIN SPACES AND PARENTHESES — a program
    # called "foo (bar) baz" is legal, and splitting on whitespace or on the
    # first ')' mis-parses every field after it. First '(' to LAST ')' is the
    # only correct read, and proc(5) says so.
    lp = stat.find("(")
    rp = stat.rfind(")")
    if lp < 0 or rp < lp:
        return None
    name = stat[lp + 1:rp]
    rest = stat[rp + 1:].split()
    # rest[0] is field 3 (state), so field N is rest[N-3]:
    # utime=14 -> rest[11], stime=15 -> rest[12], rss (pages) =24 -> rest[21].
    try:
        jiffies = int(rest[11]) + int(rest[12])
        rss = int(rest[21]) * os.sysconf("SC_PAGE_SIZE")
    except (IndexError, ValueError, OSError):
        return None
    # comm is truncated to 15 characters by the kernel, which turns
    # "gnome-shell-calendar-server" into "gnome-shell-ca". argv[0]'s basename is
    # what the user actually recognises, so prefer it when it is readable.
    cmd = _read(f"{PROC}/{pid}/cmdline") or ""
    argv0 = cmd.split("\0", 1)[0]
    if argv0:
        base = os.path.basename(argv0)
        if base:
            name = base
    try:
        uid = os.stat(f"{PROC}/{pid}").st_uid
    except OSError:
        uid = -1
    return {"pid": int(pid), "name": name, "rss": rss, "user": _uid_name(uid),
            "uid": uid, "_jiffies": jiffies}


class ProcessSampler:
    """Per-process CPU share, as a delta — the only honest way to read it.

    /proc/<pid>/stat's utime+stime are CUMULATIVE since the process started, so
    a single reading gives "percent of this process's whole lifetime". That
    number only ever falls, is unrelated to what the machine is doing now, and
    would make a busy process launched an hour ago look idle. The delta is taken
    against total CPU jiffies over the same interval, which makes the column
    directly comparable to the CPU page's headline figure.

    Like CpuSampler, the FIRST sample has no previous reading to subtract from
    and reports 0.0 rather than inventing a number.
    """

    def __init__(self):
        self._prev = {}
        self._prev_total = None

    def sample(self):
        total = _total_jiffies()
        procs = []
        seen = {}
        try:
            pids = [p for p in os.listdir(PROC) if p.isdigit()]
        except OSError:
            return []
        span = None
        if total is not None and self._prev_total is not None and total > self._prev_total:
            span = total - self._prev_total
        for pid in pids:
            # Processes die mid-scan constantly. That is normal, not an error.
            entry = _proc_line(pid)
            if not entry:
                continue
            j = entry.pop("_jiffies")
            seen[entry["pid"]] = j
            prev = self._prev.get(entry["pid"])
            if span and prev is not None and j >= prev:
                # Multiplied by the CPU count so a fully-busy single thread
                # reads 100%, matching what every other process monitor shows
                # (and what people expect), rather than 1/Nth of the machine.
                entry["cpu"] = (j - prev) / span * 100.0 * (os.cpu_count() or 1)
            else:
                entry["cpu"] = 0.0
            procs.append(entry)
        self._prev = seen
        self._prev_total = total
        return procs


def end_process(pid, force=False):
    """SIGTERM (or SIGKILL) a process. Returns (ok, message).

    NEVER RAISES, and reports WHY it failed. Refusing without a reason is how a
    button that quietly does nothing gets shipped: the overwhelmingly common
    failure here is EPERM on a process owned by root or another user, and
    "Permission denied" is a complete, actionable answer where a silent no-op
    is not.
    """
    import signal
    try:
        os.kill(int(pid), signal.SIGKILL if force else signal.SIGTERM)
        return True, ""
    except ProcessLookupError:
        return True, "already gone"
    except PermissionError:
        return False, ("This process belongs to another user. "
                       "Only its owner (or root) can end it.")
    except (OSError, ValueError) as e:
        return False, str(e)


# --------------------------------------------------------------------------- GPU
def _nvidia():
    try:
        out = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    parts = [p.strip() for p in out.stdout.strip().splitlines()[0].split(",")]
    if len(parts) < 5:
        return None

    def num(x):
        try:
            return float(x)
        except ValueError:
            return None

    return {
        "vendor": "NVIDIA", "name": parts[0], "util": num(parts[1]),
        "mem_used": (num(parts[2]) or 0) * 1024 * 1024,
        "mem_total": (num(parts[3]) or 0) * 1024 * 1024,
        "temp_c": num(parts[4]), "note": None,
    }


def _amd():
    for dev in sorted(glob.glob(f"{SYS}/class/drm/card[0-9]*/device")):
        busy = _read_int(f"{dev}/gpu_busy_percent")
        if busy is None:
            continue
        used = _read_int(f"{dev}/mem_info_vram_used", 0)
        total = _read_int(f"{dev}/mem_info_vram_total", 0)
        temp = None
        for hw in glob.glob(f"{dev}/hwmon/hwmon*/temp1_input"):
            v = _read_int(hw)
            if v:
                temp = v / 1000.0
                break
        return {"vendor": "AMD", "name": _pci_name(dev) or "AMD GPU",
                "util": float(busy), "mem_used": used, "mem_total": total,
                "temp_c": temp, "note": None}
    return None


def _intel():
    for card in sorted(glob.glob(f"{SYS}/class/drm/card[0-9]*")):
        dev = f"{card}/device"
        vendor = _read(f"{dev}/vendor")
        if vendor != "0x8086":
            continue
        freq = _read_int(f"{card}/gt_cur_freq_mhz") or _read_int(f"{dev}/gt_cur_freq_mhz")
        temp = None
        for hw in glob.glob(f"{dev}/hwmon/hwmon*/temp1_input"):
            v = _read_int(hw)
            if v:
                temp = v / 1000.0
                break
        return {
            "vendor": "Intel", "name": _pci_name(dev) or "Intel Graphics",
            # Intel exposes no unprivileged utilisation counter. Reporting 0
            # would be indistinguishable from an idle GPU, so it is None and the
            # UI says why.
            "util": None, "mem_used": None, "mem_total": None,
            "temp_c": temp, "freq_mhz": freq,
            "note": "Utilisation needs intel_gpu_top as root; frequency shown instead.",
        }
    return None


def _pci_name(dev):
    """Human name for a PCI device, via hwdata's pci.ids. Absent on a minimal
    image, hence the guard — a missing database costs a nicer label, nothing more."""
    vendor = (_read(f"{dev}/vendor") or "").replace("0x", "")
    device = (_read(f"{dev}/device") or "").replace("0x", "")
    if not vendor or not device:
        return None
    try:
        with open("/usr/share/misc/pci.ids", "r", errors="ignore") as f:
            in_vendor = False
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                if not line.startswith("\t"):
                    in_vendor = line.split()[0].lower() == vendor.lower()
                elif in_vendor and line.startswith("\t") and not line.startswith("\t\t"):
                    parts = line.strip().split(None, 1)
                    if parts and parts[0].lower() == device.lower():
                        return parts[1].strip() if len(parts) > 1 else None
    except OSError:
        return None
    return None


def gpu():
    for probe in (_nvidia, _amd, _intel):
        try:
            g = probe()
        except Exception:
            g = None
        if g:
            return g
    return None


# ------------------------------------------------------------------------- POWER
def power():
    """Battery and power draw. Returns None on a machine with no battery, which
    is a legitimate state (desktop, VM) and not a failure."""
    bats = sorted(glob.glob(f"{SYS}/class/power_supply/BAT*"))
    if not bats:
        return None
    b = bats[0]
    capacity = _read_int(f"{b}/capacity")
    status = _read(f"{b}/status")

    # Two kernel conventions: energy_* (µWh) with power_now (µW), or charge_*
    # (µAh) with current_now (µA), which needs voltage to become watts.
    power_w = None
    p = _read_int(f"{b}/power_now")
    if p is not None:
        power_w = abs(p) / 1_000_000.0
    else:
        cur = _read_int(f"{b}/current_now")
        volt = _read_int(f"{b}/voltage_now")
        if cur is not None and volt:
            power_w = abs(cur) * abs(volt) / 1e12

    energy_now = _read_int(f"{b}/energy_now") or _read_int(f"{b}/charge_now")
    energy_full = _read_int(f"{b}/energy_full") or _read_int(f"{b}/charge_full")
    design = _read_int(f"{b}/energy_full_design") or _read_int(f"{b}/charge_full_design")

    health = None
    if energy_full and design:
        health = min(100.0, energy_full * 100.0 / design)

    remaining_h = None
    if power_w and power_w > 0.1 and energy_now:
        scale = 1_000_000.0
        if status == "Charging" and energy_full:
            remaining_h = max(0.0, (energy_full - energy_now) / scale) / power_w
        elif status == "Discharging":
            remaining_h = (energy_now / scale) / power_w

    profile = None
    try:
        out = subprocess.run(["powerprofilesctl", "get"],
                             capture_output=True, text=True, timeout=2)
        if out.returncode == 0:
            profile = out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        profile = None

    return {"capacity": capacity, "status": status, "power_w": power_w,
            "health": health, "remaining_h": remaining_h, "profile": profile,
            "vendor": _read(f"{b}/manufacturer"), "model": _read(f"{b}/model_name")}


def fmt_bytes(n):
    if n is None:
        return "—"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024.0
    return "—"
