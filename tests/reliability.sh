#!/usr/bin/env bash
# Safe fixtures: no real service, network, /etc writes or root requirement.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  source lib/00_base.sh
else
  # macOS ships bash 3; pure-function fixtures do not need associative arrays.
  sed -n '/^JQ_DETECT_PROTOCOL=/,/^JQ_SHARED=/p' lib/00_base.sh > "$TEST_TMP/jq-defs.sh"
  source "$TEST_TMP/jq-defs.sh"
fi
source lib/01_utils.sh
source lib/10_config.sh
source lib/30_route.sh
source lib/50_v2ray_api.sh
source lib/60_user_db.sh
source lib/61_user_manager.sh
source lib/80_installer.sh
err() { printf '%s\n' "$*" >&2; }
warn() { printf '%s\n' "$*" >&2; }
ok() { :; }
assert_json() { printf '%s' "$1" | jq -e "$2" >/dev/null || { echo "FAIL: $2" >&2; return 1; }; }
run() { ( "$@" ); printf 'PASS %s\n' "$1"; }

test_routes() {
  meta_load() { echo '{}'; }
  relay_list_table() { :; }
  local config result again
  config='{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[{"domain_suffix":["a.example"],"outbound":"direct"},{"domain_suffix":["b.example"],"outbound":"direct"},{"ip_cidr":["192.0.2.0/24"],"action":"reject"},{"port":25,"action":"reject"}]}}'
  result="$(route_rebuild "$config" '{}')"
  assert_json "$result" '.route.rules|length == 4'
  assert_json "$result" '.route.rules[1].domain_suffix == ["b.example"]'
  again="$(route_rebuild "$result" '{}')"
  [ "$(echo "$again"|jq -Sc .)" = "$(echo "$result"|jq -Sc .)" ]
}

test_accounting() {
  local db snap
  db='{"users":{"alice":{"used_up_bytes":100,"last_live_up_bytes":100}}}'
  snap='{"process":"p1","start":10,"stats":[{"name":"user>>>node@alice>>>traffic>>>uplink","value":"120"}]}'
  db="$(account_usage_snapshot "$db" "$snap")"
  assert_json "$db" '.users.alice.used_up_bytes == 120'
  snap='{"process":"p2","start":20,"stats":[{"name":"user>>>node@alice>>>traffic>>>uplink","value":"150"}]}'
  db="$(account_usage_snapshot "$db" "$snap")"
  assert_json "$db" '.users.alice.used_up_bytes == 270'
  db="$(account_usage_snapshot "$db" "$snap")"
  assert_json "$db" '.users.alice.used_up_bytes == 270'
  snap="$(echo "$snap"|jq '.start=30')"
  db="$(account_usage_snapshot "$db" "$snap")"
  assert_json "$db" '.users.alice.used_up_bytes == 420'
  snap="$(echo "$snap"|jq '.stats=[]')"
  db="$(account_usage_snapshot "$db" "$snap")"
  assert_json "$db" '.users.alice.used_up_bytes == 420'
  snap='{"process":"p2","start":30,"stats":[{"name":"user>>>node@alice>>>traffic>>>uplink","value":"170"}]}'
  db="$(account_usage_snapshot "$db" "$snap")"
  assert_json "$db" '.users.alice.used_up_bytes == 440'
  # Removing a node must not subtract the aggregate baseline from surviving nodes.
  db='{"meta":{"usage":{"process":"p1","start":10,"counters":{"a@alice":{"uplink":100},"b@alice":{"uplink":100}}}},"users":{"alice":{"used_up_bytes":200}}}'
  snap='{"process":"p1","start":10,"stats":[{"name":"user>>>b@alice>>>traffic>>>uplink","value":"150"}]}'
  db="$(account_usage_snapshot "$db" "$snap")"
  assert_json "$db" '.users.alice.used_up_bytes == 250'
}

