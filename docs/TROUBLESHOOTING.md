# Troubleshooting

## `OBS Virtual Camera` is missing

1. Confirm OBS is installed at `/Applications/OBS.app`.
2. Verify its signature:

   ```bash
   codesign --verify --deep --strict --verbose=2 /Applications/OBS.app
   ```

3. Run `open -a OBS --args --startvirtualcam`.
4. If `asciicam status` says `approval pending`, open **System Settings →
   General → Login Items & Extensions → Camera Extensions** and enable **OBS
   Virtual Camera**.
5. Restart OBS, start its virtual camera once, then quit OBS completely.
6. Fully quit and reopen the calling app so it refreshes its camera list.

## The host does not start

```bash
asciicam status
asciicam logs
```

Check that **ASCII Camera** is allowed under **System Settings → Privacy &
Security → Camera**. If launchd reports a code-signing exit after a local
rebuild, rerun `scripts/install.sh` to refresh the LaunchAgent registration.

## `asciicam status` opens the old browser

Remove any old `alias asciicam=.../start.command` entry from `~/.zshrc`, then
open a new terminal. Shell aliases take precedence over `/usr/local/bin`.

## Background Replacement is missing

Effects are scoped per capture application. Start ASCII Camera, run
`asciicam effects`, and enable **Background** in the macOS panel that appears.
Background Replacement requires a supported Mac, camera format, and macOS 15
or later.

## The self-view orientation looks wrong

ASCII Camera publishes camera-native orientation. Meet, Slack, Zoom, and Photo
Booth normally mirror the local preview themselves while sending conventional
orientation to other participants. Verify orientation from a second client
before compensating for a local-preview setting.

## Performance is too slow

Reduce the live grid size:

```bash
asciicam columns 120
```

Valid values are 48 through 240. Run `scripts/benchmark.sh` for steady-state
release measurements on the current Mac.

## Clean uninstall

The uninstall script removes ASCII Camera but leaves OBS untouched:

```bash
scripts/uninstall.sh
```

The script stops and unloads the host, removes `/Applications/ASCII Camera.app`,
removes `/usr/local/bin/asciicam`, and deletes the app's preferences domain.
