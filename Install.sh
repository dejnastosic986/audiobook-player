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
#   3. Creates /srv/audiobook-data with config, API, scanner and watcher scripts
#   4. Configures nginx on port 8081
#   5. Sets up correct file permissions (www-data sudoers)
#   6. Creates and enables systemd services
#   7. Runs the first library scan
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
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}${BOLD}[INFO]${NC}  $1"; }
ok()      { echo -e "${GREEN}${BOLD}[ OK ]${NC}  $1"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}${BOLD}[ERR ]${NC}  $1"; exit 1; }
ask()     { echo -e "${BOLD}$1${NC}"; }

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
read -r -p "  Audiobooks path: " BOOKS_DIR

# Strip trailing slash
BOOKS_DIR="${BOOKS_DIR%/}"

if [ ! -d "$BOOKS_DIR" ]; then
  warn "Directory '$BOOKS_DIR' does not exist."
  read -r -p "  Create it now? [Y/n]: " CREATE_DIR
  if [[ "$CREATE_DIR" =~ ^[Nn] ]]; then
    error "Audiobooks directory is required. Aborting."
  fi
  mkdir -p "$BOOKS_DIR"
  chown "$REAL_USER":"$REAL_USER" "$BOOKS_DIR"
  ok "Created $BOOKS_DIR"
fi

DATA_DIR="/srv/audiobook-data"

echo ""
info "Summary:"
echo "  Audiobooks : $BOOKS_DIR"
echo "  Data dir   : $DATA_DIR"
echo "  nginx port : 8081"
echo "  API port   : 5000 (internal only)"
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
apt install -y nginx python3 python3-pip ffmpeg inotify-tools > /dev/null
ok "System packages installed"

info "Installing Python packages (flask, python-dotenv)..."
pip3 install flask python-dotenv --break-system-packages -q
ok "Python packages installed"

# ── Step 3: Create data directory and config ───────────────────────────────────
echo ""
echo -e "${BOLD}── Creating data directory ────────────────────────────────${NC}"
echo ""
mkdir -p "$DATA_DIR"
chown "$REAL_USER":"$REAL_USER" "$DATA_DIR"
ok "Created $DATA_DIR"

# config.env
cat > "$DATA_DIR/config.env" << CONFEOF
# Path to the folder containing your audiobook subfolders.
BOOKS_DIR=$BOOKS_DIR

# Path where library.json and progress data are stored.
DATA_DIR=$DATA_DIR
CONFEOF
ok "Created config.env"

# ── Step 4: Create Flask API ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Creating Flask API ─────────────────────────────────────${NC}"
echo ""
cat > "$DATA_DIR/audiobook_api.py" << 'APIEOF'
from flask import Flask, jsonify, request
import json, os
from dotenv import load_dotenv

load_dotenv("/srv/audiobook-data/config.env")
DATA_DIR = os.getenv("DATA_DIR", "/srv/audiobook-data")

app = Flask(__name__)

@app.route("/api/progress/<profile>/<book_id>", methods=["GET"])
def get_progress(profile, book_id):
    path = f"{DATA_DIR}/progress/{profile}/{book_id}.json"
    if os.path.exists(path):
        return jsonify(json.load(open(path)))
    return jsonify({"trackIndex": 0, "positionMs": 0, "updatedAt": 0})

@app.route("/api/progress/<profile>/<book_id>", methods=["POST"])
def post_progress(profile, book_id):
    data = request.get_json()
    folder = f"{DATA_DIR}/progress/{profile}"
    os.makedirs(folder, exist_ok=True)
    with open(f"{folder}/{book_id}.json", "w") as f:
        json.dump(data, f)
    return jsonify({"ok": True})

@app.route("/api/backup", methods=["GET"])
def backup():
    progress_dir = f"{DATA_DIR}/progress"
    result = {}
    if os.path.exists(progress_dir):
        for profile in os.listdir(progress_dir):
            result[profile] = {}
            profile_dir = f"{progress_dir}/{profile}"
            if os.path.isdir(profile_dir):
                for fname in os.listdir(profile_dir):
                    if fname.endswith(".json"):
                        book_id = fname[:-5]
                        result[profile][book_id] = json.load(
                            open(f"{profile_dir}/{fname}")
                        )
    return jsonify(result)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
APIEOF
ok "Created audiobook_api.py"

# ── Step 5: Create library scanner (regen_library.sh) ─────────────────────────
echo ""
echo -e "${BOLD}── Creating library scanner ───────────────────────────────${NC}"
echo ""
cat > "$DATA_DIR/regen_library.sh" << 'REGENEOF'
#!/bin/bash
source /srv/audiobook-data/config.env
OUTPUT="$DATA_DIR/library.json"
LOCK_FILE="/tmp/regen_library.lock"

# Prevent concurrent runs
if [ -f "$LOCK_FILE" ]; then
    echo "[regen] Already running, skipping."
    exit 0
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | \
    sed 's/[^a-z0-9 _-]//g' | \
    sed 's/[ _-]\+/-/g' | sed 's/^-\|-$//g'
}

echo "[regen] Scanning $BOOKS_DIR..."
echo "[" > "$OUTPUT.tmp"
first=true

