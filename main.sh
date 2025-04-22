#!/bin/bash

set -e

# === 0. Finding active GUI User ===
USER_NAME=$(who | awk '{ print $1 }' | head -n1)
USER_HOME=$(eval echo "~$USER_NAME")
USER_ID=$(id -u "$USER_NAME")

# === 1. Detection of  DISPLAY variable ===
# Na osnovu XDG_SESSION_TYPE ili tty
if [ "$XDG_SESSION_TYPE" == "x11" ]; then
    DISPLAY_N=$(su - "$USER_NAME" -c 'echo $DISPLAY')
    echo "Detected DISPLAY for x11 session: $DISPLAY_N"
else
    DISPLAY_N=$(who | grep -E "(:0|:1|tty7|tty2|tty1)" | awk '{ print $2 }' | head -n1)
    echo "Detected DISPLAY from tty: $DISPLAY_N"
fi

# Function for setup of Display Variable
export_display(){
    if [[ "$DISPLAY_N" == ":0" || "$DISPLAY_N" == ":1" ]]; then
        export DISPLAY="$DISPLAY_N"
    else 
        case "$DISPLAY_N" in
            tty7) export DISPLAY=":0" ;;
            tty1|tty2) export DISPLAY=":1" ;;
            *) export DISPLAY=":0.0" ;;
        esac
    fi
    echo "Using DISPLAY: $DISPLAY"
}

export_display

# === 2. Set up XAUTHORITY ===
XAUTHORITY="$USER_HOME/.Xauthority"
export XAUTHORITY
echo "Using XAUTHORITY: $XAUTHORITY"

# === 3. Check if YAD is installed ===
if ! command -v yad &>/dev/null; then
    echo "Yad is not installed. Installing it..."
    sudo apt-get update
    sudo apt-get install -y yad
else
    echo "Yad is already installed."
fi

# === 4. Log File ===
LOG_FILE="/tmp/onedrive_setup_full_${USER_NAME}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

CONFIG_DIR="$USER_HOME/.config/onedrive"
ONEDRIVE_DIR="$USER_HOME/OneDrive"
DESKTOP_DIR="$USER_HOME/Desktop"
UPLOAD_SERVICE="$USER_HOME/.config/systemd/user/onedrive-upload.service"

echo "==> Starting OneDrive setup for user: $USER_NAME"

# === 5. Installation dependencies ===
echo "==> Installing OneDrive, yad, and curl..."
if ! command -v onedrive &>/dev/null; then
    apt update && apt install -y onedrive yad curl
    echo "✅ OneDrive installation [Success]"
else
    echo "✅ OneDrive is already installed [Success]"
fi

# === 6. Cleanup of old OneDrive configuration ===
echo "==> Removing old configuration if exists..."
rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
chown -R "$USER_NAME:$USER_NAME" "$CONFIG_DIR"
echo "✅ Configuration cleanup [Success]"

# === 7. User Authentification===
echo "==> Starting authentication and waiting for the login URL..."
URL=""
coproc AUTH_PROC {
    sudo -u "$USER_NAME" onedrive
}

while read -r line <&"${AUTH_PROC[0]}"; do
    echo "$line"
    if [[ "$line" == *"https://login.microsoftonline.com"* ]]; then
        URL=$(echo "$line" | grep -oP 'https://login\.microsoftonline\.com[^ ]+')
        echo "✅ Authentication URL: $URL"
        break
    fi
done

if [[ -z "$URL" ]]; then
    echo "❌ Authentication URL not found. [Fail]"
    kill "${AUTH_PROC_PID}" 2>/dev/null || true
    exit 1
fi

# === 8. Open Browser ===
if command -v microsoft-edge &>/dev/null; then
    sudo -u "$USER_NAME" microsoft-edge "$URL" &
else
    sudo -u "$USER_NAME" xdg-open "$URL" &
fi

# === 9. Enternig response URL to yad ===
RESPONSE_URI=$(sudo -u "$USER_NAME" DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY yad --entry --title='OneDrive Auth' --text='Paste the "response URL" from the browser here:' --width=500)

if [[ -z "$RESPONSE_URI" ]]; then
    echo "❌ No response URI entered. [Fail]"
    kill "${AUTH_PROC_PID}" 2>/dev/null || true
    exit 1
fi

echo "✅ Sending response URI..."
echo "$RESPONSE_URI" >&"${AUTH_PROC[1]}"

# === 10. Waiting for finalization of auth ===
while read -r line <&"${AUTH_PROC[0]}"; do
    echo "$line"
    if [[ "$line" == *"Authorization successful"* ]]; then
        echo "✅ Authentication successful! [Success]"
        break
    fi
done

# === 11. Killing one drive process ===
echo "==> Ensuring no OneDrive process is running before syncing..."
pkill -u "$USER_NAME" -f onedrive || true
echo "✅ Existing OneDrive processes killed [Success]"

# === 12. First sync (upload-only) ===
echo "==> Running first sync (upload-only)..."
sudo -u "$USER_NAME" onedrive --synchronize --upload-only
echo "✅ First sync completed [Success]"

# === 13. Creating OneDrive/DesktopUbuntu folder  ===
echo "==> Creating OneDrive/DesktopUbuntu folder..."
mkdir -p "$ONEDRIVE_DIR/DesktopUbuntu"
chown -R "$USER_NAME:$USER_NAME" "$ONEDRIVE_DIR/DesktopUbuntu"
echo "✅ OneDrive/DesktopUbuntu folder created [Success]"

# === 14. Fixing Symlink desktop if already done ===
if [ -L "$DESKTOP_DIR" ]; then
    echo "==> Detected symlinked Desktop. Removing and recreating real folder..."
    rm -f "$DESKTOP_DIR"
    mkdir -p "$DESKTOP_DIR"
    chown "$USER_NAME:$USER_NAME" "$DESKTOP_DIR"
    echo "✅ Fixed symlinked Desktop [Success]"
fi

# === 15. Copying files from Desktop to OneDrive/DesktopUbuntu.. ===
echo "==> Copying files from Desktop to OneDrive/DesktopUbuntu..."
cp -rT "$DESKTOP_DIR" "$ONEDRIVE_DIR/DesktopUbuntu"
chown -R "$USER_NAME:$USER_NAME" "$ONEDRIVE_DIR/DesktopUbuntu"
echo "✅ Files copied from Desktop [Success]"

# === 16. Replacing Desktop with symlink..===
echo "==> Replacing Desktop with symlink..."
rm -rf "$DESKTOP_DIR"
ln -s "$ONEDRIVE_DIR/DesktopUbuntu" "$DESKTOP_DIR"
chown -h "$USER_NAME:$USER_NAME" "$DESKTOP_DIR"
echo "✅ Desktop replaced with symlink [Success]"

# === 17. Creating upload-only systemd service..===
echo "==> Creating upload-only systemd service..."
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
echo "✅ Upload-only systemd service created [Success]"

# === 18. Enabling lingering for user (needed for user services)..===
echo "==> Enabling lingering for user (needed for user services)..."
loginctl enable-linger "$USER_NAME" || true
echo "✅ Linger enabled [Success]"

echo "==> Reloading and starting the upload-only systemd service..."
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user daemon-reexec
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user daemon-reload
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user enable --now onedrive-upload.service
echo "✅ Service enabled and started [Success]"

echo "🎉 OneDrive setup completed successfully for $USER_NAME!"
