#!/usr/bin/env bash
# ==============================================================================
# setup-fingerprint.sh - Automated setup for FocalTech Fingerprint Sensor (2808:c6d5)
# Configures fprintd, installs patched libfprint, sets udev & polkit rules, and updates PAM.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEVICE_VENDOR_ID="2808"
DEVICE_PRODUCT_ID="c6d5"
DEVICE_ID="${DEVICE_VENDOR_ID}:${DEVICE_PRODUCT_ID}"

if [ "$EUID" -ne 0 ]; then
    echo "[-] This script must be run with root privileges (sudo)." >&2
    echo "    Usage: sudo bash $0" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

echo "[*] Target user: $TARGET_USER ($TARGET_HOME)"
echo "[*] Checking for FocalTech Fingerprint Device ($DEVICE_ID)..."

# Read sysfs directly so detection does not depend on usbutils being installed.
DEVICE_FOUND=0
for usb_device in /sys/bus/usb/devices/*; do
    if [[ -r "$usb_device/idVendor" && -r "$usb_device/idProduct" ]]; then
        read -r usb_vendor < "$usb_device/idVendor"
        read -r usb_product < "$usb_device/idProduct"
        if [[ "$usb_vendor" == "$DEVICE_VENDOR_ID" && "$usb_product" == "$DEVICE_PRODUCT_ID" ]]; then
            DEVICE_FOUND=1
            break
        fi
    fi
done

if [ "$DEVICE_FOUND" -ne 1 ]; then
    echo "[-] USB device $DEVICE_ID was not detected; refusing to install a device-specific driver." >&2
    exit 1
fi
echo "[+] Found FocalTech Fingerprint Device (ID $DEVICE_ID)."

# 1. Ensure fprintd and libpam-fprintd packages are installed
echo "[*] Ensuring fprintd and libpam-fprintd packages are installed..."
apt-get update -qq
apt-get install -y --no-install-recommends fprintd libpam-fprintd libfprint-2-2

# Resolve and stage the FocalTech host matcher before changing the active
# library or stopping fprintd, so a missing archive cannot leave a half setup.
ENGINE_INSTALL_DIR="/usr/lib/libfprint-2"
ENGINE_INSTALL_PATH="$ENGINE_INSTALL_DIR/ftWbioEngineAdapter.dll"
ENGINE_DLL_SOURCE=""
for candidate in \
    "$SCRIPT_DIR/ftWbioEngineAdapter.dll" \
    "$TARGET_HOME/Downloads/Fingerprint/x64/ftWbioEngineAdapter.dll" \
    "/tmp/k14s-fingerprint/Fingerprint/x64/ftWbioEngineAdapter.dll"; do
    if [ -r "$candidate" ]; then
        ENGINE_DLL_SOURCE="$candidate"
        break
    fi
done

ENGINE_TMP_DIR=""
if [ -z "$ENGINE_DLL_SOURCE" ]; then
    ENGINE_ARCHIVE="$TARGET_HOME/Downloads/MEGABOOK K14S AMD 7000_20260609.7z"
    if [ ! -r "$ENGINE_ARCHIVE" ]; then
        echo "[-] Could not find ftWbioEngineAdapter.dll or the official MEGABOOK driver archive." >&2
        echo "    Expected: $ENGINE_ARCHIVE" >&2
        exit 1
    fi

    SEVEN_ZIP=""
    for candidate in 7z 7zz 7za; do
        if command -v "$candidate" >/dev/null 2>&1; then
            SEVEN_ZIP=$(command -v "$candidate")
            break
        fi
    done
    if [ -z "$SEVEN_ZIP" ]; then
        echo "[-] 7-Zip is required to extract the matcher DLL from $ENGINE_ARCHIVE" >&2
        exit 1
    fi

    ENGINE_TMP_DIR=$(mktemp -d)
    ENGINE_DLL_SOURCE="$ENGINE_TMP_DIR/ftWbioEngineAdapter.dll"
    if ! "$SEVEN_ZIP" x -so "$ENGINE_ARCHIVE" 'Fingerprint/x64/ftWbioEngineAdapter.dll' > "$ENGINE_DLL_SOURCE"; then
        echo "[-] Could not extract the matcher DLL from $ENGINE_ARCHIVE" >&2
        exit 1
    fi
fi

if [ ! -s "$ENGINE_DLL_SOURCE" ]; then
    echo "[-] FocalTech matcher DLL is missing or empty: $ENGINE_DLL_SOURCE" >&2
    exit 1
fi

# 2. Setup udev rule for device access
echo "[*] Installing udev rule for FocalTech fingerprint sensor..."
cat << 'EOF' > /etc/udev/rules.d/70-focaltech.rules
# FocalTech Fingerprint Sensor (2808:c6d5)
SUBSYSTEM=="usb", ATTRS{idVendor}=="2808", ATTRS{idProduct}=="c6d5", MODE="0660", GROUP="plugdev", TAG+="uaccess"
EOF

udevadm control --reload-rules
udevadm trigger

# Ensure target user is in plugdev group
if ! id -nG "$TARGET_USER" | grep -qw "plugdev"; then
    echo "[*] Adding $TARGET_USER to plugdev group..."
    usermod -a -G plugdev "$TARGET_USER"
fi

# 3. Setup Polkit rule to allow enrollment without external GUI agent
echo "[*] Installing Polkit rule for fingerprint enrollment and verification..."
mkdir -p /etc/polkit-1/rules.d
cat << 'EOF' > /etc/polkit-1/rules.d/50-fprintd.rules
/* Allow users in plugdev or sudo group to enroll/verify fingerprints without GUI prompt */
polkit.addRule(function(action, subject) {
    if ((action.id == "net.reactivated.fprint.device.enroll" ||
         action.id == "net.reactivated.fprint.device.verify" ||
         action.id == "net.reactivated.fprint.device.setusername") &&
        (subject.isInGroup("plugdev") || subject.isInGroup("sudo"))) {
        return polkit.Result.YES;
    }
});
EOF

