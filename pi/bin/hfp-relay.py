#!/usr/bin/env python3
"""Hands-free relay: Tesla <-> Pi <-> Oppo, and the car's mic for the music source.

The Pi is a car kit (HFP Hands-Free) to the Oppo through the phone dongle, and
a phone (HFP Audio Gateway) to the Tesla through the car dongle.

  Control:  the service-level connection (SLC) is set up separately on each
            side, using the Oppo's own features and indicator list for the
            car. After that, AT commands from the car are passed to the Oppo
            and the Oppo's responses and events (RING, +CLIP, +CIEV...) are
            passed back, with indicator numbers mapped by name.
  Audio:    codec negotiation is switched off on both sides, so both calls
            use narrowband CVSD and the SCO audio packets can be copied
            byte-for-byte between the two links in both directions.

Car mic for the music source (voice search): while the music source wants a
mic, the car's cabin mic is borrowed (shown to the Tesla as a call) and sent
  * wired / USB-C: to auxlink-media (MIC_SOCKET), which hands it to the
    XIAO's or the Pi's own USB mic;
  * Bluetooth: straight to the source over its own headset audio link - the
    Pi is also a Bluetooth headset (HFP Hands-Free) to the source, and the
    source opening that link (an app wanting the Bluetooth mic) is the
    request. Whatever the source plays on that link (e.g. the assistant
    answering) goes to the car's speakers.

Requires PipeWire's own HFP/HSP roles to be disabled, so this script owns HFP.
Every AT line is logged with its direction for debugging.
"""
import math
import json
import os
import re
import socket
import struct
import time

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

def load_conf(path="/etc/auxlink.conf"):
    conf = {}
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            conf[k.strip()] = v.strip().strip('"')
    return conf


CONF = load_conf()
CAR = CONF.get("CAR", "").upper()
CAR_ADAPTER = CONF.get("CAR_ADAPTER", "").upper()
PHONE = CONF.get("PHONE", "").upper()
PHONE_ADAPTER = CONF.get("PHONE_ADAPTER", "").upper()
PHONE_ENABLED = CONF.get("PHONE_ENABLED", "1") == "1" and bool(PHONE) and bool(PHONE_ADAPTER)
SOURCE = CONF.get("SOURCE", "").upper()
SOURCE_ADAPTER = CONF.get("SOURCE_ADAPTER", "").upper()
BT_SOURCE = CONF.get("MUSIC_SOURCE", "wired") == "bluetooth" and bool(SOURCE) and bool(SOURCE_ADAPTER)


def reload_devices():
    """Pick up a newly paired car/phone without restarting (a restart would
    drop the very connection the new device is trying to make)."""
    global CONF, CAR, PHONE, PHONE_ENABLED, SOURCE, BT_SOURCE
    CONF = load_conf()
    CAR = CONF.get("CAR", "").upper()
    PHONE = CONF.get("PHONE", "").upper()
    SOURCE = CONF.get("SOURCE", "").upper()
    BT_SOURCE = (CONF.get("MUSIC_SOURCE", "wired") == "bluetooth" and bool(SOURCE)
                 and CONF.get("SOURCE_ADAPTER", "").upper() == SOURCE_ADAPTER and bool(SOURCE_ADAPTER))
    PHONE_ENABLED = (CONF.get("PHONE_ENABLED", "1") == "1" and bool(PHONE)
                     and CONF.get("PHONE_ADAPTER", "").upper() == PHONE_ADAPTER and bool(PHONE_ADAPTER))

HFP_HF_UUID = "0000111e-0000-1000-8000-00805f9b34fb"
HFP_AG_UUID = "0000111f-0000-1000-8000-00805f9b34fb"
BLUEZ = "org.bluez"

# What we tell the Oppo we are (HF features, AT+BRSF): 3-way, CLI,
# voice recognition, remote volume, enhanced call status and control.
# Bit 7 (codec negotiation) and bit 8 (HF indicators) deliberately off.
HF_FEATURES = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6)
# AG features to strip before passing the Oppo's to the car:
# bit 9 codec negotiation, bit 10 HF indicators, bit 11 eSCO S4.
AG_STRIP = (1 << 9) | (1 << 10) | (1 << 11)
# Used for the car only until the Oppo has told us its own.
DEFAULT_AG_FEATURES = 1 | 4 | 8 | 32 | 64 | 128 | 256
DEFAULT_CIND = ('("call",(0,1)),("callsetup",(0-3)),("service",(0-1)),'
                '("signal",(0-5)),("roam",(0,1)),("battchg",(0-5)),("callheld",(0-2))')
DEFAULT_CHLD = "(0,1,2,3)"
# What we tell a Bluetooth music source we are: a headset with voice
# recognition only (no calls). No codec negotiation, so its audio link is
# narrowband CVSD - the same 8 kHz 16-bit format as the car's mic.
SOURCE_HF_FEATURES = 1 << 3
# Bytes (8 kHz s16 = 16000 B/s) buffered between the car and the source;
# beyond this the oldest is dropped so the delay can't grow.
SOURCE_BUF_MAX = 3200

