#!/usr/bin/env bash
# Real Nginx + sing-box test. The CDN edge is represented by a separate local TLS vhost.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SB_TEST_NGINX:?set the absolute path to nginx with the SSL module}"
: "${SB_TEST_CORE:?set the absolute path to sing-box}"
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 50_v2ray_api 60_user_db 61_user_manager 70_export 75_ws_cdn 90_protocol_menu; do
  source "lib/$module.sh"
done
test_dir="$(mktemp -d)"
core_pid=''
cleanup() {
  ws_cdn_nginx -s quit >/dev/null 2>&1 || true
  if [ -n "$core_pid" ]; then kill "$core_pid" 2>/dev/null || true; wait "$core_pid" 2>/dev/null || true; fi
  rm -rf "$test_dir"
}
trap cleanup EXIT
USER_DB_FILE="$test_dir/db.json"
CONFIG_FILE="$test_dir/config.json"
META_FILE="$test_dir/meta.json"
SB_LOCK_FILE="$test_dir/manager.lock"
WS_CDN_NGINX_DIR="$test_dir/snippets"
mkdir -p "$WS_CDN_NGINX_DIR" "$test_dir/www" "$test_dir/logs"
user_db_min_template > "$USER_DB_FILE"
printf '{}\n' > "$META_FILE"
printf 'ip=198.51.100.42\n' > "$test_dir/www/trace"
read -r origin_port edge_port trace_port vmess_port vless_port < <(python3 - <<'PY'
from contextlib import ExitStack
from socket import AF_INET, AF_INET6, SOCK_STREAM, socket
with ExitStack() as stack:
    sockets = []
    for family, host in [(AF_INET6,'::1'),(AF_INET,'127.0.0.1')]+[(AF_INET,'127.0.0.1')]*3:
        sock=stack.enter_context(socket(family,SOCK_STREAM))
        sock.bind((host,0))
        sockets.append(sock)
    print(*(sock.getsockname()[1] for sock in sockets))
PY
)
real_curl="$(command -v curl)"
ws_cdn_nginx() { "$SB_TEST_NGINX" -p "$test_dir/" -c "$test_dir/nginx.conf" "$@"; }
ws_cdn_public_peer() { [ "$1" = 127.0.0.1 ]; } # Only the public-address policy is replaced.
ws_cdn_public_ca() { printf '%s\n' "$test_dir/ca.pem"; }
ws_cdn_probe_target() { printf 'https://127.0.0.1:%s/trace\n' "$trace_port"; }
curl() {
  "$real_curl" --resolve "cdn.loopback.test:$edge_port:127.0.0.1" "$@"
}
sing-box() {
  if [ "$1" = run ] && [[ "$3" == */client.json ]]; then
    jq '.outbounds[0].server="127.0.0.1"' "$3" > "$3.with-test-dns"
    exec "$SB_TEST_CORE" run -c "$3.with-test-dns"
  else
    "$SB_TEST_CORE" "$@"
  fi
}
# Use a private test CA, and verify both HTTPS legs and the final HTTPS request.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Stage D test CA' \
  -keyout "$test_dir/ca.key" -out "$test_dir/ca.pem" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=cdn.loopback.test' \
  -keyout "$test_dir/server.key" -out "$test_dir/server.csr" >/dev/null 2>&1
printf '%s\n' 'subjectAltName=DNS:cdn.loopback.test,DNS:origin.loopback.test,IP:127.0.0.1' > "$test_dir/extensions"
openssl x509 -req -in "$test_dir/server.csr" -CA "$test_dir/ca.pem" -CAkey "$test_dir/ca.key" \
  -CAcreateserial -days 1 -extfile "$test_dir/extensions" -out "$test_dir/server.pem" >/dev/null 2>&1

