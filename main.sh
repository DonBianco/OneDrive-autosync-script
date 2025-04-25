#!/bin/bash

set -e

# === 0. Log File (START FIRST!) ===
USER_NAME=$(who | awk '{ print $1 }' | head -n1)
LOG_FILE="/tmp/onedrive_setup_full_${USER_NAME}.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "▶️ Starting OneDrive setup script..."

# === Step Tracker ===
STEPS_LOG=()
log_step() {
    local STATUS=$1
    local MESSAGE=$2
    STEPS_LOG+=("$STATUS - $MESSAGE")
}

# === 1. Finding active GUI User ===
USER_HOME=$(eval echo "~$USER_NAME")
USER_ID=$(id -u "$USER_NAME")

echo "🔍 Active GUI user: $USER_NAME (UID: $USER_ID)"
echo "🏠 Home directory: $USER_HOME"

# === 2. Detection of DISPLAY variable ===
if [ "$XDG_SESSION_TYPE" == "x11" ]; then
    DISPLAY_N=$(su - "$USER_NAME" -c 'echo $DISPLAY')
    echo "🖥 Detected DISPLAY for x11 session: $DISPLAY_N"
else
    DISPLAY_N=$(who | grep -E "(:0|:1|tty7|tty2|tty1)" | awk '{ print $2 }' | head -n1)
    echo "🖥 Detected DISPLAY from tty: $DISPLAY_N"
fi

export_display() {
    if [[ "$DISPLAY_N" == ":0" || "$DISPLAY_N" == ":1" ]]; then
        export DISPLAY="$DISPLAY_N"
    else 
        case "$DISPLAY_N" in
            tty7) export DISPLAY=":0" ;;
            tty1|tty2) export DISPLAY=":1" ;;
            *) export DISPLAY=":0.0" ;;
        esac
    fi
    echo "🖥 Using DISPLAY: $DISPLAY"
}
export_display

# === 3. Set up XAUTHORITY ===
XAUTHORITY="$USER_HOME/.Xauthority"
export XAUTHORITY
echo "🔑 Using XAUTHORITY: $XAUTHORITY"

# === 4. Dependencies ===
echo "📦 Checking and installing dependencies..."
MISSING=()
for pkg in onedrive zenity curl xdg-utils dbus dbus-x11 dbus-bin dbus-daemon libdbus-1-3; do
    dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "⚙️ Installing missing packages: ${MISSING[*]}"
    if [ "$EUID" -ne 0 ]; then
        sudo apt update
        sudo apt --fix-broken install
        sudo apt install -y "${MISSING[@]}"
    else
        apt update
        sudo apt --fix-broken install
        apt install -y "${MISSING[@]}"
    fi
    log_step "✅" "Installed missing packages: ${MISSING[*]}"
else
    echo "✅ All dependencies already installed"
    log_step "✅" "All dependencies already installed"
fi

# === Force install specific dbus versions ===
echo "📦 Ensuring specific dbus versions..."
sudo apt install -y dbus-x11=1.14.10-4ubuntu4.1 dbus-bin=1.14.10-4ubuntu4.1 dbus-daemon=1.14.10-4ubuntu4.1 libdbus-1-3=1.14.10-4ubuntu4.1
log_step "✅" "Forced specific dbus versions (1.14.10-4ubuntu4.1) installation."

# === 5. Paths ===
CONFIG_DIR="$USER_HOME/.config/onedrive"
ONEDRIVE_DIR="$USER_HOME/OneDrive"
DESKTOP_DIR="$USER_HOME/Desktop"
UPLOAD_SERVICE="$USER_HOME/.config/systemd/user/onedrive-upload.service"

echo "📁 OneDrive config dir: $CONFIG_DIR"
echo "📁 OneDrive sync dir: $ONEDRIVE_DIR"
echo "📁 Desktop dir: $DESKTOP_DIR"

# === 6. Check and backup existing config ===
if [ -d "$CONFIG_DIR" ]; then
    BACKUP="$CONFIG_DIR.bak_$(date +%s)"
    echo "🛑 Existing OneDrive config detected. Backing up to $BACKUP"
    mv "$CONFIG_DIR" "$BACKUP"
    log_step "✅" "Backed up existing OneDrive config"
fi
mkdir -p "$CONFIG_DIR"
chown -R "$USER_NAME:$USER_NAME" "$CONFIG_DIR"
echo "✅ Fresh OneDrive config directory created"
log_step "✅" "Fresh OneDrive config directory created"

# === 7. Authentication ===
echo "🔐 Starting OneDrive authentication..."
URL=""
coproc AUTH_PROC {
    sudo -u "$USER_NAME" onedrive
}

while read -r line <&"${AUTH_PROC[0]}"; do
    echo "$line"
    if [[ "$line" == *"https://login.microsoftonline.com"* ]]; then
        URL=$(echo "$line" | grep -oP 'https://login\.microsoftonline\.com[^ ]+')
        echo "🔗 Auth URL: $URL"
        break
    fi
