#!/usr/bin/env python3
"""Recovery tests for the relay's job engine (relay/firmware/main/job.c), with a failure at every step.

The engine is the code that runs on the relay while it has the table to itself, so it has to get through
anything alone. This runs it (built as a shared library for this computer) against the simulated table from
fake_relay.py on a clock of its own, so thousands of runs take seconds, and breaks one thing at a time:

- the Bluetooth link drops at each write the relay makes, and after each message the table sends;
- the table restarts its session at each write;
- each single write, and each single table message, is lost;
- two and three link drops at random points in one job;
- the table isn't there, turns up late, never asks for a handshake, never finishes its start-up lists, is
  stuck in an old handshake, refuses or abandons uploads, runs out of storage, ignores Start, End or play,
  loses pages, doesn't confirm a playlist.

Every run must end (no hangs), within a bounded time, with a result that matches what the table ended up
with: "ok" only if the pattern is stored and drawing, and a failure only with a reason and a stage.

Then relay/tools/fuzz-job-engine.c: hundreds of thousands of random and half-broken jobs and table bytes, with
the engine built under the address and undefined-behaviour sanitizers.

Usage: relay/tools/test-job-engine.py [--quick] [--seed N]      (needs a C compiler; no hardware, no network)
"""
import argparse
import ctypes
import importlib.util
import json
import os
import random
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fake_relay", os.path.join(HERE, "fake_relay.py"))
fr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fr)


class Clock:
    """Stands in for the time module inside fake_relay: time moves only when the test says so."""
    now = 1000.0

    def monotonic(self):
        return self.now

    def strftime(self, *_):
        return ""


clock = Clock()
fr.time = clock


class QuietStats(fr.Stats):
    def __init__(self):
        super().__init__(None)

    def note(self, text):
        self.d["events"] = (self.d["events"] + [text])[-200:]


def packet(cmd, data=b""):
    return fr.packet(cmd, data)


def op(kind, body=b"", fail=0xFF):
    return bytes([kind, fail]) + struct.pack("<H", len(body)) + body


def points(n):
    return b"".join(struct.pack("<HH", (i * 37) % 60000, 20000 + i) for i in range(n))