AUDIO_USER = CONF.get("AUDIO_USER", "chris")
CALL_STATE_FILE = "/run/auxlink/call"  # "1" during a call, "0" otherwise
# For the AuxLink app's call notification (auxlink-media passes it on):
CALL_INFO_FILE = "/run/auxlink/call-info.json"   # {"state", "number"}
CALL_CMD_FILE = "/run/auxlink/call-cmd"          # "answer" / "decline", from the app
# "1" once the car's HFP link is set up (SLC complete): auxlink-audio waits for
# it after a reconnect before starting music, so the car sees the stream start
# when it is ready to play it rather than mid-connect.
CAR_SLC_FILE = "/run/auxlink/car-slc"
# Car microphone for the SMO (voice search / navigation): while this file
# holds "1", the car is put in voice-recognition mode and its cabin mic is
# streamed to the Pi. Raw 8 kHz 16-bit mono PCM is written to MIC_DUMP (for
# testing; the route to the SMO comes later).
MIC_REQUEST_FILE = "/run/auxlink/mic"
MIC_DUMP = "/run/auxlink/car-mic.raw"
# Where the car's mic audio goes for the SMO: auxlink-media listens here
# and forwards it to the XIAO (which presents it to the SMO as a USB mic).
MIC_SOCKET = "/run/auxlink/mic.sock"
# "1" while the car's mic is borrowed: the car is in call mode then, so
# auxlink-audio treats it like a call for the music stream (stop it, then
# restart it afterwards - else the car stays silent).
MIC_ACTIVE_FILE = "/run/auxlink/mic-active"
# The Tesla ignores voice recognition started by the phone side (+BVRA: 1):
# it drops the audio link within a second. It does stream its mic for a
# call, so by default the session is shown to the car as a call ("call").
# "vr" keeps the standard voice-recognition way for other cars.
MIC_MODE = CONF.get("CAR_MIC_MODE", "call")
# Never hold the car's mic longer than this per request (an app that keeps
# the SMO mic open, like always-on "Hey Google", must not lock the car).
MIC_MAX_SECONDS = 30

# Played into the car's speakers the moment its mic is live, so the person
# knows when to talk: 150 ms of 880 Hz at 8 kHz, 16-bit (the call-audio format).
READY_BEEP = b"".join(
    struct.pack("<h", int(9000 * math.sin(2 * math.pi * 880 * i / 8000)
                          * min(1.0, i / 80, (1200 - i) / 80)))   # soft edges, no click
    for i in range(1200))

# Car commands we can safely answer "OK" to while no phone is bridged.
OK_WHEN_ALONE = ("AT+CLIP", "AT+CCWA", "AT+CMEE", "AT+NREC", "AT+VGS", "AT+VGM",
                 "AT+BIA", "AT+COPS=", "AT+XAPL", "AT+IPHONEACCEV", "AT+BTRH?",
                 "AT+CSRSF", "AT+CSR", "AT+XEVENT", "AT+APLSIRI")


def clip_fields(s):
    """Comma-separated fields with "quoted" ones (commas inside quotes kept)."""
    out, cur, q = [], "", False
    for c in s.strip():
        if c == '"':
            q = not q
        elif c == "," and not q:
            out.append(cur.strip())
            cur = ""
        else:
            cur += c
    out.append(cur.strip())
    return out


def phone_number(s):
    """A real phone number, not an app's caller ID (Messenger sends a UUID)."""
    return (not s or bool(re.fullmatch(r"\+?[\d\s()./*#-]{1,20}", s.strip()))) \
        and len(re.sub(r"\D", "", s)) <= 15


# Where the number and the name are in each caller-ID line.
CALLER_FIELDS = {"+CLIP:": (0, 4), "+CCWA:": (0, 3), "+CLCC:": (5, 7)}


def car_caller(line):
    """The car shows the "number" as it is: for an app's call put the name
    there ("Messenger user") instead of a long ID."""
    for tag, (n, a) in CALLER_FIELDS.items():
        if line.upper().startswith(tag):
            f = clip_fields(line.split(":", 1)[1])
            if len(f) <= n or phone_number(f[n]):
                return line
            name = (f[a] if len(f) > a else "") or "Internet call"
            f[n] = name
            if len(f) > n + 1:
                f[n + 1] = "129"
            return tag + " " + ",".join(f'"{v}"' if i in (n, a) else v
                                       for i, v in enumerate(f))
    return line


def log(msg):
    print(msg, flush=True)


def names_of(cind_list):
    return re.findall(r'\("([^"]+)"', cind_list)


def addr_of(dev_path):
    return dev_path.rsplit("dev_", 1)[-1].replace("_", ":").upper()


class Link:
    """One RFCOMM connection with line framing."""

    def __init__(self, name, sock, on_line, on_close):
        self.name = name
        self.sock = sock
        self.buf = b""
        self.on_line = on_line
        self.on_close = on_close
        sock.setblocking(False)
        self.watch = GLib.io_add_watch(sock.fileno(), GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self._ready)

    def _ready(self, fd, cond):
        if cond & (GLib.IO_HUP | GLib.IO_ERR):
            self.close()
            return False
        try:
            data = self.sock.recv(1024)
        except BlockingIOError:
            return True
        except OSError:
            self.close()
            return False
        if not data:
            self.close()
            return False
        self.buf += data
        # Lines end in \r (commands) or \r\n (responses).
        while True:
            m = re.search(rb"[\r\n]", self.buf)
            if not m:
                break
            line, self.buf = self.buf[:m.start()], self.buf[m.end():]
            line = line.decode("utf-8", "replace").strip()
            if line:
                self.on_line(line)
        return True

    def send(self, raw):
        try:
            self.sock.sendall(raw.encode())
        except OSError as e:
            log(f"{self.name} send failed: {e}")

    def close(self):
        if self.sock is None:
            return
        GLib.source_remove(self.watch)
        try:
            self.sock.close()
        except OSError:
            pass
        self.sock = None
        self.on_close()


