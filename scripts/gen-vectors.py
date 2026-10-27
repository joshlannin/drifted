"""Writes spec/vectors/protocol.json: byte-exact examples for testing a Drift protocol implementation.
Usage: python3 scripts/gen-vectors.py"""
import json, struct

def pkt(cmd, data=b"", ack=False):
    c = (cmd | 0x80) if ack else (cmd & 0x7F)
    body = bytes([0x7B, len(data) + 4, c]) + data
    return body + bytes([sum(body) & 0xFF])

def hx(b): return " ".join(f"{x:02x}" for x in b)
def u16(v): return struct.pack("<H", v)
def u32(v): return struct.pack("<I", v)
def s(v): return v.encode() + b"\0"

def page(index, pts):
    return pkt(0x53, bytes([1, len(pts)]) + u16(index) + b"".join(u16(t) + u16(r) for t, r in pts))

circle = [(int(i * 60000 / 40) % 60000, 25000) for i in range(41)]   # rho 0.5, 41 points → 2 pages

host = [
    ("confirm_data", "Generic acknowledgement (cmd 0x50 with the ack bit, no data)", pkt(0x50, ack=True)),
    ("confirm_connection", "Reply to 0x50/1", pkt(0x50, b"\x02\x01")),
    ("current_time", "Sunday 2026-10-25 13:45:30: yy=26, month=9 (0-based), day=25, weekday=7", pkt(0x12, bytes([2, 26, 9, 25, 13, 45, 30, 7]))),
    ("draw_pattern_50000", "0x14/1 id", pkt(0x14, b"\x01" + u16(50000))),
    ("play_pause", "0x14/3", pkt(0x14, b"\x03")),
    ("speed_max", "0x14/6 raw 75", pkt(0x14, b"\x06\x4b")),
    ("brightness_100", "0x14/7", pkt(0x14, b"\x07\x64")),
    ("random_off", "0x14/10 false", pkt(0x14, b"\x0a\x00")),
    ("color_white_store_temp", "0x14/15 enable, r, g, b", pkt(0x14, b"\x0f\x01\xff\xff\xff")),
    ("select_color_temp", "0x14/13 \"Temp\"", pkt(0x14, b"\x0d" + s("Temp"))),
    ("light_fixed_full", "0x11/4 shifting off, shiftTime 0, breathing off, brightness 100", pkt(0x11, b"\x04\x00" + u16(0) + b"\x00\x64")),
    ("start_upload_50000_2_pages", "0x13/1 id, pageCount", pkt(0x13, b"\x01" + u16(50000) + u32(2))),
    ("page_1", "0x53/1 count 40, index 1, 40 × (t, r): circle at rho 0.5", page(1, circle[:40])),
    ("page_2", "0x53/1 count 1, index 2 (the last page may be short)", page(2, circle[40:])),
    ("end_upload_50000_2_pages", "0x13/2 id, pageCount", pkt(0x13, b"\x02" + u16(50000) + u32(2))),
    ("delete_50000", "0x13/3 u16 array", pkt(0x13, b"\x03\x01" + u16(50000))),
]

# Synthetic running state with neutral values (layout in docs/protocol.md).
state = (b"\x01" + b"\x64" + s("Temp") + b"\xff\xff\xff" + b"\x4b" + s("") + u16(50000) + u16(2500) + b"\x01"
         + b"\x00\x00\x01\x00\x00" + u16(0) + s("A_11_V0.7.12") + b"\x00\x00" + s("B_11_V0.3.3") + b"\x00\x00\x01")
