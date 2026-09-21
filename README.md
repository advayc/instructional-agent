# jev — macOS assistant

Jev answers questions, does quick system actions itself, and guides on-screen
work step by step with a virtual cursor. You stay on the mouse and keyboard.

```sh
./run.sh "question"   # one-shot CLI
./run.sh              # REPL, `exit` quits
./build-app.sh        # rebuild + launch the app
open Jev.app          # installed app
```

Ask anything. Quick stuff (appearance, volume, timers, opening apps) just
happens. Questions get text answers. Everything else becomes a short visual
guide in the right app — it plans once, then follows live controls without
calling home after every click. Option-Right Arrow advances manually, Escape
stops, double-Command toggles. Drag the header to move the prompt.

## Computer use (arc-cua)

`arc-cua/` runs real UI actions: observe desktop → ask JEV → click/type →
verify. Returns `SUBTASK_COMPLETE`, `BLOCKED`, or `NEEDS_AGENT`.

```sh
cd arc-cua
PYTHONPATH=src ./.venv/bin/python examples/do.py \
  "In System Settings, open Appearance and select Dark." \
  --app "System Settings" \
  --verify "Dark is selected as the current system appearance." \
  --input search_query=Appearance
```

Hands off the Mac for ~60s while it runs. Text it types only ever comes from
your `--input`s. Also see `test_spotify.py`, `test_desktop.py` (Calendar),
and the no-key probes (`macos_ax_probe.py`, `ocr_probe.py`). Needs
`TYPESAFE_API_KEY` in `~/.zshrc`. Local tweaks vs upstream: smaller candidate
budget with auto-retry, plus `do.py`.

## Files

- `JevApp.swift` — lifecycle, guide flow, hotkey, instant actions, app router.
- `Guide.swift` — plan contract, verification, loop budget.
- `DesktopSnapshot.swift` — Accessibility snapshot + target resolver.
- `PopupPanel.swift` — prompt card, answers, planning API call.
- `OverlayWindow.swift` — click-through virtual cursor + captions.
- `jev.swift` — CLI. `build-app.sh`, `main.swift`, `.env` (keys, ignored).

Plain AppKit via `swiftc` — no Xcode, no Electron.

## Setup

```sh
AI_GATEWAY_API_KEY=<primary>          # .env, never shipped in the bundle
AI_GATEWAY_API_KEY_BACKUP=<backup>
AI_GATEWAY_MODEL=vmc/jev
```

Permissions: Screen Recording (visual fallback), Accessibility (controls),
Input Monitoring (follow your clicks). The build signs the full bundle and
installs to `~/Applications` so approvals stick across rebuilds.
