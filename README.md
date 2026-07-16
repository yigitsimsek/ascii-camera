# ASCII Camera for macOS

ASCII Camera captures the macOS camera, applies the original shape-aware ASCII renderer at **240 columns**, and publishes 1920×1080 video to calling apps. Daily use is one command:

```bash
asciicam
```

There is no browser, OBS process, scene, screen capture, start screen, Dock icon, or manual routing step.

## Free architecture

The free workflow reuses OBS's properly signed modern CoreMediaIO Camera Extension without running OBS itself:

1. A headless Swift host captures the physical or Continuity Camera through AVFoundation and runs the 240-column ASCII renderer.
2. The host writes BGRA sample buffers directly into the sink stream exposed by **OBS Virtual Camera**.
3. OBS's signed Camera Extension publishes those frames to Meet, Slack, Zoom, Photo Booth, and other camera clients.
4. A per-user LaunchAgent lets `asciicam` start and stop the headless host cleanly.

OBS must remain installed because it owns and updates the signed extension, but it stays completely closed during normal use. No Apple Developer subscription is required for ASCII Camera.

The renderer remains the browser prototype's shape matcher, not a brightness ramp. It builds six-dimensional Menlo glyph vectors, samples six staggered internal regions and ten neighboring regions, applies directional and global contrast, and uses the same quantized 9⁶ nearest-glyph cache.

Keeping capture upstream of rendering preserves macOS Portrait, Center Stage, Studio Light, and virtual backgrounds whenever macOS supplies the effected AVFoundation feed to the host. Effect availability remains controlled by macOS.

## Install

Install the current OBS release in `/Applications`, then run:

```bash
scripts/install.sh
```

The script tests the renderer and transport, builds an ad-hoc-signed headless app, installs its LaunchAgent, and installs `/usr/local/bin/asciicam`.

### One-time extension activation

If `asciicam status` reports `modern driver: not activated`, run:

```bash
open -a OBS --args --startvirtualcam
```

Approve **OBS Virtual Camera** in System Settings if macOS asks. Once the virtual camera starts, quit OBS completely. This activation is only required once.

Now run:

```bash
asciicam
```

On first start, allow **ASCII Camera** to access the camera. Fully restart any calling app that was open during activation, then select **OBS Virtual Camera**.

If `asciicam status` launches the old browser on port 4173, remove the stale `alias asciicam=.../start.command` line from `~/.zshrc`, open a new terminal, and try again. Shell aliases take precedence over `/usr/local/bin/asciicam`.

## Commands

```text
asciicam          start the headless camera host
asciicam status   show host and Camera Extension state
asciicam stop     release the physical camera
asciicam logs     stream native diagnostics
```

## Tests

```bash
scripts/test.sh
```

The suite renders real Core Video frames, verifies the 240-column renderer, builds the release host, and tests its IOSurface transport primitives.

## Independent modern extension

`scripts/install-modern.sh PAID_TEAM_ID` builds the project's own Camera Extension from `AsciiCamera.xcodeproj`. That removes the OBS installation dependency, but Apple does not allow a free Personal Team to provision the System Extension capability.

## Browser prototype

The original HTML/JS implementation remains for reference:

```bash
npm install
npm start
```
