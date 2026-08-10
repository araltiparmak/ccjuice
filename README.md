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

## How it works — security & privacy

Usage percentages are not persisted on disk by Claude Code, so the app makes a
single kind of external call:

1. Reads your OAuth token from the `Claude Code-credentials` entry in the macOS
   Keychain (the same credential Claude Code itself uses) via
   `SecItemCopyMatching`. macOS decides whether to ask — usually a consent dialog
   on the first read, where **Always Allow** stops it asking again. The app never
   sees your login password.
2. Calls `https://api.anthropic.com/api/oauth/usage` with that token and shows
   the returned `five_hour` / `seven_day` / `seven_day_opus` utilization.

Nothing else is read, stored, or sent anywhere. It's a few hundred lines of
Swift — read `CCJuice.swift` and verify. What that code deliberately does *not*
do is worth stating too, because a usage meter has no business doing any of it:

- **It does not route around the Keychain prompt.** The same secret can be read
  with no dialog at all by shelling out to `/usr/bin/security`, which already
  sits inside the credential's access partition. CCJuice does not do that. An
  app that quietly helps itself to another app's OAuth token is
  indistinguishable from one that steals it, and the dialog is your chance to
  say no. If you decline, the app backs off instead of re-asking on a timer.
- **It does not log your token, or anything a token could hide in.** Error
  responses are server-controlled text and the unified log is readable by
  anything else running as you, so only the server's short error tag
  (`rate_limit_error`) and your token's scope *names* are logged — never a
  response body, never the token, and on success nothing at all.
- **It does not cache anything to disk.** The HTTP session is ephemeral: no URL
  cache, no cookie jar, no shared credential store, so a response fetched with a
  bearer token never lands in `~/Library/Caches`.
- **It does not ask you to weaken your machine.** No trusted certificate to
  install, no sudo, no login item beyond the standard `SMAppService` toggle. The
  app is signed with the hardened runtime, which is what stops another process
  running as you from attaching a debugger or injecting a library to read the
  token out of its memory.
- **It talks to exactly one host,** `api.anthropic.com`, over TLS. There is no
  telemetry, no analytics, and no update check.

## Troubleshooting

- **`CC ⚠︎` in the menu bar** — open the menu; the error is on the first line.
- **Keychain keeps asking** — choose **Always Allow** rather than Allow, and
  macOS remembers the grant. It ties that grant to the app's signature, so the
  question comes back once after a rebuild or a `brew upgrade`. If you rebuild
  often and already have a code-signing identity (`security find-identity -v -p
  codesigning`), build with `CODESIGN_IDENTITY="Apple Development" ./build.sh` —
  a stable signature keeps the grant across rebuilds. The script never creates
  or installs certificates; it only uses one you already have.
- **"Keychain access denied"** — you declined the prompt, so the app stopped
  asking rather than reopening the dialog every five minutes. **Refresh** asks
  again when you're ready.
- **"No Claude Code credential in the Keychain"** — sign in to Claude Code on
  this machine first; CCJuice reads the entry Claude Code creates.
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
- **You ran an old `make-signing-cert.sh`** — that script is gone, but deleting
  it does not undo what it did on a machine that ran it. It left a passphrase-free
  self-signed certificate in your login keychain, marked *trusted for code
  signing*, whose private key `codesign` may use without asking. Anything running
  as you could sign code with it. Remove it:

  ```bash
  security delete-identity -c ccjuice-codesign ~/Library/Keychains/login.keychain-db
  ```

  Then open **Keychain Access → login → Certificates**, and if a
  `ccjuice-codesign` entry remains, delete it there too.
- **swiftc fails with "redefinition of module 'SwiftBridging'"** — a known bug
  in some Command Line Tools releases. `build.sh` detects and works around it
  automatically with a compiler VFS overlay (no sudo, no system files touched).
- **Generic icon in notifications** — macOS caches app icons; it refreshes
  after a re-login or shortly by itself.

## Uninstall

Quit CCJuice (menu → **Quit**) and turn **Start at Login** off if you enabled
it, then:

```bash
brew uninstall ccjuice && brew untap araltiparmak/ccjuice   # Homebrew install
rm -rf CCJuice.app                                          # source build — delete the app wherever you put it
defaults delete app.ccjuice                                 # stored preferences (optional)
```

The app leaves nothing else behind. The Keychain **Always Allow** grant lives
on Claude Code's own credential entry, not in the app; to revoke it, open
Keychain Access, find `Claude Code-credentials`, and remove CCJuice under
**Access Control**.

## Contributing

Issues and PRs welcome. The constraint that matters: it stays **one Swift file
with zero dependencies** — small enough that anyone can read all of it before
trusting it with a Keychain entry.

## Regenerating the icon

```bash
swift make-icon.swift icon-1024.png
# then build an .icns from it with iconutil (see make-icon.swift header)
```

## License

MIT — see [LICENSE](LICENSE).
