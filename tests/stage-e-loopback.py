"""Real SOCKS5 authentication and TCP/native UDP/UoT probes on loopback."""
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[1]
core = os.environ["SB_TEST_CORE"]


def response(query):
    return query[:2] + b"\x81\x80" + query[4:]


class TCP(socketserver.StreamRequestHandler):
    def handle(self):
        length = int.from_bytes(self.rfile.read(2), "big")
        if length:
            data = response(self.rfile.read(length))
            self.wfile.write(len(data).to_bytes(2, "big") + data)


class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, server = self.request
        server.sendto(response(data), self.client_address)


with tempfile.TemporaryDirectory() as tmp, socketserver.ThreadingTCPServer(("127.0.0.1", 0), TCP) as tcp:
    target = tcp.server_address[1]
    with socketserver.ThreadingUDPServer(("127.0.0.1", target), UDP) as udp:
        for server in (tcp, udp):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        cfg = Path(tmp) / "landing.json"
        cfg.write_text(json.dumps({
            "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": port,
                          "users": [{"username": "u@:/%", "password": "p@:/%"}]}],
            "outbounds": [{"type": "direct", "tag": "direct"}],
        }))
        process = subprocess.Popen([core, "run", "-c", cfg], cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(.25)
            assert process.poll() is None
            (Path(tmp) / "sing-box").symlink_to(core)
            env = dict(os.environ, PATH=tmp + ":" + os.environ["PATH"])
            script = '''
                source lib/00_base.sh
                source lib/01_utils.sh
                source lib/42_relay_probe.sh
                relay_probe_target() { printf '127.0.0.1:%s\\n' "$target"; }
                relay_probe_dns "$1" tcp false
                relay_probe_dns "$1" udp false
                relay_probe_dns "$1" udp true
                if relay_probe_dns "$2" tcp false; then exit 1; fi
            '''
            env["target"] = str(target)
            landing = {"server": "127.0.0.1", "port": port, "username": "u@:/%", "password": "p@:/%"}
            subprocess.run(["bash", "-c", script, "probe", json.dumps(landing),
                            json.dumps(dict(landing, password="wrong"))], cwd=root, env=env, check=True)
            print("PASS real SOCKS5: authenticated TCP, native UDP and UoT; wrong password refused")
        finally:
            process.terminate()
            process.wait(timeout=5)
            tcp.shutdown()
            udp.shutdown()
