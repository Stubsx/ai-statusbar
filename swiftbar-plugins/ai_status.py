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
from datetime import datetime, timezone

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
ZCODE_BUSY_SEC = 300  # model-io/artifacts 5 分钟内有写入算工作中

NOW = time.time()
BUSY_MTIME_SEC = 300   # 日志 5 分钟内有动静才可能算“工作中”
TAIL_BYTES = 256 * 1024


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

    res = {"cli": {"busy": [], "latest": None},
           "ide": {"busy": [], "latest": None}}
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
        # turn 开启未收尾（最后事件是 task_started）或有未返回的工具调用，
        # 且日志 5 分钟内有动静，才算工作中
        if (last_task == "task_started" or pending) and NOW - mtime < BUSY_MTIME_SEC:
            r["busy"].append(title)
    return n, app_n, res


# ---------- Kimi Code ----------
def kimi_status():
    n = proc_count("kimi")
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
        if NOW - mtime > BUSY_MTIME_SEC:
            continue
        for w in wires:
            steps, tools = {}, {}
            for d in iter_jsonl(read_tail(w)):
                if d.get("type") != "context.append_loop_event":
                    continue
                ev = d.get("event", {})
                t = ev.get("type", "")
                if t == "step.begin":
                    steps[ev.get("uuid")] = True
                elif t == "step.end":
                    steps.pop(ev.get("stepUuid", ev.get("uuid")), None)
                elif t == "tool.call":
                    tools[ev.get("toolCallId")] = True
                elif t == "tool.result":
                    tools.pop(ev.get("toolCallId"), None)
            if steps or tools:
                busy.append(title)
                break
    return n, busy, latest


# ---------- Claude Code ----------
def claude_status():
    n = proc_count("claude", ("Claude.app/",))  # 排除 Claude 桌面 App
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
        if NOW - mtime > BUSY_MTIME_SEC or last_msg is None:
            continue
        t, kinds = last_msg
        # 最后是 user 消息（prompt 或 tool_result）说明模型正在生成；
        # 最后是带 tool_use 的 assistant 消息说明工具正在执行；
        # 最后是纯文本 assistant 消息 = 回合结束，空闲
        if t == "user" or "tool_use" in kinds:
            busy.append(title)
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
        # 工作中：5 分钟内有 API 调用的会话
        busy = [r[0] for r in db.execute("""
            SELECT DISTINCT s.title FROM sessions s
            JOIN session_model_usage u ON u.session_id = s.id
            WHERE u.last_seen > ? AND s.archived = 0 AND s.title IS NOT NULL AND s.title != ''
            ORDER BY u.last_seen DESC""", (NOW - BUSY_MTIME_SEC,))]
        row = db.execute("""SELECT title, started_at FROM sessions
            WHERE archived = 0 AND title IS NOT NULL AND title != ''
            ORDER BY started_at DESC LIMIT 1""").fetchone()
        if row:
            latest = (row[0], row[1])
        db.close()
    except Exception:
        pass
    return app_n, gw_alive, busy, latest


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
        if NOW - ts < ZCODE_BUSY_SEC:
            running.append(titles.get(sid, "(未知任务)"))
    if latest is None and activity:
        sid, ts = max(activity.items(), key=lambda kv: kv[1])
        latest = (titles.get(sid, "(未知任务)"), ts)
    return cli_n, app_on, running, latest


# ---------- Token 用量统计（增量扫描，缓存于本地 sqlite） ----------
USAGE_DIR = os.path.join(HOME, ".ai-statusbar")
USAGE_DB = os.path.join(USAGE_DIR, "usage.sqlite")
USAGE_MAX_AGE = 35 * 86400  # 只索引最近 35 天的日志文件


def _usage_db():
    os.makedirs(USAGE_DIR, exist_ok=True)
    db = sqlite3.connect(USAGE_DB)
    db.execute("""CREATE TABLE IF NOT EXISTS daily(
        date TEXT, tool TEXT, input INT, output INT, cache INT,
        PRIMARY KEY(date, tool))""")
    db.execute("""CREATE TABLE IF NOT EXISTS offsets(
        path TEXT PRIMARY KEY, offset INT, mtime REAL)""")
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
    row = db.execute("SELECT offset, mtime FROM offsets WHERE path=?", (path,)).fetchone()
    offset = row[0] if row else 0
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
            _add_usage(db, tool, *r)
    db.execute("INSERT INTO offsets(path, offset, mtime) VALUES(?,?,?) "
               "ON CONFLICT(path) DO UPDATE SET offset=excluded.offset, mtime=excluded.mtime",
               (path, offset + end + 1, mtime))


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
    return (ts, u.get("input_tokens", 0), u.get("output_tokens", 0), u.get("cached_input_tokens", 0))


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
    return (ts, u.get("inputTokens", 0), u.get("outputTokens", 0), u.get("cacheReadTokens", 0))


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
    return {"date": datetime.now().strftime("%-m月%-d日"), "tools": tools, "total": total}


def state_of(proc_on, busy):
    if busy:
        return "busy"
    return "idle" if proc_on else "off"


def collect():
    """采集所有工具状态，返回结构化 dict。"""
    codex_n, codex_app_n, codex = codex_status()
    kimi_n, kimi_busy, kimi_latest = kimi_status()
    claude_n, claude_busy, claude_latest = claude_status()
    hermes_n, hermes_gw, hermes_busy, hermes_latest = hermes_status()
    zcode_cli_n, zcode_app, zcode_running, zcode_latest = zcode_status()

    cs_ide = state_of(codex_app_n > 0, codex["ide"]["busy"])
    cs_cli = state_of(codex_n > 0, codex["cli"]["busy"])
    ks = state_of(kimi_n > 0, kimi_busy)
    ls_ = state_of(claude_n > 0, claude_busy)
    hs = state_of(hermes_n > 0 or hermes_gw, hermes_busy)
    zs = state_of(zcode_cli_n > 0 or zcode_app, zcode_running)

    def tool(key, letter, name, st, busy_titles, latest, detail_off):
        return {
            "key": key,
            "letter": letter,
            "name": name,
            "state": st,
            "busy_count": len(busy_titles),
            "busy_titles": busy_titles[:5],
            "detail": f"{len(busy_titles)} 个任务" if st == "busy" else detail_off,
            "latest_title": latest[0] if latest else None,
            "latest_age": age_str(latest[1]) if latest else None,
        }

    tools = [
        tool("codex-ide", "C", "Codex App", cs_ide, codex["ide"]["busy"],
             codex["ide"]["latest"], "App 在线" if codex_app_n else "无进程"),
        tool("codex-cli", "X", "Codex CLI", cs_cli, codex["cli"]["busy"],
             codex["cli"]["latest"], f"{codex_n} 个进程"),
        tool("kimi", "K", "Kimi Code", ks, kimi_busy, kimi_latest, f"{kimi_n} 个进程"),
        tool("claude", "L", "Claude Code", ls_, claude_busy, claude_latest, f"{claude_n} 个进程"),
        tool("hermes", "H", "Hermes", hs, hermes_busy, hermes_latest,
             "在线" if (hermes_n or hermes_gw) else "无进程"),
        tool("zcode", "Z", "ZCode", zs, zcode_running, zcode_latest,
             "App 在线" if zcode_app else "无进程"),
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
        for title in t["busy_titles"][:3]:
            out.append(f"▶ {title} | size=11 color=green")
        if t["latest_title"] and not t["busy_titles"]:
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
