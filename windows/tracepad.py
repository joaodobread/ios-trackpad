#!/usr/bin/env python3
"""TracePad para Windows — recebe gestos do app do iPhone (USB ou Bluetooth) e do PWA (Wi-Fi) e injeta no sistema.

Mesmo protocolo de texto do app do Mac (mac/Input.swift). As teclas chegam com códigos do Mac e são traduzidas
para as teclas virtuais do Windows; ⌘ (c) vira Ctrl (ou Win com TRACEPAD_CMD=win) e ❖ (w) é a tecla Windows.
Os gestos padrão chegam por nome ("g mission") e podem ser redefinidos em ~/.tracepad-actions ("@mission = win+tab").

Sem dependências obrigatórias: mouse, teclado, janelas e área de transferência vão por ctypes (SendInput & cia.).
Opcionais (pip install -r windows/requirements.txt): psutil (modo Monitor), bleak (Bluetooth), pycaw (volume),
wmi (brilho; sem ele cai para o PowerShell), winrt-Windows.Media.Control (tocando agora), Pillow (capa menor).
USB: o Apple Mobile Device Service (vem com o iTunes ou o app Dispositivos Apple) expõe o usbmuxd em 127.0.0.1:27015.

Uso: python windows\\tracepad.py [pasta-do-pwa]      (pythonw para rodar sem janela; o log vai para ~/.tracepad.log)
Fora do Windows sobe só o PWA, sem injetar nada — serve para testar o servidor no CI.
"""

import asyncio
import base64
import ctypes
import datetime
import hashlib
import io
import os
import plistlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
import zlib

IS_WIN = os.name == "nt"
if IS_WIN:
    sys.coinit_flags = 0  # COM em MTA na thread principal: o bleak (WinRT) não funciona em STA, que o comtypes/pythoncom usariam

HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))

# pythonw não tem console: o log vai para um arquivo (o PIN também fica em ~/.tracepad-pin)
if sys.stdout is None:
    try:
        sys.stdout = sys.stderr = open(os.path.join(HOME, ".tracepad.log"), "a", encoding="utf-8", buffering=1)
    except OSError:
        sys.stdout = sys.stderr = open(os.devnull, "w")
try:
    sys.stdout.reconfigure(line_buffering=True, encoding="utf-8", errors="replace")  # console cp1252 não engasga nos emojis
except (AttributeError, ValueError):
    pass

HTTP_PORT = int(os.environ.get("TRACEPAD_HTTP_PORT") or 8787)  # o PWA espera 8787/8788; mudar só para testes
WS_PORT = int(os.environ.get("TRACEPAD_WS_PORT") or 8788)
USB_DEVICE_PORT = 2345
BLE_SERVICE = "6e7a0001-5c3b-4a8e-9f2d-7a1c0de5a001"
BLE_COMMANDS = "6e7a0002-5c3b-4a8e-9f2d-7a1c0de5a001"
BLE_REPLIES = "6e7a0003-5c3b-4a8e-9f2d-7a1c0de5a001"
US = "\x1f"  # separador de campos do protocolo
NO_WINDOW = 0x08000000 if IS_WIN else 0  # CREATE_NO_WINDOW: sem piscar console ao rodar comandos


def log(*a):
    print(*a, flush=True)


def clean(s):
    """Remove separadores do protocolo de nomes vindos do sistema."""
    return s.replace("\t", " ").replace("\n", " ").replace("\r", " ").replace(US, " ")


def which(cmd):
    return shutil.which(cmd) is not None


def run(args, timeout=3):
    """Roda e devolve a saída (str) ou None."""
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, creationflags=NO_WINDOW)
        return r.stdout if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def spawn(args, label=None, **kw):
    """Dispara sem esperar; uma thread recolhe o processo e avisa se falhar."""
    if IS_WIN:
        kw.setdefault("creationflags", NO_WINDOW | 0x00000200)  # CREATE_NEW_PROCESS_GROUP
    else:
        kw.setdefault("start_new_session", True)
    try:
        p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kw)
    except OSError as e:
        log("✗ %s: %s" % (label or args, e))
        return

    def wait():
        if p.wait() != 0 and label:
            log("✗ %s: saiu com %d" % (label, p.returncode))

    threading.Thread(target=wait, daemon=True).start()


def startfile(target, label=None):
    """Abre arquivo, atalho, URL ou app registrado (App Paths) como o Executar do Windows."""
    try:
        if IS_WIN:
            os.startfile(target)
        else:
            spawn(["open" if sys.platform == "darwin" else "xdg-open", target], label or target)
        return True
    except OSError as e:
        log("✗ %s: %s" % (label or target, e))
        return False


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
HELLO = "H windows " + clean(os.environ.get("TRACEPAD_NAME") or socket.gethostname() or "Windows")

# MARK: - Win32 via ctypes (só no Windows; fora dele tudo vira no-op)

c_void_p, c_int, c_uint, c_long = ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_long
c_u16, c_u32, c_i32, c_size_t = ctypes.c_uint16, ctypes.c_uint32, ctypes.c_int32, ctypes.c_size_t
c_wchar_p, c_bool = ctypes.c_wchar_p, ctypes.c_bool
ULONG_PTR = c_size_t


def _fn(dll, name, restype, *argtypes):
    f = getattr(dll, name)
    f.restype, f.argtypes = restype, list(argtypes)
    return f


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", c_i32), ("dy", c_i32), ("mouseData", c_i32), ("dwFlags", c_u32), ("time", c_u32),
                ("dwExtraInfo", ULONG_PTR)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", c_u16), ("wScan", c_u16), ("dwFlags", c_u32), ("time", c_u32), ("dwExtraInfo", ULONG_PTR)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", c_u32), ("wParamL", c_u16), ("wParamH", c_u16)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", c_u32), ("u", _INPUTUNION)]


class ICONINFO(ctypes.Structure):
    _fields_ = [("fIcon", c_int), ("xHotspot", c_u32), ("yHotspot", c_u32), ("hbmMask", c_void_p), ("hbmColor", c_void_p)]


class BITMAP(ctypes.Structure):
    _fields_ = [("bmType", c_i32), ("bmWidth", c_i32), ("bmHeight", c_i32), ("bmWidthBytes", c_i32),
                ("bmPlanes", c_u16), ("bmBitsPixel", c_u16), ("bmBits", c_void_p)]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("biSize", c_u32), ("biWidth", c_i32), ("biHeight", c_i32), ("biPlanes", c_u16), ("biBitCount", c_u16),
                ("biCompression", c_u32), ("biSizeImage", c_u32), ("biXPelsPerMeter", c_i32), ("biYPelsPerMeter", c_i32),
                ("biClrUsed", c_u32), ("biClrImportant", c_u32), ("bmiColors", c_u32 * 4)]


class SHFILEINFOW(ctypes.Structure):
    _fields_ = [("hIcon", c_void_p), ("iIcon", c_int), ("dwAttributes", c_u32), ("szDisplayName", ctypes.c_wchar * 260),
                ("szTypeName", ctypes.c_wchar * 80)]


class W:
    """Funções do Win32 usadas aqui, com tipos declarados (handles são ponteiros de 64 bits)."""
    ok = False


