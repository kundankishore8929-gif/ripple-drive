"""Windows checks for the shared uploader (bin/ripple-drive-upload), run by .github/workflows/windows.yml.

Covers what differs on Windows: drive-letter paths, the upload lock, the Recycle Bin and junk files. The Google
side is the same code as on the Mac and needs a real account, so it isn't tested here.
  python -I windows/tests/test_windows.py
"""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UPLOADER = os.path.join(ROOT, "bin", "ripple-drive-upload")
os.environ["RD_MOUNT"] = "R:"


def load():
    loader = importlib.machinery.SourceFileLoader("rdu", UPLOADER)
    spec = importlib.util.spec_from_loader("rdu", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


rdu = load()


class Paths(unittest.TestCase):
    def test_in_mount(self):
        for p in ("R:", "R:\\", "r:\\My Drive\\x.mov", "R:/Shared with me/a"):
            self.assertTrue(rdu.in_mount(p), p)
        for p in ("C:\\Users\\x", "RX:\\a", "D:\\R:\\x"):
            self.assertFalse(rdu.in_mount(p), p)

    def test_normalise_dest(self):
        cases = {
            "R:\\My Drive\\Raw archive": "My Drive/Raw archive",
            "r:\\Shared with me\\Team\\2026": "Shared with me/Team/2026",
            "R:\\": "My Drive",
            "Raw archive": "My Drive/Raw archive",
            "My Drive/Uploads from PC": "My Drive/Uploads from PC",
        }
        for given, want in cases.items():
            self.assertEqual(rdu.normalise_dest(given), want, given)

    def test_windows_defaults(self):
        self.assertTrue(rdu.WINDOWS)
        self.assertTrue(rdu.STATE.lower().endswith("rippledrive\\uploads"), rdu.STATE)
        self.assertTrue(rdu.RCLONE.lower().endswith("rippledrive\\bin\\rclone.exe"), rdu.RCLONE)
        self.assertEqual(rdu.DEFAULT_DEST, "My Drive/Uploads from PC")


class Queue(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)
        rdu.STATE = self.state

    def test_folder_walk_skips_junk(self):
        src = os.path.join(self.tmp, "shoot day 2")
        os.makedirs(os.path.join(src, "audio"))
        for rel in ("a.mov", "audio\\b.wav", "Thumbs.db", "desktop.ini", "audio\\desktop.ini"):
            with open(os.path.join(src, rel), "wb") as f:
                f.write(b"x" * 10)
        n = rdu.enqueue([src], "R:\\My Drive\\Raw", False)
        self.assertEqual(n, 2)
        items = rdu.pending()
        dests = sorted(i["dest"] for i in items)
        self.assertEqual(dests, ["My Drive/Raw/shoot day 2", "My Drive/Raw/shoot day 2/audio"])
        self.assertTrue(all(os.path.isfile(i["source"]) for i in items))

    def test_skips_files_already_in_the_drive(self):
        self.assertEqual(rdu.enqueue(["R:\\My Drive\\x.mov"], "My Drive", False), 0)

    def test_lock_is_exclusive(self):
        lock = open(os.path.join(self.state, ".lock"), "a+")
        rdu.take_lock(lock)
        probe = ("import importlib.machinery as m, importlib.util as u, os, sys\n"
                 "l = m.SourceFileLoader('rdu', sys.argv[1]); s = u.spec_from_loader('rdu', l)\n"
                 "r = u.module_from_spec(s); l.exec_module(r)\n"
                 "f = open(os.path.join(sys.argv[2], '.lock'), 'a+')\n"
                 "try:\n    r.take_lock(f)\nexcept OSError:\n    sys.exit(3)\nsys.exit(0)\n")
        busy = subprocess.run([sys.executable, "-c", probe, UPLOADER, self.state])
        self.assertEqual(busy.returncode, 3, "a second uploader got the lock while the first held it")
        lock.close()
        free = subprocess.run([sys.executable, "-c", probe, UPLOADER, self.state])
        self.assertEqual(free.returncode, 0, "the lock wasn't free after the first uploader let go")


class RecycleBin(unittest.TestCase):
    def test_trash_file_and_folder(self):
        tmp = tempfile.mkdtemp(dir=os.path.expanduser("~"))
        f = os.path.join(tmp, "ripple drive test %d.txt" % os.getpid())
        with open(f, "w") as h:
            h.write("bye")
        self.assertTrue(rdu.trash(f))
        self.assertFalse(os.path.exists(f))
        d = os.path.join(tmp, "ripple drive folder %d" % os.getpid())
        os.makedirs(os.path.join(d, "inner"))
        self.assertTrue(rdu.trash(d))
        self.assertFalse(os.path.exists(d))
        names = subprocess.run(["powershell", "-NoProfile", "-Command",
                                "(New-Object -ComObject Shell.Application).Namespace(10).Items() | ForEach-Object { $_.Name }"],
                               capture_output=True, text=True).stdout
        self.assertIn("ripple drive test %d" % os.getpid(), names)


class Log(unittest.TestCase):
    def test_log_is_utf8(self):
        rdu.LOG = os.path.join(tempfile.mkdtemp(), "uploads.log")
        rdu.log("uploaded Café ☕ 東京.mov to My Drive/x (1.0 MB, MD5 matches)")
        with open(rdu.LOG, encoding="utf-8") as f:
            self.assertIn("東京", f.read())


if __name__ == "__main__":
    unittest.main(verbosity=2)