table = [
    ("waiting_for_confirm", "0x50/1: reply confirm_connection", pkt(0x50, b"\x01"), None),
    ("asks_for_time", "0x32/2: reply current_time", pkt(0x32, b"\x02"), None),
    ("ack_of_time", "ack bit set: the table acknowledging our time. Reply confirm_data, not the time.", pkt(0x32, b"\x02", ack=True), None),
    ("init_complete", "0x4F/1: reply confirm_data; session ready", pkt(0x4F, b"\x01"), None),
    ("running_state", "0x35/1 (synthetic values)", pkt(0x35, state),
     {"brightness": 100, "colorName": "Temp", "patternId": 50000, "progress": 0.25, "status": 1, "random": False, "loop": False,
      "controllerVersion": "A_11_V0.7.12", "driverVersion": "B_11_V0.3.3"}),
    ("upload_started", "0x34/2 with ack bit", pkt(0x34, b"\x02" + u16(50000), ack=True), {"patternId": 50000}),
    ("upload_missing_pages", "0x34/1 with ack bit: pages 1 and 2 missing", pkt(0x34, b"\x01\x02" + u16(1) + u16(2), ack=True), {"missing": [1, 2]}),
    ("upload_missing_none", "0x34/1, empty list: the LAST page(s) were lost. NOT success.", pkt(0x34, b"\x01\x00", ack=True), {"missing": []}),
    ("upload_stored", "0x34/3 with ack bit: the only success signal", pkt(0x34, b"\x03" + u16(50000), ack=True), {"patternId": 50000}),
    ("upload_failed", "0x34/5", pkt(0x34, b"\x05" + u16(50000), ack=True), {"patternId": 50000}),
    ("alarm_fatal_10_13", "0x37/1 codes [10, 13]; latched, repeats every second", pkt(0x37, b"\x01\x02" + u16(10) + u16(13)), {"kind": 1, "codes": [10, 13]}),
]

H = {n: hx(b) for n, _, b in host}
T = {n: hx(b) for n, _, b, _ in table}
exchanges = [
    {"name": "handshake", "steps": [
        {"from": "table", "hex": T["waiting_for_confirm"]}, {"from": "host", "hex": H["confirm_connection"]},
        {"from": "table", "hex": T["running_state"], "note": "state dump: many messages, each answered with confirm_data"},
        {"from": "host", "hex": H["confirm_data"]},
        {"from": "table", "hex": T["asks_for_time"]}, {"from": "host", "hex": H["current_time"]},
        {"from": "table", "hex": T["ack_of_time"]}, {"from": "host", "hex": H["confirm_data"]},
        {"from": "table", "hex": T["init_complete"]}, {"from": "host", "hex": H["confirm_data"]}]},
    {"name": "upload_clean", "steps": [
        {"from": "host", "hex": H["start_upload_50000_2_pages"]}, {"from": "table", "hex": T["upload_started"]},
        {"from": "host", "hex": H["confirm_data"]},
        {"from": "host", "hex": H["page_1"], "note": "100 ms between pages"}, {"from": "host", "hex": H["page_2"]},
        {"from": "host", "hex": H["end_upload_50000_2_pages"]}, {"from": "table", "hex": T["upload_stored"]},
        {"from": "host", "hex": H["confirm_data"]}]},
    {"name": "upload_lost_last_page", "steps": [
        {"from": "host", "hex": H["start_upload_50000_2_pages"]}, {"from": "table", "hex": T["upload_started"]},
        {"from": "host", "hex": H["confirm_data"]},
        {"from": "host", "hex": H["page_1"]}, {"from": "host", "hex": H["page_2"], "note": "lost in transit"},
        {"from": "host", "hex": H["end_upload_50000_2_pages"]}, {"from": "table", "hex": T["upload_missing_none"]},
        {"from": "host", "hex": H["confirm_data"], "note": "empty list = trailing pages lost: resend the tail"},
        {"from": "host", "hex": H["page_2"]}, {"from": "host", "hex": H["end_upload_50000_2_pages"]},
        {"from": "table", "hex": T["upload_stored"]}, {"from": "host", "hex": H["confirm_data"]}]},
]
out = {
    "about": "Byte-exact Drift protocol examples. Packet = 7B len ackCmd data checksum (docs/protocol.md). Hex is space-separated.",
    "host_to_table": [{"name": n, "note": d, "hex": hx(b)} for n, d, b in host],
    "table_to_host": [{"name": n, "note": d, "hex": hx(b), **({"decoded": dec} if dec else {})} for n, d, b, dec in table],
    "exchanges": exchanges,
}
json.dump(out, open("spec/vectors/protocol.json", "w"), indent=2)
print(f"wrote spec/vectors/protocol.json: {len(host)} host, {len(table)} table, {len(exchanges)} exchanges")
