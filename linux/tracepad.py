#!/usr/bin/env python3
"""TracePad para Linux — recebe gestos do app do iPhone (USB ou Bluetooth) e do PWA (Wi-Fi) e injeta no sistema.

Mesmo protocolo de texto do app do Mac (mac/Input.swift). As teclas chegam com códigos do Mac e são traduzidas
para as mesmas teclas físicas; ⌘ vira Ctrl (ou Super com TRACEPAD_CMD=super) e ❖ (w) é Super. Os gestos padrão
chegam por nome ("g mission") e podem ser redefinidos em ~/.tracepad-actions ("@mission = super+w").

Dependências: python3-evdev (obrigatório: mouse/teclado via /dev/uinput, funciona em X11 e Wayland).
Opcionais: psutil (modo Monitor), bleak (Bluetooth), usbmuxd (USB), pactl, brightnessctl, wmctrl/xdotool (modo Apps no X11),
xdotool/wtype/wl-copy (digitar texto com acentos).

Uso: python3 linux/tracepad.py [pasta-do-pwa]
"""

import asyncio
import base64
import glob
import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse

try:
    sys.stdout.reconfigure(line_buffering=True)
except AttributeError:
    pass

HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))
HTTP_PORT, WS_PORT = 8787, 8788
USB_DEVICE_PORT = 2345
BLE_SERVICE = "6e7a0001-5c3b-4a8e-9f2d-7a1c0de5a001"
BLE_COMMANDS = "6e7a0002-5c3b-4a8e-9f2d-7a1c0de5a001"
BLE_REPLIES = "6e7a0003-5c3b-4a8e-9f2d-7a1c0de5a001"
US = "\x1f"  # separador de campos do protocolo


def log(*a):
    print(*a, flush=True)


def clean(s):
    """Remove separadores do protocolo de nomes vindos do sistema."""
    return s.replace("\t", " ").replace("\n", " ").replace(US, " ")


def which(cmd):
    return shutil.which(cmd) is not None


def run(args, timeout=3):
    """Roda e devolve a saída (str) ou None."""
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def spawn(args, label=None, **kw):
    """Dispara sem esperar; uma thread recolhe o processo (sem zumbis) e avisa se falhar."""
    try:
        p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, start_new_session=True, **kw)
    except OSError as e:
        log("✗ %s: %s" % (label or args[0], e))
        return

    def wait():
        if p.wait() != 0 and label:
            log("✗ %s: saiu com %d" % (label, p.returncode))

    threading.Thread(target=wait, daemon=True).start()


def read_pin():
    path = os.path.join(HOME, ".tracepad-pin")
    try:
        s = open(path).read().strip()
        if len(s) == 6:
            return s
    except OSError:
        pass
    s = "%06d" % (int.from_bytes(os.urandom(4), "big") % 1000000)
    try:
        with open(path, "w") as f:
            f.write(s)
        os.chmod(path, 0o600)
    except OSError:
        pass
    return s


PIN = read_pin()

# apresentação deste computador: o iPhone mostra o tipo e escolhe entre vários no Bluetooth
HELLO = "H linux " + clean(os.environ.get("TRACEPAD_NAME") or socket.gethostname() or "Linux")

# MARK: - Injeção de eventos (uinput)

try:
    from evdev import UInput, ecodes as E
except ImportError:
    UInput, E = None, None


def _mac_keys():
    if E is None:
        return {}
    k = {
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "EQUAL", 25: "9", 26: "7",
        27: "MINUS", 28: "8", 29: "0", 30: "RIGHTBRACE", 31: "O", 32: "U", 33: "LEFTBRACE", 34: "I", 35: "P", 36: "ENTER",
        37: "L", 38: "J", 39: "APOSTROPHE", 40: "K", 41: "SEMICOLON", 42: "BACKSLASH", 43: "COMMA", 44: "SLASH", 45: "N",
        46: "M", 47: "DOT", 48: "TAB", 49: "SPACE", 50: "GRAVE", 51: "BACKSPACE", 53: "ESC",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12",
        115: "HOME", 116: "PAGEUP", 117: "DELETE", 118: "F4", 119: "END", 120: "F2", 121: "PAGEDOWN", 122: "F1",
        123: "LEFT", 124: "RIGHT", 125: "DOWN", 126: "UP",
    }
    return {mac: getattr(E, "KEY_" + name) for mac, name in k.items()}


MAC_KEYS = _mac_keys()

# ASCII → (tecla, shift) no layout US, para digitar sem ferramentas externas
US_CHARS = {}
if E is not None:
    for c in "abcdefghijklmnopqrstuvwxyz":
        US_CHARS[c] = (getattr(E, "KEY_" + c.upper()), False)
        US_CHARS[c.upper()] = (getattr(E, "KEY_" + c.upper()), True)
    for c in "1234567890":
        US_CHARS[c] = (getattr(E, "KEY_" + c), False)
    for plain, shifted, name in [("-", "_", "MINUS"), ("=", "+", "EQUAL"), ("[", "{", "LEFTBRACE"), ("]", "}", "RIGHTBRACE"),
                                 ("\\", "|", "BACKSLASH"), (";", ":", "SEMICOLON"), ("'", '"', "APOSTROPHE"), ("`", "~", "GRAVE"),
                                 (",", "<", "COMMA"), (".", ">", "DOT"), ("/", "?", "SLASH")]:
        US_CHARS[plain] = (getattr(E, "KEY_" + name), False)
        US_CHARS[shifted] = (getattr(E, "KEY_" + name), True)
    for c, s in zip("!@#$%^&*()", "1234567890"):
        US_CHARS[c] = (getattr(E, "KEY_" + s), True)
    US_CHARS[" "] = (E.KEY_SPACE, False)
    US_CHARS["\t"] = (E.KEY_TAB, False)


