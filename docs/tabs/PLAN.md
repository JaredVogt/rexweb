# Tabs inside a rexweb pane: design record

This is the brief the tabs were built from, kept as a record of what was
decided and why. Tabs are built and merged into `fork` (commits `ec041eb`
to `b12d3a5`). The code is in `Sources/Core.swift` (`Tab`, `TabStrip`,
`TabCell`, `Panel`) and the two engine files.

For how tabs behave now, read [../../AGENTS.md](../../AGENTS.md) and
[../EXTENSIONS.md](../EXTENSIONS.md). Where the build went a different way
from the brief, this file says what was built.

## What the user decided

| Topic | Decision |
|---|---|
| Cmd-click, `target="_blank"`, unsized `window.open` | Open a new tab in the same pane |
| Pane beside | Cmd-Option-click, in both engines. Also the CLI and Shift-Cmd-B |
| Sized `window.open` | Stays a native popup window, as today |
| Tab strip | Shown only when the pane has two or more tabs |
| Agent commands on a background tab | The visible tab does not change, for any command. See [Background-tab commands](#background-tab-commands) |
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
and so on). `Panel.engine` is a computed property that returns the active
tab's engine, so the tracker, `focus`, and the key handler work unchanged.

Engines take a `Tab` instead of a `Panel`: `Engine.make: (Tab) -> PageEngine`
and `Engine.route: (String, Tab, ...)`.

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
  Chromium tab is lost with its engine.
- Listing code must not wake tabs. Use `tab.url`, `tab.title` and
  `tab.isLive`, which read saved values when asleep.
- In the API, a command aimed at a sleeping tab wakes it and waits for the
  load before it runs. `/info`, `/console`, `/tabs`, tab select and tab close
  do not need the wait. `/nav` creates the engine without first loading the
  old URL.

### Unloading

A timer in `App` puts to sleep any background tab that is live, not loading,
has no load waiters, and was last used more than N minutes ago. "Used" means
selected or addressed by an API command, other than `/info`. The config key
`tab_unload_minutes` sets N: default 30, and 0 turns unloading off.

The build added one more condition: a tab stays loaded while unloading would
lose something, such as form input or playing audio. AGENTS.md lists the
cases under "Sleeping tabs".

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
by. `TabStrip` compares its items before it redraws, and layout sets a
frame only when it differs.

### Links

- WebKit, `decidePolicyFor`: Cmd-click on a link opens a background tab;
  with Shift, a foreground tab; with Option, a pane beside.
  `createWebViewWith` for a non-popup request opens a foreground tab and
  returns nil.
- Chromium, `decideWindowOpenFor`: `.newBackgroundTab` opens a background
  tab; `.newForegroundTab` and `.newWindow` with a user gesture and a URL
  open a foreground tab and return `.handled`; `.newPopup` is unchanged.
  `CefWindowOpenRequest` carries no modifier flags, but Chromium reports
  Cmd-Option-click as a split-view disposition, and that opens a pane
  beside.
- Both: a tab that would open in front does so only if the page that asked
  is the showing tab. A page in a background tab opens its tab in the
  background.

### Background-tab commands

`eval`, `snapshot`, `html`, `console`, `network` and `cdp` work on a hidden
tab in both engines.

The brief expected `click`, `type`, `press` and `screenshot` to need the tab
on screen, and proposed to select the tab, run the command, and select the
old tab again. The build does not switch tabs at all:

- `Engine.needsVisible` is the per-engine set of routes that need the page
  drawn. It is `["/shot"]` for WebKit and empty for Chromium.
- For a route in that set, the pane "borrows" the screen: the background
  tab's page is drawn behind the page on show for about 150 ms, then hidden
  again. The active tab, the tab strip and the address bar do not change.
- `click`, `type` and `press` run in place on a background tab in both
  engines. They still need the pane itself on screen.

### Keyboard

`App.key` in `Sources/Core.swift` is a local key-down monitor that handles
Cmd-L, Cmd-R and others for the key pane. For tabs it handles Cmd-T, Cmd-W
(close the tab), Ctrl-Tab (key code 48 with Control) and Ctrl-Shift-Tab.

### API and CLI

- Every pane route accepts `tab`. `info()` has `tab`, `tab_index`, `tabs`,
  `tab_active` and `tab_asleep`.
- Tab routes: `/tabs` (list), `/tab/new` (`url`, `background`),
  `/tab/select`, `/tab/close`. Closing the last tab closes the pane.
- CLI in `bin/rexweb`: `rexweb tabs [--json]`, `rexweb tab new [URL]
  [--background]`, `rexweb tab select TAB`, `rexweb tab close [TAB]`, and
  `--tab TAB` (short `-t`) parsed in `parse()` and sent by every page
  command. `rexweb ls` shows the tab count for panes with more than one.
- `/cookies/import --reload` reloads every live tab, not only the active.

## How to build and test

```sh
cd ~/projects/rexweb
make install              # WebKit app and the CLI
make install-chromium     # Chromium app; about a minute
pkill -x RexWeb; pkill -x RexWebChromium   # panes reconnect in a few seconds
rexweb doctor             # every line should be ok
```

Open test panes with `rexweb open --engine chromium URL` and `rexweb open
URL`. Serve local test pages from a scratch folder.

Checks to run after a change to tabs:

- A one-tab pane looks and behaves as it did before tabs, in both engines.
- New, select, close, close-last, Cmd-click, `target="_blank"`, and each
  shortcut, by CLI and on screen.
- Every page command with `--tab` on a background tab, in both engines.
- Kill each app with tabs open; the tabs come back, and only the active one
  loads.
- A sleeping tab wakes on select and on an agent command.
- Idle CPU of both apps and of the Rex server stays at about 3% each.

[../../review.md](../../review.md) lists the checks that nobody has yet run
with real keys and clicks.

## Lessons

- **Send input events in order.** Chromium drops a press and release that
  arrive as separate unordered tasks. Use `sendInOrder` in the Chromium
  engine.
- **Chromium ignores scripted input on an unfocused page.** `sendInOrder`
  turns on `Emulation.setFocusEmulationEnabled` for a hidden page while
  scripted input runs, and turns it off afterward.
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
- **WebKit bugs seen before tabs were built, and not rechecked since:**
  `nav` can return before the page loads, `back` can hang about 40 seconds,
  and `html SELECTOR` can fail right after such a `nav`.
