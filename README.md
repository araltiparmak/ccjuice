# CCJuice

> How much juice is left in your Claude Code tank?

[![build](https://github.com/araltiparmak/ccjuice/actions/workflows/build.yml/badge.svg)](https://github.com/araltiparmak/ccjuice/actions/workflows/build.yml)

A tiny macOS menu bar app that shows how much of your Claude Code usage limits
you have left — session (5-hour) and weekly — right next to the clock.

<!-- ![Menu bar](docs/menubar.png) — add docs/menubar.png and uncomment -->

Menu bar: `S58% W78%` (S = session, W = week, percent remaining — switch to percent
used under **Display**).

## Features

- Session, weekly, and — on Max plans — weekly Opus quota, with reset countdowns.
- Burn-rate projection: "At this pace, session empty in ~1h 05m".
- Color warning in the menu bar: orange below your chosen threshold, red at 10%.
- Optional notifications when usage runs low (threshold configurable: 10/20/30/50%)
  and when the session resets.
- Display modes: both percentages, session only, week only, or only the lowest one.
- Count either way: show what's **remaining** (default) or what's been **used**.
- Start at Login toggle (macOS 13+), one-click jump to claude.ai usage settings.
- Single Swift file, AppKit `NSStatusItem`, zero dependencies.
- Refreshes every 5 minutes, on demand via **Refresh**, and immediately on wake
  from sleep.

## Requirements

- macOS 12 or later (Start at Login toggle needs 13+)
- Xcode Command Line Tools (`xcode-select --install`) to build
- [Claude Code](https://claude.com/claude-code) logged in on the same machine

## Install

### From source

```bash
git clone https://github.com/araltiparmak/ccjuice.git
cd ccjuice
./build.sh
open CCJuice.app
```

### Homebrew

```bash
brew tap araltiparmak/ccjuice https://github.com/araltiparmak/ccjuice
brew install --HEAD araltiparmak/ccjuice/ccjuice
open "$(brew --prefix)/opt/ccjuice/CCJuice.app"
```

On first launch macOS asks for permission to read the Claude Code credential
from your Keychain — choose **Always Allow** so it doesn't ask again. Enabling
notifications triggers the standard notification permission prompt once.

## How it works — security & privacy

Usage percentages are not persisted on disk by Claude Code, so the app makes a
single kind of external call:

1. Reads your OAuth token from the `Claude Code-credentials` entry in the macOS
   Keychain (the same credential Claude Code itself uses). The Keychain prompt
   you approve is macOS enforcing access to that entry — the app never sees
   your password.
2. Calls `https://api.anthropic.com/api/oauth/usage` with that token and shows
   the returned `five_hour` / `seven_day` / `seven_day_opus` utilization.

Nothing else is read, stored, or sent anywhere. It's a few hundred lines of
Swift — read `CCJuice.swift` and verify.

## Troubleshooting

- **`CC ⚠︎` in the menu bar** — open the menu; the error is on the first line.
- **"Token expired"** — run Claude Code once; it refreshes the token.
- **"Token lacks the user:profile scope"** — the usage endpoint requires the
  `user:profile` scope. A credential created by `claude setup-token` only carries
  `user:inference`, so sign in to Claude Code with `/login` instead; the new
  Keychain entry has both scopes. Editing the entry in Keychain Access does not
  help — the scope is baked into the token by the server, and the `scopes` array
  stored next to it is only a label. The exact scopes on the stored token are
  logged next to any HTTP error (`log show --predicate 'process == "CCJuice"'`).
  After signing in again, use **Refresh** to re-check immediately.
- **An error sticks around after you fixed it** — after a failure the app backs
  off before retrying. **Refresh** overrides that wait. The one exception is
  a rate limit, which has to be waited out.
- **swiftc fails with "redefinition of module 'SwiftBridging'"** — a known bug
  in some Command Line Tools releases. `build.sh` detects and works around it
  automatically with a compiler VFS overlay (no sudo, no system files touched).
- **Generic icon in notifications** — macOS caches app icons; it refreshes
  after a re-login or shortly by itself.

## Regenerating the icon

```bash
swift make-icon.swift icon-1024.png
# then build an .icns from it with iconutil (see make-icon.swift header)
```

## License

MIT — see [LICENSE](LICENSE).
