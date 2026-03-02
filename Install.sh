#!/bin/bash
# AudioVault Server Installer
# https://dejnastosic986.github.io/audiobook-player
#
# This script automates the server setup described in the guide.
# It does nothing hidden — every action is printed before it runs.
# You are welcome to read it before running it.
#
# Usage:
#   bash install.sh
# Or directly from GitHub:
#   bash <(curl -s https://raw.githubusercontent.com/dejnastosic986/audiobook-player/main/install.sh)

set -e  # Exit immediately on any error

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}${BOLD}  $1${RESET}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

print_step() {
    echo -e "\n${GREEN}▶ $1${RESET}"
}

print_info() {
    echo -e "  ${CYAN}ℹ $1${RESET}"
}

print_warning() {
    echo -e "  ${YELLOW}⚠ $1${RESET}"
}

print_error() {
    echo -e "  ${RED}✗ $1${RESET}"
}

print_success() {
    echo -e "  ${GREEN}✓ $1${RESET}"
}

ask() {
    # ask "Question" "default_value" -> result in $REPLY
    local prompt="$1"
    local default="$2"
    echo -e -n "\n${BOLD}  $prompt${RESET}"
    if [ -n "$default" ]; then
        echo -e -n " ${CYAN}[${default}]${RESET}"
    fi
    echo -e -n ": "
    read REPLY
    if [ -z "$REPLY" ] && [ -n "$default" ]; then
        REPLY="$default"
    fi
}

