"""Headless tests for halltone-tray's model (no display, no GTK): menu building, the control
socket client against a fake daemon, config edits. Run: python3 -m unittest discover -s Linux/tray"""
import importlib.machinery
import importlib.util
import json
import os
import socket
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("halltone_tray", os.path.join(HERE, "halltone-tray"))
_spec = importlib.util.spec_from_loader("halltone_tray", _loader)
tray = importlib.util.module_from_spec(_spec)
_loader.exec_module(tray)

IDLE = {"version": "0.1", "name": "Rig", "pairingCode": 4242, "port": 47800, "codec": "pcm", "frameMs": 2.5,
        "gameMode": True, "streaming": False, "listeners": [], "kbps": 0, "pps": 0,
        "dialog": {"configured": False}, "media": {"available": False}}
STREAMING = dict(IDLE, streaming=True, kbps=1612, pps=400,
                 listeners=[{"name": "Pixel Phone", "address": "192.168.1.9:50000", "bufferMs": 40, "lossPermille": 12}],
                 dialog={"configured": True, "enabled": True, "target": "local", "phase": "paused"},
                 media={"available": True, "player": "firefox", "status": "paused"})


class PresenceTests(unittest.TestCase):
    def labels(self, status):
        return [i.get("label", "") for i in tray.build_menu(status)]

    def test_shows_when_at_pc(self):
        self.assertTrue(any("at this PC" in l for l in self.labels(dict(STREAMING, presence={"atPC": True, "inputRecent": True}))))

    def test_hidden_when_away_or_unknown(self):
        self.assertFalse(any("at this PC" in l for l in self.labels(dict(STREAMING, presence={"atPC": False}))))
        self.assertFalse(any("at this PC" in l for l in self.labels(dict(STREAMING, presence={}))))


