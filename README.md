# jev — macOS assistant

Spotlight-style popup + CLI. Stdlib Swift, no deps.

## Use

```
./run.sh "question"   # one shot
./run.sh              # REPL, `exit` quits
open Jev.app          # UI: type, Enter. Double-Cmd toggles.
./build-app.sh        # rebuild UI + bundle
```

Popup sends screenshot with every ask (vision). Frontmost-app row for context.

Commands: `dark mode` / `light mode` run locally. `click <thing>` locates it on screen, glides real cursor, clicks. All else answered as short macOS steps.

## Files

- `jev.swift` — CLI core. `run.sh` loads ignored `.env`, prefers compiled `jev` binary.
- `PopupPanel.swift` — Spotlight card: frontmost-app row, input, answers.
- `OverlayWindow.swift` — marker + label at target point.
- `Cursor.swift` — real cursor glide + click (`CGEvent`, eased).
- `JevApp.swift` — entry: hotkey, mode toggle, `click` → locate + glide + click.
- `main.swift`, `build-app.sh`, `Jev.app`, `.env` (ignored keys).

## Env

```
AI_GATEWAY_API_KEY=<primary>
AI_GATEWAY_API_KEY_BACKUP=<backup, optional>
AI_GATEWAY_MODEL=vmc/jev
```

Primary first, backup when empty. Model = Virtual Model → `openai/gpt-5-nano` (cheapest, free-tier). Retarget slug in dashboard, no redeploy.

## Permissions

Accessibility + Input Monitoring required for hotkey and real cursor. Overlay needs none.