class Input:
    SCROLL_HI = 2.4  # unidades hi-res (120 = um "dente" da roda) por ponto rolado no iPhone

    def __init__(self):
        self.mouse = self.kbd = None
        self.held = None
        self.rem = [0.0, 0.0]
        self.wheel = [0, 0]
        self.cmd = "super" if os.environ.get("TRACEPAD_CMD", "").lower() == "super" else "ctrl"
        if UInput is None:
            log("⚠️  python3-evdev não instalado: sem mouse/teclado (instale python3-evdev).")
            return
        try:
            hi_v, hi_h = getattr(E, "REL_WHEEL_HI_RES", 11), getattr(E, "REL_HWHEEL_HI_RES", 12)
            self.hi = (hi_h, hi_v)
            self.mouse = UInput({E.EV_KEY: [E.BTN_LEFT, E.BTN_RIGHT, E.BTN_MIDDLE],
                                 E.EV_REL: [E.REL_X, E.REL_Y, E.REL_WHEEL, E.REL_HWHEEL, hi_v, hi_h]}, name="TracePad Mouse")
            self.kbd = UInput({E.EV_KEY: list(range(1, 249))}, name="TracePad Keyboard")
        except Exception as e:  # OSError ou UInputError, conforme a versão do evdev
            self.mouse = self.kbd = None
            log("✗ sem acesso a /dev/uinput (%s). Rode linux/install.sh ou veja o README." % e)

    def _w(self, dev, typ, code, val):
        dev.write(typ, code, val)

    def move(self, dx, dy):
        if not self.mouse:
            return
        self.rem[0] += dx
        self.rem[1] += dy
        ix, iy = int(self.rem[0]), int(self.rem[1])
        if not ix and not iy:
            return
        self.rem[0] -= ix
        self.rem[1] -= iy
        if ix:
            self._w(self.mouse, E.EV_REL, E.REL_X, ix)
        if iy:
            self._w(self.mouse, E.EV_REL, E.REL_Y, iy)
        self.mouse.syn()

    def _btn(self, b):
        return {"r": E.BTN_RIGHT, "m": E.BTN_MIDDLE}.get(b, E.BTN_LEFT)

    def _mods(self, mods):
        keys = []
        for m in "tascw":  # ⌃ ⌥ ⇧ ⌘ ❖
            if m not in mods:
                continue
            k = {"t": E.KEY_LEFTCTRL, "a": E.KEY_LEFTALT, "s": E.KEY_LEFTSHIFT, "w": E.KEY_LEFTMETA,
                 "c": E.KEY_LEFTMETA if self.cmd == "super" else E.KEY_LEFTCTRL}[m]
            if k not in keys:
                keys.append(k)
        return keys

    def _hold(self, keys, down):
        for k in (keys if down else reversed(keys)):
            self._w(self.kbd, E.EV_KEY, k, 1 if down else 0)
            self.kbd.syn()

    def click(self, b, mods=""):
        if not self.mouse:
            return
        mk = self._mods(mods) if self.kbd else []
        self._hold(mk, True)
        for v in (1, 0):
            self._w(self.mouse, E.EV_KEY, self._btn(b), v)
            self.mouse.syn()
        self._hold(mk, False)

    def press(self):
        if self.mouse and self.held is None:
            self.held = E.BTN_LEFT
            self._w(self.mouse, E.EV_KEY, self.held, 1)
            self.mouse.syn()

    def release(self):
        if self.mouse and self.held is not None:
            self._w(self.mouse, E.EV_KEY, self.held, 0)
            self.mouse.syn()
            self.held = None

    def scroll(self, dx, dy):
        if not self.mouse or (not dx and not dy):
            return
        # macOS: dy > 0 rola para cima (igual ao REL_WHEEL); dx > 0 rola para a esquerda (oposto do REL_HWHEEL)
        for i, (v, legacy) in enumerate(((-dx, E.REL_HWHEEL), (dy, E.REL_WHEEL))):
            hv = int(round(v * self.SCROLL_HI))
            if not hv:
                continue
            self._w(self.mouse, E.EV_REL, self.hi[i], hv)
            self.wheel[i] += hv
            n = int(self.wheel[i] / 120)
            if n:
                self._w(self.mouse, E.EV_REL, legacy, n)
                self.wheel[i] -= n * 120
        self.mouse.syn()

    def combo(self, keys):
        if not self.kbd or not keys:
            return
        self._hold(keys, True)
        self._hold(keys, False)

    def key(self, code, mods=""):
        if not self.kbd:
            return
        k = MAC_KEYS.get(code)
        if k is not None:
            self.combo(self._mods(mods) + [k])

    def media(self, key):
        k = {16: E.KEY_PLAYPAUSE, 17: E.KEY_NEXTSONG, 18: E.KEY_PREVIOUSSONG}.get(key) if E else None
        if k:
            self.combo([k])

    def type(self, text):
        for i, line in enumerate(text.split("\n")):
            if i:
                self.combo([E.KEY_ENTER] if E else [])
            if line:
                self._type_line(line)

    def _type_line(self, s):
        if which("hyprctl"):
            hypr.env()  # serviço sem WAYLAND_DISPLAY: acha o socket para o wtype
        session = os.environ.get("XDG_SESSION_TYPE", "")
        wayland = session == "wayland" or "WAYLAND_DISPLAY" in os.environ
        # ferramentas externas respeitam o layout do teclado e digitam qualquer caractere
        if not wayland and which("xdotool") and run(["xdotool", "type", "--clearmodifiers", "--delay", "0", "--", s]) is not None:
            return
        if wayland and which("wtype") and run(["wtype", "--", s]) is not None:
            return  # wlroots, Hyprland, Sway… (o GNOME não aceita o protocolo do wtype)
        if all(c in US_CHARS for c in s) or not (wayland and which("wl-copy")):
            for c in s:
                if c in US_CHARS:
                    k, shift = US_CHARS[c]
                    self.combo([E.KEY_LEFTSHIFT, k] if shift else [k])
            return
        # acentos no GNOME/KDE Wayland: cola pela área de transferência
        if run(["wl-copy", "--", s]) is not None:
            self.combo([E.KEY_LEFTCTRL, E.KEY_V])


inp = Input()

# MARK: - Volume, brilho e mídia


class Latest:
    """Aplica só o último valor pedido (arrastar o slider manda dezenas por segundo)."""

    def __init__(self, fn):
        self.fn, self.val, self.cv = fn, None, threading.Condition()
        threading.Thread(target=self._loop, daemon=True).start()

    def set(self, v):
        with self.cv:
            self.val = v
            self.cv.notify()

    def _loop(self):
        while True:
            with self.cv:
                while self.val is None:
                    self.cv.wait()
                v, self.val = self.val, None
            self.fn(v)