class FakeDaemon:
    """Serves one reply per connection on a unix socket, like the real control socket."""
    def __init__(self, path, replies):
        self.path, self.replies, self.lines = path, replies, []
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(4)
        self.t = threading.Thread(target=self.serve, daemon=True)
        self.t.start()

    def serve(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            line = b""
            while not line.endswith(b"\n"):
                d = c.recv(1)
                if not d:
                    break
                line += d
            cmd = line.decode().strip()
            self.lines.append(cmd)
            c.sendall((self.replies.get(cmd, "error: unknown command") + "\n").encode())
            c.close()

    def close(self):
        self.srv.close()


class MenuTests(unittest.TestCase):
    def labels(self, status, note=None):
        return [i["label"] for i in tray.build_menu(status, note) if i["kind"] != "separator"]

    def test_not_running_offers_start(self):
        m = tray.build_menu(None)
        self.assertEqual(m[0]["label"], "Not running")
        self.assertIn("start", [i["action"] for i in m])
        self.assertNotIn("toggle_game", [i["action"] for i in m])
        self.assertEqual(tray.icon_for(None), tray.ICON_ERROR)
        self.assertEqual(tray.service_command("start"), ["systemctl", "--user", "start", "halltone"])

    def test_waiting_for_a_phone(self):
        labels = self.labels(IDLE)
        self.assertEqual(labels[0], "Waiting for a phone")
        self.assertIn("Pairing code: 4242   (click to copy)", labels)
        self.assertEqual(tray.icon_for(IDLE), tray.ICON_IDLE)
        self.assertIn("Dialog pause (not configured)", labels)

    def test_streaming_shows_listeners_and_toggles(self):
        m = tray.build_menu(STREAMING)
        labels = [i["label"] for i in m]
        self.assertEqual(labels[0], "Streaming to Pixel Phone")
        self.assertIn("   Pixel Phone (192.168.1.9:50000): buffer 40 ms, loss 1.2%", labels)
        self.assertIn("   Paused this PC's player for dialog", labels)
        self.assertIn("Media: firefox (paused)", labels)
        self.assertEqual(tray.icon_for(STREAMING), tray.ICON_STREAMING)
        by = {i["action"]: i for i in m if i["action"]}
        self.assertTrue(by["toggle_dialog"]["checked"] and by["toggle_dialog"]["enabled"])
        self.assertTrue(by["toggle_game"]["checked"])
        for a in ("restart", "logs", "quit", "copy_code"):
            self.assertIn(a, by)

    def test_capture_error_is_an_error_icon(self):
        st = dict(IDLE, captureError="pa_simple_new failed")
        self.assertEqual(tray.status_line(st), "Capture failed: pa_simple_new failed")
        self.assertEqual(tray.icon_for(st), tray.ICON_ERROR)

    def test_note_replaces_status_line(self):
        self.assertEqual(self.labels(IDLE, "Restarting…")[0], "Restarting…")

    def test_two_listeners(self):
        st = dict(STREAMING, listeners=STREAMING["listeners"] + [{"name": "iPad", "address": "a", "bufferMs": 1, "lossPermille": 0}])
        self.assertEqual(tray.status_line(st), "Streaming to Pixel Phone, iPad")

    def test_shape_ignores_label_changes(self):
        a = tray.build_menu(STREAMING)
        b = tray.build_menu(dict(STREAMING, kbps=1))
        self.assertEqual(tray.menu_shape(a), tray.menu_shape(b))
        self.assertNotEqual(tray.menu_shape(a), tray.menu_shape(tray.build_menu(IDLE)))

    def test_dump(self):
        text = tray.dump_menu(STREAMING)
        self.assertTrue(text.startswith("icon: halltone-streaming-symbolic"))
        self.assertIn("[x] Dialog pause", text)

    def test_terminal_command(self):
        cmd = tray.terminal_command(which=lambda n: "/usr/bin/" + n if n == "gnome-terminal" else None)
        self.assertEqual(cmd, ["/usr/bin/gnome-terminal", "--", "journalctl", "--user", "-u", "halltone", "-f"])
        self.assertIsNone(tray.terminal_command(which=lambda n: None))


class DaemonTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ht")
        self.sock = os.path.join(self.dir, "s.sock")

    def test_down_when_nothing_listens(self):
        self.assertIsNone(tray.fetch_status(self.sock))
        open(self.sock, "w").close()      # a stale file is not a daemon either
        self.assertIsNone(tray.fetch_status(self.sock))

    def test_fetch_status(self):
        d = FakeDaemon(self.sock, {"status --json": json.dumps(STREAMING)})
        try:
            self.assertEqual(tray.fetch_status(self.sock), STREAMING)
            self.assertEqual(tray.dump_menu(tray.fetch_status(self.sock)).splitlines()[1].strip(), "Streaming to Pixel Phone")
        finally:
            d.close()

    def test_garbage_reply_counts_as_down(self):
        d = FakeDaemon(self.sock, {"status --json": "error: unknown command"})
        try:
            self.assertIsNone(tray.fetch_status(self.sock))
        finally:
            d.close()

    def test_request_sends_the_line(self):
        d = FakeDaemon(self.sock, {"on": "ok: dialog pause on"})
        try:
            self.assertEqual(tray.request(self.sock, "on"), "ok: dialog pause on")
            self.assertEqual(d.lines, ["on"])
        finally:
            d.close()

    def test_paths(self):
        self.assertEqual(tray.socket_path({"XDG_RUNTIME_DIR": "/run/user/1000"}), "/run/user/1000/halltone-linux.sock")
        self.assertEqual(tray.config_path({"XDG_CONFIG_HOME": "/x"}), "/x/halltone/config.json")
        self.assertEqual(tray.config_path({"HOME": "/home/u"}), "/home/u/.config/halltone/config.json")


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.path = os.path.join(tempfile.mkdtemp(prefix="htc"), "halltone", "config.json")

    def test_game_mode_keeps_other_keys(self):
        tray.write_config(self.path, {"pairingCode": 1234, "name": "Rig", "dialogPause": {"target": "local"}})
        tray.set_game_mode(self.path, False)
        c = tray.read_config(self.path)
        self.assertEqual((c["codec"], c["frameMs"]), ("opus", 10))
        self.assertEqual((c["pairingCode"], c["name"], c["dialogPause"]), (1234, "Rig", {"target": "local"}))
        tray.set_game_mode(self.path, True)
        c = tray.read_config(self.path)
        self.assertEqual((c["codec"], c["frameMs"]), ("pcm", 2.5))

    def test_dialog_enabled_creates_and_merges(self):
        tray.set_dialog_enabled(self.path, True)
        self.assertEqual(tray.read_config(self.path), {"dialogPause": {"enabled": True}})
        c = tray.read_config(self.path)
        c["dialogPause"]["sourceApp"] = "Game"
        tray.write_config(self.path, c)
        tray.set_dialog_enabled(self.path, False)
        self.assertEqual(tray.read_config(self.path)["dialogPause"], {"enabled": False, "sourceApp": "Game"})


if __name__ == "__main__":
    unittest.main()
