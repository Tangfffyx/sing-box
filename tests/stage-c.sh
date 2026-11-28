#!/usr/bin/env bash
# Isolated interactive defaults, public address editing, and clock branches.
set -euo pipefail
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 50_v2ray_api 60_user_db 61_user_manager 70_export 75_ws_cdn 80_installer 90_protocol_menu; do
  source "lib/$module.sh"
done
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
USER_DB_FILE="$temp/db"
SB_LOCK_FILE="$temp/manager.lock"
user_db_min_template > "$USER_DB_FILE"
export_config="$temp/config"
export_meta="$temp/meta"
printf '%s\n' '{"inbounds":[],"route":{"rules":[]},"outbounds":[]}' > "$export_config"
printf '{}\n' > "$export_meta"
user_db_exists() { :; }
meta_load() { cat "$export_meta"; }
meta_save() { printf '%s\n' "$1" > "$export_meta"; }
config_load() { cat "$export_config"; }
user_manager_apply_changes() {
  printf '%s\n' "$2" > "$export_config"
  meta_save "$3"
}
hy2_hop_apply() { printf '%s\n' "$*" >> "$temp/hops"; }
hy2_hop_rule_verified() { :; }
hy2_hop_restore_sync() { touch "$temp/hop-restore"; }
tls_cert_for_prefix() {
  _TLS_CRT="/etc/sing-box/$1-$2.crt"
  _TLS_KEY="/etc/sing-box/$1-$2.key"
}
protocol_install_time_guard() { printf 'checked\n' >> "$temp/clock"; }
reality_handshake_check() { [ "$1" = "$REALITY_DEFAULT_HANDSHAKE" ]; }
generate_reality_keypair_auto() { printf 'private\tpublic-test\n'; }
sing-box() {
  [ "$*" = 'generate uuid' ] && printf '00000000-0000-4000-8000-000000000001\n'
}
init_manager_env() { :; }
pause() { :; }
clear() { :; }
get_public_ip() { printf '192.0.2.1\n'; }
export_configs() { printf '%s\n' "$2" > "$temp/export-scope"; }

protocol_install_menu "$(config_load)" <<< $'1\n' >/dev/null
jq -e '.inbounds[0] | .tag == "hy2-443" and .obfs.type == "gecko"
  and .ignore_client_bandwidth and (.tls | has("alpn") | not)
  and (.users[0].password | test("^[A-Za-z0-9_-]{22}$"))
  and .obfs.password != .users[0].password' "$export_config" >/dev/null
jq -e '."hy2-443".hop_start == 42310 and ."hy2-443".hop_end == 45545' "$export_meta" >/dev/null
grep -qx '42310 45545 443' "$temp/hops"
[ -e "$temp/hop-restore" ]
[ ! -e "$temp/clock" ]

protocol_install_menu "$(config_load)" <<< $'2+3+5+6+7+8\n\n\n\n\n\n\n' >/dev/null
jq -e '
  .inbounds | map(.tag) ==
  ["hy2-443","reality-443","anytls-8443","socks-1080","tuic-8443","trojan-8444","vless-ws-8002"]
' "$export_config" >/dev/null
jq -e --arg sni "$SELF_SIGNED_SNI" '
  .inbounds | any(.tag == "anytls-8443" and .tls.server_name == $sni and (has("padding_scheme") | not))
  and any(.tag == "tuic-8443" and .congestion_control == "bbr" and .zero_rtt_handshake == false)
  and any(.tag == "trojan-8444" and (.tls | (has("alpn") or has("kernel_tx")) | not))
' "$export_config" >/dev/null
[ ! -e "$temp/clock" ]

protocol_install_menu "$(config_load)" <<< $'4+8\nm\n\n' >/dev/null
[ "$(wc -l < "$temp/clock" | tr -d ' ')" = 1 ]
jq -e 'length == 2 and index("ss-8080") != null and index("vmess-ws-8001") != null' "$temp/export-scope" >/dev/null
jq -e '.inbounds | any(.tag == "vmess-ws-8001" and (.users[0] | has("alterId") | not))' "$export_config" >/dev/null
jq -er '.inbounds[] | select(.tag == "ss-8080") | [.password, .users[0].password][]' "$export_config" |
  while IFS= read -r key; do ss2022_password_part_valid "$key" || exit 1; done
cp "$export_config" "$temp/before"
protocol_edit_menu "$(config_load)" <<< $'2\n2001:db8::10\n8443' >/dev/null
cmp "$export_config" "$temp/before"
jq -e '."reality-443".public_endpoint == {host:"2001:db8::10",port:8443}' "$export_meta" >/dev/null
[ "$(wc -l < "$temp/clock" | tr -d ' ')" = 1 ]

