# ASCII Camera for macOS

ASCII Camera turns the macOS camera feed into shape-aware ASCII and publishes the result as a real virtual camera named **ASCII Camera**. After one-time installation and macOS approval, starting it is one command:

```bash
asciicam
```

There is no browser window, OBS scene, screen capture, start button, Dock icon, or manual routing step.

## What is preserved

This is the same renderer as the original browser prototype, ported to native Swift rather than replaced with a brightness ramp. It still:

- Builds a six-dimensional shape vector for all 95 printable ASCII glyphs using Menlo.
- Samples six staggered circular regions inside each 6×9 cell.
- Samples ten neighboring regions for widened directional contrast.
- Applies the same directional contrast, shape contrast, gamma, mirror, and invert stages.
- Uses the same quantized 9⁶ nearest-glyph cache.
- Renders at **240 columns by default** to a 1280×720, 30 fps camera stream.

The legacy browser version remains in the repository for reference. Its reset value and keyboard range also use 240 columns now.

## Architecture

The native workflow has two signed components:

1. **Headless host app** — runs in the logged-in user session, requests camera permission, captures the physical or Continuity Camera through AVFoundation, runs the shape-aware renderer, and publishes completed BGRA frames.
2. **Core Media I/O Camera Extension** — exposes `ASCII Camera` to Meet, Zoom, Slack, FaceTime, and other camera clients. It reads only completed frames from an App Group mmap and sends them as a 1280×720 source stream.

The frame transport is a locked, double-buffered memory map. Camera clients never execute the renderer, a slow client cannot block capture, and the extension never reads a partially written frame.

This split is intentional. Apple runs Camera Extensions in a restricted system sandbox that has no WindowServer access. Keeping capture in the host also lets macOS camera effects remain upstream of ASCII rendering. Portrait mode, Center Stage, Studio Light, and the selected virtual background are preserved when macOS supplies them on the AVFoundation feed. Apple ultimately controls effect availability for each camera and macOS release, so an effect that macOS withholds from an app cannot be reconstructed by ASCII Camera.

## Requirements

- macOS 14 or newer.
- Full Xcode (Command Line Tools alone cannot build or sign a Camera Extension).
- An Apple Developer team selected in Xcode. A local development signing team is sufficient for development; distribution to other Macs requires the appropriate Apple signing/provisioning setup.

## Build and install

1. Install Xcode, open it once, and add your Apple ID under **Xcode → Settings → Accounts**.
2. Find your Team ID in the account details.
3. From this repository, run:

```bash
scripts/install.sh YOUR_TEAM_ID
```

The installer runs the native core tests, builds and signs the app plus Camera Extension, copies the app to `/Applications`, and installs `asciicam` in `/usr/local/bin`.

Then run:

```bash
asciicam
```

On the first launch only, macOS requires two security decisions that software cannot bypass:

- Allow **ASCII Camera** to access the camera.
- Allow its Camera Extension in **System Settings → Privacy & Security** when prompted.

Run `asciicam` once more after approval. Some already-running calling apps cache their camera list and need to be restarted once. From then on, `asciicam` starts capture headlessly and `ASCII Camera` is directly selectable in the calling app.

## Command line

```text
asciicam          start the headless camera host
asciicam status   show host and Camera Extension state
asciicam stop     release the physical camera
asciicam logs     stream native host/extension diagnostics
```

## Tests

The test harness creates a real Core Video gradient frame, renders it to 1280×720 ASCII, verifies the 240-column defaults, and round-trips a BGRA frame through two independently opened shared-frame stores.

```bash
scripts/test.sh
```

The host and extension sources can also be checked independently with `swiftc`; a full signed end-to-end Camera Extension build requires Xcode by Apple design.

## Legacy browser prototype

The original HTML/JS renderer still runs with:

```bash
npm install
npm start
```

It is no longer part of the recommended virtual-camera workflow.
