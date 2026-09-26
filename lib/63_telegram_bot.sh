#!/usr/bin/env bash
# ============================================================
# 模块: 63_telegram_bot.sh
# 职责: Telegram Bot 配置、中心服务、节点上报、绑定链接
# 依赖: 00_base.sh, 01_utils.sh, 60_user_db.sh, 80_installer.sh
# ============================================================

tg_config_min_template() {
  cat <<'JSON'
{
  "enabled": false,
  "role": "",
  "bot_token": "",
  "bot_username": "",
  "admin_chat_ids": [],
  "listen_host": "0.0.0.0",
  "listen_port": 25888,
  "center_url": "",
  "access_secret": "",
  "vps_id": "",
  "vps_name": "",
  "notify_threshold": 90,
  "expire_warn_days": 3,
  "reports": {},
  "bindings": [],
  "pending_bind_tokens": {},
  "user_settings": {},
  "notify_state": {},
  "tasks": {},
  "pending_admin_actions": {},
  "waiting_inputs": {}
}
JSON
}

tg_config_load() {
  if [ -s "$TG_CONFIG_FILE" ] && jq -e . "$TG_CONFIG_FILE" >/dev/null 2>&1; then
    cat "$TG_CONFIG_FILE"
  else
    tg_config_min_template
  fi
}

tg_config_save() {
  with_manager_lock _tg_config_save_body "$@"
}

_tg_config_save_body() {
  local json="$1"
  mkdir -p "$(dirname "$TG_CONFIG_FILE")"
  chmod 700 "$(dirname "$TG_CONFIG_FILE")" 2>/dev/null || true
  local tmp_file
  tmp_file="$(mktemp "${TG_CONFIG_FILE}.tmp.XXXXXX")" || return 1
  if echo "$json" | jq . > "$tmp_file"; then
    if ! mv -f "$tmp_file" "$TG_CONFIG_FILE"; then
      err "TG 配置写入失败：$TG_CONFIG_FILE"
      rm -f "$tmp_file" >/dev/null 2>&1 || true
      return 1
    fi
    chmod 600 "$TG_CONFIG_FILE" 2>/dev/null || true
  else
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi
}

tg_task_receipts_load() {
  if [ -s "$TG_TASK_RECEIPTS_FILE" ] && jq -e . "$TG_TASK_RECEIPTS_FILE" >/dev/null 2>&1; then
    cat "$TG_TASK_RECEIPTS_FILE"
  else
    echo '{"tasks":{}}'
  fi
}

# Setup 流程的"持锁原子提交" helper（6.1.6 起）。
# tg_setup_center / tg_setup_agent 在用户输入完字段后，函数体内的 cfg 已经是 5 分钟前 load 的快照，
# 整个写回去会覆盖期间 Python 端写入的 reports/tasks/bindings 等字段。
# 这里在 with_manager_lock 内 reload + merge + save，确保跨进程 RMW 原子。
_tg_setup_center_commit() {
  with_manager_lock _tg_setup_center_commit_body "$@"
}

_tg_setup_center_commit_body() {
  local token="$1" admin="$2" port="$3" url="$4" secret="$5" vps_id="$6" vps_name="$7" username="$8"
  local cfg
  cfg="$(tg_config_load)"
  cfg="$(echo "$cfg" | jq \
    --arg token "$token" \
    --arg admin "$admin" \
    --argjson port "$port" \
    --arg url "$url" \
    --arg secret "$secret" \
    --arg vps_id "$vps_id" \
    --arg vps_name "$vps_name" \
    --arg username "$username" '
      .enabled = true
      | .role = "center"
      | .bot_token = $token
      | .bot_username = $username
      | .admin_chat_ids = [$admin]
      | .listen_host = "0.0.0.0"
      | .listen_port = $port
      | .center_url = $url
      | .access_secret = $secret
      | .vps_id = $vps_id
      | .vps_name = $vps_name
    ')" || return 1
  _tg_config_save_body "$cfg"
}

_tg_setup_agent_commit() {
  with_manager_lock _tg_setup_agent_commit_body "$@"
}

_tg_setup_agent_commit_body() {
  local url="$1" secret="$2" vps_id="$3" vps_name="$4"
  local cfg
  cfg="$(tg_config_load)"
  cfg="$(echo "$cfg" | jq \
    --arg url "$url" \
    --arg secret "$secret" \
    --arg vps_id "$vps_id" \
    --arg vps_name "$vps_name" '
      .enabled = true
      | .role = "agent"
      | .center_url = $url
      | .access_secret = $secret
      | .vps_id = $vps_id
      | .vps_name = $vps_name
    ')" || return 1
  _tg_config_save_body "$cfg"
}

# 通用 RMW：持锁内 reload + 应用 jq 表达式 + save。避免 cfg 5+ 分钟前快照被整体写回时覆盖 Python 期间写入的字段。
# 用法：tg_config_merge_jq '<jq 表达式>' [jq --arg/--argjson 参数...]
tg_config_merge_jq() {
  with_manager_lock _tg_config_merge_jq_body "$@"
}

_tg_config_merge_jq_body() {
  local jq_expr="$1"
  shift
  local cfg
  cfg="$(tg_config_load)"
  cfg="$(echo "$cfg" | jq "$@" "$jq_expr")" || return 1
  _tg_config_save_body "$cfg"
}

# 专用 prune helper：reports 过期清理。fast-path 检测+实际写入都在同一把锁内，避免与 /api/report 并发写竞争。
_tg_prune_reports_with_lock() {
  with_manager_lock _tg_prune_reports_body "$@"
}

