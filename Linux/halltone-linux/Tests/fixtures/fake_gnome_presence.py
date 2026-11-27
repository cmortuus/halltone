#!/usr/bin/env python3
"""A tiny GNOME for the presence tests: owns org.gnome.Mutter.IdleMonitor (GetIdletime) and
org.gnome.ScreenSaver (GetActive) on the session bus. The answers come from a state file that the
test rewrites at any time: two lines, "<idle milliseconds>" and "<locked|unlocked>".

usage: fake_gnome_presence.py <state file>
Prints "ready" once both names are owned. Stays up until killed."""
import sys

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

path = sys.argv[1]


def state():
    try:
        lines = open(path).read().split()
        return int(lines[0]), lines[1] == "locked"
    except Exception:
        return 0, False


IDLE_XML = """<node><interface name="org.gnome.Mutter.IdleMonitor">
  <method name="GetIdletime"><arg type="t" direction="out"/></method></interface></node>"""
SAVER_XML = """<node><interface name="org.gnome.ScreenSaver">
  <method name="GetActive"><arg type="b" direction="out"/></method></interface></node>"""
idle_info = Gio.DBusNodeInfo.new_for_xml(IDLE_XML)
saver_info = Gio.DBusNodeInfo.new_for_xml(SAVER_XML)
owned = set()


def on_idle(conn, sender, p, iface, method, params, inv):
    inv.return_value(GLib.Variant("(t)", (state()[0],)))


def on_saver(conn, sender, p, iface, method, params, inv):
    inv.return_value(GLib.Variant("(b)", (state()[1],)))


def ready(name):
    owned.add(name)
    if len(owned) == 2:
        print("ready", flush=True)


def idle_bus(conn, _n):
    conn.register_object("/org/gnome/Mutter/IdleMonitor/Core", idle_info.interfaces[0], on_idle, None, None)


def saver_bus(conn, _n):
    conn.register_object("/org/gnome/ScreenSaver", saver_info.interfaces[0], on_saver, None, None)


Gio.bus_own_name(Gio.BusType.SESSION, "org.gnome.Mutter.IdleMonitor", Gio.BusNameOwnerFlags.NONE,
                 idle_bus, lambda c, n: ready(n), None)
Gio.bus_own_name(Gio.BusType.SESSION, "org.gnome.ScreenSaver", Gio.BusNameOwnerFlags.NONE,
                 saver_bus, lambda c, n: ready(n), None)
GLib.MainLoop().run()
