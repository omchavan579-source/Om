#!/usr/bin/env bash
#
# configure-rclone.sh — writes an rclone config for Google Drive.
#
# Two supported ways of authenticating (see docs/setup-drive-credentials.md):
#
#   1. RCLONE_CONF_B64  — your local rclone.conf, base64-encoded.
#                         Recommended for personal @gmail.com accounts.
#   2. GDRIVE_SA_JSON   — a Google service-account key (raw JSON).
#                         Recommended for Google Workspace / Shared Drives.
#                         Optional: GDRIVE_FOLDER_ID, GDRIVE_TEAM_DRIVE.
#
# After this script runs, an rclone remote called $DRIVE_REMOTE (default "gdrive")
# is available, pointing at your Drive (or at GDRIVE_FOLDER_ID if set).
#
set -euo pipefail

: "${DRIVE_REMOTE:=gdrive}"
: "${RCLONE_CONF_PATH:=$HOME/.config/rclone/rclone.conf}"
: "${RCLONE_CONF_B64:=}"
: "${GDRIVE_SA_JSON:=}"
: "${GDRIVE_FOLDER_ID:=}"
: "${GDRIVE_TEAM_DRIVE:=}"

mkdir -p "$(dirname "$RCLONE_CONF_PATH")"

if [ -n "$RCLONE_CONF_B64" ]; then
  echo "==> Using base64-encoded rclone.conf from RCLONE_CONF_B64"

  # GNU coreutils uses 'base64 --decode'; macOS/BSD uses 'base64 -D'.
  # Whitespace (line wraps) in the stored secret is tolerated either way.
  decode_b64() {
    if base64 --decode </dev/null >/dev/null 2>&1; then
      tr -d ' \t\r\n' | base64 --decode
    else
      tr -d ' \t\r\n' | base64 -D
    fi
  }

  if ! printf '%s' "$RCLONE_CONF_B64" | decode_b64 > "$RCLONE_CONF_PATH" 2>/dev/null; then
    echo "ERROR: RCLONE_CONF_B64 is not valid base64." >&2
    echo "Re-create it with:  base64 -w0 ~/.config/rclone/rclone.conf   (Linux)" >&2
    echo "                    base64 -i rclone.conf | tr -d '\\n'       (macOS)" >&2
    exit 1
  fi
  chmod 600 "$RCLONE_CONF_PATH"

  if ! grep -q "^\[$DRIVE_REMOTE\]" "$RCLONE_CONF_PATH"; then
    echo "ERROR: the config you provided has no remote named [$DRIVE_REMOTE]." >&2
    echo "Remotes found: $(grep -o '^\[.*\]' "$RCLONE_CONF_PATH" | tr '\n' ' ')" >&2
    echo "Either rename your remote to [$DRIVE_REMOTE], or set the DRIVE_REMOTE env var." >&2
    exit 1
  fi

elif [ -n "$GDRIVE_SA_JSON" ]; then
  echo "==> Using Google service account from GDRIVE_SA_JSON"
  SA_FILE="${RUNNER_TEMP:-/tmp}/gdrive-service-account.json"
  printf '%s' "$GDRIVE_SA_JSON" > "$SA_FILE"
  chmod 600 "$SA_FILE"

  {
    echo "[$DRIVE_REMOTE]"
    echo "type = drive"
    echo "scope = drive"
    echo "service_account_file = $SA_FILE"
    [ -n "$GDRIVE_FOLDER_ID" ] && echo "root_folder_id = $GDRIVE_FOLDER_ID"
    [ -n "$GDRIVE_TEAM_DRIVE" ] && echo "team_drive = $GDRIVE_TEAM_DRIVE"
  } > "$RCLONE_CONF_PATH"
  chmod 600 "$RCLONE_CONF_PATH"

  if [ -z "$GDRIVE_FOLDER_ID" ] && [ -z "$GDRIVE_TEAM_DRIVE" ]; then
    echo "WARNING: no GDRIVE_FOLDER_ID set. A service account can only see folders" >&2
    echo "         that were explicitly shared with its email address." >&2
  fi

else
  cat >&2 <<'EOF'
ERROR: no Google Drive credentials were found.

Set ONE of these before running (in GitHub: Settings -> Secrets and variables -> Actions):

  * RCLONE_CONF_B64  - your rclone config, base64-encoded  (personal Gmail - recommended)
  * GDRIVE_SA_JSON   - a Google service account JSON key  (Workspace / Shared Drives)

Full instructions: docs/setup-drive-credentials.md
EOF
  exit 1
fi

echo "==> rclone remotes configured:"
rclone listremotes
