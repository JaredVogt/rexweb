# Tabs inside a rexweb pane: build brief

This brief lets a fresh session build tabs without the earlier conversation.
Read it fully, then read [../EXTENSIONS.md](../EXTENSIONS.md) for how the fork
is laid out.

## State when this was written

- Repo: `~/projects/rexweb`. Branch `feat/tabs`, created from `feat/cef-engine`
  (ten local commits on upstream `e23cb9c`). Nothing is pushed. Do not push.
- No tab code is in `Sources/` yet. The working tree has only `docs/tabs/`.
- `docs/tabs/panel-draft.swift` is an unfinished, never-compiled draft of the
  new `Tab`, `TabStrip`, `TabCell` and `Panel` classes. It is meant to replace
  the `Panel` class in `Sources/Core.swift`. Treat it as a starting point, not
  as reviewed code. It is not compiled by the Makefile.
- Both apps are installed and running from `feat/cef-engine` code:
  `~/Applications/RexWeb.app` (WebKit, port 18802) and
  `~/Applications/RexWebChromium.app` (Chromium, port 18803).

## What the user decided

| Topic | Decision |
|---|---|
| Cmd-click, `target="_blank"`, unsized `window.open` | Open a new tab in the same pane |
| Pane beside | Cmd-Option-click, where the engine can tell; otherwise CLI or Shift-Cmd-B |
| Sized `window.open` | Stays a native popup window, as today |
| Tab strip | Shown only when the pane has two or more tabs |
| Agent commands on a background tab | The visible tab does not change. Only a command that cannot work hidden switches to the tab, then switches back |
| Shortcuts, only while a browser pane has the keyboard | Cmd-T new tab. Cmd-W close tab; on the last tab it closes the pane. Ctrl-Tab next, Ctrl-Shift-Tab previous |
| Shortcuts left to Rex | Cmd-1 to Cmd-9, Shift-Cmd-[ and Shift-Cmd-] |
| Session restore | Yes. Tabs come back after the app restarts |
| Memory | Yes. Idle background tabs are unloaded and reload when used |
| Engines | Both WebKit and Chromium |

Smaller choices made on the user's behalf, which they did not object to:

- A Cmd-click tab opens in the background, right after the current tab.
  Cmd-Shift-click, Cmd-T and `target="_blank"` open in front.
- A tab opened from a link has no `window.opener`. Sign-in popups are sized,
  so they still open as native popups and keep their opener.

## Design

### Tab

A pane (`Panel`) owns a list of `Tab` objects and shows one, `activeTab`.
Everything that belongs to one page moves from `Panel` to `Tab`: the engine,
the console buffer and its counters, load waiters, `lastError`, `requested`,
`probingUntil`, `record`, `load`, `waitForLoad`, `finishWaiters`,
`refusedError`, and the engine callbacks (`engineChanged`, `engineStarted`,
`engineCommitted`, `engineFinished`, `engineFailed`, `openBeside`).

`Panel` keeps the overlay window, the toolbar, the tab strip, and the fields
the Rex tracker uses (`visible`, `lastFrame`, `lastActive`, `pendingFocus`,
and so on). `Panel.engine` becomes a computed property that returns the
active tab's engine, so the tracker, `focus`, and the key handler keep
working unchanged.

Engines take a `Tab` instead of a `Panel`: `Engine.make: (Tab) -> PageEngine`
and `Engine.route: (String, Tab, ...)`. In the two engine files this is a
rename of the `panel` property to `tab`. Mind the WebKit delegate method
names that contain "Panel" (`runJavaScriptAlertPanelWithMessage`,
`NSOpenPanel`); rename by whole word only.

### Tab IDs

Each tab gets a stable ID, `t1`, `t2`, and so on, from a counter on its pane.
The API and CLI accept either the ID or a position counted from 1. No value
means the active tab, so every existing script keeps working.

### Asleep tabs

