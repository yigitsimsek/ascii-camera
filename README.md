# ASCII Camera for macOS

A local, shape-aware ASCII webcam renderer inspired by Alex Harri's article, **“ASCII characters are not pixels.”**

This is not a normal brightness-ramp filter. It:

- Generates a six-dimensional shape vector for every printable ASCII glyph using the actual monospace font.
- Samples six staggered circular regions inside every camera cell.
- Samples ten regions outside each cell for widened directional contrast.
- Applies directional and global contrast enhancement.
- Uses a quantized 9^6 lookup cache for fast nearest-glyph matching.
- Renders rows as monospaced strings for a clean OBS-friendly output.

Everything runs locally in the browser. No camera frames are uploaded.

## Run it

### One click on macOS

1. Double-click `start.command`.
2. Your browser opens at `http://127.0.0.1:4173`.
3. Click **Start camera** and allow camera access.

If macOS blocks the script, right-click `start.command`, choose **Open**, then approve it.

### From Terminal

```bash
cd ascii-camera
python3 -m http.server 4173 --bind 127.0.0.1
```

Then open `http://127.0.0.1:4173`.

Camera access requires localhost or HTTPS, so opening `index.html` directly is not enough.

## Use it as a camera in Zoom, Meet, Slack, or Discord

1. Install and open OBS Studio.
2. Run ASCII Camera and press **H** to hide its controls.
3. In OBS, add **Window Capture** and select the ASCII Camera browser window.
4. Crop or fit it to the OBS canvas.
5. Click **Start Virtual Camera** in OBS.
6. Select **OBS Virtual Camera** in your calling app.

For a clean browser window, append `?clean=1` to the URL:

```text
http://127.0.0.1:4173/?clean=1
```

## Controls

- **Columns:** ASCII resolution. Lower is faster and chunkier; higher is denser.
- **Shape contrast:** exaggerates differences inside each glyph cell.
- **Directional contrast:** sharpens boundaries using samples outside the cell.
- **Gamma:** changes camera brightness before glyph matching.
- **Mirror:** behaves like a normal selfie camera.
- **Invert:** swaps bright and dark regions.

Keyboard shortcuts:

```text
H  show/hide controls
F  fullscreen
M  mirror
I  invert
[  fewer columns
]  more columns
```

## Notes

The implementation follows the article's core technique, but it is an independent CPU-oriented implementation rather than the author's exact GPU pipeline. On an Apple Silicon Mac, 80–130 columns should generally be comfortable. Reduce columns if the browser becomes warm or the frame rate drops.