for dir in "$BOOKS_DIR"/*/; do
  [ -d "$dir" ] || continue
  title=$(basename "$dir")
  id=$(slugify "$title")
  cover=""

  for img in "$dir"*.jpg "$dir"*.png "$dir"*.jpeg "$dir"*.JPG "$dir"*.PNG; do
    [ -f "$img" ] && cover=$(basename "$img") && break
  done

  tracks="["
  track_first=true
  for f in $(ls "$dir"*.mp3 "$dir"*.m4b "$dir"*.m4a \
                 "$dir"*.flac "$dir"*.ogg "$dir"*.wav 2>/dev/null | sort); do
    filename=$(basename "$f")
    dur=$(ffprobe -v quiet -show_entries \
      format=duration -of csv=p=0 "$f" 2>/dev/null | cut -d. -f1)
    dur_ms=$(( ${dur:-0} * 1000 ))
    [ "$track_first" = true ] && track_first=false || tracks="$tracks,"
    tracks="$tracks{\"file\":\"$filename\",\"durationMs\":$dur_ms}"
  done
  tracks="$tracks]"

  [ "$first" = true ] && first=false || echo "," >> "$OUTPUT.tmp"
  cat >> "$OUTPUT.tmp" << JSON
{
  "id": "$id",
  "title": "$title",
  "coverUrl": "$cover",
  "tracks": $tracks
}
JSON
done

echo "]" >> "$OUTPUT.tmp"

# Atomically replace the output file
mv "$OUTPUT.tmp" "$OUTPUT"

# Fix ownership so nginx (www-data) can serve the file
sudo /usr/bin/chown www-data:www-data "$OUTPUT"
sudo /usr/bin/chmod 664 "$OUTPUT"

echo "[regen] Done. Library written to $OUTPUT"
REGENEOF

chmod +x "$DATA_DIR/regen_library.sh"
ok "Created regen_library.sh"

# ── Step 6: Create folder watcher (audiobook-watch.sh) ────────────────────────
echo ""
echo -e "${BOLD}── Creating folder watcher ────────────────────────────────${NC}"
echo ""
cat > "$DATA_DIR/audiobook-watch.sh" << 'WATCHEOF'
#!/bin/bash
source /srv/audiobook-data/config.env

echo "[watch] Watching $BOOKS_DIR for changes..."

while true; do
    # Wait for any filesystem event in the books folder
    inotifywait -r -e modify,create,delete,moved_to,moved_from \
        "$BOOKS_DIR" 2>/dev/null

    # Wait for activity to settle before regenerating.
    # Resets every time a new event arrives — prevents regen mid-upload.
    echo "[watch] Change detected. Waiting for activity to settle..."
    while inotifywait -r -e modify,create,delete,moved_to,moved_from \
        -t 25 "$BOOKS_DIR" 2>/dev/null; do
        echo "[watch] Still active, resetting settle timer..."
    done

    echo "[watch] Activity settled. Regenerating library..."
    /srv/audiobook-data/regen_library.sh
    echo "[watch] Regeneration complete."
done
WATCHEOF

chmod +x "$DATA_DIR/audiobook-watch.sh"
ok "Created audiobook-watch.sh"

# ── Step 7: Configure www-data sudoers ────────────────────────────────────────
echo ""
echo -e "${BOLD}── Configuring permissions ────────────────────────────────${NC}"
echo ""

# The regen script runs as www-data (via the watch service) and needs to
# fix ownership of library.json after every scan so nginx can serve it.
# We grant www-data NOPASSWD sudo for only these exact commands.
cat > /etc/sudoers.d/www-data-chown << SUDOEOF
www-data ALL=(root) NOPASSWD: /usr/bin/chown www-data:www-data /srv/audiobook-data/library.json
www-data ALL=(root) NOPASSWD: /usr/bin/chown -R www-data:www-data $BOOKS_DIR
www-data ALL=(root) NOPASSWD: /usr/bin/chmod 644 /srv/audiobook-data/library.json
www-data ALL=(root) NOPASSWD: /usr/bin/chmod 664 /srv/audiobook-data/library.json
www-data ALL=(root) NOPASSWD: /usr/bin/chmod -R 755 $BOOKS_DIR
SUDOEOF

chmod 440 /etc/sudoers.d/www-data-chown

# Validate sudoers syntax
if visudo -c -f /etc/sudoers.d/www-data-chown > /dev/null 2>&1; then
  ok "sudoers configured for www-data"
else
  error "sudoers syntax error — check /etc/sudoers.d/www-data-chown"
fi

# ── Step 8: Configure nginx ────────────────────────────────────────────────────
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
        root $BOOKS_DIR;
        autoindex off;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:5000;
    }
}
NGINXEOF

# Enable the site
ln -sf /etc/nginx/sites-available/audiobooks \
       /etc/nginx/sites-enabled/audiobooks

# Test nginx config
if nginx -t > /dev/null 2>&1; then
  systemctl reload nginx
  ok "nginx configured and reloaded"
else
  error "nginx config test failed — check /etc/nginx/sites-available/audiobooks"
fi

# ── Step 9: Create systemd services ───────────────────────────────────────────
echo ""
echo -e "${BOLD}── Creating systemd services ──────────────────────────────${NC}"
echo ""

cat > /etc/systemd/system/audiobook-api.service << SVCEOF
[Unit]
Description=AudioVault Flask API
After=network.target

[Service]
EnvironmentFile=/srv/audiobook-data/config.env
ExecStart=/usr/bin/python3 /srv/audiobook-data/audiobook_api.py
WorkingDirectory=/srv/audiobook-data
Restart=always
User=$REAL_USER

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/audiobook-watch.service << SVCEOF
[Unit]
Description=AudioVault Library Watcher
After=network.target

[Service]
EnvironmentFile=/srv/audiobook-data/config.env
ExecStart=/bin/bash /srv/audiobook-data/audiobook-watch.sh
Restart=always
User=$REAL_USER

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable audiobook-api audiobook-watch > /dev/null 2>&1
ok "Services created and enabled"

# ── Step 10: First library scan ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Running first library scan ─────────────────────────────${NC}"
echo ""
warn "This may take a few minutes for large libraries (ffprobe reads every file)."
echo ""

bash "$DATA_DIR/regen_library.sh"

# ── Step 11: Start services ────────────────────────────────────────────────────
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
