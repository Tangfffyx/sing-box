#!/usr/bin/env python3
"""Connect with the original credentials to each real core configuration."""
from contextlib import ExitStack
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import runpy
import socket
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Event, Thread


ROOT = Path(__file__).resolve().parents[1]


def collect_stats(grpcurl, proto, port, process):
    service = "v2ray.core.app.stats.command.StatsService/QueryStats"
    data = subprocess.check_output([
        grpcurl, "-plaintext", "-import-path", str(proto.parent), "-proto", proto.name,
        "-d", '{"patterns":["user>>>"],"reset":false,"regexp":false}', f"127.0.0.1:{port}", service,
    ])
    return {"process": str(process.pid), "start": 0, "stats": json.loads(data).get("stat", [])}


def account(ledger, snapshot):
    data = subprocess.check_output([
        "bash", "-c", 'source lib/50_v2ray_api.sh; account_usage_snapshot "$1" "$2"',
        "stage-b-account", json.dumps(ledger), json.dumps(snapshot),
    ], cwd=ROOT)
    return json.loads(data)


def main(core, configs, grpcurl=None):
    helpers = runpy.run_path(str(Path(__file__).with_name("stage-a-reconnect.py")))
    fixture = helpers["FIXTURE"]
    old_link = helpers["old_link"]
    make_outbound = helpers["make_outbound"]
    start = helpers["start"]
    stop = helpers["stop"]
    stream_open = Event()
    stream_finished = Event()

    class Target(helpers["Target"]):
        def do_GET(self):
            if self.path != "/stream":
                return super().do_GET()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"open\n")
            self.wfile.flush()
            stream_open.set()
            stream_finished.wait(15)

    def available_port():
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            return probe.getsockname()[1]

    with ExitStack() as stack:
        temp = Path(stack.enter_context(TemporaryDirectory()))
        target = stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), Target))
        Thread(target=target.serve_forever, daemon=True).start()
        stack.callback(target.shutdown)
        stack.callback(stream_finished.set)
        start(stack, core, temp, "landing", json.loads((fixture / "landing.json").read_text()), 11081)
        alice = available_port()
        start(stack, core, temp, "alice-old-client", {
            "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": alice}],
            "outbounds": [make_outbound(old_link("alice", "trojan", "trojan-18443-to-lab@alice"))],
        }, alice)
        alice_direct = available_port()
        start(stack, core, temp, "alice-old-direct-client", {
            "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": alice_direct}],
            "outbounds": [make_outbound(old_link("alice", "ss", "ss-18080@alice"))],
        }, alice_direct)
        bob = available_port()
        start(stack, core, temp, "bob-old-client", {
            "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": bob}],
            "outbounds": [make_outbound(old_link("bob", "ss", "ss-18080@bob"))],
        }, bob)
        has_stats = b"with_v2ray_api" in subprocess.check_output([core, "version"])
        stats_port = available_port()

        def request(port, path="/", auth=None):
            args = ["curl", "-fsS", "--max-time", "7", "--noproxy", "",
                    "--socks5", f"127.0.0.1:{port}"]
            if auth:
                args.extend(["--proxy-user", auth])
            return args + [f"http://127.0.0.1:{target.server_port}{path}"]

        def check(port, allowed, auth=None):
            result = subprocess.run(request(port, auth=auth), capture_output=True)
            expected = (result.returncode == 0 and result.stdout == b"stage-a-reconnect\n")
            if expected != allowed:
                raise AssertionError((port, allowed, result.stderr.decode()))

        def server(context, case):
            config = json.loads((Path(configs) / f"{case}.json").read_text())
            config.get("log", {}).pop("output", None)
            config.get("experimental", {}).pop("cache_file", None)
            if has_stats:
                config["experimental"]["v2ray_api"]["listen"] = f"127.0.0.1:{stats_port}"
                ready = stats_port
            else:
                config.get("experimental", {}).pop("v2ray_api", None)
                ready = 11080 if case != "parked" else None
            return start(context, core, temp, case, config, ready)

        with ExitStack() as instance:
            allowed = server(instance, "allowed")
            check(alice, True)
            check(alice_direct, True)
            check(bob, True)
            stream = subprocess.Popen(request(alice, "/stream"), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            instance.callback(stop, stream)
            assert stream_open.wait(5)
            assert stream.poll() is None
            stop(allowed)
            server(instance, "disabled")
            stream.communicate(timeout=3)
            check(alice, False)
            check(alice_direct, False)
            check(bob, True)
        print("PASS phase B core: old connection closed, new disabled request refused, Bob reconnects")

        cases = [
            ("manual_restored", True), ("expired", False), ("expiry_restored", True),
            ("quota", False), ("quota_restored", True), ("quota_raised", True),
        ]
        for case, accepted in cases:
            with ExitStack() as instance:
                server(instance, case)
                check(alice, accepted)
                check(alice_direct, accepted)
                check(bob, True)
        print("PASS phase B core: expiry, quota, renewals and quota changes using unchanged links")

        with ExitStack() as instance:
            server(instance, "parked")
            for port in (11080, 18080):
                with socket.socket() as probe:
                    probe.settimeout(1)
                    assert probe.connect_ex(("127.0.0.1", port)) != 0
            check(bob, False)
        with ExitStack() as instance:
            server(instance, "parked_restored")
            check(bob, True)
            check(11080, True, "socks-11080@bob:fixture-socks-bob")
        print("PASS phase B core: no listener for empty SOCKS5/SS2022; Bob restores original links")

        if grpcurl:
            assert has_stats
            proto = temp / "stats.proto"
            source = (ROOT / "lib" / "50_v2ray_api.sh").read_text()
            package = "package v2ray.core.app.stats.command;"
            proto.write_text('syntax = "proto3";\n' + package +
                             source.split(package, 1)[1].split("\nEOF_V2V", 1)[0] + "\n")
            ledger = {"users": {"alice": {}, "bob": {}}}
            expected = {"uplink": 0, "downlink": 0}
            for _ in range(2):
                with ExitStack() as instance:
                    process = server(instance, "allowed")
                    check(bob, True)
                    snap = collect_stats(grpcurl, proto, stats_port, process)
                    per_direction = {
                        row["name"].rsplit(">>>", 1)[1]: int(row["value"])
                        for row in snap["stats"] if row["name"].startswith("user>>>ss-18080@bob>>>")
                    }
                    for direction in expected:
                        assert per_direction[direction] > 0
                        expected[direction] += per_direction[direction]
                    ledger = account(ledger, snap)
                    assert account(ledger, snap) == ledger
                    assert ledger["users"]["bob"]["used_up_bytes"] == expected["uplink"]
                    assert ledger["users"]["bob"]["used_down_bytes"] == expected["downlink"]
                    assert ledger["users"]["alice"]["used_down_bytes"] == 0
            print("PASS phase B live accounting: real gRPC counters across two processes, each counted once")


if __name__ == "__main__":
    main(*sys.argv[1:])
