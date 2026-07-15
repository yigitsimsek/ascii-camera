# ASCII Camera for macOS

ASCII Camera reads the macOS camera, applies the original shape-aware ASCII renderer at **240 columns**, and publishes 1280×720 video to calling apps. The normal workflow is one command:

```bash
asciicam
```

There is no browser, OBS process, scene, screen capture, start screen, Dock icon, or manual routing step.

## Free architecture

The default installer does not need an Apple Developer account. It installs three small pieces:

1. A headless Swift host captures the physical or Continuity Camera with AVFoundation and runs the ASCII renderer.
2. A per-user LaunchAgent gives the host a launchd-managed Mach service and lets `asciicam` start and stop it cleanly.
3. OBS's standalone 552 KB legacy CoreMediaIO plug-in receives IOSurface frames from that service. OBS itself never starts and can be uninstalled after the plug-in is copied.

This uses the plug-in's public, open-source transport protocol. The camera is listed as **OBS Virtual Camera** because the unmodified, Developer ID-signed plug-in supplies its device identity. The video comes entirely from ASCII Camera.

The renderer remains the browser prototype's shape matcher, not a brightness ramp. It builds six-dimensional Menlo glyph vectors, samples six staggered internal regions and ten neighboring regions, applies directional and global contrast, and uses the same quantized 9⁶ nearest-glyph cache.

Keeping capture upstream of rendering means macOS Portrait, Center Stage, Studio Light, and virtual backgrounds are preserved whenever macOS supplies an effected AVFoundation feed to the host. Effect availability is still controlled by macOS.

## Free-driver compatibility

Apple deprecated legacy DAL camera plug-ins in favor of Camera Extensions. A legacy plug-in cannot load in Apple apps or third-party apps that enforce library validation.

- Expected to work on this Mac: **Arc** (including Google Meet), **Zoom**, **Microsoft Teams**, and **Discord**.
- Needs an end-to-end check: **Slack**; its helper-process signing varies.
- Does not work: **Chrome**, **Safari**, **FaceTime**, and other Apple apps. Use Arc for Meet.

Do not disable SIP or weaken system security to change this. Universal compatibility requires Apple's paid System Extension provisioning; that implementation remains in `Native/Extension` and can be built separately.

## Free install

OBS is already installed on the development Mac, so its plug-in can be copied once. Quit OBS, then run:

```bash
scripts/install.sh
```

The script tests the renderer, builds an ad-hoc-signed headless app, copies the standalone plug-in to `/Library/CoreMediaIO/Plug-Ins/DAL`, installs the user LaunchAgent, and installs `/usr/local/bin/asciicam`. Afterward, OBS can be uninstalled; keep the copied DAL plug-in.

Quit and reopen the calling app once so it refreshes its camera list. Then:

```bash
asciicam
```

On first start, allow **ASCII Camera** to use the camera. Select **OBS Virtual Camera** in Arc, Zoom, Teams, or another compatible app.

If `asciicam status` launches the old browser on port 4173, remove the stale `alias asciicam=.../start.command` line from `~/.zshrc`, open a new terminal, and try again. Shell aliases take precedence over the installed `/usr/local/bin/asciicam` command.

## Commands

```text
asciicam          start the headless camera host
asciicam status   show host and driver state
asciicam stop     release the physical camera
asciicam logs     stream native diagnostics
```

## Tests

```bash
scripts/test.sh
```

The suite renders real Core Video frames, verifies 240-column output and shared-frame behavior, builds the release host, and runs an IOSurface/Mach transport test when its shell is permitted to load a temporary LaunchAgent.

## Paid modern option

`scripts/install-modern.sh PAID_TEAM_ID` builds the CoreMediaIO Camera Extension in `AsciiCamera.xcodeproj`. That route works in Chrome, Safari, FaceTime, and other library-validated apps, but Apple does not allow a free Personal Team to provision its System Extension capability.

## Browser prototype

The original HTML/JS implementation remains for reference:

```bash
npm install
npm start
```
