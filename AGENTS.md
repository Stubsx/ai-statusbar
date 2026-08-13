# Repository Guidelines

## Project Structure & Module Organization

`Sources/LingmouCollectorCore/` is the canonical collector. It reads local Codex, Kimi Code, Kimi Work, Claude, Hermes, and ZCode state and preserves the JSON contract consumed by all frontends. `Sources/LingmouCollectorCLI/` builds `lingmou-collector`, which emits JSON with `--json` and SwiftBar text by default. `swiftbar-plugins/ai-cli-status.10s.sh` is the thin SwiftBar launcher. The native menu-bar app lives in `AIStatusBar/`: edit `Sources/main.swift` and `Info.plist`, then run `build.sh` to produce the local `AIStatusBar.app` bundle (git-ignored build artifact, not tracked). `uebersicht-widgets/ai-status.widget/index.jsx` provides the desktop widget and reads the collector from an installed `/Applications/灵眸.app`. App icons belong in `icons/`; release packaging is handled by `scripts/`. Generated DMGs under `dist/` are ignored.

## Build, Test, and Development Commands

```bash
swift test
swift run lingmou-collector --json
./scripts/check-open-source.sh
./AIStatusBar/build.sh
open AIStatusBar/AIStatusBar.app
./scripts/build-dmg.sh
```

The first three commands validate collector output, tests, privacy checks, and Swift compilation. `build.sh` compiles universal `arm64`/`x86_64` app and collector binaries, embeds the collector, and signs both with the configured identity. Local builds prefer the stable self-signed `Lingmou Local` identity and fall back to ad-hoc signing; public releases must use a Developer ID identity and Apple notarization. `build-dmg.sh` rebuilds and creates a versioned installer in `dist/`.

## Coding Style & Naming Conventions

Use four-space indentation and Swift conventions (`PascalCase` types, `camelCase` properties and methods). Preserve encoded JSON field names because they are a shared API between the Swift core, native App, SwiftBar, and JSX. Keep collectors defensive: missing databases, malformed JSONL, or unavailable processes should degrade to empty/idle data instead of crashing. Do not edit files inside `AIStatusBar.app` directly; rebuild them from source.

## Testing Guidelines

Swift collector regression tests live in `tests/LingmouCollectorCoreTests/`. For collector changes, run `swift test` and JSON checks, then verify `busy`, `idle`, and `off` transitions against representative session events. For UI changes, rebuild, launch the app, and inspect menu-bar, popover, settings, and notifications. Include screenshots when visual behavior changes.

## Commit & Pull Request Guidelines

Recent commits use concise Chinese, action-oriented subjects such as `修复 Kimi 幽灵步骤误报` or `新增设置窗口`. Keep each commit focused and explain the behavioral reason. The `AIStatusBar.app` bundle and `dist/` files are local build artifacts — never commit them. Pull requests should summarize the change, list validation commands, note affected agents/frontends, link relevant issues, and attach before/after screenshots for UI work.

## Security & Local Configuration

Never commit user session logs, databases, credentials, `~/.ai-statusbar/settings.json`, or personal absolute paths. Network quota behavior and privacy-sensitive permissions must remain clearly documented; permissions such as notifications and screen recording stay opt-in.
