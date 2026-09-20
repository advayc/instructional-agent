# jev — macOS assistant (v0)

Spotlight-style popup + own overlay cursor. Stdlib Swift, no Xcode, no deps.

## Use

```
./run.sh "question"   # one shot
./run.sh              # REPL, `exit` quits
open Jev.app          # UI: type, Enter. Double-Cmd toggles.
./build-app.sh        # rebuild UI + bundle
```

## Files

- `jev.swift` — CLI core. `run.sh` loads ignored `.env`, prefers compiled `jev` binary.
- `PopupPanel.swift` — Spotlight card: frontmost-app row, input, answers. Every ask sends screenshot (vision).
- `OverlayWindow.swift` — jev's own cursor: yellow arrow + pill label. No rings.
- `Cursor.swift` — real cursor glide + click (`CGEvent`, eased).
- `JevApp.swift` — entry: hotkey, `dark/light mode` toggle, `click <thing>` → vision locate + glide + click.
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
