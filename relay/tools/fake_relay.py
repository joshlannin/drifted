#!/usr/bin/env python3
"""A stand-in for the Drifted relay, with a simulated table behind it, for testing hosts without hardware.

It speaks the relay's TCP protocol (relay/README.md, "Relay protocol") and behaves like the firmware: token check,
one host at a time, the handshake gate, page pacing, status every 5 s, scan/select/release/connect commands, and
ota (it downloads the image, then "restarts" with a new version string).
Behind it is a small model of the table's session rules from docs/protocol.md:

- On a fresh link (or after a session reset) the table sends 0x50/1 every 2 s until the host answers 0x50/2.
- It then sends its init dump (stored ids, a time request, colours), waits for each reply, resending up to 4
  times before restarting the handshake, and finishes with 0x4F/1.
- It broadcasts its running state (0x35/1) twice a second.
- After 2 s without any frame from the host it resets the session (back to 0x50/1). Drawing carries on.
- Uploads: 0x13/1 → 0x34/2, pages (0x53), 0x13/2 → 0x34/3 or 0x34/1 with the missing pages. An upload that gets
  no message for 5 s is abandoned: the file is deleted and the table says 0x34/5; until then a new Start is
  ignored (docs/failure-modes.md). A session reset doesn't end it sooner. Play (0x14/1) draws the pattern for
  --draw-seconds.

- Playlists: 0x10/1 and 0x10/3 store one and the table re-sends its 0x30 list; 0x10/8 starts its first id.

It records what happened (handshakes, resets, uploads, plays, forbidden commands) in --stats FILE as JSON.
Signals: SIGUSR1 drops the table link for 3 s (as if the table went out of range); SIGUSR2 closes the host's TCP
connection (as if Wi-Fi blipped).

Jobs (relay/README.md, "Jobs"): with --engine LIB the relay runs jobs with the firmware's own job engine,
relay/firmware/main/job.c built as a shared library (cc -shared -o libdriftjob.dylib relay/firmware/main/job.c),
and says proto 2. Without it, it is a proto 1 relay with no jobs.

Faults: --faults FILE names a JSON file, read again whenever it changes. Each entry is used up as it happens:
  {"losePages": [3, 7]}       the table doesn't get these pages (1-based) the first time
  {"loseLastPage": true}      the table loses the last page and answers End with an empty missing list
  {"rejectStart": [50000]}    the table refuses an upload into these ids (0x34/5 straight after Start)
  {"rejectNextStart": true}   the table refuses the next upload, whatever its id
  {"ignorePlays": 2}          the table ignores the next 2 plays
  {"ignorePlaylist": true}    the table doesn't re-send its playlists after the next change
  {"stuck": true}             the table is half-way through an old init dump: it repeats 0x36/1 on every link
                              and never asks for a handshake, until something answers it
  {"dropLinkAtPage": 5}       the relay loses the table for 2 s when page 5 arrives
  {"resetAtPage": 5}          the table restarts its session when page 5 arrives
  {"noStorage": true}         the table answers the next Start with "not enough storage" (0x34/6)
  {"failAtPage": 5}           the table gives up on the upload at page 5 (0x34/5)
  {"ignoreStart": 2}          the table doesn't answer the next 2 Starts
  {"ignoreEnd": 1}            the table doesn't answer the next End
  {"neverReady": true}        the table's init dump never finishes (no 0x4F/1)             (stays until the file changes)
  {"silent": true}            the table links but never says anything                       (stays)
  {"dropHostDuringData": true} the relay's connection to the host drops part-way through a job's pattern data
  {"dropHostAfter": "begin"}  … right after the job's steps arrive ("begin") or its run message ("run")
  {"dropHostAtState": "running"} … when the job reaches that state (linking, handshake, running, done), unannounced
  {"loseResult": true}        … just as the job's result is sent, so the host never sees it
  {"loseTableData": true}     the result arrives without what the table said (those messages are lost)
  {"corruptData": true}       a byte of the pattern is stored wrong (the checksum catches it)
  {"tableAbsent": true}       the relay can't reach the table (off, out of range, or the phone app has it)    (stays)
  {"stallWifi": true}         while a job has the table, the relay drops its host and refuses connections
                              (not used up: stays until the file changes)

Usage: fake_relay.py --token TOKEN [--port 8766] [--stats stats.json] [--chunk 20] [--no-table] [--no-reask]
                     [--engine libdriftjob.dylib] [--faults faults.json]
Never connects to anything; only Python's standard library.
"""
import argparse
import asyncio
import ctypes
import json
import os
import queue
import signal
import struct
import sys
import threading
import time
import urllib.request

# ---- table packets (docs/protocol.md) ----

def packet(cmd, data=b"", ack=False):
    body = bytes([0x7B, len(data) + 4, (cmd | 0x80) if ack else cmd]) + bytes(data)
    return body + bytes([sum(body) & 0xFF])


def s(text):
    return text.encode() + b"\x00"


def u16(v):
    return struct.pack("<H", v)


def u16_array(values):
    return bytes([len(values)]) + b"".join(u16(v) for v in values)


