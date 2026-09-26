#!/usr/bin/env bash
# Isolated real remote rule downloads and relay/WARP SOCKS forwarding.
set -euo pipefail
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 50_v2ray_api 64_warp; do source "lib/$module.sh"; done
T=$(mktemp -d); pids=(); core_pid=''
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; [ -z "$core_pid" ] || kill "$core_pid" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
read -r entry_port landing_port api_port http_port < <(python3 - <<'PY'
import socket
ss=[socket.socket() for _ in range(4)]
for s in ss:s.bind(('127.0.0.1',0))
print(*(s.getsockname()[1] for s in ss))
PY
)
echo '{"version":3,"rules":[{"ip_cidr":["127.0.0.1/32"]}]}' > "$T/rules.json"
sing-box rule-set compile -o "$T/test.srs" "$T/rules.json"
printf payload > "$T/payload"
python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$T" > "$T/http.log" 2>&1 & pids+=("$!")
jq -nc --argjson port "$landing_port" '{inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$port}],outbounds:[{type:"direct",tag:"direct"}]}' > "$T/landing.json"
sing-box run -c "$T/landing.json" > "$T/landing.log" 2>&1 & pids+=("$!")
V2RAY_API_LISTEN="127.0.0.1:$api_port"; V2RAY_PROTO_V2RAY="$T/stats.proto"; ensure_v2ray_api_proto_files
entry="socks-$entry_port"
base=$(build_socks_inbound "$entry_port" fixture|jq '{inbounds:[(.listen="127.0.0.1")],outbounds:[{type:"direct",tag:"direct"}],route:{rules:[]}}')
url="http://localhost:$http_port/test.srs"
for mode in full partial warp; do
  auth="$entry"; tag=''
  case "$mode" in
    full)
      auth="$entry-to-test"; tag=to-test
      projected=$(echo "$base"|jq --arg auth "$auth" --argjson port "$landing_port" '.inbounds[0].users += [{username:$auth,password:"fixture"}] | .outbounds += [{type:"socks",tag:"to-test",server:"127.0.0.1",server_port:$port}]')
      config=$(route_rebuild "$projected" '{}') ;;
    partial)
      tag=relay-test
      meta=$(jq -nc --arg url "$url" --argjson port "$landing_port" '{relay:{landings:{test:{server:"127.0.0.1",port:$port}},rules:[{tag:"relay-geosite-test",file:"test.srs",url:$url,landing_id:"test"}]}}')
      config=$(relay_project_partial_state_with_meta "$base" "$meta") ;;
    warp)
      tag=warp
      rules=$(jq -nc --arg url "$url" '[{tag:"relay-test",file:"test.srs",url:$url}]')
      projected=$(warp_config_project_json "$base" "$rules" true "$landing_port")
      config=$(route_rebuild "$projected" '{"warp":{"mode":"rules","rules":[{"file":"test.srs"}]}}') ;;
  esac
  echo "$config"|jq --arg api "$V2RAY_API_LISTEN" --arg tag "$tag" '.experimental.v2ray_api={listen:$api,stats:{enabled:true,outbounds:[$tag]}}' > "$T/config.json"
  sing-box check -c "$T/config.json"
  sing-box run -c "$T/config.json" > "$T/core.log" 2>&1 & core_pid=$!
  for ((n=0;n<40;n++)); do query_v2ray_api_uptime >/dev/null 2>&1 && break; sleep .25; done
  if ! curl -fsS --max-time 5 --noproxy '' --socks5 "127.0.0.1:$entry_port" --proxy-user "$auth:fixture" "http://127.0.0.1:$http_port/payload" -o "$T/result"; then cat "$T/core.log"; exit 1; fi
  [ "$(cat "$T/result")" = payload ]
  v2ray_api_query QueryStats '{"pattern":"outbound>>>","reset":false}' | jq -e --arg tag "$tag" '[.stat[]? | select(.name == ("outbound>>>"+$tag+">>>traffic>>>downlink")) | .value|tonumber]|add > 0' >/dev/null
  ! grep -q 'deprecated' "$T/core.log"
  kill "$core_pid"; wait "$core_pid" || true; core_pid=''
  echo "PASS $mode: real SOCKS forwarding and remote-rule download, no deprecation warning"
done
