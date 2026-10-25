#!/usr/bin/env bash
# ==============================================================================
# Dotfiles Installer & Deployer
# Hyprland + Waybar + Quickshell (MacShell & MacLock with Spotify Canvas)
# ==============================================================================
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${HOME}/.config/dotfiles_backup_$(date +%Y%m%d_%H%M%S)"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║             Deploying Dotfiles & macOS Desktop Rice            ║"
echo "╚════════════════════════════════════════════════════════════════╝"

mkdir -p "${HOME}/.config" "${HOME}/.local/bin" "${HOME}/.cache/maclock/canvas" "${HOME}/.cache/maclock/lyrics"

# 1. Symlink .config modules
echo "[1/4] Linking configuration directories..."
CONFIG_DIRS=(hypr waybar quickshell kitty macbar macdock maclock macshell macwidgets systemd)

for dir in "${CONFIG_DIRS[@]}"; do
    SRC="${DOTFILES_DIR}/.config/${dir}"
    DEST="${HOME}/.config/${dir}"

    if [ -d "${SRC}" ]; then
        if [ -e "${DEST}" ] && [ ! -L "${DEST}" ]; then
            mkdir -p "${BACKUP_DIR}"
            echo "  [i] Backing up existing ${DEST} -> ${BACKUP_DIR}/"
            mv "${DEST}" "${BACKUP_DIR}/"
        fi
        ln -sfn "${SRC}" "${DEST}"
        echo "  [✓] Linked ~/.config/${dir}"
    fi
done

# 2. Symlink bin scripts
echo "[2/4] Linking custom executables to ~/.local/bin..."
if [ -d "${DOTFILES_DIR}/bin" ]; then
    for script in "${DOTFILES_DIR}/bin"/*; do
        if [ -f "${script}" ]; then
            name="$(basename "${script}")"
            ln -sf "${script}" "${HOME}/.local/bin/${name}"
            chmod +x "${script}" "${HOME}/.local/bin/${name}"
            echo "  [✓] Linked ~/.local/bin/${name}"
        fi
    done
fi

# 3. Systemd User Timer (Monthly Cache Cleaner)
echo "[3/4] Registering systemd user timer for automated cache clearing..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload || true
    systemctl --user enable --now maclock-clear-cache.timer 2>/dev/null || true
    echo "  [✓] maclock-clear-cache.timer activated"
fi

# 4. Spotify & SpotX setup check
echo "[4/4] Checking Spotify & Canvas configuration..."
if [ ! -f "${HOME}/.config/maclock/sp_dc" ]; then
    echo "  [!] Notice: ~/.config/maclock/sp_dc does not exist yet."
    echo "      To activate animated Spotify Canvas videos on your lock screen:"
    echo "      echo 'YOUR_SP_DC_COOKIE' > ~/.config/maclock/sp_dc && chmod 600 ~/.config/maclock/sp_dc"
else
    echo "  [✓] Spotify session cookie detected."
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                     Deployment Complete!                       ║"
echo "║  Run 'spotify/install-spotify.sh' to patch Spotify with SpotX. ║"
echo "╚════════════════════════════════════════════════════════════════╝"