class World:
    """One job run: the engine, a table, and the things that can go wrong between them."""

    def __init__(self, lib):
        self.lib = lib
        self.stats = QuietStats()
        self.faults = fr.Faults(None)
        self.table = fr.FakeTable(self.stats, self.from_table, draw_seconds=600, faults=self.faults, drop_link=self.drop)
        self.linked = False
        self.out = []            # packets from the table, not yet read by the relay
        self.partial = b""
        self.blob = bytearray()
        self.frames = []
        self.log = []
        self.writes = self.notifies = self.link_ups = 0
        # What goes wrong, by the index of the write or table message it happens at.
        self.drop_at_write, self.reset_at_write, self.lose_write = set(), set(), set()
        self.drop_at_notify, self.lose_notify = set(), set()
        self.absent_until = 0.0
        self.chunk = 20
        self.write_kinds = []

    # the table's side
    def from_table(self, data):
        self.out.append(bytes(data))

    def drop(self):
        if self.linked:
            self.linked = False
            self.table.link_down()
            self.out, self.partial = [], b""

    # the engine's callbacks
    def now_ms(self):
        return int(clock.now * 1000)

    def link_up(self, timeout_ms):
        self.link_ups += 1
        if self.linked:
            self.drop()
        if self.absent_until > clock.now:
            if self.absent_until - clock.now > timeout_ms / 1000:
                clock.now += timeout_ms / 1000
                return False
            clock.now = self.absent_until
        clock.now += 0.3
        self.linked = True
        self.out, self.partial = [], b""
        self.table.begin_link()
        return True

    def link_down(self, done):
        self.drop()
        clock.now += 0.05

    def write(self, data, n):
        if not self.linked:
            return False
        i = self.writes
        self.writes += 1
        raw = bytes(data[:n])
        self.write_kinds.append((raw[2] & 0x7F, raw[3] if n > 4 else None))
        if i in self.drop_at_write:
            self.drop()
            return False
        if i in self.reset_at_write:
            self.table.restart("fault")
            return True
        if i in self.lose_write:
            return True
        self.table.receive(raw)
        return True

    def recv(self, buf, size, timeout_ms):
        deadline = clock.now + timeout_ms / 1000
        while True:
            if not self.linked:
                return -1
            if not self.partial and self.out:
                data = self.out.pop(0)
                i = self.notifies
                self.notifies += 1
                if i in self.drop_at_notify:
                    self.drop()
                    return -1
                if i not in self.lose_notify:
                    self.partial = data
            if self.partial:
                piece, self.partial = self.partial[:min(size, self.chunk)], self.partial[min(size, self.chunk):]
                ctypes.memmove(buf, piece, len(piece))
                return len(piece)
            if clock.now >= deadline:
                return 0
            clock.now += 0.005
            self.table.tick()

    def blob_begin(self, size):
        self.blob = bytearray(size)
        return None

    def blob_write(self, offset, data, n):
        self.blob[offset:offset + n] = bytes(data[:n])
        return True

    def blob_read(self, offset, data, n):
        if offset + n > len(self.blob):
            return False
        ctypes.memmove(data, bytes(self.blob[offset:offset + n]), n)
        return True

    def emit(self, kind, payload, n):
        self.frames.append((kind, ctypes.string_at(payload, n)))

    def on_log(self, line):
        self.log.append(line.decode(errors="replace"))

    def run(self, ops, blob=b"", linger=1500, job_id=7):
        u8p = ctypes.POINTER(ctypes.c_uint8)
        kinds = [(ctypes.CFUNCTYPE(ctypes.c_int64), self.now_ms), (ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_int), self.link_up),
                 (ctypes.CFUNCTYPE(None, ctypes.c_bool), self.link_down), (ctypes.CFUNCTYPE(ctypes.c_bool, u8p, ctypes.c_size_t), self.write),
                 (ctypes.CFUNCTYPE(ctypes.c_int, u8p, ctypes.c_size_t, ctypes.c_int), self.recv), (ctypes.CFUNCTYPE(ctypes.c_int), lambda: -50),
                 (ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_uint32), self.blob_begin),
                 (ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_uint32, u8p, ctypes.c_size_t), self.blob_write),
                 (ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_uint32, u8p, ctypes.c_size_t), self.blob_read),
                 (ctypes.CFUNCTYPE(None, ctypes.c_uint8, ctypes.c_void_p, ctypes.c_size_t), self.emit),
                 (ctypes.CFUNCTYPE(None, ctypes.c_char_p), self.on_log)]

        class IO(ctypes.Structure):
            _fields_ = [(f"f{i}", k) for i, (k, _) in enumerate(kinds)]

        self.keep = [k(f) for k, f in kinds]
        self.lib.job_init(ctypes.byref(IO(*self.keep)))
        begin = struct.pack("<IIHIIB", job_id, 1_800_000_000, linger, len(blob), zlib.crc32(blob), len(ops)) + b"".join(ops)
        frame = lambda kind, p: self.lib.job_frame(kind, p, len(p))
        frame(0x50, begin)
        states = [json.loads(p) for k, p in self.frames if k == 0x58]
        if states[-1]["state"] == "refused":
            return {"refused": states[-1]}
        for off in range(0, len(blob), 3000):
            frame(0x51, struct.pack("<II", job_id, off) + blob[off:off + 3000])
        started = clock.now
        if not frame(0x52, struct.pack("<I", job_id)):
            return {"refused": [json.loads(p) for k, p in self.frames if k == 0x58][-1]}
        self.lib.job_execute()
        self.seconds = clock.now - started
        results = [json.loads(p) for k, p in self.frames if k == 0x59]
        assert len(results) == 1, f"{len(results)} results"
        r = results[0]
        table_bytes = b"".join(p[4:] for k, p in self.frames if k == 0x5A)
        assert len(table_bytes) == r["tableBytes"], "what the table said doesn't add up to tableBytes"
        assert [json.loads(p) for k, p in self.frames if k == 0x58][-1]["state"] == "done"
        r["table"] = fr.parse_packets(table_bytes)[0]
        return r