class System:
    """Volume por pactl (PulseAudio/pipewire-pulse) ou wpctl (WirePlumber); brilho por brightnessctl."""

    def __init__(self):
        self.pactl, self.wpctl, self.bctl = which("pactl"), which("wpctl"), which("brightnessctl")
        self._vol = Latest(self._apply_volume)
        self._bri = Latest(lambda v: run(["brightnessctl", "-q", "set", "%d%%" % max(1, round(v * 100))]))

    def _apply_volume(self, v):
        if self.pactl:
            run(["pactl", "set-sink-volume", "@DEFAULT_SINK@", "%d%%" % round(v * 100)])
        elif self.wpctl:
            run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "%.2f" % v])

    def _wp(self):
        """'Volume: 0.40 [MUTED]' → (0.4, True)"""
        out = run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]) if self.wpctl else None
        m = re.search(r"([\d.]+)", out or "")
        return (float(m.group(1)) if m else -1), bool(out and "MUTED" in out)

    def volume(self):
        if self.pactl:
            m = re.search(r"(\d+)%", run(["pactl", "get-sink-volume", "@DEFAULT_SINK@"]) or "")
            return int(m.group(1)) / 100 if m else -1
        return self._wp()[0]

    def muted(self):
        if self.pactl:
            out = run(["pactl", "get-sink-mute", "@DEFAULT_SINK@"])
            return bool(out and "yes" in out)
        return self._wp()[1]

    def set_volume(self, v):
        if self.pactl or self.wpctl:
            self._vol.set(min(max(v, 0), 1))
            if v > 0:
                spawn(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "0"] if self.pactl else ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"])

    def toggle_mute(self):
        if self.pactl:
            run(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle"])
        elif self.wpctl:
            run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])

    def brightness(self):
        out = run(["brightnessctl", "-m"]) if self.bctl else None
        f = (out or "").strip().split("\n")[0].split(",")
        try:
            return int(f[2]) / int(f[4])
        except (IndexError, ValueError, ZeroDivisionError):
            return -1

    def set_brightness(self, v):
        if self.bctl:
            self._bri.set(min(max(v, 0), 1))

    def state(self):
        """'S volume brilho mudo' — -1 quando não disponível."""
        return "S %.3f %.3f %d" % (self.volume(), self.brightness(), 1 if self.muted() else 0)


system = System()

# MARK: - Monitor (psutil)

try:
    import psutil
except ImportError:
    psutil = None


class Stats:
    def __init__(self):
        self.prev_net = None
        self.warned = False
        if psutil:
            psutil.cpu_percent(None)

    def _gpu(self):
        for f in glob.glob("/sys/class/drm/card*/device/gpu_busy_percent"):  # AMD/Intel recentes
            try:
                return int(open(f).read()) / 100
            except (OSError, ValueError):
                pass
        if which("nvidia-smi"):
            out = run(["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"], timeout=2)
            try:
                return max(int(x) for x in out.split()) / 100
            except (AttributeError, ValueError):
                pass
        return -1

    def line(self):
        """'T cpu gpu memUsado memTotal redeEntrada redeSaída discoUsado discoTotal bateria carregando núcleos'"""
        if not psutil:
            if not self.warned:
                log("⚠️  instale psutil (python3-psutil) para o modo Monitor")
                self.warned = True
            return None
        vm = psutil.virtual_memory()
        now = time.monotonic()
        nic = psutil.net_io_counters(pernic=True)
        rx = sum(v.bytes_recv for k, v in nic.items() if k != "lo")
        tx = sum(v.bytes_sent for k, v in nic.items() if k != "lo")
        rin = rout = 0.0
        if self.prev_net and now > self.prev_net[0]:
            dt = now - self.prev_net[0]
            rin, rout = max(rx - self.prev_net[1], 0) / dt, max(tx - self.prev_net[2], 0) / dt
        self.prev_net = (now, rx, tx)
        du = psutil.disk_usage("/")
        bat = psutil.sensors_battery() if hasattr(psutil, "sensors_battery") else None
        return "T %.3f %.3f %.0f %.0f %.0f %.0f %.0f %.0f %.3f %d %d" % (
            psutil.cpu_percent(None) / 100, self._gpu(), vm.total - vm.available, vm.total, rin, rout, du.used, du.total,
            bat.percent / 100 if bat else -1, 1 if bat and bat.power_plugged else 0, psutil.cpu_count() or 1)

    def processes(self, limit=8):
        """'P nome␟cpu␟memória\\t…' — cpu em fração de um núcleo"""
        if not psutil:
            return None
        rows = []
        for p in psutil.process_iter(["name", "memory_info"]):  # psutil guarda os objetos: cpu_percent vira delta
            try:
                rows.append((p.cpu_percent(None) / 100, p.info["name"] or "?", p.info["memory_info"].rss if p.info["memory_info"] else 0))
            except (psutil.Error, AttributeError):
                pass
        rows.sort(key=lambda r: -r[0])
        return "P " + "\t".join("%s%s%.3f%s%.0f" % (clean(n), US, c, US, m) for c, n, m in rows[:limit])


stats = Stats()

# MARK: - Apps (.desktop para abrir; wmctrl/xdotool para janelas no X11)


class DesktopEntry:
    def __init__(self, path, did, fields):
        self.path, self.id = path, did
        lang = os.environ.get("LANG", "").split(".")[0]
        self.name = fields.get("Name[%s]" % lang) or fields.get("Name[%s]" % lang.split("_")[0]) or fields.get("Name") or did
        self.icon = fields.get("Icon", "")
        self.wmclass = fields.get("StartupWMClass", "").lower()
        self.exec = fields.get("Exec", "")

    def matches_class(self, cls):
        c = cls.lower()
        stem = self.id[:-8].lower() if self.id.endswith(".desktop") else self.id.lower()
        return c in (self.wmclass, stem, stem.split(".")[-1], self.name.lower())


def data_dirs():
    home = os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local/share")
    rest = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    dirs = [home] + [d for d in rest.split(":") if d]
    for extra in ["/var/lib/flatpak/exports/share", os.path.join(HOME, ".local/share/flatpak/exports/share")]:
        if extra not in dirs:
            dirs.append(extra)
    return dirs