# If correction fails, skip only the protocols which need the clock.
protocol_install_time_guard() { return 1; }
protocol_install_menu "$(config_load)" <<< $'4+5+8\nm\n\n\n' >/dev/null
jq -e 'map(startswith("socks-")) == [true]' "$temp/export-scope" >/dev/null
jq -e '[.inbounds[]| select(.type == "shadowsocks" or .type == "vmess")] | length == 2' "$export_config" >/dev/null
(
  hy2_hop_rule_verified() { return 1; }
  hy2_hop_remove() { :; }
  protocol_install_menu "$(config_load)" <<< $'1\n' >/dev/null
  jq -e '.inbounds | any(.tag == "hy2-8444")' "$export_config" >/dev/null
  jq -e '."hy2-8444".hop_start == null and ."hy2-443".hop_start == 42310' "$export_meta" >/dev/null
)
echo 'PASS stage C defaults, TCP/UDP reservations, edit preservation, and one clock check per batch'

# Exercise read, probe, existing-service repair, and fresh-service selection without changing the host clock.
source lib/80_installer.sh
run_with_timeout() { shift; "$@"; }
(
  INIT_SYSTEM=systemd
  timedatectl() { echo yes; }
  install_clock_probe() { exit 7; }
  install_pkg() { exit 8; }
  protocol_install_time_guard
)
(
  install_clock_reports_synchronized() { return 1; }
  install_clock_probe() { return 0; }
  install_clock_correct() { exit 7; }
  protocol_install_time_guard
)
(
  date() {
    if [ "$*" = '+%s' ]; then printf '%s\n' 1000; else /bin/date "$@"; fi
  }
  install_clock_epoch_utc() { printf '%s\n' "$remote_epoch"; }
  sing-box() {
    [ "$1 $2" = 'tools synctime' ] && [[ " $* " != *' --write '* ]] &&
      printf '%s\n' '2026-11-28 11:00:00'
  }
  remote_epoch=1003
  install_clock_probe
  remote_epoch=1020
  confirmed=0
  install_clock_probe || confirmed=$?
  [ "$confirmed" = 1 ]
)
(
  install_clock_reports_synchronized() { return 1; }
  install_clock_probe() { return 1; }
  install_clock_can_adjust() { return 0; }
  install_clock_service() { echo chronyd; }
  install_clock_correct() { [ "$1" = chronyd ]; }
  protocol_install_time_guard
)
(
  install_clock_reports_synchronized() { return 1; }
  install_clock_probe() { return 1; }
  install_clock_can_adjust() { return 1; }
  install_clock_correct() { exit 7; }
  if protocol_install_time_guard; then exit 1; fi
)
(
  install_clock_reports_synchronized() { return 1; }
  install_clock_probe() { return 2; }
  install_clock_service() { return 1; }
  install_clock_correct() { exit 7; }
  protocol_install_time_guard <<< c
)
(
  INIT_SYSTEM=openrc
  has_cmd() { return 1; }
  chrony_service_name() { if [ -e "$temp/openrc" ]; then echo chronyd; fi; }
  install_pkg() {
    printf '%s\n' "$1" >> "$temp/pkgs"
    if [ "$1" = chrony-openrc ]; then touch "$temp/openrc"; fi
  }
  chrony_service_start() { [ "$1" = chronyd ]; }
  chrony_service_enable() { [ "$1" = chronyd ]; }
  install_clock_wait() { :; }
  install_clock_probe() { :; }
  install_clock_correct ''
)
[ "$(cat "$temp/pkgs")" = $'chrony\nchrony-openrc' ]
echo 'PASS stage C synchronized, read-only, existing service, container, timeout, and Alpine package paths'

# Check all generated URLs with a standard parser, including legacy reserved characters.
source lib/70_export.sh
fixture_cert="$PWD/tests/fixtures/migration-7.0.0/test-cert.pem"
tls_export_self_signed "$(jq -nc --arg file "$fixture_cert" '{certificate_path:$file}')"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Stage C CA' \
  -keyout "$temp/ca.key" -out "$temp/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=stage-c.example' \
  -keyout "$temp/leaf.key" -out "$temp/leaf.csr" >/dev/null 2>&1
openssl x509 -req -in "$temp/leaf.csr" -CA "$temp/ca.crt" -CAkey "$temp/ca.key" \
  -CAcreateserial -days 1 -out "$temp/leaf.crt" >/dev/null 2>&1
