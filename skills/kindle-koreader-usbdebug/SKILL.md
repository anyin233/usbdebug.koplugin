---
name: kindle-koreader-usbdebug
description: >-
  Operate, deploy to, visually test, and debug a physical jailbroken Kindle running KOReader over USB
  (zero-exit CDC-ECM/NCM or FunctionFS SSH) or Wi-Fi. Use when bootstrapping USB debugging over MTP,
  connecting to KOReader Dropbear SSH, capturing E-Ink /dev/fb0 screenshots, computing UI pixel diffs,
  injecting Multi-Touch gestures, rendering KOReader widgets offscreen, or developing .koplugin Lua/Go plugins.
---

# Kindle + KOReader USB Debug & Visual Testing

Deterministic workflow for driving a physical jailbroken Kindle running KOReader over a USB cable **without exiting KOReader**, deploying `.koplugin` bundles, capturing E-Ink screenshots, injecting touch gestures, reading logs, and rendering UI widgets offscreen.

Bundled scripts live in [`scripts/`](scripts/) relative to this `SKILL.md`:
- [`scripts/kindle_usb_bridge.py`](scripts/kindle_usb_bridge.py) — USB auto-discovery (`192.168.15.1` CDC-ECM/NCM or `127.0.0.1` FunctionFS bridge) & USB mode probe
- [`scripts/kindle_ssh.sh`](scripts/kindle_ssh.sh) — SSH command runner and clean macOS/Linux-to-Kindle `tar` deployer
- [`scripts/kindle_screenshot.py`](scripts/kindle_screenshot.py) — Zero-dependency `/dev/fb0` → PNG capture & pixel-diff bounding-box locator
- [`scripts/kindle_touch.sh`](scripts/kindle_touch.sh) — Multi-Touch Type B (`pt_mt` + `BTN_TOUCH`) tap, long-press, and swipe injector via KOReader's `luajit` FFI
- [`scripts/kindle_offscreen_render.sh`](scripts/kindle_offscreen_render.sh) — Headless KOReader widget → PNG renderer (never touches `/dev/fb0` or the live session)

For KOReader Lua, `lua-ljsqlite3`, `json` null-sentinel, background subprocess, and i18n pitfalls, read [`references/koreader-lua-pitfalls.md`](references/koreader-lua-pitfalls.md).

---

## Step 0: Check USB Connectivity & First-Time MTP Bootstrap

Probe the USB bus before running commands:

```bash
python3 -B scripts/kindle_usb_bridge.py probe
```

- **`"net": true` or `"ffs": true`**: `usbdebug.koplugin` is active inside KOReader. `KINDLE_HOST` is **optional** — all scripts auto-discover the USB Kindle (`192.168.15.1:2222` on CDC-ECM/NCM or `127.0.0.1:2222` on FunctionFS) and handle empty-password Dropbear auth via `sshpass` automatically.
- **`"mtp": true`**: The Kindle is in stock MTP mode (not running KOReader yet, or `usbdebug.koplugin` is not installed yet).
  - If `usbdebug.koplugin` is not installed on the Kindle yet, run the repo's bootstrapper once while in MTP (or UMS) mode:
    ```bash
    ./scripts/bootstrap_mtp.sh
    ```
  - Then open KOReader on the Kindle — `usbdebug.koplugin` auto-starts USB networking (`1949:9983`) or FunctionFS (`1949:9982`), and exits cleanly after KOReader closes so stock MTP still works.
- **Wi-Fi override**: Set `export KINDLE_HOST="192.168.x.x"` (and optionally `KINDLE_PORT=2222`, `KINDLE_USER=root`) to target a Kindle over Wi-Fi instead of USB.

---

## Core Workflow

### Step 1: Probe & Observe Before Acting (Mandatory)

1. Verify SSH reachability, architecture, USB debug status, and running KOReader processes:
   ```bash
   scripts/kindle_ssh.sh exec "uname -m; cat /var/tmp/usbdebugd.status 2>/dev/null || true; ps | grep reader.lua"
   ```
   - **Note on CPU arch**: Newer Kindles (e.g., PW5/PW6 on Bellatrix4) run a **32-bit `armv7l` userland** even on 64-bit SoCs. Cross-compile Go binaries with `CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 -trimpath -ldflags="-s -w"`.