def load_desktop_entries():
    seen, out = set(), []
    for d in data_dirs():
        base = os.path.join(d, "applications")
        for path in glob.glob(os.path.join(base, "**/*.desktop"), recursive=True):
            did = os.path.relpath(path, base).replace("/", "-")
            if did in seen:
                continue
            seen.add(did)
            fields, section = {}, None
            try:
                for line in open(path, encoding="utf-8", errors="replace"):
                    line = line.strip()
                    if line.startswith("["):
                        section = line
                    elif section == "[Desktop Entry]" and "=" in line:
                        k, v = line.split("=", 1)
                        fields.setdefault(k.strip(), v.strip())
            except OSError:
                continue
            if fields.get("Type") != "Application" or fields.get("NoDisplay") == "true" or fields.get("Hidden") == "true":
                continue
            out.append(DesktopEntry(path, did, fields))
    out.sort(key=lambda e: e.name.casefold())
    return out


def icon_png(name):
    """Caminho de um PNG (ou SVG convertido) para o ícone do tema; base64 ou None."""
    if not name:
        return None
    path = name if name.startswith("/") else None
    if not path:
        for d in data_dirs():
            for size in ["256x256", "128x128", "96x96", "64x64", "48x48", "scalable"]:
                for ext in ["png", "svg"]:
                    p = os.path.join(d, "icons/hicolor", size, "apps", "%s.%s" % (name, ext))
                    if os.path.exists(p):
                        path = p
                        break
                if path:
                    break
            if path:
                break
    if not path:
        for ext in ["png", "svg"]:
            p = "/usr/share/pixmaps/%s.%s" % (name, ext)
            if os.path.exists(p):
                path = p
                break
    if not path:
        return None
    if path.endswith(".svg"):
        if not which("rsvg-convert"):
            return None
        try:
            data = subprocess.run(["rsvg-convert", "-w", "96", "-h", "96", path], capture_output=True, timeout=3).stdout
        except (OSError, subprocess.SubprocessError):
            return None
    else:
        try:
            data = open(path, "rb").read()
        except OSError:
            return None
    return base64.b64encode(data).decode() if data else None


def launch_entry(e):
    if which("gio"):
        spawn(["gio", "launch", e.path], e.name)
    elif which("gtk-launch"):
        spawn(["gtk-launch", e.id], e.name)
    else:
        args = [a for a in shlex.split(e.exec) if not re.match(r"^%[a-zA-Z]$", a)]
        if args:
            spawn(args, e.name)


class Hypr:
    """Hyprland (Omarchy e afins) via hyprctl — aceita a configuração em Lua (hl.dsp.*) e a clássica."""

    def __init__(self):
        self.lua = None  # descoberto no primeiro dispatch

    def env(self):
        """Serviços do systemd podem subir sem as variáveis da sessão: acha a instância e o socket do Wayland."""
        rt = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
        sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
        if not sig or not os.path.isdir(os.path.join(rt, "hypr", sig)):
            dirs = [d for d in glob.glob(os.path.join(rt, "hypr", "*")) if os.path.exists(os.path.join(d, ".socket.sock"))]
            if not dirs:
                return None
            os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = os.path.basename(max(dirs, key=os.path.getmtime))
        if "WAYLAND_DISPLAY" not in os.environ:
            socks = sorted(glob.glob(os.path.join(rt, "wayland-[0-9]")))
            if socks:
                os.environ["WAYLAND_DISPLAY"] = os.path.basename(socks[0])
        return os.environ["HYPRLAND_INSTANCE_SIGNATURE"]

    @property
    def available(self):
        return which("hyprctl") and self.env() is not None

    def json(self, what):
        out = run(["hyprctl", "-j", what])
        try:
            return json.loads(out) if out else None
        except ValueError:
            return None

    def _try(self, args):
        try:
            r = subprocess.run(["hyprctl", "dispatch"] + args, capture_output=True, text=True, timeout=3)
        except (OSError, subprocess.SubprocessError):
            return False
        out = r.stdout.strip()
        return r.returncode == 0 and out in ("", "ok")

    def dispatch(self, lua, classic):
        """lua: expressão hl.dsp.*; classic: [dispatcher, argumento]. Tenta o modo que funcionou da última vez."""
        order = [True, False] if self.lua is not False else [False, True]
        for use_lua in order:
            if self._try([lua] if use_lua else classic):
                self.lua = use_lua
                return True
        return False

    # gestos padrão no Hyprland (sem visão geral nativa: o scratchpad do Omarchy faz as vezes)
    def gesture(self, name):
        g = {
            "space-right": ('hl.dsp.focus({ workspace = "e+1" })', ["workspace", "e+1"]),
            "space-left": ('hl.dsp.focus({ workspace = "e-1" })', ["workspace", "e-1"]),
            "mission": ('hl.dsp.workspace.toggle_special("scratchpad")', ["togglespecialworkspace", "scratchpad"]),
            "desktop": ('hl.dsp.focus({ workspace = "empty" })', ["workspace", "empty"]),
            "expose": ("hl.dsp.window.cycle_next()", ["cyclenext", ""]),
        }.get(name)
        if not g:
            return False
        self.dispatch(*g)
        if name == "expose":
            self.dispatch("hl.dsp.window.bring_to_top()", ["bringactivetotop", ""])
        return True

    def windows(self):
        """[{id, pid, cls, title, hidden}] — janelas mapeadas; as de áreas especiais (minimizadas, scratchpad) contam como ocultas."""
        out = []
        for c in self.json("clients") or []:
            if not c.get("mapped", True) or c.get("pid", -1) <= 0:
                continue
            ws = c.get("workspace") or {}
            out.append({"id": c.get("address", ""), "pid": c["pid"], "cls": c.get("class") or c.get("initialClass") or "?",
                        "title": c.get("title") or "", "hidden": str(ws.get("name", "")).startswith("special:"),
                        "tags": c.get("tags") or []})
        return out

    def active(self):
        return (self.json("activewindow") or {}).get("address")

    def raise_(self, w):
        if w.get("hidden"):  # volta da área especial para a mesa de onde saiu (tag do Omarchy) ou para a atual
            dest = next((t.rsplit("-", 1)[1] for t in w["tags"] if t.startswith("omarchy-minimized-from-")), None) \
                or str((self.json("activeworkspace") or {}).get("id", ""))
            if dest:
                self.dispatch('hl.dsp.window.move({ workspace = "%s", window = "address:%s" })' % (dest, w["id"]),
                              ["movetoworkspace", "%s,address:%s" % (dest, w["id"])])
        self.dispatch('hl.dsp.focus({ window = "address:%s" })' % w["id"], ["focuswindow", "address:" + w["id"]])

    def minimize(self, w):
        self.dispatch('hl.dsp.window.move({ workspace = "special:minimized", follow = false, window = "address:%s" })' % w["id"],
                      ["movetoworkspacesilent", "special:minimized,address:" + w["id"]])

    def close(self, w):
        self.dispatch('hl.dsp.window.close({ window = "address:%s" })' % w["id"], ["closewindow", "address:" + w["id"]])


