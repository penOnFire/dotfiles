#!/usr/bin/env bash
# Helper script to set up Spotify with Wayland support and SpotX-Bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
SPOTIFY_LOCAL="${HOME}/.local/share/spotify/spotify"

echo "=== Spotify + Wayland + SpotX-Bash Setup ==="

mkdir -p "${BIN_DIR}" "${HOME}/.config/maclock" "${HOME}/.cache/maclock/canvas"

# 1. Install Wayland wrapper
cat << 'EOF' > "${BIN_DIR}/spotify"
#!/usr/bin/env bash
if [ -x "$HOME/.local/share/spotify/spotify" ]; then
    exec "$HOME/.local/share/spotify/spotify" --enable-features=UseOzonePlatform --ozone-platform=wayland "$@"
elif command -v /usr/bin/spotify >/dev/null 2>&1; then
    exec /usr/bin/spotify --enable-features=UseOzonePlatform --ozone-platform=wayland "$@"
else
    echo "Error: Spotify binary not found." >&2
    exit 1
fi
EOF
chmod +x "${BIN_DIR}/spotify"
echo "[✓] Installed Spotify Wayland wrapper to ${BIN_DIR}/spotify"

# 2. Run SpotX-Bash if Spotify client binary exists
if [ -x "${SPOTIFY_LOCAL}" ] || command -v /usr/bin/spotify >/dev/null 2>&1; then
    echo "[*] Launching SpotX-Bash patcher..."
    bash "${SCRIPT_DIR}/spotx.sh" -c -f || true
    echo "[✓] SpotX-Bash applied."
else
    echo "[!] Spotify binary not detected yet. Please install Spotify first, then rerun this script."
fi

# 3. Canvas instructions
echo ""
echo "=== Spotify Canvas Setup ==="
if [ -f "${HOME}/.config/maclock/sp_dc" ]; then
    echo "[✓] sp_dc cookie is configured in ~/.config/maclock/sp_dc!"
else
    echo "[!] sp_dc cookie not found in ~/.config/maclock/sp_dc."
    echo "    To enable animated Canvas video loops on the lockscreen:"
    echo "    1. Open https://open.spotify.com and log in."
    echo "    2. Press F12 -> Application/Storage -> Cookies -> copy 'sp_dc'."
    echo "    3. Run: echo 'YOUR_COOKIE' > ~/.config/maclock/sp_dc && chmod 600 ~/.config/maclock/sp_dc"
fi
echo "============================================"
