# Pixel Agents popup

A small, always-on-top Electron window for the standalone Pixel Agents office (macOS).
It starts `pixel-agents` for a workspace, waits for the tokened URL it prints, and loads
that URL in a 420x320 window that floats above other apps.

## Setup

```bash
cd popup
npm install        # downloads Electron (~100 MB, git-ignored)
```

Node 20+ is required (the same as Pixel Agents itself).

## Run

Run the launcher from anywhere, passing the workspace whose Claude sessions you want to watch.
It defaults to the current directory.

```bash
pixel-pin ~/path/to/workspace
```

`pixel-pin` lives in this folder. Link it onto your PATH once:

```bash
ln -sf "$PWD/pixel-pin" ~/.local/bin/pixel-pin
```

It finds the app folder from its own location, so the repo can live anywhere.

Or without the script: `PIXEL_PIN_WORKSPACE=/path/to/workspace npm start` from this folder.

Start `claude` in the same workspace **after** the window is open. Claude Code reads hooks when a
session starts, so a session that was already running will not move a character.

## Controls

| Keys | Action |
|---|---|
| Cmd + `-` / Cmd + `=` | Zoom the whole page out / in (40%-200%), so the toolbar fits a small window |
| Cmd + `0` | Reset page zoom to 100% |
| Cmd + Shift + T | Toggle always on top |
| Cmd + Q | Quit (also stops the server it started) |

The office's own canvas zoom (1x-10x) is separate. Use the `+` / `-` buttons in its top-left corner.
Window size, position and page zoom are remembered in `~/.pixel-agents/pin-window.json`.

## Environment

| Variable | Meaning |
|---|---|
| `PIXEL_PIN_WORKSPACE` | Workspace directory the server watches (default: current directory) |
| `PIXEL_PIN_PORT` | Fixed port for the server (default: a free port chosen by the CLI) |

## Notes

- If a standalone server is already running, the CLI reuses it ("Reusing existing standalone server").
  Close any other Pixel Agents window or server first if you want a clean start.
- The URL carries a `?token=` that can approve the hooks install. The app never logs it or writes
  it to disk, and the window cannot navigate away from the local office.
- The window uses the standard title bar. A hidden title bar made the window impossible to drag
  because the page defines no draggable region.
- Only `127.0.0.1` is used. Nothing here binds to the network.