if IS_WIN:
    _u, _k, _g = ctypes.WinDLL("user32", use_last_error=True), ctypes.WinDLL("kernel32"), ctypes.WinDLL("gdi32")
    _s, _ole, _ver = ctypes.WinDLL("shell32"), ctypes.WinDLL("ole32"), ctypes.WinDLL("version")
    WNDENUMPROC = ctypes.WINFUNCTYPE(c_bool, c_void_p, c_void_p)
    W.SendInput = _fn(_u, "SendInput", c_uint, c_uint, ctypes.POINTER(INPUT), c_int)
    W.MapVirtualKeyW = _fn(_u, "MapVirtualKeyW", c_uint, c_uint, c_uint)
    W.EnumWindows = _fn(_u, "EnumWindows", c_bool, WNDENUMPROC, c_void_p)
    W.EnumChildWindows = _fn(_u, "EnumChildWindows", c_bool, c_void_p, WNDENUMPROC, c_void_p)
    W.IsWindowVisible = _fn(_u, "IsWindowVisible", c_bool, c_void_p)
    W.IsIconic = _fn(_u, "IsIconic", c_bool, c_void_p)
    W.GetWindow = _fn(_u, "GetWindow", c_void_p, c_void_p, c_uint)
    W.GetWindowLongW = _fn(_u, "GetWindowLongW", c_long, c_void_p, c_int)
    W.GetWindowTextLengthW = _fn(_u, "GetWindowTextLengthW", c_int, c_void_p)
    W.GetWindowTextW = _fn(_u, "GetWindowTextW", c_int, c_void_p, c_wchar_p, c_int)
    W.GetClassNameW = _fn(_u, "GetClassNameW", c_int, c_void_p, c_wchar_p, c_int)
    W.GetWindowThreadProcessId = _fn(_u, "GetWindowThreadProcessId", c_u32, c_void_p, ctypes.POINTER(c_u32))
    W.GetForegroundWindow = _fn(_u, "GetForegroundWindow", c_void_p)
    W.SetForegroundWindow = _fn(_u, "SetForegroundWindow", c_bool, c_void_p)
    W.BringWindowToTop = _fn(_u, "BringWindowToTop", c_bool, c_void_p)
    W.ShowWindow = _fn(_u, "ShowWindow", c_bool, c_void_p, c_int)
    W.PostMessageW = _fn(_u, "PostMessageW", c_bool, c_void_p, c_uint, c_size_t, c_size_t)
    W.OpenClipboard = _fn(_u, "OpenClipboard", c_bool, c_void_p)
    W.CloseClipboard = _fn(_u, "CloseClipboard", c_bool)
    W.EmptyClipboard = _fn(_u, "EmptyClipboard", c_bool)
    W.GetClipboardData = _fn(_u, "GetClipboardData", c_void_p, c_uint)
    W.SetClipboardData = _fn(_u, "SetClipboardData", c_void_p, c_uint, c_void_p)
    W.GetIconInfo = _fn(_u, "GetIconInfo", c_bool, c_void_p, ctypes.POINTER(ICONINFO))
    W.DestroyIcon = _fn(_u, "DestroyIcon", c_bool, c_void_p)
    W.GetDC = _fn(_u, "GetDC", c_void_p, c_void_p)
    W.ReleaseDC = _fn(_u, "ReleaseDC", c_int, c_void_p, c_void_p)
    W.PrivateExtractIconsW = _fn(_u, "PrivateExtractIconsW", c_uint, c_wchar_p, c_int, c_int, c_int,
                                 ctypes.POINTER(c_void_p), c_void_p, c_uint, c_uint)
    W.GlobalAlloc = _fn(_k, "GlobalAlloc", c_void_p, c_uint, c_size_t)
    W.GlobalLock = _fn(_k, "GlobalLock", c_void_p, c_void_p)
    W.GlobalUnlock = _fn(_k, "GlobalUnlock", c_bool, c_void_p)
    W.GlobalFree = _fn(_k, "GlobalFree", c_void_p, c_void_p)
    W.OpenProcess = _fn(_k, "OpenProcess", c_void_p, c_u32, c_bool, c_u32)
    W.CloseHandle = _fn(_k, "CloseHandle", c_bool, c_void_p)
    W.QueryFullProcessImageNameW = _fn(_k, "QueryFullProcessImageNameW", c_bool, c_void_p, c_u32, c_wchar_p,
                                       ctypes.POINTER(c_u32))
    W.GetObjectW = _fn(_g, "GetObjectW", c_int, c_void_p, c_int, c_void_p)
    W.GetDIBits = _fn(_g, "GetDIBits", c_int, c_void_p, c_void_p, c_uint, c_uint, c_void_p, ctypes.POINTER(BITMAPINFO), c_uint)
    W.DeleteObject = _fn(_g, "DeleteObject", c_bool, c_void_p)
    W.SHGetFileInfoW = _fn(_s, "SHGetFileInfoW", c_size_t, c_wchar_p, c_u32, ctypes.POINTER(SHFILEINFOW), c_uint, c_uint)
    W.SHGetKnownFolderPath = _fn(_s, "SHGetKnownFolderPath", c_long, c_void_p, c_u32, c_void_p, ctypes.POINTER(c_wchar_p))
    W.CoTaskMemFree = _fn(_ole, "CoTaskMemFree", None, c_void_p)
    W.CoInitializeEx = _fn(_ole, "CoInitializeEx", c_long, c_void_p, c_u32)
    W.GetFileVersionInfoSizeW = _fn(_ver, "GetFileVersionInfoSizeW", c_u32, c_wchar_p, c_void_p)
    W.GetFileVersionInfoW = _fn(_ver, "GetFileVersionInfoW", c_bool, c_wchar_p, c_u32, c_u32, c_void_p)
    W.VerQueryValueW = _fn(_ver, "VerQueryValueW", c_bool, c_void_p, c_wchar_p, ctypes.POINTER(c_void_p), ctypes.POINTER(c_uint))
    try:
        W.DwmGetWindowAttribute = _fn(ctypes.WinDLL("dwmapi"), "DwmGetWindowAttribute", c_long, c_void_p, c_u32, c_void_p, c_u32)
    except OSError:
        W.DwmGetWindowAttribute = None
    W.ok = True

_com = threading.local()


def com_init():
    """COM em cada thread que usa pycaw/wmi (MTA, igual à principal)."""
    if IS_WIN and not getattr(_com, "done", False):
        W.CoInitializeEx(None, 0)
        _com.done = True


# MARK: - Injeção de eventos (SendInput)

INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
MOUSEEVENTF_MOVE, MOUSEEVENTF_WHEEL, MOUSEEVENTF_HWHEEL = 0x0001, 0x0800, 0x1000
BUTTON_FLAGS = {"l": (0x0002, 0x0004), "r": (0x0008, 0x0010), "m": (0x0020, 0x0040)}  # (desce, sobe)
KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE = 0x1, 0x2, 0x4

VK_RETURN, VK_TAB, VK_LSHIFT, VK_LCONTROL, VK_LMENU, VK_LWIN = 0x0D, 0x09, 0xA0, 0xA2, 0xA4, 0x5B
VK_VOLUME_MUTE, VK_MEDIA_NEXT, VK_MEDIA_PREV, VK_MEDIA_PLAY_PAUSE = 0xAD, 0xB0, 0xB1, 0xB3

# teclas que no teclado físico têm o prefixo E0 (setas, bloco de navegação, Win, mídia…)
EXTENDED = {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2C, 0x2D, 0x2E, 0x5B, 0x5C, 0x5D, 0x6F, 0x90, 0xA3, 0xA5,
            0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3}

# códigos de tecla do Mac (os que o iPhone manda) → teclas virtuais do Windows, na mesma posição física
MAC_KEYS = {
    0: ord("A"), 1: ord("S"), 2: ord("D"), 3: ord("F"), 4: ord("H"), 5: ord("G"), 6: ord("Z"), 7: ord("X"), 8: ord("C"),
    9: ord("V"), 11: ord("B"), 12: ord("Q"), 13: ord("W"), 14: ord("E"), 15: ord("R"), 16: ord("Y"), 17: ord("T"),
    18: ord("1"), 19: ord("2"), 20: ord("3"), 21: ord("4"), 22: ord("6"), 23: ord("5"), 24: 0xBB, 25: ord("9"), 26: ord("7"),
    27: 0xBD, 28: ord("8"), 29: ord("0"), 30: 0xDD, 31: ord("O"), 32: ord("U"), 33: 0xDB, 34: ord("I"), 35: ord("P"),
    36: VK_RETURN, 37: ord("L"), 38: ord("J"), 39: 0xDE, 40: ord("K"), 41: 0xBA, 42: 0xDC, 43: 0xBC, 44: 0xBF, 45: ord("N"),
    46: ord("M"), 47: 0xBE, 48: VK_TAB, 49: 0x20, 50: 0xC0, 51: 0x08, 53: 0x1B,
    96: 0x74, 97: 0x75, 98: 0x76, 99: 0x72, 100: 0x77, 101: 0x78, 103: 0x7A, 109: 0x79, 111: 0x7B,
    115: 0x24, 116: 0x21, 117: 0x2E, 118: 0x73, 119: 0x23, 120: 0x71, 121: 0x22, 122: 0x70,
    123: 0x25, 124: 0x27, 125: 0x28, 126: 0x26,
}


