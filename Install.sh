#!/bin/bash
# =============================================================================
# AudioVault Server Installer
# https://github.com/dejnastosic986/audiobook-player
#
# This script sets up a complete AudioVault server on a Raspberry Pi
# (or any Debian/Ubuntu-based Linux machine).
#
# What it does:
#   1. Installs required packages (nginx, python3, ffmpeg, inotify-tools)
#   2. Asks where your audiobooks drive is mounted
#   3. Creates /srv/audiobook-api with venv, API, scanner and watcher scripts
#   4. Creates /srv/audiobook-data for library.json and progress.json
#   5. Configures nginx on port 8081
#   6. Sets up correct file permissions (www-data sudoers)
#   7. Creates and enables systemd services
#   8. Runs the first library scan
#
# The library scanner (regen_library.sh) also reads chapter markers
# (m4b/mp3 via ffprobe) and extracts embedded cover art for single-file
# books that don't already have a cover image (via ffmpeg).
#
# You are encouraged to read through this script before running it.
# Every section is commented. Nothing is hidden.
# =============================================================================

set -e  # Exit immediately on any error

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}${BOLD}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}${BOLD}[ OK ]${NC}  $1"; }
warn()  { echo -e "${YELLOW}${BOLD}[WARN]${NC}  $1"; }
error() { echo -e "${RED}${BOLD}[ERR ]${NC}  $1"; exit 1; }
ask()   { echo -e "${BOLD}$1${NC}"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      AudioVault Server Installer         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  error "Please run this script with sudo:\n  sudo bash install.sh"
fi

REAL_USER="${SUDO_USER:-$(whoami)}"
info "Running as root, actual user: ${BOLD}$REAL_USER${NC}"

# ── Step 1: Ask for configuration ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Configuration ──────────────────────────────────────────${NC}"
echo ""

ask "Where are your audiobooks stored?"
ask "This is the directory that contains one subfolder per book."
ask "Example: /mnt/wd/audiobooks  or  /mnt/audiodrive/audiobooks"
echo ""
read -r -p "  Audiobooks path: " AUDIOBOOKS_DIR

AUDIOBOOKS_DIR="${AUDIOBOOKS_DIR%/}"

if [ ! -d "$AUDIOBOOKS_DIR" ]; then
  warn "Directory '$AUDIOBOOKS_DIR' does not exist."
  read -r -p "  Create it now? [Y/n]: " CREATE_DIR
  if [[ "$CREATE_DIR" =~ ^[Nn] ]]; then
    error "Audiobooks directory is required. Aborting."
  fi
  mkdir -p "$AUDIOBOOKS_DIR"
  chown "$REAL_USER":"$REAL_USER" "$AUDIOBOOKS_DIR"
  ok "Created $AUDIOBOOKS_DIR"
fi

API_DIR="/srv/audiobook-api"
DATA_DIR="/srv/audiobook-data"

echo ""
info "Summary:"
echo "  Audiobooks : $AUDIOBOOKS_DIR"
echo "  API dir    : $API_DIR"
echo "  Data dir   : $DATA_DIR"
echo "  nginx port : 8081"
echo "  API port   : 5000 (internal only, via gunicorn)"
echo ""
read -r -p "  Continue? [Y/n]: " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn] ]]; then
  echo "Aborted."
  exit 0
fi

# ── Step 2: Install packages ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Installing packages ────────────────────────────────────${NC}"
echo ""
info "Running apt update..."
apt update -qq

info "Installing nginx, python3, ffmpeg, inotify-tools..."
apt install -y nginx python3 python3-pip python3-venv ffmpeg inotify-tools > /dev/null
ok "System packages installed"

# ── Step 3: Create directories ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Creating directories ───────────────────────────────────${NC}"
echo ""
mkdir -p "$API_DIR" "$DATA_DIR"
chown "$REAL_USER":"$REAL_USER" "$API_DIR"
chown www-data:www-data "$DATA_DIR"
chmod 775 "$DATA_DIR"
ok "Created $API_DIR and $DATA_DIR"

