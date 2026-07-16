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

Keeping capture upstream of rendering preserves macOS Portrait, Center Stage, Studio Light, and Background Replacement. macOS stores these effects per capture application, so a background selected for Slack or Arc is not automatically selected for ASCII Camera. While ASCII Camera is running, use `asciicam effects` and enable **Background** once in Apple's Video Effects panel.

Camera clients normally mirror their local self-view themselves. ASCII Camera therefore publishes camera-native orientation, avoiding the double flip that previously made the Meet or Slack preview appear unmirrored.

## Install

Install the current OBS release in `/Applications`, then run:

```bash
scripts/install.sh
```

The script first verifies the OBS application and its embedded Camera Extension using Apple's code-signing tools. It then tests the renderer and transport, builds an ad-hoc-signed headless app, installs its LaunchAgent, and installs `/usr/local/bin/asciicam`.

### One-time extension activation

If `asciicam status` reports `modern driver: not activated`, run:

```bash
open -a OBS --args --startvirtualcam
```

When `asciicam status` reports `modern driver: approval pending`, open **System Settings → General → Login Items & Extensions**, scroll to **Camera Extensions**, click its info button, and enable **OBS Virtual Camera**. Restart OBS and click **Start Virtual Camera** once. When it starts successfully, quit OBS completely. This activation is only required once. The Camera Extensions row may not exist until macOS has accepted a valid extension activation request.

If no prompt or Extensions section appears, verify the installed application:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/OBS.app
```

Any validation error means macOS will refuse to register the bundled camera extension. Reinstall OBS from its official DMG, choosing **Replace** when copying it into `/Applications`, and rerun `scripts/install.sh`.

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
asciicam columns  show the current column count
asciicam columns N
                  change columns live (48–240; default 240)
asciicam effects  open Apple's Video Effects panel for ASCII Camera
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
