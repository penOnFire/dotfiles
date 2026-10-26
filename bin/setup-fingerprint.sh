#!/usr/bin/env bash
# ==============================================================================
# setup-fingerprint.sh - Automated setup for FocalTech Fingerprint Sensor (2808:c6d5)
# Configures fprintd, installs patched libfprint, sets udev & polkit rules, and updates PAM.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ "$EUID" -ne 0 ]; then
    echo "[-] This script must be run with root privileges (sudo)." >&2
    echo "    Usage: sudo bash $0" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

echo "[*] Target user: $TARGET_USER ($TARGET_HOME)"
echo "[*] Checking for FocalTech Fingerprint Device (2808:c6d5)..."

if lsusb -d 2808:c6d5 >/dev/null 2>&1; then
    echo "[+] Found FocalTech Fingerprint Device (ID 2808:c6d5)!"
else
    echo "[!] Warning: USB device 2808:c6d5 not detected via lsusb."
fi

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
echo "[*] Terminating any stale fprintd processes and restarting service..."
pkill -9 -f fprintd 2>/dev/null || true
systemctl restart fprintd 2>/dev/null || true

# Wait for fprintd to initialize on DBus
sleep 1.5

echo "======================================================================="
echo "[+] Fingerprint driver and PAM integration successfully configured!"
echo "    Device: FocalTech Fingerprint Device (2808:c6d5)"
echo ""
echo "[*] Available devices detected by fprintd:"
fprintd-list "$TARGET_USER" || true
echo "======================================================================="
echo "    To enroll your fingerprint now, run:"
echo "        fprintd-enroll"
echo "    Then test verification with:"
echo "        fprintd-verify"
echo "======================================================================="