write_nginx() {
  local vless_target="$1"
  cat > "$test_dir/nginx.conf" <<EOF
worker_processes 1;
pid "$test_dir/nginx.pid";
error_log "$test_dir/error.log";
events {worker_connections 64;}
http {
    access_log off;
    ssl_certificate "$test_dir/server.pem";
    ssl_certificate_key "$test_dir/server.key";
    server {
        listen [::1]:$origin_port ssl;
        server_name origin.loopback.test cdn.loopback.test;
        include "$WS_CDN_NGINX_DIR/cdn.loopback.test.*.conf";
    }
    server {
        listen 127.0.0.1:$trace_port ssl;
        server_name trace.loopback.test;
        location = /trace { root "$test_dir/www"; }
    }
    server {
        listen 127.0.0.1:$edge_port ssl;
        server_name cdn.loopback.test;
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate "$test_dir/ca.pem";
        proxy_ssl_server_name on;
        proxy_ssl_name origin.loopback.test;
        proxy_http_version 1.1;
        proxy_set_header Connection "upgrade";
        proxy_set_header Upgrade \$http_upgrade;
        location / { proxy_pass https://[::1]:$origin_port; }
        location = /vless {
            proxy_pass https://[::1]:$origin_port$vless_target;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Sec-WebSocket-Protocol "";
        }
    }
}
EOF
}

jq --argjson vmess "$vmess_port" --argjson vless "$vless_port" '
  (.inbounds[] | select(.tag == "vmess-ws-18001") | .listen_port=$vmess) as $old
  | {inbounds:[$old,
       ($old | .type="vless" | .tag="vless-ws-18002" | .listen_port=$vless
        | .users=[{name:"vless-ws-18002",uuid:"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"}]
        | .transport.path="/vless")],
     outbounds:[{type:"direct",tag:"direct"}], log:{disabled:true}, route:{rules:[]}}
' tests/fixtures/migration-7.0.0/config.json > "$CONFIG_FILE"
cp "$CONFIG_FILE" "$test_dir/original"
write_nginx /old-ws
ws_cdn_nginx -t -q
ws_cdn_nginx
"$SB_TEST_CORE" run -c "$CONFIG_FILE" > "$test_dir/core.log" 2>&1 &
core_pid=$!
sleep 0.4
kill -0 "$core_pid"

profile="$(jq -nc --argjson edge "$edge_port" --argjson origin "$origin_port" --arg ca "$test_dir/ca.pem" '
  {host:"cdn.loopback.test",port:$edge,mode:"nginx",
   origin:{address:"::1",port:$origin,sni:"origin.loopback.test",ca:$ca}}
')"
ws_cdn_attach vmess-ws-18001 "$profile"
snippet="$(ws_cdn_snippet_path cdn.loopback.test)"
cp "$snippet" "$test_dir/before"
cp "$META_FILE" "$test_dir/meta.before"
jq -e '."vmess-ws-18001".cdn_entries[0].early_data == 2048' "$META_FILE" >/dev/null

# Both HTTPS upgrades work, but the edge sends VLESS to the VMess origin path.
if ws_cdn_attach vless-ws-18002 "$profile"; then exit 1; fi
cmp "$snippet" "$test_dir/before"
cmp "$META_FILE" "$test_dir/meta.before"
old_inbound="$(ws_cdn_ws_inbound "$(config_load)" vmess-ws-18001)"
ws_cdn_proxy_probe "$old_inbound" cdn.loopback.test "$edge_port" /old-ws 0 "$test_dir/ca.pem"

write_nginx /vless
ws_cdn_nginx -t -q
ws_cdn_nginx -s reload
sleep 0.4
ws_cdn_attach vless-ws-18002 "$profile"
jq -e '."vless-ws-18002".cdn_entries[0].verified == true and
       ."vless-ws-18002".cdn_entries[0].early_data == 0' "$META_FILE" >/dev/null
cp "$META_FILE" "$test_dir/verified"
cp "$snippet" "$test_dir/both-paths"
(
  # Keep the origin trust correct, and make only the edge CA validation fail.
  ws_cdn_public_ca() { printf '%s\n' "$PWD/tests/fixtures/migration-7.0.0/test-cert.pem"; }
  if ws_cdn_attach vless-ws-18002 "$profile"; then exit 1; fi
)
cmp "$META_FILE" "$test_dir/verified"
cmp "$snippet" "$test_dir/both-paths"
cmp "$CONFIG_FILE" "$test_dir/original"
kill -0 "$core_pid"
printf '%s\n' 'PASS stage D real TLS and WebSocket for both paths, detected incorrect forwarding, preserved first path, gated Early Data'
