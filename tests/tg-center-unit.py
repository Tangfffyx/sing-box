#!/usr/bin/env python3
"""Offline unit tests for py/tg_center_bot.py security, parsing, and atomic config handling."""
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "py"))


class DummyHandler:
    def __init__(self, headers=None, body=b""):
        self.headers = headers or {}
        self.rfile = io.BytesIO(body)


class TestTgCenterBot(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg_path = os.path.join(self.tmp.name, "telegram.json")
        self.lock_path = os.path.join(self.tmp.name, "manager.lock")
        os.environ["SB_LOCK_FILE"] = self.lock_path
        import tg_center_bot as bot
        self.bot = bot
        self.bot.CONFIG_PATH = self.cfg_path
        self.bot.LOCK_PATH = self.lock_path

    def tearDown(self):
        self.tmp.cleanup()

    def test_authorized_constant_time(self):
        self.bot.save_config({"access_secret": "s3cr3t-token"})
        self.assertTrue(self.bot.authorized(DummyHandler({"X-SB-TG-Secret": "s3cr3t-token"})))
        self.assertFalse(self.bot.authorized(DummyHandler({"X-SB-TG-Secret": "wrong"})))
        self.assertFalse(self.bot.authorized(DummyHandler({})))

    def test_read_json_limits_and_validation(self):
        h_ok = DummyHandler({"Content-Length": "13"}, b'{"hello":"v"}')
        self.assertEqual(self.bot.read_json(h_ok), {"hello": "v"})

        h_neg = DummyHandler({"Content-Length": "-1"}, b"")
        with self.assertRaises(ValueError):
            self.bot.read_json(h_neg)

        h_big = DummyHandler({"Content-Length": str(self.bot.MAX_REQUEST_BYTES + 1)}, b"{}")
        with self.assertRaises(self.bot.PayloadTooLargeError):
            self.bot.read_json(h_big)

        h_list = DummyHandler({"Content-Length": "2"}, b"[]")
        with self.assertRaises(ValueError):
            self.bot.read_json(h_list)

    def test_corrupt_config_creates_backup(self):
        with open(self.cfg_path, "w", encoding="utf-8") as f:
            f.write("{broken json")
        loaded = self.bot.load_config()
        self.assertEqual(loaded, {})
        backups = [p for p in os.listdir(self.tmp.name) if p.startswith("telegram.json.corrupt.")]
        self.assertEqual(len(backups), 1)

    def test_atomic_save_and_reload(self):
        payload = {"enabled": True, "access_secret": "abc", "reports": {"n1": {"vps_name": "HK"}}}
        self.bot.save_config(payload)
        self.assertEqual(self.bot.load_config(), payload)
        with open(self.cfg_path, "r", encoding="utf-8") as f:
            self.assertEqual(json.load(f), payload)

    def post(self, path, payload):
        body = json.dumps(payload).encode()
        handler = DummyHandler({"X-SB-TG-Secret": "secret", "Content-Length": str(len(body))}, body)
        handler.path = path
        with patch.object(self.bot, "write_json") as reply:
            self.bot.Handler.do_POST(handler)
        return reply.call_args.args[1:]

    def test_notify_reaches_configured_admin(self):
        self.bot.save_config({"access_secret": "secret", "admin_chat_ids": ["123"]})
        with patch.object(self.bot, "send_message", return_value={"ok": True}) as send:
            status, payload = self.post("/api/test", {"vps_name": "第二台"})
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        send.assert_called_once_with("123", "通知测试成功：第二台")

    def test_bind_scope_and_expiration(self):
        self.bot.save_config({"access_secret": "secret", "bot_username": "fixture_bot"})
        alice = {"vps_id": "n1", "vps_name": "首台", "username": "alice"}
        bob = {"vps_id": "n2", "vps_name": "第二台", "username": "bob"}
        with patch.object(self.bot.time, "time", return_value=1000):
            status, reply = self.post("/api/bind-token", alice)
            self.assertEqual(status, 200)
            token = reply["link"].split("start=bind_")[1]
            _, reply = self.post("/api/bind-token", bob)
            expired = reply["link"].split("start=bind_")[1]
        with patch.object(self.bot, "send_home"), patch.object(self.bot, "send_message") as send:
            with patch.object(self.bot.time, "time", return_value=1599):
                self.bot.handle_message({"text": f"/start bind_{token}", "chat": {"id": 101}, "from": {"id": 101}})
                self.bot.bind_token(202, 202, token)
            with patch.object(self.bot.time, "time", return_value=1600):
                self.bot.bind_token(202, 202, expired)
            self.assertEqual(send.call_count, 3)
            self.assertIn("已失效", send.call_args.args[1])
        cfg = self.bot.load_config()
        self.assertEqual([item["username"] for item in self.bot.user_bindings(cfg, 101)], ["alice"])
        self.assertEqual(self.bot.user_bindings(cfg, 202), [])
        with patch.object(self.bot, "render_page") as render:
            self.bot.user_status(101, 101)
            self.assertIn("alice", render.call_args.args[1])
            self.assertNotIn("bob", render.call_args.args[1])


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestTgCenterBot)
    res = unittest.TextTestRunner(verbosity=0).run(suite)
    if not res.wasSuccessful():
        sys.exit(1)
    print("PASS py/tg_center_bot.py unit tests (auth, payload limits, atomic save, admin test, binding scope and expiry)")