class Relay:
    def __init__(self, bus):
        self.bus = bus
        self.car = None          # Link to the Tesla (we are AG)
        self.phone = None        # Link to the Oppo (we are HF)
        self.car_slc = False
        self.phone_slc = False
        self.phone_queue = []    # our own SLC commands still to send
        self.phone_waiting = False
        self.phone_ag_features = None
        self.phone_cind = None   # raw +CIND=? list from the Oppo
        self.phone_names = []
        self.phone_chld = None
        self.values = {}         # indicator name -> value (mirrors the Oppo)
        self.car_names = []      # indicator list as we gave it to the car
        self.sco_phone = None
        self.sco_car = None
        self.sco_watches = []
        self.in_call = False
        self.caller = ""         # number from +CLIP while ringing
        self.caller_name = ""    # name, when the phone sends one with it
        self.call_info = None    # last written (state, number)
        self.own_pending = 0     # our own commands to the phone after SLC (their OK isn't the car's)
        self.own_clcc = False    # our own AT+CLCC is out: its +CLCC lines aren't the car's
        self.clcc_asked = False  # asked once this call
        try:
            self.cmd_seen = os.stat(CALL_CMD_FILE).st_mtime
        except OSError:
            self.cmd_seen = 0.0
        self.mic = False         # car-mic session for the SMO is open
        self.mic_sco = None
        self.mic_watch = None
        self.mic_out = None
        self.mic_bytes = 0
        self.mic_hold = 0.0      # after a failure / car cancel: don't retry until then
        self.mic_note = ""       # last "can't start" reason logged (no repeats)
        self.mic_since = 0.0
        self.mic_tx = None       # datagram socket to auxlink-media
        self.beep = bytearray()  # ready beep still to play into the car
        self.beep_due = 0        # when the ready beep is due at the latest (0 = done)
        self.src = None          # HFP link to a Bluetooth music source (we are HF)
        self.src_slc = False
        self.src_queue = []
        self.src_waiting = False
        self.src_sco = None      # its headset audio link: open = it wants the mic
        self.src_watch = None
        self.src_buf = bytearray()   # car mic -> source
        self.car_buf = bytearray()   # source (assistant's answer) -> car speakers
        self.sco_listeners = {}  # adapter address -> listening SCO socket
        try:
            os.makedirs(os.path.dirname(CALL_STATE_FILE), exist_ok=True)
            with open(CALL_STATE_FILE, "w") as f:
                f.write("0")
        except OSError:
            pass
        self.write_flag(MIC_ACTIVE_FILE, "0")    # no mic session survives a restart

    # ------------------------------------------------------------ car side
    def car_connected(self, sock):
        if self.car:
            self.car.close()
        self.car = Link("car", sock, self.car_line, self.car_closed)
        self.car_slc = False
        self.car_names = []
        log("Car HFP connected")

    def car_closed(self):
        log("Car HFP disconnected")
        self.car = None
        self.car_slc = False
        self.write_flag(CAR_SLC_FILE, "0")
        self.sco_close_car()
        if self.mic:
            self.mic_stop("car disconnected")

    def to_car(self, line):
        if self.car:
            log(f"  -> car   {line}")
            self.car.send(f"\r\n{line}\r\n")

    def car_line(self, line):
        log(f"car   ->   {line}")
        up = line.upper()
        if up.startswith("AT+BRSF="):
            feats = self.phone_ag_features if self.phone_ag_features is not None else DEFAULT_AG_FEATURES
            self.to_car(f"+BRSF: {feats & ~AG_STRIP}")
            self.to_car("OK")
        elif up.startswith("AT+BAC="):
            self.to_car("OK")
        elif up == "AT+CIND=?":
            raw = self.phone_cind or DEFAULT_CIND
            self.car_names = names_of(raw)
            self.to_car(f"+CIND: {raw}")
            self.to_car("OK")
        elif up == "AT+CIND?":
            names = self.car_names or names_of(DEFAULT_CIND)
            vals = ",".join(str(self.values.get(n, 0)) for n in names)
            self.to_car(f"+CIND: {vals}")
            self.to_car("OK")
        elif up.startswith("AT+CMER="):
            self.to_car("OK")
            if not self.phone_ag_features or not (self.phone_ag_features & 1):
                self.car_slc_done()  # no three-way calling: SLC ends here
        elif up == "AT+CHLD=?":
            self.to_car(f"+CHLD: {self.phone_chld or DEFAULT_CHLD}")
            self.to_car("OK")
            self.car_slc_done()
        elif up.startswith("AT+BIND") or up.startswith("AT+BIEV"):
            self.to_car("OK")
        elif self.mic and MIC_MODE == "call" and up == "AT+CLCC":
            self.to_car('+CLCC: 1,0,0,0,0,"",129')   # our "call": outgoing, active
            self.to_car("OK")
        elif self.mic and MIC_MODE == "call" and (up in ("AT+CHUP", "ATH") or up.startswith("AT+CHLD=1")):
            self.to_car("OK")                         # hang-up in the car ends it
            self.mic_stop("hung up in the car")
            self.mic_hold = float("inf")
        elif up.startswith("AT+BVRA") and self.mic:
            # During our own mic session voice recognition belongs to us, not
            # the Oppo. =0 means the car ended it (e.g. cancelled on screen).
            self.to_car("OK")
            if up.endswith("=0"):
                self.mic_stop("ended by the car", tell_car=False)
                self.mic_hold = float("inf")   # until the SMO stops asking
        elif self.phone and self.phone_slc:
            self.phone.send(line + "\r")   # pass straight through
            log(f"  -> phone {line}")
        elif any(up.startswith(p) for p in OK_WHEN_ALONE):
            self.to_car("OK")
        elif up == "AT+CLCC":
            self.to_car("OK")              # no calls without a phone
        elif up == "AT+COPS?":
            self.to_car('+COPS: 0,0,"AuxLink"')
            self.to_car("OK")
        else:
            self.to_car("ERROR")

    def car_slc_done(self):
        if not self.car_slc:
            self.car_slc = True
            log("Car SLC complete")
            self.write_flag(CAR_SLC_FILE, "1")

    @staticmethod
    def write_flag(path, value):
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(value)
        except OSError as e:
            log(f"Could not write {path}: {e}")

    # ------------------------------------------------- car mic for the SMO
    def write_call_info(self):
        """The call's state for the app's notification on the music device."""
        setup, call = self.values.get("callsetup", 0), self.values.get("call", 0)
        state = ("incoming" if setup == 1 else "outgoing" if setup in (2, 3)
                 else "active" if call else "idle")
        if state == "idle":
            self.caller = self.caller_name = ""
            self.clcc_asked = False
        elif state in ("outgoing", "active") and not self.caller and not self.clcc_asked:
            # No +CLIP for an outgoing call: ask the phone for its call list.
            self.clcc_asked = True
            GLib.timeout_add(1500, self.ask_clcc)
        info = (state, self.caller, self.caller_name)
        if info == self.call_info:
            return
        self.call_info = info
        try:
            os.makedirs(os.path.dirname(CALL_INFO_FILE), exist_ok=True)
            with open(CALL_INFO_FILE + ".tmp", "w") as f:
                json.dump({"state": state, "number": self.caller, "name": self.caller_name}, f)
            os.replace(CALL_INFO_FILE + ".tmp", CALL_INFO_FILE)
        except OSError as e:
            log(f"Could not write {CALL_INFO_FILE}: {e}")

    def ask_clcc(self):
        if self.caller or not (self.phone and self.phone_slc) or self.values.get("callsetup", 0) == 1:
            return False
        log("Asking the phone who the call is with -> phone AT+CLCC")
        self.own_pending += 1
        self.own_clcc = True
        self.phone.send("AT+CLCC\r")
        GLib.timeout_add(3000, self.clcc_timeout)
        return False

    def clcc_timeout(self):
        # No answer: never keep holding back the car's own call-list lines.
        self.own_clcc = False
        return False

    def call_cmd_poll(self):
        """Answer / Decline pressed on the music device (the AuxLink app)."""
        try:
            t = os.stat(CALL_CMD_FILE).st_mtime
            if t == self.cmd_seen:
                return True
            self.cmd_seen = t
            cmd = open(CALL_CMD_FILE).read().strip()
        except OSError:
            return True
        if not (self.phone and self.phone_slc):
            log(f"App asked to {cmd} the call, but the phone isn't connected")
            return True
        at = {"answer": "ATA", "decline": "AT+CHUP", "hangup": "AT+CHUP"}.get(cmd)
        if at:
            log(f"App: {cmd} the call -> phone {at}")
            self.own_pending += 1
            self.phone.send(at + "\r")
        return True

    def mic_poll(self):
        """Follow MIC_REQUEST_FILE: start/stop the car-mic session."""
        try:
            want = open(MIC_REQUEST_FILE).read().strip() == "1"
        except OSError:
            want = False
        want = want or self.src_sco is not None   # Bluetooth source listening
        if not want:
            self.mic_hold = 0.0
            self.mic_note = ""
            if self.mic:
                self.mic_stop("SMO stopped listening")
        elif self.mic and time.time() - self.mic_since > MIC_MAX_SECONDS:
            self.mic_stop(f"longer than {MIC_MAX_SECONDS} s")
            self.mic_hold = float("inf")   # until the SMO closes the mic
        elif not self.mic and time.time() >= self.mic_hold:
            self.mic_start()
        return True

    def car_ind(self, name, value):
        """Send one indicator to the car directly (not mirrored from the Oppo)."""
        if self.car and self.car_slc and name in self.car_names:
            self.to_car(f"+CIEV: {self.car_names.index(name) + 1},{value}")

    def mic_cant(self, why):
        if why != self.mic_note:
            log(f"Car mic requested but {why}")
            self.mic_note = why

    def mic_start(self):
        if not (self.car and self.car_slc):
            return self.mic_cant("the car is not connected")
        if self.in_call or self.sco_car or self.sco_phone:
            return self.mic_cant("a call is in progress")
        self.mic_note = ""
        self.write_flag(MIC_ACTIVE_FILE, "1")
        if MIC_MODE == "call":
            log("Car mic: starting (shown to the car as a call)")
            self.car_ind("callsetup", 2)
        else:
            log("Car mic: starting voice recognition on the car")
            self.to_car("+BVRA: 1")
        try:
            s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_SCO)
            s.bind(CAR_ADAPTER)
            s.settimeout(5)
            s.connect(CAR)
            s.setblocking(False)
        except OSError as e:
            log(f"Car mic: could not open the audio link to the car: {e}")
            if MIC_MODE == "call":
                self.car_ind("callsetup", 0)
            else:
                self.to_car("+BVRA: 0")
            self.mic_hold = float("inf")   # don't hammer the car; wait for the next request
            self.write_flag(MIC_ACTIVE_FILE, "0")
            return
        if MIC_MODE == "call":
            self.car_ind("call", 1)
            self.car_ind("callsetup", 0)
        try:
            self.mic_out = open(MIC_DUMP, "wb")
        except OSError as e:
            log(f"Car mic: cannot write {MIC_DUMP}: {e}")
            self.mic_out = None
        self.mic, self.mic_sco, self.mic_bytes = True, s, 0
        # "Talk now" beep: played when the car's mic is really live (its
        # first non-silent audio), not when the link opens - the car is
        # still setting the call up then and doesn't play call audio yet.
        self.beep = bytearray()
        self.beep_due = time.time() + 6       # fallback: play it by then anyway
        self.mic_since = time.time()
        if self.mic_tx is None:
            self.mic_tx = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            self.mic_tx.setblocking(False)
        self.mic_watch = GLib.io_add_watch(s.fileno(), GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR,
                                           self.mic_pump)
        log("Car mic: open")

    def mic_pump(self, fd, cond):
        if self.mic_sco is None:
            return False
        if cond & (GLib.IO_HUP | GLib.IO_ERR):
            self.mic_watch = None
            self.mic_stop("audio link closed by the car")
            self.mic_hold = float("inf")   # not again until the SMO asks anew
            return False
        try:
            data = self.mic_sco.recv(1024)
        except BlockingIOError:
            return True
        except OSError:
            data = b""
        if not data:
            self.mic_watch = None
            self.mic_stop("audio link closed")
            self.mic_hold = float("inf")
            return False
        self.mic_bytes += len(data)
        if self.beep_due:
            n = len(data) // 2
            loud = n and max(abs(v) for v in struct.unpack(f"<{n}h", data[:n * 2])) > 600
            if loud or time.time() >= self.beep_due:
                self.beep_due = 0
                self.beep = bytearray(READY_BEEP)
                log("Car mic: live - beep")
        if self.mic_out:
            self.mic_out.write(data)
        try:
            self.mic_tx.sendto(data, MIC_SOCKET)
        except OSError:
            pass   # nobody listening (or busy): this audio is just dropped
        if self.src_sco is not None:
            self.src_buf += data
            del self.src_buf[:max(0, len(self.src_buf) - SOURCE_BUF_MAX)]
        # To the car's speakers: first the ready beep, then the source's own
        # audio if it sends any (a Bluetooth source's assistant), else silence.
        if self.beep:
            out = bytes(self.beep[:len(data)])
            del self.beep[:len(data)]
        else:
            out = bytes(self.car_buf[:len(data)])
            del self.car_buf[:len(data)]
        try:
            self.mic_sco.send(out + bytes(len(data) - len(out)))
        except OSError:
            pass
        return True

    def mic_stop(self, why, tell_car=True):
        # Ended from the car's side (hang-up, timeout, car gone, a real
        # call) while a Bluetooth source still holds its headset mic open:
        # end that too, or the source stays in call mode with its music
        # held back (Google Assistant doesn't let go by itself).
        if self.src_sco is not None and why != "SMO stopped listening":
            self.src_end_voice(why)
        if self.mic_watch:
            GLib.source_remove(self.mic_watch)
            self.mic_watch = None
        if self.mic_sco:
            try:
                self.mic_sco.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.mic_sco.close()
            self.mic_sco = None
        if self.mic_out:
            self.mic_out.close()
            self.mic_out = None
        self.src_buf.clear()
        self.car_buf.clear()
        if tell_car and self.car and self.car_slc:
            if MIC_MODE == "call":
                self.car_ind("call", 0)
            else:
                self.to_car("+BVRA: 0")
        self.mic = False
        self.write_flag(MIC_ACTIVE_FILE, "0")
        log(f"Car mic: closed ({why}); {self.mic_bytes // 16000:.0f} s of audio received")

    # ------------------------------------------- Bluetooth music source
    def src_connected(self, sock):
        if self.src:
            self.src.close()
        self.src = Link("source", sock, self.src_line, self.src_closed)
        self.src_slc = False
        self.src_queue = [f"AT+BRSF={SOURCE_HF_FEATURES}"]
        self.src_waiting = False
        log("Music source: headset link connected (for the car's mic)")
        self.src_next()

    def src_closed(self):
        log("Music source: headset link disconnected")
        self.src = None
        self.src_slc = False
        self.src_sco_close("headset link closed")

    def src_next(self):
        if self.src and self.src_queue and not self.src_waiting:
            cmd = self.src_queue.pop(0)
            self.src_waiting = True
            log(f"  -> source {cmd}")
            self.src.send(cmd + "\r")
        elif self.src and not self.src_queue and not self.src_waiting and not self.src_slc:
            self.src_slc = True
            log("Music source: headset link ready; its voice search can use the car's mic")

    def src_line(self, line):
        log(f"source ->  {line}")
        up = line.upper()
        if up.startswith("+BRSF:"):
            feats = int(line.split(":", 1)[1].strip() or 0)
            self.src_queue = ["AT+CIND=?", "AT+CIND?", "AT+CMER=3,0,0,1"]
            if feats & 1:
                self.src_queue.append("AT+CHLD=?")
            return
        if up in ("OK", "ERROR") or up.startswith("+CME ERROR"):
            if self.src_waiting:
                self.src_waiting = False
                self.src_next()
        # Everything else (+CIND, +CIEV, +BVRA, +VGS...) needs no answer.

    def src_sco_open(self, conn):
        self.src_sco_close("replaced")
        conn.setblocking(False)
        self.src_sco = conn
        self.src_buf.clear()
        self.car_buf.clear()
        self.src_watch = GLib.io_add_watch(conn.fileno(), GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR,
                                           self.src_pump)
        log("Music source opened its headset mic: borrowing the car's mic")
        self.mic_poll()

    def src_pump(self, fd, cond):
        if self.src_sco is None:
            return False
        if cond & (GLib.IO_HUP | GLib.IO_ERR):
            self.src_watch = None
            self.src_sco_close("closed by the source")
            return False
        try:
            data = self.src_sco.recv(1024)
        except BlockingIOError:
            return True
        except OSError:
            data = b""
        if not data:
            self.src_watch = None
            self.src_sco_close("closed by the source")
            return False
        if self.mic:
            self.car_buf += data
            del self.car_buf[:max(0, len(self.car_buf) - SOURCE_BUF_MAX)]
        # Paced by the source: one packet of car mic back per packet it sends.
        out = bytes(self.src_buf[:len(data)])
        del self.src_buf[:len(data)]
        try:
            self.src_sco.send(out + bytes(len(data) - len(out)))
        except OSError:
            pass
        return True

    def src_end_voice(self, why):
        """Tell the source to stop voice recognition (the headset way:
        AT+BVRA=0) and close its headset audio link."""
        if self.src and self.src_slc:
            log("  -> source AT+BVRA=0")
            self.src.send("AT+BVRA=0\r")
        sco, self.src_sco = self.src_sco, None
        if self.src_watch:
            GLib.source_remove(self.src_watch)
            self.src_watch = None
        for f in (lambda: sco.shutdown(socket.SHUT_RDWR), sco.close):
            try:
                f()
            except OSError:
                pass
        log(f"Music source: ended its voice session ({why})")

    def src_sco_close(self, why):
        if self.src_watch:
            GLib.source_remove(self.src_watch)
            self.src_watch = None
        if self.src_sco is None:
            return
        try:
            self.src_sco.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.src_sco.close()
        except OSError:
            pass
        self.src_sco = None
        log(f"Music source closed its headset mic ({why})")
        self.mic_poll()

    # ---------------------------------------------------------- phone side
    def phone_connected(self, sock):
        if self.phone:
            self.phone.close()
        self.phone = Link("phone", sock, self.phone_line, self.phone_closed)
        self.phone_slc = False
        self.phone_queue = [f"AT+BRSF={HF_FEATURES}"]  # the rest follows +BRSF
        self.phone_waiting = False
        log("Oppo HFP connected, starting SLC")
        self.phone_next()

    def phone_closed(self):
        log("Oppo HFP disconnected")
        self.phone = None
        self.phone_slc = False
        self.sco_close_phone()
        # Tell the car the phone has no service / no call.
        for name in ("call", "callsetup", "callheld"):
            self.set_value(name, 0)
        self.set_value("service", 0)

    def phone_next(self):
        if self.phone and self.phone_queue and not self.phone_waiting:
            cmd = self.phone_queue.pop(0)
            self.phone_waiting = True
            log(f"  -> phone {cmd}  (ours)")
            self.phone.send(cmd + "\r")
        elif self.phone and not self.phone_queue and not self.phone_waiting and not self.phone_slc:
            self.phone_slc = True
            log("Oppo SLC complete; relaying")

    def phone_line(self, line):
        log(f"phone ->   {line}")
        up = line.upper()
        # Things we always track, whoever asked.
        if up.startswith("+BRSF:"):
            self.phone_ag_features = int(line.split(":", 1)[1].strip())
            # SLC order from the HFP spec, then the extras we want.
            self.phone_queue = ["AT+CIND=?", "AT+CIND?", "AT+CMER=3,0,0,1"]
            if self.phone_ag_features & 1:  # three-way calling
                self.phone_queue.append("AT+CHLD=?")
            self.phone_queue += ["AT+CLIP=1", "AT+CCWA=1", "AT+CMEE=1"]
            return
        if up.startswith("+CIND:") and "(" in line:
            self.phone_cind = line.split(":", 1)[1].strip()
            self.phone_names = names_of(self.phone_cind)
            return
        if up.startswith("+CIND:"):
            vals = [v.strip() for v in line.split(":", 1)[1].split(",")]
            for n, v in zip(self.phone_names, vals):
                self.set_value(n, int(v) if v.isdigit() else 0)
            return
        if up.startswith("+CHLD:"):
            self.phone_chld = line.split(":", 1)[1].strip()
            if not self.phone_slc:
                return
        if up.startswith("+CIEV:"):
            idx, val = [p.strip() for p in line.split(":", 1)[1].split(",")[:2]]
            if idx.isdigit() and 0 < int(idx) <= len(self.phone_names):
                self.set_value(self.phone_names[int(idx) - 1], int(val))
            return  # set_value forwards to the car with the car's numbering
        if up.startswith("+BCS:"):
            return  # codec negotiation is off; never pass this on
        if up.startswith("+CLIP:") and '"' in line:
            # +CLIP: "number",type[,subaddr,satype,"name"[,validity]]
            f = clip_fields(line.split(":", 1)[1])
            num, name = f[0], (f[4] if len(f) > 4 else "")
            if (num, name) != (self.caller, self.caller_name):
                self.caller, self.caller_name = num, name
                self.write_call_info()
        if up.startswith("+CLCC:") and '"' in line and (self.own_clcc or not self.caller):
            # The call list (the car asks for it during calls): the only
            # place an OUTGOING call's number shows up (no +CLIP for those).
            # +CLCC: idx,dir,stat,mode,mpty,"number",type[,"name"]
            f = clip_fields(line.split(":", 1)[1])
            if len(f) > 5 and f[5]:
                self.caller, self.caller_name = f[5], (f[7] if len(f) > 7 else "")
                self.write_call_info()
        if up.startswith("+CLCC:") and self.own_clcc:
            return  # the answer to our own AT+CLCC: not the car's
        if self.own_pending and (up in ("OK", "ERROR") or up.startswith("+CME ERROR")):
            self.own_pending -= 1
            self.own_clcc = False
            return  # the answer to our own ATA / AT+CHUP (the app's buttons)
        # Responses to our own SLC commands stay here.
        if not self.phone_slc:
            if up in ("OK", "ERROR") or up.startswith("+CME ERROR"):
                self.phone_waiting = False
                self.phone_next()
            return
        # Everything else (RING, +CLIP, +CLCC, +CCWA, +VGS, OK/ERROR for the
        # car's own commands...) goes to the car as-is (caller IDs from apps
        # like Messenger swapped for their name).
        if self.car_slc:
            self.to_car(car_caller(line))

    def set_value(self, name, value):
        if self.values.get(name) == value:
            return
        self.values[name] = value
        self.track_call_state()
        self.write_call_info()
        if self.car and self.car_slc and name in self.car_names:
            self.to_car(f"+CIEV: {self.car_names.index(name) + 1},{value}")

    def track_call_state(self):
        """Note when a call (or a ringing/dialling attempt) ends, and then
        nudge the car's music stream so it actually plays again."""
        busy = bool(self.values.get("call") or self.values.get("callsetup"))
        if busy != self.in_call:
            try:
                os.makedirs(os.path.dirname(CALL_STATE_FILE), exist_ok=True)
                with open(CALL_STATE_FILE, "w") as f:
                    f.write("1" if busy else "0")
            except OSError as e:
                log(f"Could not write {CALL_STATE_FILE}: {e}")
        if busy and not self.in_call:
            self.in_call = True
            if self.mic:
                self.mic_stop("a call started")   # calls always win
        elif not busy and self.in_call:
            self.in_call = False
            # Close call audio ourselves rather than waiting on the far end's
            # socket to HUP: a lagging or missing HUP can leave the actual
            # SCO link established on the controller with nothing reading or
            # writing it, which shows up as corrupted packets, then a crash.
            if self.sco_phone or self.sco_car:
                log("Call over; closing call audio")
                self.sco_close_all()
            # No music nudge any more: auxlink-audio stops the car's music
            # stream for the call and starts a fresh one once the call file
            # says 0 (and the SMO plays), which the car plays like a phone's.
            log("Call over")

    # --------------------------------------------------------------- audio
    def sco_start_listening(self):
        """Listen for audio links on the phone adapter (call audio from the
        Oppo) and the Bluetooth music source's adapter (its headset mic).
        Called again by the periodic tick if an adapter was reset."""
        want = set()
        if PHONE_ENABLED:
            want.add(PHONE_ADAPTER)
        if BT_SOURCE:
            want.add(SOURCE_ADAPTER)
        for adapter in want - set(self.sco_listeners):
            try:
                s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_SCO)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                s.bind(adapter)
                s.listen(1)
            except OSError as e:
                log(f"Cannot listen for audio links on {adapter} yet: {e}")
                continue
            self.sco_listeners[adapter] = s
            GLib.io_add_watch(s.fileno(), GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self.sco_incoming)
            log(f"Listening for audio links on {adapter}")

    def sco_incoming(self, fd, cond):
        adapter = next((a for a, s in self.sco_listeners.items() if s.fileno() == fd), None)
        if adapter is None:
            return False
        listener = self.sco_listeners[adapter]
        if cond & (GLib.IO_HUP | GLib.IO_ERR):
            log(f"Audio-link listener on {adapter} closed (adapter reset?); will reopen")
            try:
                listener.close()
            except OSError:
                pass
            del self.sco_listeners[adapter]
            return False
        try:
            conn, addr = listener.accept()
        except OSError as e:
            log(f"Audio link accept failed: {e}")
            return True
        addr = str(addr).upper()
        if BT_SOURCE and addr == SOURCE and adapter == SOURCE_ADAPTER:
            self.src_sco_open(conn)
            return True
        if addr != PHONE or adapter != PHONE_ADAPTER:
            log(f"Rejecting audio link from {addr}")
            conn.close()
            return True
        self.sco_close_phone()
        self.sco_phone = conn
        log("Call audio: Oppo -> Pi open")
        if self.car and self.car_slc:
            try:
                c = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_SCO)
                c.bind(CAR_ADAPTER)
                c.settimeout(5)
                c.connect(CAR)
                self.sco_car = c
                log("Call audio: Pi -> car open")
            except OSError as e:
                log(f"Could not open call audio to the car: {e}")
                self.sco_car = None
        for s in (self.sco_phone, self.sco_car):
            if s:
                s.setblocking(False)
                self.sco_watches.append(GLib.io_add_watch(
                    s.fileno(), GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self.sco_pump))
        return True

    def sco_pump(self, fd, cond):
        src = dst = None
        for a, b in ((self.sco_phone, self.sco_car), (self.sco_car, self.sco_phone)):
            try:
                if a is not None and a.fileno() == fd:
                    src, dst = a, b
                    break
            except OSError:
                pass
        if src is None:
            return False  # socket already closed; drop this watch
        if cond & (GLib.IO_HUP | GLib.IO_ERR):
            log("Call audio closed")
            self.sco_close_all()
            return False
        try:
            data = src.recv(1024)
        except BlockingIOError:
            return True
        except OSError:
            self.sco_close_all()
            return False
        if not data:
            self.sco_close_all()
            return False
        if dst:
            try:
                dst.send(data)
            except (BlockingIOError, OSError):
                pass  # drop a packet rather than stall
        return True

    def sco_close_all(self):
        for w in self.sco_watches:
            GLib.source_remove(w)
        self.sco_watches = []
        for s in (self.sco_phone, self.sco_car):
            if s:
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    s.close()
                except OSError:
                    pass
        self.sco_phone = self.sco_car = None

    def sco_close_phone(self):
        if self.sco_phone:
            self.sco_close_all()

    def sco_close_car(self):
        if self.sco_car:
            self.sco_close_all()


