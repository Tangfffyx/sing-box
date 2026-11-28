#!/usr/bin/env bash
# Exercise the generated artifact in temporary paths with a real core and local HTTP.
set -euo pipefail
cd "$(dirname "$0")/.."
core="${1:?absolute path to test sing-box}"
source <(sed '/^main_menu$/d' sb.sh)
testdir="$(mktemp -d)"
pid='' client='' http=''
cleanup() {
  for child in "$pid" "$client" "$http"; do
    if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
  done
  rm -rf "$testdir"
}
trap cleanup EXIT
CONFIG_FILE="$testdir/config.json"
META_FILE="$testdir/meta.json"
USER_DB_FILE="$testdir/users.json"
SINGBOX_INSTALL_DIR="$testdir"
SINGBOX_BIN="$testdir/sing-box"
SINGBOX_VERSION_STAMP="$testdir/stamp"
SCRIPT_LOG_FILE="$testdir/access.log"
SB_LOCK_FILE="$testdir/lock"
SB_TARGET_SCRIPT="$testdir/sb.sh"
SB_SHORTCUT="$testdir/s"
INIT_SYSTEM=unknown
export PATH="$testdir:$PATH"
mkdir "$testdir/www"
printf 'release-fixture' > "$testdir/www/index.html"
read -r port client_port http_port < <(python3 - <<'PY'
import socket
socks = [socket.socket() for _ in range(3)]
for sock in socks:
    sock.bind(("127.0.0.1", 0))
print(*(sock.getsockname()[1] for sock in socks))
PY
)
http_target="http://127.0.0.1:$http_port/"
python3 -m http.server --bind 127.0.0.1 --directory "$testdir/www" "$http_port" > "$testdir/http.log" 2>&1 &
http=$!
# The real service managers spawn outside the shell holding the manager lock.
flock() { fixture_lock_fd="$1"; command flock "$@"; }
clear() { :; }
pause() { :; }
init_manager_env() { :; }
sync_user_usage_counters() { :; }
prepare_script_runtime() { :; }
protocol_install_time_guard() { :; }
get_public_ip() { printf '%s\n' 127.0.0.1; }
ensure_v2ray_api_on_json() { cat <<< "$1"; }
singbox_service_active() { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
reload_or_restart_singbox_safe() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  jq --arg log "$SCRIPT_LOG_FILE" '.log.output=$log' "$CONFIG_FILE" > "$testdir/runtime.json"
  (
    if [ -n "${fixture_lock_fd:-}" ]; then exec {fixture_lock_fd}>&-; fi
    exec "$SINGBOX_BIN" -D "$testdir" run -c "$testdir/runtime.json"
  ) > "$testdir/server.log" 2>&1 &
  pid=$!
  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then cat "$testdir/server.log"; return 1; fi
}
printf '%s\n' '{}' > "$META_FILE"
with_manager_lock install_candidate_singbox "$core" fixture-first
user_db_min_template > "$USER_DB_FILE"
cmp "$SINGBOX_BIN" "$core"
# Use the actual installation menu and import the emitted SS URI into a real client.
protocol_manager <<< $'1\n4\nc\n'"$port"$'\n\n0' > "$testdir/menus"
link="$(awk '/通用链接: ss:\/\// {print $NF; exit}' "$testdir/menus")"
[ -n "$link" ] || { cat "$testdir/menus"; exit 1; }
python3 - "$link" "$client_port" > "$testdir/client.json" <<'PY'
import json, sys
from urllib.parse import unquote, urlsplit
uri = urlsplit(sys.argv[1])
assert uri.scheme == "ss" and uri.hostname == "127.0.0.1"
print(json.dumps({
    "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": int(sys.argv[2])}],
    "outbounds": [{"type": "shadowsocks", "server": uri.hostname, "server_port": uri.port,
                   "method": unquote(uri.username), "password": unquote(uri.password)}],
}))
PY
"$core" -D "$testdir" run -c "$testdir/client.json" > "$testdir/client.log" 2>&1 &
client=$!
sleep 0.3
request() {
  curl --noproxy '' -fsS --max-time 5 --socks5 "127.0.0.1:$client_port" "$http_target"
}
assert_connected() {
  local attempt body
  for attempt in {1..15}; do
    if body="$(request 2> "$testdir/curl.log")" && [ "$body" = release-fixture ]; then return 0; fi
    sleep 0.2
  done
  tail -n 20 "$testdir/curl.log" "$testdir/server.log" "$testdir/access.log" "$testdir/client.log" >&2
  return 1
}
assert_connected
printf '%s\n' 'PASS generated script: first deployment, node installation, SS2022 URI import and connection'

cp "$CONFIG_FILE" "$testdir/before-config"
cp "$USER_DB_FILE" "$testdir/before-users"
cp "$META_FILE" "$testdir/before-meta"
old_pid="$pid"
with_manager_lock install_candidate_singbox "$core" fixture-updated
[ "$pid" != "$old_pid" ]
[ "$(cat "$SINGBOX_VERSION_STAMP")" = fixture-updated ]
cmp "$SINGBOX_BIN.bak" "$core"
cmp "$CONFIG_FILE.bak.upgrade" "$testdir/before-config"
assert_connected
cat > "$testdir/bad" <<BAD
#!/bin/sh
for arg; do [ "\$arg" != run ] || exit 1; done
exec "$core" "\$@"
BAD
chmod 700 "$testdir/bad"
if with_manager_lock install_candidate_singbox "$testdir/bad" fixture-failed; then exit 1; fi
[ "$(cat "$SINGBOX_VERSION_STAMP")" = fixture-updated ]
cmp "$CONFIG_FILE" "$testdir/before-config"
cmp "$USER_DB_FILE" "$testdir/before-users"
cmp "$META_FILE" "$testdir/before-meta"
cmp "$SINGBOX_BIN" "$core"
assert_connected
printf '%s\n' 'PASS generated script: upgrade and failed-candidate rollback preserve exported link and management data'
