#!/usr/bin/env bash
# Exercises the same locked account operations used by the menu, cron, and Bot.
set -euo pipefail
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 50_v2ray_api 60_user_db 61_user_manager 62_user_menu 63_telegram_bot; do
  source "lib/$module.sh"
done
fixture="$PWD/tests/fixtures/migration-7.0.0"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
USER_DB_FILE="$test_tmp/db.json"
CONFIG_FILE="$test_tmp/config.json"
META_FILE="$test_tmp/meta.json"
SB_LOCK_FILE="$test_tmp/lock"
TG_TASK_RECEIPTS_FILE="$test_tmp/receipts.json"
output="${1:-}"
if [ -n "$output" ]; then mkdir -p "$output"; fi
cp "$fixture/user-manager.json" "$USER_DB_FILE"
cp "$fixture/config.json" "$CONFIG_FILE"
cp "$fixture/meta.json" "$META_FILE"

init_manager_env() { :; }
singbox_service_active() { :; }
user_today_date() { echo "${test_date:-2026-11-28}"; }
config_apply_no_usage_sync() {
  atomic_write_json_file "$CONFIG_FILE" "$1" &&
    printf 'restart\n' >> "$test_tmp/restarts"
}
query_usage_snapshot() { cat "$test_tmp/sample" 2>/dev/null; }
write_case() { if [ -n "$output" ]; then cp "$CONFIG_FILE" "$output/$1.json"; fi; }
edit() {
  local before after
  before="$(user_db_load)"
  after="$(jq "$1" <<< "$before")"
  user_manager_commit_edit "$before" "$after" "${2:-edit}" "${3:-alice}" >/dev/null
}
task() {
  tg_execute_task "$(jq -nc --arg user "$1" --arg action "$2" --argjson params "$3" \
    '{username:$user, action:$action, params:$params}')" >/dev/null
}

jq '.route.rules |= ([{domain:["localhost"], auth_user:"ss-18080@alice", outbound:"direct"}] + .)' \
  "$fixture/config.json" > "$CONFIG_FILE"
