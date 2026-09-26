#!/usr/bin/env bash
# Generates isolated fixtures using the production builders; never touches /etc.
set -euo pipefail
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 50_v2ray_api 60_user_db 61_user_manager; do source "lib/$module.sh"; done
out=${1:?fixture directory}; base=${2:?base port}
mkdir -p "$out"
ensure_self_signed_cert() { :; }
openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) -nodes -keyout "$out/key.pem" -out "$out/cert.pem" -days 1 -subj '/CN=localhost' >/dev/null 2>&1
pair=$(sing-box generate reality-keypair)
private=$(echo "$pair"|awk '/PrivateKey/ {print $2}')
echo "$pair"|awk '/PublicKey/ {print $2}' > "$out/public.key"
{
  build_vless_reality_inbound "$base" localhost "$private" abcd
  build_anytls_inbound "$((base+1))" localhost
  build_ss_inbound "$((base+2))"
  build_socks_inbound "$((base+3))"
  build_trojan_inbound "$((base+4))" localhost
  build_vmess_ws_inbound "$((base+5))" 127.0.0.1 /fixture
  build_vless_ws_inbound "$((base+6))" 127.0.0.1 /fixture
  build_tuic_inbound "$((base+7))" localhost
} | jq -s --arg crt "$out/cert.pem" --arg key "$out/key.pem" --argjson handshake "$((base+10))" '
 map(.listen="127.0.0.1" | if .tls.certificate_path? then .tls.certificate_path=$crt | .tls.key_path=$key else . end
 | if .tls.reality? then .tls.reality.handshake={server:"127.0.0.1",server_port:$handshake} else . end)
 | {inbounds:.,outbounds:[{type:"direct",tag:"direct"}],route:{rules:[]}}
' > "$out/base.json"
db='{"users":{"admin":{"enabled":true},"alice":{"enabled":true,"allow_all_nodes":true},"bob":{"enabled":false,"allow_all_nodes":true}}}'
V2RAY_API_LISTEN="127.0.0.1:$((base+9))"
user_manager_apply_to_json "$(cat "$out/base.json")" "$db" '{}' > "$out/allowed.json"
# Rebuilding must preserve every credential and rule, not merely pass core check.
user_manager_apply_to_json "$(cat "$out/allowed.json")" "$db" '{}' | jq -Sc . > "$out/again.json"
[ "$(jq -Sc . "$out/allowed.json")" = "$(cat "$out/again.json")" ]
user_manager_apply_to_json "$(cat "$out/allowed.json")" "$(echo "$db"|jq '.users.alice.enabled=false')" '{}' > "$out/disabled.json"
user_manager_apply_to_json "$(cat "$out/allowed.json")" "$(echo "$db"|jq '.users.alice.allow_all_nodes=false | .users.alice.nodes=[]')" '{}' > "$out/unassigned.json"
for config in allowed disabled unassigned; do sing-box check -c "$out/$config.json"; done
printf 'PASS production protocol builders, projection and credential idempotence\n'
