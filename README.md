# SlapShip

A whip for Claude Code, in your Mac's menu bar

Click the whip, press ⌃⌥W, or slap your MacBook: the screen gets lashed (animation + crack sound) and Claude Code gets the message to hurry up and keep it short

Early prototype, open source, macOS 14+, Apple Silicon

## How it works

- menu bar app (Swift, AppKit + Core Animation), no Dock icon
- slap detection reads the built-in accelerometer on Apple Silicon MacBooks (M2+, M1 Pro) through IOKit HID
- every lash is queued in `~/.slapship/state.json`
- a Claude Code hook (`PostToolUse`, `UserPromptSubmit`) picks the lashes up and injects a "be faster, be shorter" note into the session: 1 lash = be concise, 2 = stop deliberating, 3 or a hard slap = wrap up now

## Build

```bash
scripts/bundle.sh          # builds build/SlapShip.app
open build/SlapShip.app
```

## CLI

```bash
SlapShip lash [--hard]     # lash from scripts, Raycast, Stream Deck
SlapShip lash --queue      # queue a lash for Claude without the app
SlapShip install-hooks     # add the hook to ~/.claude/settings.json (backs it up first)
SlapShip uninstall-hooks
SlapShip sensor --debug    # live accelerometer readings, for tuning slap thresholds
```

## License

MIT