jq -c '.usage_next' "$fixture/expected.json" > "$test_tmp/sample"
user_manager_reconcile_user_state >/dev/null
write_case allowed
task alice set_enabled '{"enabled":false}'
jq -e '.users.alice.admin_allowed == false and .users.alice.disabled_reason == "manual"' "$USER_DB_FILE" >/dev/null
jq -e '
  all(.inbounds[].users[]; ((.name // .username) | endswith("@alice") | not))
  and any(.route.rules[]; .domain? == ["localhost"] and .auth_user == "ss-18080@alice")
' "$CONFIG_FILE" >/dev/null
write_case disabled
task alice set_enabled '{"enabled":true}'
write_case manual_restored

# A failed final sample does not delay expiry, nor advance the last successful sample time.
mv "$test_tmp/sample" "$test_tmp/saved-sample"
old_time="$(jq -r '.meta.data_updated_at_text' "$USER_DB_FILE")"
edit '.users.alice.expire_at = "2026-11-29"'
test_date=2026-11-29 user_watch_run
jq -e --arg stamp "$old_time" '
  .users.alice.disabled_reason == "expired" and .users.alice.admin_allowed
  and .meta.data_updated_at_text == $stamp and (.meta.last_usage_gap_at_text != null)
' "$USER_DB_FILE" >/dev/null
write_case expired
# The configured expiry date still wins on the day it becomes due.
test_date=2026-11-29 task alice set_enabled '{"enabled":true}'
jq -e '.users.alice.enabled == false' "$USER_DB_FILE" >/dev/null
task alice set_expire '{"expire_at":"2026-12-28"}'
write_case expiry_restored
mv "$test_tmp/saved-sample" "$test_tmp/sample"

edit '.users.alice.quota_gb = 1 | .users.alice.manual_added_bytes = 1073741824'
jq -e '.users.alice.disabled_reason == "quota_exceeded"' "$USER_DB_FILE" >/dev/null
write_case quota
task alice reset_usage '{}'
jq -e '.users.alice.enabled and .users.alice.admin_allowed' "$USER_DB_FILE" >/dev/null
write_case quota_restored
edit '.users.alice.manual_added_bytes = 1073741824'
task alice set_quota '{"quota_gb":2}'
write_case quota_raised

# No available identities on the last SOCKS5 and SS2022 listeners.
task admin set_enabled '{"enabled":false}'
task alice set_enabled '{"enabled":false}'
task bob set_enabled '{"enabled":false}'
jq -e 'all(.inbounds[]; .tag != "socks-11080" and .tag != "ss-18080")' "$CONFIG_FILE" >/dev/null
jq -e '.meta.parked_inbounds | (index("socks-11080") != null) and (index("ss-18080") != null)' "$USER_DB_FILE" >/dev/null
write_case parked
user_watch_run
task bob set_enabled '{"enabled":true}'
jq -e '
  .users.bob.nodes == ["socks-11080","ss-18080"] and .users.bob.enabled
  and .meta.managed_inbounds["ss-18080"].users[0].password == "AAAAAAAAAAAAAAAAAAAAAA=="
' "$USER_DB_FILE" >/dev/null
write_case parked_restored
task alice set_enabled '{"enabled":true}'
task admin set_enabled '{"enabled":true}'

# A manual period reset leaves the persisted live baseline intact. A new core epoch
# counts once from zero, and an omitted direction does not forget its baseline.
task alice reset_usage '{}'
jq '.process="after-restart" | .start=200 | .stats=[
   {name:"user>>>ss-18080@alice>>>traffic>>>uplink",value:"40"},
   {name:"user>>>ss-18080@alice>>>traffic>>>downlink",value:"160"}]' \
  "$test_tmp/sample" > "$test_tmp/next"
mv "$test_tmp/next" "$test_tmp/sample"
user_manager_reconcile_user_state >/dev/null
user_manager_reconcile_user_state >/dev/null
cp "$test_tmp/sample" "$test_tmp/complete"
jq 'del(.stats[1])' "$test_tmp/complete" > "$test_tmp/sample"
user_manager_reconcile_user_state >/dev/null
cp "$test_tmp/complete" "$test_tmp/sample"
user_manager_reconcile_user_state >/dev/null
jq -e '.users.alice.used_up_bytes == 40 and .users.alice.used_down_bytes == 160' "$USER_DB_FILE" >/dev/null
restarts="$(wc -l < "$test_tmp/restarts")"
task alice set_quota '{"quota_gb":3}'
[ "$(wc -l < "$test_tmp/restarts")" = "$restarts" ]

# The same delivered Bot task must not add its adjustment twice.
tg_poll_tasks() {
  echo '[{"id":"adjust-once","action":"add_usage","username":"bob","params":{"bytes":9}}]'
}
tg_post_report() { :; }
tg_post_task_result() { :; }
before_adjustment="$(jq -r '.users.bob.manual_added_bytes' "$USER_DB_FILE")"
tg_process_tasks '{}' '' '' fixture
tg_process_tasks '{}' '' '' fixture
jq -e --argjson previous "$before_adjustment" '
  .users.bob.manual_added_bytes == ($previous + 9)
' "$USER_DB_FILE" >/dev/null

# Removing a configured node releases its grant and preserves its historical usage.
base="$(user_manager_config_for_edit)"
base="$(jq '.inbounds |= map(select(.tag != "ss-18080"))' <<< "$base")"
_USER_KEEP_LATEST_DB=1 user_manager_apply_changes '' "$base" >/dev/null
jq -e '
  .meta.managed_inbounds["ss-18080"] == null
  and all(.users[].nodes[]; . != "ss-18080")
  and .users.alice.used_up_bytes == 40 and .users.alice.used_down_bytes == 160
' "$USER_DB_FILE" >/dev/null
echo 'PASS phase B: availability, archive, failure handling, epoch and sampled accounting'