# ── Step 4: Create Python virtual environment ─────────────────────────────────
echo ""
echo -e "${BOLD}── Creating Python virtual environment ────────────────────${NC}"
echo ""
python3 -m venv "$API_DIR/venv"
"$API_DIR/venv/bin/pip" install --quiet flask gunicorn python-dotenv
ok "Virtual environment ready with flask, gunicorn, python-dotenv"

# ── Step 5: Create config.env ─────────────────────────────────────────────────
cat > "$API_DIR/config.env" << CONFEOF
# Path to the folder containing your audiobook subfolders.
AUDIOBOOKS_DIR=$AUDIOBOOKS_DIR
CONFEOF
ok "Created config.env"

# ── Step 6: Create Flask API ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Creating Flask API ─────────────────────────────────────${NC}"
echo ""
cat > "$API_DIR/audiobook_api.py" << 'APIEOF'
from flask import Flask, jsonify, request
import json, os, time
from pathlib import Path
from tempfile import NamedTemporaryFile

app = Flask(__name__)

DATA_DIR      = Path("/srv/audiobook-data")
PROGRESS_FILE = DATA_DIR / "progress.json"


def atomic_write_json(path: Path, data: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = NamedTemporaryFile("w", delete=False, dir=str(path.parent), encoding="utf-8")
    try:
        json.dump(data, tmp, ensure_ascii=False, indent=2)
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp.close()
        os.replace(tmp.name, str(path))
        os.chmod(str(path), 0o664)
    finally:
        try:
            os.unlink(tmp.name)
        except Exception:
            pass


def load_json(path: Path, default: dict):
    try:
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        pass
    return default


@app.route("/api/progress", methods=["GET"])
def get_progress():
    profile = (request.args.get("profile") or "").strip()
    book_id = (request.args.get("bookId") or "").strip()
    root = load_json(PROGRESS_FILE, {"profiles": {}})
    item = root.get("profiles", {}).get(profile, {}).get(book_id)
    return jsonify(item or {})


@app.route("/api/progress", methods=["POST"])
def save_progress():
    data      = request.get_json(force=True, silent=True) or {}
    profile   = (data.get("profile") or "").strip()
    book_id   = (data.get("bookId") or "").strip()
    track_idx = data.get("trackIndex")
    pos_ms    = data.get("positionMs")

    if not profile or not book_id:
        return jsonify({"ok": False, "error": "Missing profile or bookId"}), 400

    root = load_json(PROGRESS_FILE, {"profiles": {}})
    root.setdefault("profiles", {}).setdefault(profile, {})[book_id] = {
        "trackIndex": track_idx,
        "positionMs": pos_ms,
        "updatedAt":  int(time.time())
    }
    atomic_write_json(PROGRESS_FILE, root)
    return jsonify({"ok": True})


@app.route("/api/profile-rename", methods=["POST"])
def rename_profile():
    data        = request.get_json(force=True, silent=True) or {}
    old_profile = (data.get("oldProfile") or "").strip()
    new_profile = (data.get("newProfile") or "").strip()

    if not old_profile or not new_profile:
        return jsonify({"ok": False, "error": "Missing profile names"}), 400
    if old_profile == new_profile:
        return jsonify({"ok": True})

    root = load_json(PROGRESS_FILE, {"profiles": {}})
    old_data = root["profiles"].get(old_profile, {})
    root["profiles"].setdefault(new_profile, {})
    for book_id, entry in old_data.items():
        existing = root["profiles"][new_profile].get(book_id)
        if not existing or existing.get("updatedAt", 0) < entry.get("updatedAt", 0):
            root["profiles"][new_profile][book_id] = entry
    root["profiles"].pop(old_profile, None)
    atomic_write_json(PROGRESS_FILE, root)
    return jsonify({"ok": True})


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000)
APIEOF
ok "Created audiobook_api.py"

# ── Step 7: Create library scanner ────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Creating library scanner ───────────────────────────────${NC}"
echo ""
cat > "$API_DIR/regen_library.sh" << 'REGENEOF'
#!/usr/bin/env bash
# regen_library.sh

set -euo pipefail