systemctl restart polkit 2>/dev/null || true

# 4. Install verified patched libfprint with 2808:c6d5 support and fix symlinks
LIB_DIR="/usr/lib/x86_64-linux-gnu"
ALT_LIB_DIR="/lib/x86_64-linux-gnu"

echo "[*] Stopping fprintd service..."
systemctl stop fprintd 2>/dev/null || true
pkill -9 -f fprintd 2>/dev/null || true

echo "[*] Re-initializing USB hardware sensor..."
for dev in /sys/bus/usb/devices/*; do
    if [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]]; then
        if [[ "$(< "$dev/idVendor")" == "$DEVICE_VENDOR_ID" && "$(< "$dev/idProduct")" == "$DEVICE_PRODUCT_ID" ]]; then
            if [[ -w "$dev/authorized" ]]; then
                echo "[*] Power cycling USB sensor ($dev)..."
                echo 0 > "$dev/authorized"
                sleep 0.5
                echo 1 > "$dev/authorized"
                sleep 1
            fi
            break
        fi
    fi
done

echo "[*] Installing patched libfprint driver..."
rm -f "$TARGET_HOME/.cache/focaltech_enrolled.bin" 2>/dev/null || true

# Keep old ELF backups out of the library directory. They carry the same SONAME
# and ldconfig can select one of them for libfprint-2.so.2 instead of our build.
BACKUP_ROOT="/root/libfprint-backups"
mkdir -p "$BACKUP_ROOT"
BACKUP_DIR=$(mktemp -d "$BACKUP_ROOT/setup-XXXXXX")
for old_lib in "$LIB_DIR"/libfprint-2.so.2.0.0.* "$ALT_LIB_DIR"/libfprint-2.so.2.0.0.*; do
    if [ -f "$old_lib" ]; then
        echo "[*] Moving old libfprint backup out of the loader directory: $old_lib"
        mv "$old_lib" "$BACKUP_DIR/"
    fi
done

cp -f "$SCRIPT_DIR/libfprint-2.so.2.0.0" "$LIB_DIR/libfprint-2.so.2.0.0"
chmod 644 "$LIB_DIR/libfprint-2.so.2.0.0"

install -D -m 644 "$ENGINE_DLL_SOURCE" "$ENGINE_INSTALL_PATH"
if [ -n "$ENGINE_TMP_DIR" ]; then
    rm -rf "$ENGINE_TMP_DIR"
    ENGINE_TMP_DIR=""
fi
echo "[+] Installed FocalTech host matcher to $ENGINE_INSTALL_PATH"

# Point soname symlinks directly to the patched 2.0.0 binary
ln -sf libfprint-2.so.2.0.0 "$LIB_DIR/libfprint-2.so.2"
if [ -d "$ALT_LIB_DIR" ]; then
    ln -sf libfprint-2.so.2.0.0 "$ALT_LIB_DIR/libfprint-2.so.2"
fi

ldconfig
ACTIVE_LIB=$(readlink -f "$LIB_DIR/libfprint-2.so.2")
EXPECTED_LIB=$(readlink -f "$LIB_DIR/libfprint-2.so.2.0.0")
if [ "$ACTIVE_LIB" != "$EXPECTED_LIB" ]; then
    echo "[-] libfprint soname resolves to $ACTIVE_LIB, expected $EXPECTED_LIB" >&2
    exit 1
fi
echo "[+] Successfully installed patched libfprint to $LIB_DIR/libfprint-2.so.2"

# 5. Configure PAM for Hyprlock / Quickshell
echo "[*] Configuring PAM authentication in /etc/pam.d/hyprlock..."
cat << 'EOF' > /etc/pam.d/hyprlock
# PAM configuration for Hyprlock / MacLock with fingerprint support
auth    sufficient      pam_fprintd.so max_tries=1 timeout=10
@include common-auth
EOF

# 6. Restart fprintd daemon
echo "[*] Restarting fprintd service..."
if ! systemctl restart fprintd; then
    echo "[-] Could not restart fprintd. Service status follows:" >&2
    systemctl status fprintd --no-pager >&2 || true
    exit 1
fi

# Wait for fprintd to initialize on DBus
sleep 1.5

echo "[*] Available devices detected by fprintd:"
if ! fprintd-list "$TARGET_USER"; then
    echo "[-] fprintd is running, but device discovery failed for $TARGET_USER." >&2
    echo "    Check the service log with: sudo journalctl -u fprintd -b --no-pager" >&2
    exit 1
fi
echo "======================================================================="
echo "[+] Fingerprint driver and PAM integration successfully configured!"
echo "    Device: FocalTech Fingerprint Device ($DEVICE_ID)"
echo "======================================================================="
echo "    To enroll your fingerprint now, run:"
echo "        test-fingerprint enroll"
echo "    Then test live verification with:"
echo "        test-fingerprint"
echo "======================================================================="
