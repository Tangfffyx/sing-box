#!/usr/bin/env bash
# Run against a real Linux core built with with_v2ray_api. Only loopback traffic.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="${1:?path to sing-box}"
GRPC="${2:?path to grpcurl}"
cd "$ROOT"
source lib/00_base.sh
source lib/01_utils.sh
source lib/10_config.sh
source lib/50_v2ray_api.sh
TMP_SMOKE="$(mktemp -d)"
core_pid=""; http_pid=""
cleanup() {
  [ -z "$core_pid" ] || kill "$core_pid" 2>/dev/null || true
  [ -z "$http_pid" ] || kill "$http_pid" 2>/dev/null || true
  rm -rf "$TMP_SMOKE"
}
trap cleanup EXIT
read -r socks_port api_port http_port < <(python3 - <<'PY'
import socket
sockets = [socket.socket() for _ in range(3)]
for s in sockets: s.bind(('127.0.0.1', 0))
print(*(s.getsockname()[1] for s in sockets))
for s in sockets: s.close()
PY
)
GRPCURL_BIN="$GRPC"
V2RAY_API_LISTEN="127.0.0.1:$api_port"
V2RAY_PROTO_EXP="$TMP_SMOKE/stats.proto"
# Extract the exact proto shipped by the script without writing /etc.
sed -n "/^syntax = \"proto3\";/,/^EOF_V2E/p" lib/50_v2ray_api.sh | sed '/^EOF_V2E/,$d' > "$V2RAY_PROTO_EXP"
# sed range above stops once EOF_V2E is reached via the second sed.
jq -n --argjson socks "$socks_port" --arg api "$V2RAY_API_LISTEN" '{
 inbounds:[{type:"socks",tag:"socks-test",listen:"127.0.0.1",listen_port:$socks,users:[{username:"node@alice",password:"fixture"},{username:"node@disabled",password:"fixture"}]}],
 outbounds:[{type:"direct",tag:"direct"},{type:"block",tag:"reject"}],
 route:{rules:[{auth_user:"node@alice",outbound:"direct"}],final:"reject"},
 experimental:{v2ray_api:{listen:$api,stats:{enabled:true,users:["node@alice"]}}}
}' > "$TMP_SMOKE/config.json"
"$CORE" check -c "$TMP_SMOKE/config.json"
dd if=/dev/zero of="$TMP_SMOKE/payload" bs=65536 count=1 2>/dev/null
python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$TMP_SMOKE" > "$TMP_SMOKE/http.log" 2>&1 &
http_pid=$!
start_core() {
  "$CORE" run -c "$TMP_SMOKE/config.json" > "$TMP_SMOKE/core.log" 2>&1 &
  core_pid=$!
  local attempt
  for ((attempt=0;attempt<40;attempt++)); do
    if query_v2ray_api_uptime >/dev/null 2>&1; then return 0; fi
    kill -0 "$core_pid" 2>/dev/null || { cat "$TMP_SMOKE/core.log"; return 1; }
    sleep 0.25
  done
  cat "$TMP_SMOKE/core.log"
  return 1
}
INIT_SYSTEM=systemd
systemctl() { echo "$core_pid"; }
start_core
empty="$(query_v2ray_api_stats_json)"
[ "$empty" = '[]' ]
for ((attempt=0;attempt<20;attempt++)); do
  if curl -fsS --noproxy '*' "http://127.0.0.1:$http_port/payload" -o /dev/null; then break; fi
  sleep 0.1
done
curl -fsS --max-time 5 --noproxy '' --socks5 "127.0.0.1:$socks_port" --proxy-user 'node@alice:fixture' "http://127.0.0.1:$http_port/payload" -o /dev/null
if curl -fsS --max-time 3 --noproxy '' --socks5 "127.0.0.1:$socks_port" --proxy-user 'node@disabled:fixture' "http://127.0.0.1:$http_port/payload" -o /dev/null 2>/dev/null; then
  echo 'Disabled user unexpectedly allowed' >&2; exit 1
fi
snapshot="$(query_usage_snapshot)"
db="$(account_usage_snapshot '{"users":{"alice":{}}}' "$snapshot")"
printf '%s' "$db" | jq -e '.users.alice.used_down_bytes >= 65536' >/dev/null
previous="$(printf '%s' "$db" | jq '.users.alice.used_down_bytes')"
kill "$core_pid"; wait "$core_pid" || true; core_pid=""
start_core
curl -fsS --max-time 5 --noproxy '' --socks5 "127.0.0.1:$socks_port" --proxy-user 'node@alice:fixture' "http://127.0.0.1:$http_port/payload" -o /dev/null
snapshot="$(query_usage_snapshot)"
db="$(account_usage_snapshot "$db" "$snapshot")"
printf '%s' "$db" | jq -e --argjson previous "$previous" '.users.alice.used_down_bytes >= ($previous+65536)' >/dev/null
printf 'PASS real core: empty stats, allowed/disabled users, traffic accounting across restart\n'
