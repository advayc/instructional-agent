# jev — on-screen macOS guide

Jev is a fast, visual guide rather than a chatbot. Describe a task, then it
points to one visible control at a time with a transparent virtual cursor and
a type-on caption. You remain in control of the real mouse and keyboard.

## Use

```sh
./run.sh "question"   # text-only CLI helper
./run.sh              # CLI REPL; `exit` quits
./build-app.sh        # rebuild and launch the AppKit app
open Jev.app          # type a task and press Return
```

The app hides its prompt once a guide starts. Click the marked control, type,
or scroll as the caption asks; Jev captures the updated screen and immediately
draws the next step. If it cannot observe an action, press Option-Right Arrow
to advance manually. Escape stops the guide, and double-Command toggles Jev.

The overlay is visual only: it never moves, clicks, or types with the real
cursor.

## Files

- `JevApp.swift` — app lifecycle, guide progression, hotkey, and action detection.
- `Guide.swift` — validated one-step guide model; model output is never executed.
- `PopupPanel.swift` — compact task prompt, screenshot request, and grounded next-step API call.
- `OverlayWindow.swift` — click-through transparent virtual cursor and animated caption.
- `jev.swift` — separate text-only CLI core.
- `setup-signing.sh` — locates the stable local signing identity used to retain macOS permissions across rebuilds.
- `build-app.sh`, `main.swift`, `Jev.app`, `.env` (ignored keys).

The UI is plain AppKit compiled with `swiftc`; it uses neither SwiftUI nor
Xcode, so Electron is not needed.

## Environment

```sh
AI_GATEWAY_API_KEY=<primary>
AI_GATEWAY_API_KEY_BACKUP=<backup, optional>
AI_GATEWAY_MODEL=vmc/jev
```

Keep `.env` beside the development `Jev.app` or provide the values through the
launch environment. `build-app.sh` deliberately does **not** copy `.env` into
the app bundle. Do not distribute a bundle containing a personal gateway key;
use a Keychain-backed or server-side credential flow first.

## Permissions

- **Screen Recording** — lets Jev identify the currently visible control.
- **Input Monitoring** — lets it notice your click, typing, or scroll and move
  to the next guide step. The app still cannot and does not send input for you.

The build signs Jev with an existing Apple Development or Developer ID identity
from your login keychain. That gives the app a stable macOS privacy identity
across rebuilds without requiring Xcode. After the next launch, approve the
fresh Screen Recording prompt for Jev once and restart the app.
