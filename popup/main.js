'use strict';
// Small always-on-top window for the Pixel Agents standalone office.
// Spawns `pixel-agents` in the workspace, waits for its tokened URL, loads it.
// The URL carries a bearer token: it is never logged or written to disk.

const { app, BrowserWindow, Menu, screen } = require('electron');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const WORKSPACE = process.env.PIXEL_PIN_WORKSPACE || process.cwd();
const PORT = process.env.PIXEL_PIN_PORT; // unset => the CLI picks a free port
const DEFAULT_SIZE = { width: 420, height: 320 };
const STARTUP_TIMEOUT_MS = 60_000;
const BOUNDS_FILE = path.join(os.homedir(), '.pixel-agents', 'pin-window.json');
const URL_RE = /http:\/\/127\.0\.0\.1:(\d+)\/\?token=[A-Za-z0-9_-]+/;

let server = null;
let win = null;
let quitting = false;

function loadBounds() {
  try {
    const b = JSON.parse(fs.readFileSync(BOUNDS_FILE, 'utf8'));
    const ok = ['x', 'y', 'width', 'height'].every((k) => Number.isFinite(b[k]));
    if (!ok) return DEFAULT_SIZE;
    if (Number.isFinite(b.zoom) && b.zoom >= 0.4 && b.zoom <= 2) pageZoom = b.zoom;
    // Ignore saved positions that are no longer on any display.
    const visible = screen.getAllDisplays().some((d) => {
      const a = d.workArea;
      return b.x < a.x + a.width && b.x + b.width > a.x && b.y < a.y + a.height && b.y + b.height > a.y;
    });
    return visible ? b : DEFAULT_SIZE;
  } catch {
    return DEFAULT_SIZE;
  }
}

function saveBounds() {
  if (!win || win.isDestroyed()) return;
  try {
    fs.mkdirSync(path.dirname(BOUNDS_FILE), { recursive: true });
    fs.writeFileSync(BOUNDS_FILE, JSON.stringify({ ...win.getBounds(), zoom: pageZoom }), { mode: 0o600 });
  } catch {
    /* best effort */
  }
}

function startServer() {
  const args = ['--yes', 'pixel-agents', '--host', '127.0.0.1'];
  if (PORT) args.push('--port', PORT);
  server = spawn('npx', args, { cwd: WORKSPACE, stdio: ['ignore', 'pipe', 'pipe'] });

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timed out waiting for the server URL')), STARTUP_TIMEOUT_MS);
    let buf = '';
    const onData = (chunk) => {
      buf = (buf + chunk.toString()).slice(-8192);
      const m = buf.match(URL_RE);
      if (m) {
        clearTimeout(timer);
        server.stdout.off('data', onData);
        server.stderr.off('data', onData);
        // Keep draining so the child never blocks on a full pipe.
        server.stdout.resume();
        server.stderr.resume();
        resolve(m[0]);
      }
    };
    server.stdout.on('data', onData);
    server.stderr.on('data', onData);
    server.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
    server.on('exit', (code) => {
      clearTimeout(timer);
      if (!quitting) reject(new Error(`server exited early (code ${code})`));
    });
  });
}

function stopServer() {
  if (server && !server.killed) server.kill('SIGTERM');
}

function createWindow(url) {
  const bounds = loadBounds();
  win = new BrowserWindow({
    ...bounds,
    minWidth: 240,
    minHeight: 180,
    title: 'Pixel Agents',
    backgroundColor: '#1e1e2e',
    alwaysOnTop: true,
    fullscreenable: false,
    webPreferences: { contextIsolation: true, sandbox: true, nodeIntegration: false },
  });
  win.setAlwaysOnTop(true, 'floating');
  win.setVisibleOnAllWorkspaces(true);

  // Only the local office may load here; anything else opens nowhere.
  const origin = new URL(url).origin;
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e, target) => {
    if (new URL(target).origin !== origin) e.preventDefault();
  });

  win.on('close', saveBounds);
  win.on('closed', () => {
    win = null;
  });
  win.webContents.on('did-finish-load', () => win.webContents.setZoomFactor(pageZoom));
  win.loadURL(url);
}

function showError(message) {
  win = new BrowserWindow({ ...DEFAULT_SIZE, title: 'Pixel Agents', alwaysOnTop: true });
  win.loadURL(
    'data:text/html;charset=utf-8,' +
      encodeURIComponent(
        `<body style="font:13px -apple-system;padding:16px;background:#1e1e2e;color:#f38ba8">` +
          `<b>Pixel Agents failed to start</b><p>${message.replace(/[<>&]/g, '')}</p></body>`,
      ),
  );
}

let pageZoom = 1;
const ZOOM_STEPS = [0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 2];

function applyPageZoom(factor) {
  pageZoom = factor;
  if (win && !win.isDestroyed()) win.webContents.setZoomFactor(pageZoom);
}

// Page zoom shrinks the whole UI (toolbar, settings) like browser zoom; the
// office canvas keeps its own 1x-10x zoom via the on-page +/- buttons.
function stepZoom(dir) {
  const i = ZOOM_STEPS.findIndex((z) => z >= pageZoom - 1e-6);
  const next = Math.max(0, Math.min(ZOOM_STEPS.length - 1, (i < 0 ? ZOOM_STEPS.length - 1 : i) + dir));
  applyPageZoom(ZOOM_STEPS[next]);
}

function buildMenu() {
  const template = [
    { role: 'appMenu' },
    {
      label: 'View',
      submenu: [
        { label: 'Zoom In', accelerator: 'CmdOrCtrl+=', click: () => stepZoom(1) },
        { label: 'Zoom Out', accelerator: 'CmdOrCtrl+-', click: () => stepZoom(-1) },
        { label: 'Actual Size', accelerator: 'CmdOrCtrl+0', click: () => applyPageZoom(1) },
      ],
    },
    {
      label: 'Window',
      submenu: [
        {
          label: 'Always on Top',
          type: 'checkbox',
          checked: true,
          accelerator: 'CmdOrCtrl+Shift+T',
          click: (item) => win && win.setAlwaysOnTop(item.checked, 'floating'),
        },
        { role: 'minimize' },
        { role: 'close' },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

app.on('before-quit', () => {
  quitting = true;
  saveBounds();
  stopServer();
});
app.on('window-all-closed', () => app.quit());
process.on('SIGINT', () => app.quit());
process.on('SIGTERM', () => app.quit());

app.whenReady().then(async () => {
  buildMenu();
  try {
    createWindow(await startServer());
  } catch (err) {
    showError(String(err.message || err));
  }
});
