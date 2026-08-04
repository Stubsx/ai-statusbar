# Repository Guidelines

## Project Structure & Module Organization

`swiftbar-plugins/ai_status.py` is the canonical collector. It reads local Codex, Kimi, Claude, Hermes, and ZCode state and emits either SwiftBar text or the JSON contract consumed by other frontends. `ai-cli-status.10s.py` is the thin SwiftBar launcher. The native menu-bar app lives in `AIStatusBar/`: edit `Sources/main.swift` and `Info.plist`, then run `build.sh` to produce the local `AIStatusBar.app` bundle (git-ignored build artifact, not tracked). `uebersicht-widgets/ai-status.widget/index.jsx` provides the desktop widget. App icons belong in `icons/`; release packaging is handled by `scripts/`. Generated DMGs under `dist/` are ignored.

## Build, Test, and Development Commands

```bash
python3 swiftbar-plugins/ai_status.py --json | python3 -m json.tool
python3 -m py_compile swiftbar-plugins/ai_status.py
./AIStatusBar/build.sh
open AIStatusBar/AIStatusBar.app
./scripts/build-dmg.sh
```

The first two commands validate collector output and syntax. `build.sh` compiles a universal `arm64`/`x86_64` app, copies the collector into the bundle, and signs it with the stable self-signed `Lingmou Local` identity (falls back to ad-hoc when the certificate is absent, e.g. on another machine). The stable identity keeps TCC grants (screen recording, notifications) valid across rebuilds. `build-dmg.sh` rebuilds and creates a versioned installer in `dist/`.

## Coding Style & Naming Conventions

Use four-space indentation in Python and Swift. Follow `snake_case` for Python functions and fields, `UPPER_CASE` for constants, and Swift conventions (`PascalCase` types, `camelCase` properties and methods). Preserve JSON field names because they are a shared API between Python, Swift, and JSX. Keep collectors defensive: missing databases, malformed JSONL, or unavailable processes should degrade to empty/idle data instead of crashing. Do not edit files inside `AIStatusBar.app` directly; rebuild them from source.

## Testing Guidelines

There is no automated test suite or coverage threshold yet. For collector changes, run syntax and JSON checks, then verify `busy`, `idle`, and `off` transitions against representative session events. For UI changes, rebuild, launch the app, and inspect menu-bar, popover, settings, and notifications. Include screenshots when visual behavior changes.

## Commit & Pull Request Guidelines

Recent commits use concise Chinese, action-oriented subjects such as `修复 Kimi 幽灵步骤误报` or `新增设置窗口`. Keep each commit focused and explain the behavioral reason. The `AIStatusBar.app` bundle and `dist/` files are local build artifacts — never commit them. Pull requests should summarize the change, list validation commands, note affected agents/frontends, link relevant issues, and attach before/after screenshots for UI work.

## Security & Local Configuration

Never commit user session logs, databases, credentials, or `~/.ai-statusbar/settings.json`. The Übersicht command currently contains an absolute local path; update it for local use without introducing personal paths into unrelated changes.