CONFIRM = packet(0x50, ack=True)  # 7B 04 D0 4F


def parse_packets(buf):
    """Returns (packets, rest). Each packet is (cmd, ack, data)."""
    out = []
    i = 0
    while len(buf) - i >= 2:
        if buf[i] != 0x7B:
            i += 1
            continue
        n = buf[i + 1]
        if n < 4:
            i += 1
            continue
        if len(buf) - i < n:
            break
        raw = buf[i:i + n]
        total = sum(raw[:-1]) & 0xFF
        alt = (total - raw[2] + (raw[2] & 0x7F)) & 0xFF
        if raw[-1] in (total, alt):
            out.append((raw[2] & 0x7F, bool(raw[2] & 0x80), bytes(raw[3:-1])))
            i += n
        else:
            i += 1
    return out, buf[i:]


class Stats:
    def __init__(self, path):
        self.path = path
        self.d = {"handshakes": 0, "sessionsReady": 0, "sessionResets": 0, "confirmsReceived": 0,
                  "maxHostSilenceMs": 0, "uploadsStored": [], "uploadsMissing": 0, "plays": [], "forbidden": [],
                  "droppedBeforeHandshake": 0, "pagesPaced": 0, "hosts": 0, "linkDrops": 0, "events": []}

    def note(self, text):
        line = time.strftime("%H:%M:%S ") + text
        print(line, flush=True)
        self.d["events"] = (self.d["events"] + [line])[-60:]
        self.save()

    def save(self):
        if self.path:
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.d, f, indent=1)
            os.replace(tmp, self.path)


def cstring(data, at):
    """A NUL-terminated string at `at`: (text, index after it)."""
    end = data.index(0, at)
    return data[at:end].decode(errors="replace"), end + 1


class Faults:
    """Things to go wrong, from --faults FILE (see the top of this file). Entries are used up in memory."""

    def __init__(self, path):
        self.path = path
        self.mtime = None
        self.d = {}

    def load(self):
        if self.path:
            try:
                m = os.stat(self.path).st_mtime_ns
                if m != self.mtime:
                    self.mtime = m
                    self.d = json.load(open(self.path))
            except (OSError, ValueError):
                pass
        return self.d

    def get(self, key):
        return self.load().get(key)

    def flag(self, key):
        if self.load().get(key):
            self.d[key] = False
            return True
        return False

    def count(self, key):
        if self.load().get(key, 0) > 0:
            self.d[key] -= 1
            return True
        return False

    def item(self, key, value):
        if value in (self.load().get(key) or []):
            self.d[key].remove(value)
            return True
        return False

    def at(self, key, value):
        if value is not None and self.load().get(key) == value:
            self.d[key] = None
            return True
        return False