def _mouse(flags, dx=0, dy=0, data=0):
    i = INPUT(type=INPUT_MOUSE)
    i.mi = MOUSEINPUT(dx, dy, data, flags, 0, 0)
    return i


def _kbd(vk, up=False, unicode_char=None):
    i = INPUT(type=INPUT_KEYBOARD)
    if unicode_char is not None:
        i.ki = KEYBDINPUT(0, unicode_char, KEYEVENTF_UNICODE | (KEYEVENTF_KEYUP if up else 0), 0, 0)
    else:
        flags = (KEYEVENTF_KEYUP if up else 0) | (KEYEVENTF_EXTENDEDKEY if vk in EXTENDED else 0)
        i.ki = KEYBDINPUT(vk, (W.MapVirtualKeyW(vk, 0) & 0xFFFF) if W.ok else 0, flags, 0, 0)
    return i


def _send(events):
    if not events or not W.ok:
        return
    for i in range(0, len(events), 256):
        part = events[i:i + 256]
        arr = (INPUT * len(part))(*part)
        W.SendInput(len(part), arr, ctypes.sizeof(INPUT))


class Input:
    SCROLL_HI = 2.4  # unidades da roda (120 = um "dente") por ponto rolado no iPhone

    def __init__(self):
        self.held = None
        self.rem = [0.0, 0.0]
        self.wheel = [0.0, 0.0]
        self.cmd = VK_LWIN if os.environ.get("TRACEPAD_CMD", "").lower() in ("win", "super") else VK_LCONTROL
        if not W.ok:
            log("⚠️  fora do Windows: sem mouse/teclado (modo de teste, só o servidor do PWA)")

    def move(self, dx, dy):
        self.rem[0] += dx
        self.rem[1] += dy
        ix, iy = int(self.rem[0]), int(self.rem[1])
        if not ix and not iy:
            return
        self.rem[0] -= ix
        self.rem[1] -= iy
        _send([_mouse(MOUSEEVENTF_MOVE, ix, iy)])

    def _mods(self, mods):
        keys = []
        for m in "tascw":  # ⌃ ⌥ ⇧ ⌘ ❖
            if m not in mods:
                continue
            k = {"t": VK_LCONTROL, "a": VK_LMENU, "s": VK_LSHIFT, "w": VK_LWIN, "c": self.cmd}[m]
            if k not in keys:
                keys.append(k)
        return keys

    def click(self, b, mods=""):
        down, up = BUTTON_FLAGS.get(b, BUTTON_FLAGS["l"])
        mk = self._mods(mods)
        _send([_kbd(k) for k in mk] + [_mouse(down), _mouse(up)] + [_kbd(k, True) for k in reversed(mk)])

    def press(self):
        if self.held is None:
            self.held = "l"
            _send([_mouse(BUTTON_FLAGS["l"][0])])

    def release(self):
        if self.held is not None:
            _send([_mouse(BUTTON_FLAGS[self.held][1])])
            self.held = None

    def scroll(self, dx, dy):
        if not dx and not dy:
            return
        # macOS: dy > 0 rola para cima (igual à roda do Windows); dx > 0 rola para a esquerda (HWHEEL > 0 é para a direita)
        ev = []
        for i, (v, flag) in enumerate(((-dx, MOUSEEVENTF_HWHEEL), (dy, MOUSEEVENTF_WHEEL))):
            self.wheel[i] += v * self.SCROLL_HI
            n = int(self.wheel[i])
            if n:
                self.wheel[i] -= n
                ev.append(_mouse(flag, data=n))  # roda de alta resolução: frações de WHEEL_DELTA (120)
        _send(ev)

    def combo(self, keys):
        if keys:
            _send([_kbd(k) for k in keys] + [_kbd(k, True) for k in reversed(keys)])

    def key(self, code, mods=""):
        k = MAC_KEYS.get(code)
        if k is not None:
            self.combo(self._mods(mods) + [k])

    def media(self, key):
        k = {16: VK_MEDIA_PLAY_PAUSE, 17: VK_MEDIA_NEXT, 18: VK_MEDIA_PREV}.get(key)
        if k:
            self.combo([k])

    def type(self, text):
        """KEYEVENTF_UNICODE digita qualquer caractere, independente do layout do teclado."""
        ev = []
        for c in text.replace("\r\n", "\n"):
            if c in "\r\n":
                ev += [_kbd(VK_RETURN), _kbd(VK_RETURN, True)]
            elif c == "\t":
                ev += [_kbd(VK_TAB), _kbd(VK_TAB, True)]
            else:
                b = c.encode("utf-16-le")  # fora do BMP (emoji) vira par de surrogates
                for j in range(0, len(b), 2):
                    u = b[j] | b[j + 1] << 8
                    ev += [_kbd(0, False, u), _kbd(0, True, u)]
        _send(ev)


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
            try:
                self.fn(v)
            except Exception as e:
                log("✗ %s" % e)


PS = ["powershell", "-NoProfile", "-NonInteractive", "-Command"]


class System:
    """Volume pelo pycaw (IAudioEndpointVolume); brilho pelo WMI (só telas internas/DDC suportadas); mídia por teclas VK_MEDIA_*."""

    def __init__(self):
        try:
            from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume
            self._au, self._iev = AudioUtilities, IAudioEndpointVolume
        except Exception:  # ImportError, ou o comtypes fora do Windows
            self._au = None
            if IS_WIN:
                log("⚠️  volume: instale pycaw (pip install pycaw) — sem ele só o mudo funciona")
        try:
            import wmi
            self._wmi = wmi
        except Exception:
            self._wmi = None
        self._vol = Latest(self._apply_volume)
        self._bri = Latest(self._apply_brightness)
        self._bri_val, self._bri_at = -1.0, 0.0
        self._bri_ok = IS_WIN
        self._bri_lock = threading.Lock()
        if IS_WIN:
            threading.Thread(target=self._read_brightness, daemon=True).start()

    def _endpoint(self):
        """Pega o dispositivo padrão a cada uso (fones plugados mudam o padrão)."""
        if not self._au:
            return None
        com_init()
        try:
            dev = self._au.GetSpeakers()
            ev = getattr(dev, "EndpointVolume", None)  # pycaw novo
            if ev is not None:
                return ev
            from comtypes import CLSCTX_ALL
            iface = dev.Activate(self._iev._iid_, CLSCTX_ALL, None)
            return ctypes.cast(iface, ctypes.POINTER(self._iev))
        except Exception:
            return None

    def _apply_volume(self, v):
        ev = self._endpoint()
        if ev:
            ev.SetMasterVolumeLevelScalar(float(v), None)
            if v > 0:
                ev.SetMute(0, None)

    def volume(self):
        ev = self._endpoint()
        try:
            return float(ev.GetMasterVolumeLevelScalar()) if ev else -1
        except Exception:
            return -1

    def muted(self):
        ev = self._endpoint()
        try:
            return bool(ev.GetMute()) if ev else False
        except Exception:
            return False

    def set_volume(self, v):
        self._vol.set(min(max(v, 0), 1))

    def toggle_mute(self):
        ev = self._endpoint()
        if ev:
            try:
                return ev.SetMute(0 if ev.GetMute() else 1, None)
            except Exception:
                pass
        inp.combo([VK_VOLUME_MUTE])
        time.sleep(0.05)

    def _read_brightness(self):
        """Lento (WMI/PowerShell): lido em segundo plano e guardado; monitores externos sem suporte devolvem -1."""
        if not self._bri_lock.acquire(blocking=False):
            return
        try:
            v = -1.0
            if self._wmi:
                try:
                    com_init()
                    m = self._wmi.WMI(namespace="wmi").WmiMonitorBrightness()
                    v = m[0].CurrentBrightness / 100 if m else -1.0
                except Exception:
                    v = -1.0
            else:
                out = run(PS + ["(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop)"
                                "[0].CurrentBrightness"], timeout=8)
                try:
                    v = int(out.strip()) / 100
                except (AttributeError, ValueError):
                    v = -1.0
            self._bri_val, self._bri_at = v, time.monotonic()
            self._bri_ok = v >= 0
        finally:
            self._bri_lock.release()

    def _apply_brightness(self, v):
        n = max(1, round(v * 100))
        if self._wmi:
            com_init()
            m = self._wmi.WMI(namespace="wmi").WmiMonitorBrightnessMethods()
            if m:
                m[0].WmiSetBrightness(Brightness=n, Timeout=0)
        else:
            run(PS + ["Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods | "
                      "Invoke-CimMethod -MethodName WmiSetBrightness -Arguments @{Brightness=%d; Timeout=0} | Out-Null" % n], timeout=8)

    def brightness(self):
        if self._bri_ok and time.monotonic() - self._bri_at > 10:  # o usuário pode ter mudado pelo teclado
            threading.Thread(target=self._read_brightness, daemon=True).start()
        return self._bri_val

    def set_brightness(self, v):
        if self._bri_ok:
            v = min(max(v, 0), 1)
            self._bri_val, self._bri_at = v, time.monotonic()
            self._bri.set(v)

    def state(self):
        """'S volume brilho mudo' — -1 quando não disponível."""
        return "S %.3f %.3f %d" % (self.volume(), self.brightness(), 1 if self.muted() else 0)


