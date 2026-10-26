#!/usr/bin/env bash
# ==============================================================================
# setup-fingerprint.sh - Automated setup for FocalTech Fingerprint Sensor (2808:c6d5)
# Configures fprintd, builds patched libfprint, sets udev rules, and updates PAM.
# ==============================================================================
set -euo pipefail

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
    echo "    Continuing with driver and daemon installation anyway..."
fi

# 1. Install dependencies and system packages
echo "[*] Installing fprintd, libpam-fprintd, and build dependencies..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    fprintd \
    libpam-fprintd \
    libfprint-2-2 \
    libgusb-dev \
    libgudev-1.0-dev \
    libglib2.0-dev \
    libnss3-dev \
    libpixman-1-dev \
    meson \
    ninja-build \
    build-essential \
    pkg-config \
    git

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

# 3. Patch and build libfprint with 2808:c6d5 support
BUILD_DIR="/tmp/libfprint-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "[*] Fetching Debian libfprint source..."
apt-get source libfprint-2-2

LIBFPRINT_SRC=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "libfprint-*" | head -n1)
if [ -z "$LIBFPRINT_SRC" ]; then
    echo "[-] Failed to fetch libfprint source." >&2
    exit 1
fi

echo "[*] Patching $LIBFPRINT_SRC/libfprint/drivers/focaltech_moc/focaltech_moc.c..."
MOC_C="$LIBFPRINT_SRC/libfprint/drivers/focaltech_moc/focaltech_moc.c"

if ! grep -q "0xc6d5" "$MOC_C"; then
    sed -i '/static const FpIdEntry id_table\[\] = {/a \  { .vid = 0x2808,  .pid = 0xc6d5,  },' "$MOC_C"
    echo "[+] Successfully added 0x2808:0xc6d5 to focaltech_moc driver!"
else
    echo "[*] 0x2808:0xc6d5 already present in focaltech_moc.c"
fi

echo "[*] Compiling patched libfprint..."
cd "$LIBFPRINT_SRC"
rm -rf build
meson setup build --prefix=/usr
meson compile -C build
meson install -C build
ldconfig

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

echo "======================================================================="
echo "[+] Fingerprint driver and PAM integration successfully configured!"
echo "    Device: FocalTech Fingerprint Device (2808:c6d5)"
echo "    Status: fprintd service is active"
echo ""
echo "    To enroll your fingerprint now, run:"
echo "        fprintd-enroll"
echo "    Then verify with:"
echo "        fprintd-verify"
echo "======================================================================="