test_user_edits() {
  local before after current result
  before='{"users":{"alice":{"enabled":true,"quota_gb":10,"expire_at":"0","used_up_bytes":0,"manual_added_bytes":0}}}'
  after="$(echo "$before"|jq '.users.alice.quota_gb=20')"
  current="$(echo "$before"|jq '.users.alice.used_up_bytes=123 | .users.alice.expire_at="2027-01-01" | .meta.usage.process="new"')"
  result="$(merge_user_edit "$current" "$before" "$after")"
  assert_json "$result" '.users.alice.quota_gb == 20 and .users.alice.used_up_bytes == 123 and .users.alice.expire_at == "2027-01-01" and .meta.usage.process == "new"'
  current="$(echo "$current"|jq '.users.alice.quota_gb=30')"
  if merge_user_edit "$current" "$before" "$after" >/dev/null 2>&1; then return 1; fi
  result="$(merge_user_edit "$current" "$before" "$before" reset alice)"
  assert_json "$result" '.users.alice.used_up_bytes == 0 and .users.alice.quota_gb == 30'
  after="$(echo "$before"|jq '.users.alice.manual_added_bytes=50')"
  current="$(echo "$current"|jq '.users.alice.manual_added_bytes=70')"
  result="$(merge_user_edit "$current" "$before" "$after" add alice)"
  assert_json "$result" '.users.alice.manual_added_bytes == 120'
  current="$(echo "$current"|jq 'del(.users.alice)')"
  if merge_user_edit "$current" "$before" "$after" >/dev/null 2>&1; then return 1; fi
}

test_billing_periods() {
  init_manager_env() { :; }; user_db_exists() { return 0; }; sync_user_usage_counters() { :; }
  config_load() { echo '{}'; }
  user_today_date() { echo "$fixture_today"; }
  user_db_load() { cat "$TEST_TMP/db.json"; }
  user_manager_apply_changes() { echo "$1" > "$TEST_TMP/db.json"; }
  local fixture_today result
  fixture_today=2026-09-16
  echo '{"users":{"alice":{"enabled":false,"disabled_reason":"quota_exceeded","quota_gb":10,"used_up_bytes":100,"reset_day":15,"last_reset_period":"2026-08","expire_at":"0"}}}' > "$TEST_TMP/db.json"
  _user_manager_reconcile_user_state_body
  assert_json "$(user_db_load)" '.users.alice.used_up_bytes == 0 and .users.alice.enabled and .users.alice.last_reset_period == "2026-09"'
  result="$(user_db_load|jq '.users.alice.used_up_bytes=50')"; echo "$result" > "$TEST_TMP/db.json"
  _user_manager_reconcile_user_state_body
  assert_json "$(user_db_load)" '.users.alice.used_up_bytes == 50'
  fixture_today=2027-01-02
  _user_manager_reconcile_user_state_body
  assert_json "$(user_db_load)" '.users.alice.last_reset_period == "2026-12"'
  # New users establish a period instead of losing already accrued usage.
  result="$(user_db_load|jq '.users.alice.last_reset_period="" | .users.alice.used_up_bytes=75')"; echo "$result" > "$TEST_TMP/db.json"
  _user_manager_reconcile_user_state_body
  assert_json "$(user_db_load)" '.users.alice.used_up_bytes == 75'
  fixture_today=2028-03-01
  result="$(user_db_load|jq '.users.alice.reset_day=32 | .users.alice.last_reset_period="2028-01" | .users.alice.disabled_reason="manual" | .users.alice.enabled=false')"; echo "$result" > "$TEST_TMP/db.json"
  _user_manager_reconcile_user_state_body
  assert_json "$(user_db_load)" '.users.alice.last_reset_period == "2028-02" and .users.alice.used_up_bytes == 0 and (.users.alice.enabled|not)'
}

test_lock_failure() {
  has_cmd() { return 1; }
  _CONFIG_LOCK_HELD=0
  if with_manager_lock touch "$TEST_TMP/unsafe" 2>/dev/null; then return 1; fi
  [ ! -e "$TEST_TMP/unsafe" ]
}

test_ready_and_restart() {
  INIT_SYSTEM=systemd
  CONFIG_FILE="$TEST_TMP/health.json"
  echo '{"experimental":{"v2ray_api":{"stats":{"enabled":true}}}}' > "$CONFIG_FILE"
  echo old > "$TEST_TMP/process"
  singbox_process_token() { cat "$TEST_TMP/process"; }
  singbox_service_active() { return 0; }
  query_v2ray_api_uptime() { echo 10; }
  check_config_or_print() { :; }
  sleep() { :; }
  systemctl() { [ "$1" = restart ] || return 1; echo new > "$TEST_TMP/process"; }
  reload_or_restart_singbox_safe
  query_v2ray_api_uptime() { return 1; }
  if wait_singbox_ready old 2>/dev/null; then return 1; fi
}