2. Capture the current screen **before** touching or restarting anything:
   ```bash
   python3 -B scripts/kindle_screenshot.py capture /tmp/kindle_before.png
   ```
3. Inspect `/tmp/kindle_before.png` visually.
   - **Active-session guardrail**: If the user is actively reading or running a background download queue, **do not restart `reader.lua` or inject screen taps**. Deploy files in place and verify UI via **Step 5 (Offscreen Rendering)** instead.

### Step 2: Deploy Plugin Files Safely

KOReader plugins live at `/mnt/us/koreader/plugins/<name>.koplugin`.

```bash
scripts/kindle_ssh.sh deploy ./my.koplugin /mnt/us/koreader/plugins/my.koplugin
```

Key constraints enforced by `kindle_ssh.sh`:
- **Never pass `-o BatchMode=yes`** to SSH: KOReader's passwordless Dropbear (`-n`) uses empty-password auth, which `BatchMode=yes` rejects with `Permission denied (publickey,password)`. `kindle_ssh.sh` wraps `ssh` with `sshpass -p ""` and `SSH_ASKPASS_REQUIRE=never` automatically.
- **Always set `COPYFILE_DISABLE=1`** on macOS `tar`: prevents `._*` AppleDouble resource-fork files from littering `/mnt/us`.
- **Keep `/var/tmp` light**: `/var` is a 64 MB `tmpfs` (often >95% used by Kindle system logs). Store staging/backups on `/mnt/us` (outside visible library folders or clean up immediately) or `/dev/shm` when temporary RAM storage is needed; never leave large files in `/var/tmp/`.
- **Keep binary pipes clean**: never merge remote `2>&1` into binary `stdout` pipes (`gzip`, `tar`, `cat`).

### Step 3: Visual Capture & Exact Coordinate Discovery

Never guess touch coordinates by eye on high-DPI (300 DPI, e.g., `1272×1696`) E-Ink panels.

```bash
python3 -B scripts/kindle_screenshot.py capture /tmp/s0.png
python3 -B scripts/kindle_screenshot.py lines /tmp/s0.png
python3 -B scripts/kindle_screenshot.py diff /tmp/s0.png /tmp/s1.png
```

### Step 4: Inject Touch Gestures (`tap` / `hold` / `swipe`)

```bash
scripts/kindle_touch.sh tap 636 30             # Tap top-center menu chevron
scripts/kindle_touch.sh hold 500 415           # 900ms long-press on a list row
scripts/kindle_touch.sh swipe 600 1200 600 400 # Vertical swipe
```

`kindle_touch.sh` auto-discovers the touchscreen `/dev/input/eventX` node from `/proc/bus/input/devices` and drives Multi-Touch Type B (`ABS_MT_TRACKING_ID` + `EV_KEY BTN_TOUCH`) via `/mnt/us/koreader/luajit`'s built-in `ffi`.

### Step 5: Restarting KOReader vs. Offscreen Rendering

- **Option A — Offscreen Headless Render (Preferred when user session is busy)**:
  Renders real KOReader widgets (`Blitbuffer.TYPE_BB8`, Kindle 300 DPI FreeType/HarfBuzz fonts) into `/tmp/*.png` without touching `/dev/fb0` or live settings:
  ```bash
  scripts/kindle_offscreen_render.sh my_render_snippet.lua /tmp/preview.png
  ```

- **Option B — Clean KOReader Restart (Only when screen is idle)**:
  KOReader's launch wrapper (`/var/tmp/koreader.sh`) loops **only while `./reader.lua` exits with code `85`**.
  - **Never run `killall -9 reader.lua`**: exit code != 85 drops back to the stock Kindle UI.
  - Restart via KOReader UI (**Power → Restart**) or HTTP Inspector (`GET /koreader/UIManager/restartKOReader/`). `usbdebugd` keeps running across `quit(85)` restarts so your USB SSH session stays alive.

### Step 6: Tail Logs & Inspect Lua / SQLite Live

```bash
scripts/kindle_ssh.sh exec "tail -n 50 /mnt/us/koreader/crash.log"
scripts/kindle_ssh.sh exec "cat /var/tmp/usbdebugd.log"
```

When running standalone Lua scripts via `./luajit`, always `cd /mnt/us/koreader` and `require("setupkoenv")` first so `libs/lib*.so` resolve cleanly.