CONFIG_FILE="/srv/audiobook-api/config.env"
[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config.env not found"; exit 1; }
source "$CONFIG_FILE"
[[ -n "${AUDIOBOOKS_DIR:-}" ]] || { echo "ERROR: AUDIOBOOKS_DIR not set"; exit 1; }

DATA_DIR="/srv/audiobook-data"
OUT="$DATA_DIR/library.json"
mkdir -p "$DATA_DIR"
umask 0002

echo "[regen] Scanning: $AUDIOBOOKS_DIR"
echo "[regen] Output:   $OUT"

AUDIOBOOKS_DIR="$AUDIOBOOKS_DIR" OUT_FILE="$OUT" python3 - <<'PY'

import os, sys, json, subprocess, tempfile, shutil

AUDIOBOOKS_DIR = os.environ["AUDIOBOOKS_DIR"]
OUT_FILE       = os.environ["OUT_FILE"]
AUDIO_EXT      = (".mp3", ".m4b", ".m4a", ".wav", ".ogg", ".flac")
IMAGE_EXT      = (".jpg", ".jpeg", ".png")
PREFERRED_COVERS = ("cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.png")

if not shutil.which("ffprobe"):
    print("ERROR: ffprobe not found. Install: sudo apt install ffmpeg")
    sys.exit(1)

if not os.path.isdir(AUDIOBOOKS_DIR):
    print(f"ERROR: Directory not found: {AUDIOBOOKS_DIR}")
    sys.exit(1)

CACHE_FILE = os.path.join(os.path.dirname(OUT_FILE), "duration_cache.json")

def load_cache():
    try:
        with open(CACHE_FILE, "r", encoding="utf-8") as f: return json.load(f)
    except Exception: return {}

def save_cache(cache):
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CACHE_FILE))
        with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(cache, f)
        os.replace(tmp, CACHE_FILE)
        os.chmod(CACHE_FILE, 0o664)
    except Exception as e: print(f"[warn] Could not save cache: {e}")

cache = load_cache()

def slugify(s):
    s = s.lower().strip()
    out = []
    for ch in s:
        if ch.isalnum(): out.append(ch)
        elif ch in (" ", "-", "_"): out.append("-")
    slug = "".join(out)
    while "--" in slug: slug = slug.replace("--", "-")
    return slug.strip("-")

def get_duration_ms(path):
    try:
        mtime = str(os.path.getmtime(path))
        key = f"{path}:{mtime}"
        if key in cache: return cache[key]
    except OSError: pass
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15)
        txt = (r.stdout or "").strip()
        if not txt or txt.lower() == "n/a": return 0
        ms = int(float(txt) * 1000)
        try:
            mtime = str(os.path.getmtime(path))
            cache[f"{path}:{mtime}"] = ms
        except OSError: pass
        return ms
    except Exception: return 0

def get_chapters(path):
    """
    Reads chapter markers from an audio file using ffprobe.
    Works for m4b/m4a (iTunes chapters) and mp3 (ID3 CHAP frames).
    Returns a list of {"title", "startMs", "endMs"} dicts, or [] if none found.
    """
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "quiet",
             "-print_format", "json",
             "-show_chapters", path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30)
        data = json.loads(r.stdout or "{}")
        raw_chapters = data.get("chapters", [])
        if len(raw_chapters) <= 1:
            return []
        chapters = []
        for i, ch in enumerate(raw_chapters):
            title = ch.get("tags", {}).get("title", f"Chapter {i + 1}")
            start_ms = int(float(ch.get("start_time", 0)) * 1000)
            end_ms   = int(float(ch.get("end_time",   0)) * 1000)
            chapters.append({"title": title, "startMs": start_ms, "endMs": end_ms})
        return chapters
    except Exception as e:
        print(f"    [warn] Could not read chapters from {os.path.basename(path)}: {e}")
        return []

