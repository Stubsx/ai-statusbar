#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AI CLI 状态采集核心：Codex App、Codex CLI、Kimi Code、Claude Code、ZCode。
默认输出 SwiftBar 格式，--json 输出 JSON 供 Übersicht 小组件使用。"""

import glob
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

def latest_glob(pattern):
    """匹配一组版本化路径，取最近修改的一个（如 state_5.sqlite、v2/）。"""
    matches = glob.glob(pattern)
    if not matches:
        return None
    try:
        return max(matches, key=os.path.getmtime)
    except Exception:
        return matches[0]


HOME = os.path.expanduser("~")
CODEX_INDEX = os.path.join(HOME, ".codex", "session_index.jsonl")
CODEX_DB = latest_glob(os.path.join(HOME, ".codex", "state_*.sqlite")) \
    or os.path.join(HOME, ".codex", "state_5.sqlite")
KIMI_SESSIONS = os.path.join(HOME, ".kimi-code", "sessions")
CLAUDE_PROJECTS = os.path.join(HOME, ".claude", "projects")
HERMES_DB = os.path.join(HOME, ".hermes", "state.db")
HERMES_HEARTBEAT = os.path.join(HOME, ".hermes", "state", "gateway.heartbeat")
ZCODE_DB = latest_glob(os.path.join(HOME, ".zcode", "v*", "tasks-index.sqlite")) \
    or os.path.join(HOME, ".zcode", "v2", "tasks-index.sqlite")
ZCODE_CLI = os.path.join(HOME, ".zcode", "cli")

NOW = time.time()
TAIL_BYTES = 256 * 1024

# ---------- 空闲判定时间设置（~/.ai-statusbar/settings.json，菜单栏可改） ----------
USAGE_DIR = os.path.join(HOME, ".ai-statusbar")
SETTINGS_PATH = os.path.join(USAGE_DIR, "settings.json")
DEFAULT_BUSY_SEC = 300  # 默认 5 分钟


def _load_busy_settings():
    try:
        s = json.load(open(SETTINGS_PATH, encoding="utf-8"))
        return (int(s.get("default_busy_sec", DEFAULT_BUSY_SEC)),
                dict(s.get("per_tool", {})),
                int(s.get("offline_after_sec", 10800)))  # 默认 3 小时无活动算未运行，0=从不
    except Exception:
        return DEFAULT_BUSY_SEC, {}, 10800


_DEFAULT_BUSY, _PER_TOOL_BUSY, _OFFLINE_AFTER = _load_busy_settings()


def busy_sec(tool):
    """某工具的空闲判定秒数：单独设置优先，否则用统一值。"""
    try:
        return int(_PER_TOOL_BUSY.get(tool, _DEFAULT_BUSY))
    except Exception:
        return _DEFAULT_BUSY


CONN_STATE = os.path.join(USAGE_DIR, "conn_state.json")
CONN_PERSIST_SEC = 300   # 同一连接连续存在超过 5 分钟视为常驻（心跳/遥测），忽略
CONN_MAX_AGE_SEC = 1800  # 模型请求连接最长认定 30 分钟


def transient_conns(proc_names=(), pids=(), max_age=CONN_PERSIST_SEC, min_age=15):
    """探测「非常驻」TCP 连接数：{进程名: 连接数}。
    流式模型请求的连接随回合生灭；存活 >max_age 秒的视为常驻（心跳/云同步）过滤，
    存活 <min_age 秒的视为瞬时闪连（定期心跳）也过滤，只留中段 = 真实请求。
    跨 10 秒采样用 conn_state.json 记忆连接首次出现时间。"""
    args = ["lsof", "-nP", "-iTCP", "-sTCP:ESTABLISHED", "-a"]
    for n in proc_names:
        args += ["-c", n]
    for p in pids:
        args += ["-p", str(p)]
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return {}
    cur = {}
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 9 or "->" not in parts[-1]:
            continue
        if "->127.0.0.1" in line or "->[::1]" in line or "->localhost" in line:
            continue
        local_port = parts[-1].split("->")[0].rsplit(":", 1)[-1]
        cur.setdefault(parts[0], set()).add(local_port)
    try:
        state = json.load(open(CONN_STATE, encoding="utf-8"))
    except Exception:
        state = {}
    busy = {}
    for proc, ports in cur.items():
        prev = state.get(proc, {})
        new_prev, transient = {}, 0
        for p in ports:
            first_seen = prev.get(p, NOW)
            new_prev[p] = first_seen
            if min_age <= NOW - first_seen < max_age:
                transient += 1
        state[proc] = new_prev
        busy[proc] = transient
    try:
        os.makedirs(USAGE_DIR, exist_ok=True)
        json.dump(state, open(CONN_STATE, "w"))
    except Exception:
        pass
    return busy


def proc_count(basename, exclude_substrings=()):
    """按 argv[0] 的可执行文件名统计进程数，可按命令行内容排除。"""
    try:
        out = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout
        n = 0
        for line in out.splitlines()[1:]:
            tokens = line.strip().split()
            while tokens and "=" in tokens[0] and not tokens[0].startswith("/"):
                tokens.pop(0)  # 跳过开头的环境变量赋值（如 HOME=... PATH=...）
            if not tokens or os.path.basename(tokens[0]) != basename:
                continue
            if any(s in line for s in exclude_substrings):
                continue
            n += 1
        return n
    except Exception:
        return 0


def age_str(ts):
    secs = int(NOW - ts)
    if secs < 60:
        return "刚刚"
    if secs < 3600:
        return f"{secs // 60}分钟前"
    if secs < 86400:
        return f"{secs // 3600}小时前"
    return f"{secs // 86400}天前"


def read_tail(path, size=TAIL_BYTES):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            n = f.tell()
            f.seek(max(0, n - size))
            return f.read().decode("utf-8", "ignore")
    except Exception:
        return ""


def iter_jsonl(text):
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except Exception:
            continue


# ---------- Codex ----------
def codex_status():
    n = proc_count("codex", ("ChatGPT.app/", "Codex.app/"))  # 纯 CLI 进程（排除桌面 App 内嵌的 codex）
    app_n = proc_count("ChatGPT") + proc_count("Codex")      # 桌面/IDE 宿主（Codex.app 主进程名是 ChatGPT）
    names = {}  # sid -> (title, updated_ts, kind)  kind: cli / ide
    # 桌面版/IDE 版的线程标题都在 state_5.sqlite 的 threads 表里
    try:
        db = sqlite3.connect(f"file:{CODEX_DB}?mode=ro", uri=True)
        cols = {r[1] for r in db.execute("PRAGMA table_info(threads)")}
        if not {"id", "title", "updated_at", "source"} <= cols:
            raise RuntimeError(f"threads 表结构不兼容: {sorted(cols)}")
        for tid, title, updated, source in db.execute(
                "SELECT id, title, updated_at, source FROM threads WHERE archived=0"):
            if tid:
                kind = "cli" if source in ("cli", "exec") else "ide"
                names[tid] = (title or "(未命名会话)", float(updated or 0), kind)
        db.close()
    except Exception:
        pass
    if not names:  # 退回 session_index.jsonl（主要是 CLI 会话）
        try:
            for r in iter_jsonl(open(CODEX_INDEX, encoding="utf-8").read()):
                if r.get("id"):
                    try:
                        ts = datetime.fromisoformat(
                            r.get("updated_at", "").replace("Z", "+00:00")).timestamp()
                    except Exception:
                        ts = 0
                    names[r["id"]] = (r.get("thread_name") or "(未命名会话)", ts, "cli")
        except Exception:
            pass

    res = {"cli": {"busy": [], "latest": None, "activity": 0},
           "ide": {"busy": [], "latest": None, "activity": 0}}
    files = glob.glob(os.path.join(HOME, ".codex", "sessions", "*", "*", "*", "*.jsonl"))
    files = [f for f in files if NOW - os.path.getmtime(f) < 86400]
    for f in files:
        mtime = os.path.getmtime(f)
        sid = os.path.basename(f).rsplit("-", 5)
        sid = "-".join(sid[-5:]).replace(".jsonl", "") if len(sid) >= 5 else ""
        title, ts, kind = names.get(sid, ("(未命名会话)", mtime, "ide"))
        ts = ts or mtime
        r = res[kind]
        if r["latest"] is None or ts > r["latest"][1]:
            r["latest"] = (title, ts)
        r["activity"] = max(r["activity"], mtime, ts)
        last_task, pending = None, {}
        try:
            with open(f, encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    # task 事件可能离文件尾很远（之后还有大量流式输出），全文件扫但先做子串粗筛
                    if "task_started" in line or "task_complete" in line or "turn_aborted" in line:
                        try:
                            d = json.loads(line)
                        except Exception:
                            continue
                        p = d.get("payload", {})
                        if isinstance(p, dict) and d.get("type") == "event_msg" \
                           and p.get("type") in ("task_started", "task_complete", "turn_aborted"):
                            last_task = p["type"]
        except Exception:
            pass
        for d in iter_jsonl(read_tail(f)):
            p = d.get("payload", {})
            if not isinstance(p, dict):
                continue
            t = p.get("type", "")
            if d.get("type") == "event_msg" and t in ("task_started", "task_complete", "turn_aborted"):
                last_task = t
            elif d.get("type") == "response_item":
                if t in ("function_call", "custom_tool_call"):
                    cid = p.get("call_id") or p.get("id")
                    if cid:
                        pending[cid] = True
                elif t in ("function_call_output", "custom_tool_call_output"):
                    pending.pop(p.get("call_id"), None)
        # 纯事件闭环：turn 开启未收尾（task_started 或有未返回的工具调用）
        # 且对应进程还活着，就是工作中（卡几十分钟也算）；进程死了不算。
        # 3 小时兜底：防止崩溃残留的未收尾 turn 永远显示工作中
        alive = (n > 0) if kind == "cli" else (app_n > 0)
        if (last_task == "task_started" or pending) and alive \
                and NOW - mtime < max(busy_sec("codex"), 3 * 3600):
            r["busy"].append({"id": sid, "title": title})
    return n, app_n, res


# ---------- Kimi Code ----------
def kimi_status():
    n = proc_count("kimi")
    # 窗口取 max(设置值, 30分钟)：wire 在请求开始就会写 llm.request，
    # 未闭环的 step/tool_call 配 30 分钟窗可覆盖长卡顿，无需连接探测
    window = max(busy_sec("kimi"), 30 * 60)
    busy, latest = [], None
    for state_path in glob.glob(os.path.join(KIMI_SESSIONS, "*", "*", "state.json")):
        sdir = os.path.dirname(state_path)
        try:
            meta = json.load(open(state_path, encoding="utf-8"))
            title = meta.get("title") or os.path.basename(meta.get("workDir", ""))
        except Exception:
            title = "(未命名会话)"
        wires = glob.glob(os.path.join(sdir, "agents", "*", "wire.jsonl"))
        if not wires:
            continue
        mtime = max(os.path.getmtime(w) for w in wires)
        if latest is None or mtime > latest[1]:
            latest = (title, mtime)
        if NOW - mtime > window:
            continue
        for w in wires:
            events = []
            for d in iter_jsonl(read_tail(w)):
                if d.get("type") != "context.append_loop_event":
                    continue
                ev = d.get("event", {})
                if ev.get("type") in ("step.begin", "step.end", "tool.call", "tool.result"):
                    events.append(ev)
            if not events:
                continue
            # 只统计最新一个 turn：被打断的旧 turn 会留下永不闭环的幽灵步骤
            max_turn = max((e.get("turnId") or "" for e in events
                            if e.get("turnId") is not None), default="")
            if not max_turn:
                continue
            steps, tools = {}, {}
            for ev in events:
                t = ev.get("type", "")
                # Kimi 的 tool.result 不带 turnId，只能用 toolCallId 与当前
                # turn 已记录的 tool.call 配对；其他事件仍严格限定为最新 turn。
                if t == "tool.result":
                    tools.pop(ev.get("toolCallId"), None)
                    continue
                if (ev.get("turnId") or "") != max_turn:
                    continue
                if t == "step.begin":
                    steps[ev.get("uuid")] = True
                elif t == "step.end":  # step.end 的 uuid 与 step.begin 相同
                    steps.pop(ev.get("uuid"), None)
                elif t == "tool.call":
                    tools[ev.get("toolCallId")] = True
            if steps or tools:
                busy.append({"id": os.path.basename(sdir), "title": title})
                break
    return n, busy, latest


# ---------- Claude Code ----------
def claude_status():
    n = proc_count("claude", ("Claude.app/",))  # 排除 Claude 桌面 App
    # 同 Kimi：事件闭环 + max(设置值, 30分钟) 窗口覆盖长卡顿
    window = max(busy_sec("claude"), 30 * 60)
    busy, latest = [], None
    for f in glob.glob(os.path.join(CLAUDE_PROJECTS, "*", "*.jsonl")):
        try:
            mtime = os.path.getmtime(f)
        except Exception:
            continue
        if NOW - mtime > 86400:
            continue
        title, last_msg = None, None
        try:
            with open(f, encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    if '"ai-title"' in line:
                        try:
                            t = json.loads(line).get("aiTitle")
                            if t:
                                title = t
                        except Exception:
                            pass
                        continue
                    if '"user"' not in line and '"assistant"' not in line:
                        continue
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    if d.get("type") not in ("user", "assistant"):
                        continue
                    m = d.get("message", {})
                    c = m.get("content")
                    kinds = tuple(x.get("type") for x in c) if isinstance(c, list) else ("text",)
                    last_msg = (d["type"], kinds)
        except Exception:
            pass
        if not title:  # 目录名是 cwd 编码：-Users-jabber1-Desktop-xxx → xxx
            title = os.path.basename(os.path.dirname(f)).lstrip("-").rsplit("-", 1)[-1] or "(未命名会话)"
        if latest is None or mtime > latest[1]:
            latest = (title, mtime)
        if NOW - mtime > window:
            continue
        if last_msg is None:
            continue
        t, kinds = last_msg
        # 最后是 user 消息（prompt 或 tool_result）说明模型正在生成；
        # 最后是带 tool_use 的 assistant 消息说明工具正在执行；
        # 最后是纯文本 assistant 消息 = 回合结束，空闲
        if t == "user" or "tool_use" in kinds:
            busy.append({"id": os.path.basename(f).replace(".jsonl", ""), "title": title})
    return n, busy, latest


# ---------- Hermes ----------
def hermes_status():
    # 在线：桌面 App 进程在，或 gateway 心跳 2 分钟内有更新（后端活着）
    app_n = proc_count("Hermes")
    try:
        gw_alive = NOW - os.path.getmtime(HERMES_HEARTBEAT) < 120
    except Exception:
        gw_alive = False
    busy, latest = [], None
    try:
        db = sqlite3.connect(f"file:{HERMES_DB}?mode=ro", uri=True)
        cols = {r[1] for r in db.execute("PRAGMA table_info(sessions)")}
        ucols = {r[1] for r in db.execute("PRAGMA table_info(session_model_usage)")}
        if not {"id", "title", "started_at"} <= cols or "last_seen" not in ucols:
            raise RuntimeError("hermes state.db 表结构不兼容")
        # 工作中：5 分钟内有 API 调用的会话（按会话 ID 追踪）
        busy = [{"id": r[0], "title": r[1]} for r in db.execute("""
            SELECT DISTINCT s.id, s.title FROM sessions s
            JOIN session_model_usage u ON u.session_id = s.id
            WHERE u.last_seen > ? AND s.archived = 0 AND s.title IS NOT NULL AND s.title != ''
            ORDER BY u.last_seen DESC""", (NOW - busy_sec("hermes"),))]
        row = db.execute("""SELECT title, started_at FROM sessions
            WHERE archived = 0 AND title IS NOT NULL AND title != ''
            ORDER BY started_at DESC LIMIT 1""").fetchone()
        if row:
            latest = (row[0], row[1])
        activity = db.execute("SELECT MAX(last_seen) FROM session_model_usage").fetchone()[0] or 0
        db.close()
        # 连接补充：hermes python 进程有短命（非心跳）连接 = 有请求在途
        if not busy:
            pids = subprocess.run(["pgrep", "-f", "hermes_cli"],
                                  capture_output=True, text=True).stdout.split()
            if transient_conns(pids=pids).get("python", 0) > 0 and latest:
                busy = [{"id": "conn-hermes", "title": latest[0]}]
    except Exception:
        activity = 0
    return app_n, gw_alive, busy, latest, activity


# ---------- ZCode ----------
def zcode_status():
    cli_n = proc_count("zcode-cli")
    app_on = proc_count("ZCode") > 0

    # task_status='running' 会残留僵尸记录，不可信；
    # 改为按会话活动判断：model-io 转录或 artifacts 目录 5 分钟内有写入 = 工作中
    titles, latest = {}, None
    try:
        db = sqlite3.connect(f"file:{ZCODE_DB}?mode=ro", uri=True)
        cur = db.cursor()
        cols = {r[1] for r in cur.execute("PRAGMA table_info(tasks)")}
        if not {"task_id", "title", "updated_at"} <= cols:
            raise RuntimeError(f"tasks 表结构不兼容: {sorted(cols)}")
        cur.execute("SELECT task_id, title FROM tasks WHERE deleted=0")
        titles = dict(cur.fetchall())
        cur.execute("""SELECT title, updated_at/1000 FROM tasks
                       WHERE deleted=0 ORDER BY updated_at DESC LIMIT 1""")
        row = cur.fetchone()
        if row:
            latest = (row[0], row[1])
        db.close()
    except Exception:
        pass

    activity = {}  # sess_id -> 最近活动时间
    for f in glob.glob(os.path.join(ZCODE_CLI, "rollout", "model-io-sess_*.jsonl")):
        sid = os.path.basename(f)[len("model-io-"):-len(".jsonl")]
        if sid.startswith("sess_subagent_"):
            continue
        activity[sid] = max(activity.get(sid, 0), os.path.getmtime(f))
    for d in glob.glob(os.path.join(ZCODE_CLI, "artifacts", "sess_*")):
        sid = os.path.basename(d)
        if sid.startswith("sess_subagent_"):
            continue
        activity[sid] = max(activity.get(sid, 0), os.path.getmtime(d))

    running = []
    for sid, ts in sorted(activity.items(), key=lambda kv: -kv[1]):
        if NOW - ts < busy_sec("zcode"):
            running.append({"id": sid, "title": titles.get(sid, "(未知任务)")})
    if latest is None and activity:
        sid, ts = max(activity.items(), key=lambda kv: kv[1])
        latest = (titles.get(sid, "(未知任务)"), ts)
    last_activity = max(activity.values()) if activity else 0
    # 连接补充：ZCode App 有短命（非心跳）连接 = 有流式请求在途
    if not running and app_on and latest:
        if transient_conns(proc_names=["ZCode"]).get("ZCode", 0) > 0:
            running.append({"id": "conn-zcode", "title": latest[0]})
    return cli_n, app_on, running, latest, last_activity


# ---------- Token 用量统计（增量扫描，缓存于本地 sqlite） ----------
USAGE_DB = os.path.join(USAGE_DIR, "usage.sqlite")
USAGE_MAX_AGE = 70 * 86400  # 只索引最近 70 天的日志文件（热力图需要 10 周）


def _usage_db():
    os.makedirs(USAGE_DIR, exist_ok=True)
    db = sqlite3.connect(USAGE_DB)
    db.execute("""CREATE TABLE IF NOT EXISTS daily(
        date TEXT, tool TEXT, input INT, output INT, cache INT,
        PRIMARY KEY(date, tool))""")
    db.execute("""CREATE TABLE IF NOT EXISTS offsets(
        path TEXT PRIMARY KEY, offset INT, mtime REAL, last_key TEXT)""")
    cols = {r[1] for r in db.execute("PRAGMA table_info(offsets)")}
    if "last_key" not in cols:
        db.execute("ALTER TABLE offsets ADD COLUMN last_key TEXT")
    return db


def _local_date(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d")


def _add_usage(db, tool, ts, inp, outp, cache):
    date = _local_date(ts)
    db.execute("""INSERT INTO daily(date, tool, input, output, cache) VALUES(?,?,?,?,?)
        ON CONFLICT(date, tool) DO UPDATE SET
        input=input+excluded.input, output=output+excluded.output, cache=cache+excluded.cache""",
        (date, tool, inp, outp, cache))


def _scan_file(db, path, tool, parse):
    """按字节偏移增量扫描追加式 jsonl，parse(line) -> (ts, input, output, cache) 或 None。"""
    try:
        size = os.path.getsize(path)
        mtime = os.path.getmtime(path)
    except Exception:
        return
    if NOW - mtime > USAGE_MAX_AGE:
        return
    row = db.execute("SELECT offset, mtime, last_key FROM offsets WHERE path=?", (path,)).fetchone()
    offset = row[0] if row else 0
    prev_key = row[2] if row else None
    if row and row[0] == size and row[1] == mtime:
        return  # 没变化
    if size < offset:
        offset = 0  # 文件被截断/轮转，重扫
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            raw = f.read()
    except Exception:
        return
    end = raw.rfind(b"\n")
    if end < 0:
        return  # 没有完整行
    complete = raw[:end]
    for line in complete.decode("utf-8", "ignore").splitlines():
        if not line.strip():
            continue
        r = parse(line)
        if r:
            # 相邻完全重复事件跳过（codex rollout 会重复写同一 token_count）
            key = f"{r[1]}:{r[2]}:{r[3]}"
            if key != prev_key:
                _add_usage(db, tool, *r)
                prev_key = key
    db.execute("INSERT INTO offsets(path, offset, mtime, last_key) VALUES(?,?,?,?) "
               "ON CONFLICT(path) DO UPDATE SET offset=excluded.offset, mtime=excluded.mtime, "
               "last_key=excluded.last_key",
               (path, offset + end + 1, mtime, prev_key))


def _parse_codex(line):
    if "token_count" not in line:
        return None
    try:
        d = json.loads(line)
    except Exception:
        return None
    p = d.get("payload", {})
    if d.get("type") != "event_msg" or p.get("type") != "token_count":
        return None
    try:
        ts = datetime.fromisoformat(d["timestamp"].replace("Z", "+00:00")).timestamp()
    except Exception:
        return None
    u = p.get("info", {}).get("last_token_usage", {})
    inp = u.get("input_tokens", 0)
    cache = u.get("cached_input_tokens", 0)
    # 统一口径：输入 = 非缓存新增输入（cached_input 是 input 的子集，剔除）
    return (ts, max(0, inp - cache), u.get("output_tokens", 0), cache)


def _parse_kimi(line):
    if "usage.record" not in line:
        return None
    try:
        d = json.loads(line)
    except Exception:
        return None
    if d.get("type") != "usage.record" or not d.get("time"):
        return None
    u = d.get("usage", {})
    return (d.get("time", 0) / 1000, u.get("inputOther", 0), u.get("output", 0), u.get("inputCacheRead", 0))


def _parse_claude(line):
    if '"usage"' not in line:
        return None
    try:
        d = json.loads(line)
    except Exception:
        return None
    u = d.get("message", {}).get("usage")
    if not u or not d.get("timestamp"):
        return None
    try:
        ts = datetime.fromisoformat(d["timestamp"].replace("Z", "+00:00")).timestamp()
    except Exception:
        return None
    return (ts, u.get("input_tokens", 0), u.get("output_tokens", 0),
            u.get("cache_read_input_tokens", 0))


def _parse_zcode(line):
    if '"usage"' not in line:
        return None
    try:
        d = json.loads(line)
    except Exception:
        return None
    u = d.get("response", {}).get("usage")
    ca = d.get("completedAt")
    if not u or not ca:
        return None
    try:
        ts = datetime.fromisoformat(ca.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None
    inp = u.get("inputTokens", 0)
    cache = u.get("cacheReadTokens", 0)
    # 统一口径：输入 = 非缓存新增输入（inputTokens 含 cacheReadTokens，剔除）
    return (ts, max(0, inp - cache), u.get("outputTokens", 0), cache)


def collect_usage():
    """增量扫描四家日志，返回今日用量。首次运行做全量索引（约数十秒）。"""
    try:
        db = _usage_db()
        sources = [
            (glob.glob(os.path.join(HOME, ".codex", "sessions", "*", "*", "*", "*.jsonl")), "codex", _parse_codex),
            (glob.glob(os.path.join(KIMI_SESSIONS, "*", "*", "agents", "*", "wire.jsonl")), "kimi", _parse_kimi),
            (glob.glob(os.path.join(CLAUDE_PROJECTS, "*", "*.jsonl")), "claude", _parse_claude),
            (glob.glob(os.path.join(ZCODE_CLI, "rollout", "model-io-*.jsonl")), "zcode", _parse_zcode),
        ]
        for files, tool, parse in sources:
            for f in files:
                try:
                    _scan_file(db, f, tool, parse)
                except Exception:
                    continue
        # Hermes：session_model_usage 是累计计数，用快照差分归属到当天
        try:
            db.execute("""CREATE TABLE IF NOT EXISTS hermes_snap(
                pk TEXT PRIMARY KEY, input INT, output INT, cache INT)""")
            today_start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
            hdb = sqlite3.connect(f"file:{HERMES_DB}?mode=ro", uri=True)
            rows = hdb.execute("""SELECT session_id||'|'||model||'|'||billing_provider||'|'||
                billing_base_url||'|'||billing_mode||'|'||task,
                input_tokens, output_tokens, cache_read_tokens, first_seen
                FROM session_model_usage""").fetchall()
            hdb.close()
            for pk, inp, outp, cache, first_seen in rows:
                prev = db.execute("SELECT input, output, cache FROM hermes_snap WHERE pk=?", (pk,)).fetchone()
                db.execute("INSERT INTO hermes_snap(pk, input, output, cache) VALUES(?,?,?,?) "
                           "ON CONFLICT(pk) DO UPDATE SET input=excluded.input, "
                           "output=excluded.output, cache=excluded.cache", (pk, inp, outp, cache))
                if prev is None:
                    # 首次见到：只有今天才开始累计的行才全额计入，否则只建基线
                    if first_seen and first_seen >= today_start:
                        _add_usage(db, "hermes", NOW, inp, outp, cache)
                else:
                    di, do, dc = max(0, inp - prev[0]), max(0, outp - prev[1]), max(0, cache - prev[2])
                    if di or do or dc:
                        _add_usage(db, "hermes", NOW, di, do, dc)
        except Exception:
            pass
        db.commit()
        today = datetime.now().strftime("%Y-%m-%d")
        rows = db.execute("SELECT tool, input, output, cache FROM daily WHERE date=?", (today,)).fetchall()
        db.close()
    except Exception:
        return None
    tools = {}
    total = {"input": 0, "output": 0, "cache": 0}
    for tool, inp, outp, cache in rows:
        tools[tool] = {"input": inp, "output": outp, "cache": cache}
        total["input"] += inp
        total["output"] += outp
        total["cache"] += cache

    # 热力图：近 10 周逐天 token 总量（输入+输出，缓存不计避免重复），起点对齐到周一
    heatmap, heatmax = [], 0
    try:
        db = _usage_db()
        per_day = dict(db.execute(
            "SELECT date, SUM(input + output + cache) FROM daily GROUP BY date").fetchall())
        db.close()
        start_ts = NOW - 69 * 86400
        start = datetime.fromtimestamp(start_ts)
        start -= timedelta(days=start.weekday())  # 对齐周一
        days = []
        d = start
        end = datetime.now()
        while d <= end:
            days.append(d)
            d += timedelta(days=1)
        while len(days) % 7:  # 凑满整周
            days.append(days[-1] + timedelta(days=1))
        for d in days:
            key = d.strftime("%Y-%m-%d")
            v = per_day.get(key, 0)
            heatmap.append({"date": key, "total": v, "future": d.date() > end.date()})
            heatmax = max(heatmax, v)
    except Exception:
        pass
    return {"date": datetime.now().strftime("%-m月%-d日"), "tools": tools, "total": total,
            "heatmap": heatmap, "heatmax": heatmax}


def state_of(proc_on, busy):
    if busy:
        return "busy"
    return "idle" if proc_on else "off"


def collect():
    """采集所有工具状态，返回结构化 dict。"""
    codex_n, codex_app_n, codex = codex_status()
    kimi_n, kimi_busy, kimi_latest = kimi_status()
    claude_n, claude_busy, claude_latest = claude_status()
    hermes_n, hermes_gw, hermes_busy, hermes_latest, hermes_act = hermes_status()
    zcode_cli_n, zcode_app, zcode_running, zcode_latest, zcode_act = zcode_status()

    cs_ide = state_of(codex_app_n > 0, codex["ide"]["busy"])
    cs_cli = state_of(codex_n > 0, codex["cli"]["busy"])
    ks = state_of(kimi_n > 0, kimi_busy)
    ls_ = state_of(claude_n > 0, claude_busy)
    hs = state_of(hermes_n > 0 or hermes_gw, hermes_busy)
    zs = state_of(zcode_cli_n > 0 or zcode_app, zcode_running)

    def tool(key, letter, name, st, busy_items, latest, detail_off, activity):
        # 长时间无活动（默认 3 小时）即使进程在也按未运行处理，0=不启用
        if st == "idle" and _OFFLINE_AFTER > 0 and activity and NOW - activity > _OFFLINE_AFTER:
            st = "off"
        return {
            "key": key,
            "letter": letter,
            "name": name,
            "state": st,
            "busy_count": len(busy_items),
            "busy_items": busy_items[:5],
            "detail": f"{len(busy_items)} 个任务" if st == "busy" else detail_off,
            "latest_title": latest[0] if latest else None,
            "latest_age": age_str(latest[1]) if latest else None,
        }

    tools = [
        tool("codex-ide", "C", "Codex App", cs_ide, codex["ide"]["busy"],
             codex["ide"]["latest"], "App 在线" if codex_app_n else "无进程", codex["ide"]["activity"]),
        tool("codex-cli", "X", "Codex CLI", cs_cli, codex["cli"]["busy"],
             codex["cli"]["latest"], f"{codex_n} 个进程", codex["cli"]["activity"]),
        tool("kimi", "K", "Kimi Code", ks, kimi_busy, kimi_latest, f"{kimi_n} 个进程",
             kimi_latest[1] if kimi_latest else 0),
        tool("claude", "L", "Claude Code", ls_, claude_busy, claude_latest, f"{claude_n} 个进程",
             claude_latest[1] if claude_latest else 0),
        tool("hermes", "H", "Hermes", hs, hermes_busy, hermes_latest,
             "在线" if (hermes_n or hermes_gw) else "无进程", hermes_act),
        tool("zcode", "Z", "ZCode", zs, zcode_running, zcode_latest,
             "App 在线" if zcode_app else "无进程", zcode_act),
    ]
    return {"updated_at": datetime.now().strftime("%H:%M:%S"),
            "tools": tools,
            "usage": collect_usage()}


# ---------- SwiftBar 输出 ----------
def mark(state):
    return {"busy": "🟢", "idle": "🟡", "off": "⚪️"}[state]


def render_swiftbar(data):
    label = {"busy": "工作中", "idle": "空闲", "off": "未运行"}
    out = []

    def badge(t):
        if t["state"] == "busy":
            return f"{t['letter']}🟢{t['busy_count']}"
        return f"{t['letter']}{mark(t['state'])}"

    out.append(" ".join(badge(t) for t in data["tools"]))
    out.append("---")
    for t in data["tools"]:
        out.append(f"{mark(t['state'])} {t['name']}：{label[t['state']]}（{t['detail']}）")
        for item in t["busy_items"][:3]:
            out.append(f"▶ {item['title']} | size=11 color=green")
        if t["latest_title"] and not t["busy_items"]:
            out.append(f"最近任务：{t['latest_title']} · {t['latest_age']} | size=11 color=gray")
        out.append("---")
    out.append("C=Codex App  X=Codex CLI  K=Kimi  L=Claude  H=Hermes  Z=ZCode | size=10 color=gray")
    out.append("🟢工作中  🟡空闲  ⚪️未运行 | size=10 color=gray")
    out.append("刷新 | refresh=true")
    return "\n".join(out)


if __name__ == "__main__":
    data = collect()
    if "--json" in sys.argv:
        print(json.dumps(data, ensure_ascii=False))
    else:
        print(render_swiftbar(data))