_tg_prune_reports_body() {
  local now="$1"
  local cfg removed pruned
  cfg="$(tg_config_load)"
  removed="$(echo "$cfg" | jq -r --argjson now "$now" '
    [(.reports // {}) | to_entries[] | select(($now - (.value.received_at // $now)) > 900)] | length
  ')" || return 1
  if [ "${removed:-0}" -le 0 ]; then
    echo 0
    return 0
  fi
  pruned="$(echo "$cfg" | jq --argjson now "$now" '
    .reports = ((.reports // {}) | with_entries(select(($now - (.value.received_at // $now)) <= 900)))
  ')" || return 1
  _tg_config_save_body "$pruned" || return 1
  echo "$removed"
}

tg_task_receipts_save() {
  local json="$1"
  mkdir -p "$(dirname "$TG_TASK_RECEIPTS_FILE")"
  chmod 700 "$(dirname "$TG_TASK_RECEIPTS_FILE")" 2>/dev/null || true
  local tmp_file
  tmp_file="$(mktemp "${TG_TASK_RECEIPTS_FILE}.tmp.XXXXXX")" || return 1
  if echo "$json" | jq . > "$tmp_file"; then
    if ! mv -f "$tmp_file" "$TG_TASK_RECEIPTS_FILE"; then
      err "TG 任务回执写入失败：$TG_TASK_RECEIPTS_FILE"
      rm -f "$tmp_file" >/dev/null 2>&1 || true
      return 1
    fi
    chmod 600 "$TG_TASK_RECEIPTS_FILE" 2>/dev/null || true
  else
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi
}

tg_task_receipt_get() {
  local task_id="$1"
  [ -n "$task_id" ] || return 1
  tg_task_receipts_load | jq -c --arg id "$task_id" '.tasks[$id] // empty'
}

# 预留 receipt 占位：写入成功才允许执行任务，避免崩溃后无法识别已开过头的任务
tg_task_receipt_reserve() {
  local task_id="$1" now receipts
  [ -n "$task_id" ] || return 1
  now="$(date +%s)"
  receipts="$(tg_task_receipts_load | jq --arg id "$task_id" --argjson now "$now" '
    .tasks = (.tasks // {})
    | .tasks[$id] = {status:"running", started_at:$now}
    | .tasks |= with_entries(select(($now - (.value.completed_at // .value.started_at // $now)) <= 604800))
  ')" || return 1
  tg_task_receipts_save "$receipts"
}

# 任务执行结束后落盘最终结果；保存失败必须返回非零，由调用方决定是否上报主控
tg_task_receipt_finalize() {
  local task_id="$1" ok_value="$2" message="$3" now receipts ok_bool
  [ -n "$task_id" ] || return 1
  if [ "$ok_value" = "true" ]; then ok_bool="true"; else ok_bool="false"; fi
  now="$(date +%s)"
  receipts="$(tg_task_receipts_load | jq --arg id "$task_id" --arg message "$message" --argjson ok "$ok_bool" --argjson now "$now" '
    .tasks = (.tasks // {})
    | .tasks[$id] = {status:"done", ok:$ok, message:$message, completed_at:$now}
    | .tasks |= with_entries(select(($now - (.value.completed_at // .value.started_at // $now)) <= 604800))
  ')" || return 1
  tg_task_receipts_save "$receipts"
}

tg_config_enabled_value() {
  local cfg="$1"
  echo "$cfg" | jq -r '
    if has("enabled") then
      (.enabled == true)
    else
      ((.role // "") == "center" or (.role // "") == "agent")
    end
  '
}

tg_config_is_enabled() {
  local cfg="${1:-}"
  [ -n "$cfg" ] || cfg="$(tg_config_load)"
  [ "$(tg_config_enabled_value "$cfg")" = "true" ]
}

tg_mark_disabled_keep_config() {
  [ -s "$TG_CONFIG_FILE" ] || return 0
  tg_config_merge_jq '.enabled = false'
}

tg_generate_secret() {
  local raw
  raw="$(openssl rand -hex 16 2>/dev/null || true)"
  [ -n "$raw" ] || raw="$(date +%s%N | sha256sum | awk '{print $1}' | cut -c1-32)"
  echo "sb_tg_${raw}"
}

tg_normalize_url() {
  local url="${1:-}"
  url="${url%/}"
  echo "$url"
}

tg_api_request() {
  local token="$1" method="$2" payload="${3:-{}}"
  [ -n "$token" ] || return 1
  curl -fsS --connect-timeout 10 --max-time 20 \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://api.telegram.org/bot${token}/${method}"
}

tg_bot_username_from_token() {
  local token="$1" resp
  resp="$(tg_api_request "$token" "getMe" '{}')" || return 1
  echo "$resp" | jq -r '.result.username // empty'
}

tg_send_message() {
  local token="$1" chat_id="$2" text="$3"
  local payload
  [ -n "$chat_id" ] || return 1
  payload="$(jq -n --arg chat_id "$chat_id" --arg text "$text" \
    '{chat_id:$chat_id,text:$text,disable_web_page_preview:true}')"
  tg_api_request "$token" "sendMessage" "$payload" >/dev/null
}

tg_generate_vps_id() {
  local raw
  raw="$(openssl rand -hex 4 2>/dev/null || true)"
  [ -n "$raw" ] || raw="$(date +%s%N | sha256sum | awk '{print $1}' | cut -c1-8)"
  echo "node_${raw}"
}

tg_require_python3() {
  if has_cmd python3; then
    return 0
  fi
  warn "未检测到 python3，开始安装..."
  install_pkg python3
}

tg_write_center_app() {
  mkdir -p "$(dirname "$TG_CENTER_APP")"
  cat > "$TG_CENTER_APP" <<'PY'
#!/usr/bin/env python3
import contextlib
import datetime
import fcntl
import http.server
import json
import os
import re
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

CONFIG_PATH = sys.argv[1] if len(sys.argv) > 1 else "/etc/sing-box-manager/telegram.json"
LOCK_PATH = "/var/lock/singbox-manager.lock"
REPORT_ONLINE_SECONDS = 900


def load_config():
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_config(cfg):
    # 与 bash 端 with_manager_lock 共享同一个 lock 文件。
    # 这是"单次写"的对外入口，自带文件锁。RMW（load→改→save）必须用 cfg_lock() 包，
    # 否则 load 和 save 之间存在间隙，跨进程 RMW 仍会丢更新。
    with file_lock():
        save_config_unlocked(cfg)


@contextlib.contextmanager
def file_lock():
    """跨进程文件锁，与 bash with_manager_lock 共享 SB_LOCK_FILE。"""
    os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
    fd = os.open(LOCK_PATH, os.O_CREAT | os.O_WRONLY, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass


def save_config_unlocked(cfg):
    """save_config 的不持锁版本——调用方已在 file_lock / cfg_lock 内时用这个。"""
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, CONFIG_PATH)
    try:
        os.chmod(CONFIG_PATH, 0o600)
    except OSError:
        pass


@contextlib.contextmanager
def cfg_lock():
    """RMW 双锁：threading.Lock 防同进程多线程竞争 + file_lock 防跨进程并发。
    替代 `with CFG_LOCK:` 块——后者只防同进程线程，没防 bash 与 Python 跨进程 RMW 丢更新。
    内部 load_config / save_config_unlocked 在同一把锁内进行。
    注意：CFG_LOCK 是非重入 threading.Lock，调用方不能在已持有 cfg_lock 的情况下再进入。"""
    with CFG_LOCK:
        with file_lock():
            yield


CFG_LOCK = threading.Lock()


def bot_api(method, payload=None):
    cfg = load_config()
    token = cfg.get("bot_token", "")
    if not token:
        return {"ok": False, "description": "bot token missing"}
    data = json.dumps(payload or {}).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            return json.loads(exc.read().decode("utf-8"))
        except Exception:
            return {"ok": False, "description": str(exc)}
    except Exception as exc:
        return {"ok": False, "description": str(exc)}


def send_message(chat_id, text, keyboard=None):
    payload = {
        "chat_id": chat_id,
        "text": text,
        "disable_web_page_preview": True,
    }
    if keyboard is not None:
        payload["reply_markup"] = {"inline_keyboard": keyboard}
    return bot_api("sendMessage", payload)


def edit_message(chat_id, message_id, text, keyboard=None):
    payload = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": text,
        "disable_web_page_preview": True,
    }
    if keyboard is not None:
        payload["reply_markup"] = {"inline_keyboard": keyboard}
    return bot_api("editMessageText", payload)


def render_page(chat_id, text, keyboard=None, message_id=None):
    if message_id:
        resp = edit_message(chat_id, message_id, text, keyboard)
        if resp.get("ok") or "message is not modified" in (resp.get("description") or ""):
            return resp
    return send_message(chat_id, text, keyboard)


def answer_callback(callback_id, text=None):
    payload = {"callback_query_id": callback_id}
    if text:
        payload["text"] = text
    bot_api("answerCallbackQuery", payload)


def get_bot_username(cfg):
    """读 bot_username。如果 cfg 里缺，在线 getMe 获取并写入 cfg（**只更新内存**）。
    调用方负责后续 save——避免与外层 cfg_lock 嵌套死锁（CFG_LOCK 是非重入锁）。"""
    username = cfg.get("bot_username") or ""
    if username:
        return username
    resp = bot_api("getMe", {})
    username = ((resp.get("result") or {}).get("username") or "")
    if username:
        cfg["bot_username"] = username
    return username


def today():
    # 锁定北京时间（UTC+8），与 bash 端的 user_today_date / BUSINESS_TZ 保持一致。
    # 用 utcnow + 8h 而非 zoneinfo，零依赖、不挑 Python 版本。
    return (datetime.datetime.utcnow() + datetime.timedelta(hours=8)).date()


def parse_date(value):
    if not value or value == "0":
        return None
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        return None


def fmt_bytes(value):
    try:
        b = float(value or 0)
    except Exception:
        b = 0.0
    gb = 1024 ** 3
    tb = 1024 ** 4
    if abs(b) >= tb:
        return f"{b / tb:.1f}TB"
    return f"{b / gb:.1f}GB"


def user_total(user):
    return int(user.get("used_up_bytes") or 0) + int(user.get("used_down_bytes") or 0) + int(user.get("manual_added_bytes") or 0)


def status_text(user):
    if user.get("enabled") is True:
        return "开启"
    reason = user.get("disabled_reason")
    if reason == "expired":
        return "关闭（到期）"
    if reason == "quota_exceeded":
        return "关闭（超量）"
    if reason == "manual":
        return "关闭（手动停用）"
    return "关闭"


def find_report_user(cfg, binding):
    report = (cfg.get("reports") or {}).get(binding.get("vps_id") or "")
    if not report:
        return None, None
    username = binding.get("username") or ""
    for user in report.get("users") or []:
        if user.get("username") == username:
            return report, user
    return report, None


def is_admin(cfg, tg_id):
    return str(tg_id) in {str(x) for x in cfg.get("admin_chat_ids") or []}


def user_home_keyboard(bindings=None):
    bindings = bindings or []
    rows = []
    row = []
    for idx, binding in enumerate(bindings):
        label = binding.get("vps_name") or binding.get("vps_id") or str(idx + 1)
        row.append({"text": label, "callback_data": f"u:detail:{idx}"})
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    if bindings:
        rows.append([{"text": "提醒设置", "callback_data": "u:notify"}, {"text": "解除绑定", "callback_data": "u:bind"}])
    return rows


def render_unbound_user_state(chat_id, message_id=None, text=None):
    render_page(
        chat_id,
        text or "当前没有绑定。\n请联系管理员生成绑定链接。",
        None,
        message_id,
    )


def back_keyboard(back_to):
    return [[{"text": "返回", "callback_data": back_to}]]


def clear_waiting_input(tg_id):
    with cfg_lock():
        cfg = load_config()
        waiting = cfg.setdefault("waiting_inputs", {})
        if str(tg_id) in waiting:
            waiting.pop(str(tg_id), None)
            save_config_unlocked(cfg)


def send_home(chat_id, tg_id, message_id=None):
    cfg = load_config()
    if is_admin(cfg, tg_id):
        admin_overview(chat_id, message_id)
    else:
        user_status(chat_id, tg_id, message_id)


def bind_token(chat_id, tg_id, token):
    with cfg_lock():
        cfg = load_config()
        pending = cfg.setdefault("pending_bind_tokens", {})
        item = pending.get(token)
        now = int(time.time())
        if not item or int(item.get("expires_at") or 0) < now:
            send_message(chat_id, "绑定链接已失效，请联系管理员重新生成。")
            return
        bindings = cfg.setdefault("bindings", [])
        exists = False
        for b in bindings:
            if str(b.get("tg_user_id")) == str(tg_id) and b.get("vps_id") == item.get("vps_id") and b.get("username") == item.get("username"):
                b["active"] = True
                b["chat_id"] = chat_id
                exists = True
                break
        if not exists:
            bindings.append({
                "tg_user_id": tg_id,
                "chat_id": chat_id,
                "vps_id": item.get("vps_id"),
                "vps_name": item.get("vps_name"),
                "username": item.get("username"),
                "active": True,
                "created_at": now,
            })
        pending.pop(token, None)
        settings = cfg.setdefault("user_settings", {})
        settings.setdefault(str(tg_id), {"notify": True})
        save_config_unlocked(cfg)
    send_message(chat_id, f"绑定成功：{item.get('vps_name')} / {item.get('username')}")
    send_home(chat_id, tg_id)


def user_bindings(cfg, tg_id):
    return [
        b for b in (cfg.get("bindings") or [])
        if b.get("active") is not False and str(b.get("tg_user_id")) == str(tg_id)
    ]


def user_status(chat_id, tg_id, message_id=None):
    cfg = load_config()
    bindings = user_bindings(cfg, tg_id)
    if not bindings:
        render_unbound_user_state(chat_id, message_id)
        return
    lines = ["我的绑定", ""]
    for b in bindings:
        lines.append(f"{b.get('vps_name') or b.get('vps_id')} / {b.get('username')}")
    render_page(chat_id, "\n".join(lines), user_home_keyboard(bindings), message_id)


def user_detail(chat_id, tg_id, idx, message_id=None):
    cfg = load_config()
    bindings = user_bindings(cfg, tg_id)
    if idx < 0 or idx >= len(bindings):
        user_status(chat_id, tg_id, message_id)
        return
    binding = bindings[idx]
    report, user = find_report_user(cfg, binding)
    title = f"{binding.get('vps_name') or binding.get('vps_id')} / {binding.get('username')}"
    if report is None:
        render_page(chat_id, f"{title}\n状态：节点暂无上报", back_keyboard("u:home"), message_id)
        return
    if user is None:
        render_page(chat_id, f"{title}\n状态：绑定已失效，请联系管理员", back_keyboard("u:home"), message_id)
        return
    render_page(chat_id, "\n".join(user_detail_lines(title, report, user)), back_keyboard("u:home"), message_id)


def notify_settings(chat_id, tg_id, admin=False, message_id=None):
    cfg = load_config()
    settings = cfg.setdefault("user_settings", {})
    item = settings.setdefault(str(tg_id), {"notify": True})
    state = "开启" if item.get("notify", True) else "关闭"
    text = f"提醒设置\n\n提醒：{state}\n规则：流量达到{cfg.get('notify_threshold', 90)}%、到期前{cfg.get('expire_warn_days', 3)}天提醒"
    back_to = "a:home" if admin else "u:home"
    keyboard = [[
        {"text": "关闭提醒" if item.get("notify", True) else "开启提醒", "callback_data": "a:toggle_notify" if admin else "u:toggle_notify"},
        {"text": "返回", "callback_data": back_to},
    ]]
    render_page(chat_id, text, keyboard, message_id)


def toggle_notify(chat_id, tg_id, admin=False, message_id=None):
    with cfg_lock():
        cfg = load_config()
        settings = cfg.setdefault("user_settings", {})
        item = settings.setdefault(str(tg_id), {"notify": True})
        item["notify"] = not bool(item.get("notify", True))
        save_config_unlocked(cfg)
    notify_settings(chat_id, tg_id, admin, message_id)


def binding_list(chat_id, tg_id, message_id=None):
    cfg = load_config()
    bindings = user_bindings(cfg, tg_id)
    if not bindings:
        render_page(chat_id, "当前没有绑定的用户。", back_keyboard("u:home"), message_id)
        return
    lines = ["绑定状态", "", "已绑定："]
    keyboard = []
    for idx, b in enumerate(bindings):
        label = f"{b.get('vps_name') or b.get('vps_id')} / {b.get('username')}"
        lines.append(f"- {label}")
        keyboard.append([{"text": f"解绑 {label}", "callback_data": f"u:ask_unbind:{idx}"}])
    keyboard.append([{"text": "返回", "callback_data": "u:home"}])
    render_page(chat_id, "\n".join(lines), keyboard, message_id)


def ask_unbind(chat_id, tg_id, idx, message_id=None):
    cfg = load_config()
    bindings = user_bindings(cfg, tg_id)
    if idx < 0 or idx >= len(bindings):
        binding_list(chat_id, tg_id, message_id)
        return
    b = bindings[idx]
    label = f"{b.get('vps_name') or b.get('vps_id')} / {b.get('username')}"
    render_page(chat_id, f"确认解除绑定：{label}？", [
        [{"text": "确认解除", "callback_data": f"u:do_unbind:{idx}"}, {"text": "取消", "callback_data": "u:bind"}],
    ], message_id)


def do_unbind(chat_id, tg_id, idx, message_id=None):
    with cfg_lock():
        cfg = load_config()
        real_indices = [
            i for i, b in enumerate(cfg.get("bindings") or [])
            if b.get("active") is not False and str(b.get("tg_user_id")) == str(tg_id)
        ]
        if idx < 0 or idx >= len(real_indices):
            save_config_unlocked(cfg)
            binding_list(chat_id, tg_id, message_id)
            return
        cfg["bindings"][real_indices[idx]]["active"] = False
        save_config_unlocked(cfg)
    render_unbound_user_state(chat_id, message_id, "绑定已解除。\n当前没有绑定。")


def quota_text(quota):
    quota = int(quota or 0)
    return "不限" if quota == 0 else f"{quota}GB"


def reset_day_text(value):
    try:
        value = int(value or 0)
    except Exception:
        value = 0
    if value == 0:
        return "不重置"
    if value == 32:
        return "月底"
    return f"{value}号"


def user_summary_line(user):
    total = fmt_bytes(user_total(user))
    quota = quota_text(user.get("quota_gb") or 0)
    expire = user.get("expire_at") or "0"
    exp = parse_date(expire)
    if exp is None:
        exp_text = "永久"
    else:
        days = (exp - today()).days
        exp_text = f"剩{days}天" if days > 0 else "已过期"
    return f"{user.get('username')}：{total}/{quota}，{exp_text}，{status_text(user)}"


def expire_display(value):
    return "永久" if not value or value == "0" else str(value)


def usage_current_line(user):
    return f"当前用量：{fmt_bytes(user_total(user))} / {quota_text(user.get('quota_gb') or 0)}"


def traffic_detail_lines(user):
    return [
        f"上传：{fmt_bytes(user.get('used_up_bytes') or 0)}",
        f"下载：{fmt_bytes(user.get('used_down_bytes') or 0)}",
        f"补正：{fmt_bytes(user.get('manual_added_bytes') or 0)}",
    ]


def usage_summary(user):
    return [usage_current_line(user)]


def used_detail_text(user):
    total = user_total(user)
    quota = int(user.get("quota_gb") or 0)
    if quota > 0:
        return f"{fmt_bytes(total)} / {quota}GB（{int(total * 100 / (quota * 1024 ** 3))}%）"
    return f"{fmt_bytes(total)} / 不限"


def expire_detail_text(user):
    expire = user.get("expire_at") or "0"
    exp = parse_date(expire)
    if exp is None:
        return "永久"
    days = (exp - today()).days
    return f"{expire}（剩余{days}天）" if days > 0 else f"{expire}（已过期）"


def user_detail_lines(title, report, user):
    return [
        title,
        f"状态：{status_text(user)}",
        f"已用：{used_detail_text(user)}",
        *traffic_detail_lines(user),
        f"重置日期：{reset_day_text(user.get('reset_day') or 0)}",
        f"到期：{expire_detail_text(user)}",
        f"更新时间：{report.get('updated_at_text') or '未知'}",
    ]


def report_user_title(report, vps_id, user):
    return f"{report.get('vps_name') or vps_id} / {user.get('username')}"


def add_calendar_months(base_date, months):
    def last_day(year, month):
        if month == 12:
            nxt = datetime.date(year + 1, 1, 1)
        else:
            nxt = datetime.date(year, month + 1, 1)
        return (nxt - datetime.timedelta(days=1)).day

    is_eom = base_date.day == last_day(base_date.year, base_date.month)
    total = base_date.year * 12 + (base_date.month - 1) + int(months)
    year = total // 12
    month = total % 12 + 1
    day = last_day(year, month) if is_eom else min(base_date.day, last_day(year, month))
    return datetime.date(year, month, day)


def renewal_preview(user, months):
    current = user.get("expire_at") or "0"
    current_date = parse_date(current)
    if current_date is None:
        return None
    base_date = today() if today() >= current_date else current_date
    return add_calendar_months(base_date, int(months)).isoformat()


def renew_months_text(months):
    months = int(months)
    if months == 1:
        return "1 个月"
    if months == 3:
        return "1 个季度"
    return f"{months} 个月"


def renew_confirm_text(report, vps_id, user, months):
    new_expire = renewal_preview(user, months)
    if new_expire is None:
        return None
    return "\n".join([
        f"当前到期：{expire_display(user.get('expire_at') or '0')}",
        f"续期后：{new_expire}",
        "",
        f"确认将 {report_user_title(report, vps_id, user)}",
        f"续期 {renew_months_text(months)}？",
    ])


def signed_gb_text(bytes_value):
    return f"{float(bytes_value) / (1024 ** 3):+.1f}GB"


def sorted_reports(reports):
    return sorted(
        (reports or {}).items(),
        key=lambda item: ((item[1].get("vps_name") or item[0]).casefold(), item[0]),
    )


def admin_machine_keyboard(reports):
    buttons = [
        {"text": (report.get("vps_name") or vps_id), "callback_data": f"a:vps:{vps_id}"}
        for vps_id, report in sorted_reports(reports)
    ]
    rows = []
    i = 0
    while i + 1 < len(buttons):
        rows.append([buttons[i], buttons[i + 1]])
        i += 2
    if i < len(buttons):
        rows.append([buttons[i]])
    rows.append([{"text": "刷新", "callback_data": "a:home"}, {"text": "提醒设置", "callback_data": "a:notify"}])
    return rows


def admin_overview(chat_id, message_id=None):
    cfg = load_config()
    reports = cfg.get("reports") or {}
    if not reports:
        render_page(chat_id, "当前没有节点上报数据。", [[{"text": "刷新", "callback_data": "a:home"}, {"text": "提醒设置", "callback_data": "a:notify"}]], message_id)
        return
    lines = []
    now = int(time.time())
    for vps_id, report in sorted_reports(reports):
        users = report.get("users") or []
        warn_count = 0
        expire_count = 0
        for user in users:
            quota = int(user.get("quota_gb") or 0)
            if quota > 0 and user_total(user) >= quota * 1024 ** 3 * int(cfg.get("notify_threshold", 90)) / 100:
                warn_count += 1
            exp = parse_date(user.get("expire_at") or "0")
            if exp is not None and 1 <= (exp - today()).days <= int(cfg.get("expire_warn_days", 3)):
                expire_count += 1
        age = now - int(report.get("received_at") or now)
        state_text = "在线 ✅" if age <= REPORT_ONLINE_SECONDS else "离线 ❌"
        parts = [f"{report.get('vps_name') or vps_id}：用户{len(users)}"]
        if warn_count > 0:
            parts.append(f"预警{warn_count}⚠️")
        if expire_count > 0:
            parts.append(f"到期{expire_count}⚠️")
        parts.append(state_text)
        lines.append("，".join(parts))
    render_page(chat_id, "\n".join(lines), admin_machine_keyboard(reports), message_id)


def admin_vps(chat_id, vps_id, message_id=None):
    cfg = load_config()
    report = (cfg.get("reports") or {}).get(vps_id)
    if not report:
        admin_overview(chat_id, message_id)
        return
    users = report.get("users") or []
    if len(users) == 1:
        render_page(
            chat_id,
            "\n".join(user_detail_lines(report_user_title(report, vps_id, users[0]), report, users[0])),
            admin_user_keyboard(vps_id, 0, users[0], "a:home"),
            message_id,
        )
        return
    lines = [report.get("vps_name") or vps_id]
    keyboard = []
    row = []
    for idx, user in enumerate(users):
        lines.append(user_summary_line(user))
        row.append({"text": str(user.get("username") or idx), "callback_data": f"a:user:{vps_id}:{idx}"})
        if len(row) == 2:
            keyboard.append(row)
            row = []
    if row:
        keyboard.append(row)
    keyboard.append([{"text": "返回", "callback_data": "a:home"}])
    render_page(chat_id, "\n".join(lines), keyboard, message_id)


def find_report_user_by_index(cfg, vps_id, idx):
    report = (cfg.get("reports") or {}).get(vps_id)
    if not report:
        return None, None
    users = report.get("users") or []
    if idx < 0 or idx >= len(users):
        return report, None
    return report, users[idx]


def admin_user_back_data(report, vps_id):
    return "a:home" if len(report.get("users") or []) == 1 else f"a:vps:{vps_id}"


def admin_user_keyboard(vps_id, idx, user, back_data=None):
    toggle_text = "停用" if user.get("enabled") is True else "启用"
    back_data = back_data or f"a:vps:{vps_id}"
    return [
        [{"text": toggle_text, "callback_data": f"a:toggle:{vps_id}:{idx}"}, {"text": "续期", "callback_data": f"a:renew_menu:{vps_id}:{idx}"}],
        [{"text": "套餐", "callback_data": f"a:quota_menu:{vps_id}:{idx}"}, {"text": "更多", "callback_data": f"a:more:{vps_id}:{idx}"}],
        [{"text": "返回", "callback_data": back_data}],
    ]


def admin_user_detail(chat_id, vps_id, idx, message_id=None):
    cfg = load_config()
    report, user = find_report_user_by_index(cfg, vps_id, idx)
    if not report or not user:
        admin_vps(chat_id, vps_id, message_id)
        return
    render_page(
        chat_id,
        "\n".join(user_detail_lines(report_user_title(report, vps_id, user), report, user)),
        admin_user_keyboard(vps_id, idx, user, admin_user_back_data(report, vps_id)),
        message_id,
    )


def admin_quota_menu(chat_id, vps_id, idx, message_id=None):
    cfg = load_config()
    report, user = find_report_user_by_index(cfg, vps_id, idx)
    if not report or not user:
        admin_vps(chat_id, vps_id, message_id)
        return
    text = f"套餐设置\n\n{report.get('vps_name') or vps_id} / {user.get('username')}\n当前套餐：{quota_text(user.get('quota_gb') or 0)}"
    keyboard = [
        [{"text": "50G", "callback_data": f"a:quota:{vps_id}:{idx}:50"}, {"text": "100G", "callback_data": f"a:quota:{vps_id}:{idx}:100"}, {"text": "250G", "callback_data": f"a:quota:{vps_id}:{idx}:250"}],
        [{"text": "自定义", "callback_data": f"a:quota_custom:{vps_id}:{idx}"}, {"text": "返回", "callback_data": f"a:user:{vps_id}:{idx}"}],
    ]
    render_page(chat_id, text, keyboard, message_id)


def admin_renew_menu(chat_id, vps_id, idx, message_id=None):
    cfg = load_config()
    report, user = find_report_user_by_index(cfg, vps_id, idx)
    if not report or not user:
        admin_vps(chat_id, vps_id, message_id)
        return
    text = f"一键续期\n\n{report.get('vps_name') or vps_id} / {user.get('username')}\n当前到期：{user.get('expire_at') or '0'}"
    keyboard = [
        [{"text": "1个月", "callback_data": f"a:renew:{vps_id}:{idx}:1"}, {"text": "1季度", "callback_data": f"a:renew:{vps_id}:{idx}:3"}],
        [{"text": "自定义", "callback_data": f"a:renew_custom:{vps_id}:{idx}"}, {"text": "返回", "callback_data": f"a:user:{vps_id}:{idx}"}],
    ]
    render_page(chat_id, text, keyboard, message_id)


def admin_more_menu(chat_id, vps_id, idx, message_id=None):
    cfg = load_config()
    report, user = find_report_user_by_index(cfg, vps_id, idx)
    if not report or not user:
        admin_vps(chat_id, vps_id, message_id)
        return
    text = f"更多操作\n\n{report.get('vps_name') or vps_id} / {user.get('username')}"
    keyboard = [
        [{"text": "重置流量", "callback_data": f"a:reset:{vps_id}:{idx}"}, {"text": "补正流量", "callback_data": f"a:add_usage:{vps_id}:{idx}"}],
        [{"text": "到期设置", "callback_data": f"a:expire_set:{vps_id}:{idx}"}, {"text": "重置日期", "callback_data": f"a:reset_day_set:{vps_id}:{idx}"}],
        [{"text": "返回", "callback_data": f"a:user:{vps_id}:{idx}"}],
    ]
    render_page(chat_id, text, keyboard, message_id)


def parse_quota_input(text):
    raw = (text or "").strip()
    if not re.fullmatch(r"\d+", raw):
        return None
    return int(raw)


def parse_months_input(text):
    raw = (text or "").strip()
    if not re.fullmatch(r"\d+", raw):
        return None
    months = int(raw)
    return months if months >= 1 else None


def parse_traffic_input(text):
    raw = (text or "").strip().replace(" ", "")
    m = re.fullmatch(r"([+-]?\d+(?:\.\d)?)", raw)
    if not m:
        return None
    value = float(m.group(1))
    return int(value * (1024 ** 3))


def parse_expire_input(text):
    raw = (text or "").strip()
    if raw == "0":
        return "0"
    try:
        return datetime.date.fromisoformat(raw).isoformat()
    except ValueError:
        return None


def parse_reset_day_input(text):
    raw = (text or "").strip()
    if raw in {"0", "32"}:
        return int(raw)
    if re.fullmatch(r"\d+", raw):
        value = int(raw)
        if 1 <= value <= 29:
            return value
    return None


def create_admin_confirmation(chat_id, tg_id, text, action, vps_id, username, params, back_data, message_id=None):
    token = secrets.token_urlsafe(6)
    with cfg_lock():
        cfg = load_config()
        pending = cfg.setdefault("pending_admin_actions", {})
        pending[token] = {
            "tg_user_id": str(tg_id),
            "chat_id": chat_id,
            "action": action,
            "vps_id": vps_id,
            "username": username,
            "params": params or {},
            "back_data": back_data,
            "expires_at": int(time.time()) + 300,
        }
        save_config_unlocked(cfg)
    keyboard = [[
        {"text": "确认执行", "callback_data": f"a:confirm:{token}"},
        {"text": "取消", "callback_data": back_data},
    ]]
    render_page(chat_id, text, keyboard, message_id)


def create_task_from_confirmation(chat_id, tg_id, token, message_id=None):
    with cfg_lock():
        cfg = load_config()
        pending = cfg.setdefault("pending_admin_actions", {})
        action = pending.pop(token, None)
        if not action or str(action.get("tg_user_id")) != str(tg_id) or int(action.get("expires_at") or 0) < int(time.time()):
            save_config_unlocked(cfg)
            render_page(chat_id, "确认已失效，请重新操作。", back_keyboard("a:home"), message_id)
            return
        task_id = secrets.token_urlsafe(8)
        tasks = cfg.setdefault("tasks", {})
        tasks[task_id] = {
            "id": task_id,
            "status": "pending",
            "created_at": int(time.time()),
            "created_by": str(tg_id),
            "created_chat_id": chat_id,
            "action": action.get("action"),
            "vps_id": action.get("vps_id"),
            "username": action.get("username"),
            "params": action.get("params") or {},
            "attempts": 0,
        }
        save_config_unlocked(cfg)
    render_page(chat_id, "任务已提交，等待节点执行，通常 10 秒内完成。", None, message_id)


def start_waiting_input(chat_id, tg_id, action, vps_id, idx, username, prompt, message_id=None):
    with cfg_lock():
        cfg = load_config()
        waiting = cfg.setdefault("waiting_inputs", {})
        waiting[str(tg_id)] = {
            "action": action,
            "vps_id": vps_id,
            "idx": idx,
            "username": username,
            "expires_at": int(time.time()) + 300,
        }
        save_config_unlocked(cfg)
    render_page(chat_id, prompt, back_keyboard(f"a:user:{vps_id}:{idx}"), message_id)


def handle_waiting_input(chat_id, tg_id, text):
    cfg = load_config()
    waiting = (cfg.get("waiting_inputs") or {}).get(str(tg_id))
    if not waiting or not is_admin(cfg, tg_id):
        return False
    if int(waiting.get("expires_at") or 0) < int(time.time()):
        clear_waiting_input(tg_id)
        send_message(chat_id, "输入已超时，请重新操作。")
        return True
    action = waiting.get("action")
    vps_id = waiting.get("vps_id")
    idx = int(waiting.get("idx") or 0)
    username = waiting.get("username")
    back_data = f"a:user:{vps_id}:{idx}"
    report, user = find_report_user_by_index(cfg, vps_id, idx)
    title = f"{vps_id} / {username}" if not report or not user else report_user_title(report, vps_id, user)
    if action == "set_quota":
        quota = parse_quota_input(text)
        if quota is None:
            send_message(chat_id, "输入无效，请输入数字，例如 300；输入 0 表示不限。")
            return True
        clear_waiting_input(tg_id)
        create_admin_confirmation(chat_id, tg_id, "\n".join([
            f"确认将 {title}",
            f"套餐改为 {quota_text(quota)}？",
        ]), "set_quota", vps_id, username, {"quota_gb": quota}, back_data)
        return True
    if action == "renew":
        months = parse_months_input(text)
        if months is None:
            send_message(chat_id, "输入无效，请输入需要续期的月数，例如 2。")
            return True
        if not user:
            send_message(chat_id, "用户状态已变化，请重新操作。")
            clear_waiting_input(tg_id)
            return True
        confirm_text = renew_confirm_text(report, vps_id, user, months)
        if confirm_text is None:
            send_message(chat_id, "永久用户无需续期。")
            clear_waiting_input(tg_id)
            return True
        clear_waiting_input(tg_id)
        create_admin_confirmation(chat_id, tg_id, confirm_text, "renew", vps_id, username, {"months": months}, back_data)
        return True
    if action == "add_usage":
        bytes_value = parse_traffic_input(text)
        if bytes_value is None:
            send_message(chat_id, "输入无效，请输入数字，单位G，最多1位小数。例如 +10.1 或 -5.5。")
            return True
        clear_waiting_input(tg_id)
        lines = []
        if user:
            lines += usage_summary(user) + [""]
        lines += [
            f"补正变化：{signed_gb_text(bytes_value)}",
            "",
            f"确认给 {title}",
            "补正流量？",
        ]
        create_admin_confirmation(chat_id, tg_id, "\n".join(lines), "add_usage", vps_id, username, {"bytes": bytes_value}, back_data)
        return True
    if action == "set_expire":
        expire_at = parse_expire_input(text)
        if expire_at is None:
            send_message(chat_id, "输入无效，请输入 YYYY-MM-DD，或输入 0 表示永久。")
            return True
        clear_waiting_input(tg_id)
        current = expire_display(user.get("expire_at") if user else "")
        new_value = expire_display(expire_at)
        create_admin_confirmation(chat_id, tg_id, "\n".join([
            f"当前到期：{current}",
            f"修改后：{new_value}",
            "",
            f"确认修改 {title}",
            "的到期时间？",
        ]), "set_expire", vps_id, username, {"expire_at": expire_at}, back_data)
        return True
    if action == "set_reset_day":
        reset_day = parse_reset_day_input(text)
        if reset_day is None:
            send_message(chat_id, "输入无效，请输入 0、1-29 或 32。")
            return True
        clear_waiting_input(tg_id)
        current = reset_day_text(user.get("reset_day") if user else 0)
        new_value = reset_day_text(reset_day)
        create_admin_confirmation(chat_id, tg_id, "\n".join([
            f"当前重置日期：{current}",
            f"修改后：{new_value}",
            "",
            f"确认修改 {title}",
            "的重置日期？",
        ]), "set_reset_day", vps_id, username, {"reset_day": reset_day}, back_data)
        return True
    clear_waiting_input(tg_id)
    return False


def handle_message(msg):
    text = msg.get("text") or ""
    chat = msg.get("chat") or {}
    user = msg.get("from") or {}
    chat_id = chat.get("id")
    tg_id = user.get("id")
    if not chat_id or not tg_id:
        return
    if handle_waiting_input(chat_id, tg_id, text):
        return
    if text.startswith("/start"):
        parts = text.split(maxsplit=1)
        if len(parts) == 2 and parts[1].startswith("bind_"):
            bind_token(chat_id, tg_id, parts[1][5:])
        else:
            send_home(chat_id, tg_id)
    else:
        send_home(chat_id, tg_id)


def handle_callback(cb):
    data = cb.get("data") or ""
    msg = cb.get("message") or {}
    chat_id = (msg.get("chat") or {}).get("id")
    message_id = msg.get("message_id")
    user = cb.get("from") or {}
    tg_id = user.get("id")
    if not chat_id or not tg_id:
        return
    if cb.get("id"):
        answer_callback(cb.get("id"))
    cfg = load_config()
    admin = is_admin(cfg, tg_id)
    if data == "u:home":
        clear_waiting_input(tg_id)
        send_home(chat_id, tg_id, message_id)
    elif data == "u:notify":
        clear_waiting_input(tg_id)
        notify_settings(chat_id, tg_id, message_id=message_id)
    elif data == "u:toggle_notify":
        clear_waiting_input(tg_id)
        toggle_notify(chat_id, tg_id, message_id=message_id)
    elif data == "u:bind":
        clear_waiting_input(tg_id)
        binding_list(chat_id, tg_id, message_id)
    elif data.startswith("u:detail:"):
        clear_waiting_input(tg_id)
        user_detail(chat_id, tg_id, int(data.rsplit(":", 1)[1]), message_id)
    elif data.startswith("u:ask_unbind:"):
        clear_waiting_input(tg_id)
        ask_unbind(chat_id, tg_id, int(data.rsplit(":", 1)[1]), message_id)
    elif data.startswith("u:do_unbind:"):
        clear_waiting_input(tg_id)
        do_unbind(chat_id, tg_id, int(data.rsplit(":", 1)[1]), message_id)
    elif admin and data == "a:home":
        clear_waiting_input(tg_id)
        send_home(chat_id, tg_id, message_id)
    elif admin and data == "a:notify":
        clear_waiting_input(tg_id)
        notify_settings(chat_id, tg_id, admin=True, message_id=message_id)
    elif admin and data == "a:toggle_notify":
        clear_waiting_input(tg_id)
        toggle_notify(chat_id, tg_id, admin=True, message_id=message_id)
    elif admin and data.startswith("a:vps:"):
        clear_waiting_input(tg_id)
        admin_vps(chat_id, data.split(":", 2)[2], message_id)
    elif admin and data.startswith("a:user:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        admin_user_detail(chat_id, vps_id, int(idx), message_id)
    elif admin and data.startswith("a:toggle:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            target = not bool(user.get("enabled") is True)
            word = "启用" if target else "停用"
            create_admin_confirmation(chat_id, tg_id, f"确认{word}用户 {report.get('vps_name') or vps_id} / {user.get('username')}？", "set_enabled", vps_id, user.get("username"), {"enabled": target}, f"a:user:{vps_id}:{idx}", message_id)
    elif admin and data.startswith("a:renew_menu:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        admin_renew_menu(chat_id, vps_id, int(idx), message_id)
    elif admin and data.startswith("a:renew:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx, months = data.split(":", 4)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            confirm_text = renew_confirm_text(report, vps_id, user, int(months))
            if confirm_text is None:
                render_page(chat_id, "永久用户无需续期。", back_keyboard(f"a:user:{vps_id}:{idx}"), message_id)
            else:
                create_admin_confirmation(chat_id, tg_id, confirm_text, "renew", vps_id, user.get("username"), {"months": int(months)}, f"a:user:{vps_id}:{idx}", message_id)
    elif admin and data.startswith("a:renew_custom:"):
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            start_waiting_input(chat_id, tg_id, "renew", vps_id, idx, user.get("username"), "请输入需要续期的月数，例如 2。", message_id)
    elif admin and data.startswith("a:quota_menu:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        admin_quota_menu(chat_id, vps_id, int(idx), message_id)
    elif admin and data.startswith("a:quota:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx, quota = data.split(":", 4)
        idx = int(idx)
        quota = int(quota)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            create_admin_confirmation(chat_id, tg_id, "\n".join([
                f"确认将 {report_user_title(report, vps_id, user)}",
                f"套餐改为 {quota_text(quota)}？",
            ]), "set_quota", vps_id, user.get("username"), {"quota_gb": quota}, f"a:user:{vps_id}:{idx}", message_id)
    elif admin and data.startswith("a:quota_custom:"):
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            start_waiting_input(chat_id, tg_id, "set_quota", vps_id, idx, user.get("username"), "\n".join([
                "折算成单向流量填入。",
                "双向800G流量填写400。",
                "单向500G流量填写500。",
                "",
                "请输入新的套餐流量，0 表示不限。",
            ]), message_id)
    elif admin and data.startswith("a:more:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        admin_more_menu(chat_id, vps_id, int(idx), message_id)
    elif admin and data.startswith("a:reset:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            create_admin_confirmation(chat_id, tg_id, "\n".join(
                usage_summary(user) + [
                    "",
                    f"确认重置 {report_user_title(report, vps_id, user)}",
                    "的流量？",
                ]
            ), "reset_usage", vps_id, user.get("username"), {}, f"a:user:{vps_id}:{idx}", message_id)
    elif admin and data.startswith("a:add_usage:"):
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            start_waiting_input(chat_id, tg_id, "add_usage", vps_id, idx, user.get("username"), "\n".join(
                usage_summary(user) + [
                    "",
                    "单位G，精确到小数点后1位",
                    "例如 +10.1 或 -5.5",
                    "",
                    "请输入补正流量：",
                ]
            ), message_id)
    elif admin and data.startswith("a:expire_set:"):
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            start_waiting_input(chat_id, tg_id, "set_expire", vps_id, idx, user.get("username"), "\n".join([
                f"当前到期：{expire_display(user.get('expire_at') or '0')}",
                "",
                "请输入新的到期日期：",
                "YYYY-MM-DD，输入 0 表示永久。",
            ]), message_id)
    elif admin and data.startswith("a:reset_day_set:"):
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            start_waiting_input(chat_id, tg_id, "set_reset_day", vps_id, idx, user.get("username"), "\n".join([
                f"当前重置日期：{reset_day_text(user.get('reset_day') or 0)}",
                "0. 不重置",
                "1-29. 指定日期",
                "32. 月底",
                "请输入重置日期：",
            ]), message_id)
    elif admin and data.startswith("a:confirm:"):
        clear_waiting_input(tg_id)
        create_task_from_confirmation(chat_id, tg_id, data.rsplit(":", 1)[1], message_id)
    else:
        clear_waiting_input(tg_id)
        send_home(chat_id, tg_id, message_id)


def process_updates():
    offset = None
    while True:
        payload = {"timeout": 25}
        if offset is not None:
            payload["offset"] = offset
        resp = bot_api("getUpdates", payload)
        for upd in resp.get("result") or []:
            offset = max(offset or 0, int(upd.get("update_id", 0)) + 1)
            if "message" in upd:
                handle_message(upd["message"])
            elif "callback_query" in upd:
                handle_callback(upd["callback_query"])
        time.sleep(1)


def authorized(handler):
    secret = load_config().get("access_secret") or ""
    got = handler.headers.get("X-SB-TG-Secret", "")
    return secret and got == secret


def read_json(handler):
    length = int(handler.headers.get("Content-Length") or 0)
    body = handler.rfile.read(length) if length > 0 else b"{}"
    return json.loads(body.decode("utf-8") or "{}")


def write_json(handler, code, payload):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def evaluate_reminders(cfg, report):
    threshold = int(cfg.get("notify_threshold") or 90)
    expire_days = int(cfg.get("expire_warn_days") or 3)
    notify_state = cfg.setdefault("notify_state", {})
    settings = cfg.setdefault("user_settings", {})
    changed = False
    users_by_name = {u.get("username"): u for u in report.get("users") or []}
    for b in cfg.get("bindings") or []:
        if b.get("active") is False or b.get("vps_id") != report.get("vps_id"):
            continue
        tg_id = str(b.get("tg_user_id"))
        if not settings.get(tg_id, {"notify": True}).get("notify", True):
            continue
        user = users_by_name.get(b.get("username"))
        if not user:
            continue
        if user.get("disabled_reason") == "manual":
            continue
        title = f"{report.get('vps_name')} / {b.get('username')}"
        total = user_total(user)
        quota = int(user.get("quota_gb") or 0)
        if quota > 0:
            ratio = int(total * 100 / (quota * 1024 ** 3))
            if ratio >= threshold:
                period = user.get("last_reset_period") or today().strftime("%Y-%m")
                key = f"{tg_id}:{report.get('vps_id')}:{b.get('username')}:traffic:{threshold}:{period}"
                if not notify_state.get(key):
                    send_message(b.get("chat_id"), f"{title}\n流量已使用 {ratio}%，请留意。")
                    notify_state[key] = int(time.time())
                    changed = True
        exp = parse_date(user.get("expire_at") or "0")
        if exp is not None:
            days = (exp - today()).days
            if 1 <= days <= expire_days:
                key = f"{tg_id}:{report.get('vps_id')}:{b.get('username')}:expire:{exp.isoformat()}:{days}"
                if not notify_state.get(key):
                    send_message(b.get("chat_id"), f"{title}\n距离到期还有 {days} 天。")
                    notify_state[key] = int(time.time())
                    changed = True
            elif days <= 0 and user.get("disabled_reason") == "expired":
                key = f"{tg_id}:{report.get('vps_id')}:{b.get('username')}:expired:{exp.isoformat()}"
                if not notify_state.get(key):
                    send_message(b.get("chat_id"), f"{title}\n用户已到期。")
                    notify_state[key] = int(time.time())
                    changed = True
    return changed


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        if not authorized(self):
            write_json(self, 403, {"ok": False, "error": "forbidden"})
            return
        try:
            payload = read_json(self)
        except Exception:
            write_json(self, 400, {"ok": False, "error": "bad_json"})
            return

        if self.path == "/api/report":
            with cfg_lock():
                cfg = load_config()
                reports = cfg.setdefault("reports", {})
                payload["received_at"] = int(time.time())
                payload["received_at_text"] = (datetime.datetime.utcnow() + datetime.timedelta(hours=8)).strftime("%Y-%m-%d %H:%M:%S")
                payload["updated_at_text"] = payload.get("data_updated_at_text") or ""
                reports[payload.get("vps_id") or "unknown"] = payload
                changed = evaluate_reminders(cfg, payload)
                if changed:
                    save_config_unlocked(cfg)
                else:
                    save_config_unlocked(cfg)
            write_json(self, 200, {"ok": True})
            return

        if self.path == "/api/tasks/poll":
            vps_id = payload.get("vps_id") or ""
            if not vps_id:
                write_json(self, 400, {"ok": False, "error": "vps_id_missing"})
                return
            now = int(time.time())
            available = []
            expired_notifications = []
            with cfg_lock():
                cfg = load_config()
                tasks = cfg.setdefault("tasks", {})
                for task_id in list(tasks.keys()):
                    task = tasks[task_id]
                    if task.get("status") in {"success", "failed"} and now - int(task.get("completed_at") or now) > 86400:
                        tasks.pop(task_id, None)
                for task_id, task in tasks.items():
                    if task.get("vps_id") != vps_id:
                        continue
                    status = task.get("status")
                    picked_at = int(task.get("picked_at") or 0)
                    attempts = int(task.get("attempts") or 0)
                    if status == "running" and picked_at and now - picked_at > 120 and attempts >= 3:
                        message = "节点超过重试次数仍未回传结果，任务已停止重试。"
                        task["status"] = "failed"
                        task["message"] = message
                        task["completed_at"] = now
                        expired_notifications.append((
                            task.get("created_chat_id"),
                            f"{vps_id} / {task.get('username') or ''}".strip(" /"),
                            message,
                        ))
                        continue
                    runnable = status == "pending" or (status == "running" and now - picked_at > 120 and attempts < 3)
                    if not runnable:
                        continue
                    task["status"] = "running"
                    task["picked_at"] = now
                    task["attempts"] = attempts + 1
                    available.append({
                        "id": task_id,
                        "action": task.get("action"),
                        "username": task.get("username"),
                        "params": task.get("params") or {},
                    })
                save_config_unlocked(cfg)
            for chat_id, title, message in expired_notifications:
                if chat_id:
                    send_message(chat_id, f"执行失败：{title}\n{message}")
            write_json(self, 200, {"ok": True, "tasks": available})
            return

        if self.path == "/api/tasks/result":
            task_id = payload.get("task_id") or ""
            vps_id = payload.get("vps_id") or ""
            ok_value = bool(payload.get("ok"))
            message = payload.get("message") or ("执行成功" if ok_value else "执行失败")
            with cfg_lock():
                cfg = load_config()
                task = (cfg.setdefault("tasks", {})).get(task_id)
                if not task or task.get("vps_id") != vps_id:
                    write_json(self, 404, {"ok": False, "error": "task_not_found"})
                    return
                task["status"] = "success" if ok_value else "failed"
                task["message"] = message
                task["completed_at"] = int(time.time())
                chat_id = task.get("created_chat_id")
                tg_id = task.get("created_by")
                username = task.get("username") or ""
                save_config_unlocked(cfg)
            if chat_id:
                title = f"{vps_id} / {username}".strip(" /")
                prefix = "执行成功" if ok_value else "执行失败"
                send_message(chat_id, f"{prefix}：{title}\n{message}")
                if ok_value and tg_id:
                    send_home(chat_id, tg_id)
            write_json(self, 200, {"ok": True})
            return

        if self.path == "/api/bind-token":
            with cfg_lock():
                cfg = load_config()
                token = secrets.token_urlsafe(8)
                pending = cfg.setdefault("pending_bind_tokens", {})
                pending[token] = {
                    "vps_id": payload.get("vps_id"),
                    "vps_name": payload.get("vps_name"),
                    "username": payload.get("username"),
                    "expires_at": int(time.time()) + 600,
                }
                username = get_bot_username(cfg)
                save_config_unlocked(cfg)
            if not username:
                write_json(self, 500, {"ok": False, "error": "bot_username_missing"})
            else:
                write_json(self, 200, {"ok": True, "link": f"https://t.me/{username}?start=bind_{token}"})
            return

        if self.path == "/api/test":
            cfg = load_config()
            errors = []
            admin_ids = cfg.get("admin_chat_ids") or []
            if not admin_ids:
                errors.append("管理员 TG ID 未配置")
            for chat_id in admin_ids:
                resp = send_message(chat_id, f"通知测试成功：{payload.get('vps_name') or payload.get('vps_id') or '主控节点'}")
                if not resp.get("ok"):
                    errors.append(resp.get("description") or "sendMessage failed")
            write_json(self, 200, {"ok": len(errors) == 0, "errors": errors})
            return

        write_json(self, 404, {"ok": False, "error": "not_found"})


def run_http():
    cfg = load_config()
    host = cfg.get("listen_host") or "0.0.0.0"
    port = int(cfg.get("listen_port") or 25888)
    server = http.server.ThreadingHTTPServer((host, port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    threading.Thread(target=process_updates, daemon=True).start()
    run_http()
PY
  chmod 700 "$TG_CENTER_APP" >/dev/null 2>&1 || true
}

tg_install_center_service() {
  tg_require_python3 || return 1
  tg_write_center_app || return 1
  case "$INIT_SYSTEM" in
    systemd)
      cat > "/etc/systemd/system/${TG_CENTER_SERVICE}.service" <<EOF
[Unit]
Description=Sing-box Telegram Bot Center
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 ${TG_CENTER_APP} ${TG_CONFIG_FILE}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable "$TG_CENTER_SERVICE" >/dev/null 2>&1 || true
      systemctl restart "$TG_CENTER_SERVICE"
      ;;
    openrc)
      cat > "/etc/init.d/${TG_CENTER_SERVICE}" <<EOF
#!/sbin/openrc-run
description="Sing-box Telegram Bot Center"
command="/usr/bin/env"
command_args="python3 ${TG_CENTER_APP} ${TG_CONFIG_FILE}"
command_background=true
pidfile="/run/${TG_CENTER_SERVICE}.pid"
depend() {
  need net
}
EOF
      chmod +x "/etc/init.d/${TG_CENTER_SERVICE}"
      openrc_enable_service "$TG_CENTER_SERVICE" default >/dev/null 2>&1 || true
      rc-service "$TG_CENTER_SERVICE" restart
      ;;
    *)
      err "未识别的 init 系统，无法安装主控服务。"
      return 1
      ;;
  esac
}

tg_stop_center_service() {
  case "$INIT_SYSTEM" in
    systemd)
      systemctl stop "$TG_CENTER_SERVICE" >/dev/null 2>&1 || true
      systemctl disable "$TG_CENTER_SERVICE" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/${TG_CENTER_SERVICE}.service" >/dev/null 2>&1 || true
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      openrc_stop_service "$TG_CENTER_SERVICE" >/dev/null 2>&1 || true
      openrc_disable_service "$TG_CENTER_SERVICE" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/${TG_CENTER_SERVICE}" >/dev/null 2>&1 || true
      ;;
  esac
}

install_tg_agent_cron() {
  # 6.0.9 起 TG 上报已合并到 periodic-sync cron，无需独立 cron。
  # 函数保留为 no-op 以保持现有调用点兼容；TG 是否上报由 enabled 标记 + tg_agent_sync 内部自检决定。
  return 0
}
remove_tg_agent_cron()  { _remove_cron_job "$TG_AGENT_CRON_MARK"; }

tg_collect_report_json() {
  local cfg="$1" db_json
  db_json="$(user_db_load)"
  echo "$db_json" | jq \
    --arg vps_id "$(echo "$cfg" | jq -r '.vps_id // ""')" \
    --arg vps_name "$(echo "$cfg" | jq -r '.vps_name // ""')" \
    '
      {
        vps_id: $vps_id,
        vps_name: $vps_name,
        data_updated_at_text: (.meta.data_updated_at_text // ""),
        updated_at_text: (.meta.data_updated_at_text // ""),
        users: [
          .users
          | to_entries[]
          | {
              username: .key,
              enabled: (.value.enabled // false),
              disabled_reason: (.value.disabled_reason // null),
              quota_gb: (.value.quota_gb // 0),
              used_up_bytes: (.value.used_up_bytes // 0),
              used_down_bytes: (.value.used_down_bytes // 0),
              manual_added_bytes: (.value.manual_added_bytes // 0),
              last_reset_period: (.value.last_reset_period // ""),
              reset_day: (.value.reset_day // 0),
              expire_at: (.value.expire_at // "0")
            }
        ]
      }
    '
}

tg_center_api_post() {
  local url="$1" secret="$2" path="$3" payload="$4"
  curl -sS --connect-timeout 10 --max-time 20 \
    -H "Content-Type: application/json" \
    -H "X-SB-TG-Secret: ${secret}" \
    -d "$payload" \
    "${url%/}${path}"
}

tg_post_report() {
  local cfg="$1" center_url="$2" secret="$3" payload resp
  payload="$(tg_collect_report_json "$cfg")" || return 1
  resp="$(tg_center_api_post "$center_url" "$secret" "/api/report" "$payload" 2>/dev/null)" || return 1
  echo "$resp" | jq -e '.ok == true' >/dev/null 2>&1
}

tg_post_task_result() {
  local center_url="$1" secret="$2" task_id="$3" vps_id="$4" ok_value="$5" message="$6" payload
  payload="$(jq -n \
    --arg task_id "$task_id" \
    --arg vps_id "$vps_id" \
    --arg message "$message" \
    --argjson ok "$ok_value" \
    '{task_id:$task_id,vps_id:$vps_id,ok:$ok,message:$message}')"
  tg_center_api_post "$center_url" "$secret" "/api/tasks/result" "$payload" >/dev/null 2>&1 || true
}

tg_poll_tasks() {
  local center_url="$1" secret="$2" vps_id="$3" payload resp
  payload="$(jq -n --arg vps_id "$vps_id" '{vps_id:$vps_id}')"
  resp="$(tg_center_api_post "$center_url" "$secret" "/api/tasks/poll" "$payload" 2>/dev/null)" || return 1
  echo "$resp" | jq -c '.tasks // []'
}

tg_task_apply_db() {
  local new_db="$1" json
  json="$(config_load)" || return 1
  _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes "$new_db" "$json" >/dev/null 2>&1
}

tg_task_exec_set_enabled() {
  local db_json="$1" username="$2" enabled="$3" new_db
  if [ "$enabled" = "true" ]; then
    new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = true | .users[$u].disabled_reason = null')" || return 1
    tg_task_apply_db "$new_db" && echo "用户已启用。"
  else
    new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = false | .users[$u].disabled_reason = "manual"')" || return 1
    tg_task_apply_db "$new_db" && echo "用户已停用。"
  fi
}

tg_task_exec_set_quota() {
  local db_json="$1" username="$2" quota="$3" new_db text
  [[ "$quota" =~ ^[0-9]+$ ]] || return 1
  new_db="$(echo "$db_json" | jq --arg u "$username" --argjson quota "$quota" '.users[$u].quota_gb = $quota')" || return 1
  if [ "$quota" = "0" ]; then text="不限"; else text="${quota}GB"; fi
  tg_task_apply_db "$new_db" && echo "套餐已修改为 ${text}。"
}

tg_task_exec_renew() {
  local db_json="$1" username="$2" months="$3" current_expire today base_date expired=0 new_expire new_db
  [[ "$months" =~ ^[0-9]+$ ]] && [ "$months" -ge 1 ] || return 1
  current_expire="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].expire_at // "0"')"
  [ "$current_expire" != "0" ] || { echo "永久用户无需续期。"; return 1; }
  today="$(user_today_date)"
  if user_expire_is_past "$today" "$current_expire"; then
    expired=1
    base_date="$today"
  else
    base_date="$current_expire"
  fi
  new_expire="$(user_date_add_months "$base_date" "$months")" || return 1
  new_db="$(echo "$db_json" | jq --arg u "$username" --arg exp "$new_expire" --argjson expired "$expired" '
    .users[$u].expire_at = $exp
    | if $expired == 1 then
        .users[$u].used_up_bytes = 0
        | .users[$u].used_down_bytes = 0
        | .users[$u].manual_added_bytes = 0
        | .users[$u].last_reset_period = ""
        | if (.users[$u].disabled_reason // null) == "manual" then .
          else .users[$u].enabled = true | .users[$u].disabled_reason = null
          end
      else
        if (.users[$u].disabled_reason // null) == "expired" then
          .users[$u].enabled = true | .users[$u].disabled_reason = null
        else . end
      end
  ')" || return 1
  tg_task_apply_db "$new_db" && echo "已续期至 ${new_expire}。"
}

tg_task_exec_reset_usage() {
  local db_json="$1" username="$2" new_db
  new_db="$(echo "$db_json" | jq --arg u "$username" '
    .users[$u].used_up_bytes = 0
    | .users[$u].used_down_bytes = 0
    | .users[$u].manual_added_bytes = 0
  ')" || return 1
  tg_task_apply_db "$new_db" && echo "流量已重置。"
}

tg_task_exec_add_usage() {
  local db_json="$1" username="$2" bytes="$3" new_db
  [[ "$bytes" =~ ^-?[0-9]+$ ]] || return 1
  new_db="$(echo "$db_json" | jq --arg u "$username" --argjson add "$bytes" '.users[$u].manual_added_bytes = ((.users[$u].manual_added_bytes // 0) + $add)')" || return 1
  tg_task_apply_db "$new_db" && echo "补正流量已更新：$(format_bytes_human "$bytes")。"
}

tg_task_exec_set_expire() {
  local db_json="$1" username="$2" expire_at="$3" today active new_db
  if [ "$expire_at" != "0" ] && ! is_valid_ymd_date "$expire_at"; then
    return 1
  fi
  today="$(user_today_date)"
  active=false
  if [ "$expire_at" = "0" ] || [[ "$today" < "$expire_at" ]]; then
    active=true
  fi
  new_db="$(echo "$db_json" | jq --arg u "$username" --arg exp "$expire_at" --argjson active "$active" '
    .users[$u].expire_at = $exp
    | if $active == true then
        if (.users[$u].disabled_reason // null) == "expired" then
          .users[$u].enabled = true | .users[$u].disabled_reason = null
        else . end
      else
        if (.users[$u].disabled_reason // null) == "manual" then .
        else .users[$u].enabled = false | .users[$u].disabled_reason = "expired"
        end
      end
  ')" || return 1
  tg_task_apply_db "$new_db" && echo "到期时间已修改为 $(expire_text "$expire_at")。"
}

tg_task_exec_set_reset_day() {
  local db_json="$1" username="$2" reset_day="$3" new_db
  [[ "$reset_day" =~ ^[0-9]+$ ]] || return 1
  if [ "$reset_day" != "0" ] && [ "$reset_day" != "32" ] && { [ "$reset_day" -lt 1 ] || [ "$reset_day" -gt 29 ]; }; then
    return 1
  fi
  new_db="$(echo "$db_json" | jq --arg u "$username" --argjson reset "$reset_day" '
    (.users[$u].reset_day // 0) as $old_reset
    | .users[$u].reset_day = $reset
    | if ($old_reset != $reset) then .users[$u].last_reset_period = "" else . end
  ')" || return 1
  tg_task_apply_db "$new_db" && echo "重置日期已修改为 $(reset_day_text "$reset_day")。"
}

tg_execute_task() {
  with_manager_lock _tg_execute_task_body "$@"
}

_tg_execute_task_body() {
  local task="$1" action username db_json exists params result
  action="$(echo "$task" | jq -r '.action // empty')"
  username="$(echo "$task" | jq -r '.username // empty')"
  [ -n "$action" ] && [ -n "$username" ] || { echo "任务参数不完整。"; return 1; }
  user_db_exists || { echo "用户数据库不存在。"; return 1; }
  sync_user_usage_counters || return 1
  db_json="$(user_db_load)"
  exists="$(echo "$db_json" | jq -r --arg u "$username" 'if .users[$u] then "1" else "0" end')"
  [ "$exists" = "1" ] || { echo "用户不存在：$username"; return 1; }
  params="$(echo "$task" | jq -c '.params // {}')"
  case "$action" in
    set_enabled)
      tg_task_exec_set_enabled "$db_json" "$username" "$(echo "$params" | jq -r '.enabled // false')" ;;
    set_quota)
      tg_task_exec_set_quota "$db_json" "$username" "$(echo "$params" | jq -r '.quota_gb // empty')" ;;
    renew)
      tg_task_exec_renew "$db_json" "$username" "$(echo "$params" | jq -r '.months // empty')" ;;
    reset_usage)
      tg_task_exec_reset_usage "$db_json" "$username" ;;
    add_usage)
      tg_task_exec_add_usage "$db_json" "$username" "$(echo "$params" | jq -r '.bytes // empty')" ;;
    set_expire)
      tg_task_exec_set_expire "$db_json" "$username" "$(echo "$params" | jq -r '.expire_at // empty')" ;;
    set_reset_day)
      tg_task_exec_set_reset_day "$db_json" "$username" "$(echo "$params" | jq -r '.reset_day // empty')" ;;
    *)
      echo "不支持的任务类型：$action"
      return 1
      ;;
  esac
}

tg_process_tasks() {
  local cfg="$1" center_url="$2" secret="$3" vps_id="$4" tasks task task_id msg ok_value receipt receipt_status
  TG_TASKS_REPORTED_STATE=0
  tasks="$(tg_poll_tasks "$center_url" "$secret" "$vps_id")" || return 0
  echo "$tasks" | jq -e 'length > 0' >/dev/null 2>&1 || return 0
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    task_id="$(echo "$task" | jq -r '.id // empty')"
    [ -n "$task_id" ] || continue

    receipt="$(tg_task_receipt_get "$task_id" 2>/dev/null || true)"
    receipt_status="$(echo "${receipt:-}" | jq -r '.status // ""' 2>/dev/null || true)"

    if [ "$receipt_status" = "done" ]; then
      # 历史已完成任务：只重发结果，不再执行
      ok_value="$(echo "$receipt" | jq -r 'if (.ok // false) then "true" else "false" end')"
      msg="$(echo "$receipt" | jq -r '.message // "执行成功。"')"
    elif [ "$receipt_status" = "running" ]; then
      # 上一次执行后崩在落盘前；为安全起见不重复执行，标记失败让主控判断
      ok_value=false
      msg="任务上一次执行未完整落盘，已拒绝重复执行，请人工确认。"
      tg_task_receipt_finalize "$task_id" false "$msg" >/dev/null 2>&1 || true
    else
      # 新任务：先预留 receipt 占位，预留失败就拒绝执行（保证落盘可查）
      if ! tg_task_receipt_reserve "$task_id" >/dev/null 2>&1; then
        # 预留失败说明本地存储不可用，跳过本轮，等下次 poll 重试
        continue
      fi
      if msg="$(tg_execute_task "$task" 2>&1)"; then
        ok_value=true
      else
        ok_value=false
        [ -n "$msg" ] || msg="执行失败。"
      fi
      # 落盘最终结果；落盘失败时绝不上报成功
      if ! tg_task_receipt_finalize "$task_id" "$ok_value" "$msg" >/dev/null 2>&1; then
        warn "任务回执落盘失败：$task_id（不上报，等待下次重试）"
        continue
      fi
      if [ "$ok_value" = "true" ]; then
        tg_prepare_report_state
        if tg_post_report "$cfg" "$center_url" "$secret"; then
          TG_TASKS_REPORTED_STATE=1
        fi
      fi
    fi

    tg_post_task_result "$center_url" "$secret" "$task_id" "$vps_id" "$ok_value" "$msg"
  done < <(echo "$tasks" | jq -c '.[]')
}

tg_prepare_report_state() {
  if user_manager_reconcile_user_state >/dev/null 2>&1; then
    return 0
  fi
  sync_user_usage_counters >/dev/null 2>&1 || true
}

tg_agent_sync_once() {
  local cfg enabled role center_url secret vps_id
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  [ "$enabled" = "true" ] || return 1
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$role" = "center" ] || [ "$role" = "agent" ] || return 1
  user_db_exists || return 1
  if [ "$role" = "center" ]; then
    center_url="http://127.0.0.1:$(echo "$cfg" | jq -r '.listen_port // 25888')"
  else
    center_url="$(echo "$cfg" | jq -r '.center_url // empty')"
  fi
  secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  vps_id="$(echo "$cfg" | jq -r '.vps_id // empty')"
  [ -n "$center_url" ] && [ -n "$secret" ] || return 1
  [ -n "$vps_id" ] || return 1
  tg_process_tasks "$cfg" "$center_url" "$secret" "$vps_id" || true
  if [ "${TG_TASKS_REPORTED_STATE:-0}" != "1" ]; then
    tg_prepare_report_state
    tg_post_report "$cfg" "$center_url" "$secret" || return 1
  fi
}

tg_agent_poll_tasks_once() {
  local cfg enabled role center_url secret vps_id
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  [ "$enabled" = "true" ] || return 1
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$role" = "center" ] || [ "$role" = "agent" ] || return 1
  user_db_exists || return 1
  if [ "$role" = "center" ]; then
    center_url="http://127.0.0.1:$(echo "$cfg" | jq -r '.listen_port // 25888')"
  else
    center_url="$(echo "$cfg" | jq -r '.center_url // empty')"
  fi
  secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  vps_id="$(echo "$cfg" | jq -r '.vps_id // empty')"
  [ -n "$center_url" ] && [ -n "$secret" ] && [ -n "$vps_id" ] || return 1
  tg_process_tasks "$cfg" "$center_url" "$secret" "$vps_id" || true
}

tg_agent_sync_now() {
  local cfg lock_fd lock_dir i rc=1
  cfg="$(tg_config_load)"
  tg_config_is_enabled "$cfg" || return 1
  mkdir -p "$(dirname "$TG_AGENT_LOCK_FILE")" 2>/dev/null || true
  if has_cmd flock && { exec {lock_fd}>"$TG_AGENT_LOCK_FILE"; } 2>/dev/null; then
    if ! flock -w 5 "$lock_fd"; then
      { exec {lock_fd}>&-; } 2>/dev/null || true
      return 1
    fi
  else
    lock_fd=""
    lock_dir="${TG_AGENT_LOCK_FILE}.d"
    if ! mkdir "$lock_dir" 2>/dev/null; then
      sleep 1
      mkdir "$lock_dir" 2>/dev/null || return 1
    fi
  fi
  for i in 1 2 3; do
    if tg_agent_sync_once; then
      rc=0
      break
    fi
    sleep 1
  done
  if [ -n "$lock_fd" ]; then
    { exec {lock_fd}>&-; } 2>/dev/null || true
  else
    rmdir "${TG_AGENT_LOCK_FILE}.d" 2>/dev/null || true
  fi
  return $rc
}

tg_agent_sync() {
  local cfg lock_fd lock_dir i
  cfg="$(tg_config_load)"
  tg_config_is_enabled "$cfg" || return 0
  mkdir -p "$(dirname "$TG_AGENT_LOCK_FILE")" 2>/dev/null || true
  if has_cmd flock && { exec {lock_fd}>"$TG_AGENT_LOCK_FILE"; } 2>/dev/null; then
    flock -n "$lock_fd" || { exec {lock_fd}>&-; return 0; }
  else
    lock_fd=""
    lock_dir="${TG_AGENT_LOCK_FILE}.d"
    mkdir "$lock_dir" 2>/dev/null || return 0
  fi
  for i in 1 2 3 4 5 6; do
    if [ "$i" = "1" ]; then
      tg_agent_sync_once >/dev/null 2>&1 || true
    else
      tg_agent_poll_tasks_once >/dev/null 2>&1 || true
    fi
    [ "$i" -lt 6 ] && sleep 10
  done
  [ -n "${lock_fd:-}" ] && exec {lock_fd}>&-
  [ -n "${lock_dir:-}" ] && rmdir "$lock_dir" 2>/dev/null || true
}

tg_refresh_after_singbox_install() {
  local cfg enabled role
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$enabled" = "true" ] || return 0
  [ "$role" = "center" ] || [ "$role" = "agent" ] || return 0

  if [ "$role" = "center" ]; then
    if ! tg_install_center_service; then
      warn "TG Bot 服务刷新失败，请稍后进入 TG Bot 管理检查。"
      return 0
    fi
  fi
  install_tg_agent_cron >/dev/null 2>&1 || warn "TG Bot 上报任务刷新失败。"
  if tg_agent_sync_now; then
    ok "TG Bot 已刷新，本机数据已立即上报。"
  else
    warn "TG Bot 已刷新，但本机立即上报失败，定时任务会继续自动上报。"
  fi
}

tg_start_existing_config() {
  local cfg role
  cfg="$(tg_config_load)"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$role" = "center" ] || [ "$role" = "agent" ] || { warn "未找到可启动的 TG Bot 配置。"; return 1; }
  if [ "$role" = "center" ]; then
    tg_install_center_service || { err "主控服务启动失败。"; return 1; }
  fi
  install_tg_agent_cron || { err "TG 节点上报定时任务安装失败。"; return 1; }
  tg_config_merge_jq '.enabled = true' || { err "TG Bot 配置保存失败。"; return 1; }
  if tg_agent_sync_now; then
    ok "TG Bot 已启动，本机数据已立即上报。"
  else
    warn "TG Bot 已启动，但首次上报失败，请检查服务状态或稍后再试。"
  fi
}

tg_setup_center() {
  local cfg token admin_id port public_url secret vps_id vps_name username
  local cur_token cur_admin cur_port cur_vps_name cur_username
  cfg="$(tg_config_load)"
  cur_token="$(echo "$cfg" | jq -r '.bot_token // empty')"
  cur_admin="$(echo "$cfg" | jq -r '.admin_chat_ids[0] // empty')"
  cur_port="$(echo "$cfg" | jq -r '.listen_port // empty')"
  cur_vps_name="$(echo "$cfg" | jq -r '.vps_name // empty')"
  cur_username="$(echo "$cfg" | jq -r '.bot_username // empty')"

  # Bot Token（敏感字段不显示当前值）
  if [ -n "$cur_token" ]; then
    read -r -p "Bot Token（回车保持当前值）: " token
    [ -n "$token" ] || token="$cur_token"
  else
    read -r -p "Bot Token（回车返回）: " token
    [ -n "$token" ] || { warn "Bot Token 不能为空。"; pause; return 1; }
  fi

  # 管理员 TG ID（敏感字段不显示当前值）
  if [ -n "$cur_admin" ]; then
    read -r -p "管理员 TG ID（回车保持当前值）: " admin_id
    [ -n "$admin_id" ] || admin_id="$cur_admin"
  else
    read -r -p "管理员 TG ID（回车返回）: " admin_id
  fi
  [[ "$admin_id" =~ ^[0-9]+$ ]] || { warn "管理员 TG ID 必须是数字。"; pause; return 1; }

  # 主控监听端口（非敏感，显示当前值/默认值）
  if [ -n "$cur_port" ]; then
    read -r -p "主控监听端口（回车保持当前值: ${cur_port}）: " port
    port="${port:-$cur_port}"
  else
    read -r -p "主控监听端口（默认: 25888）: " port
    port="${port:-25888}"
  fi
  is_valid_port "$port" || { warn "端口无效。"; pause; return 1; }

  # 本机名称（非敏感，显示当前值）
  if [ -n "$cur_vps_name" ]; then
    read -r -p "本机名称（支持中文，回车保持当前值: ${cur_vps_name}）: " vps_name
    [ -n "$vps_name" ] || vps_name="$cur_vps_name"
  else
    read -r -p "本机名称（支持中文，回车返回）: " vps_name
    [ -n "$vps_name" ] || { warn "本机名称不能为空。"; pause; return 1; }
  fi

  public_url="$(tg_normalize_url "http://$(get_public_ip):${port}")"
  # Token 没变时复用已存的 bot_username，跳过在线校验 API
  if [ "$token" = "$cur_token" ] && [ -n "$cur_username" ]; then
    username="$cur_username"
  else
    username="$(tg_bot_username_from_token "$token")" || username=""
    [ -n "$username" ] || { warn "Bot Token 校验失败，无法获取 Bot 用户名。"; pause; return 1; }
  fi
  secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  [ -n "$secret" ] || secret="$(tg_generate_secret)"
  vps_id="$(echo "$cfg" | jq -r '.vps_id // empty')"
  [ -n "$vps_id" ] || vps_id="$(tg_generate_vps_id)"
  if ! _tg_setup_center_commit "$token" "$admin_id" "$port" "$public_url" "$secret" "$vps_id" "$vps_name" "$username"; then
    err "TG Bot 配置保存失败。"
    pause
    return 1
  fi
  tg_install_center_service || { err "主控服务安装失败。"; pause; return 1; }
  install_tg_agent_cron || warn "TG 节点上报定时任务安装失败。"
  if tg_agent_sync_now; then
    ok "本机数据已立即上报。"
  else
    warn "TG Bot 已配置，但首次上报失败，请检查服务状态或稍后再试。"
  fi
  ok "主控节点已配置。"
  param_echo "主控地址" "$public_url"
  param_echo "接入密钥" "$secret"
  param_echo "Bot 用户名" "@${username}"
  pause
}

tg_setup_agent() {
  local cfg center_url secret vps_id vps_name
  local cur_url cur_secret cur_vps_name
  cfg="$(tg_config_load)"
  cur_url="$(echo "$cfg" | jq -r '.center_url // empty')"
  cur_secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  cur_vps_name="$(echo "$cfg" | jq -r '.vps_name // empty')"

  # 主控地址（非敏感，显示当前值）
  if [ -n "$cur_url" ]; then
    read -r -p "主控地址（回车保持当前值: ${cur_url}）: " center_url
    [ -n "$center_url" ] || center_url="$cur_url"
  else
    read -r -p "主控地址（回车返回）: " center_url
  fi
  center_url="$(tg_normalize_url "$center_url")"
  [ -n "$center_url" ] || { warn "主控地址不能为空。"; pause; return 1; }

  # 接入密钥（敏感字段不显示当前值）
  if [ -n "$cur_secret" ]; then
    read -r -p "接入密钥（回车保持当前值）: " secret
    [ -n "$secret" ] || secret="$cur_secret"
  else
    read -r -p "接入密钥（回车返回）: " secret
    [ -n "$secret" ] || { warn "接入密钥不能为空。"; pause; return 1; }
  fi

  # 本机名称（非敏感，显示当前值）
  if [ -n "$cur_vps_name" ]; then
    read -r -p "本机名称（支持中文，回车保持当前值: ${cur_vps_name}）: " vps_name
    [ -n "$vps_name" ] || vps_name="$cur_vps_name"
  else
    read -r -p "本机名称（支持中文，回车返回）: " vps_name
    [ -n "$vps_name" ] || { warn "本机名称不能为空。"; pause; return 1; }
  fi

  vps_id="$(echo "$cfg" | jq -r '.vps_id // empty')"
  [ -n "$vps_id" ] || vps_id="$(tg_generate_vps_id)"
  if ! _tg_setup_agent_commit "$center_url" "$secret" "$vps_id" "$vps_name"; then
    err "TG Bot 配置保存失败。"
    pause
    return 1
  fi
  install_tg_agent_cron || { err "TG 节点上报定时任务安装失败。"; pause; return 1; }
  if tg_agent_sync_now; then
    ok "本机数据已立即上报。"
  else
    warn "已保存配置，但首次上报失败，请检查主控地址、接入密钥或防火墙。"
  fi
  ok "普通节点已配置。"
  pause
}

tg_setup_menu() {
  local cfg enabled role ans
  clear
  print_rect_title "设置/启动TG Bot"
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  if [ "$enabled" != "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; }; then
    read -r -p "检测到已保留配置，是否直接启动？[Y/n]: " ans
    case "${ans:-Y}" in
      [Nn]*) ;;
      *)
        tg_start_existing_config
        pause
        return
        ;;
    esac
  fi
  echo "  1. 主控节点"
  echo "  2. 普通节点"
  echo "  0. 返回上一级"
  read -r -p "请选择本机模式: " role
  case "${role:-}" in
    1) tg_setup_center ;;
    2) tg_setup_agent ;;
    0|q|Q|"") return 0 ;;
    *) warn "无效输入：$role"; pause ;;
  esac
}

tg_generate_bind_link_menu() {
  local cfg enabled role center_url secret db_json usernames=() ans username payload resp link
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$enabled" = "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; } || { warn "请先设置/启动TG Bot。"; pause; return 0; }
  user_db_exists || { warn "用户数据库不存在，请先安装并创建用户。"; pause; return 0; }
  db_json="$(user_db_load)"
  mapfile -t usernames < <(echo "$db_json" | jq -r '.users | keys[] | select(. != "admin")')
  [ ${#usernames[@]} -gt 0 ] || { warn "当前没有可绑定的普通用户。"; pause; return 0; }
  clear
  print_rect_title "生成绑定链接"
  local i=1
  for username in "${usernames[@]}"; do
    echo " [$i] $username"
    i=$((i+1))
  done
  read -r -p "请选择用户（回车返回上一级）: " ans
  [ -z "${ans:-}" ] && return 0
  if ! [[ "$ans" =~ ^[0-9]+$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt "${#usernames[@]}" ]; then
    warn "无效输入：$ans"
    pause
    return 0
  fi
  username="${usernames[$((ans-1))]}"
  if [ "$role" = "center" ]; then
    center_url="http://127.0.0.1:$(echo "$cfg" | jq -r '.listen_port // 25888')"
  else
    center_url="$(echo "$cfg" | jq -r '.center_url // empty')"
  fi
  secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  payload="$(echo "$cfg" | jq -n \
    --arg vps_id "$(echo "$cfg" | jq -r '.vps_id // empty')" \
    --arg vps_name "$(echo "$cfg" | jq -r '.vps_name // empty')" \
    --arg username "$username" \
    '{vps_id:$vps_id,vps_name:$vps_name,username:$username}')"
  resp="$(tg_center_api_post "$center_url" "$secret" "/api/bind-token" "$payload" 2>/dev/null || true)"
  link="$(echo "$resp" | jq -r '.link // empty' 2>/dev/null || true)"
  if [ -n "$link" ]; then
    ok "绑定链接已生成，有效期 10 分钟。"
    param_echo "用户" "$username"
    param_echo "链接" "$link"
  else
    err "绑定链接生成失败，请检查主控服务和接入密钥。"
  fi
  pause
}

tg_notify_test() {
  local cfg enabled role center_url secret payload resp ok_value err_msg
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$enabled" = "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; } || { warn "请先设置/启动TG Bot。"; pause; return 0; }
  if [ "$role" = "center" ]; then
    center_url="http://127.0.0.1:$(echo "$cfg" | jq -r '.listen_port // 25888')"
    secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  else
    center_url="$(echo "$cfg" | jq -r '.center_url // empty')"
    secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  fi
  payload="$(echo "$cfg" | jq -n \
    --arg vps_id "$(echo "$cfg" | jq -r '.vps_id // empty')" \
    --arg vps_name "$(echo "$cfg" | jq -r '.vps_name // empty')" \
    '{vps_id:$vps_id,vps_name:$vps_name}')"
  resp="$(tg_center_api_post "$center_url" "$secret" "/api/test" "$payload" 2>/dev/null || true)"
  ok_value="$(echo "$resp" | jq -r '.ok // false' 2>/dev/null || echo false)"
  if [ "$ok_value" = "true" ]; then
    ok "通知测试已发送到管理员。"
  else
    err_msg="$(echo "$resp" | jq -r '(.errors // []) | join("; ")' 2>/dev/null || true)"
    [ -n "$err_msg" ] || err_msg="请检查主控服务、Bot Token、管理员 TG ID，且管理员需先向 Bot 发送 /start。"
    err "通知测试失败：$err_msg"
  fi
  pause
}

tg_prune_offline_reports() {
  local now
  now="$(date +%s)"
  _tg_prune_reports_with_lock "$now"
}

tg_reload_center_service_menu() {
  local cfg enabled role pruned_count
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  if [ "$enabled" != "true" ] || [ "$role" != "center" ]; then
    warn "只有已启动的主控节点需要重启/刷新 TG Bot 服务。"
    pause
    return 1
  fi
  tg_install_center_service || { err "TG Bot 服务重启/刷新失败。"; pause; return 1; }
  install_tg_agent_cron >/dev/null 2>&1 || true
  if tg_agent_sync_now; then
    ok "TG Bot 服务已重启刷新，本机数据已立即上报。"
  else
    ok "TG Bot 服务已重启刷新。"
    warn "本机立即上报失败，定时任务会继续自动上报。"
  fi
  pruned_count="$(tg_prune_offline_reports 2>/dev/null || echo 0)"
  if [ "${pruned_count:-0}" -gt 0 ]; then
    ok "已隐藏 ${pruned_count} 个已下线节点。"
  fi
  pause
}

tg_disable_menu() {
  clear
  print_rect_title "卸载/停止TG Bot"
  warn "该操作将停止 TG Bot 服务和上报任务。"
  local keep_cfg
  read -r -p "是否保留 TG Bot 配置？[Y/n]: " keep_cfg
  remove_tg_agent_cron || true
  tg_stop_center_service || true
  rm -f "$TG_CENTER_APP" >/dev/null 2>&1 || true
  rmdir "${TG_AGENT_LOCK_FILE}.d" >/dev/null 2>&1 || true
  case "${keep_cfg:-Y}" in
    [Nn]*)
      rm -f "$TG_CONFIG_FILE" >/dev/null 2>&1 || true
      ok "TG Bot 已停止，配置已删除。"
      ;;
    *)
      tg_mark_disabled_keep_config || warn "TG Bot 配置状态保存失败。"
      ok "TG Bot 已停止，配置已保留。"
      ;;
  esac
  pause
}

telegram_bot_manager_menu() {
  while true; do
    clear
    print_rect_title "Telegram Bot 管理"
    local cfg enabled role role_label vps_name center_url access_secret
    cfg="$(tg_config_load)"
    enabled="$(tg_config_enabled_value "$cfg")"
    role="$(echo "$cfg" | jq -r '.role // "未设置"')"
    vps_name="$(echo "$cfg" | jq -r '.vps_name // ""')"
    center_url="$(echo "$cfg" | jq -r '.center_url // ""')"
    access_secret="$(echo "$cfg" | jq -r '.access_secret // ""')"
    if [ "$enabled" = "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; }; then
      install_tg_agent_cron >/dev/null 2>&1 || true
    fi
    case "$role" in
      center) role_label="主控节点" ;;
      agent) role_label="普通节点" ;;
      ""|"未设置") role_label="未设置" ;;
      *) role_label="$role" ;;
    esac
    if [ "$enabled" != "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; }; then
      role_label="${role_label}（已停止）"
    fi
    echo "当前模式：$role_label"
    [ -n "$vps_name" ] && echo "本机名称：$vps_name"
    [ -n "$center_url" ] && echo "主控地址：$center_url"
    if [ "$role" = "center" ] && [ -n "$access_secret" ]; then
      echo "接入密钥：$access_secret"
    fi
    echo -e "${B}--------------------------------------------------------${NC}"
    echo "  1. 设置/启动TG Bot"
    echo "  2. 生成用户绑定链接"
    echo "  3. 通知测试"
    if [ "$enabled" = "true" ] && [ "$role" = "center" ]; then
      echo "  4. 重启/刷新TG Bot"
      echo "  5. 卸载/停止TG Bot"
    else
      echo "  4. 卸载/停止TG Bot"
    fi
    echo "  0. 返回上一级"
    local act
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) tg_setup_menu ;;
      2) tg_generate_bind_link_menu ;;
      3) tg_notify_test ;;
      4)
        if [ "$enabled" = "true" ] && [ "$role" = "center" ]; then
          tg_reload_center_service_menu
        else
          tg_disable_menu
        fi
        ;;
      5)
        if [ "$enabled" = "true" ] && [ "$role" = "center" ]; then
          tg_disable_menu
        else
          warn "无效输入：$act"; sleep 1
        fi
        ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