class FakeTable:
    """The table's side of one BLE link. `send` delivers notification bytes to the relay."""

    def __init__(self, stats, send, draw_seconds, reask=True, faults=None, drop_link=None):
        self.stats = stats
        self.send = send
        self.draw_seconds = draw_seconds
        self.faults = faults or Faults(None)
        self.drop_link = drop_link or (lambda: None)
        self.stuck = False
        self.playlists = {}
        self.current_playlist = ""
        self.random = False
        self.loop = False
        self.empty_missing = False
        # False: ask for a handshake (0x50/1) only once per link, never again after a session reset. The docs
        # suggest the table does re-ask; this checks the relay's fallback (relink after 8 s) if it doesn't.
        self.reask = reask
        self.asked_this_link = False
        self.rx = b""
        self.state = "idle"            # idle (no link) | waiting | dumping | ready
        self.last_host = time.monotonic()
        self.expect = None             # (kind, packet, tries, sent_at) while waiting for a reply in the dump
        self.dump = []
        self.stored = {1, 2, 3}
        self.upload = None             # [id, pages, received set, time of its last message]
        self.pattern = 0
        self.drawing_since = None
        self.task = None

    # link
    def link_up(self):
        self.begin_link()
        self.task = asyncio.get_running_loop().create_task(self.run())

    def begin_link(self):
        """The link is up; something calls tick() from now on (run(), or a test with its own clock)."""
        self.rx = b""
        self.asked_this_link = False
        self.last_host = time.monotonic()
        self.restart("link up")
        if self.faults.flag("stuck"):
            self.stuck = True
            self.stats.note("table: stuck half-way through an old init dump (fault)")
        if self.stuck:
            self.state = "stuck"
            self.last_ask = 0

    def link_down(self):
        self.state = "idle"
        if self.task:
            self.task.cancel()
            self.task = None

    def restart(self, why):
        if self.state in ("dumping", "ready"):
            self.stats.d["sessionResets"] += 1
            self.stats.note(f"table: session reset ({why})")
        self.state = "waiting"
        self.expect = None
        self.last_ask = 0

    async def run(self):
        try:
            while True:
                await asyncio.sleep(0.05)
                self.tick()
        except asyncio.CancelledError:
            pass

    def tick(self):
        now = time.monotonic()
        if self.faults.get("silent"):
            return
        silence = now - self.last_host
        if self.state in ("dumping", "ready") and silence > 2.0:
            self.restart(f"host silent {silence:.1f} s")
        if self.upload and now - self.upload[3] > 5.0:
            # Nothing for 5 s: the upload is given up, its file deleted, and whoever is listening is told.
            pid, self.upload = self.upload[0], None
            self.stored.discard(pid)
            self.stats.d["uploadsAbandoned"] = self.stats.d.get("uploadsAbandoned", 0) + 1
            self.stats.note(f"table: upload into {pid} abandoned after 5 s without a message")
            if self.state == "ready":
                self.send(packet(0x34, b"\x05" + u16(pid), ack=True))
        if self.state == "stuck" and now - self.last_ask >= 0.5:
            self.last_ask = now
            self.send(packet(0x36, b"\x01\x01"))   # 7B 06 36 01 01 B9, again and again
        if self.state == "waiting" and now - self.last_ask >= 2.0 and (self.reask or not self.asked_this_link):
            self.last_ask = now
            self.asked_this_link = True
            self.send(packet(0x50, b"\x01"))
        if self.state == "dumping":
            if self.expect is None:
                if self.dump:
                    kind, p = self.dump.pop(0)
                    self.expect = [kind, p, 1, now]
                    self.send(p)
                elif self.faults.get("neverReady"):
                    pass
                else:
                    self.state = "ready"
                    self.stats.d["sessionsReady"] += 1
                    self.stats.note("table: init complete; session ready")
                    self.send(packet(0x4F, b"\x01"))
                    self.next_state = now
            elif now - self.expect[3] > 0.5:
                if self.expect[2] >= 4:
                    self.restart("no reply to the init dump")
                else:
                    self.expect[2] += 1
                    self.expect[3] = now
                    self.send(self.expect[1])
        if self.state == "ready" and now >= self.next_state:
            self.next_state = now + 0.5
            self.send(self.state_packet(now))

    def state_packet(self, now):
        progress, status = 0, 0
        if self.pattern and self.drawing_since is not None:
            f = (now - self.drawing_since) / self.draw_seconds
            if f >= 1:
                self.drawing_since = None
                self.stats.note(f"table: finished pattern {self.pattern}")
                self.pattern = 0
            else:
                progress, status = int(f * 10000), 1
        data = (b"\x01" + bytes([60]) + s("Temp") + bytes([255, 255, 255]) + bytes([50]) + s(self.current_playlist)
                + u16(self.pattern) + u16(progress) + bytes([status, int(self.random), int(self.loop), 0, 0, 0]) + u16(0)
                + s("A_11_V0.7.12") + bytes([0, 0])
                + s("B_11_V0.3.3") + bytes([0, 0, 1]))
        return packet(0x35, data)

    # host → table
    def receive(self, data):
        self.rx += data
        packets, self.rx = parse_packets(self.rx)
        for cmd, ack, d in packets:
            now = time.monotonic()
            gap = (now - self.last_host) * 1000
            if self.state == "ready":
                self.stats.d["maxHostSilenceMs"] = max(self.stats.d["maxHostSilenceMs"], int(gap))
            self.last_host = now
            self.handle(cmd, ack, d)

    def handle(self, cmd, ack, d):
        action = d[0] if d else None
        if cmd == 0x15 or (cmd == 0x14 and action == 12):
            self.stats.d["forbidden"].append(f"{cmd:02x}/{action}")
            self.stats.note(f"table: FORBIDDEN command {cmd:02x}/{action} received")
            return
        if cmd == 0x50 and ack and not d:   # ConfirmData
            self.stats.d["confirmsReceived"] += 1
            if self.state == "stuck":
                # Answered at last: the old dump runs to its end, with no handshake.
                self.stuck = False
                self.stats.d["unstuck"] = self.stats.d.get("unstuck", 0) + 1
                self.stats.note("table: the old init dump was answered; finishing it")
                self.state = "dumping"
                self.dump = [("confirm", packet(0x33, b"\x03\x01" + u16_array(sorted(self.stored)))),
                             ("confirm", packet(0x36, b"\x02"))]
                self.expect = None
                return
            if self.expect and self.expect[0] == "confirm":
                self.expect = None
            return
        if self.state == "stuck":
            return
        if cmd == 0x50 and action == 2:
            if self.state == "waiting":
                self.stats.d["handshakes"] += 1
                self.stats.note("table: host confirmed the connection; sending init dump")
                self.state = "dumping"
                ids = sorted(self.stored)
                self.dump = [("confirm", p) for p in self.playlist_packets()]
                self.dump += [("confirm", packet(0x33, b"\x01")), ("confirm", packet(0x33, b"\x03\x01" + u16_array(ids))),
                             ("confirm", packet(0x33, b"\x02")), ("time", packet(0x32, b"\x02")),
                             ("confirm", packet(0x31, b"\x03\x01\x01" + s("Temp") + bytes([255, 255, 255])))]
            return
        if self.state not in ("dumping", "ready"):
            return
        if cmd == 0x12 and action == 2:      # the time, answering 0x32/2
            if self.expect and self.expect[0] == "time":
                self.expect = None
            self.send(packet(0x32, b"\x02", ack=True))   # the table acks it with the ack bit (b2 02)
            return
        if cmd == 0x13 and action == 1:
            pid, pages = struct.unpack("<HI", d[1:7])
            if self.faults.item("rejectStart", pid) or self.faults.flag("rejectNextStart"):
                self.stats.note(f"table: refusing an upload into {pid} (fault)")
                self.send(packet(0x34, b"\x05" + u16(pid), ack=True))
                return
            if self.faults.flag("noStorage"):
                self.send(packet(0x34, b"\x06" + u16(pid), ack=True))
                return
            if self.faults.count("ignoreStart"):
                return
            if self.upload:
                self.stats.note(f"table: Start for {pid} ignored (the upload into {self.upload[0]} is unfinished)")
                return
            self.upload = [pid, pages, set(), time.monotonic()]
            self.send(packet(0x34, b"\x02" + u16(pid), ack=True))
            return
        if cmd == 0x53 and action == 1:
            if self.upload:
                index = struct.unpack("<H", d[2:4])[0]
                self.upload[3] = time.monotonic()
                self.stats.d["pages"] = self.stats.d.get("pages", 0) + 1
                if self.faults.at("dropLinkAtPage", index):
                    self.stats.note(f"table: link lost at page {index} (fault)")
                    self.drop_link()
                    return
                if self.faults.at("resetAtPage", index):
                    self.restart(f"fault at page {index}")
                    return
                if self.faults.at("failAtPage", index):
                    self.stats.note(f"table: giving up on the upload at page {index} (fault)")
                    self.send(packet(0x34, b"\x05" + u16(self.upload[0]), ack=True))
                    self.upload = None
                    return
                if self.faults.item("losePages", index):
                    return
                if index == self.upload[1] and self.faults.flag("loseLastPage"):
                    self.empty_missing = True
                    return
                self.upload[2].add(index)
            return
        if cmd == 0x13 and action == 2:
            pid, pages = struct.unpack("<HI", d[1:7])
            if self.faults.count("ignoreEnd"):
                return
            if not self.upload or self.upload[0] != pid:
                self.send(packet(0x34, b"\x05" + u16(pid), ack=True))
                return
            self.upload[3] = time.monotonic()
            missing = [i for i in range(1, pages + 1) if i not in self.upload[2]]
            if missing:
                self.stats.d["uploadsMissing"] += 1
                if self.empty_missing:   # trailing pages lost: the real table sends an empty list
                    self.empty_missing = False
                    missing = []
                self.send(packet(0x34, b"\x01" + u16_array(missing[:20]), ack=True))
            else:
                self.stored.add(pid)
                self.stats.d["uploadsStored"].append(pid)
                self.stats.note(f"table: stored pattern {pid} ({pages} pages)")
                self.upload = None
                self.send(packet(0x34, b"\x03" + u16(pid), ack=True))
                self.send(packet(0x33, b"\x01"))
                self.send(packet(0x33, b"\x03\x01" + u16_array(sorted(self.stored))))
                self.send(packet(0x33, b"\x02"))
            return
        if cmd == 0x10 and action in (1, 3):   # create / replace a playlist
            at = 1
            if action == 3:
                old, at = cstring(d, at)
                self.playlists.pop(old, None)
            name, at = cstring(d, at)
            ids = list(struct.unpack_from(f"<{d[at]}H", d, at + 1))
            self.playlists[name] = ids
            self.stats.d["playlists"] = {k: v for k, v in self.playlists.items()}
            self.stats.note(f"table: playlist {name} = {ids}")
            self.send(CONFIRM)
            if not self.faults.flag("ignorePlaylist"):
                for p in self.playlist_packets():
                    self.send(p)
            return
        if cmd == 0x10 and action == 8:        # make a playlist current: its first id starts
            name, _ = cstring(d, 1)
            self.send(CONFIRM)
            if self.playlists.get(name):
                self.current_playlist = name
                self.pattern = self.playlists[name][0]
                self.drawing_since = time.monotonic()
                self.stats.d["plays"].append(self.pattern)
                self.stats.note(f"table: playlist {name} selected; drawing {self.pattern}")
            return
        if cmd == 0x14 and action in (10, 11):
            if action == 10:
                self.random = bool(d[1])
            else:
                self.loop = bool(d[1])
            self.stats.d["settings"] = (self.stats.d.get("settings", []) + [f"{cmd:02x}/{action}"])[-40:]
            self.send(CONFIRM)
            return
        if cmd == 0x14 and action == 1:
            pid = struct.unpack("<H", d[1:3])[0]
            self.send(CONFIRM)
            if self.faults.count("ignorePlays"):
                self.stats.note(f"table: ignoring a play of {pid} (fault)")
                return
            if pid in self.stored:
                self.pattern = pid
                self.drawing_since = time.monotonic()
                self.stats.d["plays"].append(pid)
                self.stats.note(f"table: drawing pattern {pid}")
            return
        # Everything else (settings, play/pause, power, …): a bare ConfirmData.
        self.stats.d["settings"] = (self.stats.d.get("settings", []) + [f"{cmd:02x}/{action}"])[-40:]
        self.send(CONFIRM)

    def playlist_packets(self):
        lists = b"".join(s(name) + u16_array(ids) for name, ids in self.playlists.items())
        return [packet(0x30, b"\x01"), packet(0x30, b"\x03\x01" + bytes([len(self.playlists)]) + lists), packet(0x30, b"\x02")]


