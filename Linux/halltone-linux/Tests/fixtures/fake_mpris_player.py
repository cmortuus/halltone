#!/usr/bin/env python3
"""A tiny MPRIS player for the integration tests: owns org.mpris.MediaPlayer2.<name> on the session
bus and implements Play / Pause / PlayPause / Next / Previous over a real D-Bus connection.

usage: fake_mpris_player.py <name> <Playing|Paused|Stopped> [identity]
Prints "ready" once the name is owned. Stays up until killed."""
import sys

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

name = sys.argv[1]
state = {"status": sys.argv[2], "track": 1}
identity = sys.argv[3] if len(sys.argv) > 3 else "Fake Player " + name

XML = """
<node>
  <interface name="org.mpris.MediaPlayer2">
    <property name="Identity" type="s" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="Play"/><method name="Pause"/><method name="PlayPause"/>
    <method name="Next"/><method name="Previous"/>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="Metadata" type="a{sv}" access="read"/>
  </interface>
</node>
"""
info = Gio.DBusNodeInfo.new_for_xml(XML)


def on_method(conn, sender, path, iface, method, params, invocation):
    if method == "Play":
        state["status"] = "Playing"
    elif method == "Pause":
        state["status"] = "Paused"
    elif method == "PlayPause":
        state["status"] = "Paused" if state["status"] == "Playing" else "Playing"
    elif method == "Next":
        state["track"] += 1
    elif method == "Previous":
        state["track"] = max(1, state["track"] - 1)
    invocation.return_value(None)


def on_get(conn, sender, path, iface, prop):
    if prop == "Identity":
        return GLib.Variant("s", identity)
    if prop == "PlaybackStatus":
        return GLib.Variant("s", state["status"])
    if prop == "Metadata":
        return GLib.Variant("a{sv}", {
            "mpris:trackid": GLib.Variant("o", "/fake/track/%d" % state["track"]),
            "xesam:title": GLib.Variant("s", "Track %d" % state["track"]),
        })
    return None


def on_bus(conn, _name):
    conn.register_object("/org/mpris/MediaPlayer2", info.interfaces[0], None, on_get, None)
    conn.register_object("/org/mpris/MediaPlayer2", info.interfaces[1], on_method, on_get, None)


def on_name(conn, _name):
    print("ready", flush=True)


Gio.bus_own_name(Gio.BusType.SESSION, "org.mpris.MediaPlayer2." + name,
                 Gio.BusNameOwnerFlags.NONE, on_bus, on_name, None)
GLib.MainLoop().run()
