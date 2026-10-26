#!/usr/bin/env python3
"""
fprint-listener.py - Biometric fingerprint listener daemon for MacLock
Communicates with fprintd over system D-Bus and outputs JSON events to stdout.
"""

import sys
import os
import signal
import json
import pwd
import time

LOG_FILE = "/tmp/fprint-listener.log"

def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%X')}] {msg}\n")
    except Exception:
        pass

log("Starting fprint-listener.py...")

try:
    import dbus
    import dbus.mainloop.glib
    from gi.repository import GLib
except ImportError as e:
    err = json.dumps({"status": "unavailable", "reason": str(e)})
    sys.stdout.write(err + "\n")
    sys.stdout.flush()
    log(f"ImportError: {err}")
    sys.exit(0)

loop = None
bus = None
device = None
claimed = False
rearm_timer = None

def emit(event, **kwargs):
    payload = {"status": event}
    payload.update(kwargs)
    line = json.dumps(payload)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()
    log(f"EMIT: {line}")

def cleanup(*args):
    global loop, device, claimed, rearm_timer
    log("Cleanup called")
    if rearm_timer:
        try:
            GLib.source_remove(rearm_timer)
        except Exception:
            pass
        rearm_timer = None

    if device and claimed:
        try:
            device.VerifyStop(dbus_interface="net.reactivated.Fprint.Device")
        except Exception as e:
            log(f"VerifyStop exception: {e}")
        try:
            device.Release(dbus_interface="net.reactivated.Fprint.Device")
        except Exception as e:
            log(f"Release exception: {e}")
        claimed = False
    if loop and loop.is_running():
        GLib.idle_add(loop.quit)

def schedule_rearm(delay_ms=200):
    global rearm_timer
    if rearm_timer:
        try:
            GLib.source_remove(rearm_timer)
        except Exception:
            pass
    rearm_timer = GLib.timeout_add(delay_ms, do_rearm)
    log(f"Scheduled rearm in {delay_ms}ms")

def do_rearm():
    global rearm_timer, device, claimed
    rearm_timer = None
    if not claimed or not device:
        return False
    for attempt in range(8):
        try:
            device.VerifyStart("any", dbus_interface="net.reactivated.Fprint.Device")
            log(f"VerifyStart successfully re-armed on attempt {attempt}")
            emit("ready_waiting")
            return False
        except dbus.DBusException as e:
            name = e.get_dbus_name()
            err_str = str(e)
            log(f"rearm DBusException (attempt {attempt}): {name} - {err_str}")
            if "AlreadyInUse" in name or "AlreadyInUse" in err_str:
                try:
                    device.VerifyStop(dbus_interface="net.reactivated.Fprint.Device")
                except Exception:
                    pass
                time.sleep(0.08)
                continue
            elif "ClaimDevice" in name or "ClaimDevice" in err_str:
                try:
                    username = pwd.getpwuid(os.getuid()).pw_name
                    device.Claim(username, dbus_interface="net.reactivated.Fprint.Device")
                    device.VerifyStart("any", dbus_interface="net.reactivated.Fprint.Device")
                    log("Re-claimed and re-armed VerifyStart")
                    emit("ready_waiting")
                    return False
                except Exception as e2:
                    log(f"Re-claim failed: {e2}")
            return False
        except Exception as e:
            log(f"rearm generic exception: {e}")
            return False
    # If still busy after 8 immediate retries, try again in 150ms
    rearm_timer = GLib.timeout_add(150, do_rearm)
    return False

def on_verify_status(result, done):
    log(f"on_verify_status: result={result}, done={done}")
    if result == "verify-match":
        emit("matched")
        cleanup()
    elif result == "verify-no-match":
        emit("no-match")
        try:
            device.VerifyStop(dbus_interface="net.reactivated.Fprint.Device")
        except Exception:
            pass
        if done:
            schedule_rearm(300)
    elif result in ("verify-swipe-too-short", "verify-finger-not-centered", "verify-remove-and-retry", "verify-retry-scan"):
        emit("retry", reason=result)
        try:
            device.VerifyStop(dbus_interface="net.reactivated.Fprint.Device")
        except Exception:
            pass
        if done:
            schedule_rearm(250)
    else:
        emit("status", result=result)
        if done:
            try:
                device.VerifyStop(dbus_interface="net.reactivated.Fprint.Device")
            except Exception:
                pass
            schedule_rearm(250)

def on_verify_finger_selected(finger_name):
    log(f"on_verify_finger_selected: {finger_name}")
    emit("finger-selected", finger=finger_name)

def on_properties_changed(interface, changed, invalidated):
    if interface != "net.reactivated.Fprint.Device":
        return
    if "finger-present" in changed:
        present = bool(changed["finger-present"])
        log(f"finger-present: {present}")
        if present:
            emit("touch")

def main():
    global loop, bus, device, claimed

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

        # Claim with retry in case previous locker just exited
        claimed = False
        for attempt in range(15):
            try:
                device.Claim(username)
                claimed = True
                break
            except dbus.DBusException as ce:
                if "AlreadyInUse" in ce.get_dbus_name() and attempt < 14:
                    time.sleep(0.2)
                    continue
                raise

        # Connect signals cleanly on dev_obj
        dev_obj.connect_to_signal("VerifyStatus", on_verify_status, dbus_interface="net.reactivated.Fprint.Device")
        dev_obj.connect_to_signal("VerifyFingerSelected", on_verify_finger_selected, dbus_interface="net.reactivated.Fprint.Device")
        dev_obj.connect_to_signal("PropertiesChanged", on_properties_changed, dbus_interface="org.freedesktop.DBus.Properties")

        device.VerifyStart("any")
        emit("ready", device=str(dev_path), user=username)
        log("VerifyStart succeeded and ready emitted")
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