test_install_transaction() {
  local dir="$TEST_TMP/install"
  mkdir -p "$dir"
  SINGBOX_INSTALL_DIR="$dir"
  SINGBOX_BIN="$dir/sing-box"
  SINGBOX_VERSION_STAMP="$dir/stamp"
  CONFIG_FILE="$dir/config.json"
  INIT_SYSTEM=systemd
  printf '#!/bin/sh\n# OLD\nexit 0\n' > "$SINGBOX_BIN"; chmod +x "$SINGBOX_BIN"
  printf '#!/bin/sh\n# NEW\nexit 0\n' > "$dir/candidate"; chmod +x "$dir/candidate"
  echo '{"old":true}' > "$CONFIG_FILE"
  echo v1.13.0 > "$SINGBOX_VERSION_STAMP"
  sync_user_usage_counters() { :; }
  prepare_script_runtime() { :; }
  systemctl() { :; }
  reload_or_restart_singbox_safe() { ! grep -q NEW "$SINGBOX_BIN"; }
  if install_candidate_singbox "$dir/candidate" v1.14.2 2>/dev/null; then return 1; fi
  grep -q OLD "$SINGBOX_BIN"
  [ "$(cat "$SINGBOX_VERSION_STAMP")" = v1.13.0 ]
  assert_json "$(cat "$CONFIG_FILE")" '.old == true'
  reload_or_restart_singbox_safe() { return 0; }
  install_candidate_singbox "$dir/candidate" v1.14.2
  grep -q NEW "$SINGBOX_BIN"
  grep -q OLD "${SINGBOX_BIN}.bak"
  [ "$(cat "$SINGBOX_VERSION_STAMP")" = v1.14.2 ]
  printf '#!/bin/sh\nexit 1\n' > "$dir/bad"; chmod +x "$dir/bad"
  if install_candidate_singbox "$dir/bad" v2 2>/dev/null; then return 1; fi
  grep -q NEW "$SINGBOX_BIN"
  [ "$(cat "$SINGBOX_VERSION_STAMP")" = v1.14.2 ]
}

test_linux_lock_and_process() {
  if [ "${BASH_VERSINFO[0]}" -lt 4 ] || ! command -v flock >/dev/null; then
    echo 'SKIP real flock/process fixtures (Linux CI runs these)'
    return 0
  fi
  SB_LOCK_FILE="$TEST_TMP/manager.lock"
  _CONFIG_LOCK_HELD=0
  echo 0 > "$TEST_TMP/count"
  increment() {
    local n
    n="$(cat "$TEST_TMP/count")"
    sleep 0.01
    echo "$((n + 1))" > "$TEST_TMP/count"
  }
  local i pids=() pid
  for ((i=0;i<12;i++)); do
    with_manager_lock increment &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  [ "$(cat "$TEST_TMP/count")" = 12 ]
  INIT_SYSTEM=systemd
  systemctl() { echo "$$"; }
  local token
  token="$(singbox_process_token)"
  [[ "$token" == *":$$:"* ]]
  nested() { with_manager_lock increment; }
  with_manager_lock nested
  [ "$(cat "$TEST_TMP/count")" = 13 ]
}

test_openrc_restart() {
  INIT_SYSTEM=openrc
  CONFIG_FILE="$TEST_TMP/openrc-health.json"
  echo '{}' > "$CONFIG_FILE"
  echo old > "$TEST_TMP/openrc-process"
  singbox_process_token() { cat "$TEST_TMP/openrc-process"; }
  singbox_service_active() { return 0; }
  check_config_or_print() { :; }
  sleep() { :; }
  rc-service() { [ "$1" = sing-box ] && [ "$2" = restart ] || return 1; echo new > "$TEST_TMP/openrc-process"; }
  reload_or_restart_singbox_safe
}

run test_routes
run test_accounting
run test_user_edits
run test_billing_periods
run test_lock_failure
run test_ready_and_restart
run test_install_transaction
run test_linux_lock_and_process
run test_openrc_restart
