#!/usr/bin/env python3
"""
Spotify Canvas Fetcher for MacLock Animated Lock Screen
Downloads looping canvas video for supported Spotify music and caches in ~/.cache/maclock/canvas/
Outputs the local .mp4 path to stdout if found.
"""

import sys
import os
import re
import json
import time
import struct
import hmac
import hashlib
import urllib.parse
import urllib.request
import subprocess

DEFAULT_SECRET_VER = 61
DEFAULT_SECRET = ",7/*F(\"rLJ2oxaKL^f+E1xvP@N"

def get_track_id(raw):
    if not raw:
        return None
    raw = raw.strip()
    # If format is spotify:track:XXX
    m = re.search(r'spotify:track:([a-zA-Z0-9]{22})', raw)
    if m:
        return m.group(1)
    # If URL
    m = re.search(r'track/([a-zA-Z0-9]{22})', raw)
    if m:
        return m.group(1)
    # If standard 22-char base62
    if re.match(r'^[a-zA-Z0-9]{22}$', raw):
        return raw
    return None

def discover_spotify_track_id():
    """Read Spotify's standard MPRIS URL if Quickshell passed only title/artist."""
    try:
        players = subprocess.run(["playerctl", "-l"], capture_output=True, text=True, timeout=3, check=False)
        for player in players.stdout.splitlines():
            if "spotify" not in player.lower():
                continue
            result = subprocess.run(
                ["playerctl", "-p", player, "metadata", "xesam:url"],
                capture_output=True, text=True, timeout=3, check=False
            )
            track_id = get_track_id(result.stdout)
            if track_id:
                return track_id
    except (OSError, subprocess.SubprocessError):
        pass
    return None

def log_err(cache_dir, msg):
    try:
        os.makedirs(cache_dir, exist_ok=True)
        with open(os.path.join(cache_dir, "last-error.log"), "a", encoding="utf-8") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except OSError:
        pass

