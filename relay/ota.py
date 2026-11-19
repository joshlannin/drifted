#!/usr/bin/env python3
"""Updates a Drifted relay's firmware over the network.

It serves the firmware file from this computer over HTTP and tells the relay to fetch it. The relay writes it to
its other app slot and restarts into it; if the new firmware doesn't get back on Wi-Fi within 5 minutes, it rolls
back by itself.

Through Drifted (keeps Drifted's own connection to the relay):
    python3 relay/ota.py --drifted http://mac-mini.local:8765 --drifted-token TOKEN
Straight to the relay (Drifted reconnects afterwards):
    python3 relay/ota.py --relay 192.168.1.40 --token RELAY_TOKEN

Default firmware: relay/firmware/.pio/build/nanoc6/firmware.bin (build it with `pio run` in relay/firmware).
Only Python's standard library.
"""
import argparse
import http.server
import json
import os
import socket
import struct
import sys
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_FIRMWARE = os.path.join(HERE, "firmware", ".pio", "build", "nanoc6", "firmware.bin")


def local_ip_towards(host):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((host, 9))
        return s.getsockname()[0]
    finally:
        s.close()


def serve(path):
    """Serves `path` at /firmware.bin on a free port; returns (server, port, progress dict)."""
    data = open(path, "rb").read()
    progress = {"sent": 0, "total": len(data), "requests": 0}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/firmware.bin":
                self.send_error(404)
                return
            progress["requests"] += 1
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            for i in range(0, len(data), 16384):
                self.wfile.write(data[i:i + 16384])
                progress["sent"] = i + len(data[i:i + 16384])

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1], progress


class RelayConnection:
    def __init__(self, host, port, token):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = b""
        # Observe: don't take the table back if it's been released for the HoMedics app.
        self.send(0x01, b"\x01" + token.encode())
        kind, payload = self.read(10)
        if kind != 0x02:
            sys.exit(f"The relay refused the connection: {payload.decode(errors='replace')}")
        self.welcome = json.loads(payload)

    def send(self, kind, payload):
        self.sock.sendall(bytes([kind]) + struct.pack("<H", len(payload)) + payload)

    def read(self, timeout):
        self.sock.settimeout(timeout)
        while True:
            if len(self.buf) >= 3:
                n = struct.unpack("<H", self.buf[1:3])[0]
                if len(self.buf) >= 3 + n:
                    kind, payload, self.buf = self.buf[0], self.buf[3:3 + n], self.buf[3 + n:]
                    return kind, payload
            chunk = self.sock.recv(65536)
            if not chunk:
                return None, b""
            self.buf += chunk


def relay_version(host, port, token):
    try:
        c = RelayConnection(host, port, token)
        c.sock.close()
        return c.welcome.get("firmware")
    except OSError:
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--firmware", default=DEFAULT_FIRMWARE)
    ap.add_argument("--relay", help="relay IP address or host name (e.g. drifted-relay-1a2b3c.local)")
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--token", default=os.environ.get("DRIFTED_RELAY_TOKEN"), help="relay token (or DRIFTED_RELAY_TOKEN)")
    ap.add_argument("--drifted", help="Drifted's API URL, to send the update through it, e.g. http://localhost:8765")
    ap.add_argument("--drifted-token", default=os.environ.get("DRIFTED_TOKEN"), help="Drifted's API token (or DRIFTED_TOKEN)")
    args = ap.parse_args()
    if not os.path.exists(args.firmware):
        sys.exit(f"No firmware at {args.firmware}; build it with `pio run` in relay/firmware.")
    size = os.path.getsize(args.firmware)

    if args.drifted:
        if not args.drifted_token:
            path = os.path.expanduser("~/Library/Application Support/Drifted/token")
            args.drifted_token = open(path).read().strip() if os.path.exists(path) else None
        if not args.drifted_token:
            sys.exit("Give --drifted-token (Drifted's API token).")

        def api(method, path, body=None):
            req = urllib.request.Request(args.drifted.rstrip("/") + path, method=method,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers={"Authorization": f"Bearer {args.drifted_token}", "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)

        info = api("GET", "/relay")
        status = info.get("status") or {}
        if not info.get("connected"):
            sys.exit("Drifted isn't connected to a relay (GET /relay).")
        relay_ip = status.get("ip")
        before = status.get("firmware")
        print(f"Relay {status.get('name')} at {relay_ip}, firmware {before}")
        server, port, progress = serve(args.firmware)
        url = f"http://{local_ip_towards(relay_ip)}:{port}/firmware.bin"
        print(f"Serving {args.firmware} ({size} bytes) at {url}")
        r = api("POST", "/relay/command", {"command": f"ota {url}"})
        if r.get("ok") is False:
            sys.exit(f"The relay refused: {r.get('message')}")
    else:
        if not args.relay or not args.token:
            sys.exit("Give --relay and --token, or --drifted.")
        c = RelayConnection(args.relay, args.port, args.token)
        before = c.welcome.get("firmware")
        print(f"Relay {c.welcome.get('name')} at {args.relay}, firmware {before}")
        server, port, progress = serve(args.firmware)
        url = f"http://{local_ip_towards(args.relay)}:{port}/firmware.bin"
        print(f"Serving {args.firmware} ({size} bytes) at {url}")
        c.send(0x30, f"ota {url}".encode())
        c.sock.close()   # Drifted may take the connection back meanwhile; the download carries on regardless

    print("Waiting for the relay to download it…")
    deadline = time.time() + 180
    while time.time() < deadline and progress["sent"] < size:
        time.sleep(1)
        print(f"\r  {progress['sent'] * 100 // size:3d}%", end="", flush=True)
    print()
    if progress["sent"] < size:
        sys.exit("The relay didn't download the firmware. Is this computer reachable from it (firewall)?")
    print("Downloaded. The relay checks it, then restarts into it (about 10 s).")
    server.shutdown()
    time.sleep(12)

    for _ in range(20):
        if args.drifted:
            try:
                after = (api("GET", "/relay").get("status") or {}).get("firmware")
            except OSError:
                after = None
        else:
            after = relay_version(args.relay, args.port, args.token)
        if after:
            print(f"The relay is back with firmware {after} (was {before}).")
            return
        time.sleep(3)
    print("The relay hasn't come back yet. If it doesn't within 5 minutes it rolls back to the previous firmware.")


if __name__ == "__main__":
    main()
