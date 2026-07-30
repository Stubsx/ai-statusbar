#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# <swiftbar.title>AI CLI Status</swiftbar.title>
# <swiftbar.version>2.0</swiftbar.version>
# <swiftbar.author>jabber1</swiftbar.author>
# <swiftbar.desc>显示 Codex / Kimi Code / ZCode 的运行状态（工作中/空闲/未运行）和最近任务</swiftbar.desc>

import glob
import json
import os
import sqlite3
import subprocess
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CODEX_INDEX = os.path.join(HOME, ".codex", "session_index.jsonl")
CODEX_DB = os.path.join(HOME, ".codex", "state_5.sqlite")
KIMI_SESSIONS = os.path.join(HOME, ".kimi-code", "sessions")
ZCODE_DB = os.path.join(HOME, ".zcode", "v2", "tasks-index.sqlite")
ZCODE_CLI = os.path.join(HOME, ".zcode", "cli")
ZCODE_BUSY_SEC = 240  # model-io/artifacts 4 分钟内有写入算工作中

NOW = time.time()
BUSY_MTIME_SEC = 600   # 日志 10 分钟内有动静才可能算“工作中”
TAIL_BYTES = 256 * 1024


def proc_count(basename):
    try:
        out = subprocess.run(["ps", "-eo", "comm"], capture_output=True, text=True).stdout
        return sum(1 for line in out.splitlines() if line.strip() == basename)
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
    n = proc_count("codex")
    names = {}
    # 桌面版/IDE 版的线程标题都在 state_5.sqlite 的 threads 表里
    try:
        db = sqlite3.connect(f"file:{CODEX_DB}?mode=ro", uri=True)
        for tid, title, updated in db.execute(
                "SELECT id, title, updated_at FROM threads WHERE archived=0"):
            if tid:
                names[tid] = (title or "(未命名会话)", float(updated or 0))
        db.close()
    except Exception:
        pass
    if not names:  # 退回 session_index.jsonl
        try:
            for r in iter_jsonl(open(CODEX_INDEX, encoding="utf-8").read()):
                if r.get("id"):
                    try:
                        ts = datetime.fromisoformat(
                            r.get("updated_at", "").replace("Z", "+00:00")).timestamp()
                    except Exception:
                        ts = 0
                    names[r["id"]] = (r.get("thread_name") or "(未命名会话)", ts)
        except Exception:
            pass

    busy, latest = [], None
    files = glob.glob(os.path.join(HOME, ".codex", "sessions", "*", "*", "*", "*.jsonl"))
    files = [f for f in files if NOW - os.path.getmtime(f) < 86400]
    for f in files:
        mtime = os.path.getmtime(f)
        sid = os.path.basename(f).rsplit("-", 5)
        sid = "-".join(sid[-5:]).replace(".jsonl", "") if len(sid) >= 5 else ""
        title, ts = names.get(sid, ("(未命名会话)", mtime))
        ts = ts or mtime
        if latest is None or ts > latest[1]:
            latest = (title, ts)
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
        # 桌面版请求经常卡几十分钟：turn 开启未收尾（最后事件是 task_started）
        # 即算工作中，放宽到 6 小时；仅靠未完成工具调用判断时仍要求 10 分钟新鲜度
        if (last_task == "task_started" and NOW - mtime < 6 * 3600) or \
           (pending and NOW - mtime < BUSY_MTIME_SEC):
            busy.append(title)
    return n, busy, latest


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


# ---------- ZCode ----------
def zcode_status():
    cli_n = proc_count("zcode-cli")
    app_on = proc_count("ZCode") > 0

    # task_status='running' 会残留僵尸记录，不可信；
    # 改为按会话活动判断：model-io 转录或 artifacts 目录 4 分钟内有写入 = 工作中
    titles, latest = {}, None
    try:
        db = sqlite3.connect(f"file:{ZCODE_DB}?mode=ro", uri=True)
        cur = db.cursor()
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
        elif latest is None or ts > latest[1]:
            pass
    if latest is None and activity:
        sid, ts = max(activity.items(), key=lambda kv: kv[1])
        latest = (titles.get(sid, "(未知任务)"), ts)
    return cli_n, app_on, running, latest


def mark(state):
    return {"busy": "🟢", "idle": "🟡", "off": "⚪️"}[state]


codex_n, codex_busy, codex_latest = codex_status()
kimi_n, kimi_busy, kimi_latest = kimi_status()
zcode_cli_n, zcode_app, zcode_running, zcode_latest = zcode_status()


def state_of(proc_on, busy):
    if busy:
        return "busy"
    return "idle" if proc_on else "off"


cs = state_of(codex_n > 0, codex_busy)
ks = state_of(kimi_n > 0, kimi_busy)
zs = state_of(zcode_cli_n > 0 or zcode_app, zcode_running)

def badge(letter, st, count):
    return f"{letter}🟢{count}" if st == "busy" else f"{letter}{mark(st)}"


print(f"{badge('C', cs, len(codex_busy))} {badge('K', ks, len(kimi_busy))} {badge('Z', zs, len(zcode_running))}")
print("---")

label = {"busy": "工作中", "idle": "空闲", "off": "未运行"}

for name, st, n, busy_titles, latest in (
    ("Codex", cs, codex_n, codex_busy, codex_latest),
    ("Kimi Code", ks, kimi_n, kimi_busy, kimi_latest),
):
    detail = f"{len(busy_titles)} 个任务" if st == "busy" else f"{n} 个进程"
    print(f"{mark(st)} {name}：{label[st]}（{detail}）")
    for t in busy_titles[:3]:
        print(f"▶ {t} | size=11 color=green")
    if latest and not busy_titles:
        print(f"最近任务：{latest[0]} · {age_str(latest[1])} | size=11 color=gray")
    print("---")

parts = []
if zcode_app:
    parts.append("App")
if zcode_cli_n:
    parts.append(f"{zcode_cli_n} CLI")
print(f"{mark(zs)} ZCode：{label[zs]}（{' + '.join(parts) if parts else '无进程'}）")
for t in zcode_running[:3]:
    print(f"▶ {t} | size=11 color=green")
if zcode_latest and not zcode_running:
    print(f"最近任务：{zcode_latest[0]} · {age_str(zcode_latest[1])} | size=11 color=gray")
print("---")
print("🟢工作中  🟡空闲  ⚪️未运行 | size=10 color=gray")
print("刷新 | refresh=true")
