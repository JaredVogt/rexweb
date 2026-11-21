# What this fork adds to rexweb

This fork extends [rexweb](https://github.com/acoyfellow/rexweb) in two ways:

1. **Console logging for WebKit (Safari engine) panes.** `rexweb console` and
   `rexweb html` let a script or an agent read a page's console output and
   live HTML.
2. **A Chromium engine.** A second app, `RexWebChromium.app`, draws panes
   with Chromium (through CEF) and adds a network log, the DevTools window,
   raw DevTools Protocol commands, and an optional debugging port.

The work sits on the branch `feat/cef-engine`, nine commits on top of upstream
commit `e23cb9c`. Nothing has been pushed.

For day-to-day usage, read [README.md](../README.md) and
[AGENTS.md](../AGENTS.md). This document explains what changed and why.

## Why

The goal was for an agent running in one Rex pane to open a browser pane,
load a page, and inspect its DOM and console. Upstream rexweb already covered
opening, navigating, `eval`, `snapshot` and `screenshot`. It had no way to
read the console, and WebKit cannot report network traffic or the browser's
own messages (CORS refusals, the reason a request was blocked) to a script. The
console patch closes the first gap. The Chromium engine closes the second.

## Commits

| Commit | What it does |
|---|---|
| `14fb6f5` | Console capture, `html` command, window-pick fix (WebKit) |
| `0d24e80` | Split the app into a shared core and a WebKit engine |
| `adc59b1` | Add the Chromium engine as a second app |
| `2a3cb61` | Route cookie commands and clicked links by engine |
| `f5add8d` | Stop the Rex refresh storm; slow window polling when idle |
| `84d230f` | Document and install the Chromium engine |
| `616d1fa` | Fix load waits, token repair and CLI issues found in review |
| `c26dbae` | Fix scripted click and press on Chromium panes |
| `81260aa` | Add `rexweb cdp`; refuse a pane fragment matched in both apps |

## Part 1: console logging for WebKit panes

### Commands

```sh
rexweb console                       # number, level, text, source
rexweb console --level error,warn    # filter by level
n=$(rexweb console --json | jq .last)
rexweb click e3
rexweb console --since "$n"          # only what the click caused
rexweb console --clear
rexweb html                          # live HTML of the whole page
rexweb html '#main'                  # live HTML of one element
```

Levels are `log`, `info`, `warn`, `error`, `debug` and `navigation`.
`--json` prints `{messages, last, dropped}`.

### How it works

- A script injected at document start (`JS.consoleHook` in
  `Sources/Core.swift`) wraps `console.log`, `info`, `warn`, `error` and
  `debug`. It also listens for page events, so these appear as `error`
  entries too: uncaught exceptions, rejected promises, resources that failed
  to load, and Content Security Policy violations.
- Each message is posted to the app through a WebKit script message handler
  named `rexwebConsole`. The original console method still runs, so Web
  Inspector shows the same output.
- The app keeps the last 1000 messages per pane, each with a sequence number.
  `dropped` counts messages that fell off the front.
- A `navigation` entry is recorded whenever the pane commits a new page, so a
  log that spans page loads stays readable.

### Limits

- WebKit reports cross-origin script errors only as "Script error." with no
  detail. That is a browser rule, not a rexweb one.
- Messages the browser itself writes never pass through `console.*`. A
  WebKit pane reports that a resource failed or a policy blocked something,
  but not the browser's reason, and it shows nothing for CORS refusals.
  Chromium panes show the browser's full message.
- Pages opened from `file://` report limited error detail for the same reason.

### Two fixes that came with it

- **Window pick.** A pane could be drawn over an off-screen twin of its Rex
  window. The app now skips Rex windows that are mostly off every display and
  merges windows that share a frame.
- **False "Uncaught Script error."** `rexweb eval` first tries the code as an
  expression and retries it as statements. The failed first attempt leaked
  into the console log as an error. The app now ignores that one message
  while an `eval` is probing (`probingUntil` in `Panel`).

## Part 2: the Chromium engine

### What you get

| | WebKit pane | Chromium pane |
|---|---|---|
| App | `RexWeb.app`, port 18802 | `RexWebChromium.app`, port 18803 |
| `open`, `nav`, `eval`, `snapshot`, `click`, `type`, `press`, `screenshot`, `html` | yes | yes |
| `console` | page messages | page messages plus the browser's own |
| `network` | no | yes |
| `devtools` | right-click, Inspect Element | `rexweb devtools` |
| `cdp` | no | yes |
| Debugging port | no | optional |
| MP4 (H.264/AAC) video | yes | no; WebM works |
| Size on disk | small | about 290 MB plus a profile |

```sh
id=$(rexweb open --engine chromium localhost:3000)
rexweb console -b "$id" --level error
rexweb network -b "$id" --failed
rexweb devtools -b "$id"
rexweb cdp -b "$id" Page.getLayoutMetrics
```

Only `open` takes `--engine`. Every other command finds the app that owns the
pane. `rexweb ls` marks Chromium panes with `[chromium]`.

### Architecture

Upstream was one Swift file. It is now a shared core with one engine per app.

```
Sources/Core.swift            engine-independent: config, auth, Rex tracking,
                              local HTTP API, panels, injected scripts, links
Sources/WebKitEngine.swift    WKWebView engine
Sources/main.swift            RexWeb.app entry point

chromium/                     SwiftPM package for RexWebChromium.app
  Sources/RexWebChromium/
    Core.swift                symlink to ../../../Sources/Core.swift
    ChromiumEngine.swift      CEF engine
    Main.swift                app entry point, CEF configuration
  Package.swift               pins CefSwift by revision
```

- `Core.swift` talks to an engine through `protocol PageEngine` (load,
  navigate, run script, click, press, screenshot, focus, close) and a small
  `Engine` hook table (name, factory, cookie setter, extra routes).
- The two apps are separate processes with separate ports. They share the
  token file `~/.rexweb/token`. The CLI lists panes from both and routes each
  command to the owner.
- `rexweb-pane`, the script that holds a Rex pane open, picks the app from
  `REXWEB_ENGINE` or the `engine` key in the config file.

### How the Chromium engine works

- It embeds CEF 156 through
  [CefSwift](https://github.com/Rajaniraiyn/CefSwift), pinned to revision
  `880adc0`.
- Almost everything goes through the Chrome DevTools Protocol from inside the
  app, with no open port:
  - `Runtime.evaluate` runs scripts (`eval`, `snapshot`, `html`, `type`).
  - `Runtime`, `Log` and `Page` events feed the console log.
  - `Network` events feed the network log: the last 1000 requests per pane,
    with status, type and failure reason. Headers and bodies are not kept.
  - `Input.dispatchMouseEvent` and `Input.dispatchKeyEvent` deliver `click`
    and `press`. `Page.captureScreenshot` takes screenshots.
- `rexweb devtools` opens CEF's own DevTools window for the pane.
- `rexweb cdp METHOD [PARAMS]` passes one protocol command straight through
  and prints the result.
- `Cmd`-click opens the link in a new pane beside, with the same engine. A
  sized `window.open` becomes a native popup. Other new-window requests load
  in place.

### Configuration

Keys added to `~/.rexweb/config.json`:

| Key | Default | Meaning |
|---|---|---|
| `engine` | `webkit` | Engine for `open`, Shift-Cmd-B, clicked links, and cookie commands |
| `chromium_port` | 18803 | Local API port of `RexWebChromium.app` |
| `chromium_debug_port` | 0 (off) | Chrome DevTools Protocol port, bound to 127.0.0.1 |

The Lua plugin takes a matching `engine` option. The Chromium profile lives
in `~/.rexweb/chromium`.

### Build and install

```sh
./install.sh --with-chromium     # both apps
make install                     # WebKit app and the CLI
make install-chromium            # Chromium app only
```

The first Chromium build downloads CEF. The app is signed ad hoc.

## Fixes that apply to both engines

- **Rex server CPU.** Upstream's window tracker ran `rex` commands whose own
  events triggered more commands, about 200 a second. That held the Rex
  server near 30% CPU per app. The tracker now ignores client connect and
  disconnect events and debounces refreshes. The Rex server sits near 3%.
- **Idle polling.** The window-position timer drops to 10 Hz after one
  second without change. Each app idles near 3% CPU instead of 9%.
- **Token file.** Created exclusively and repaired by write-then-rename, so
  two apps starting together cannot corrupt it.
- **Ambiguous `-b`.** A fragment that matches panes in both apps is refused
  and the matches are listed.

## Problems found on the way, and their fixes

| Problem | Cause | Fix |
|---|---|---|
| Chromium pane vanished when its app restarted | `$appname…` misparsed under the pane's locale | `${appname}` braces in `rexweb-pane` |
| `nav`, `back`, `forward` hung or returned early on Chromium | Load end was inferred from one event | Track an expected load with a grace period and the delegate's finish call |
| A CSP-blocked request stayed "pending" | The failure event arrived before the request event | Stash early events and apply them when the request appears |
| Scripted `click` and `press` did nothing on Chromium | Press and release went out as unordered tasks, and Chromium ignores scripted input on an unfocused page | Send each gesture's events in order; turn on focus emulation |

Focus emulation has one visible effect: a page in a Chromium pane always
reports `document.hasFocus()` as true.

## Security notes

- **Local API.** Unchanged in design: localhost only, and every request needs
  the token. An independent review of the diff found no gap in it.
- **Debugging port.** Off by default. When on, anything on this Mac that can
  reach the port controls every Chromium pane. `rexweb cdp` does not need it.
- **Chromium cookies.** Ad-hoc signing makes CEF use a mock keychain, so any
  process running as you can decrypt the Chromium profile's cookies. Signing
  with a real identity fixes this.
- **CefSwift.** Audited at the pinned revision; nothing malicious. It is a
  young, single-maintainer project, CEF downloads are checked by SHA-1 only,
  and upstream merges CEF version bumps automatically. Review the diff before
  moving the pin.

## Known gaps

- `rexweb cookies import --engine chromium` is untested. One attempt stopped
  before reading anything, probably blocked by macOS privacy protection.
- `Cmd`-click, `links on` with Chromium, `install.sh --with-chromium` and
  `uninstall.sh --purge` have not been run end to end.
- Three WebKit behaviours predate the fork and are not fixed: `nav` can
  return before the page has loaded, `back` can hang for about 40 seconds,
  and `html SELECTOR` can fail right after such a `nav`.
- WebKit panes load `file://` pages with read access to the whole disk.
- The split from one file into a core and two engines makes upstream merges
  harder.
