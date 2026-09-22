# jev — macOS assistant (v1)

Spotlight-style popup that does things. Stdlib Swift, no Xcode, no deps.

## Use

```
./run.sh "question"   # one shot
./run.sh              # REPL, `exit` quits
open Jev.app          # UI: type, Enter runs it. Esc hides. Double-Cmd toggles.
./build-app.sh        # rebuild UI + bundle
```

## Files

- `jev.swift` — CLI core. `run.sh` loads ignored `.env`, prefers compiled `jev` binary.
- `Actions.swift` — local parser + runner: apps, Spotify, Chrome, Terminal, system. Multi-step planner returns ordered JSON steps, no vision, no shell from model.
- `Web.swift` — sites + search URLs, agent loop driving Chrome via AppleScript JS (snapshot/click/type/press/read, 8 rounds). Stops at passwords/payments/checkout.
- `PopupPanel.swift` — Spotlight card: frontmost-app row, input, confirmation + answers.
- `OverlayWindow.swift` — completion toast. No rings.
- `JevApp.swift` — entry: hotkey, parse → confirm → execute. Questions answered as text.
- `main.swift`, `build-app.sh`, `Jev.app`, `.env` (ignored keys).
- Retired from build (kept on disk): `Guide.swift`, `DesktopSnapshot.swift`, `Cursor.swift`, `arc-cua/`.

## Env

```
AI_GATEWAY_API_KEY=<primary>
AI_GATEWAY_API_KEY_BACKUP=<backup, optional>
AI_GATEWAY_MODEL=vmc/jev
```

Primary first, backup when empty. Model = Virtual Model → `openai/gpt-5-nano` (cheapest, free-tier). Retarget slug in dashboard, no redeploy. Only used for ambiguous phrasing + text answers; common commands run fully local.

## Permissions

Accessibility for keystroke-driven actions (Spotify play), Automation for Terminal/Spotify/Chrome AppleScript. Input Monitoring for double-Cmd hotkey. Overlay needs none.