system = System()

# MARK: - Monitor (psutil)

try:
    import psutil
except ImportError:
    psutil = None


class GPU:
    """Uso da GPU como no Gerenciador de Tarefas: contadores "GPU Engine" (motor 3D) pelo PDH."""

    def __init__(self):
        self.q = self.c = None
        if not IS_WIN:
            return
        try:
            pdh = ctypes.WinDLL("pdh")
            self.pdh = pdh
            q, c = c_void_p(), c_void_p()
            if pdh.PdhOpenQueryW(None, None, ctypes.byref(q)) != 0:
                return
            if pdh.PdhAddEnglishCounterW(q, c_wchar_p(r"\GPU Engine(*engtype_3D)\Utilization Percentage"), None,
                                         ctypes.byref(c)) != 0:
                return
            pdh.PdhCollectQueryData(q)
            self.q, self.c = q, c
        except (OSError, AttributeError):
            pass

    def usage(self):
        if self.q is None:
            return -1

        class ITEM(ctypes.Structure):
            _fields_ = [("name", c_wchar_p), ("status", c_u32), ("value", ctypes.c_double)]

        PDH_FMT_DOUBLE, PDH_MORE_DATA = 0x200, 0x800007D2
        if self.pdh.PdhCollectQueryData(self.q) != 0:
            return -1
        size, count = c_u32(0), c_u32(0)
        r = self.pdh.PdhGetFormattedCounterArrayW(self.c, PDH_FMT_DOUBLE, ctypes.byref(size), ctypes.byref(count), None)
        if r & 0xFFFFFFFF != PDH_MORE_DATA or not size.value:
            return 0.0 if r == 0 else -1
        buf = ctypes.create_string_buffer(size.value)
        if self.pdh.PdhGetFormattedCounterArrayW(self.c, PDH_FMT_DOUBLE, ctypes.byref(size), ctypes.byref(count), buf) != 0:
            return -1
        items = ctypes.cast(buf, ctypes.POINTER(ITEM))
        return min(sum(items[i].value for i in range(count.value) if items[i].status in (0, 1)) / 100, 1.0)


class Stats:
    def __init__(self):
        self.prev_net = None
        self.warned = False
        self.gpu = GPU()
        if psutil:
            psutil.cpu_percent(None)

    def _gpu(self):
        try:
            v = self.gpu.usage()
        except Exception:
            v = -1
        if v < 0 and which("nvidia-smi"):
            out = run(["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"], timeout=2)
            try:
                return max(int(x) for x in out.split()) / 100
            except (AttributeError, ValueError):
                pass
        return v

    def line(self):
        """'T cpu gpu memUsado memTotal redeEntrada redeSaída discoUsado discoTotal bateria carregando núcleos'"""
        if not psutil:
            if not self.warned:
                log("⚠️  instale psutil (pip install psutil) para o modo Monitor")
                self.warned = True
            return None
        vm = psutil.virtual_memory()
        now = time.monotonic()
        nic = psutil.net_io_counters(pernic=True)
        real = {k: v for k, v in nic.items() if k != "lo" and "loopback" not in k.lower()}
        rx = sum(v.bytes_recv for v in real.values())
        tx = sum(v.bytes_sent for v in real.values())
        rin = rout = 0.0
        if self.prev_net and now > self.prev_net[0]:
            dt = now - self.prev_net[0]
            rin, rout = max(rx - self.prev_net[1], 0) / dt, max(tx - self.prev_net[2], 0) / dt
        self.prev_net = (now, rx, tx)
        du = psutil.disk_usage((os.environ.get("SystemDrive", "C:") + "\\") if IS_WIN else "/")
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
                if p.pid == 0:  # "System Idle Process"
                    continue
                name = re.sub(r"\.exe$", "", p.info["name"] or "?", flags=re.I)
                rows.append((p.cpu_percent(None) / 100, name, p.info["memory_info"].rss if p.info["memory_info"] else 0))
            except (psutil.Error, AttributeError):
                pass
        rows.sort(key=lambda r: -r[0])
        return "P " + "\t".join("%s%s%.3f%s%.0f" % (clean(n), US, c, US, m) for c, n, m in rows[:limit])


stats = Stats()

# MARK: - Apps (janelas por EnumWindows; instalados = atalhos .lnk do Menu Iniciar)


def png_encode(w, h, rgba):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def _bitmap_bgra(hdc, hbm, w, h):
    bmi = BITMAPINFO(biSize=40, biWidth=w, biHeight=-h, biPlanes=1, biBitCount=32, biCompression=0)
    buf = ctypes.create_string_buffer(w * h * 4)
    if W.GetDIBits(hdc, hbm, 0, h, buf, ctypes.byref(bmi), 0) != h:
        return None
    return bytearray(buf.raw)


def hicon_png(hicon):
    """HICON → PNG (base64). Ícones antigos sem alfa usam a máscara."""
    ii = ICONINFO()
    if not hicon or not W.GetIconInfo(hicon, ctypes.byref(ii)):
        return None
    hdc = W.GetDC(None)
    try:
        bm = BITMAP()
        if not ii.hbmColor or not W.GetObjectW(ii.hbmColor, ctypes.sizeof(bm), ctypes.byref(bm)):
            return None
        w, h = bm.bmWidth, bm.bmHeight
        px = _bitmap_bgra(hdc, ii.hbmColor, w, h)
        if px is None:
            return None
        if not any(px[3::4]):
            mask = _bitmap_bgra(hdc, ii.hbmMask, w, h) if ii.hbmMask else None
            px[3::4] = bytes(0 if mask and mask[i * 4] else 255 for i in range(w * h))
        px[0::4], px[2::4] = px[2::4], px[0::4]  # BGRA → RGBA
        return base64.b64encode(png_encode(w, h, bytes(px))).decode()
    finally:
        W.ReleaseDC(None, hdc)
        for hb in (ii.hbmColor, ii.hbmMask):
            if hb:
                W.DeleteObject(hb)
        W.DestroyIcon(hicon)


def icon_png(path, size=64):
    """Ícone de um .exe (64 px) ou de qualquer arquivo/atalho pelo shell (32 px); base64 ou None."""
    if not W.ok or not path:
        return None
    try:
        if path.lower().endswith((".exe", ".ico", ".dll")):
            h = c_void_p()
            if W.PrivateExtractIconsW(path, 0, size, size, ctypes.byref(h), None, 1, 0) == 1 and h.value:
                return hicon_png(h.value)
        sfi = SHFILEINFOW()
        if W.SHGetFileInfoW(path, 0, ctypes.byref(sfi), ctypes.sizeof(sfi), 0x100) and sfi.hIcon:  # SHGFI_ICON (grande)
            return hicon_png(sfi.hIcon)
    except (OSError, ValueError):
        pass
    return None


