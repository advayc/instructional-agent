# jev — macOS text assistant (v0)

Spotlight-style popup for asking questions without leaving the current app.
Text-only. No voice yet. Stdlib Swift, no dependencies.

## How to use

Ask anything through jev (the CLI core — every query routes through it):

```
./run.sh "go to Appearance and change to light mode"
./run.sh            # interactive REPL with history, `exit` quits
```

`run.sh` loads the ignored `.env` and execs the compiled `jev` binary
(rebuild with `swiftc -O jev.swift -o jev` after editing the source).

## Files

- `jev.swift` — text core. Reads `AI_GATEWAY_API_KEY` (falls back to
  `AI_GATEWAY_API_KEY_BACKUP`), posts to the AI Gateway chat endpoint.
- `run.sh` — sources `.env`, execs `jev.swift`. Use this, not raw `swift`.
- `PopupPanel.swift` — centered Spotlight-style panel. Placeholder
  "What should I do?", context row shows the frontmost app name.
- `OverlayWindow.swift` — fullscreen transparent overlay, yellow dashed
  ring + label for pointing at things on screen.
- `JevApp.swift` — app entry wiring popup + overlay + double-Cmd hotkey.
- `main.swift` — top-level entry for `swiftc` builds (no Xcode project).
- `jev-ui` — compiled UI binary (`swiftc -O JevApp.swift PopupPanel.swift OverlayWindow.swift main.swift -o jev-ui`). Launch it, type, hit Enter.
- `.env` — ignored secret storage. Never commit. Holds primary key,
  backup key, and model.

## Env (.env)

```
AI_GATEWAY_API_KEY=<primary key>
AI_GATEWAY_API_KEY_BACKUP=<backup key, optional>
AI_GATEWAY_MODEL=vmc/jev
```

Key fallback: primary first, backup when primary is empty. Paste the
backup key after `AI_GATEWAY_API_KEY_BACKUP=` — nothing else to change.

## Model

Default is `vmc/jev`: a Virtual Model slug pointing at `openai/gpt-5-nano`,
the cheapest GPT tier ($0.05/1M input, $0.40/1M output), free-tier eligible,
fast. Retarget the slug in the Gateway dashboard to swap models with no
redeploy. Step up to `openai/gpt-5-mini` only when answers need more reasoning.

## macOS permissions

Grant Accessibility + Input Monitoring or the double-Cmd hotkey and any
real cursor control will not work. Fake overlay ring needs none.