class JobEngine:
    """The firmware's job engine (relay/firmware/main/job.c, built as a shared library), run the way the relay
    runs it: messages from the host go in on the network side, and the job itself runs on a thread of its own."""

    def __init__(self, path, relay, loop):
        self.relay = relay
        self.loop = loop
        self.lib = ctypes.CDLL(path)
        self.blob = bytearray()
        self.rx = queue.Queue()
        self.wake = threading.Event()
        u8p = ctypes.POINTER(ctypes.c_uint8)
        kinds = [("now_ms", ctypes.CFUNCTYPE(ctypes.c_int64), self.now_ms),
                 ("link_up", ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_int), self.link_up),
                 ("link_down", ctypes.CFUNCTYPE(None, ctypes.c_bool), self.link_down),
                 ("write", ctypes.CFUNCTYPE(ctypes.c_bool, u8p, ctypes.c_size_t), self.write),
                 ("recv", ctypes.CFUNCTYPE(ctypes.c_int, u8p, ctypes.c_size_t, ctypes.c_int), self.recv),
                 ("rssi", ctypes.CFUNCTYPE(ctypes.c_int), lambda: -58),
                 ("blob_begin", ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_uint32), self.blob_begin),
                 ("blob_write", ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_uint32, u8p, ctypes.c_size_t), self.blob_write),
                 ("blob_read", ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_uint32, u8p, ctypes.c_size_t), self.blob_read),
                 ("emit", ctypes.CFUNCTYPE(None, ctypes.c_uint8, ctypes.c_void_p, ctypes.c_size_t), self.emit),
                 ("log", ctypes.CFUNCTYPE(None, ctypes.c_char_p), self.log)]

        class IO(ctypes.Structure):
            _fields_ = [(name, kind) for name, kind, _ in kinds]

        self.callbacks = [kind(fn) for _, kind, fn in kinds]   # kept alive for as long as the library has them
        self.io = IO(*self.callbacks)
        self.lib.job_frame.argtypes = [ctypes.c_uint8, ctypes.c_char_p, ctypes.c_size_t]
        self.lib.job_frame.restype = ctypes.c_bool
        self.lib.job_busy.restype = ctypes.c_bool
        self.lib.job_status_json.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        self.lib.job_init(ctypes.byref(self.io))
        threading.Thread(target=self.worker, daemon=True).start()

    # network side (the asyncio thread)
    def frame(self, kind, payload):
        if self.lib.job_frame(kind, payload, len(payload)):
            self.wake.set()
        self.relay.dirty = True

    def busy(self):
        return bool(self.lib.job_busy())

    def status(self):
        buf = ctypes.create_string_buffer(200)
        n = self.lib.job_status_json(buf, 200)
        return json.loads("{" + buf.raw[:n].decode() + "}").get("job") if n > 0 else None

    # the job's thread
    def worker(self):
        while True:
            self.wake.wait()
            self.wake.clear()
            self.lib.job_execute()
            self.loop.call_soon_threadsafe(setattr, self.relay, "dirty", True)

    def now_ms(self):
        return int(time.monotonic() * 1000)

    def link_up(self, timeout_ms):
        while not self.rx.empty():
            self.rx.get_nowait()
        gen = self.relay.link_gen
        self.relay.job_active = True
        if self.relay.link == "linked":
            self.relay.job_relink = True   # a fresh link, with its handshake
        deadline = time.monotonic() + timeout_ms / 1000
        while time.monotonic() < deadline:
            if self.relay.link == "linked" and not self.relay.job_relink and self.relay.link_gen != gen:
                return True
            time.sleep(0.02)
        return False

    def link_down(self, done):
        if done:
            self.relay.job_active = False
            return
        if self.relay.link != "linked":
            return
        self.relay.job_relink = True
        for _ in range(150):
            if self.relay.link != "linked":
                break
            time.sleep(0.02)

    def write(self, data, n):
        if self.relay.link != "linked":
            return False
        self.loop.call_soon_threadsafe(self.relay.job_write, bytes(data[:n]))
        return True

    def recv(self, buf, size, timeout_ms):
        try:
            data = self.rx.get(timeout=max(timeout_ms, 1) / 1000)
        except queue.Empty:
            return 0 if self.relay.link == "linked" else -1
        data = data[:size]
        ctypes.memmove(buf, data, len(data))
        return len(data)

    def blob_begin(self, size):
        self.blob = bytearray(size)
        return None

    def blob_write(self, offset, data, n):
        self.blob[offset:offset + n] = bytes(data[:n])
        if n and self.relay.faults.flag("corruptData"):
            self.blob[offset] ^= 0x40
            self.loop.call_soon_threadsafe(self.relay.stats.note, "relay: a byte of the pattern stored wrong (fault)")
        return True

    def blob_read(self, offset, data, n):
        if offset + n > len(self.blob):
            return False
        ctypes.memmove(data, bytes(self.blob[offset:offset + n]), n)
        return True

    def emit(self, kind, payload, n):
        self.loop.call_soon_threadsafe(self.relay.job_emit, kind, ctypes.string_at(payload, n))

    def log(self, line):
        self.loop.call_soon_threadsafe(self.relay.job_log, line.decode(errors="replace"))