_desc_cache = {}


def exe_description(path):
    """'Descrição do arquivo' do .exe (ex.: Google Chrome) — o nome que o Gerenciador de Tarefas mostra."""
    if path in _desc_cache:
        return _desc_cache[path]
    desc = None
    if W.ok and path:
        try:
            n = W.GetFileVersionInfoSizeW(path, None)
            if n:
                buf = ctypes.create_string_buffer(n)
                if W.GetFileVersionInfoW(path, 0, n, buf):
                    p, ln = c_void_p(), c_uint()
                    langs = ["040904b0", "040904e4", "041604b0"]
                    if W.VerQueryValueW(buf, "\\VarFileInfo\\Translation", ctypes.byref(p), ctypes.byref(ln)) and ln.value >= 4:
                        lang, cp = struct.unpack("<HH", ctypes.string_at(p.value, 4))
                        langs.insert(0, "%04x%04x" % (lang, cp))
                    for l in langs:
                        if W.VerQueryValueW(buf, "\\StringFileInfo\\%s\\FileDescription" % l, ctypes.byref(p), ctypes.byref(ln)) \
                                and ln.value > 1:
                            desc = ctypes.wstring_at(p.value).strip() or None
                            break
        except (OSError, ValueError):
            pass
    _desc_cache[path] = desc
    return desc


def exe_path(pid):
    if not W.ok:
        return ""
    h = W.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return ""
    try:
        buf, n = ctypes.create_unicode_buffer(1024), c_u32(1024)
        return buf.value if W.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)) else ""
    finally:
        W.CloseHandle(h)


def lnk_target(path):
    """Caminho local (LocalBasePath) de um atalho .lnk, lido direto do formato MS-SHLLINK; None se não tiver."""
    try:
        with open(path, "rb") as f:
            d = f.read(1 << 16)
        if len(d) < 0x4C or d[:4] != b"\x4c\x00\x00\x00":
            return None
        flags = struct.unpack_from("<I", d, 0x14)[0]
        off = 0x4C
        if flags & 1:  # HasLinkTargetIDList
            off += 2 + struct.unpack_from("<H", d, off)[0]
        if not flags & 2:  # HasLinkInfo
            return None
        size, hsize, liflags = struct.unpack_from("<III", d, off)
        if not liflags & 1:  # VolumeIDAndLocalBasePath
            return None
        if hsize >= 0x24:
            u = off + struct.unpack_from("<I", d, off + 0x1C)[0]
            end = u
            while end + 1 < off + size and d[end:end + 2] != b"\x00\x00":
                end += 2
            s = d[u:end].decode("utf-16-le", "replace")
        else:
            a = off + struct.unpack_from("<I", d, off + 0x10)[0]
            s = d[a:off + size].split(b"\x00", 1)[0].decode("mbcs" if IS_WIN else "latin-1", "replace")
        return s or None
    except (OSError, struct.error, LookupError):
        return None


class Shortcut:
    def __init__(self, path):
        self.path = path
        self.name = os.path.splitext(os.path.basename(path))[0]
        self._target = False

    @property
    def target(self):
        if self._target is False:
            self._target = lnk_target(self.path)
        return self._target


def start_menu_dirs():
    out = []
    for env in ("APPDATA", "ProgramData"):
        base = os.environ.get(env)
        if base:
            out.append(os.path.join(base, "Microsoft", "Windows", "Start Menu", "Programs"))
    return out


SKIP_SHORTCUT = re.compile(r"uninstall|desinstal|readme|leia-me|release notes|website|^help$|^ajuda$", re.I)


def load_shortcuts():
    seen, out = set(), []
    for d in start_menu_dirs():
        for root, _dirs, names in os.walk(d):
            for n in names:
                if not n.lower().endswith(".lnk"):
                    continue
                s = Shortcut(os.path.join(root, n))
                key = s.name.casefold()
                if key in seen or SKIP_SHORTCUT.search(s.name):
                    continue
                seen.add(key)
                out.append(s)
    out.sort(key=lambda s: s.name.casefold())
    return out


GWL_EXSTYLE, WS_EX_TOOLWINDOW, WS_EX_APPWINDOW, GW_OWNER = -20, 0x80, 0x40000, 4
SHELL_CLASSES = {"Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow"}


def _text(fn, hwnd, n=256):
    buf = ctypes.create_unicode_buffer(n)
    fn(hwnd, buf, n)
    return buf.value


def _pid(hwnd):
    pid = c_u32()
    W.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return pid.value


def _cloaked(hwnd):
    """Janelas "cloaked" (apps UWP suspensos, outras áreas de trabalho virtuais) não aparecem na barra de tarefas."""
    if not W.DwmGetWindowAttribute:
        return False
    v = c_u32()
    return W.DwmGetWindowAttribute(hwnd, 14, ctypes.byref(v), 4) == 0 and v.value != 0  # DWMWA_CLOAKED


def _frame_child_pid(hwnd, host):
    """App UWP: a janela é do ApplicationFrameHost; o processo de verdade é o de uma janela filha."""
    found = []

    def cb(h, _):
        p = _pid(h)
        if p != host:
            found.append(p)
            return False
        return True

    W.EnumChildWindows(hwnd, WNDENUMPROC(cb), None)
    return found[0] if found else host


def top_windows():
    """[{id, pid, exe, title, hidden}] — as janelas que aparecem na barra de tarefas / Alt+Tab."""
    if not W.ok:
        return []
    hwnds = []

    def cb(h, _):
        hwnds.append(h)
        return True

    W.EnumWindows(WNDENUMPROC(cb), None)
    out = []
    for h in hwnds:
        if not W.IsWindowVisible(h) or not W.GetWindowTextLengthW(h):
            continue
        ex = W.GetWindowLongW(h, GWL_EXSTYLE)
        if ex & WS_EX_TOOLWINDOW and not ex & WS_EX_APPWINDOW:
            continue
        if W.GetWindow(h, GW_OWNER) and not ex & WS_EX_APPWINDOW:
            continue
        if _text(W.GetClassNameW, h) in SHELL_CLASSES or _cloaked(h):
            continue
        pid = _pid(h)
        exe = exe_path(pid)
        if os.path.basename(exe).lower() == "applicationframehost.exe":
            pid = _frame_child_pid(h, pid)
            exe = exe_path(pid) or exe
        out.append({"id": h, "pid": pid, "exe": exe, "title": _text(W.GetWindowTextW, h, 512), "hidden": bool(W.IsIconic(h))})
    return out


def app_name(exe):
    return exe_description(exe) or os.path.splitext(os.path.basename(exe))[0].replace("-", " ").title() or "?"


def app_key(exe):
    return clean(os.path.splitext(os.path.basename(exe))[0].lower() or "app").replace(" ", "_")


def raise_window(hwnd):
    if W.IsIconic(hwnd):
        W.ShowWindow(hwnd, 9)  # SW_RESTORE
    # o Windows só deixa trocar o foco quem recebeu a última entrada: um Alt "de mentira" libera
    _send([_kbd(VK_LMENU), _kbd(VK_LMENU, True)])
    W.SetForegroundWindow(hwnd)
    W.BringWindowToTop(hwnd)


