#!/usr/bin/env bash
# Opt-in: real disposable systemd unit, never touches the sing-box unit or its data.
set -euo pipefail
[[ "${1:-}" == --allow-systemd ]] || { echo 'Requires --allow-systemd on a disposable Linux test host'; exit 2; }
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 50_v2ray_api 60_user_db 61_user_manager 80_installer; do source "lib/$module.sh"; done
TEST=$(mktemp -d /var/tmp/sb-systemd.XXXXXX)
unit="sb-validation-$$"
cleanup() {
 command systemctl stop "$unit" >/dev/null 2>&1 || true
 command systemctl disable "$unit" >/dev/null 2>&1 || true
 rm -f "/etc/systemd/system/$unit.service"
 command systemctl daemon-reload
 rm -rf "$TEST"
}
trap cleanup EXIT
CONFIG_FILE="$TEST/config.json"; USER_DB_FILE="$TEST/users.json"; META_FILE="$TEST/meta.json"
SINGBOX_BIN="$TEST/sing-box"; SINGBOX_INSTALL_DIR="$TEST"; SINGBOX_VERSION_STAMP="$TEST/version"
SB_LOCK_FILE="$TEST/lock"; V2RAY_PROTO_V2RAY="$TEST/stats.proto"
cp /usr/local/bin/sing-box "$SINGBOX_BIN"
read -r socks_port api_port occupied_port http_port < <(python3 - <<'PY'
import socket
ss=[socket.socket() for _ in range(4)]
for s in ss:s.bind(('127.0.0.1',0))
print(*(s.getsockname()[1] for s in ss))
PY
)
V2RAY_API_LISTEN="127.0.0.1:$api_port"
# Route only commands for the production unit name to a real disposable unit.
systemctl() {
 local arg args=()
 for arg in "$@"; do [ "$arg" != sing-box ] || arg="$unit"; args+=("$arg"); done
 command systemctl "${args[@]}"
}
prepare_script_runtime() { command systemctl daemon-reload; }
cat > "/etc/systemd/system/$unit.service" <<UNIT
[Service]
ExecStart=$SINGBOX_BIN run -c $CONFIG_FILE
Restart=no
UNIT
command systemctl daemon-reload
base=$(build_socks_inbound "$socks_port" fixture | jq '{inbounds:[(.listen="127.0.0.1")],outbounds:[{type:"direct",tag:"direct"}],route:{rules:[]}}')
db='{"enabled":true,"users":{"admin":{"enabled":true},"alice":{"enabled":true,"allow_all_nodes":true,"quota_gb":10,"used_up_bytes":0,"used_down_bytes":0}}}'
printf '%s' "$db" > "$USER_DB_FILE"
user_manager_apply_to_json "$base" "$db" '{}' > "$CONFIG_FILE"
ensure_v2ray_api_proto_files
systemctl start sing-box
wait_singbox_ready ''
old=$(singbox_process_token)
config_apply "$(cat "$CONFIG_FILE")"
[ "$(singbox_process_token)" = "$old" ]
echo 'PASS real systemd: no-op config keeps process'
# Config-changing transaction restarts and validates the new instance.
config_apply "$(jq '.log.level="warn"' "$CONFIG_FILE")"
[ "$(singbox_process_token)" != "$old" ]
query_v2ray_api_uptime >/dev/null
before=$(user_db_load); after=$(echo "$before"|jq '.users.alice.quota_gb=20')
old=$(singbox_process_token)
user_manager_commit_edit "$before" "$after"
[ "$(singbox_process_token)" = "$old" ]
user_db_load|jq -e '.users.alice.quota_gb == 20' >/dev/null
echo 'PASS real systemd: policy-only edit keeps process'
# Candidate starts failing only at runtime: real rollback must restore executable and config.
printf 'v1.14.2\n' > "$SINGBOX_VERSION_STAMP"
old_hash=$(sha256sum "$SINGBOX_BIN"|cut -d' ' -f1)
cat > "$TEST/bad-candidate" <<'BAD'
#!/bin/sh
for arg in "$@"; do [ "$arg" != run ] || exit 1; done
exec /usr/local/bin/sing-box "$@"
BAD
chmod +x "$TEST/bad-candidate"
if with_manager_lock install_candidate_singbox "$TEST/bad-candidate" failed-fixture > "$TEST/rollback.log" 2>&1; then
 echo 'FAIL runtime candidate unexpectedly accepted'; exit 1
fi
[ "$(sha256sum "$SINGBOX_BIN"|cut -d' ' -f1)" = "$old_hash" ]
[ "$(cat "$SINGBOX_VERSION_STAMP")" = v1.14.2 ]
systemctl is-active --quiet sing-box
query_v2ray_api_uptime >/dev/null
echo 'PASS real systemd: failing candidate restores core/config and preserves version'
with_manager_lock install_candidate_singbox /usr/local/bin/sing-box v1.14.2 >/dev/null
[ -s "$SINGBOX_BIN.bak" ] && [ -s "$CONFIG_FILE.bak.upgrade" ]
query_v2ray_api_uptime >/dev/null
echo 'PASS real systemd: successful candidate commits and retains rollback files'
