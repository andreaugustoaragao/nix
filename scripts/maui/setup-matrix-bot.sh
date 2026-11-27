#!/usr/bin/env bash
# Register the maui alert bot, create its alert room, and write the bot's
# long-lived access_token and the room id to temporary files under
# /data/services/matrix/.
#
# After running this script, copy the generated values into secrets/maui.yaml
# (`matrix_bot_token` and `matrix_alert_room_id`) using `sops secrets/maui.yaml`,
# rebuild maui (`sudo nixos-rebuild switch --flake .#maui`), and remove the
# temporary plaintext files (/data/services/matrix/bot-token,
# /data/services/matrix/alert-room-id, /data/services/matrix/registration_token)
# so secrets only live in sops-nix (/run/secrets/*).
#
# Run this on maui as root after the registration_token_file has been
# placed at /data/services/matrix/registration_token.
#
# Usage:
#   sudo ./scripts/maui/setup-matrix-bot.sh <bot-username> <bot-password> <your-mxid>
# Example:
#   sudo ./scripts/maui/setup-matrix-bot.sh maui-alerts 'somepassword' '@aragao:matrix.faragao.net'

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <bot-username> <bot-password> <your-mxid>" >&2
  exit 2
fi

BOT_USER="$1"
BOT_PASS="$2"
USER_MXID="$3"
HS="https://matrix.faragao.net"
TOKEN_FILE=/data/services/matrix/registration_token

if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "missing $TOKEN_FILE — generate one and chown to continuwuity first" >&2
  exit 1
fi

REG_TOKEN=$(cat "$TOKEN_FILE")

# Kick off registration to obtain a UIA session id.
SESSION=$(curl -sS -X POST -H "Content-Type: application/json" -d '{}' \
  "$HS/_matrix/client/v3/register" | jq -r '.session')
[[ -n "$SESSION" && "$SESSION" != "null" ]] || { echo "no session returned" >&2; exit 1; }

# Submit credentials with the registration token. Continuwuity returns
# either a 200 (success) or 401 with a follow-up flow stage required.
RESP=$(curl -sS -X POST -H "Content-Type: application/json" \
  -d "$(jq -n --arg user "$BOT_USER" --arg pass "$BOT_PASS" --arg token "$REG_TOKEN" --arg sess "$SESSION" \
        '{username:$user,password:$pass,auth:{type:"m.login.registration_token",token:$token,session:$sess}}')" \
  "$HS/_matrix/client/v3/register")

ACCESS_TOKEN=$(echo "$RESP" | jq -r '.access_token // empty')

if [[ -z "$ACCESS_TOKEN" ]]; then
  # Some flows require a second m.login.dummy stage.
  RESP=$(curl -sS -X POST -H "Content-Type: application/json" \
    -d "$(jq -n --arg user "$BOT_USER" --arg pass "$BOT_PASS" --arg sess "$SESSION" \
          '{username:$user,password:$pass,auth:{type:"m.login.dummy",session:$sess}}')" \
    "$HS/_matrix/client/v3/register")
  ACCESS_TOKEN=$(echo "$RESP" | jq -r '.access_token // empty')
fi

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "registration failed:" >&2
  echo "$RESP" >&2
  exit 1
fi

install -m 0600 -o continuwuity -g continuwuity /dev/stdin /data/services/matrix/bot-token <<< "$ACCESS_TOKEN"
echo "saved bot access token to /data/services/matrix/bot-token"

# Create the private alert room with just the bot.
ROOM_ID=$(curl -sS -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"maui alerts","preset":"private_chat"}' \
  "$HS/_matrix/client/v3/createRoom" | jq -r '.room_id')

[[ -n "$ROOM_ID" && "$ROOM_ID" != "null" ]] || { echo "createRoom failed" >&2; exit 1; }

install -m 0600 -o continuwuity -g continuwuity /dev/stdin /data/services/matrix/alert-room-id <<< "$ROOM_ID"
echo "saved alert room id ($ROOM_ID) to /data/services/matrix/alert-room-id"

# Invite the user.
curl -fsS -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg uid "$USER_MXID" '{user_id:$uid}')" \
  "$HS/_matrix/client/v3/rooms/$ROOM_ID/invite" \
  >/dev/null

echo "invited $USER_MXID. Accept the invite in element-desktop."
echo "Next: add bot-token and alert-room-id to secrets/maui.yaml via sops, then remove the temporary plaintext files."
