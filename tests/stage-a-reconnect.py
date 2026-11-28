#!/usr/bin/env python3
"""Use the saved 7.0.0 links against the config recovered by stage-a.sh."""
import base64
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import socket
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Thread
import time
from urllib.parse import parse_qs, unquote, urlsplit


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "migration-7.0.0"


def old_link(user, scheme, label):
    for line in (FIXTURE / "old-exports" / f"{user}.txt").read_text().splitlines():
        if "通用链接:" not in line:
            continue
        link = urlsplit(line.split("通用链接:", 1)[1].strip())
        if link.scheme == scheme and unquote(link.fragment) == label:
            return link
    raise ValueError(f"Missing legacy link for {user}/{label}")


def make_outbound(link):
    outbound = {"tag": "legacy", "server": link.hostname, "server_port": link.port}
    if link.scheme == "ss":
        method, password = base64.b64decode(link.username).decode().split(":", 1)
        return dict(outbound, type="shadowsocks", method=method, password=password)
    query = parse_qs(link.query)
    return dict(outbound, type="trojan", password=unquote(link.username), tls={
        "enabled": True, "server_name": query["sni"][0],
        "insecure": query.get("allowInsecure") == ["1"],
    })


class Target(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"stage-a-reconnect\n")

    def log_message(self, *_args):
        pass


def stop(process):
    if process.poll() is None:
        process.terminate()
    process.wait(timeout=5)


def start(stack, core, temp, name, config, ready_port):
    for inbound in config.get("inbounds", []):
        tls = inbound.get("tls", {})
        if tls.get("key_path") != "test-key.pem":
            continue
        cert, key = temp / "fixture-cert.pem", temp / "fixture-key.pem"
        if not key.exists():
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=fixture.invalid", "-keyout", str(key), "-out", str(cert),
            ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tls.update(certificate_path=str(cert), key_path=str(key))
    path = temp / f"{name}.json"
    path.write_text(json.dumps(config))
    subprocess.run([core, "check", "-c", path], check=True, cwd=FIXTURE)
    log = stack.enter_context((temp / f"{name}.log").open("w+"))
    process = subprocess.Popen([core, "run", "-c", path], cwd=FIXTURE, stdout=log, stderr=log)
    stack.callback(stop, process)
    for _ in range(50):
        if process.poll() is not None:
            break
        if ready_port is None:
            time.sleep(0.2)
            if process.poll() is None:
                return process
            break
        try:
            with socket.create_connection(("127.0.0.1", ready_port), timeout=0.1):
                return process
        except OSError:
            time.sleep(0.1)
    log.seek(0)
    raise RuntimeError(log.read())


def main(core, recovered_path):
    recovered = json.loads(Path(recovered_path).read_text())
    with ExitStack() as stack:
        temp = Path(stack.enter_context(TemporaryDirectory()))
        target = stack.enter_context(HTTPServer(("127.0.0.1", 0), Target))
        Thread(target=target.serve_forever, daemon=True).start()
        stack.callback(target.shutdown)
        start(stack, core, temp, "landing", json.loads((FIXTURE / "landing.json").read_text()), 11081)
        start(stack, core, temp, "recovered", recovered, 11080)
        for user, scheme, label in (
            ("alice", "trojan", "trojan-18443-to-lab@alice"),
            ("bob", "ss", "ss-18080@bob"),
        ):
            with ExitStack() as client, socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
                probe.close()
                start(client, core, temp, user, {
                    "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": port}],
                    "outbounds": [make_outbound(old_link(user, scheme, label))],
                }, port)
                body = subprocess.check_output([
                    "curl", "-fsS", "--max-time", "5", "--noproxy", "",
                    "--socks5", f"127.0.0.1:{port}", f"http://127.0.0.1:{target.server_port}/",
                ])
                assert body == b"stage-a-reconnect\n"
                print(f"PASS old {user} {scheme} link after recovery")


if __name__ == "__main__":
    main(*sys.argv[1:])