if tls_export_self_signed "$(jq -nc --arg file "$temp/leaf.crt" '{certificate_path:$file}')"; then exit 1; fi
{
  build_v2rayn_hysteria2_link 2001:db8::1 42310-45545 'a/+=@' example.test gecko 'o/+' hy2; echo
  build_v2rayn_vless_reality_link 2001:db8::1 443 uuid example.test public abcd xtls-rprx-vision reality; echo
  build_v2rayn_anytls_link example.test 443 'a/+=@' example.test anytls; echo
  build_v2rayn_ss_link 2001:db8::1 8080 2022-blake3-aes-128-gcm 'abc/+=:abc/+=' ss; echo
  build_socks_link 2001:db8::2 1080 'u@:' 'p/+%@' socks; echo
  build_v2rayn_tuic_link example.test 443 uuid 't/+@' example.test tuic; echo
  build_v2rayn_trojan_link example.test 443 't/+@' example.test trojan false; echo
  build_v2rayn_vmess_ws_link cdn.example uuid cdn.example /vmess vmess 8443; echo
  build_v2rayn_vless_ws_link cdn.example uuid cdn.example /vless vless 8443; echo
} > "$temp/links"
python3 - "$temp/links" <<'PY'
import base64, json, sys
from urllib.parse import parse_qs, unquote, urlsplit

links = open(sys.argv[1]).read().splitlines()
hy, reality, anytls, ss, socks, tuic, trojan = map(urlsplit, links[:7])
assert hy.hostname == '2001:db8::1' and hy.netloc.endswith(':42310-45545')
assert unquote(hy.username) == 'a/+=@'
assert parse_qs(hy.query) == {'sni':['example.test'],'insecure':['1'],'obfs':['gecko'],'obfs-password':['o/+']}
assert parse_qs(reality.query)['pbk'] == ['public'] and reality.username == 'uuid'
assert unquote(anytls.username) == 'a/+=@' and parse_qs(anytls.query)['insecure'] == ['1']
assert ss.port == 8080 and ss.username == '2022-blake3-aes-128-gcm' and unquote(ss.password) == 'abc/+=:abc/+='
assert socks.hostname == '2001:db8::2' and unquote(socks.username) == 'u@:' and unquote(socks.password) == 'p/+%@'
assert unquote(tuic.password) == 't/+@' and parse_qs(tuic.query)['congestion_control'] == ['bbr']
assert unquote(trojan.username) == 't/+@' and 'alpn=' not in trojan.query and 'allowInsecure' not in trojan.query
vmess = json.loads(base64.b64decode(links[7].split('://',1)[1]))
assert (vmess['add'], vmess['port'], vmess['path'], vmess['aid'], vmess['scy']) == ('cdn.example','8443','/vmess','0','auto')
vless = urlsplit(links[8])
assert vless.port == 8443 and parse_qs(vless.query)['path'] == ['/vless']
PY
expected=$'hy2-443\nreality-443\nanytls-8443\nss-8080\nsocks-1080\ntuic-8443\ntrojan-8444\nvmess-ws-8001\nvless-ws-8002'
actual="$(protocol_entry_table "$(cat "$temp/before")" | cut -d $'\x01' -f1)"
[ "$actual" = "$expected" ]
cp "$temp/before" "$export_config"
meta_save "$(jq '
  ."vmess-ws-8001".public_endpoint = {host:"vmess.example",port:443}
  | ."vless-ws-8002".public_endpoint = {host:"vless.example",port:443}
' "$export_meta")"
export_configs "__admin__" > "$temp/rendered"
test "$(grep -cE '通用链接:|落地链接:' "$temp/rendered")" = 9
grep -q 'insecure=1.*obfs=gecko' "$temp/rendered"
grep -q 'Quantumult X: anytls=.*tls-verification=false' "$temp/rendered"
grep -q 'Quantumult X: vmess=vmess.example:443, method=chacha20-poly1305' "$temp/rendered"
grep -q 'udp-relay-mode: native, congestion-controller: bbr' "$temp/rendered"
grep -q 'socks5://socks-1080:' "$temp/rendered"
! grep -qE 'pinSHA256|min-idle-session|min_idle_session|obfs-uri=.*ed=|PUBLIC_KEY_MISSING' "$temp/rendered"
! grep '通用链接: trojan://' "$temp/rendered" | grep -q 'alpn='
protocol_edit_menu "$(config_load)" <<< $'5\nlanding.example\n1081' >/dev/null
protocol_remove_menu "$(config_load)" <<< 5 >/dev/null
jq -e '."socks-1080" == null and ."vless-ws-8002".public_endpoint.host == "vless.example"' "$export_meta" >/dev/null
echo 'PASS stage C nine URL round trips and display order'