class Apps:
    """Janelas: EnumWindows (agrupadas por processo). Apps instalados: atalhos .lnk do Menu Iniciar."""

    def __init__(self):
        self.installed = []
        self._shortcuts = None

    @property
    def shortcuts(self):
        if self._shortcuts is None:
            self._shortcuts = load_shortcuts()
        return self._shortcuts

    def _by_pid(self):
        apps = {}
        for w in top_windows():
            apps.setdefault(w["pid"], {"exe": w["exe"], "wins": []})["wins"].append(w)
        return apps

    def _wins(self, pid):
        return self._by_pid().get(pid, {"wins": []})["wins"]

    def list(self):
        """'A pid␟ativo␟oculto␟nome␟chave␟janelas\\t…'"""
        active = W.GetForegroundWindow() if W.ok else None
        rows = []
        for pid, a in self._by_pid().items():
            wins = a["wins"]
            rows.append((app_name(a["exe"]), pid, any(w["id"] == active for w in wins), all(w["hidden"] for w in wins),
                         app_key(a["exe"]), len(wins)))
        rows.sort(key=lambda r: r[0].casefold())
        return "A " + "\t".join(US.join([str(pid), "1" if act else "0", "1" if hid else "0", clean(name), key, str(n)])
                                for name, pid, act, hid, key, n in rows)

    def icon(self, pid):
        a = self._by_pid().get(pid)
        if not a:
            return None
        png = icon_png(a["exe"])
        return "I %s %s" % (app_key(a["exe"]), png) if png else None

    def windows(self, pid):
        return "W %d " % pid + "\t".join("%d%s%s%s%d" % (i, US, clean(w["title"]) or "Sem título", US, 1 if w["hidden"] else 0)
                                         for i, w in enumerate(self._wins(pid)))

    def activate(self, pid):
        wins = self._wins(pid)
        if wins:
            raise_window(next((w for w in wins if not w["hidden"]), wins[0])["id"])

    def focus(self, pid, i, title):
        wins = self._wins(pid)
        if not wins:
            return
        if not (i < len(wins) and clean(wins[i]["title"]) == title):
            i = next((j for j, w in enumerate(wins) if clean(w["title"]) == title), i)
        raise_window(wins[min(i, len(wins) - 1)]["id"])

    def hide(self, pid):
        for w in self._wins(pid):
            W.ShowWindow(w["id"], 6)  # SW_MINIMIZE

    def quit(self, pid):
        for w in self._wins(pid):  # fecha educadamente (o app pode pedir para salvar)
            W.PostMessageW(w["id"], 0x0010, 0, 0)  # WM_CLOSE

    def installed_list(self):
        """'L índice␟nome␟aberto\\t…'"""
        self._shortcuts = load_shortcuts()
        self.installed = self.shortcuts
        running = {a["exe"].lower() for a in self._by_pid().values()}
        names = {app_name(e).casefold() for e in running}

        def is_running(s):
            t = (s.target or "").lower()
            return (t and t in running) or s.name.casefold() in names
        return "L " + "\t".join("%d%s%s%s%d" % (i, US, clean(s.name), US, 1 if is_running(s) else 0)
                                for i, s in enumerate(self.installed))

    def installed_icon(self, i):
        if 0 <= i < len(self.installed):
            s = self.installed[i]
            t = s.target
            png = icon_png(t if t and os.path.exists(t) else s.path)
            return "J %d %s" % (i, png) if png else None
        return None

    def launch(self, i):
        if 0 <= i < len(self.installed):
            startfile(self.installed[i].path, self.installed[i].name)


apps = Apps()

# MARK: - Ações customizadas (~/.tracepad-actions)


def _vk_names():
    k = {"ctrl": VK_LCONTROL, "control": VK_LCONTROL, "alt": VK_LMENU, "shift": VK_LSHIFT, "win": VK_LWIN, "super": VK_LWIN,
         "meta": VK_LWIN, "cmd": VK_LWIN, "altgr": 0xA5, "rctrl": 0xA3, "rshift": 0xA1, "rwin": 0x5C,
         "enter": VK_RETURN, "return": VK_RETURN, "tab": VK_TAB, "space": 0x20, "backspace": 0x08, "esc": 0x1B, "escape": 0x1B,
         "delete": 0x2E, "del": 0x2E, "insert": 0x2D, "ins": 0x2D, "home": 0x24, "end": 0x23, "pageup": 0x21, "pgup": 0x21,
         "pagedown": 0x22, "pgdn": 0x22, "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28, "print": 0x2C,
         "printscreen": 0x2C, "sysrq": 0x2C, "pause": 0x13, "capslock": 0x14, "menu": 0x5D, "apps": 0x5D,
         "equal": 0xBB, "=": 0xBB, "plus": 0xBB, "minus": 0xBD, "-": 0xBD, "comma": 0xBC, ",": 0xBC, "dot": 0xBE,
         "period": 0xBE, ".": 0xBE, "slash": 0xBF, "/": 0xBF, "backslash": 0xDC, "\\": 0xDC, "semicolon": 0xBA, ";": 0xBA,
         "apostrophe": 0xDE, "'": 0xDE, "grave": 0xC0, "`": 0xC0, "leftbrace": 0xDB, "[": 0xDB, "rightbrace": 0xDD, "]": 0xDD,
         "volumeup": 0xAF, "volumedown": 0xAE, "mute": VK_VOLUME_MUTE, "playpause": VK_MEDIA_PLAY_PAUSE,
         "next": VK_MEDIA_NEXT, "nextsong": VK_MEDIA_NEXT, "prev": VK_MEDIA_PREV, "previoussong": VK_MEDIA_PREV}
    for c in "abcdefghijklmnopqrstuvwxyz0123456789":
        k[c] = ord(c.upper())
    for i in range(1, 25):
        k["f%d" % i] = 0x6F + i
    return k


VK_NAMES = _vk_names()


class Actions:
    file = os.path.join(HOME, ".tracepad-actions")
    sample = """# Ações do TracePad — uma por linha: Nome = comando
# Aparecem no iPhone em Ajustes › Modo › Ações › + › Comando. O comando roda no cmd (ou no PowerShell com
# TRACEPAD_SHELL=powershell).
#
# Bloquear tela = rundll32.exe user32.dll,LockWorkStation
# Suspender = rundll32.exe powrprof.dll,SetSuspendState 0,1,0
# Gerenciador de tarefas = start taskmgr
# Bloco de notas = start notepad
#
# Gestos padrão (quando o gesto está em "Padrão" no iPhone, e sempre no PWA): @nome = atalho ou comando
# nomes: mission, expose, desktop, space-left, space-right, lookup, zoom-in, zoom-out
# @mission = win+tab
# @desktop = win+d
# @space-left = ctrl+win+left
# @space-right = ctrl+win+right
# @lookup = win+s
"""

    # padrões dos gestos no Windows (visão de tarefas, área de trabalho, áreas de trabalho virtuais, zoom)
    gesture_defaults = {
        "mission": "win+tab", "expose": "win+tab", "space-right": "ctrl+win+right", "space-left": "ctrl+win+left",
        "desktop": "win+d", "lookup": "", "zoom-in": "ctrl+equal", "zoom-out": "ctrl+minus",
    }

    def ensure_file(self):
        if not os.path.exists(self.file):
            try:
                with open(self.file, "w", encoding="utf-8") as f:
                    f.write(self.sample)
            except OSError:
                pass

    def commands(self):
        """Lido a cada pedido: editar não exige reiniciar."""
        out = []
        try:
            lines = open(self.file, encoding="utf-8-sig").read().splitlines()  # o Bloco de Notas às vezes grava BOM
        except (OSError, UnicodeError):
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
        if not IS_WIN:
            return spawn(["/bin/sh", "-c", cmd], label)
        if os.environ.get("TRACEPAD_SHELL", "").lower() in ("powershell", "pwsh"):
            return spawn(["powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", cmd], label)
        spawn("cmd /d /c " + cmd, label)  # string: o cmd recebe a linha como foi escrita (aspas, &&, start…)

    def combo(self, spec):
        """'ctrl+win+left' → [teclas virtuais]; None se algum pedaço não for tecla (aí é comando de shell)."""
        if not spec:
            return None
        keys = []
        for part in spec.lower().split("+"):
            k = VK_NAMES.get(part.strip())
            if k is None:
                return None
            keys.append(k)
        return keys

    def gesture(self, name):
        spec = next((c for n, c in self.commands() if n == "@" + name), None)
        if spec is None:
            spec = self.gesture_defaults.get(name, "")
        elif self.combo(spec) is None:
            return self._shell(spec, "@" + name)
        inp.combo(self.combo(spec) or [])

    def open(self, target):
        t = target.strip()
        if not t:
            return
        if "://" in t or t.startswith("mailto:") or re.match(r"^[a-zA-Z]:[\\/]|^\\\\|^~", t):
            return startfile(os.path.expanduser(t))
        # nome do app como aparece no Menu Iniciar, ou o que o Executar (Win+R) entende: notepad, chrome, calc…
        low = t.casefold()
        s = next((s for s in apps.shortcuts if s.name.casefold() == low), None) \
            or next((s for s in apps.shortcuts if low in s.name.casefold()), None)
        if s:
            return startfile(s.path, s.name)
        if not startfile(t):
            log("✗ não achei o app: %s" % t)


