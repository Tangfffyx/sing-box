"""Drive the export menu through a real terminal so read and layout paths run."""
import errno
import fcntl
import os
import pty
import select
import struct
import subprocess
import termios
import time


def session(args, keys):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 44, 100, 0, 0))
    process = subprocess.Popen(
        ["bash", "tests/stage-f.sh", "terminal", *args],
        stdin=slave, stdout=slave, stderr=slave,
        env={**os.environ, "TERM": "xterm"},
    )
    os.close(slave)
    try:
        os.write(master, keys.encode())
        result = bytearray()
        deadline = time.monotonic() + 30
        while True:
            ready, _, _ = select.select([master], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                raise TimeoutError(result.decode(errors="replace"))
            try:
                block = os.read(master, 4096)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
            if not block:
                break
            result.extend(block)
        assert process.wait(timeout=3) == 0, result.decode()
        return result.decode()
    finally:
        os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait()


home = session([], 'bad\nq\n')
assert "请选择列表中的节点" in home
assert "导出全部用户" in home and "socks-11080@bob" not in home
expanded = session([], 'a\nq\n')
assert "socks-11080@bob" in expanded and "@paused" not in expanded
alice = session(["alice"], 'a\nq\n')
assert "ss-18080@alice" in alice and "导出全部用户" not in alice and "@bob" not in alice
single = session(["__admin__", '["socks-11080"]'], 'invalid\n1\n\n')
assert "请选择 1、2 或 3" in single and "socks5://" in single and "ss-18080" not in single
batch = session(["__admin__", '["socks-11080","ss-18080"]'], 'b\n1\nxq\n')
assert "ss://" in batch and "socks5://" in batch and "trojan-18443" not in batch
assert "type: socks5" not in batch and "导出全部用户" not in batch
print("PASS stage F PTY home, explicit all, user detail, single install and install-batch navigation")