class Profile(dbus.service.Object):
    def __init__(self, bus, path, relay, side):
        super().__init__(bus, path)
        self.relay = relay
        self.side = side  # "car" or "phone"

    @dbus.service.method("org.bluez.Profile1", in_signature="", out_signature="")
    def Release(self):
        log(f"{self.side} profile released")

    @dbus.service.method("org.bluez.Profile1", in_signature="oha{sv}", out_signature="")
    def NewConnection(self, device, fd, props):
        reload_devices()
        addr = addr_of(str(device))
        fd = fd.take()
        sock = socket.socket(fileno=fd)
        if self.side == "car" and addr == CAR:
            self.relay.car_connected(sock)
        elif self.side == "phone" and addr == PHONE:
            self.relay.phone_connected(sock)
        elif self.side == "phone" and BT_SOURCE and addr == SOURCE:
            self.relay.src_connected(sock)       # the music source, as a headset
        else:
            log(f"Rejecting {self.side} HFP connection from {addr}")
            sock.close()

    @dbus.service.method("org.bluez.Profile1", in_signature="o", out_signature="")
    def RequestDisconnection(self, device):
        addr = addr_of(str(device))
        if self.side == "car" and self.relay.car and addr == CAR:
            self.relay.car.close()
        elif self.side == "phone" and self.relay.phone and addr == PHONE:
            self.relay.phone.close()
        elif self.side == "phone" and self.relay.src and addr == SOURCE:
            self.relay.src.close()