# ---- The jobs ----

N_POINTS = 290   # 8 pages, the last one short


def show_job():
    """Power on, upload (two slots to choose from), play what was uploaded: what `show` sends."""
    return [op(1, packet(0x14, bytes([16, 1]))),
            op(4, struct.pack("<IIB", N_POINTS, 0, 2) + struct.pack("<HH", 50000, 50001)),
            op(3, struct.pack("<H", 0))], points(N_POINTS)


def save_job():
    """One upload into one id, nothing else: what saving a pattern sends. No second slot to fall back to."""
    return [op(4, struct.pack("<IIB", N_POINTS, 0, 1) + struct.pack("<H", 50100))], points(N_POINTS)


def playlist_job(first=2, ids=(2, 3, 1)):
    """The table playlist: write, wait for the table's list, random off, loop on, select, check it started;
    play directly if the list isn't confirmed or selecting doesn't start it."""
    name = b"drifted_mix\x00"
    listed = name + fr.u16_array(list(ids))
    return [op(1, packet(0x10, b"\x01" + listed)),
            op(2, struct.pack("<HBBBB", 20000, 1, 0x30, 3, len(listed)) + listed, fail=7),
            op(1, packet(0x14, bytes([10, 0]))),
            op(1, packet(0x14, bytes([11, 1]))),
            op(1, packet(0x10, b"\x08" + name)),
            op(2, struct.pack("<HBH", 6000, 2, first), fail=7),
            op(6),
            op(3, struct.pack("<H", first))], b""