hypr = Hypr()


class Apps:
    """Janelas: Hyprland (hyprctl) ou X11 (wmctrl/xdotool). Apps instalados: arquivos .desktop (qualquer sessão)."""

    def __init__(self):
        self.installed = []
        self._entries = None
        self.warned = False

    @property
    def entries(self):
        if self._entries is None:
            self._entries = load_desktop_entries()
        return self._entries

    def _entry_for(self, cls):
        return next((e for e in self.entries if e.matches_class(cls)), None)

    def _windows(self):
        if hypr.available:
            return hypr.windows()
        out = run(["wmctrl", "-lpx"]) if which("wmctrl") else None
        if out is None:
            if not self.warned:
                log("⚠️  modo Apps: precisa de Hyprland (hyprctl) ou X11 com wmctrl")
                self.warned = True
            return []
        wins = []
        for line in out.splitlines():
            f = line.split(None, 5)
            if len(f) < 5 or f[1] == "-1":  # -1: painéis e docks
                continue
            try:
                wins.append({"id": "0x%x" % int(f[0], 16), "pid": int(f[2]), "cls": f[3], "title": f[5] if len(f) > 5 else "",
                             "hidden": False})
            except ValueError:
                pass
        return wins

    def _active(self):
        if hypr.available:
            return hypr.active()
        out = run(["xprop", "-root", "_NET_ACTIVE_WINDOW"]) if which("xprop") else None
        m = re.search(r"0x[0-9a-f]+", out or "")
        return "0x%x" % int(m.group(0), 16) if m else None

    def _by_pid(self):
        apps = {}
        for w in self._windows():
            apps.setdefault(w["pid"], {"cls": w["cls"], "wins": []})["wins"].append(w)
        return apps

    def _wins(self, pid):
        return self._by_pid().get(pid, {"wins": []})["wins"]

    def _name(self, cls):
        e = self._entry_for(cls.split(".")[-1]) or self._entry_for(cls.split(".")[0])
        return e.name if e else cls.split(".")[-1].replace("-", " ").title()

    def list(self):
        """'A pid␟ativo␟oculto␟nome␟chave␟janelas\\t…'"""
        active = self._active()
        rows = []
        for pid, a in self._by_pid().items():
            wins = a["wins"]
            rows.append((self._name(a["cls"]), pid, any(w["id"] == active for w in wins), all(w["hidden"] for w in wins),
                         a["cls"], len(wins)))
        rows.sort(key=lambda r: r[0].casefold())
        return "A " + "\t".join(US.join([str(pid), "1" if act else "0", "1" if hid else "0", clean(name), clean(cls).replace(" ", "_"), str(n)])
                                for name, pid, act, hid, cls, n in rows)

    def icon(self, pid):
        a = self._by_pid().get(pid)
        if not a:
            return None
        cls = a["cls"]
        e = self._entry_for(cls.split(".")[-1]) or self._entry_for(cls.split(".")[0])
        png = icon_png(e.icon if e else cls.split(".")[0].lower())
        return "I %s %s" % (clean(cls).replace(" ", "_"), png) if png else None

    def windows(self, pid):
        return "W %d " % pid + "\t".join("%d%s%s%s%d" % (i, US, clean(w["title"]) or "Sem título", US, 1 if w["hidden"] else 0)
                                         for i, w in enumerate(self._wins(pid)))

    def _raise(self, w):
        if hypr.available:
            hypr.raise_(w)
        else:
            spawn(["wmctrl", "-ia", w["id"]])

    def activate(self, pid):
        wins = self._wins(pid)
        if wins:
            self._raise(next((w for w in wins if not w["hidden"]), wins[0]))

    def focus(self, pid, i, title):
        wins = self._wins(pid)
        if not wins:
            return
        if not (i < len(wins) and clean(wins[i]["title"]) == title):
            i = next((j for j, w in enumerate(wins) if clean(w["title"]) == title), i)
        self._raise(wins[min(i, len(wins) - 1)])

    def hide(self, pid):
        for w in self._wins(pid):
            if hypr.available:
                hypr.minimize(w)
            elif which("xdotool"):
                spawn(["xdotool", "windowminimize", str(int(w["id"], 16))])

    def quit(self, pid):
        for w in self._wins(pid):  # fecha educadamente (o app pode pedir para salvar)
            if hypr.available:
                hypr.close(w)
            else:
                spawn(["wmctrl", "-ic", w["id"]])

    def installed_list(self):
        """'L índice␟nome␟aberto\\t…'"""
        self._entries = load_desktop_entries()
        self.installed = self.entries
        running = {a["cls"] for a in self._by_pid().values()}
        def is_running(e):
            return any(e.matches_class(c.split(".")[-1]) or e.matches_class(c.split(".")[0]) for c in running)
        return "L " + "\t".join("%d%s%s%s%d" % (i, US, clean(e.name), US, 1 if is_running(e) else 0) for i, e in enumerate(self.installed))

    def installed_icon(self, i):
        if 0 <= i < len(self.installed):
            png = icon_png(self.installed[i].icon)
            return "J %d %s" % (i, png) if png else None
        return None

    def launch(self, i):
        if 0 <= i < len(self.installed):
            launch_entry(self.installed[i])


apps = Apps()

# MARK: - Ações customizadas (~/.tracepad-actions)