class FakeRelay:
    def __init__(self, args, stats):
        self.args = args
        self.stats = stats
        self.token = args.token
        self.client = None           # (reader, writer)
        self.gate_open = False
        self.released = False
        self.link = "off"
        self.table_present = not args.no_table
        self.faults = Faults(args.faults)
        self.table = FakeTable(stats, self.from_table, args.draw_seconds, reask=not args.no_reask, faults=self.faults,
                               drop_link=lambda: asyncio.get_running_loop().create_task(self.drop_link(2)))
        self.engine = None           # JobEngine, with --engine
        self.job_active = False      # a job has the table
        self.job_relink = False      # the job wants a fresh link
        self.link_gen = 0
        self.gate_waiting_since = None
        self.rx = b""
        self.dirty = True
        self.writes = asyncio.Queue()
        self.last_page = 0.0
        self.firmware = "0.1.0-fake"

    def start_engine(self, path):
        self.engine = JobEngine(path, self, asyncio.get_running_loop())
        self.firmware = "0.2.0-fake"
        self.stats.note("relay: jobs on (the firmware's engine)")

    def job_write(self, data):
        if self.link == "linked":
            self.stats.d["jobWrites"] = self.stats.d.get("jobWrites", 0) + 1
            self.table.receive(data)

    def job_log(self, line):
        self.stats.note(f"relay: {line}")
        self.send(0x40, line)

    def cut_host(self, why):
        """The host's connection goes, as when the relay's Wi-Fi does: nothing more reaches it."""
        self.stats.d["hostCuts"] = self.stats.d.get("hostCuts", 0) + 1
        self.stats.note(f"relay: host connection lost {why} (fault)")
        if self.client:
            self.client[1].close()
            self.client = None

    def job_emit(self, kind, payload):
        """A message from the job engine for the host, with the faults that lose it."""
        if kind == 0x58:
            state = json.loads(payload).get("state")
            if self.faults.at("dropHostAtState", state):
                self.cut_host(f"as the job reached {state}")
                return
        if kind in (0x59, 0x5A) and self.faults.flag("loseResult"):
            self.cut_host("as the job's result was sent")
            return
        if kind == 0x5A and self.faults.get("loseTableData"):
            self.stats.d["tableDataLost"] = self.stats.d.get("tableDataLost", 0) + 1
            return
        if kind == 0x59 and self.faults.get("loseTableData"):
            self.faults.d["loseTableData"] = False   # one result's worth
        self.send(kind, payload)

    def stalled(self):
        """The "stallWifi" fault: no network while a job has the table."""
        return bool(self.engine and self.engine.busy() and self.faults.get("stallWifi"))

    # ---- framing ----
    def frame(self, kind, payload):
        if isinstance(payload, str):
            payload = payload.encode()
        return bytes([kind]) + struct.pack("<H", len(payload)) + payload

    def send(self, kind, payload):
        if self.client:
            self.client[1].write(self.frame(kind, payload))

    def send_json(self, kind, obj):
        self.send(kind, json.dumps(obj, separators=(",", ":")))

    def status(self):
        return {"link": self.link, "released": self.released, "hold": True,
                "table": {"name": "KS0000000001", "address": "aa:bb:cc:dd:ee:01", "addrType": 0} if self.table_present else None,
                "rssi": -58 if self.link == "linked" else None, "mtu": 247 if self.link == "linked" else 0,
                "maxWrite": 244 if self.link == "linked" else 0, "gate": "open" if self.gate_open else "waiting",
                "host": self.client is not None, "wifiRssi": -49, "ip": "127.0.0.1", "name": "drifted-relay-fake01",
                "uptime": int(time.monotonic()), "firmware": self.firmware, "heap": 0, "ota": False,
                "proto": 2 if self.engine else 1, "job": self.engine.status() if self.engine else None,
                "stats": {"handshakeRequests": self.stats.d["handshakes"],
                          "droppedBeforeHandshake": self.stats.d["droppedBeforeHandshake"],
                          "pagesPaced": self.stats.d["pagesPaced"]}}

    def set_link(self, link):
        if link != self.link:
            self.link = link
            self.dirty = True
            self.stats.note(f"relay: link {link}")

    # ---- table side ----
    def from_table(self, data):
        if self.job_active:   # the job listens to the table; the host gets what it said afterwards
            step = self.args.chunk or len(data)
            for i in range(0, len(data), step):
                self.engine.rx.put(data[i:i + step])
            return
        # The gate opens on the table's handshake request, before the host can answer it.
        for cmd, ack, d in parse_packets(data)[0]:
            if cmd == 0x50 and not ack and d[:1] == b"\x01" and self.client and not self.gate_open:
                self.gate_open = True
                self.dirty = True
                self.send(0x40, "table asked for a handshake; passing the host's writes on")
        if self.dirty:
            self.flush_status()
        step = self.args.chunk or len(data)
        for i in range(0, len(data), step):   # BLE notifications arrive in pieces
            self.send(0x10, data[i:i + step])

    def flush_status(self):
        self.dirty = False
        self.send_json(0x20, self.status())

    async def link_loop(self):
        while True:
            if self.job_relink and self.link == "linked":
                self.table.link_down()
                self.set_link("waiting")
                await asyncio.sleep(0.3)
            self.job_relink = False
            # Like the firmware: a host waiting 8 s for a handshake request the table never sends gets a fresh link.
            if self.client and self.link == "linked" and not self.gate_open and not self.job_active:
                if self.gate_waiting_since is None:
                    self.gate_waiting_since = time.monotonic()
                elif time.monotonic() - self.gate_waiting_since > 8:
                    self.stats.d["gateTimeouts"] = self.stats.d.get("gateTimeouts", 0) + 1
                    self.stats.note("relay: no handshake request from the table for 8 s; relinking")
                    self.send(0x40, "no handshake request from the table for 8 s; reconnecting so it starts a fresh session")
                    self.table.link_down()
                    self.set_link("waiting")
                    self.flush_status()
                    self.gate_waiting_since = None
                    await asyncio.sleep(0.5)
            else:
                self.gate_waiting_since = None
            present = self.table_present and not self.faults.get("tableAbsent")
            want = present and (self.job_active or not self.released)
            if want and self.link != "linked":
                self.set_link("connecting")
                await asyncio.sleep(0.3)
                if self.table_present and not self.faults.get("tableAbsent") and (self.job_active or not self.released):
                    self.link_gen += 1
                    self.set_link("linked")
                    self.gate_open = False
                    self.flush_status()
                    self.table.link_up()
            elif not want and self.link == "linked":
                self.table.link_down()
                self.gate_open = False
                self.set_link("released" if self.released else "waiting")
            elif not want and self.link not in ("released", "waiting"):
                self.set_link("released" if self.released else "waiting")
            await asyncio.sleep(0.1)

    async def drop_link(self, seconds=3):
        self.stats.d["linkDrops"] += 1
        self.stats.note(f"relay: dropping the table link for {seconds} s (SIGUSR1)")
        self.table_present = False
        await asyncio.sleep(seconds)
        self.table_present = True

    async def writer_loop(self):
        while True:
            data = await self.writes.get()
            if self.job_active or self.link != "linked" or not self.gate_open:
                self.stats.d["droppedBeforeHandshake"] += 1
                continue
            if len(data) >= 4 and data[0] == 0x7B and (data[2] & 0x7F) == 0x53:   # pace pages like the firmware
                gap = time.monotonic() - self.last_page
                if gap < 0.08:
                    self.stats.d["pagesPaced"] += 1
                    await asyncio.sleep(0.08 - gap)
                self.last_page = time.monotonic()
            self.table.receive(data)

    async def status_loop(self):
        last_save = 0
        while True:
            await asyncio.sleep(0.2)
            if time.monotonic() - last_save > 1:
                last_save = time.monotonic()
                self.stats.save()
            if self.client and self.stalled():
                self.stats.d["stalls"] = self.stats.d.get("stalls", 0) + 1
                self.stats.note("relay: no Wi-Fi while the job has the table (fault); the host is cut off")
                self.client[1].close()
            if self.client and (self.dirty or time.monotonic() - getattr(self, "last_status", 0) > 5):
                self.last_status = time.monotonic()
                self.flush_status()

    # ---- host side ----
    async def handle_client(self, reader, writer):
        peer = writer.get_extra_info("peername")
        if self.stalled():
            writer.close()
            return
        try:
            head = await asyncio.wait_for(reader.readexactly(3), 5)
            kind, n = head[0], struct.unpack("<H", head[1:3])[0]
            body = await asyncio.wait_for(reader.readexactly(n), 5)
        except (asyncio.TimeoutError, asyncio.IncompleteReadError):
            writer.write(self.frame(0x03, '{"error":"no hello within 5 s"}'))
            writer.close()
            return
        if kind != 0x01 or body[1:].decode(errors="replace") != self.token:
            self.stats.note(f"relay: refused {peer} (wrong token)")
            writer.write(self.frame(0x03, '{"error":"wrong token"}'))
            await writer.drain()
            writer.close()
            return
        if self.client:
            old = self.client[1]
            old.write(self.frame(0x03, '{"error":"another host connected"}'))
            old.close()
        self.client = (reader, writer)
        self.stats.d["hosts"] += 1
        observe = bool(body[0] & 1)
        self.stats.note(f"relay: host {peer} connected{' (observing)' if observe else ''}")
        writer.write(self.frame(0x02, json.dumps({"proto": 2 if self.engine else 1, "firmware": self.firmware,
                                                   "name": "drifted-relay-fake01"})))
        self.gate_open = False
        self.gate_waiting_since = None
        if not observe:
            self.released = False
        self.flush_status()
        buf = b""
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                buf += data
                while len(buf) >= 3:
                    kind, n = buf[0], struct.unpack("<H", buf[1:3])[0]
                    if len(buf) < 3 + n:
                        break
                    payload, buf = buf[3:3 + n], buf[3 + n:]
                    if kind == 0x11:
                        self.writes.put_nowait(payload)
                    elif kind == 0x30:
                        await self.command(payload.decode(errors="replace").strip())
                    elif 0x50 <= kind <= 0x53 and self.engine:
                        self.engine.frame(kind, payload)
                        if kind == 0x51 and self.faults.flag("dropHostDuringData"):
                            self.stats.d["dataDrops"] = self.stats.d.get("dataDrops", 0) + 1
                            self.stats.note("relay: host connection lost part-way through the pattern data (fault)")
                            writer.close()
                            buf = b""
                            break
                        if self.faults.at("dropHostAfter", {0x50: "begin", 0x52: "run"}.get(kind)):
                            self.cut_host(f"right after the job's {'steps' if kind == 0x50 else 'run message'} arrived")
                            buf = b""
                            break
                await writer.drain()
        except (ConnectionError, asyncio.CancelledError):
            pass
        finally:
            if self.client and self.client[1] is writer:
                self.client = None
                self.gate_open = False
                self.stats.note("relay: host disconnected")
            writer.close()

    async def command(self, line):
        word, _, arg = line.partition(" ")
        result = {"command": word, "ok": True, "message": ""}
        if word == "scan":
            await asyncio.sleep(1)
            tables = {"tables": [{"name": "KS0000000001", "address": "aa:bb:cc:dd:ee:01", "addrType": 0, "rssi": -58}]}
            self.send_json(0x21, tables)
            result.update(tables)
        elif word == "release":
            self.released = True
        elif word == "connect":
            self.released = False
            self.gate_open = False
            self.gate_waiting_since = None
            self.dirty = True
        elif word in ("select", "forget", "hold", "status", "version"):
            result["message"] = f"{word} {arg}".strip()
            self.dirty = True
        elif word == "ota":
            # Like the firmware: download the image, answer, then restart (a new version, the host dropped).
            result["message"] = "downloading; the relay restarts into the new firmware when it's written"
            asyncio.get_running_loop().create_task(self.fake_ota(arg))
        else:
            result.update(ok=False, message=f"{word} isn't supported by the fake relay")
        self.stats.note(f"relay: command {line!r}")
        self.send_json(0x31, result)

    async def fake_ota(self, url):
        loop = asyncio.get_running_loop()
        try:
            data = await loop.run_in_executor(None, lambda: urllib.request.urlopen(url, timeout=30).read())
        except Exception as e:  # noqa: BLE001 - report any download failure like the firmware does
            self.send_json(0x31, {"command": "ota", "ok": False, "message": str(e)})
            return
        self.stats.d["ota"] = len(data)
        self.stats.note(f"relay: downloaded {len(data)} bytes of firmware; restarting")
        self.send_json(0x31, {"command": "ota", "ok": True, "message": "update written; restarting"})
        await asyncio.sleep(0.5)
        self.firmware = self.firmware.split("+")[0] + "+ota"
        self.kick_host()
        await self.drop_link(2)

    def kick_host(self):
        if self.client:
            self.stats.note("relay: closing the host connection (SIGUSR2)")
            self.client[1].close()


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--token", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--stats", help="write a JSON summary here")
    ap.add_argument("--chunk", type=int, default=20, help="split table notifications into pieces this big (0: whole)")
    ap.add_argument("--draw-seconds", type=float, default=20)
    ap.add_argument("--no-table", action="store_true", help="simulate a relay that can't find the table")
    ap.add_argument("--no-reask", action="store_true",
                    help="the table asks for a handshake once per link only (exercises the relay's 8 s relink)")
    ap.add_argument("--engine", help="the firmware's job engine as a shared library: the relay then runs jobs (proto 2)")
    ap.add_argument("--faults", help="a JSON file of things to go wrong (see the top of this file)")
    args = ap.parse_args()
    stats = Stats(args.stats)
    relay = FakeRelay(args, stats)
    loop = asyncio.get_running_loop()
    if args.engine:
        relay.start_engine(args.engine)
    loop.add_signal_handler(signal.SIGUSR1, lambda: loop.create_task(relay.drop_link()))
    loop.add_signal_handler(signal.SIGUSR2, relay.kick_host)
    server = await asyncio.start_server(relay.handle_client, args.host, args.port)
    stats.note(f"fake relay listening on {args.host}:{args.port}")
    await asyncio.gather(server.serve_forever(), relay.link_loop(), relay.writer_loop(), relay.status_loop())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
