# rexweb for coding agents

rexweb gives Rex panes a real WebKit browser, and optionally a Chromium one.
You drive both with the `rexweb` command. Print this guide at any time with
`rexweb skill`.

## Install

Requirements: macOS 14 or later, Rex with a working `rex` command, the Xcode
command line tools (`xcode-select -p` succeeds), and `jq`.

```sh
git clone https://github.com/acoyfellow/rexweb ~/src/rexweb
~/src/rexweb/install.sh
```

The script asks no questions and is safe to run again. It ends with
`rexweb doctor`. If it says `~/.local/bin` isn't on PATH, run
`export PATH="$HOME/.local/bin:$PATH"` or call `~/.local/bin/rexweb`.

Update with `git -C ~/src/rexweb pull && ~/src/rexweb/install.sh`. Reinstalling
restarts RexWeb, so open panes go blank for about 2 seconds and reload. Their
tabs come back with the same IDs; see [Tabs](#tabs).

The Chromium engine is optional: `~/src/rexweb/install.sh --with-chromium`. It
needs macOS 15 or later and full Xcode (`swift package --version` succeeds).
The first build downloads about 134 MB from `cef-builds.spotifycdn.com`, and
the app takes about 290 MB, so ask the person before you install it. Use the
same flag when you update, or only RexWeb.app is rebuilt.

## Check it

```sh
rexweb doctor          # one line per check; exits 1 if any check fails
```

Fix each `FAIL` line as it says before you go on. A `chromium-app` line means
the Chromium engine is installed. No such line means it isn't, which is not a
failure.

## Use it

Always keep the ID that `open` prints and pass it with `-b`. Without `-b`,
commands act on the pane someone used last, which may belong to another agent
or to the person.

```sh
id=$(rexweb open --focus=false localhost:3000) || echo "load failed: see stderr"
rexweb snapshot -b "$id"                  # numbered controls, then the page text
rexweb click -b "$id" e3                  # refs last until the next snapshot
rexweb type -b "$id" --submit e1 'hello'
rexweb wait -b "$id" --text 'Saved'
rexweb eval -b "$id" 'document.title'     # prints JSON
rexweb console -b "$id" --level error     # console messages and page errors
rexweb html -b "$id" '#app'               # live HTML of the page or one element
rexweb screenshot -b "$id" /tmp/page.png
rexweb close -b "$id"
```

- `open` prints the ID, then waits for the page. If the page fails to load, it
  still prints the ID, writes `Error: ...` to stderr, and exits 1. Close the
  pane or `nav` it again.
- `open` warns on stderr if Rex isn't showing the pane. Panes only show while
  their Rex window is on screen. `snapshot`, `eval`, and `screenshot` work
  either way. `click`, `type`, and `press` need the pane on screen. They wait
  about a second for it, then exit 1.
- `nav`, `back`, `forward`, `reload`, `click`, and `type` wait for any page
  load. `nav` and `wait` exit 1 if the page fails to load.
- `info --json` prints `{id, session, url, title, loading, visible, error}`,
  plus the tab fields described under [Tabs](#tabs).
  `visible` turns false for about half a second while Rex rearranges panes,
  so poll it rather than reading it once.
- `console` prints each tab's last 1000 messages, oldest first: `console.*`
  calls, uncaught errors, unhandled rejections, failed resource loads,
  Content Security Policy blocks, and a `navigation` line per page load.
  Capture starts before the page's scripts run. Each line starts with the
  message's number; `--since N` prints only later ones, so read
  `rexweb console --json | jq .last` before an action and pass it afterward.
  In a WebKit pane it doesn't capture the browser's own messages (such as
  CORS refusals) or network traffic, and pages opened from `file://` report
  uncaught errors only as "Script error." A Chromium pane captures those
  messages; see below.
- Errors go to stderr as `Error: ...`, with exit status 1. Two of them are
  about rexweb itself, and they differ. `rexweb didn't answer within Ns. The
  command may still be running in the pane; check with "rexweb info".` means
  the app is up and the command ran out of time. `rexweb isn't running.`
  means nothing is listening.
- A command whose pane or tab goes away while it waits fails with `the pane
  was closed` or `the tab was closed`.
- In a Chromium pane, the page has 25 seconds to answer a DevTools call.
  That caps `eval` and `cdp`: a longer one fails with `the page didn't
  answer METHOD within 25 seconds`.

## Tabs

A pane holds one or more tabs. Each tab is a separate page with its own
console log, load state, and history. A pane starts with one tab, and a
script that never mentions tabs keeps working: without `--tab`, every
command acts on the tab the pane is showing.

```sh
rexweb tabs -b "$id"                          # index, ID, mark, title, URL
rexweb tabs -b "$id" --json                   # {id, active, tabs: [...]}
t=$(rexweb tab new -b "$id" --background localhost:3000/admin)
rexweb snapshot -b "$id" --tab "$t"           # -t "$t" is the same
rexweb click -b "$id" --tab "$t" e3
rexweb tab select -b "$id" "$t"               # show the tab to the person
rexweb tab close -b "$id" "$t"
```

- **Addressing.** A tab has an ID: `t1`, `t2`, and so on, counted per pane.
  `--tab` takes the ID or the tab's position, counted from 1. Prefer the ID.
  Positions shift when a tab opens or closes; an ID stays with its tab and
  is not reused. An unknown tab exits 1.
- **IDs survive a restart.** When RexWeb restarts, each tab comes back with
  the ID it had, and new tabs carry on from the old count. Blank tabs are
  not restored, so a blank tab's ID answers "no tab" afterward.
- **`--tab` and `open`.** `--tab TAB`, `--tab=TAB`, or `-t TAB` works on
  every page command: `nav`, `snapshot`, `click`, `type`, `press`, `eval`,
  `wait`, `screenshot`, `console`, `html`, `back`, `forward`, `reload`,
  `info`, `focus`, `network`, `cdp`, and `devtools`. `ls`, `tabs`, `close`,
  `doctor`, and `tab new` exit 1 if you pass it. On `open`, `--tab` takes no
  value and means something else: put the new pane in a new Rex tab.
- **Output.** `tabs` prints one line per tab: position, ID, `●` for the
  showing tab or `○`, title, URL, and `[asleep]` for a sleeping tab. `ls`
  adds `[3 tabs]` to a pane with more than one. A command that prints a pane
  line adds `[tab t2, 2 of 3]` in such a pane.
- **`tabs --json`** prints `{id, active, tabs}`. Each tab is
  `{id, index, url, title, active, asleep, loading, unload_blocked}`.
  Listing never wakes a sleeping tab.
- **`visible` is per tab.** In `info --json`, `visible` is true only when
  the pane is on screen and this tab is the one showing, so it is false for
  every background tab. `pane_visible` is the pane alone. `click`, `type`,
  and `press` need `pane_visible`, not `visible`.
- **`info --json`** adds `tab` (the ID), `tab_index` (position from 1),
  `tabs` (how many the pane has), `tab_active`, and `tab_asleep`. With
  `--tab` it describes that tab. `ls --json` describes each pane's showing
  tab and has the same fields, so `tabs` there is the pane's tab count.
- **`tab new [URL]`** opens the tab at the end, in front. Like `open`, it
  prints the new tab's ID and then waits for the page. If the page fails to
  load, it still prints the ID, writes the error to stderr, and exits 1.
  Pass `--background` so you do not change what the person is looking at,
  and `--no-wait` to skip the wait. With `--json` it prints the new tab's
  `info`; the ID is in `.tab`. Without a URL the tab is empty.
- **`tab select TAB`** needs a tab. `tab close` prints the closed tab's ID;
  without a tab it closes the showing one. Closing a pane's last tab closes
  the pane. `tab ls` is the same as `tabs`.
- **`close` closes the whole pane**, with every tab in it. It takes the pane
  with `-b` only and exits 1 on any other argument.
- **Pages open tabs too.** A click on a `target="_blank"` link, or a
  `window.open` without a size, opens a new tab in front. Your next command
  without `--tab` then acts on that new tab. Run `rexweb tabs` after a click
  that might have opened one. A page in a background tab opens its new tab
  in the background too.
- **Popups are not tabs.** A `window.open` with a size makes a separate
  popup window, which cannot be scripted. In a WebKit pane, so does a
  `window.open` with no URL or an `about:` URL. A page that a link opened in
  a tab has no `window.opener`, and the `window.open` call that made it
  returns null.
- **Only web addresses open.** A link or `window.open` to a scheme other
  than `http`, `https`, `file`, `about`, `data`, or `blob`, such as
  `mailto:` or `tel:`, opens no tab or pane. The opener tab's console gets
  a `warn` line that starts `Didn't open`.

### Background tabs

A command aimed at a background tab does not change the tab the pane shows,
the tab strip, the address bar, or where the keyboard is. That includes
`click`, `type`, `press`, and `screenshot`. The first three still need the
pane itself on screen, as before.

- **WebKit: `screenshot` draws the page out of sight.** For the shot, the
  background page is drawn behind the page on show for about 150 ms, then
  hidden again. The person sees no change. A screenshot of a different
  background tab of the same pane waits for the first; if it waits 30
  seconds, it exits 1 with `another command is still using this pane`, so
  run it again.
- **Chromium: no command shows the tab.** `screenshot` runs in place too,
  and shows the page as it is now.
- **A background tab is a hidden page, in both engines.** Only the showing
  tab reports focused and visible. In a background tab,
  `document.visibilityState` is `"hidden"`, animation frames do not run, and
  timers fire about once a second, as in a hidden tab of any browser. In
  WebKit, CSS transitions stand still too.
- **Select the tab first if the page must keep running.** A page that only
  renders inside `requestAnimationFrame` does not update in the background,
  so a `wait` on what it draws, or on a fast timer, can time out. Run
  `tab select`, then the command.
- **Chromium screenshots** are one pixel per CSS pixel of the tab's
  viewport.

`focus --tab TAB` is the exception to "does not change the tab": it selects
the tab and gives the pane the keyboard.

### Sleeping tabs

A tab is live or asleep. A sleeping tab has no page: only its URL, its title,
and its console log are kept. Tabs sleep in two cases:

- After a restart, only the tab that was showing loads. The rest start
  asleep.
- A background tab that was neither selected nor addressed by a command for
  `tab_unload_minutes` (default 30; 0 turns this off) is unloaded. Any
  command with `--tab` counts as use, except `info`. So a tab you poll stays
  awake. A tab is never unloaded while a command is running on it.

An idle tab is kept loaded while unloading would lose something. Then its
`unload_blocked` in `tabs --json` holds the reason, such as `a form on it
has input that would be lost`; otherwise it is null.

- Both engines: the tab plays audio (a muted video does not count), uses the
  camera or microphone, has a form field that the person or a script
  changed, or the page asks before it is left (`beforeunload`).
- WebKit only: the tab has a popup window open.
- Chromium only: the tab's DevTools window is open, a download is running,
  it captures the screen, shows picture in picture, or is connected to a
  device. Chromium counts audio for a minute after it stops.

So a tab you `type` into without submitting stays loaded.

`tabs --json` shows `asleep`, and `info --json` shows `tab_asleep`. You do
not need to check before a command:

- A command aimed at a sleeping tab wakes it, waits for the page to load, and
  then runs. Allow for the load time. If the page has not loaded after 20
  seconds, the command fails without running, with this error. Do what it
  says.

  ```
  Error: the tab was unloaded and is still loading after 20s, so the command didn't run. Wait for it with `rexweb wait -t t2`, then try again.
  ```

- `wait` on a sleeping tab wakes it and uses its own `--timeout`.
- `info` and `console` answer from what the sleeping tab kept and do not wake
  it. `nav` wakes it and loads the new URL without loading the old one first.
- `tab select` wakes the tab but does not wait for the load. Follow it with
  `wait` if you need the page.
- `reload` on a sleeping tab is the wake itself: the page loads once.

What a tab loses when it sleeps:

- Page state: form input, scroll position, anything held in JavaScript. The
  page loads again from its URL, so a page reached by a form post may not
  come back the same.
- Its back and forward history. `back` has nowhere to go afterward.
- In a Chromium pane, its network log. Read `network` before you leave a tab
  idle if you need it.
- Element refs from an earlier `snapshot`. Take a new one.

The console log is kept. It gets a `navigation` line that says the tab was
unloaded, and another when the page loads again.

## Choose an engine

`open` makes a WebKit pane unless you pass `--engine chromium`, or the person
set `"engine": "chromium"` in `~/.rexweb/config.json`. Pass `--engine` when
the engine matters to you. Only `open` takes it: every later command finds
the pane's engine from its ID. `ls` marks Chromium panes with `[chromium]`,
and `info --json` has an `engine` field.

Use WebKit, the default, unless you need what Chromium adds. WebKit is
lighter, is always installed, and plays MP4 video.

Use Chromium when you need one of these:

- Browser-level console messages: why a CORS request was refused, what a
  Content Security Policy blocked, why a resource failed. `console` prints
  them with their origin in brackets, such as `[network]` or `[security]`.
- A network log.
- The real Chrome DevTools Protocol.

```sh
id=$(rexweb open --engine chromium --focus=false localhost:3000)
rexweb console -b "$id" --level error,warn   # includes the browser's own messages
rexweb network -b "$id"                      # number, status, method, type, URL
rexweb network -b "$id" --failed             # only errors and statuses of 400 or above
n=$(rexweb network -b "$id" --json | jq .last)
rexweb click -b "$id" e3
rexweb network -b "$id" --since "$n"         # only what the click caused
rexweb devtools -b "$id"                     # opens Chromium DevTools for the person
rexweb devtools -b "$id" close
rexweb cdp -b "$id" Page.getLayoutMetrics    # any DevTools Protocol command; prints JSON
rexweb cdp -b "$id" Emulation.setDeviceMetricsOverride '{"width":390,"height":844,"deviceScaleFactor":3,"mobile":true}'
```

- If `open --engine chromium` says RexWebChromium.app isn't installed, use
  WebKit or ask the person to run `./install.sh --with-chromium`.
- `network` keeps each tab's last 1000 requests. A failed request shows
  `ERR` and the reason, including CORS and blocked-request reasons. It has no
  headers or bodies; use `eval` with `fetch` if you need them.
  `network --json` prints `{requests, last, dropped}`.
- `network`, `devtools`, and `cdp` exit 1 on a WebKit pane and tell you to
  open a Chromium one.
- `cdp METHOD [PARAMS]` takes PARAMS as a JSON object and prints the command's
  result. A protocol error exits 1 with the protocol's message. Prefer the
  named commands; use `cdp` for what they don't cover.
- A `-b` value that matches panes in both apps exits 1 and lists them. Pass
  more of the pane ID.
- Chromium can't play H.264 or AAC (MP4) video. WebM works. Test MP4 video in
  a WebKit pane.
- Each engine has its own cookies. A sign-in in one doesn't carry to the
  other. `cookies import` and `cookies set` take `--engine`.

### The DevTools Protocol port

For work that the CLI can't do, such as request interception or performance
traces, the person can set `"chromium_debug_port": 9333` (any free port) in
`~/.rexweb/config.json` and restart with `pkill -x RexWebChromium`. Then
connect a Chrome DevTools Protocol client to `http://127.0.0.1:9333`; every
Chromium pane is a target there.

The port is off by default and has no password. Anything on the Mac that can
reach it can drive every Chromium pane, including signed-in ones. Don't turn
it on yourself. Ask the person, and suggest they remove the key afterward.

## Needs a person

These commands open a macOS dialog. Don't run them unattended:

- `rexweb links on` and `links off` (default browser confirmation)
- `rexweb cookies import`, for either engine (Keychain prompt for "Chrome
  Safe Storage")

Passkeys and security keys don't work in rexweb. Ask the person to sign in
with Chrome and run `rexweb cookies import --domain ...`. With `--reload`,
the import reloads every live tab in every pane of that engine, including
tabs you are working in. Sleeping tabs get the cookies when they wake.

## When something breaks

1. Run `rexweb doctor` and fix what it reports.
2. Restart RexWeb: `pkill -x RexWeb`. Panes come back within 2 seconds. For
   Chromium panes, restart `pkill -x RexWebChromium` instead. Tabs come back
   too, with their IDs, and with every tab except the showing one asleep.
3. Read what the pane itself says: `rex capture -b "$id"`. It prints the URL,
   or why it can't reach RexWeb.
4. If the Rex server restarted, old browser panes are now plain shells.
   Close them and open new ones.
5. Reinstall: `~/src/rexweb/install.sh`.

## How it talks

RexWeb listens on `127.0.0.1:18802`, and RexWebChromium on `127.0.0.1:18803`.
Every request is a POST with JSON and an `x-rexweb-token` header holding the
contents of `~/.rexweb/token`. Both apps share that token and refuse requests
from web pages. A pane belongs to one app, so send its requests to that app's
port. Use the CLI unless you need the raw API.

Pane routes take the pane as `id` and, optionally, a tab as `tab` (an ID or a
position from 1). The tab routes are `/tabs`, `/tab/new` (`url`,
`background`), `/tab/select` (`tab`), and `/tab/close` (`tab`, optional).