class Actions:
    file = os.path.join(HOME, ".tracepad-actions")
    sample = """# Ações do TracePad — uma por linha: Nome = comando
# Aparecem no iPhone em Ajustes › Modo › Ações › + › Comando. O comando roda no seu shell.
#
# Bloquear tela = loginctl lock-session
# Suspender = systemctl suspend
# Terminal = gnome-terminal
#
# Gestos padrão (quando o gesto está em "Padrão" no iPhone, e sempre no PWA): @nome = atalho ou comando
# nomes: mission, expose, desktop, space-left, space-right, lookup, zoom-in, zoom-out
# @mission = super+w
# @space-left = super+pageup
# @space-right = super+pagedown
# @desktop = wmctrl -k on
# Hyprland/Omarchy: @mission = hyprctl dispatch 'hl.dsp.workspace.toggle_special("scratchpad")'
"""

    # padrões dos gestos (GNOME; no KDE a visão geral é super+w e as mesas ctrl+f1…; no Hyprland, ver Hypr.gesture)
    gesture_defaults = {
        "mission": "super", "expose": "super", "space-right": "ctrl+alt+right", "space-left": "ctrl+alt+left",
        "desktop": "super+d", "lookup": "", "zoom-in": "ctrl+equal", "zoom-out": "ctrl+minus",
    }

    def ensure_file(self):
        if not os.path.exists(self.file):
            try:
                with open(self.file, "w") as f:
                    f.write(self.sample)
            except OSError:
                pass

    def commands(self):
        """Lido a cada pedido: editar não exige reiniciar."""
        out = []
        try:
            lines = open(self.file, encoding="utf-8").read().splitlines()
        except OSError:
            return out
        for line in lines:
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            name, cmd = (s.strip() for s in line.split("=", 1))
            if name and cmd:
                out.append((clean(name), cmd))
        return out

    def list(self):
        """'C nome\tnome…' (linhas '@gesto' redefinem gestos e não aparecem)"""
        return "C " + "\t".join(n for n, _ in self.commands() if not n.startswith("@"))

    def run(self, name):
        cmd = next((c for n, c in self.commands() if n == name), None)
        if cmd is None or name.startswith("@"):
            return log("✗ ação desconhecida: %s" % name)
        self._shell(cmd, name)

    def _shell(self, cmd, label):
        log("▶ %s" % label)
        spawn([os.environ.get("SHELL") or "/bin/sh", "-lc", cmd], label)

    ALIASES = {"ctrl": "LEFTCTRL", "control": "LEFTCTRL", "alt": "LEFTALT", "shift": "LEFTSHIFT", "super": "LEFTMETA",
               "meta": "LEFTMETA", "win": "LEFTMETA", "cmd": "LEFTMETA", "altgr": "RIGHTALT", "return": "ENTER",
               "escape": "ESC", "del": "DELETE", "pgup": "PAGEUP", "pgdn": "PAGEDOWN", "=": "EQUAL", "-": "MINUS",
               "plus": "EQUAL", "print": "SYSRQ"}

    def combo(self, spec):
        """'ctrl+alt+left' → [teclas evdev]; None se algum pedaço não for tecla (aí é comando de shell)."""
        if E is None or not spec:
            return None
        keys = []
        for part in spec.lower().split("+"):
            name = self.ALIASES.get(part.strip(), part.strip().upper())
            k = getattr(E, "KEY_" + name, None)
            if not isinstance(k, int):
                return None
            keys.append(k)
        return keys

    def gesture(self, name):
        spec = next((c for n, c in self.commands() if n == "@" + name), None)
        if spec is None:
            if hypr.available and hypr.gesture(name):  # Hyprland/Omarchy: mesas e scratchpad pelo hyprctl
                return
            spec = self.gesture_defaults.get(name, "")
        elif self.combo(spec) is None:
            return self._shell(spec, "@" + name)
        inp.combo(self.combo(spec) or [])

    def open(self, target):
        t = target.strip()
        if not t:
            return
        if "://" in t or t.startswith("mailto:") or t.startswith("/") or t.startswith("~"):
            return spawn(["xdg-open", os.path.expanduser(t)], "xdg-open")
        # nome do app como aparece no menu, ou id do .desktop, ou executável
        low = t.casefold()
        e = next((e for e in apps.entries if e.name.casefold() == low or e.id[:-8].casefold() == low), None) \
            or next((e for e in apps.entries if low in e.name.casefold()), None)
        if e:
            return launch_entry(e)
        args = shlex.split(t)
        if args and which(args[0]):
            return spawn(args, t)
        log("✗ não achei o app: %s" % t)


actions = Actions()

# MARK: - Assinatura de dados contínuos (um cliente por vez — o último que pediu)


class Hub:
    def __init__(self):
        self.sub = None
        self.task = None
        self.tick = 0

    def subscribe(self, kind, owner, reply):
        if self.task:
            self.task.cancel()
            self.task = None
        if kind not in ("s", "a"):
            self.sub = None
            return
        self.sub = (kind, owner, reply)
        self.task = asyncio.ensure_future(self._loop())

    def drop(self, owner):
        if self.sub and self.sub[1] == owner:
            self.subscribe("0", owner, None)

    async def _loop(self):
        while self.sub:
            kind, _, reply = self.sub
            self.tick += 1
            if kind == "s":
                for s in (stats.line(), stats.processes()):
                    if s:
                        reply(s)
            elif self.tick % 2 == 1:
                reply(apps.list())  # sem notificações de janela no Linux: consulta a cada 2 s
            await asyncio.sleep(1)


hub = Hub()

# MARK: - Protocolo (texto, 1 comando por mensagem/linha) — igual ao do Mac, ver mac/Input.swift


def handle(msg, owner="", reply=lambda s: None):
    try:
        _handle(msg, owner, reply)
    except Exception as e:  # um comando ruim não derruba a conexão
        log("✗ %r: %s" % (msg[:40], e))


