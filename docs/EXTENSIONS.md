# What this fork adds to rexweb

This fork extends [rexweb](https://github.com/acoyfellow/rexweb) in three ways:

1. **Console logging for WebKit (Safari engine) panes.** `rexweb console` and
   `rexweb html` let a script or an agent read a page's console output and
   live HTML.
2. **A Chromium engine.** A second app, `RexWebChromium.app`, draws panes
   with Chromium (through CEF) and adds a network log, the DevTools window,
   raw DevTools Protocol commands, and an optional debugging port.
3. **Tabs inside a pane.** A browser pane holds several pages, in both
   engines. Tabs come back after a restart, and idle ones are unloaded.

Parts 1 and 2 sit on the branch `feat/cef-engine`, ten commits on top of
upstream commit `e23cb9c`. Part 3 sits on the branch `feat/tabs`, which is
built on `feat/cef-engine`. Nothing has been pushed.

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
| `b3b8608` | Add this document |
| `0cc8651` | Add tabs to the pane core (`feat/tabs`) |
| `249a671` | Open links as tabs in WebKit panes |
| `5cd19d6` | Open links as tabs in Chromium panes |
| `c07bc78` | Add tab commands and `--tab` to the CLI |
| `3141744` | Document tabs |
| `f7296d8` | Fix tab defects found in review |

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
- The app keeps the last 1000 messages per tab, each with a sequence number.
  `dropped` counts messages that fell off the front.
- A `navigation` entry is recorded whenever the tab commits a new page, so a
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
  while an `eval` is probing (`probingUntil` in `Tab`).

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
  `Engine` hook table (name, factory, cookie setter, extra routes, and the
  routes that need their tab on show).
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
  - `Network` events feed the network log: the last 1000 requests per tab,
    with status, type and failure reason. Headers and bodies are not kept.
  - `Input.dispatchMouseEvent` and `Input.dispatchKeyEvent` deliver `click`
    and `press`. `Page.captureScreenshot` takes screenshots.
- `rexweb devtools` opens CEF's own DevTools window for the pane.
- `rexweb cdp METHOD [PARAMS]` passes one protocol command straight through
  and prints the result.
- A sized `window.open` becomes a native popup. Other new-window requests
  open a tab; see [Part 3](#part-3-tabs-inside-a-pane).

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

## Part 3: tabs inside a pane

### What you get

A pane holds one or more tabs, and shows one. A pane with one tab looks and
behaves as it did before. With two or more, a 26-point strip of tabs sits
above the address bar, with a close button per tab and a `+` button.

| Action | Result |
|---|---|
| `Cmd`-click a link | New tab behind the current one, placed right after it |
| `Shift-Cmd`-click a link | New tab in front, placed right after the current one |
| `Shift`-click a link (Chromium panes) | New tab in front |
| `target="_blank"` link, `window.open` with no size | New tab in front |
| `window.open` with a size | Native popup window, as before |
| `Cmd-Opt`-click a link | New pane beside |
| `Cmd-T` | New blank tab at the end, with the address bar focused |
| `Cmd-W` | Close the tab; on the last tab, close the pane |
| `Ctrl-Tab`, `Ctrl-Shift-Tab` | Next and previous tab, wrapping round |

```sh
rexweb tabs [--json]                 # list the pane's tabs
rexweb tab new [URL] [--background] [--no-wait]
rexweb tab select TAB                # show a tab
rexweb tab close [TAB]               # close a tab; the last one closes the pane
rexweb eval --tab t2 'document.title'   # --tab or -t on every page command
```

`tabs` prints one line per tab: position, ID, a mark for the showing tab,
title and URL, with `[asleep]` on a sleeping tab. `tab new` prints the new
tab's ID and then waits for the page, as `open` does. `tab ls` is the same
as `tabs`. `rexweb ls` adds `[3 tabs]` to a pane that has more than one, and
a command that prints one pane adds `[tab t2, 2 of 3]`.

`--tab` is refused by `close`, `ls`, `doctor`, `tabs` and `tab new`. On
`open` it keeps its older meaning: put the pane in a new Rex tab. `rexweb
close` closes the whole pane and now refuses positional arguments.

### Decisions, and why

- **Links open tabs, not panes.** Before this, `Cmd`-click split the Rex
  layout every time. A tab keeps the layout as it is. A pane beside is still
  one modifier away.
- **The strip hides for one tab.** A pane that never opens a second tab
  loses no space and looks as upstream's does.
- **A tab opened from a link has no `window.opener`.** It is a separate
  page, not a child of the page that opened it, and the `window.open` call
  that made it returns null. Sign-in flows that hand a
  result back to their opener use sized popups, and those still open as
  native windows and keep their opener.
- **Only shortcuts that Rex does not need.** The tab shortcuts apply while a
  browser pane has the keyboard. `Cmd-1` to `Cmd-9`, `Shift-Cmd-[` and
  `Shift-Cmd-]` are left to Rex, where they switch Rex's own tabs.
- **Agent commands leave the visible tab alone.** An agent working in a
  background tab must not pull the page out from under the person. No
  command switches tabs. A command that needs a page that is drawing, which
  is `screenshot` in a WebKit pane, has the page drawn behind the one on
  show. An earlier version switched tabs and switched back; that moved the
  address bar and the keyboard, and a command without a tab could land on
  the borrowed tab.
- **Do not unload what would be lost.** Freeing memory is not worth a
  half-filled form or a call in progress, so a tab with something to lose
  stays loaded and says why.
- **No tab argument means the showing tab.** Every script written before
  tabs keeps working.

### Design

Everything that belongs to one page moved from `Panel` to a new class, `Tab`,
in `Sources/Core.swift`: the engine, the console log, the load waiters, the
last load error, and the engine callbacks. `Panel` keeps the overlay window,
the toolbar, the tab strip, and what the Rex tracker uses. `Panel.engine`
returns the showing tab's engine, so the tracker and the key handler did not
change. Engines now take a `Tab` where they took a `Panel`.

- **IDs.** Each pane numbers its tabs `t1`, `t2`, and so on from its own
  counter. An ID is not reused, and the IDs and the counter are saved, so
  an ID that a script holds names the same page after a restart, or nothing.
  The API and the CLI take an ID or a position counted from 1.
- **Live and asleep.** A tab is live, with an engine, or asleep, with only
  its URL, title and console log. This one state serves both session restore
  and unloading. Reading `tab.engine` wakes a tab: it makes the engine, puts
  its view in the pane, and loads the saved URL. Code that lists tabs reads
  `url`, `title` and `isLive`, which never wake one.
- **Views.** Every live tab's view is a subview of the pane's root view, and
  all but the showing one are hidden. Each gets the page rectangle.
- **Repaint only on change.** The strip compares its items before it
  redraws, and layout sets a frame only when it differs. A control in a Rex
  pane that repaints constantly drives Rex's CPU up.

### Links, per engine

- **WebKit.** The navigation delegate sees the modifier keys of a clicked
  link: Command opens a background tab, with Shift a foreground tab, with
  Option a pane beside. A new-window request with no size, such as a
  `target="_blank"` link or `window.open(url)`, opens a tab. A request with
  a size opens a native popup. So does a `window.open` with no URL or an
  `about:` URL, even without a size, so that a page that opens a blank
  window and fills it in keeps working.
- **Chromium.** CEF reports a disposition, not the keys, and only requests
  that come from a user gesture and carry a URL are handled. A
  background-tab disposition (`Cmd`-click) opens a background tab. A
  foreground-tab or new-window disposition (`Shift-Cmd`-click,
  `Shift`-click, `target="_blank"`, an unsized `window.open`) opens a
  foreground tab. A split-view disposition, which is how Chromium reports
  `Cmd-Opt`-click, opens a pane beside. A popup disposition opens a native
  popup, which keeps its opener.
- **Both.** A tab that would open in front does so only if the page that
  asked is the showing tab. A page in a background tab opens its tab in the
  background.

### Commands on a background tab

A command for a tab that is not showing runs on the hidden page. `Engine`
holds a set of routes that need a page that is drawing, `needsVisible`, and
each app sets it for its engine. For a route in the set the pane borrows the
page: it unhides the tab's view behind the view of the tab on show, waits
150 ms, runs the command, and hides the view again once the command has
replied. The tab on show, the strip, the address bar and the keyboard focus
do not change, and the borrowed page stays out of sight and out of reach of
the mouse.

The pane and the tab are resolved once per command. A command that has to
wait, for a wake or for a borrow, continues with the same two. If either has
gone it fails with "the pane was closed" or "the tab was closed".

| Engine | Routes that borrow the page |
|---|---|
| WebKit | `screenshot` |
| Chromium | none |

- **WebKit.** `click`, `type` and `press` reach a background tab because the
  engine sends mouse and key events straight to the web view, not through
  the window. A background tab is a hidden page: `visibilityState` is
  `"hidden"`, no animation frames run, CSS transitions stand still, and
  timers fire about once a second. That is why `screenshot` has the page
  drawn first.
- **Chromium.** Input and screenshots go through the DevTools Protocol and
  run in place. A screenshot is one pixel per CSS pixel of the tab's
  viewport. The engine tells Chromium when a tab's view is hidden, and
  keeps focus emulation on only for the tab on show, so a background tab is
  a hidden page here too: `visibilityState` is `"hidden"`, no animation
  frames run, and timers fire about once a second. A screenshot of it still
  shows the page as it is now. Scripted input on a background tab turns
  focus emulation on while the input is delivered, so `document.hasFocus()`
  can read true there for that time; the page stays hidden and does not
  draw. A DevTools call that the page never answers fails after 25 seconds,
  which caps `eval` and `cdp`.

In both engines, a page that only renders inside `requestAnimationFrame`
does not update while its tab is in the background.

The borrow has three rules:

- One tab is borrowed at a time. A command for another tab of the same pane
  waits for the first, for up to 30 seconds, and then fails. Commands for
  the same tab share the borrow.
- If the person selects another tab meanwhile, the borrowed page keeps
  drawing behind it until its command replies.
- A borrow is given up after 60 seconds even if its command never replies.

### Session restore

Each app writes its panes' tabs to `~/.rexweb/tabs-<engine>.json` about a
second after any change, and once more when it quits or gets SIGTERM, which
is what `pkill` sends. The file lists every open page, so it is written to
a new file created at mode 600 and then moved into place.

```json
{ "<pane ID>": { "active": 1, "counter": 4, "saved": 1795000000,
                 "tabs": [ { "id": "t2", "url": "...", "title": "..." } ] } }
```

`active` is the showing tab's position counted from 0, `counter` is the
highest tab number the pane has given out, and `saved` is when the entry was
written.

- When a pane registers and the file has an entry for its ID, the pane gets
  those tabs back and the URL that the pane script sends is ignored. Only
  the tab that was showing is live. The rest start asleep.
- Blank tabs are not restored. If the showing tab was blank, the nearest
  earlier tab shows. If every tab was blank, the pane starts fresh.
- Each tab keeps its ID, and the counter carries on. A blank tab's ID is
  gone with the tab. A file from before IDs were saved has none, and its
  tabs are numbered from `t1`.
- Closing the pane removes its entry. The pane script reports the close
  when its Rex pane goes away. Killing the app reports nothing, and that is
  the case to restore.
- Entries older than 30 days are dropped when the file is read. An open
  pane's entry is renewed once a day, so only panes that went away without
  a close are pruned.

### Unloading

Once a minute, each app looks for background tabs that are live, are not
loading, have no command running or waiting, and were last used more than
`tab_unload_minutes` ago. "Used" means selected, or addressed by an API
command other than `info`. The showing tab never sleeps.

Each such tab's engine is then asked whether anything would be lost
(`PageEngine.unloadBlocker`). A tab with a reason to stay is kept, and the
reason shows as `unload_blocked` in `/tabs`. A page that does not answer
within 10 seconds is kept too.

| Keeps a tab loaded | WebKit | Chromium |
|---|---|---|
| Playing audio | yes | yes, and for a minute after |
| Camera or microphone in use | yes | yes, and screen capture |
| A form field changed by the person or a script | yes | yes |
| A `beforeunload` handler | `window.onbeforeunload` only | yes |
| A popup window open | yes | no |
| DevTools open, a download running, picture in picture, a connected device | no | yes |

WebKit asks the web view and a script in the page (`JS.unloadProbe`).
Chromium asks its own tab-discard rules first and then runs the same script,
because Chromium counts only what a person typed, not what `rexweb type`
filled in.

A sleeping tab reloads its URL when it is selected or when a command is
aimed at it. The command waits for that load before it runs. If the page has
not loaded after 20 seconds, the command fails without running and tells the
caller to run `rexweb wait -t TAB` and try again. The limit is below the 30
seconds that the CLI waits for an answer. `wait` wakes the tab and uses its
own timeout. `info` and `console` answer without waking the tab. `nav` wakes
it straight onto the new URL.

| Key | Default | Meaning |
|---|---|---|
| `tab_unload_minutes` | 30 | Minutes before an idle background tab is unloaded. 0 turns unloading off |

### API

Every pane route accepts `tab`. The pane's `info` gains `tab`, `tab_index`,
`tabs`, `tab_active` and `tab_asleep`. `visible` is now per tab: the pane is
on screen and the tab is the one on show. The new `pane_visible` holds the
pane-level value that `visible` used to.

| Route | Input | What it does |
|---|---|---|
| `/tabs` | | Lists the pane's tabs: `{id, active, tabs: [{id, index, url, title, active, asleep, loading, unload_blocked}]}` |
| `/tab/new` | `url`, `background` | Opens a tab at the end and returns its `info` |
| `/tab/select` | `tab` | Shows a tab, waking it if needed |
| `/tab/close` | `tab` | Closes a tab, the showing one by default. Returns `{id, closed, pane_closed, tabs, active}` |

`/cookies/import` with `reload` reloads every live tab of every pane, not
only the showing ones. Sleeping tabs read the new cookies when they wake.

### Limits

- A tab that sleeps loses its back and forward history and its page state:
  form input, scroll position, and anything held in JavaScript. It reloads
  from its URL only.
- A Chromium tab that sleeps also loses its network log, which lives in the
  engine. The console log is kept in both engines.
- A restored pane keeps its tabs' IDs, URLs and titles, nothing else. No
  history comes back for any tab, the showing one included.
- A tab opened from a link has no `window.opener`.
- A page in a background tab runs as a hidden page in both engines, with
  slow timers and no animation frames. Only the showing tab reports focused
  and visible.
- `screenshot` of a background WebKit tab takes about 150 ms longer, while
  the page is drawn behind the one on show. Screenshots of two different
  background tabs of one pane run one after the other.
- A link, `target="_blank"` or `window.open` to anything but `http`,
  `https`, `file`, `about`, `data` or `blob` opens no tab or pane. The
  opener tab's console gets a warning.
- On WebKit, a `beforeunload` handler added with `addEventListener` does not
  keep a tab from being unloaded; only `window.onbeforeunload` is seen.
- A Chromium screenshot is at 1x, not at the screen's Retina scale.
- Tabs cannot be reordered, dragged between panes, or pinned, and there is
  no shortcut to reopen a closed tab.

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
| `type` into a rich editor (`contenteditable`) silently did nothing on Chromium, and focus emulation was never actually on | A DevTools command sent without a completion handler was never sent | Send first, then call the handler if there is one |
| Scripted clicks were dropped on WebKit when RexWeb was not the active app; a click or key press could land on the wrong tab or in the address field | Events went through the window, which routes them by app and focus state | Send mouse and key events straight to the web view |
| During a screenshot of a background tab, the address bar, shortcuts and commands without a tab acted on the borrowed tab | The borrow selected the tab and selected the earlier one afterward | Draw the borrowed page behind the page on show; the active tab never changes |
| A command that woke a sleeping tab could run on another pane, or run late after its caller had given up | The command was looked up again by pane and tab after the wait, and ran anyway after 30 seconds | Resolve the pane and tab once; fail after 20 seconds without running |
| Unloading threw away form input, playing audio and open popups | The timer looked only at idle time | Ask the engine first, and keep a tab that has something to lose |
| Tab IDs changed on restart, so a script's ID could name a different page | IDs were renumbered from `t1` | Save each tab's ID and the pane's counter |
| A tab change in the last second before `pkill` was lost; the session file was briefly readable by others | The save was debounced, and the mode was set after the write | Save on quit and on SIGTERM; create the file at mode 600 |
| A Chromium command could hang for good | A DevTools call that the page never answered had no timeout | Time out after 25 seconds |
| Scripted input did nothing on a background Chromium tab | Focus emulation is off for a hidden tab, and Chromium drops input on an unfocused page | Turn focus emulation on for the batch of input, then off |
| A link to a non-web scheme, such as `mailto:`, was handed to a new tab or pane | Any address was passed on | Open only web schemes; log a console warning for the rest |
| The CLI said "rexweb isn't running" when a command was only slow | Every curl failure was read the same way | Report curl's timeout as "didn't answer within Ns" |

Focus emulation has one visible effect: the showing tab of a Chromium pane
reports `document.hasFocus()` as true even when the pane does not have the
keyboard. It is on only for the tab on show, and for a background tab while
scripted input is delivered to it; otherwise a background tab reports
unfocused and hidden.

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
