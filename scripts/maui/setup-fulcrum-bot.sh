#!/usr/bin/env bash
# Register the fulcrum bot, save its access token + device id, create a private
# fulcrum chat room, and invite the operator.
#
# After running this script, store the generated token, device id, and room id
# in sops-nix (`secrets/secrets.yaml` for fulcrum, or `secrets/maui.yaml` if
# hosted on maui) and delete the temporary plaintext files under
# /data/services/matrix/ (`fulcrum-token`, `fulcrum-device-id`,
# `fulcrum-room-id`, `registration_token`).
#
# Run on maui as root after /data/services/matrix/registration_token has been
# placed (see scripts/maui/setup-matrix-bot.sh for how to provision it).
#
# Usage:
#   sudo ./scripts/maui/setup-fulcrum-bot.sh <bot-username> <bot-password> <your-mxid>
# Example:
#   sudo ./scripts/maui/setup-fulcrum-bot.sh fulcrum 'somepassword' '@aragao:matrix.faragao.net'

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
TOKEN_OUT=/data/services/matrix/fulcrum-token
DEVICE_OUT=/data/services/matrix/fulcrum-device-id
ROOM_OUT=/data/services/matrix/fulcrum-room-id
DEVICE_ID="fulcrum-bot-$(date +%s)"

if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "missing $TOKEN_FILE — generate one and chown to continuwuity first" >&2
  exit 1
fi

REG_TOKEN=$(cat "$TOKEN_FILE")

# Kick off registration to obtain a UIA session id.
SESSION=$(curl -sS -X POST -H "Content-Type: application/json" -d '{}' \
  "$HS/_matrix/client/v3/register" | jq -r '.session')
[[ -n "$SESSION" && "$SESSION" != "null" ]] || { echo "no session returned" >&2; exit 1; }

RESP=$(curl -sS -X POST -H "Content-Type: application/json" \
  -d "$(jq -n --arg user "$BOT_USER" --arg pass "$BOT_PASS" --arg dev "$DEVICE_ID" \
              --arg token "$REG_TOKEN" --arg sess "$SESSION" \
        '{username:$user,password:$pass,device_id:$dev,initial_device_display_name:"fulcrum",auth:{type:"m.login.registration_token",token:$token,session:$sess}}')" \
  "$HS/_matrix/client/v3/register")

ACCESS_TOKEN=$(echo "$RESP" | jq -r '.access_token // empty')
RETURNED_DEVICE=$(echo "$RESP" | jq -r '.device_id // empty')

if [[ -z "$ACCESS_TOKEN" ]]; then
  RESP=$(curl -sS -X POST -H "Content-Type: application/json" \
    -d "$(jq -n --arg user "$BOT_USER" --arg pass "$BOT_PASS" --arg dev "$DEVICE_ID" --arg sess "$SESSION" \
          '{username:$user,password:$pass,device_id:$dev,initial_device_display_name:"fulcrum",auth:{type:"m.login.dummy",session:$sess}}')" \
    "$HS/_matrix/client/v3/register")
  ACCESS_TOKEN=$(echo "$RESP" | jq -r '.access_token // empty')
  RETURNED_DEVICE=$(echo "$RESP" | jq -r '.device_id // empty')
fi

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "registration failed:" >&2
  echo "$RESP" >&2
  exit 1
fi

DEVICE_ID="${RETURNED_DEVICE:-$DEVICE_ID}"

install -m 0600 -o continuwuity -g continuwuity /dev/stdin "$TOKEN_OUT" <<< "$ACCESS_TOKEN"
echo "saved bot access token to $TOKEN_OUT"
install -m 0600 -o continuwuity -g continuwuity /dev/stdin "$DEVICE_OUT" <<< "$DEVICE_ID"
echo "saved bot device id ($DEVICE_ID) to $DEVICE_OUT"

# Create an encrypted private chat room and invite the operator.
ROOM_ID=$(curl -sS -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg uid "$USER_MXID" \
        '{name:"fulcrum",preset:"trusted_private_chat",invite:[$uid],
          initial_state:[{type:"m.room.encryption",state_key:"",content:{algorithm:"m.megolm.v1.aes-sha2"}}]}')" \
  "$HS/_matrix/client/v3/createRoom" | jq -r '.room_id')

[[ -n "$ROOM_ID" && "$ROOM_ID" != "null" ]] || { echo "createRoom failed" >&2; exit 1; }

install -m 0600 -o continuwuity -g continuwuity /dev/stdin "$ROOM_OUT" <<< "$ROOM_ID"
echo "saved fulcrum room id ($ROOM_ID) to $ROOM_OUT"
echo
echo "Store the following in sops-nix (then remove the temporary files above):"
echo "  MATRIX_HOMESERVER_URL=$HS"
echo "  MATRIX_USER_ID=@$BOT_USER:matrix.faragao.net"
echo "  MATRIX_ACCESS_TOKEN=\$(cat $TOKEN_OUT)"
echo "  MATRIX_DEVICE_ID=\$(cat $DEVICE_OUT)"
echo
echo "Accept the invite to '$ROOM_ID' in Element-Desktop, then restart Fulcrum."
