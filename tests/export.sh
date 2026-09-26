#!/usr/bin/env bash
set -euo pipefail
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo 'SKIP export fixtures (Bash 4+ in Linux CI)'; exit 0; }
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 50_v2ray_api 70_export; do source "lib/$module.sh"; done
init_manager_env() { :; }; pause() { :; }; clear() { :; }
export_collect_context() { echo '{"ip":"127.0.0.1","ws_domain":"example.com","vm_domain":"example.com"}'; }
key=MDEyMzQ1Njc4OWFiY2RlZg==
config_load() {
  jq -nc --arg key "$key" '{inbounds:[{type:"shadowsocks",tag:"ss-443",listen_port:443,method:"2022-blake3-aes-128-gcm",password:$key,users:[{name:"ss-443",password:$key}]}],route:{rules:[]},outbounds:[]}'
}
result=$(export_configs)
link=$(printf '%s\n' "$result"|sed -n 's/.*通用链接: ss:\/\/\([^@]*\)@.*/\1/p')
[ "$(printf '%s' "$link"|openssl base64 -d -A)" = "2022-blake3-aes-128-gcm:$key:$key" ]
echo 'PASS SS2022 equal server/user keys export both password components'
