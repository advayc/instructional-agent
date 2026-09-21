# jev — general macOS assistant

Jev answers general questions directly and guides on-screen work step by step.
Ask anything: it answers chat-style in the popup, does safe instant actions
itself (appearance, volume, timers, opening apps), and otherwise routes a
visual guide to the right Mac app — not just whatever is frontmost. The guide
points to one live control at a time with a transparent virtual cursor and a
type-on caption. You remain in control of the real mouse and keyboard.

## Use

```sh
./run.sh "question"   # text-only CLI helper
./run.sh              # CLI REPL; `exit` quits
./build-app.sh        # rebuild and launch the AppKit app
open Jev.app          # convenience link to the installed app
```

The app hides its prompt once a guide starts and returns focus to the app you
were using. It asks for one short plan, then resolves the next visible target
locally and moves on without another remote round trip after every click. When
Accessibility exposes live controls, the first request sends that compact data
instead of a full-screen image; screenshots remain a fallback for apps that do
not expose usable controls. It uses a short UI-settle check after each action,
verifies the visible end state, and pauses instead of endlessly repeating an
unconfirmed instruction.

Three paths, in order:

1. **Instant native** — dark/light mode, mute/unmute, `volume 40`,
   `set a 5 min timer`, `open Safari`. Runs immediately, no vision needed.
2. **Direct answer** — general questions (`what…?`, `explain…`, `write…`)
   answered as text in the popup, never as clicks inside a random app.
3. **Routed guide** — everything else opens/guides in the right app
   (Clock for alarms, Reminders for todos, System Settings for Wi-Fi/
   wallpaper/Focus, Mail/Calendar/Notes when named). A `5 min timer` no
   longer plans clicks inside VSCode just because it was frontmost.

Model output never becomes shell code; native actions are a fixed safe list.

If it cannot observe an action, press Option-Right Arrow to advance manually.
Escape stops the guide, and double-Command toggles Jev.

Drag the prompt from its header (labelled **Drag to move**) to keep it out of
the way. Its location is remembered for the next launch.

The overlay is visual only: it never moves, clicks, or types with the real
cursor.

## Files

- `JevApp.swift` — app lifecycle, guide progression, hotkey, and action detection.
- `Guide.swift` — bounded guide-plan contract, verification criteria, and loop budget.
- `DesktopSnapshot.swift` — local macOS Accessibility snapshot, live target resolver, and freshness guard.
- `PopupPanel.swift` — compact task prompt, reduced-size screenshot request, and grounded planning API call.
- `OverlayWindow.swift` — click-through transparent virtual cursor and animated caption.
- `jev.swift` — separate text-only CLI core.
- `setup-signing.sh` — locates the stable local signing identity used to retain macOS permissions across rebuilds.
- `build-app.sh`, `main.swift`, `Jev.app`, `.env` (ignored keys).

The UI is plain AppKit compiled with `swiftc`; it uses neither SwiftUI nor
Xcode, so Electron is not needed.

The fast guide runtime is a native Swift adaptation of the bounded-subtask,
freshness, and explicit `complete` / `blocked` ideas in
[arc-cua](https://github.com/shhivv/arc-cua) (MIT). It does not add a Python
runtime or external dependency to Jev.

## Environment

```sh
AI_GATEWAY_API_KEY=<primary>
AI_GATEWAY_API_KEY_BACKUP=<backup, optional>
AI_GATEWAY_MODEL=vmc/jev
```

`build-app.sh` copies the development `.env` to the user-only Application
Support folder (`~/Library/Application Support/Jev/.env`), never into the app
bundle. Do not distribute a bundle containing a personal gateway key; use a
Keychain-backed or server-side credential flow first.

## Permissions

- **Screen Recording** — lets Jev use a visual snapshot. The app only checks
  this permission while starting a guide; it never repeatedly summons a macOS
  permission sheet when the system has a stale approval record. It falls back
  to local Accessibility controls when screen capture is temporarily
  unavailable.
- **Accessibility** — enables that local fallback and makes cursor targets more
  reliable in native and Electron apps.
- **Input Monitoring** — lets it notice your click, typing, or scroll and move
  to the next guide step. The app still cannot and does not send input for you.

The build signs the entire Jev bundle, installs it in `~/Applications`, then
launches it through macOS so privacy approval applies to Jev rather than a bare
terminal process. It uses a valid Apple Development / Developer ID identity
when available; otherwise it creates one user-local development identity in the
login keychain. That keeps its privacy identity stable across rebuilds instead
of falling back to an ad-hoc signature that macOS sees as a new app each time.
