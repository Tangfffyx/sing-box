#!/usr/bin/env bash
# Exercises the original exporter and accounting against isolated sample data.
set -euo pipefail

fixture="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseline="${1:?usage: bash verify-original.sh /path/to/7.0.0 [directory-for-exports]}"
output="${2:-}"
if [ -n "$output" ]; then
  mkdir -p "$output"
  output="$(cd "$output" && pwd)"
fi
cd "$baseline"

[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo 'Bash 4+ required' >&2; exit 1; }
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 50_v2ray_api 60_user_db 70_export; do
  source "lib/$module.sh"
done
[ "$SCRIPT_VERSION" = 7.0.0 ] || { echo 'Expected original script 7.0.0' >&2; exit 1; }

# Supply local state and a fixed export context. Never initialize /etc or probe the network.
init_manager_env() { :; }
pause() { :; }
clear() { :; }
config_load() { cat "$fixture/config.json"; }
meta_load() { cat "$fixture/meta.json"; }
export_collect_context() {
  printf '%s\n' '{"ip":"127.0.0.1","ws_domain":"example.com","vm_domain":"example.com"}'
}
USER_DB_FILE="$fixture/user-manager.json"
B= G= R= Y= C= NC= W= D=

db="$(user_db_load)"
expected="$(cat "$fixture/expected.json")"
jq -ne --argjson db "$db" --argjson expected "$expected" '
  ($db.users | with_entries(.value |= (.used_up_bytes + .used_down_bytes + .manual_added_bytes))) == $expected.billable_bytes
  and ($db.users | del(.admin) | with_entries(.value |= .nodes)) == $expected.allowed
  and [$db.users | to_entries[] | select(.value.enabled == false) | .key] == $expected.disabled
' >/dev/null
user_db_user_allow_node "$db" alice trojan-18443-to-lab
user_db_user_allow_node "$db" bob socks-11080
! user_db_user_allow_node "$db" bob trojan-18443-to-lab
! user_db_user_is_enabled "$db" paused

sample="$(jq -c '.usage_next' <<< "$expected")"
once="$(account_usage_snapshot "$db" "$sample")"
twice="$(account_usage_snapshot "$once" "$sample")"
[ "$(jq -Sc . <<< "$once")" = "$(jq -Sc . <<< "$twice")" ]
jq -ne --argjson db "$twice" --argjson expected "$expected" '
  ($db.users | {alice, bob} | with_entries(.value |= (.used_up_bytes + .used_down_bytes + .manual_added_bytes))) == $expected.after_usage_next
' >/dev/null

for account in __admin__ alice bob; do
  exported="$(export_configs "$account")"
  printf '%s\n' "$exported" | grep -q '通用链接: ss://'
  case "$account" in
    alice)
      [[ "$exported" == *'trojan-18443-to-lab@alice'* && "$exported" != *'@bob'* ]]
      ;;
    bob)
      [[ "$exported" == *'socks-11080@bob'* && "$exported" != *'@alice'* ]]
      ;;
  esac
  if [ -n "$output" ]; then
    printf '%s\n' "$exported" > "$output/$account.txt"
  else
    printf '%s\n' "$exported" | diff - "$fixture/old-exports/$account.txt"
  fi
done
printf '%s\n' 'PASS original 7.0.0 exports, stored permissions, balances and repeated statistics sample'