actions = Actions()

# MARK: - Tocando agora (GlobalSystemMediaTransportControls), área de transferência, arquivos e Wake-on-LAN

MediaManager = DataReader = InputStreamOptions = None
if IS_WIN:
    for _ns in ("winrt", "winsdk"):  # pywinrt modular (winrt-Windows.Media.Control) ou o pacote antigo winsdk
        try:
            _mc = __import__(_ns + ".windows.media.control", fromlist=["x"])
            _st = __import__(_ns + ".windows.storage.streams", fromlist=["x"])
            MediaManager = _mc.GlobalSystemMediaTransportControlsSessionManager
            DataReader, InputStreamOptions = _st.DataReader, _st.InputStreamOptions
            break
        except Exception:
            continue

try:
    from PIL import Image
except ImportError:
    Image = None


def _seconds(v):
    """TimeSpan do WinRT: timedelta nas versões novas, ticks de 100 ns nas antigas."""
    if v is None:
        return -1.0
    if isinstance(v, datetime.timedelta):
        return v.total_seconds()
    try:
        return float(getattr(v, "duration", v)) / 1e7
    except (TypeError, ValueError):
        return -1.0


def _pretty_app(aumid):
    """'Spotify.exe' → Spotify; 'Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic' → ZuneMusic."""
    a = (aumid or "").split("!")[-1]
    a = re.sub(r"\.exe$", "", a, flags=re.I)
    a = a.split("_")[0].split(".")[-1] if "." in a or "_" in a else a
    return a[:1].upper() + a[1:]


class NowPlaying:
    def __init__(self):
        self.mgr = None
        self.warned = False
        self.reset()

    def reset(self):
        self.last_line = ""
        self.last_art = None

    async def _session(self):
        if MediaManager is None:
            if IS_WIN and not self.warned:
                log("⚠️  Tocando agora: instale winrt-Windows.Media.Control (pip install -r windows/requirements.txt)")
                self.warned = True
            return None
        if self.mgr is None:
            self.mgr = await MediaManager.request_async()
        return self.mgr.get_current_session()

    async def read(self):
        """(linha "N …", chave da faixa, propriedades para a capa)."""
        try:
            s = await self._session()
            if s is None:
                return "N stopped", "", None
            st = int(s.get_playback_info().playback_status)  # 0 fechado 1 aberto 2 mudando 3 parado 4 tocando 5 pausado
            if st in (0, 3):
                return "N stopped", "", None
            props = await s.try_get_media_properties_async()
            title = props.title or ""
            if not title:
                return "N stopped", "", None
            tl = s.get_timeline_properties()
            dur = _seconds(tl.end_time) - max(_seconds(tl.start_time), 0)
            pos = _seconds(tl.position)
            lu = getattr(tl, "last_updated_time", None)
            if st == 4 and pos >= 0 and isinstance(lu, datetime.datetime) and lu.year > 2000:
                now = datetime.datetime.now(lu.tzinfo or datetime.timezone.utc)
                pos += max((now - lu).total_seconds(), 0)
            if dur <= 0:
                dur = -1.0
            elif pos > dur:
                pos = dur
            state = "playing" if st == 4 else "paused"
            artist, album = props.artist or "", props.album_title or ""
            line = "N %s\t%.1f\t%.0f\t%s\t%s\t%s\t%s" % (state, dur, pos, clean(title), clean(artist), clean(album),
                                                        clean(_pretty_app(s.source_app_user_model_id)))
            return line, US.join([title, artist, album]), props
        except Exception as e:
            if not self.warned:
                log("Tocando agora: %s" % e)
                self.warned = True
            self.mgr = None
            return "N stopped", "", None

    async def artwork(self, props):
        """Capa da faixa (base64), reduzida para 240 px se o Pillow estiver instalado."""
        try:
            thumb = props.thumbnail if props else None
            if thumb is None:
                return ""
            stream = await thumb.open_read_async()
            n = int(stream.size)
            if not 0 < n < 4000000:
                return ""
            reader = DataReader(stream.get_input_stream_at(0))
            await reader.load_async(n)
            try:
                data = bytes(reader.read_buffer(n))
            except Exception:  # versões antigas: read_bytes preenche uma lista
                arr = bytearray(n)
                reader.read_bytes(arr)
                data = bytes(arr)
        except Exception:
            return ""
        if Image is not None:
            try:
                img = Image.open(io.BytesIO(data)).convert("RGB")
                img.thumbnail((240, 240))
                out = io.BytesIO()
                img.save(out, "JPEG", quality=75)
                data = out.getvalue()
            except Exception:
                pass
        return base64.b64encode(data).decode() if data and len(data) < 300000 else ""

    async def push(self, reply):
        line, key, props = await self.read()
        if line != self.last_line:
            self.last_line = line
            reply(line)
        if key != self.last_art:
            self.last_art = key
            reply("M " + ((await self.artwork(props)) if key else ""))


now_playing = NowPlaying()

CF_UNICODETEXT, GMEM_MOVEABLE = 13, 0x0002


class Clipboard:
    @staticmethod
    def _open():
        for _ in range(10):  # outro app pode estar com ela aberta por um instante
            if W.OpenClipboard(None):
                return True
            time.sleep(0.02)
        return False

    @staticmethod
    def text():
        if not W.ok or not Clipboard._open():
            return ""
        try:
            h = W.GetClipboardData(CF_UNICODETEXT)
            p = W.GlobalLock(h) if h else None
            if not p:
                return ""
            try:
                return ctypes.wstring_at(p).replace("\r\n", "\n")
            finally:
                W.GlobalUnlock(h)
        finally:
            W.CloseClipboard()

    @staticmethod
    def get():
        return "Y " + base64.b64encode(Clipboard.text().encode()).decode()

    @staticmethod
    def set(b64):
        try:
            text = base64.b64decode(b64).decode("utf-8", "replace")
        except ValueError:
            return
        if not W.ok:
            return log("⚠️  área de transferência: só no Windows")
        data = text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-16-le") + b"\x00\x00"
        if not Clipboard._open():
            return log("✗ área de transferência ocupada por outro app")
        try:
            W.EmptyClipboard()
            h = W.GlobalAlloc(GMEM_MOVEABLE, len(data))
            p = W.GlobalLock(h) if h else None
            if not p:
                return
            ctypes.memmove(p, data, len(data))
            W.GlobalUnlock(h)
            if not W.SetClipboardData(CF_UNICODETEXT, h):  # deu certo: o sistema passa a ser dono da memória
                W.GlobalFree(h)
                return log("✗ área de transferência: %d" % ctypes.get_last_error())
            log("📋 área de transferência recebida do iPhone")
        finally:
            W.CloseClipboard()


def downloads_dir():
    d = None
    if W.ok:  # FOLDERID_Downloads (o usuário pode ter movido a pasta)
        guid = ctypes.create_string_buffer(uuid.UUID("374DE290-123F-4565-9164-39C4925E467B").bytes_le, 16)
        p = c_wchar_p()
        if W.SHGetKnownFolderPath(ctypes.byref(guid), 0, None, ctypes.byref(p)) == 0:
            d = p.value
            W.CoTaskMemFree(p)
    d = d or os.path.join(HOME, "Downloads")
    os.makedirs(d, exist_ok=True)
    return d


RESERVED = re.compile(r"^(con|prn|aux|nul|com\d|lpt\d)(\..*)?$", re.I)


def safe_name(name):
    n = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", os.path.basename(name.replace("\\", "/"))).strip().rstrip(". ")
    if RESERVED.match(n):
        n = "_" + n
    return n if n and not n.startswith(".") else "arquivo" + n


