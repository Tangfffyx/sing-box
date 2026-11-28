#!/usr/bin/env bash
# Offline verification of staging, rollback, routing ownership and exported fields.
set -euo pipefail
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 50_v2ray_api 60_user_db 61_user_manager 70_export 75_ws_cdn 90_protocol_menu; do
  source "lib/$module.sh"
done
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
USER_DB_FILE="$test_dir/db.json"
CONFIG_FILE="$test_dir/config.json"
META_FILE="$test_dir/meta.json"
SB_LOCK_FILE="$test_dir/manager.lock"
WS_CDN_NGINX_DIR="$test_dir/snippets"
user_db_min_template > "$USER_DB_FILE"
printf '{}\n' > "$META_FILE"
jq '
  (.inbounds[] | select(.tag == "vmess-ws-18001")) as $vmess
  | {inbounds:[$vmess,($vmess | .type="vless" | .tag="vless-ws-18002" | .listen_port=18002
      | .users=[{name:"vless-ws-18002",uuid:"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"}]
      | .transport.path="/vless")], outbounds:[{type:"direct",tag:"direct"}], route:{rules:[]}}
' tests/fixtures/migration-7.0.0/config.json > "$CONFIG_FILE"
cp "$CONFIG_FILE" "$test_dir/config.before"
init_manager_env() { :; }
clear() { :; }
pause() { :; }
singbox_service_active() { return 1; }
ws_cdn_nginx() {
  case "$*" in
    -T) for file in "$WS_CDN_NGINX_DIR"/*.conf; do printf '# configuration file %s:\n' "$file"; done ;;
    '-t -q'|'-s reload') : ;;
    *) return 1 ;;
  esac
}
ws_cdn_http_upgrade() {
  if [ "$1" = 源站 ]; then printf '127.0.0.1\n'
  elif [ "$2" = carrier.example.net ]; then printf '9.9.9.9\n'
  else printf '8.8.8.8\n'; fi
}
ws_cdn_proxy_probe() {
  if [ "$4" = /vless ] && [ -f "$test_dir/fail-vless" ]; then return 1; fi
  [ "$4" != /vless ] || [ "$5" -eq 0 ]
}
entry() {
  jq -nc --arg host "$1" --arg mode "$2" '{host:$host,port:443,mode:$mode,
    origin:{address:"127.0.0.1",port:8443,sni:"origin.example.net",ca:""}}'
}

profile="$(entry cdn.example.net nginx)"
ws_cdn_attach vmess-ws-18001 "$profile"
snippet="$(ws_cdn_snippet_path cdn.example.net)"
cp "$snippet" "$test_dir/vmess.before"
cp "$META_FILE" "$test_dir/meta.before"
grep -Fq 'location = /old-ws' "$snippet"
grep -Fq 'proxy_pass http://127.0.0.1:18001;' "$snippet"
touch "$test_dir/fail-vless"
if ws_cdn_attach vless-ws-18002 "$profile"; then exit 1; fi
cmp "$snippet" "$test_dir/vmess.before"
cmp "$META_FILE" "$test_dir/meta.before"
cmp "$CONFIG_FILE" "$test_dir/config.before"
[ ! -d "$USER_DB_FILE.pending" ]
mv "$test_dir/fail-vless" "$test_dir/failure-observed"

(
  writer="$BASHPID"
  ws_cdn_proxy_probe() { kill -KILL "$writer"; return 1; }
  ws_cdn_attach vless-ws-18002 "$profile"
) >/dev/null 2>&1 &
interrupted_pid=$!
interrupted_rc=0
wait "$interrupted_pid" 2>/dev/null || interrupted_rc=$?
[ "$interrupted_rc" -eq 137 ]
[ -d "$USER_DB_FILE.pending" ]
with_manager_lock true
cmp "$snippet" "$test_dir/vmess.before"
cmp "$META_FILE" "$test_dir/meta.before"

ws_cdn_attach vless-ws-18002 "$profile"
grep -Fq 'location = /vless' "$snippet"
jq -e '."vmess-ws-18001".cdn_entries[0].early_data == 2048 and
       ."vless-ws-18002".cdn_entries[0].early_data == 0' "$META_FILE" >/dev/null
cmp "$CONFIG_FILE" "$test_dir/config.before"
export_configs __admin__ > "$test_dir/export"
grep -q 'VMess-WS · CDN 自动' "$test_dir/export"
grep -q 'VLESS-WS · CDN 自动' "$test_dir/export"
grep -Fq 'server: "cdn.example.net", port: 443' "$test_dir/export"
grep -Fq 'vless=cdn.example.net:443' "$test_dir/export"
grep -Fq 'vmess=cdn.example.net:443' "$test_dir/export"
[ "$(grep -c 'max-early-data' "$test_dir/export")" -eq 1 ]
! grep -Eq ':(18001|18002)|127\.0\.0\.1|obfs-uri=[^ ]+\?ed=' "$test_dir/export"
python3 - "$test_dir/export" <<'PY'
import base64, json, sys
from urllib.parse import parse_qs, urlsplit

with open(sys.argv[1]) as results:
    vmess_url, vless_url = [line.split("通用链接:",1)[1].strip()
                            for line in results if "通用链接:" in line]
vmess = json.loads(base64.b64decode(vmess_url.split("://",1)[1]))
assert (vmess["add"], vmess["port"], vmess["host"], vmess["sni"], vmess["path"]) == (
    "cdn.example.net", "443", "cdn.example.net", "cdn.example.net", "/old-ws")
assert vmess["id"] == "7b0b20ca-2195-4fda-9960-178e2ab75212"
vless = urlsplit(vless_url)
assert (vless.hostname, vless.port, vless.username) == (
    "cdn.example.net", 443, "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa")
assert parse_qs(vless.query)["path"] == ["/vless"]
assert parse_qs(vless.query)["host"] == ["cdn.example.net"]
assert parse_qs(vless.query)["sni"] == ["cdn.example.net"]
PY

# An old saved mapping survives accepting a separate verified CDN hostname.
jq '."vmess-ws-18001".public_endpoint = {host:"old.example.net", port:8443}' "$META_FILE" > "$test_dir/legacy"
mv "$test_dir/legacy" "$META_FILE"
profile="$(entry carrier.example.net existing)"
printf '%s\n' '{"operator":"电信","provider":"Fixture CDN","source":"https://provider.example.net/record",
  "host":"carrier.example.net","port":443,"edge_ips":["203.0.113.3"]}' > "$test_dir/evidence"
ws_cdn_attach vmess-ws-18001 "$profile" "$test_dir/evidence"
jq -e '."vmess-ws-18001".cdn_entries[1].operator_evidence == null' "$META_FILE" >/dev/null
jq '.edge_ips=["9.9.9.9"]' "$test_dir/evidence" > "$test_dir/matched"
ws_cdn_attach vmess-ws-18001 "$profile" "$test_dir/matched"
ws_cdn_attach vmess-ws-18001 "$profile"
export_configs __admin__ > "$test_dir/export"
grep -Fq '电信入口' "$test_dir/export"
grep -Fq 'vmess=old.example.net:8443' "$test_dir/export"
grep -Fq 'vmess=cdn.example.net:443' "$test_dir/export"
[ "$(grep -c '通用链接:' "$test_dir/export")" -eq 4 ]

# A second node with an existing path is rejected before touching Nginx.
jq '(.inbounds[] | select(.type=="vless")).transport.path="/old-ws"' "$CONFIG_FILE" > "$test_dir/duplicate"
mv "$test_dir/duplicate" "$CONFIG_FILE"
if ws_cdn_attach vless-ws-18002 "$(entry cdn.example.net nginx)"; then exit 1; fi
cp "$test_dir/config.before" "$CONFIG_FILE"
ws_cdn_detach vless-ws-18002 cdn.example.net 443
grep -Fq 'location = /old-ws' "$snippet"
! grep -Fq 'location = /vless' "$snippet"
cmp "$CONFIG_FILE" "$test_dir/config.before"
ws_cdn_detach vmess-ws-18001 cdn.example.net 443
export_configs __admin__ > "$test_dir/export"
grep -Fq 'VMess-WS · CDN 自动' "$test_dir/export"
! grep -Fq '电信入口' "$test_dir/export"
echo 'PASS stage D CDN store, Nginx rollback, path ownership, evidence and endpoint export'
