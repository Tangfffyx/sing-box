#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 50_v2ray_api 60_user_db 61_user_manager 70_export; do
  source "lib/$module.sh"
done
fixture=tests/fixtures/migration-7.0.0
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
CONFIG_FILE="$fixture/config.json"
META_FILE="$fixture/meta.json"
USER_DB_FILE="$test_dir/users.json"
cp "$fixture/user-manager.json" "$USER_DB_FILE"
init_manager_env() { :; }
user_today_date() { printf '%s\n' 2026-11-28; }
export_collect_context() { printf '%s\n' '{"ip":"2001:db8::1"}'; }

if [ "${1:-}" = terminal ]; then
  shift
  # Keep PTY tests deterministic on hosts with or without qrencode installed.
  export_qr() { return 1; }
  export_configs "$@"
  exit
fi

admin="$(export_collect_records __admin__ | jq -cs .)"
[ "$admin" = "$(export_collect_records admin | jq -cs .)" ]
alice="$(export_collect_records alice | jq -cs .)"
jq -e 'map(.name) == ["ss-18080@alice","trojan-18443@alice","trojan-18443-to-lab@alice"]' <<< "$alice" >/dev/null
[ "$(export_collect_records paused)" = '' ]
[ "$(export_collect_records missing)" = '' ]
all="$(export_collect_records __all__ | jq -cs .)"
jq -e 'any(.[]; .name=="socks-11080@bob") and all(.[]; (.name|endswith("@paused")|not))' <<< "$all" >/dev/null
jq '.users.bob.nodes=["socks-11080"] | .users.alice.expire_at="2025-01-01"' "$fixture/user-manager.json" > "$USER_DB_FILE"
[ "$(export_collect_records alice)" = '' ]
[ "$(export_collect_records bob | jq -r .name)" = 'socks-11080@bob' ]
jq '.users.bob.quota_gb=1 | .users.bob.used_up_bytes=1073741824' "$fixture/user-manager.json" > "$USER_DB_FILE"
[ "$(export_collect_records bob)" = '' ]
cp "$fixture/user-manager.json" "$USER_DB_FILE"

single="$(export_collect_records __admin__ '["socks-11080"]' | jq -cs .)"
batch="$(export_collect_records __admin__ '["socks-11080","ss-18080"]' | jq -cs .)"
jq -e 'map(.name) == ["socks-11080"]' <<< "$single" >/dev/null
jq -e 'map(.name) == ["ss-18080","socks-11080"]' <<< "$batch" >/dev/null
[ "$(export_print_format "$batch" 1)" = "$(jq -r '.[].link' <<< "$batch")" ]
[ "$(export_print_format "$batch" 2)" = "$(jq -r '.[].clash' <<< "$batch")" ]
[ "$(export_print_format "$batch" 3)" = "$(jq -r '.[].qx' <<< "$batch")" ]
if export_print_format "$batch" bogus; then exit 1; fi
preview="$(export_configs __admin__ '["socks-11080"]')"
[[ "$preview" == *"落地链接:"*" Clash: "*" Quantumult X: "* && "$preview" != *Surge* && "$preview" != *ss-18080* ]]
record="$(jq -c '.[0]' <<< "$single")"
uri="$(jq -r .link <<< "$record")"
has_cmd() { return 0; }
export_qr() { printf '\033[40m████\033[0m\n\033[40m████\033[0m\n'; }
wide="$(export_detail_card "$record" 100 40)"
[[ "$wide" == *$'\033[7G1. 落地链接'* ]]
narrow="$(export_detail_card "$record" 21 40)"
[[ "$narrow" == *$'████\033[0m\n1. 落地链接'* && "$narrow" != *$'\033[7G'* ]]
small="$(export_detail_card "$record" 3 40)"
[[ "$small" == *"$uri"* && "$small" != *████* ]]
export_qr() { return 1; }
failed="$(export_detail_card "$record" 100 40)"
[[ "$failed" == *"$uri"* ]]
printf '%s\n' 'PASS stage F authorization, admin alias, single and batch scope, format order, layouts and QR fallback'
python3 tests/stage-f-terminal.py
