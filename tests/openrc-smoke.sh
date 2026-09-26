#!/usr/bin/env bash
# Only run in the disposable Alpine container below, never on an existing host.
set -euo pipefail
[[ "${1:-}" == --disposable-container ]] && [[ -f /.dockerenv ]] || exit 2
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 50_v2ray_api 60_user_db 80_installer; do source "lib/$module.sh"; done
T=$(mktemp -d)
trap 'rc-service sing-box stop >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
CONFIG_FILE="$T/config.json"; USER_DB_FILE="$T/users.json"; SB_LOCK_FILE="$T/lock"
SINGBOX_BIN="$T/sing-box"; SINGBOX_INSTALL_DIR="$T"; SINGBOX_VERSION_STAMP="$T/version"
cp /fixture-core "$SINGBOX_BIN"
export PATH="$T:$PATH"
config_normalize "$(config_min_template)" > "$CONFIG_FILE"
mkdir -p /run/openrc
: > /run/openrc/softlevel
# Container networking is already configured by Docker.
cat > /etc/init.d/net <<'NET'
#!/sbin/openrc-run
start() { return 0; }
NET
chmod +x /etc/init.d/net
prepare_script_runtime
rc-service net start
rc-service sing-box start
wait_singbox_ready '' || { rc-service sing-box status || true; cat /run/sing-box.pid 2>/dev/null || true; timeout 3 "$SINGBOX_BIN" run -c "$CONFIG_FILE" || true; exit 1; }
old=$(singbox_process_token)
config_apply "$(jq '.log.level="warn"' "$CONFIG_FILE")"
[ "$(singbox_process_token)" != "$old" ]
echo 'PASS real OpenRC start, config restart and PID verification'
printf v1.14.2 > "$SINGBOX_VERSION_STAMP"
cat > "$T/bad" <<'BAD'
#!/bin/sh
for arg in "$@"; do [ "$arg" != run ] || exit 1; done
exec /fixture-core "$@"
BAD
chmod +x "$T/bad"
if with_manager_lock install_candidate_singbox "$T/bad" fail-fixture > "$T/failure.log" 2>&1; then exit 1; fi
rc-service sing-box status
[ "$(cat "$SINGBOX_VERSION_STAMP")" = v1.14.2 ]
echo 'PASS real OpenRC failed candidate restores service and version'