A tab is live (it has an engine) or asleep (only its URL, title and console
log are kept). This one state serves both session restore and unloading.

- Reading `tab.engine` wakes the tab: it creates the engine, attaches the
  view, and loads the saved URL.
- `tab.sleep()` closes the engine of a background tab. The network log of a
  Chromium tab is lost with its engine; say so in the docs.
- Listing code must not wake tabs. Use `tab.url`, `tab.title` and
  `tab.isLive`, which read saved values when asleep.
- In the API, a command aimed at a sleeping tab wakes it and waits for the
  load before it runs. `/info`, `/console`, `/tabs`, tab select and tab close
  do not need the wait. `/nav` should create the engine without first
  loading the old URL.

### Unloading

A timer in `App` puts to sleep any background tab that is live, not loading,
has no load waiters, and was last used more than N minutes ago. "Used" means
selected or addressed by an API command. Add a config key,
`tab_unload_minutes`, default 30, where 0 turns unloading off.

### Session restore

`App` writes `~/.rexweb/tabs-<engine>.json`, debounced by about one second,
whenever tabs change: `{ paneID: { active, saved, tabs: [{url, title}] } }`.

- `/register` for a pane ID with saved tabs restores them and ignores the URL
  the pane script sends. Only the active tab is live; the rest start asleep.
- `/close` deletes the pane's entry. The pane script calls `/close` when its
  Rex pane goes away, so a closed pane is forgotten. The app being killed
  does not call it, which is exactly the restart case to restore.
- Prune entries older than 30 days when loading the file.

### Views

All live tab views are subviews of the pane's root view. Inactive ones are
hidden. Layout gives every live view the page rectangle. The tab strip sits
above the toolbar and takes 26 points when shown.

Repaint only on change. A page or control in a Rex pane that repaints
constantly drives Rex's CPU up, which this project has already been bitten
by. `TabStrip.show` in the draft compares before it redraws; keep that.

### Links

- WebKit, `decidePolicyFor`: Cmd-click on a link opens a background tab;
  with Shift, a foreground tab; with Option, a pane beside.
  `createWebViewWith` for a non-popup request opens a foreground tab and
  returns nil.
- Chromium, `decideWindowOpenFor`: `.newBackgroundTab` opens a background
  tab; `.newForegroundTab` and `.newWindow` with a user gesture and a URL
  open a foreground tab and return `.handled`; `.newPopup` is unchanged.
  `CefWindowOpenRequest` carries no modifier flags, so Cmd-Option-click may
  not be detectable. If so, document that pane-beside on Chromium is CLI or
  Shift-Cmd-B only.

### Background-tab commands

`eval`, `snapshot`, `html`, `console`, `network` and `cdp` should work on a
hidden tab in both engines. Verify each; do not assume.

`click`, `type` into rich editors, `press` and `screenshot` may need the tab
on screen. For those, when the tab is not active: select it, wait about
150 ms, run the command, and restore the previous tab after the reply. Find
out by testing whether Chromium needs this at all; WebKit certainly does,
because it sends real window events. Add a per-engine flag rather than
guessing.

### Keyboard

`App.key` in `Sources/Core.swift` is a local key-down monitor that already
handles Cmd-L, Cmd-R, Cmd-W and others for the key pane. Add Cmd-T, change
Cmd-W to close the tab, and add Ctrl-Tab (key code 48 with Control) and
Ctrl-Shift-Tab.

### API and CLI

- Every pane route accepts `tab`. `info()` gains `tab`, `tab_index`, `tabs`,
  `tab_active` and `tab_asleep`.
- New routes: `/tabs` (list), `/tab/new` (`url`, `background`),
  `/tab/select`, `/tab/close`. Closing the last tab closes the pane.
- CLI in `bin/rexweb`: `rexweb tabs [--json]`, `rexweb tab new [URL]
  [--background]`, `rexweb tab select TAB`, `rexweb tab close [TAB]`, and
  `--tab TAB` (short `-t`) parsed in `parse()` and sent by every page
  command. `rexweb ls` shows the tab count for panes with more than one.
