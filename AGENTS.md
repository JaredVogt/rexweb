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
restarts RexWeb, so open panes go blank for about 2 seconds and reload.

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
- `info --json` prints `{id, session, url, title, loading, visible, error}`.
  `visible` turns false for about half a second while Rex rearranges panes,
  so poll it rather than reading it once.
- `console` prints each pane's last 1000 messages, oldest first: `console.*`
  calls, uncaught errors, unhandled rejections, failed resource loads,
  Content Security Policy blocks, and a `navigation` line per page load.
  Capture starts before the page's scripts run. Each line starts with the
  message's number; `--since N` prints only later ones, so read
  `rexweb console --json | jq .last` before an action and pass it afterward.
  In a WebKit pane it doesn't capture the browser's own messages (such as
  CORS refusals) or network traffic, and pages opened from `file://` report
  uncaught errors only as "Script error." A Chromium pane captures those
  messages; see below.
- Errors go to stderr as `Error: ...`, with exit status 1.

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
```

- If `open --engine chromium` says RexWebChromium.app isn't installed, use
  WebKit or ask the person to run `./install.sh --with-chromium`.
- `network` keeps each pane's last 1000 requests. A failed request shows
  `ERR` and the reason, including CORS and blocked-request reasons. It has no
  headers or bodies; use `eval` with `fetch` if you need them.
  `network --json` prints `{requests, last, dropped}`.
- `network` and `devtools` exit 1 on a WebKit pane and tell you to open a
  Chromium one.
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
with Chrome and run `rexweb cookies import --domain ...`.

## When something breaks

1. Run `rexweb doctor` and fix what it reports.
2. Restart RexWeb: `pkill -x RexWeb`. Panes come back within 2 seconds. For
   Chromium panes, restart `pkill -x RexWebChromium` instead.
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