def _handle(msg, owner, reply):
    if not msg:
        return
    op, rest = msg[0], msg[2:]
    if op == "t":
        return inp.type(rest)
    if op == "r":
        return actions.run(rest)
    if op == "O":
        return actions.open(rest)
    if op == "f":  # o título pode ter espaços
        p = msg.split(" ", 3)
        if len(p) >= 3:
            apps.focus(int(p[1]), int(p[2]), p[3] if len(p) > 3 else "")
        return
    a = msg.split()

    def d(i):
        try:
            return float(a[i])
        except (IndexError, ValueError):
            return 0.0

    def s(i):
        return a[i] if i < len(a) else ""

    def r(x):
        if x:
            reply(x)

    if op == "m":
        inp.move(d(1), d(2))
    elif op == "c":
        inp.click(s(1), s(2))
    elif op == "d":
        inp.press()
    elif op == "u":
        inp.release()
    elif op == "s":
        inp.scroll(int(d(3)), int(d(4)))
    elif op == "k":
        inp.key(int(d(1)), s(2))
    elif op == "p":
        reply(msg)
    elif op == "?":
        reply(HELLO)
    elif op == "v":
        system.set_volume(d(1))
    elif op == "b":
        system.set_brightness(d(1))
    elif op == "z":
        system.toggle_mute()
        reply(system.state())
    elif op == "x":
        inp.media(int(d(1)))
    elif op == "q":
        reply(system.state())
    elif op == "w":
        hub.subscribe(s(1)[:1] or "0", owner, reply)
    elif op == "l":
        reply(apps.list())
    elif op == "i":
        r(apps.icon(int(d(1))))
    elif op == "a":
        apps.activate(int(d(1)))
    elif op == "h":
        apps.hide(int(d(1)))
    elif op == "Q":
        apps.quit(int(d(1)))
    elif op == "W":
        reply(apps.windows(int(d(1))))
    elif op == "L":
        reply(apps.installed_list())
    elif op == "j":
        r(apps.installed_icon(int(d(1))))
    elif op == "o":
        apps.launch(int(d(1)))
    elif op == "C":
        reply(actions.list())
    elif op == "g":
        actions.gesture(s(1))


def disconnected(owner):
    inp.release()
    hub.drop(owner)


# MARK: - USB via usbmuxd (mesmo protocolo do Mac: cabeçalho de 16 bytes + plist XML)

MUX_PATH = os.environ.get("USBMUXD_SOCKET_ADDRESS", "/var/run/usbmuxd").replace("UNIX:", "")


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError
        buf += chunk
    return buf


def _mux_open():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(MUX_PATH)
    return s


def _mux_send(s, d):
    d = dict(d, ClientVersionString="TracePad", ProgName="TracePad")
    body = plistlib.dumps(d, fmt=plistlib.FMT_XML)
    s.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, 1) + body)


def _mux_read(s):
    n = struct.unpack("<I", _recv_exact(s, 16)[:4])[0]
    if not 16 <= n < 1 << 20:
        raise ConnectionError
    return plistlib.loads(_recv_exact(s, n - 16))


class USBLink:
    def __init__(self, loop):
        self.loop = loop
        self.attached = set()
        self.lock = threading.Lock()
        self.warned = False

    def start(self):
        threading.Thread(target=self._listen, daemon=True).start()

    def _listen(self):
        while True:
            try:
                s = _mux_open()
                _mux_send(s, {"MessageType": "Listen", "kLibUSBMuxVersion": 3})
                while True:
                    msg = _mux_read(s)
                    did = msg.get("DeviceID", -1)
                    if msg.get("MessageType") == "Attached":
                        if msg.get("Properties", {}).get("ConnectionType") == "USB":
                            self._attach(did)
                    elif msg.get("MessageType") == "Detached":
                        with self.lock:
                            self.attached.discard(did)
            except (OSError, ConnectionError, plistlib.InvalidFileException, struct.error):
                if not self.warned and not os.path.exists(MUX_PATH):
                    log("⚠️  USB: usbmuxd não encontrado (instale usbmuxd; ele sobe sozinho ao plugar o iPhone)")
                    self.warned = True
            threading.Event().wait(2)

    def _attach(self, did):
        with self.lock:
            if did in self.attached:
                return
            self.attached.add(did)
        log("🔌 iPhone no USB (id %d)" % did)
        threading.Thread(target=self._device, args=(did,), daemon=True).start()

    def _device(self, did):
        """Enquanto plugado, tenta abrir o túnel até a porta do app (que pode ainda não estar aberto)."""
        while True:
            with self.lock:
                if did not in self.attached:
                    return
            try:
                s = _mux_open()
                _mux_send(s, {"MessageType": "Connect", "DeviceID": did, "PortNumber": socket.htons(USB_DEVICE_PORT)})
                r = _mux_read(s)
                if r.get("Number") == 0:
                    self._session(s, "usb-%d-%s" % (did, os.urandom(4).hex()))
                elif r.get("Number") == 2 and not getattr(self, "pair_warned", False):
                    log("⚠️  USB: iPhone não pareado com este computador — rode `idevicepair pair` e toque em Confiar")
                    self.pair_warned = True
                s.close()
            except (OSError, ConnectionError, plistlib.InvalidFileException, struct.error):
                pass
            threading.Event().wait(1)

    def _session(self, s, owner):
        log("● USB conectado")
        wlock = threading.Lock()

        def reply(line):
            try:
                with wlock:
                    s.sendall((line + "\n").encode())
            except OSError:
                pass

        reply(HELLO)

        buf = b""
        try:
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                buf += chunk
                *lines, buf = buf.split(b"\n")
                for l in lines:
                    self.loop.call_soon_threadsafe(handle, l.decode("utf-8", "replace"), owner, reply)
        except OSError:
            pass
        done = threading.Event()
        self.loop.call_soon_threadsafe(lambda: (disconnected(owner), done.set()))
        done.wait(2)  # antes de fechar o socket
        log("○ USB desconectado")


# MARK: - Bluetooth LE (bleak + BlueZ): o iPhone é o periférico, este computador assina a característica de comandos


