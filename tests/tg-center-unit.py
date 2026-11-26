#!/usr/bin/env python3
"""Offline unit tests for py/tg_center_bot.py security, parsing, and atomic config handling."""
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestTgCenterBot)
    res = unittest.TextTestRunner(verbosity=0).run(suite)
    if not res.wasSuccessful():
        sys.exit(1)
    print("PASS py/tg_center_bot.py unit tests (auth, payload bounds, corrupt backup, atomic save)")