confirm() {
    # confirm "Question" -> returns 0 for yes, 1 for no
    echo -e -n "\n${BOLD}  $1 (y/n): ${RESET}"
    read answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ── Welcome ───────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${CYAN}${BOLD}"
echo "   █████╗ ██╗   ██╗██████╗ ██╗ ██████╗ "
echo "  ██╔══██╗██║   ██║██╔══██╗██║██╔═══██╗"
echo "  ███████║██║   ██║██║  ██║██║██║   ██║"
echo "  ██╔══██║██║   ██║██║  ██║██║██║   ██║"
echo "  ██║  ██║╚██████╔╝██████╔╝██║╚██████╔╝"
echo "  ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝ ╚═════╝ "
echo -e "${RESET}"
echo -e "  ${BOLD}AudioVault Server Installer${RESET}"
echo -e "  ${CYAN}https://dejnastosic986.github.io/audiobook-player${RESET}"
echo ""
echo -e "  This script will set up your AudioVault server step by step."
echo -e "  Every action will be shown before it runs — nothing is hidden."
echo ""

if ! confirm "Ready to start?"; then
    echo ""
    echo "  Setup cancelled. Run this script again when you're ready."
    echo ""
    exit 0
fi

# ── Check: running as non-root with sudo access ───────────────────────────────
print_header "Checking system"

if [ "$EUID" -eq 0 ]; then
    print_error "Please do not run this script as root. Run it as your normal user."
    exit 1
fi

if ! sudo -n true 2>/dev/null; then
    print_info "This script needs sudo access. You may be asked for your password."
    sudo true || { print_error "sudo access required. Exiting."; exit 1; }
fi

print_success "Running as: $(whoami)"

# ── Check: external drive ─────────────────────────────────────────────────────
print_header "External drive"

echo ""
echo -e "  AudioVault stores books on an external USB drive, not the SD card."
echo -e "  The drive must already be connected to your Raspberry Pi."
echo ""

print_step "Listing connected drives..."
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v "loop"

echo ""
print_info "Look for your external drive in the list above (usually sda or sdb)."
print_warning "Do not use the drive that contains your OS (usually mmcblk0)."

ask "Enter the partition name of your external drive (e.g. sda1)" "sda1"
DRIVE_PARTITION="$REPLY"

# Verify it exists
if ! lsblk "/dev/$DRIVE_PARTITION" > /dev/null 2>&1; then
    print_error "/dev/$DRIVE_PARTITION not found. Please check the drive name and try again."
    exit 1
fi

print_success "Found /dev/$DRIVE_PARTITION"

# Get UUID
print_step "Reading UUID for /dev/$DRIVE_PARTITION..."
DRIVE_UUID=$(sudo blkid -s UUID -o value "/dev/$DRIVE_PARTITION")

if [ -z "$DRIVE_UUID" ]; then
    print_error "Could not read UUID. Make sure the drive is formatted (ext4 or ntfs)."
    exit 1
fi

print_success "UUID: $DRIVE_UUID"

# Filesystem type
DRIVE_FS=$(sudo blkid -s TYPE -o value "/dev/$DRIVE_PARTITION")
print_info "Filesystem type: $DRIVE_FS"

if [ "$DRIVE_FS" = "ntfs" ]; then
    print_warning "NTFS detected. Will install ntfs-3g driver automatically."
    FSTAB_FS="ntfs-3g"
else
    FSTAB_FS="ext4"
fi

# ── Questions ─────────────────────────────────────────────────────────────────
print_header "Configuration"

echo ""
echo -e "  Answer the following questions to configure your setup."
echo -e "  Press Enter to accept the default value shown in brackets."
echo ""

ask "Where should the drive be mounted?" "/mnt/audiodrive"
MOUNT_POINT="$REPLY"

ask "Name of the audiobooks folder on the drive" "audiobooks"
BOOKS_FOLDER="$REPLY"

BOOKS_DIR="$MOUNT_POINT/$BOOKS_FOLDER"
DATA_DIR="/srv/audiobook-data"

echo ""
echo -e "  ${BOLD}Summary of your configuration:${RESET}"
echo -e "  ${CYAN}Drive:${RESET}         /dev/$DRIVE_PARTITION  (UUID: $DRIVE_UUID)"
echo -e "  ${CYAN}Mount point:${RESET}   $MOUNT_POINT"
echo -e "  ${CYAN}Books folder:${RESET}  $BOOKS_DIR"
echo -e "  ${CYAN}Data folder:${RESET}   $DATA_DIR  (on SD card — progress, library.json)"
echo ""

if ! confirm "Does this look correct?"; then
    echo ""
    echo "  Setup cancelled. Run this script again to start over."
    exit 0
fi

# ── Install packages ──────────────────────────────────────────────────────────
print_header "Installing packages"

print_step "Updating package list..."
sudo apt update -q

PACKAGES="nginx python3 python3-pip ffmpeg inotify-tools"
if [ "$DRIVE_FS" = "ntfs" ]; then
    PACKAGES="$PACKAGES ntfs-3g"
fi

print_step "Installing: $PACKAGES"
sudo apt install -y $PACKAGES

print_step "Installing Python packages..."
pip3 install flask python-dotenv --break-system-packages -q

print_success "All packages installed"

# ── Mount drive ───────────────────────────────────────────────────────────────
print_header "Mounting external drive"

print_step "Creating mount point: $MOUNT_POINT"
sudo mkdir -p "$MOUNT_POINT"

# Check if already in fstab
if grep -q "$DRIVE_UUID" /etc/fstab; then
    print_info "Drive already in /etc/fstab — skipping."
else
    print_step "Adding drive to /etc/fstab for automatic mounting on boot..."
    echo "UUID=$DRIVE_UUID  $MOUNT_POINT  $FSTAB_FS  defaults,nofail  0  2" | sudo tee -a /etc/fstab > /dev/null
    print_success "Added to /etc/fstab"
fi

print_step "Mounting drive now..."
sudo mount -a
print_success "Drive mounted at $MOUNT_POINT"

# ── Create folders and config ─────────────────────────────────────────────────
print_header "Creating folders and config"

print_step "Creating books folder: $BOOKS_DIR"
mkdir -p "$BOOKS_DIR"

print_step "Creating data folder: $DATA_DIR"
sudo mkdir -p "$DATA_DIR"
sudo chown -R "$USER:$USER" "$DATA_DIR"

print_step "Writing config.env..."
cat > "$DATA_DIR/config.env" << ENVEOF
# AudioVault configuration
# Generated by install.sh on $(date)

# Path to the folder containing your audiobook subfolders.
BOOKS_DIR=$BOOKS_DIR

# Path where library.json and progress data are stored.
DATA_DIR=$DATA_DIR
ENVEOF
print_success "config.env written"

# ── Flask API ─────────────────────────────────────────────────────────────────
print_header "Creating Flask API"

print_step "Writing audiobook_api.py..."
cat > "$DATA_DIR/audiobook_api.py" << 'PYEOF'
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

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
PYEOF
print_success "audiobook_api.py written"

# ── nginx ─────────────────────────────────────────────────────────────────────
print_header "Configuring nginx"

print_step "Writing nginx config..."
# Note: nginx cannot read config.env — paths are hardcoded here.
# If you move your books folder in the future, update this file manually.
sudo tee /etc/nginx/sites-available/audiobooks > /dev/null << NGINXEOF
server {
    listen 8081;

    location /library.json {
        alias $DATA_DIR/library.json;
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

print_step "Enabling nginx site..."
sudo ln -sf /etc/nginx/sites-available/audiobooks /etc/nginx/sites-enabled/audiobooks
sudo nginx -t
sudo systemctl reload nginx
print_success "nginx configured"

# ── regen_library.sh ──────────────────────────────────────────────────────────
print_header "Creating library scanner"

print_step "Writing regen_library.sh..."
cat > "$DATA_DIR/regen_library.sh" << 'REGENEOF'
#!/bin/bash
source /srv/audiobook-data/config.env
OUTPUT="$DATA_DIR/library.json"

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | \
    sed 's/[^a-z0-9 _-]//g' | \
    sed 's/[ _-]\+/-/g' | sed 's/^-\|-$//g'
}

echo "[" > "$OUTPUT"
first=true

for dir in "$BOOKS_DIR"/*/; do
  [ -d "$dir" ] || continue
  title=$(basename "$dir")
  id=$(slugify "$title")
  cover=""

  for img in "$dir"*.jpg "$dir"*.png "$dir"*.jpeg; do
    [ -f "$img" ] && cover=$(basename "$img") && break
  done

  tracks="["
  track_first=true
  for f in $(ls "$dir"*.mp3 "$dir"*.m4b "$dir"*.m4a \
                 "$dir"*.flac "$dir"*.ogg 2>/dev/null | sort); do
    filename=$(basename "$f")
    dur=$(ffprobe -v quiet -show_entries \
      format=duration -of csv=p=0 "$f" 2>/dev/null | cut -d. -f1)
    dur_ms=$(( ${dur:-0} * 1000 ))
    [ "$track_first" = true ] && track_first=false || tracks="$tracks,"
    tracks="$tracks{\"file\":\"$filename\",\"durationMs\":$dur_ms}"
  done
  tracks="$tracks]"

  [ "$first" = true ] && first=false || echo "," >> "$OUTPUT"
  cat >> "$OUTPUT" << JSON
{
  "id": "$id",
  "title": "$title",
  "coverUrl": "$cover",
  "tracks": $tracks
}
JSON
done

echo "]" >> "$OUTPUT"
REGENEOF

chmod +x "$DATA_DIR/regen_library.sh"
print_success "regen_library.sh written"

# ── audiobook-watch.sh ────────────────────────────────────────────────────────
print_header "Creating folder watcher"

print_step "Writing audiobook-watch.sh..."
cat > "$DATA_DIR/audiobook-watch.sh" << 'WATCHEOF'
#!/bin/bash
source /srv/audiobook-data/config.env

echo "Watching $BOOKS_DIR for changes..."

while true; do
    inotifywait -r -e modify,create,delete,moved_to,moved_from \
        "$BOOKS_DIR" 2>/dev/null

    echo "Change detected. Waiting for activity to settle..."
    while inotifywait -r -e modify,create,delete,moved_to,moved_from \
        -t 25 "$BOOKS_DIR" 2>/dev/null; do
        echo "Still active, resetting settle timer..."
    done

    echo "Activity settled. Regenerating library..."
    /srv/audiobook-data/regen_library.sh
    echo "Library regenerated."
done
WATCHEOF

chmod +x "$DATA_DIR/audiobook-watch.sh"
print_success "audiobook-watch.sh written"

# ── systemd services ──────────────────────────────────────────────────────────
print_header "Setting up systemd services"

print_step "Writing audiobook-api.service..."
sudo tee /etc/systemd/system/audiobook-api.service > /dev/null << SVCEOF
[Unit]
Description=AudioVault Flask API
After=network.target

[Service]
EnvironmentFile=$DATA_DIR/config.env
ExecStart=/usr/bin/python3 $DATA_DIR/audiobook_api.py
WorkingDirectory=$DATA_DIR
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
SVCEOF

print_step "Writing audiobook-watcher.service..."
sudo tee /etc/systemd/system/audiobook-watcher.service > /dev/null << SVCEOF
[Unit]
Description=AudioVault Library Watcher
After=network.target

[Service]
EnvironmentFile=$DATA_DIR/config.env
ExecStart=/bin/bash $DATA_DIR/audiobook-watch.sh
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
SVCEOF

print_step "Enabling and starting services..."
sudo systemctl daemon-reload
sudo systemctl enable audiobook-api audiobook-watcher
sudo systemctl start audiobook-api audiobook-watcher
print_success "Services started"

# ── Initial library scan ──────────────────────────────────────────────────────
print_header "Initial library scan"

print_info "Scanning your books folder for the first time..."
print_warning "This may take a while if you have many books."
"$DATA_DIR/regen_library.sh"
print_success "library.json generated"

# ── Verify ────────────────────────────────────────────────────────────────────
print_header "Verifying installation"

sleep 2  # Give services a moment to start

API_STATUS=$(systemctl is-active audiobook-api)
WATCHER_STATUS=$(systemctl is-active audiobook-watcher)
NGINX_STATUS=$(systemctl is-active nginx)

if [ "$API_STATUS" = "active" ]; then
    print_success "audiobook-api: running"
else
    print_error "audiobook-api: $API_STATUS — run 'sudo journalctl -u audiobook-api -n 20' to debug"
fi

if [ "$WATCHER_STATUS" = "active" ]; then
    print_success "audiobook-watcher: running"
else
    print_error "audiobook-watcher: $WATCHER_STATUS — run 'sudo journalctl -u audiobook-watcher -n 20' to debug"
fi

if [ "$NGINX_STATUS" = "active" ]; then
    print_success "nginx: running"
else
    print_error "nginx: $NGINX_STATUS — run 'sudo systemctl status nginx' to debug"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Setup complete!${RESET}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Your server address for the AudioVault app:"
echo ""
echo -e "  ${BOLD}  http://$LOCAL_IP:8081${RESET}"
echo ""
echo -e "  To verify the server is working, open this URL in a browser:"
echo -e "  ${CYAN}  http://$LOCAL_IP:8081/library.json${RESET}"
echo ""
echo -e "  Books folder:  ${CYAN}$BOOKS_DIR${RESET}"
echo -e "  Add books there and the library will update automatically."
echo ""
echo -e "  If you run into issues, the setup guide is available at:"
echo -e "  ${CYAN}  https://dejnastosic986.github.io/audiobook-player${RESET}"
echo ""