def extract_embedded_cover(audio_path, folder_name):
    """
    Attempts to extract embedded artwork from audio file using ffmpeg.
    Works for m4b (iTunes cover art) and mp3 (ID3 APIC frame).
    Saves as cover.jpg in book folder with correct owner/permissions.
    Returns relative path on success, None if no artwork or cover already exists.
    """
    # Check all possible cover files -- if any exists, skip
    full_folder = os.path.join(AUDIOBOOKS_DIR, folder_name)
    for name in PREFERRED_COVERS:
        if os.path.isfile(os.path.join(full_folder, name)):
            return None
    existing_imgs = [n for n in os.listdir(full_folder) if n.lower().endswith(IMAGE_EXT)]
    if existing_imgs:
        return None

    ext = os.path.splitext(audio_path)[1].lower()
    if ext not in (".m4b", ".m4a", ".mp3"):
        return None

    cover_path = os.path.join(AUDIOBOOKS_DIR, folder_name, "cover.jpg")

    try:
        r = subprocess.run(
            ["ffmpeg", "-v", "quiet", "-i", audio_path,
             "-an",            # bez audio streama
             "-vcodec", "copy", # kopiraj video stream (cover art)
             "-y",             # overwrite ako postoji
             cover_path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=30
        )
        if r.returncode == 0 and os.path.isfile(cover_path) and os.path.getsize(cover_path) > 0:
            # Set correct permissions -- www-data must read, upload user must write
            os.chmod(cover_path, 0o664)
            print(f"    [cover] Extracted embedded artwork")
            return f"{folder_name}/cover.jpg"
        else:
            # Cleanup ako je ffmpeg napravio prazan fajl
            try:
                if os.path.isfile(cover_path) and os.path.getsize(cover_path) == 0:
                    os.unlink(cover_path)
            except OSError: pass
            return None
    except Exception as e:
        print(f"    [warn] Could not extract cover from {os.path.basename(audio_path)}: {e}")
        return None

def find_cover(folder_name):
    full = os.path.join(AUDIOBOOKS_DIR, folder_name)
    for name in PREFERRED_COVERS:
        if os.path.isfile(os.path.join(full, name)):
            return f"{folder_name}/{name}"
    try:
        imgs = sorted(n for n in os.listdir(full) if n.lower().endswith(IMAGE_EXT))
        if imgs: return f"{folder_name}/{imgs[0]}"
    except OSError: pass
    return None

def list_audio_files(folder_name):
    full = os.path.join(AUDIOBOOKS_DIR, folder_name)
    try:
        return sorted(n for n in os.listdir(full) if n.lower().endswith(AUDIO_EXT))
    except OSError: return []

books = []
skipped_zero = []
warned_partial = []
missing_covers = []  # Books without cover that have a single audio file -- candidates for extraction

# -- PASS 1: duration, chapters, existing covers --
for folder_name in sorted(os.listdir(AUDIOBOOKS_DIR)):
    full_folder = os.path.join(AUDIOBOOKS_DIR, folder_name)
    if not os.path.isdir(full_folder) or folder_name.startswith("."): continue

    audio_files = list_audio_files(folder_name)
    if not audio_files:
        print(f"  [skip] No audio files in: {folder_name}"); continue

    print(f"  [book] {folder_name} ({len(audio_files)} track(s))")

    tracks = []
    zero_tracks = []

    for filename in audio_files:
        full_file = os.path.join(full_folder, filename)
        ms = get_duration_ms(full_file)
        if ms == 0:
            zero_tracks.append(filename)
            print(f"    [warn] Duration 0ms: {filename}")
        else:
            print(f"    [ok]   {filename} ({ms // 1000}s)")
        tracks.append({"file": filename, "durationMs": ms})

    if zero_tracks:
        if len(zero_tracks) == len(audio_files): skipped_zero.append(folder_name)
        else: warned_partial.append(folder_name)

    # Chapters for single-file books
    chapters = []
    if len(audio_files) == 1:
        full_file = os.path.join(full_folder, audio_files[0])
        chapters = get_chapters(full_file)
        if chapters:
            print(f"    [chapters] Found {len(chapters)} chapters")

    # Cover -- only check if already exists, do NOT attempt extraction yet
    cover_rel = find_cover(folder_name)

    book = {
        "id":       slugify(folder_name),
        "title":    folder_name,
        "coverUrl": cover_rel,
        "tracks":   tracks,
    }
    if chapters:
        book["chapters"] = chapters

    books.append(book)

    # Track candidates for cover extraction -- single file books without a cover
    if cover_rel is None and len(audio_files) == 1:
        missing_covers.append((folder_name, audio_files[0]))

# -- Atomic write library.json -- Pass 1 result --
def write_library(books):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(OUT_FILE))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"books": books}, f, ensure_ascii=False, indent=2)
        os.replace(tmp, OUT_FILE)
        os.chmod(OUT_FILE, 0o664)
    except Exception as e:
        try: os.unlink(tmp)
        except OSError: pass
        raise e