done

if [[ -z "$URL" ]]; then
    echo "❌ Failed to find authentication URL"
    log_step "❌" "Failed to find authentication URL"
    kill "${AUTH_PROC_PID}" 2>/dev/null || true
    exit 1
fi

# === 8. Open browser ===
echo "🌐 Opening browser for authentication..."
if command -v microsoft-edge &>/dev/null; then
   sudo -u "$USER_NAME" microsoft-edge --new-window "$URL" 
else
    sudo -u "$USER_NAME" xdg-open "$URL" &
fi

# === 9. Get response URI via Zenity ===
RESPONSE_URI=$(sudo -u "$USER_NAME" \
    DISPLAY=$DISPLAY \
    XAUTHORITY=$XAUTHORITY \
    XDG_RUNTIME_DIR="/run/user/$USER_ID" \
    dbus-launch --exit-with-session \
    zenity --entry --title="OneDrive Auth" --text="Paste the 'response URL' from the browser here:")


if [[ -z "$RESPONSE_URI" ]]; then
    echo "❌ No response URI entered"
    log_step "❌" "No response URI entered"
    kill "${AUTH_PROC_PID}" 2>/dev/null || true
    exit 1
fi

echo "📨 Sending response URI..."
echo "$RESPONSE_URI" >&"${AUTH_PROC[1]}"

# === 10. Wait for successful login ===
while read -r line <&"${AUTH_PROC[0]}"; do
    echo "$line"
    if [[ "$line" == *"Authorization successful"* ]]; then
        echo "✅ Authentication successful!"
        log_step "✅" "Authentication successful"
        break
    fi
done

# === 11. Kill existing onedrive processes ===
echo "🛑 Killing existing onedrive processes..."
pgrep -u "$USER_NAME" -f onedrive && pkill -u "$USER_NAME" -f onedrive || echo "ℹ️ No onedrive process to kill"
echo "✅ Clean state ready"
log_step "✅" "Cleaned existing OneDrive processes"

# === 12. First upload-only sync ===
echo "⬆️ Running initial upload-only sync..."
sudo -u "$USER_NAME" onedrive --synchronize --upload-only
echo "✅ Initial sync complete"
log_step "✅" "Initial upload-only sync complete"

# === 13. Create OneDrive/DesktopUbuntu ===
mkdir -p "$ONEDRIVE_DIR/DesktopUbuntu"
chown -R "$USER_NAME:$USER_NAME" "$ONEDRIVE_DIR/DesktopUbuntu"
echo "✅ Created DesktopUbuntu folder"
log_step "✅" "Created DesktopUbuntu folder"

# === 14. Handle Desktop symlink ===
if [ -L "$DESKTOP_DIR" ]; then
    echo "🔗 Desktop is a symlink. Removing..."
    rm -f "$DESKTOP_DIR"
elif [ -d "$DESKTOP_DIR" ]; then
    echo "📁 Existing Desktop folder found. Backing up..."
    mv "$DESKTOP_DIR" "${DESKTOP_DIR}_bak_$(date +%s)"
fi

mkdir -p "$DESKTOP_DIR"
cp -rT "$DESKTOP_DIR" "$ONEDRIVE_DIR/DesktopUbuntu"
chown -R "$USER_NAME:$USER_NAME" "$ONEDRIVE_DIR/DesktopUbuntu"

echo "🔗 Replacing Desktop with symlink..."
rm -rf "$DESKTOP_DIR"
ln -s "$ONEDRIVE_DIR/DesktopUbuntu" "$DESKTOP_DIR"
chown -h "$USER_NAME:$USER_NAME" "$DESKTOP_DIR"
echo "✅ Desktop symlinked to OneDrive"
log_step "✅" "Desktop symlinked to OneDrive"

# === 15. Create systemd service ===
mkdir -p "$(dirname "$UPLOAD_SERVICE")"

cat <<EOF > "$UPLOAD_SERVICE"
[Unit]
Description=OneDrive Upload-Only Sync (Desktop)
After=network-online.target

[Service]
ExecStart=/usr/bin/onedrive --monitor --upload-only --single-directory "DesktopUbuntu"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

chown "$USER_NAME:$USER_NAME" "$UPLOAD_SERVICE"
echo "✅ Created systemd upload-only service"
log_step "✅" "Created systemd upload-only service"

# === 16. Enable lingering and start service ===
echo "🔄 Enabling linger mode..."
loginctl enable-linger "$USER_NAME" || true

echo "🚀 Starting OneDrive service..."
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user daemon-reexec
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user daemon-reload
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user enable --now onedrive-upload.service
echo "✅ OneDrive systemd service active"
log_step "✅" "OneDrive systemd service active"

# === 17. Summary Output ===
echo -e "\n📋 OneDrive Setup Summary:"
for step in "${STEPS_LOG[@]}"; do
    echo "  $step"
done

echo "🎉 OneDrive setup complete for user: $USER_NAME!"
