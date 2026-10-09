# Pixel Agents Menu Bar

A menu-bar-only version of Pixel Agents (macOS). Every running Claude Code session is a small
side-view pixel pet that wanders around inside the status item. Click it for a list of sessions.
No window, no Dock icon, no Node server.

It reuses the hooks Pixel Agents already installed in `~/.claude/settings.json`: the app listens
on a loopback port and registers itself in `~/.pixel-agents/servers/`, and the existing
`claude-hook.js` posts every event to it, alongside any VS Code or `npx pixel-agents` server that
is also running. It never writes `settings.json`. If the dropdown says hooks are not installed, run
`npx pixel-agents` once and accept the prompt.

## Build and run

```bash
./build-app.sh                       # -> PixelAgentsMenuBar.app (needs the Swift toolchain, no Xcode)
open PixelAgentsMenuBar.app
```

Quit from the dropdown (or `pkill -TERM PixelMenuBar`); that removes its registry file.

```bash
./test.sh                            # unit tests (Swift Testing from the Command Line Tools)
.build/debug/PixelMenuBar --dump-frame /tmp/lane.png   # render the lane to a PNG to check sprites
```

## How it behaves

- One pet per session, no limit. They share one lane. By default it is a fixed 320pt wide while any
  session exists; the Lane width submenu offers 160, 240, 480 and 640pt, or "Grow with sessions"
  (below). No choice takes more than 40% of the screen width. On a notched MacBook, macOS only shows
  status items right of the notch, so the app works out the widest lane that fits (from the item's
  right edge and where the notch area starts, ~426pt on a 14" screen) and caps every choice to it; the
  submenu labels the ones that can't be shown in full, e.g. "640 pt (fits 426)". If macOS hides the
  item anyway, it shrinks the lane until the item shows, and re-checks every 3 seconds.
  The growing mode follows the session count
  (`laneWidth` in `Wanderer.swift`: 120pt, +30pt per extra session, capped at 320pt). Past the cap
  pets overlap, with the most urgent on top.
- Pets always wander in strolls of one to four legs, easing into and out of each walk, with long legs
  favoured so they cross the lane. Working and permission sessions scurry (short pauses, 2x speed, faster with
  tool-call rate); waiting and done sessions amble.
- Every running subagent gets its own pet (same species as its session, always scurrying) and keeps it
  until its own SubagentStop, even after the parent session has gone idle. A subagent whose stop never
  arrives is dropped after 15 minutes.
- Badges: a blinking amber `!` for a permission prompt, green `...` when Claude is waiting for you.
  Done sessions dim after a minute.
- With no sessions, one dim pet sleeps and nothing ticks. The 12 fps clock runs only while a session
  exists, and stops while the display sleeps.
- Sessions with no event for 30 minutes (60 when working) are dropped, since there is no
  transcript tailing to confirm they are alive.
- Dropdown: project, state and current tool for each session, a Pet submenu (Mixed, claudio,
  gitcat), and the read-only hook status.

## Layout

- `Sources/PixelMenuBarCore`: no AppKit. Hook payload normalization (`HookEvent.swift`, port of
  `normalizeHookEvent`), `formatToolStatus` port, agent state, HTTP parsing and auth, registry file,
  wander model.
- `Sources/PixelMenuBar`: status item, loopback listener, sprite slicing, menu.
- `Resources/pets`: copied from `webview-ui/public/assets/pets`. The sheet layout used is the one in
  `core/src/assets/pngDecoder.ts`: `walkRight` is three 32x32 cells at y=64, `idleDown` is three 16x32
  cells at y=0 starting at x=48.

Not ported on purpose: transcript tailing, heuristic (no-hooks) mode, context gauges, teams.