async def ble_loop():
    try:
        from bleak import BleakClient, BleakScanner
    except ImportError:
        log("⚠️  Bluetooth: instale bleak (pip install bleak) para conectar sem cabo")
        return
    last_err = None
    while True:
        wait = 1
        try:
            dev = await BleakScanner.find_device_by_filter(
                lambda d, ad: BLE_SERVICE in [u.lower() for u in (ad.service_uuids or [])], timeout=10)
            if dev is None:
                continue
            gone = asyncio.Event()
            async with BleakClient(dev, disconnected_callback=lambda _c: gone.set()) as client:
                out = asyncio.Queue()
                buf = bytearray()

                def on_data(_ch, data):
                    buf.extend(data)
                    while b"\n" in buf:
                        i = buf.index(b"\n")
                        line = bytes(buf[:i]).decode("utf-8", "replace")
                        del buf[:i + 1]
                        handle(line, "ble", out.put_nowait)

                try:
                    await client.start_notify(BLE_COMMANDS, on_data)
                except Exception:  # a característica exige criptografia: pareia e tenta de novo
                    log("Bluetooth: pareando com %s… (confirme no iPhone)" % (dev.name or "iPhone"))
                    await client.pair()
                    await client.start_notify(BLE_COMMANDS, on_data)
                log("● Bluetooth conectado: %s" % (dev.name or "iPhone"))
                out.put_nowait(HELLO)

                async def writer():
                    while True:
                        data = (await out.get() + "\n").encode()
                        size = max(20, (getattr(client, "mtu_size", 23) or 23) - 3)
                        for i in range(0, len(data), size):
                            await client.write_gatt_char(BLE_REPLIES, data[i:i + size], response=True)

                w = asyncio.ensure_future(writer())
                await gone.wait()
                w.cancel()
            log("○ Bluetooth desconectado")
        except asyncio.CancelledError:
            raise
        except Exception as e:
            if str(e) != last_err:  # BlueZ parado/sem adaptador: avisa uma vez e tenta com calma
                log("Bluetooth: %s (o serviço bluetooth está ativo?)" % e)
                last_err = str(e)
            wait = 10
        finally:
            disconnected("ble")
        await asyncio.sleep(wait)


# MARK: - PWA por Wi-Fi: HTTP estático (:8787) + WebSocket (:8788) autenticado por PIN

MIME = {"html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
        "json": "application/manifest+json", "webmanifest": "application/manifest+json", "png": "image/png", "svg": "image/svg+xml"}


def web_server(web_dir):
    web_dir = os.path.realpath(web_dir)

    async def serve(reader, writer):
        try:
            line = (await reader.readline()).decode("latin-1")
            parts = line.split()
            path = urllib.parse.unquote(parts[1].split("?")[0]) if len(parts) > 1 else "/"
            if path.endswith("/"):
                path += "index.html"
            f = os.path.realpath(os.path.join(web_dir, path.lstrip("/")))
            status, body = "200 OK", None
            if f.startswith(web_dir + os.sep) and os.path.isfile(f):
                body = open(f, "rb").read()
            else:
                status, body = "404 Not Found", b"not found"
            mime = MIME.get(f.rsplit(".", 1)[-1], "application/octet-stream")
            writer.write(("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                          % (status, mime, len(body))).encode() + body)
            await writer.drain()
        except (OSError, asyncio.IncompleteReadError, UnicodeError):
            pass
        finally:
            writer.close()

    return serve


class WSClients:
    count = 0


def _ws_frame(op, data):
    n = len(data)
    head = bytes([0x80 | op])
    if n < 126:
        head += bytes([n])
    elif n < 1 << 16:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    return head + data


async def _ws_read(reader):
    """Uma mensagem completa: (opcode, bytes). Junta fragmentos."""
    op, payload = None, b""
    while True:
        b0, b1 = await reader.readexactly(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", await reader.readexactly(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", await reader.readexactly(8))[0]
        if n > 1 << 20:
            raise ConnectionError
        mask = await reader.readexactly(4) if b1 & 0x80 else None
        data = await reader.readexactly(n)
        if mask:
            data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
        fop = b0 & 0x0F
        if fop >= 8:  # controle pode vir no meio de fragmentos
            return fop, data
        if fop:
            op = fop
        payload += data
        if b0 & 0x80:
            return op, payload


async def ws_client(reader, writer):
    peer = "%s:%s" % (writer.get_extra_info("peername") or ("?", "?"))[:2]
    owner = "ws-" + peer
    authed = False
    try:
        head = await reader.readuntil(b"\r\n\r\n")
        m = re.search(rb"Sec-WebSocket-Key:\s*(\S+)", head, re.I)
        if not m:
            return
        accept = base64.b64encode(hashlib.sha1(m.group(1) + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
                     + accept + b"\r\n\r\n")
        sock = writer.get_extra_info("socket")
        if sock:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        def send(s):
            if not writer.is_closing():
                writer.write(_ws_frame(1, s.encode()))

        while True:
            op, data = await _ws_read(reader)
            if op == 8:
                break
            if op == 9:
                writer.write(_ws_frame(10, data))
                continue
            if op != 1:
                continue
            msg = data.decode("utf-8", "replace")
            if authed:
                handle(msg, owner, send)
            elif msg == "a " + PIN:
                authed = True
                send("ok")
                WSClients.count += 1
                log("● PWA conectado: %s" % peer)
            else:
                log("✗ PIN incorreto: %s" % peer)
                send("bad")
                await writer.drain()
                break
            await writer.drain()
    except (OSError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError, ValueError):
        pass
    finally:
        if authed:
            WSClients.count -= 1
            disconnected(owner)
            log("○ PWA desconectado: %s" % peer)
        writer.close()


def lan_ips():
    out = run(["hostname", "-I"]) or ""
    ips = [i for i in out.split() if re.match(r"^\d+\.\d+\.\d+\.\d+$", i) and not i.startswith(("127.", "172.17."))]
    if not ips:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("10.255.255.255", 1))
            ips = [s.getsockname()[0]]
            s.close()
        except OSError:
            pass
    return ips


# MARK: - main


async def main():
    web_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "web")
    loop = asyncio.get_event_loop()
    actions.ensure_file()
    USBLink(loop).start()
    for port, handler in ((HTTP_PORT, web_server(web_dir)), (WS_PORT, ws_client)):
        try:
            await asyncio.start_server(handler, "0.0.0.0", port)
        except OSError as e:
            log("✗ porta %d indisponível: %s" % (port, e))
    log("TracePad rodando — PIN do PWA: %s" % PIN)
    for ip in lan_ips():
        url = "http://%s:%d/?k=%s" % (ip, HTTP_PORT, PIN)
        log("  PWA: " + url)
        if which("qrencode"):
            log(run(["qrencode", "-t", "ansiutf8", url]) or "")
    log("  Ações de shell: %s" % actions.file)
    await ble_loop()
    await asyncio.Event().wait()  # sem bleak, ble_loop volta na hora


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        inp.release()
