#!/usr/bin/env python3
"""Sets up a Drifted relay over USB: Wi-Fi network, password and the token Drifted uses to connect.

Plug the relay into this computer with USB-C, then:
    python3 relay/setup.py                      # asks for the Wi-Fi name and password, makes a token
    python3 relay/setup.py --ssid "Home" --token <existing token>
    python3 relay/setup.py --show               # print the relay's settings (secrets masked) and status

Nothing is written to disk here: the settings live only on the relay. The token is printed once at the end,
with the command that points Drifted at the relay. Needs pyserial (PlatformIO's Python has it:
~/.local/pio-venv/bin/python relay/setup.py, or python3 -m pip install --user pyserial).
"""
import argparse
import getpass
import glob
import json
import secrets
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial is missing: python3 -m pip install --user pyserial (or run this with PlatformIO's python)")


def find_port():
    ports = sorted(glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/ttyACM*"))
    if not ports:
        sys.exit("No relay found on USB. Plug it in with a data cable (some USB-C cables only charge), or pass --port.")
    if len(ports) > 1:
        print(f"Several serial ports; using {ports[0]} (pass --port to choose): {', '.join(ports)}")
    return ports[0]


class Relay:
    def __init__(self, port):
        self.port = port
        self.open()

    def open(self, wait=0):
        deadline = time.time() + wait
        while True:
            try:
                self.s = serial.Serial(self.port, 115200, timeout=0.2)
                return
            except serial.SerialException:
                if time.time() > deadline:
                    raise
                time.sleep(0.5)

    def lines(self, seconds):
        """Yields lines from the relay for up to `seconds`."""
        deadline = time.time() + seconds
        buf = b""
        while time.time() < deadline:
            chunk = self.s.read(256)
            if not chunk:
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                yield line.decode(errors="replace").strip()

    def command(self, line, seconds=5, echo=True):
        """Sends a command; returns (ok, message, output lines). Log lines from the relay are skipped."""
        self.s.reset_input_buffer()
        self.s.write(line.encode() + b"\n")
        out = []
        for l in self.lines(seconds):
            if l.startswith("ok"):
                return True, l[2:].strip(), out
            if l.startswith("error:"):
                return False, l[6:].strip(), out
            if not l.startswith(("I (", "W (", "E (", "D (")):
                out.append(l)
                if echo and line in ("show", "status", "scan", "wifi-scan"):
                    print("  " + l)
        return False, "no answer from the relay", out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="serial port (default: the first /dev/cu.usbmodem*)")
    ap.add_argument("--ssid", help="Wi-Fi network name (2.4 GHz; the relay can't use 5 GHz)")
    ap.add_argument("--password", help="Wi-Fi password (asked for if left out)")
    ap.add_argument("--token", help="token for Drifted to connect with (default: a new random one)")
    ap.add_argument("--show", action="store_true", help="just print the relay's settings and status")
    ap.add_argument("--wifi-scan", action="store_true", help="just list the Wi-Fi networks the relay can see")
    args = ap.parse_args()

    relay = Relay(args.port or find_port())
    ok, version, _ = relay.command("version")
    if not ok:
        sys.exit("The relay didn't answer. Is the Drifted relay firmware flashed (relay/README.md)? Try unplugging it and plugging it back in.")
    print(f"Found {version} on {relay.port}")

    if args.show:
        relay.command("show")
        return
    if args.wifi_scan:
        print("Wi-Fi networks the relay can see:")
        relay.command("wifi-scan", seconds=15)
        return

    ssid = args.ssid or input("Wi-Fi network name (2.4 GHz): ").strip()
    password = args.password if args.password is not None else getpass.getpass(f"Password for {ssid} (blank for an open network): ")
    token = args.token or secrets.token_hex(16)
    if len(token) < 16:
        sys.exit("The token must be at least 16 characters.")

    for key, value in (("ssid", ssid), ("password", password), ("token", token)):
        ok, msg, _ = relay.command(f"sethex {key} {value.encode().hex()}")
        if not ok:
            sys.exit(f"Setting {key} failed: {msg}")
    print("Saved on the relay. Restarting it to join Wi-Fi…")
    relay.command("reboot")
    relay.s.close()
    time.sleep(2)
    relay.open(wait=15)

    # Ask for its settings until Wi-Fi is up (the USB port can reconnect during the restart).
    ip = name = None
    deadline = time.time() + 45
    while time.time() < deadline and not ip:
        try:
            ok, _, out = relay.command("show", seconds=3, echo=False)
        except serial.SerialException:
            relay.open(wait=10)
            continue
        for l in out:
            parts = l.split()
            if parts[:1] == ["name"] and len(parts) > 1:
                name = parts[1]
            if parts[:2] == ["wifi", "up"] and len(parts) > 2:
                ip = parts[2]
        if not ip:
            time.sleep(2)
    if not ip:
        print(f"\nThe relay hasn't joined \"{ssid}\" yet (its light blinks red while it tries). Check the name and password,")
        print("and that the network is 2.4 GHz. `python3 relay/setup.py --wifi-scan` lists what it can see.")
        sys.exit(1)

    print(f"\nThe relay is on Wi-Fi: {name} at {ip}, port 8766.")
    print("Its light turns blue when it has linked to the table (amber while it looks), green while Drifted is connected.")
    print(f"\nToken (Drifted needs it; it isn't stored anywhere else): {token}")
    body = json.dumps({"enabled": True, "name": name, "host": ip, "token": token})
    print("\nPoint Drifted at it (on the Mac running Drifted):")
    print("  curl -X PUT -H \"Authorization: Bearer $(cat ~/Library/Application\\ Support/Drifted/token)\" \\")
    print(f"    localhost:8765/relay -d '{body}'")
    print("or ask your AI assistant to use the relay tool with these details.")


if __name__ == "__main__":
    main()