def read_sp_dc():
    v = os.environ.get("SP_DC", "").strip()
    if v:
        return v
    try:
        with open(os.path.expanduser("~/.config/maclock/sp_dc"), "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)

def ld(tag, payload):
    return bytes([(tag << 3) | 2]) + varint(len(payload)) + payload

def generate_totp(secret_bytes, timestamp_ms):
    counter = int(timestamp_ms // 1000 // 30)
    buf = struct.pack(">Q", counter)
    digest = hmac.new(secret_bytes, buf, hashlib.sha1).digest()
    offset = digest[-1] & 0x0f
    code = (struct.unpack(">I", digest[offset:offset+4])[0] & 0x7fffffff) % 1000000
    return f"{code:06d}"

def get_access_token(cache_dir):
    token_file = os.path.join(cache_dir, "token.json")
    now_ms = int(time.time() * 1000)

    # 1. Check cached token
    if os.path.exists(token_file):
        try:
            with open(token_file, "r", encoding="utf-8") as f:
                tdata = json.load(f)
            expires = tdata.get("expires", 0)
            token = tdata.get("token")
            if token and expires > (now_ms + 120_000): # buffer 2 minutes
                return token
        except (OSError, json.JSONDecodeError):
            pass

    # 2. Acquire fresh token using sp_dc cookie & TOTP
    sp_dc = read_sp_dc()
    if not sp_dc:
        log_err(cache_dir, "sp_dc cookie not found in ~/.config/maclock/sp_dc")
        return None

    # Derive secret bytes
    r = [ord(c) ^ ((idx % 33) + 9) for idx, c in enumerate(DEFAULT_SECRET)]
    secret_bytes = "".join(map(str, r)).encode("utf-8")

    # Fetch server time for sync
    server_time = None
    try:
        sreq = urllib.request.Request(
            "https://open.spotify.com/api/server-time",
            headers={"User-Agent": "Mozilla/5.0", "Cookie": f"sp_dc={sp_dc}"}
        )
        with urllib.request.urlopen(sreq, timeout=5) as sresp:
            sdata = json.loads(sresp.read().decode())
            server_time = int(sdata.get("serverTime", 0))
    except Exception:
        pass

    totp_client = generate_totp(secret_bytes, now_ms)
    totp_server = generate_totp(secret_bytes, server_time * 1000) if server_time else totp_client

    params = urllib.parse.urlencode({
        "reason": "init",
        "productType": "web-player",
        "totp": totp_client,
        "totpServer": totp_server,
        "totpVer": str(DEFAULT_SECRET_VER)
    })

    req = urllib.request.Request(
        f"https://open.spotify.com/api/token?{params}",
        headers={
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
            "Origin": "https://open.spotify.com",
            "Referer": "https://open.spotify.com/",
            "Cookie": f"sp_dc={sp_dc}"
        }
    )

    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode())
            token = data.get("accessToken")
            expires = data.get("accessTokenExpirationTimestampMs", now_ms + 3600_000)
            if token:
                try:
                    with open(token_file, "w", encoding="utf-8") as f:
                        json.dump({"token": token, "expires": expires}, f)
                except OSError:
                    pass
                return token
            log_err(cache_dir, f"token response missing accessToken: {data}")
    except Exception as e:
        log_err(cache_dir, f"token request error: {e!r}")

    return None

def fetch_canvas(track_id, cache_dir):
    os.makedirs(cache_dir, exist_ok=True)
    video_path = os.path.join(cache_dir, f"{track_id}.mp4")

    # Already downloaded?
    if os.path.exists(video_path) and os.path.getsize(video_path) > 1000:
        return video_path

    # Already checked and confirmed no canvas? (Cache negative response for 3 days)
    miss_path = os.path.join(cache_dir, f"{track_id}.none")
    if os.path.exists(miss_path) and (time.time() - os.path.getmtime(miss_path)) < 3 * 86400:
        return None

    token = get_access_token(cache_dir)
    if not token:
        return None

    # Protobuf CanvasRequest { repeated Track tracks = 1; Track { string track_uri = 1; } }
    entity = ld(1, f"spotify:track:{track_id}".encode("utf-8"))
    payload = ld(1, entity)

    hdr = {
        "User-Agent": "Spotify/9.0.34.593 iOS/18.4 (iPhone15,3)",
        "Content-Type": "application/x-protobuf",
        "Accept": "application/protobuf",
        "Authorization": f"Bearer {token}",
    }

    canvas_url = None
    try:
        req = urllib.request.Request(
            "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases",
            data=payload,
            headers=hdr,
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            body = resp.read()

        m = re.search(rb'https?://[a-zA-Z0-9\.\-\/_]+\.mp4', body)
        if m:
            canvas_url = m.group(0).decode("utf-8", "ignore")
        else:
            try:
                open(miss_path, "w").close()
            except OSError:
                pass
            return None
    except Exception as e:
        log_err(cache_dir, f"canvaz request failed: {e!r}")
        return None

    # Download canvas video
    try:
        ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        req_dl = urllib.request.Request(canvas_url, headers={"User-Agent": ua})
        with urllib.request.urlopen(req_dl, timeout=15) as resp:
            content = resp.read()
        if len(content) > 1000:
            tmp_path = video_path + ".tmp"
            with open(tmp_path, "wb") as f:
                f.write(content)
            os.replace(tmp_path, video_path)
            return video_path
    except Exception as e:
        log_err(cache_dir, f"canvas download failed: {e!r}")

    return None

def check_monthly_cleanup(cache_dir):
    """Auto-clears stale cache if month has rolled over."""
    try:
        month_file = os.path.join(cache_dir, ".last_month")
        current_month = time.strftime("%Y-%m")
        last_month = None
        if os.path.exists(month_file):
            with open(month_file, "r", encoding="utf-8") as f:
                last_month = f.read().strip()
        if last_month and last_month != current_month:
            for fname in os.listdir(cache_dir):
                if fname.endswith((".mp4", ".none", ".tmp")):
                    try:
                        os.remove(os.path.join(cache_dir, fname))
                    except OSError:
                        pass
        with open(month_file, "w", encoding="utf-8") as f:
            f.write(current_month)
    except OSError:
        pass

def main():
    if len(sys.argv) < 2:
        track_id = discover_spotify_track_id()
    else:
        raw = sys.argv[1].strip()
        track_id = get_track_id(raw)
        if not track_id:
            track_id = discover_spotify_track_id()

    cache_dir = sys.argv[2].strip() if len(sys.argv) > 2 else os.path.expanduser("~/.cache/maclock/canvas")
    check_monthly_cleanup(cache_dir)

    if not track_id:
        return

    video_path = fetch_canvas(track_id, cache_dir)
    if video_path and os.path.exists(video_path):
        print(video_path)

if __name__ == "__main__":
    main()