- `/cookies/import --reload` must reload every live tab, not only the active.

## Suggested split across agents

`Sources/Core.swift` is one large file, so parallel edits to it will
conflict. Do the core first, then fan out by file.

1. **Core (one agent, serial).** Integrate the draft into `Core.swift`:
   `Tab`, `Panel`, tab strip, API routes, key handling, save/restore,
   unloading, config key. Make the minimal rename in both engine files so
   both apps build. Gate: both apps build, and every existing command still
   works on a one-tab pane.
2. **In parallel, one agent per file set:**
   - `Sources/WebKitEngine.swift`: link handling, hidden-tab behaviour.
   - `chromium/Sources/RexWebChromium/ChromiumEngine.swift`: link handling,
     hidden-tab behaviour, focus emulation on new tabs.
   - `bin/rexweb`: commands, `--tab`, help text.
   - `README.md`, `AGENTS.md`, `docs/EXTENSIONS.md`.
3. **Independent review** of the whole diff by an agent that did not write
   it. Give it the code, not the conclusions.
4. **On-screen verification** by the main session, with screen captures.
   The Mac must be unlocked; when it is locked, pages report hidden and
   input tests give false failures.

## How to build and test

```sh
cd ~/projects/rexweb
make install              # WebKit app and the CLI
make install-chromium     # Chromium app; about a minute
pkill -x RexWeb; pkill -x RexWebChromium   # panes reconnect in a few seconds
rexweb doctor             # expect 11 ok lines
```

Open test panes with `rexweb open --engine chromium URL` and `rexweb open
URL`. Serve local test pages from a scratch folder; the user's rule is that
dev servers go through `portless` and never use ports 3000 or 5173.

Checks that must pass before calling it done:

- A one-tab pane looks and behaves exactly as before, in both engines.
- New, select, close, close-last, Cmd-click, `target="_blank"`, and each
  shortcut, by CLI and on screen.
- Every page command with `--tab` on a background tab, in both engines.
- Kill each app with tabs open; the tabs come back, and only the active one
  loads.
- A sleeping tab wakes on select and on an agent command.
- Idle CPU of both apps and of the Rex server is no higher than before
  (about 3% each).

## Lessons from the earlier work

- **Send input events in order.** Chromium drops a press and release that
  arrive as separate unordered tasks. Use `sendInOrder` in the Chromium
  engine.
- **Chromium ignores scripted input on an unfocused page.** The engine turns
  on `Emulation.setFocusEmulationEnabled` when a page is ready and after each
  load. New tabs need the same.
- **`rexweb cdp METHOD [PARAMS]`** sends any DevTools Protocol command to a
  Chromium pane. Use it to experiment instead of rebuilding per guess.
- **`rexweb eval` returns null for statements.** Wrap test code in an
  immediately called function that returns a value.
- **The user may be using the Mac.** Their clicks change focus and can skew
  input tests. Ask them to leave the test pane alone while testing input.
- **Do not run `osascript` against System Events**; it hangs on a permission
  prompt.
- **Never print `~/.rexweb/token`.** Do not run the pane script under
  `bash -x`; it echoes the token.
- **Pre-existing WebKit bugs, not caused by tabs:** `nav` can return before
  the page loads, `back` can hang about 40 seconds, and `html SELECTOR` can
  fail right after such a `nav`.

## The user's standing rules

No emoji. Use `rg`, `fd`, `bat`, `eza`. Write `\rm`, never bare `rm`. Shell
scripts start with `#!/usr/bin/env bash`, `set -euo pipefail`,
`IFS=$'\n\t'`. Commit messages: imperative subject of at most 72 characters,
body wrapped at 72, last line exactly `Message by Claude`, and no
co-author or session lines. Never push without an explicit ask. Temporary
debug logging is prefixed `[debug]` and removed before commit.
