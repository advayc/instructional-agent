# jev — macOS text assistant

Spotlight-style popup for asking questions without leaving current app. Text-only. Stdlib Swift, no dependencies.

## Use

Every query routes through `jev` CLI core:

```
./run.sh "go to Appearance and change to light mode"
./run.sh            # interactive REPL with history, `exit` quits
```

`run.sh` loads ignored `.env` and execs compiled `jev` binary. Rebuild after editing source:

```
swiftc -O jev.swift -o jev
```

## Files

- `jev.swift` — text core. Reads `AI_GATEWAY_API_KEY` (falls back to `AI_GATEWAY_API_KEY_BACKUP`), posts to AI Gateway chat endpoint.
- `run.sh` — sources `.env`, execs `jev`. Use this, not raw `swift`.
- `PopupPanel.swift` — centered Spotlight-style panel. Placeholder "What should I do?", context row shows frontmost app name.
- `OverlayWindow.swift` — fullscreen transparent overlay, yellow dashed ring + label for pointing at things on screen.
- `JevApp.swift` — app entry wiring popup + overlay + double-Cmd hotkey.
- `.env` — ignored secret storage. Never commit.

## Env (.env)

```
AI_GATEWAY_API_KEY=<primary key>
AI_GATEWAY_API_KEY_BACKUP=<backup key, optional>
AI_GATEWAY_MODEL=vmc/jev
```

Primary first, backup when primary empty.

## Model

Default `vmc/jev`: Virtual Model slug pointing at `openai/gpt-5-nano` ($0.05/1M input, $0.40/1M output), free-tier eligible, fast. Retarget slug in Gateway dashboard to swap models with no redeploy. Step up to `openai/gpt-5-mini` only when answers need more reasoning.

## macOS permissions

Grant Accessibility + Input Monitoring or double-Cmd hotkey and real cursor control will not work. Fake overlay ring needs none.
