#!/usr/bin/env python3
"""
fprint-listener.py - Biometric fingerprint listener daemon for MacLock
Communicates with fprintd over system D-Bus and outputs JSON events to stdout.
"""

import sys
import os
import signal
import json
import time
import pwd

try:
    import dbus
    import dbus.mainloop.glib
    from gi.repository import GLib
except ImportError as e:
    sys.stdout.write(json.dumps({"status": "unavailable", "reason": str(e)}) + "\n")
    sys.stdout.flush()
    sys.exit(0)

loop = None
device = None
claimed = False

def emit(event, **kwargs):
    payload = {"status": event}
    payload.update(kwargs)
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()

def cleanup(*args):
    global loop, device, claimed
    if device and claimed:
        try:
            device.VerifyStop(dbus_interface="net.reactivated.Fprint.Device")
        except Exception:
            pass
        try:
            device.Release(dbus_interface="net.reactivated.Fprint.Device")
        except Exception:
            pass
        claimed = False
    if loop and loop.is_running():
        loop.quit()
    sys.exit(0)

def on_verify_status(result, done):
    if result == "verify-match":
        emit("matched")
        cleanup()
    elif result == "verify-no-match":
        emit("no-match")
        # Restart verification so user can try again
        if not done and device:
            try:
                device.VerifyStart("any", dbus_interface="net.reactivated.Fprint.Device")
            except Exception:
                pass
    elif result in ("verify-swipe-too-short", "verify-finger-not-centered", "verify-remove-and-retry"):
        emit("retry", reason=result)
    else:
        emit("status", result=result)

def on_verify_finger_selected(finger_name):
    emit("finger-selected", finger=finger_name)

def main():
    global loop, device, claimed

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    if os.environ.get("MACLOCK_TOUCHID_EMULATE") == "1":
        emit("ready", device="/dev/bus/usb/001/003", user=pwd.getpwuid(os.getuid()).pw_name)
        while True:
            time.sleep(1)

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    loop = GLib.MainLoop()

    try:
        bus = dbus.SystemBus()
    except Exception as e:
        emit("unavailable", reason=f"Cannot connect to system bus: {e}")
        return

    try:
        fprint_obj = bus.get_object("net.reactivated.Fprint", "/net/reactivated/Fprint/Manager")
        fprint_mgr = dbus.Interface(fprint_obj, "net.reactivated.Fprint.Manager")
        dev_path = fprint_mgr.GetDefaultDevice()
    except dbus.DBusException as e:
        emit("unavailable", reason=f"fprintd service not available: {e.get_dbus_name()}")
        return
    except Exception as e:
        emit("unavailable", reason=str(e))
        return

    try:
        dev_obj = bus.get_object("net.reactivated.Fprint", dev_path)
        device = dbus.Interface(dev_obj, "net.reactivated.Fprint.Device")
        
        username = pwd.getpwuid(os.getuid()).pw_name
        device.Claim(username)
        claimed = True

        dev_obj.connect_to_signal("VerifyStatus", on_verify_status, dbus_interface="net.reactivated.Fprint.Device")
        dev_obj.connect_to_signal("VerifyFingerSelected", on_verify_finger_selected, dbus_interface="net.reactivated.Fprint.Device")

        device.VerifyStart("any")
        emit("ready", device=str(dev_path), user=username)
    except dbus.DBusException as e:
        emit("unavailable", reason=f"Device claim/verify failed: {e.get_dbus_name()}")
        cleanup()
        return
    except Exception as e:
        emit("unavailable", reason=str(e))
        cleanup()
        return

    try:
        loop.run()
    except (KeyboardInterrupt, SystemExit):
        cleanup()

if __name__ == "__main__":
    main()
