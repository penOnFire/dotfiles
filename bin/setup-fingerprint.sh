#!/usr/bin/env bash
# ==============================================================================
# setup-fingerprint.sh - Automated setup for FocalTech Fingerprint Sensor (2808:c6d5)
# Configures fprintd, installs patched libfprint, sets udev rules, and updates PAM.
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
    echo "    Continuing anyway..."
fi

# 1. Install dependencies and system packages if needed
echo "[*] Ensuring fprintd, libpam-fprintd, and system packages are installed..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    fprintd \
    libpam-fprintd \
    libfprint-2-2

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

# 3. Install patched libfprint with 2808:c6d5 support
SYSTEM_LIB="/usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0"

if [ -f "$SCRIPT_DIR/libfprint-2.so.2.0.0" ]; then
    echo "[*] Installing bundled patched libfprint-2.so.2.0.0 (contains 2808:c6d5 support)..."
    if [ -f "$SYSTEM_LIB" ] && [ ! -f "${SYSTEM_LIB}.bak" ]; then
        cp "$SYSTEM_LIB" "${SYSTEM_LIB}.bak"
    fi
    cp "$SCRIPT_DIR/libfprint-2.so.2.0.0" "$SYSTEM_LIB"
    chmod 644 "$SYSTEM_LIB"
    ldconfig
    echo "[+] Successfully installed patched libfprint to $SYSTEM_LIB"
else
    echo "[*] Building patched libfprint from source..."
    BUILD_DIR="/tmp/libfprint-src-build"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    apt-get source libfprint-2-2
    MOC_C=$(find "$BUILD_DIR" -type f -name "focaltech_moc.c" | head -n1)
    if [ -n "$MOC_C" ]; then
        SRC_DIR=$(dirname $(dirname $(dirname $(dirname "$MOC_C"))))
        if ! grep -q "0xc6d5" "$MOC_C"; then
            sed -i '/static const FpIdEntry id_table\[\] = {/a \  { .vid = 0x2808,  .pid = 0xc6d5,  },' "$MOC_C"
        fi
        cd "$SRC_DIR"
        meson setup build --prefix=/usr --libdir=lib/x86_64-linux-gnu -Dintrospection=false -Ddoc=false -Dudev_rules=disabled -Dudev_hwdb=disabled
        meson compile -C build
        meson install -C build
        ldconfig
        echo "[+] Successfully built and installed patched libfprint!"
    fi
fi

# 4. Configure PAM for Hyprlock / Quickshell
echo "[*] Configuring PAM authentication in /etc/pam.d/hyprlock..."
cat << 'EOF' > /etc/pam.d/hyprlock
# PAM configuration for Hyprlock / MacLock with fingerprint support
auth    sufficient      pam_fprintd.so max_tries=1 timeout=10
@include common-auth
EOF

# 5. Restart fprintd daemon
echo "[*] Enabling and restarting fprintd service..."
systemctl daemon-reload
systemctl enable fprintd
systemctl restart fprintd

# Wait 1 second for fprintd to settle on DBus
sleep 1

echo "======================================================================="
echo "[+] Fingerprint driver and PAM integration successfully configured!"
echo "    Device: FocalTech Fingerprint Device (2808:c6d5)"
echo ""
echo "[*] Checking available devices via fprintd-list:"
fprintd-list "$TARGET_USER" || true
echo ""
echo "======================================================================="
echo "    To enroll your fingerprint now, run:"
echo "        fprintd-enroll"
echo "    Then test verification with:"
echo "        fprintd-verify"
echo "======================================================================="