write_library(books)
save_cache(cache)
print("")
print("[regen] Pass 1 done. Written " + str(len(books)) + " book(s) to " + OUT_FILE)

# -- PASS 2: cover extraction for books without a cover --
# Each successful extraction immediately patches library.json
if missing_covers:
    print("")
    print("[cover] Attempting cover extraction for " + str(len(missing_covers)) + " books...")
    extracted_covers = []

    for folder_name, audio_filename in missing_covers:
        full_file = os.path.join(AUDIOBOOKS_DIR, folder_name, audio_filename)
        cover_rel = extract_embedded_cover(full_file, folder_name)

        if cover_rel:
            extracted_covers.append(folder_name)
            # Patch only this entry in library.json
            try:
                data = json.loads(open(OUT_FILE, encoding="utf-8").read())
                book_id = slugify(folder_name)
                for b in data["books"]:
                    if b["id"] == book_id:
                        b["coverUrl"] = cover_rel
                        break
                write_library(data["books"])
                print(f"    [ok] Cover added to library.json for: {folder_name}")
            except Exception as e:
                print(f"    [warn] Could not patch library.json: {e}")

    if extracted_covers:
        print("")
        print("[cover] Extracted embedded cover art for " + str(len(extracted_covers)) + " book(s):")
        for b in extracted_covers: print("   - " + b)
    else:
        print("   No embedded artwork found in remaining books.")

if skipped_zero:
    print()
    print("WARNING: ALL tracks 0ms duration:")
    for b in skipped_zero: print(f"   - {b}")

if warned_partial:
    print()
    print("WARNING: SOME tracks 0ms duration:")
    for b in warned_partial: print(f"   - {b}")

PY

# Postavi ispravne permisije na sve output fajlove
sudo chown www-data:www-data "$OUT"
sudo chmod 664 "$OUT"
sudo chown www-data:www-data "$DATA_DIR/duration_cache.json" 2>/dev/null || true
sudo chmod 664 "$DATA_DIR/duration_cache.json" 2>/dev/null || true
sudo chmod 775 "$DATA_DIR"
echo "[regen] Done."
REGENEOF

chmod +x "$API_DIR/regen_library.sh"
ok "Created regen_library.sh"

# ── Step 8: Create folder watcher ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Creating folder watcher ────────────────────────────────${NC}"
echo ""
cat > "$API_DIR/audiobook-watch.sh" << 'WATCHEOF'
#!/bin/bash
CONFIG_FILE="/srv/audiobook-api/config.env"
source "$CONFIG_FILE"

echo "[watch] Watching $AUDIOBOOKS_DIR for changes..."

while true; do
    inotifywait -r -e modify,create,delete,moved_to,moved_from \
        "$AUDIOBOOKS_DIR" 2>/dev/null

    echo "[watch] Change detected. Waiting for activity to settle..."
    while inotifywait -r -e modify,create,delete,moved_to,moved_from \
        -t 25 "$AUDIOBOOKS_DIR" 2>/dev/null; do
        echo "[watch] Still active, resetting settle timer..."
    done

    echo "[watch] Activity settled. Regenerating library..."
    /srv/audiobook-api/regen_library.sh
    echo "[watch] Regeneration complete."
done
WATCHEOF

chmod +x "$API_DIR/audiobook-watch.sh"
ok "Created audiobook-watch.sh"

# ── Step 9: Configure www-data sudoers ────────────────────────────────────────
echo ""
echo -e "${BOLD}── Configuring permissions ────────────────────────────────${NC}"
echo ""

