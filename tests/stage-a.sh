#!/usr/bin/env bash
# Isolated data and fault injection. No root, system service or remote host.
set -euo pipefail
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 50_v2ray_api 60_user_db 61_user_manager 62_user_menu 63_telegram_bot 80_installer; do
  source "lib/$module.sh"
done
fixture="$PWD/tests/fixtures/migration-7.0.0"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
USER_DB_FILE="$test_tmp/user-manager.json"
CONFIG_FILE="$test_tmp/config.json"
META_FILE="$test_tmp/meta.json"
SB_LOCK_FILE="$test_tmp/manager.lock"
TG_CONFIG_FILE="$test_tmp/telegram.json"
TG_TASK_RECEIPTS_FILE="$test_tmp/receipts.json"
SINGBOX_VERSION_STAMP="$test_tmp/installed"
init_manager_env() { :; }
pause() { :; }
tg_agent_sync() { :; }
singbox_service_active() { return 0; }
query_usage_snapshot() { jq -c '.usage_next' "$fixture/expected.json"; }

user_today_date() { echo 2026-11-28; }
user_db_initialize >/dev/null
user_db_exists
[ -f "$USER_DB_FILE.initialized" ]
cp "$fixture/config.json" "$CONFIG_FILE"
cp "$fixture/meta.json" "$META_FILE"
cp "$fixture/telegram.json" "$TG_CONFIG_FILE"
tg_task='{"action":"set_quota","username":"alice","params":{"quota_gb":12}}'

for invalid in '' '{broken' '{"enabled":true,"users":{}}' '{"enabled":true,"users":{"admin":[]}}'; do
  printf '%s' "$invalid" > "$USER_DB_FILE"
  if user_db_load 2>/dev/null || user_db_initialize 2>/dev/null; then exit 1; fi
  user_manager_menu </dev/null 2>/dev/null
  periodic_sync_run 2>/dev/null
  if tg_execute_task "$tg_task" 2>/dev/null; then exit 1; fi
  if user_db_save "$(user_db_min_template)" 2>/dev/null; then exit 1; fi
  [ "$(cat "$USER_DB_FILE")" = "$invalid" ]
done
mv "$USER_DB_FILE" "$test_tmp/invalid"
user_manager_menu </dev/null 2>/dev/null
periodic_sync_run 2>/dev/null
if tg_execute_task "$tg_task" 2>/dev/null; then exit 1; fi
[ ! -e "$USER_DB_FILE" ]
cmp "$CONFIG_FILE" "$fixture/config.json"
cmp "$META_FILE" "$fixture/meta.json"
echo 'PASS phase A: first install and invalid/missing DB through menu, cron and Bot'

cp "$fixture/user-manager.json" "$USER_DB_FILE"
db="$(user_db_load)"
meta="$(meta_load)"
original="$(config_load)"
config_apply_no_usage_sync() { atomic_write_json_file "$CONFIG_FILE" "$1"; }
reload_or_restart_singbox_safe() { touch "$test_tmp/service-reloaded"; }
user_manager_apply_changes "$db" "$original" "$meta" >/dev/null
first="$(config_load)"
cp "$CONFIG_FILE" "$test_tmp/pass-one-config"
cp "$USER_DB_FILE" "$test_tmp/pass-one-db"
cp "$META_FILE" "$test_tmp/pass-one-meta"
user_manager_apply_changes "$(user_db_load)" "$first" "$(meta_load)" >/dev/null
cmp "$CONFIG_FILE" "$test_tmp/pass-one-config"
cmp "$USER_DB_FILE" "$test_tmp/pass-one-db"
cmp "$META_FILE" "$test_tmp/pass-one-meta"
jq -ne --argjson first "$first" --argjson old "$original" '
  ($old.inbounds | map(.users |= map(select(.name != "ss-18080@paused"))) | map({tag, users}) | sort_by(.tag)) ==
    ($first.inbounds | map({tag, users}) | sort_by(.tag))
  and any($first.route.rules[]; .action == "reject" and .domain == ["blocked.example"])
' >/dev/null
[ "$(jq -Sc 'del(.meta.managed_inbounds,.meta.parked_inbounds) | .users |= with_entries(.value |= (del(.admin_allowed) | .nodes |= sort))' "$USER_DB_FILE")" = \
  "$(jq -Sc 'del(.meta.managed_inbounds,.meta.parked_inbounds) | .users |= with_entries(.value |= (del(.admin_allowed) | .nodes |= sort))' "$fixture/user-manager.json")" ]
cmp "$TG_CONFIG_FILE" "$fixture/telegram.json"
echo 'PASS phase A: two migration writes, original credentials and hand-written rule'

# Use original files to prove recovery preserves even their pre-migration bytes.
cp "$fixture/config.json" "$CONFIG_FILE"
cp "$fixture/user-manager.json" "$USER_DB_FILE"
cp "$fixture/meta.json" "$META_FILE"
new_db="$(jq '.users.alice.quota_gb=12' "$USER_DB_FILE")"
new_meta="$(jq '.fixture_change=true' "$META_FILE")"

# Fail after both the database and runtime config have been replaced.
(
  meta_save() { return 1; }
  if user_manager_apply_changes "$new_db" "$original" "$new_meta"; then exit 1; fi
) >/dev/null 2>&1
cmp "$USER_DB_FILE" "$fixture/user-manager.json"
cmp "$CONFIG_FILE" "$fixture/config.json"
cmp "$META_FILE" "$fixture/meta.json"
[ -f "$test_tmp/service-reloaded" ]
mv "$test_tmp/service-reloaded" "$test_tmp/service-reloaded-on-error"

(
  meta_save() { kill -KILL "$BASHPID"; }
  user_manager_apply_changes "$new_db" "$original" "$new_meta"
) >/dev/null 2>&1 &
interrupted_pid=$!
interrupted_rc=0
wait "$interrupted_pid" 2>/dev/null || interrupted_rc=$?
[ "$interrupted_rc" -eq 137 ]
[ -d "$USER_DB_FILE.pending" ]
jq -e '.users.alice.quota_gb == 12' "$USER_DB_FILE" >/dev/null
with_manager_lock true
cmp "$USER_DB_FILE" "$fixture/user-manager.json"
cmp "$CONFIG_FILE" "$fixture/config.json"
cmp "$META_FILE" "$fixture/meta.json"
cmp "$TG_CONFIG_FILE" "$fixture/telegram.json"
[ -f "$test_tmp/service-reloaded" ]
[ ! -e "$USER_DB_FILE.pending" ]
with_manager_lock true
echo 'PASS phase A: write failure and SIGKILL roll back DB, config and metadata'

# Optional output for the real core reconnect smoke test.
if [ -n "${1:-}" ]; then
  cp "$CONFIG_FILE" "$1"
fi