def unique_path(d, name):
    base, ext = os.path.splitext(name)
    path, i = os.path.join(d, name), 1
    while os.path.exists(path):
        path = os.path.join(d, "%s (%d)%s" % (base, i, ext))
        i += 1
    return path


class Files:
    """"F nome", "D base64"…, "E" → "E ok caminho" | "E erro mensagem" (um arquivo por conexão)."""

    def __init__(self):
        self.open = {}

    def begin(self, name, owner):
        self.cancel(owner)
        try:
            path = unique_path(downloads_dir(), safe_name(name))
            self.open[owner] = [open(path, "wb"), path, None]
        except OSError as e:
            self.open[owner] = [None, "", str(e)]
            log("✗ arquivo: %s" % e)

    def data(self, b64, owner):
        f = self.open.get(owner)
        if f and f[0] and not f[2]:
            try:
                f[0].write(base64.b64decode(b64))
            except (ValueError, OSError) as e:
                f[2] = str(e)

    def end(self, owner, reply):
        f = self.open.pop(owner, None)
        if not f:
            return reply("E erro transferência não iniciada")
        if f[0]:
            f[0].close()
        if f[2]:
            self._remove(f[1])
            return reply("E erro " + clean(f[2]))
        log("📥 arquivo recebido: %s" % f[1])
        reply("E ok " + f[1])

    @staticmethod
    def _remove(path):
        try:
            if path:
                os.remove(path)
        except OSError:
            pass

    def cancel(self, owner):
        """Conexão caiu no meio: apaga o arquivo pela metade."""
        f = self.open.pop(owner, None)
        if f:
            if f[0]:
                f[0].close()
            self._remove(f[1])


files = Files()


def primary_ip():
    """IPv4 da interface da rota padrão (nada é enviado: o UDP só escolhe a rota)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip if not ip.startswith("127.") else None
    except OSError:
        return None


class WakeOnLAN:
    @staticmethod
    def line():
        """MAC e broadcast da interface da rota padrão: "K mac broadcast"."""
        ip = primary_ip()
        if not ip or not psutil:
            return None
        for _name, addrs in psutil.net_if_addrs().items():
            v4 = next((a for a in addrs if a.family == socket.AF_INET and a.address == ip), None)
            if not v4:
                continue
            mac = next((a.address for a in addrs if a.family == psutil.AF_LINK), None)
            h = re.sub(r"[^0-9a-fA-F]", "", mac or "")
            if len(h) != 12:
                return None
            bcast = v4.broadcast
            if not bcast and v4.netmask:  # o psutil não dá o broadcast no Windows: calcula pela máscara
                ipn = struct.unpack(">I", socket.inet_aton(ip))[0]
                mask = struct.unpack(">I", socket.inet_aton(v4.netmask))[0]
                bcast = socket.inet_ntoa(struct.pack(">I", ipn | (~mask & 0xFFFFFFFF)))
            return "K %s %s" % (":".join(h[i:i + 2] for i in range(0, 12, 2)).lower(), bcast or "255.255.255.255")
        return None

    @staticmethod
    def wake(mac, bcast=""):
        h = re.sub(r"[^0-9a-fA-F]", "", mac)
        if len(h) != 12:
            return
        packet = b"\xff" * 6 + bytes.fromhex(h) * 16
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for target in {bcast or "255.255.255.255", "255.255.255.255"}:
            try:
                s.sendto(packet, (target, 9))
            except OSError as e:
                log("✗ Wake-on-LAN: %s" % e)
        s.close()
        log("⏰ Wake-on-LAN para %s" % mac)


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
        now_playing.reset()
        if kind not in ("s", "a", "n"):
            self.sub = None
            return
        self.sub = (kind, owner, reply)
        self.task = asyncio.ensure_future(self._loop())

    def drop(self, owner):
        files.cancel(owner)
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
            elif kind == "n":
                await now_playing.push(reply)
            elif self.tick % 2 == 1:
                reply(apps.list())  # sem notificações de janela aqui: consulta a cada 2 s
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
    if op == "F":
        return files.begin(rest, owner)
    if op == "D":
        return files.data(rest, owner)
    if op == "E":
        return files.end(owner, reply)
    if op == "Y":
        return Clipboard.set(rest)
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
    elif op == "y":
        reply(Clipboard.get())
    elif op == "K":
        r(WakeOnLAN.line())
    elif op == "R":
        WakeOnLAN.wake(s(1), s(2))


def disconnected(owner):
    inp.release()
    hub.drop(owner)


# MARK: - USB via usbmuxd (Apple Mobile Device Service em 127.0.0.1:27015; mesmo protocolo: cabeçalho de 16 bytes + plist XML)

MUX_ADDR = os.environ.get("USBMUXD_SOCKET_ADDRESS", "127.0.0.1:27015")


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError
        buf += chunk
    return buf


def _mux_open():
    host, _, port = MUX_ADDR.replace("TCP:", "").rpartition(":")
    s = socket.create_connection((host or "127.0.0.1", int(port)), timeout=5)
    s.settimeout(None)
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
        self.pair_warned = False

    def start(self):
        threading.Thread(target=self._listen, daemon=True).start()

    def _listen(self):
        while True:
            try:
                s = _mux_open()
                self.warned = False
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
            except (OSError, ConnectionError, ValueError, plistlib.InvalidFileException, struct.error) as e:
                if not self.warned and isinstance(e, ConnectionRefusedError):
                    log("⚠️  USB: Apple Mobile Device Service não encontrado (instale o app Dispositivos Apple ou o iTunes)")
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
                elif r.get("Number") == 2 and not self.pair_warned:
                    log("⚠️  USB: iPhone não confia neste computador — abra o app Dispositivos Apple/iTunes com ele plugado "
                        "e toque em Confiar no iPhone")
                    self.pair_warned = True
                s.close()
            except (OSError, ConnectionError, ValueError, plistlib.InvalidFileException, struct.error):
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
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
                *lines, buf = buf.split(b"\n")
                for l in lines:
                    self.loop.call_soon_threadsafe(handle, l.decode("utf-8", "replace").rstrip("\r"), owner, reply)
        except OSError:
            pass
        done = threading.Event()
        self.loop.call_soon_threadsafe(lambda: (disconnected(owner), done.set()))
        done.wait(2)  # antes de fechar o socket
        log("○ USB desconectado")


# MARK: - Bluetooth LE (bleak + WinRT): o iPhone é o periférico, este computador assina a característica de comandos


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
            if str(e) != last_err:  # Bluetooth desligado/sem adaptador: avisa uma vez e tenta com calma
                log("Bluetooth: %s (o Bluetooth está ligado?)" % e)
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
            try:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except OSError:
                pass

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
    ips = []
    if psutil:
        for name, addrs in psutil.net_if_addrs().items():
            if "loopback" in name.lower() or "vethernet" in name.lower():  # Hyper-V/WSL: rede interna
                continue
            ips += [a.address for a in addrs if a.family == socket.AF_INET
                    and not a.address.startswith(("127.", "169.254.", "172.17."))]
    p = primary_ip()
    if p:
        ips = [p] + [i for i in ips if i != p]
    return ips


# MARK: - main


async def main():
    web_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "web")
    loop = asyncio.get_event_loop()
    actions.ensure_file()
    if IS_WIN:
        USBLink(loop).start()
    for port, handler in ((HTTP_PORT, web_server(web_dir)), (WS_PORT, ws_client)):
        try:
            await asyncio.start_server(handler, "0.0.0.0", port)
        except OSError as e:
            log("✗ porta %d indisponível: %s" % (port, e))
    log("TracePad rodando — PIN do PWA: %s" % PIN)
    for ip in lan_ips():
        log("  PWA: http://%s:%d/?k=%s" % (ip, HTTP_PORT, PIN))
    log("  Ações de shell: %s" % actions.file)
    if IS_WIN:
        await ble_loop()
    else:
        log("  fora do Windows: sem USB e Bluetooth (modo de teste)")
    await asyncio.Event().wait()  # sem bleak, ble_loop volta na hora


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        inp.release()