def main():
    import sys
    import traceback

    def hook(t, v, tb):  # log and carry on instead of dying mid-call
        log("Unexpected error: " + "".join(traceback.format_exception(t, v, tb)))
    sys.excepthook = hook
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    relay = Relay(bus)
    mgr = dbus.Interface(bus.get_object(BLUEZ, "/org/bluez"), "org.bluez.ProfileManager1")

    ag = Profile(bus, "/auxlink/hfp_ag", relay, "car")
    mgr.RegisterProfile("/auxlink/hfp_ag", HFP_AG_UUID, dbus.Dictionary({
        "Name": "auxlink Audio Gateway",
        "Channel": dbus.UInt16(13),
        "Version": dbus.UInt16(0x0107),
        "Features": dbus.UInt16(0x000D),   # 3-way, voice recognition, in-band ring
        "RequireAuthorization": dbus.Boolean(False),
        "AutoConnect": dbus.Boolean(True),
    }, signature="sv"))
    hf = Profile(bus, "/auxlink/hfp_hf", relay, "phone")
    mgr.RegisterProfile("/auxlink/hfp_hf", HFP_HF_UUID, dbus.Dictionary({
        "Name": "auxlink Hands-Free",
        "Channel": dbus.UInt16(7),
        "Version": dbus.UInt16(0x0107),
        "Features": dbus.UInt16(0x001E),   # 3-way, CLI, voice recognition, volume
        "RequireAuthorization": dbus.Boolean(False),
        "AutoConnect": dbus.Boolean(True),
    }, signature="sv"))
    log("Registered HFP Audio Gateway (for the car) and Hands-Free (for the Oppo"
        + (" and the Bluetooth music source)" if BT_SOURCE else ")"))
    relay.sco_start_listening()

    om = dbus.Interface(bus.get_object(BLUEZ, "/"), "org.freedesktop.DBus.ObjectManager")

    def device_path(adapter_addr, dev_addr):
        for path, ifaces in om.GetManagedObjects().items():
            a = ifaces.get("org.bluez.Adapter1")
            if a and str(a["Address"]).upper() == adapter_addr:
                return f"{path}/dev_{dev_addr.replace(':', '_')}"
        return None

    connected_since = {}
    last_err = {}

    def connect_error(dev_addr, e):
        msg = e.get_dbus_message()
        if last_err.get(dev_addr) != msg:       # each new reason once, not every 10 s
            last_err[dev_addr] = msg
            log(f"HFP connect to {dev_addr}: {msg}")

    def ensure(dev_addr, adapter_addr, remote_uuid, have):
        """If the device is connected but our HFP link to it is not, open it.

        Waits until it has been connected for 20 s: right after connecting,
        the device opens HFP itself, and our connect colliding with that
        made the Tesla drop the whole connection."""
        if have():
            connected_since.pop(dev_addr, None)
            return
        path = device_path(adapter_addr, dev_addr)
        if not path:
            return
        try:
            props = dbus.Interface(bus.get_object(BLUEZ, path), "org.freedesktop.DBus.Properties")
            if not props.Get("org.bluez.Device1", "Connected"):
                connected_since.pop(dev_addr, None)
                return
            if time.time() - connected_since.setdefault(dev_addr, time.time()) < 20:
                return
            dev = dbus.Interface(bus.get_object(BLUEZ, path), "org.bluez.Device1")
            dev.ConnectProfile(remote_uuid, reply_handler=lambda: last_err.pop(dev_addr, None),
                               error_handler=lambda e: connect_error(dev_addr, e))
        except dbus.DBusException:
            pass

    def tick():
        try:
            if int(open("/run/auxlink/pairing-active").read().strip()) > time.time():
                return True      # a pairing is under way: leave the adapters alone
        except (OSError, ValueError):
            pass
        reload_devices()
        relay.sco_start_listening()
        if PHONE_ENABLED:
            ensure(PHONE, PHONE_ADAPTER, HFP_AG_UUID, lambda: relay.phone is not None)
        if CAR and CAR_ADAPTER:
            ensure(CAR, CAR_ADAPTER, HFP_HF_UUID, lambda: relay.car is not None)
        if BT_SOURCE:
            ensure(SOURCE, SOURCE_ADAPTER, HFP_AG_UUID, lambda: relay.src is not None)
        return True

    GLib.timeout_add(200, relay.mic_poll)   # react quickly: the SMO is listening
    GLib.timeout_add(300, relay.call_cmd_poll)   # the app's Answer / Decline
    GLib.timeout_add_seconds(10, tick)
    GLib.timeout_add_seconds(3, lambda: (tick(), False)[1])
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
