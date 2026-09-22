# jev — macOS assistant

Type plaintext, it does it. Same input every time.

```sh
./run.sh "question"  # CLI
./build-app.sh       # rebuild + launch
open Jev.app         # UI, double-Cmd toggles
```

Type, Enter, done. Jev runs it immediately and reports back.

Things you can say:

Apps — `open excel`, `launch Google Chrome`, `quit slack`.

Spotify — `play SICKO MODE on Spotify`, `pause spotify`, `next song on spotify`.

Chrome — `open my bookmarks`, `open github bookmark`, `search google for best ramen`, `open youtube.com`.

Terminal — `open a new terminal with opencode running`, `terminal run npm test`.

Web — `open gmail`, `search amazon for headphones`, `find airpods on youtube`.
Multi-step jobs (`book a flight from sfo to jfk on kayak`,
`make a github repo with random info`) run start to finish in Chrome:
snapshot, click, type, read, done. Compounds (`open excel then search
amazon for cables`) split into ordered steps. Passwords, logins,
payments, and checkout stop with a status instead of completing.

System — `dark mode`, `volume 40`, `mute`, `set a 5 min timer`.

Answers as text — `what's sequestration?`, `explain ...`, `write ...`

Common commands parse locally (no network). Ambiguous phrasing routes once
through the model into the same allowlisted actions — never free-form shell.

Setup: `.env` with `AI_GATEWAY_API_KEY`, `AI_GATEWAY_MODEL=vmc/jev`.
Needs Accessibility + Automation + Input Monitoring.
Website tasks need one toggle: Chrome → View → Developer →
Allow JavaScript from Apple Events.
