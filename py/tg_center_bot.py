#!/usr/bin/env python3
import contextlib
import datetime
import fcntl
import hmac
import http.server
import json
import logging
import os
import re
import secrets
import shutil
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

CONFIG_PATH = sys.argv[1] if len(sys.argv) > 1 else "/etc/sing-box-manager/telegram.json"
LOCK_PATH = os.environ.get("SB_LOCK_FILE") or "/var/lock/singbox-manager.lock"
REPORT_ONLINE_SECONDS = 900
MAX_REQUEST_BYTES = 1024 * 1024  # 1 MiB ceiling against malformed/oversized POST payloads

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("sb-tg-center")


def load_config():
    if not os.path.exists(CONFIG_PATH):
        return {}
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception as exc:
        logger.warning("Failed to parse %s: %s", CONFIG_PATH, exc)
        try:
            backup = f"{CONFIG_PATH}.corrupt.{int(time.time())}"
            if not os.path.exists(backup):
                shutil.copy2(CONFIG_PATH, backup)
        except OSError:
            pass
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
    os.makedirs(os.path.dirname(LOCK_PATH) or ".", exist_ok=True)
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
    cfg_dir = os.path.dirname(CONFIG_PATH) or "."
    os.makedirs(cfg_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".telegram.tmp.", dir=cfg_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, CONFIG_PATH)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


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
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=8)).date()


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
        if not item or int(item.get("expires_at") or 0) <= now:
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
    if not secret or not got:
        return False
    return hmac.compare_digest(str(got), str(secret))


class PayloadTooLargeError(ValueError):
    pass


def read_json(handler):
    raw_len = handler.headers.get("Content-Length") or "0"
    length = int(raw_len)
    if length < 0:
        raise ValueError("negative content-length")
    if length > MAX_REQUEST_BYTES:
        raise PayloadTooLargeError("payload too large")
    body = handler.rfile.read(length) if length > 0 else b"{}"
    data = json.loads(body.decode("utf-8") or "{}")
    if not isinstance(data, dict):
        raise ValueError("json payload must be an object")
    return data


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
        except PayloadTooLargeError:
            write_json(self, 413, {"ok": False, "error": "payload_too_large"})
            return
        except Exception:
            write_json(self, 400, {"ok": False, "error": "bad_json"})
            return

        if self.path == "/api/report":
            with cfg_lock():
                cfg = load_config()
                reports = cfg.setdefault("reports", {})
                now_utc8 = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=8)
                payload["received_at"] = int(time.time())
                payload["received_at_text"] = now_utc8.strftime("%Y-%m-%d %H:%M:%S")
                payload["updated_at_text"] = payload.get("data_updated_at_text") or ""
                reports[payload.get("vps_id") or "unknown"] = payload
                evaluate_reminders(cfg, payload)
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
