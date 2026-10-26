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

echo "[*] Removing poisoned .bak libraries and pointing symlinks to patched driver..."
rm -f "$LIB_DIR/libfprint-2.so.2.0.0.bak" "$ALT_LIB_DIR/libfprint-2.so.2.0.0.bak" 2>/dev/null || true

cp -f "$SCRIPT_DIR/libfprint-2.so.2.0.0" "$LIB_DIR/libfprint-2.so.2.0.0"
chmod 644 "$LIB_DIR/libfprint-2.so.2.0.0"

# Point soname symlinks directly to the patched 2.0.0 binary
ln -sf libfprint-2.so.2.0.0 "$LIB_DIR/libfprint-2.so.2"
if [ -d "$ALT_LIB_DIR" ]; then
    ln -sf libfprint-2.so.2.0.0 "$ALT_LIB_DIR/libfprint-2.so.2"
fi

ldconfig
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
echo "        fprintd-enroll"
echo "    Then test verification with:"
echo "        fprintd-verify"
echo "======================================================================="