cat > /etc/sudoers.d/www-data-chown << SUDOEOF
www-data ALL=(root) NOPASSWD: /usr/bin/chown www-data\:www-data /srv/audiobook-data/library.json
www-data ALL=(root) NOPASSWD: /usr/bin/chown -R www-data\:www-data $AUDIOBOOKS_DIR
www-data ALL=(root) NOPASSWD: /usr/bin/chmod 644 /srv/audiobook-data/library.json
www-data ALL=(root) NOPASSWD: /usr/bin/chmod 664 /srv/audiobook-data/library.json
www-data ALL=(root) NOPASSWD: /usr/bin/chmod -R 755 $AUDIOBOOKS_DIR
www-data ALL=(root) NOPASSWD: /usr/bin/chown www-data\:www-data /srv/audiobook-data/duration_cache.json
www-data ALL=(root) NOPASSWD: /usr/bin/chmod 664 /srv/audiobook-data/duration_cache.json
www-data ALL=(root) NOPASSWD: /usr/bin/chmod 775 /srv/audiobook-data
SUDOEOF

chmod 440 /etc/sudoers.d/www-data-chown

if visudo -c -f /etc/sudoers.d/www-data-chown > /dev/null 2>&1; then
  ok "sudoers configured for www-data"
else
  error "sudoers syntax error — check /etc/sudoers.d/www-data-chown"
fi

# Fix ownership on API and data directories
chown -R www-data:www-data "$DATA_DIR"
chmod 775 "$DATA_DIR"
ok "Directory permissions set"

# ── Step 10: Configure nginx ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Configuring nginx ──────────────────────────────────────${NC}"
echo ""

cat > /etc/nginx/sites-available/audiobooks << NGINXEOF
server {
    listen 8081;

    location /library.json {
        alias /srv/audiobook-data/library.json;
    }

    location / {
        root $AUDIOBOOKS_DIR;
        autoindex off;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:5000;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/audiobooks \
       /etc/nginx/sites-enabled/audiobooks

if nginx -t > /dev/null 2>&1; then
  systemctl reload nginx
  ok "nginx configured and reloaded"
else
  error "nginx config test failed — check /etc/nginx/sites-available/audiobooks"
fi

# ── Step 11: Create systemd services ──────────────────────────────────────────
echo ""
echo -e "${BOLD}── Creating systemd services ──────────────────────────────${NC}"
echo ""

cat > /etc/systemd/system/audiobook-api.service << SVCEOF
[Unit]
Description=Audiobook API
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=/srv/audiobook-api
ExecStart=/srv/audiobook-api/venv/bin/gunicorn \\
  --workers 2 \\
  --bind 127.0.0.1:5000 \\
  --access-logfile - \\
  --error-logfile - \\
  audiobook_api:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/audiobook-watch.service << SVCEOF
[Unit]
Description=Audiobook Library Watcher
After=network.target

[Service]
User=www-data
Group=www-data
ExecStart=/bin/bash /srv/audiobook-api/audiobook-watch.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable audiobook-api audiobook-watch > /dev/null 2>&1
ok "Services created and enabled"

# ── Step 12: First library scan ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Running first library scan ─────────────────────────────${NC}"
echo ""
warn "This may take a few minutes for large libraries."
echo ""

sudo -u www-data /srv/audiobook-api/regen_library.sh

# ── Step 13: Start services ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Starting services ──────────────────────────────────────${NC}"
echo ""
systemctl start audiobook-api audiobook-watch

sleep 2

API_STATUS=$(systemctl is-active audiobook-api)
WATCH_STATUS=$(systemctl is-active audiobook-watch)

if [ "$API_STATUS" = "active" ]; then
  ok "audiobook-api is running"
else
  warn "audiobook-api failed to start — check: sudo journalctl -u audiobook-api -n 20"
fi

if [ "$WATCH_STATUS" = "active" ]; then
  ok "audiobook-watch is running"
else
  warn "audiobook-watch failed to start — check: sudo journalctl -u audiobook-watch -n 20"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
PI_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║           Installation complete!         ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Test the server in your browser:"
echo -e "  ${BOLD}http://${PI_IP}:8081/library.json${NC}"
echo ""
echo -e "  Then open AudioVault → Settings → Server and enter:"
echo -e "  ${BOLD}http://${PI_IP}:8081${NC}"
echo ""
echo -e "  Service status:"
echo -e "    sudo systemctl status audiobook-api"
echo -e "    sudo systemctl status audiobook-watch"
echo ""