def check(name, world, r, expect_ok=True, playing=None, stored=None, limit=420):
    """What every run must satisfy. Returns a description of what's wrong, or None."""
    t = world.table
    where = f"{name}: "
    if world.seconds > limit:
        return where + f"took {world.seconds:.0f} s of the job's time (limit {limit})"
    if world.linked:
        return where + "the relay still held the table after the job"
    if r["ok"] != expect_ok:
        return where + (f"failed: {r['error']} (stage {r['stage']})" if expect_ok else "reported ok")
    if not r["ok"] and (not r["error"] or r["stage"] not in ("link", "handshake", "step")):
        return where + f"failed without a reason or stage: {r}"
    if r["ok"]:
        if stored == "uploaded":   # whichever slot the upload ended up in (a second one, if the first was refused)
            stored = playing = next(o[2] for o in r["ops"] if o[2] >= 50000)
        if stored is not None and stored not in t.stored:
            return where + f"reported ok but pattern {stored} isn't stored (table has {sorted(t.stored)})"
        if playing is not None and not (t.pattern == playing and t.drawing_since is not None):
            return where + f"reported ok but the table is drawing {t.pattern}, not {playing}"
    if world.stats.d["forbidden"]:
        return where + f"forbidden command sent: {world.stats.d['forbidden']}"
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true", help="fewer random combinations")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="drifted-job-engine.")
    lib_path = os.path.join(tmp, "libdriftjob.dylib")
    subprocess.run(["cc", "-shared", "-O1", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", "-o", lib_path,
                    os.path.join(HERE, "..", "firmware", "main", "job.c")], check=True)
    lib = ctypes.CDLL(lib_path)
    lib.job_frame.argtypes = [ctypes.c_uint8, ctypes.c_char_p, ctypes.c_size_t]
    lib.job_frame.restype = ctypes.c_bool
    rng = random.Random(args.seed)
    failures, runs = [], 0

    def run(name, job, setup=None, **expect):
        nonlocal runs
        runs += 1
        w = World(lib)
        if setup:
            setup(w)
        ops, blob = job
        try:
            r = w.run(ops, blob)
            problem = "refused: " + str(r["refused"]) if "refused" in r else check(name, w, r, **expect)
        except AssertionError as e:
            problem, r = f"{name}: {e}", {}
        if problem:
            failures.append(problem)
            if len(failures) <= 12:
                print(f"  ✘ {problem}\n      log: {' | '.join(w.log[-6:])}")
        return w, r

    def section(title, before):
        bad = len(failures) - before
        print(f"  {'✓' if not bad else '✘'} {title}" + (f" ({bad} failed)" if bad else ""))

    show_ok = dict(playing="uploaded", stored="uploaded")

    print("Nothing wrong…")
    n = len(failures)
    base, r = run("show", show_job(), playing=50000, stored=50000)
    W, M = base.writes, base.notifies
    assert r["ops"][1][2] == 50000 and r["links"] == 1 and r["restarts"] == 0, r
    names = [f"{c:02x}/{a}" for c, a in base.write_kinds]
    pbase, _ = run("playlist", playlist_job(), playing=2)
    PW, PM = pbase.writes, pbase.notifies
    assert pbase.table.current_playlist == "drifted_mix" and pbase.table.loop and not pbase.table.random
    cbase, r = run("check-in", ([], b""))
    assert any(c == 0x33 for c, _, _ in r["table"]) and any(c == 0x35 for c, _, _ in r["table"]), "the check-in brought no lists or state"
    section(f"show ({W} writes to the table, {M} messages from it), table playlist ({PW}, {PM}), check-in ({cbase.writes}, {cbase.notifies})", n)

    print("The Bluetooth link drops…")
    n = len(failures)
    for i in range(W + 1):
        run(f"show, link lost at write {i} ({names[i] if i < W else 'end'})", show_job(), lambda w, i=i: w.drop_at_write.add(i), **show_ok)
    section(f"at each of the relay's {W} writes during show: linked again, stored and drawing every time", n)
    n = len(failures)
    for i in range(M + 1):
        run(f"show, link lost after table message {i}", show_job(), lambda w, i=i: w.drop_at_notify.add(i), **show_ok)
    section(f"after each of the table's {M} messages during show", n)
    n = len(failures)
    for i in range(PW + 1):
        run(f"playlist, link lost at write {i}", playlist_job(), lambda w, i=i: w.drop_at_write.add(i), playing=2)
    for i in range(PM + 1):
        run(f"playlist, link lost after table message {i}", playlist_job(), lambda w, i=i: w.drop_at_notify.add(i), playing=2)
    for i in range(cbase.writes + 1):
        run(f"check-in, link lost at write {i}", ([], b""), lambda w, i=i: w.drop_at_write.add(i))
    section(f"at every write and message of the table playlist and of a check-in", n)
    n = len(failures)
    sbase, _ = run("save", save_job(), stored=50100)
    for i in range(sbase.writes + 1):
        run(f"save, link lost at write {i}", save_job(), lambda w, i=i: w.drop_at_write.add(i), stored=50100)
    for i in range(sbase.notifies + 1):
        run(f"save, link lost after table message {i}", save_job(), lambda w, i=i: w.drop_at_notify.add(i), stored=50100)
    for i in range(sbase.writes):
        run(f"save, session reset at write {i}", save_job(), lambda w, i=i: w.reset_at_write.add(i), stored=50100)
    section("at every write and message of a save (one slot only: it waits out the table's 5 s and uses it again)", n)

    print("The table restarts its session…")
    n = len(failures)
    for i in range(W):
        run(f"show, session reset at write {i} ({names[i]})", show_job(), lambda w, i=i: w.reset_at_write.add(i), **show_ok)
    for i in range(PW):
        run(f"playlist, session reset at write {i}", playlist_job(), lambda w, i=i: w.reset_at_write.add(i), playing=2)
    section(f"at each write of show and of the table playlist: handshake again, step again", n)

    print("A single message is lost…")
    n = len(failures)
    for i in range(W):
        run(f"show, write {i} ({names[i]}) never arrives", show_job(), lambda w, i=i: w.lose_write.add(i), **show_ok)
    section("each write of show in turn (handshake answer, Start, every page, End, play, every acknowledgement)", n)
    n = len(failures)
    for i in range(M):
        run(f"show, table message {i} never arrives", show_job(), lambda w, i=i: w.lose_notify.add(i), **show_ok)
    section("each of the table's messages in turn (handshake request, lists, upload started, missing pages, stored, state)", n)
    n = len(failures)
    for i in range(PW):
        run(f"playlist, write {i} never arrives", playlist_job(), lambda w, i=i: w.lose_write.add(i), playing=2)
    for i in range(PM):
        run(f"playlist, table message {i} never arrives", playlist_job(), lambda w, i=i: w.lose_notify.add(i), playing=2)
    section("each write and message of the table playlist (it still ends with the first pattern drawing)", n)

    print("Several things at once…")
    n = len(failures)
    pairs = 150 if args.quick else 1200
    for _ in range(pairs):
        a, b = rng.randrange(W + 40), rng.randrange(W + 40)
        run(f"show, link lost at writes {a} and {b}", show_job(), lambda w, a=a, b=b: w.drop_at_write.update((a, b)), **show_ok)
    section(f"two link drops at random points ({pairs} combinations): always recovers", n)
    n = len(failures)
    mixed, gave_up = (150 if args.quick else 1500), 0
    for k in range(mixed):
        def setup(w, k=k):
            for _ in range(rng.randrange(2, 6)):
                kind = rng.choice([w.drop_at_write, w.drop_at_write, w.reset_at_write, w.lose_write, w.drop_at_notify, w.lose_notify])
                kind.add(rng.randrange(W + 60))
            w.chunk = rng.choice([1, 7, 20, 244])
        w = World(lib)
        setup(w)
        ops, blob = show_job()
        runs += 1
        try:
            r = w.run(ops, blob)
            problem = check(f"show, random faults #{k}", w, r, expect_ok=r["ok"], **show_ok)
            gave_up += not r["ok"]
        except AssertionError as e:
            problem = f"show, random faults #{k}: {e}"
        if problem:
            failures.append(problem)
            if len(failures) <= 12:
                print(f"  ✘ {problem}\n      log: {' | '.join(w.log[-6:])}")
    section(f"2 to 5 faults of mixed kinds ({mixed} combinations): {mixed - gave_up} recovered, {gave_up} gave up with a reason; "
            "none hung, none said ok wrongly", n)

    print("The table isn't itself…")
    n = len(failures)

    def faults(**f):
        return lambda w: w.faults.d.update(f)

    def absent(seconds):
        return lambda w: setattr(w, "absent_until", clock.now + seconds)

    w, r = run("table not there", show_job(), absent(10_000), expect_ok=False)
    assert r.get("stage") == "link" and w.seconds < 120, (r, w.seconds)
    w, r = run("table turns up after 50 s", show_job(), absent(50), **show_ok)
    w, r = run("table links but says nothing", show_job(), faults(silent=True), expect_ok=False)
    assert r.get("stage") == "handshake" and r["links"] == 3, r
    w, r = run("table never finishes its start-up lists", show_job(), faults(neverReady=True), expect_ok=False)
    assert r.get("stage") == "handshake", r
    w, r = run("table stuck in an old handshake", show_job(), faults(stuck=True), **show_ok)
    assert w.stats.d.get("unstuck") == 1 and r["links"] == 1, r
    section("absent (gives up in under 2 minutes), late, silent, never ready, stuck in an old handshake", n)

    n = len(failures)
    w, r = run("pages lost", show_job(), faults(losePages=[1, 4, 8]), **show_ok)
    assert r["ops"][1][3] == 3, r
    run("last page lost", show_job(), faults(loseLastPage=True), **show_ok)
    w, r = run("first slot refused", show_job(), faults(rejectStart=[50000]), playing=50001, stored=50001)
    assert r["ops"][1][2] == 50001, r
    w, r = run("both slots refused, then accepted", show_job(), faults(rejectStart=[50000, 50001]), playing=50001, stored=50001)
    w, r = run("every try refused", show_job(), faults(rejectStart=[50000, 50001, 50001]), expect_ok=False)
    assert r["failedOp"] == 1 and "rejected" in r["error"], r
    w, r = run("no storage", show_job(), faults(noStorage=True), expect_ok=False)
    assert "storage" in r["error"], r
    run("upload abandoned by the table part-way", show_job(), faults(failAtPage=5), **show_ok)
    run("Start ignored twice", show_job(), faults(ignoreStart=2), **show_ok)
    run("Start ignored three times, then answered", show_job(), faults(ignoreStart=3), **show_ok)
    run("End ignored", show_job(), faults(ignoreEnd=1), **show_ok)
    run("play ignored three times", show_job(), faults(ignorePlays=3), **show_ok)
    w, r = run("play ignored every time", show_job(), faults(ignorePlays=4), expect_ok=False)
    assert r["failedOp"] == 2 and 50000 in w.table.stored, r
    section("pages lost, slots refused, no storage, upload abandoned, Start, End and play ignored", n)

    n = len(failures)
    w, r = run("playlist not confirmed", playlist_job(), faults(ignorePlaylist=True), playing=2)
    assert r["ops"][1][1] == 0 and r["ops"][7][0] == 1, r
    # Selecting starts the list's first pattern, 2; the job was told to expect 9, which isn't stored, so the
    # fallback play can't start it either: the job has to say so.
    w, r = run("playlist selected but the expected pattern doesn't start", playlist_job(first=9), expect_ok=False)
    assert r["failedOp"] == 7 and r["ops"][5][1] == 0 and "didn't start pattern 9" in r["error"], r
    section("table playlist: not confirmed (plays the pattern directly); the expected pattern never starts (fails, saying so)", n)

    print("Bad jobs are refused, not run…")
    n = len(failures)
    for name, ops, why in [("a firmware-update command", [op(1, packet(0x15, b"\x01"))], "never sent"),
                           ("the reserved reset", [op(1, packet(0x14, bytes([12])))], "never sent"),
                           ("a jump past the end", [op(6, fail=5)], "past the end"),
                           ("an upload outside the data", [op(4, struct.pack("<IIB", 500, 0, 1) + struct.pack("<H", 50000))], "outside the data"),
                           ("pattern id 0", [op(4, struct.pack("<IIB", 1, 0, 1) + struct.pack("<H", 0))], "pattern id 0"),
                           ("an unknown step", [op(9)], "unknown step")]:
        w = World(lib)
        runs += 1
        r = w.run(ops, points(1))
        if "refused" not in r or why not in r["refused"].get("error", "") or w.writes:
            failures.append(f"{name}: not refused ({r})")
            print(f"  ✘ {failures[-1]}")
    w = World(lib)
    blob = bytearray(points(N_POINTS))
    w.run(show_job()[0], bytes(blob))   # fine
    w = World(lib)
    orig = w.blob_write
    w.blob_write = lambda off, data, n: (orig(off, data, n), w.blob.__setitem__(off, w.blob[off] ^ 1))[0]
    r = w.run(*show_job())
    runs += 2
    if "intact" not in r.get("refused", {}).get("error", ""):
        failures.append(f"a pattern stored wrong wasn't caught: {r}")
        print(f"  ✘ {failures[-1]}")
    section("firmware-update and reset commands, bad steps, a pattern that didn't arrive intact", n)

    print("Random and broken input, under the sanitizers…")
    fuzz = os.path.join(tmp, "fuzz-job-engine")
    subprocess.run(["cc", "-g", "-O1", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", "-fsanitize=address,undefined",
                    "-fno-sanitize-recover=undefined", "-o", fuzz, os.path.join(HERE, "fuzz-job-engine.c"),
                    os.path.join(HERE, "..", "firmware", "main", "job.c")], check=True)
    for seed in ([args.seed] if args.quick else [args.seed, args.seed + 1, args.seed + 2]):
        out = subprocess.run([fuzz, "20000" if args.quick else "200000", str(seed)], capture_output=True, text=True)
        if out.returncode != 0:
            failures.append(f"fuzz seed {seed}: {(out.stderr or out.stdout).strip()[-600:]}")
            print(f"  ✘ {failures[-1]}")
        else:
            print(f"  ✓ {out.stdout.strip()}")

    print(f"{runs} runs. " + ("PASS" if not failures else f"FAIL ({len(failures)})"))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
