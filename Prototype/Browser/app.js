const output = document.querySelector('#output');
const outputCtx = output.getContext('2d', { alpha: false });
const video = document.querySelector('#camera');
const sampler = document.querySelector('#sampler');
const sampleCtx = sampler.getContext('2d', { alpha: false, willReadFrequently: true });

const welcome = document.querySelector('#welcome');
const startButton = document.querySelector('#startButton');
const startError = document.querySelector('#startError');
const status = document.querySelector('#status');
const cameraSelect = document.querySelector('#cameraSelect');
const controls = document.querySelector('#controls');

const inputs = {
  mode: document.querySelector('#mode'),
  columns: document.querySelector('#columns'),
  contrast: document.querySelector('#contrast'),
  directional: document.querySelector('#directional'),
  gamma: document.querySelector('#gamma'),
  mirror: document.querySelector('#mirror'),
  invert: document.querySelector('#invert'),
};

const values = {
  columns: document.querySelector('#columnsValue'),
  contrast: document.querySelector('#contrastValue'),
  directional: document.querySelector('#directionalValue'),
  gamma: document.querySelector('#gammaValue'),
};

const TILE_W = 6;
const TILE_H = 9;
const SAMPLE_RADIUS = 1.65;
const FONT_STACK = 'Menlo, Monaco, "Courier New", monospace';
const CHARACTERS = Array.from({ length: 95 }, (_, i) => String.fromCharCode(32 + i));
const CACHE_RANGE = 9;
const CACHE_SIZE = CACHE_RANGE ** 6;
const MATRIX_BRIGHTNESS_BUCKETS = 12;

const INTERNAL_CENTERS = [
  [1.80, 2.15], [4.20, 1.65],
  [1.80, 4.55], [4.20, 4.05],
  [1.80, 6.95], [4.20, 6.45],
];

// Ten circles outside the cell. Their ordering matches the mapping described
// in Alex Harri's widened directional-contrast section.
const EXTERNAL_CENTERS = [
  [1.80, -0.55], [4.20, -0.55],
  [-0.85, 2.15], [6.85, 1.65],
  [-0.85, 4.55], [6.85, 4.05],
  [-0.85, 6.95], [6.85, 6.45],
  [1.80, 9.55], [4.20, 9.55],
];

const AFFECTING_EXTERNAL_INDICES = [
  [0, 1, 2, 4],
  [0, 1, 3, 5],
  [2, 4, 6],
  [3, 5, 7],
  [4, 6, 8, 9],
  [5, 7, 8, 9],
];

const internalKernels = INTERNAL_CENTERS.map(([x, y]) => makeKernel(x, y, SAMPLE_RADIUS));
const externalKernels = EXTERNAL_CENTERS.map(([x, y]) => makeKernel(x, y, SAMPLE_RADIUS));

let glyphVectors = [];
let lookupCache = new Int16Array(CACHE_SIZE);
let stream = null;
let running = false;
let frameRequest = 0;
let lastRenderAt = 0;
let fpsWindowStart = performance.now();
let renderedFrames = 0;
let currentRows = 0;
let currentColumns = 0;
let grayBuffer = new Float32Array(0);
let internalBuffer = new Float32Array(0);
let externalBuffer = new Float32Array(0);
let matrixStreams = [];
let cameraLabelsAvailable = false;

lookupCache.fill(-1);

if (new URLSearchParams(location.search).get('clean') === '1') {
  document.body.classList.add('clean');
}

function makeKernel(centerX, centerY, radius) {
  const taps = [];
  let weightTotal = 0;
  const minX = Math.floor(centerX - radius);
  const maxX = Math.ceil(centerX + radius);
  const minY = Math.floor(centerY - radius);
  const maxY = Math.ceil(centerY + radius);

  for (let y = minY; y <= maxY; y++) {
    for (let x = minX; x <= maxX; x++) {
      const dx = x + 0.5 - centerX;
      const dy = y + 0.5 - centerY;
      const distance = Math.hypot(dx, dy);
      if (distance >= radius) continue;
      const weight = 1 - distance / radius;
      taps.push({ x, y, weight });
      weightTotal += weight;
    }
  }

  return { taps, weightTotal };
}

function updateLabels() {
  values.columns.value = inputs.columns.value;
  values.contrast.value = Number(inputs.contrast.value).toFixed(2);
  values.directional.value = Number(inputs.directional.value).toFixed(2);
  values.gamma.value = Number(inputs.gamma.value).toFixed(2);
}

function resetSettings() {
  inputs.mode.value = 'ascii';
  inputs.columns.value = '240';
  inputs.contrast.value = '2.2';
  inputs.directional.value = '1.7';
  inputs.gamma.value = '0.9';
  inputs.mirror.checked = true;
  inputs.invert.checked = false;
  updateLabels();
  invalidateGrid();
}

function invalidateGrid() {
  currentColumns = 0;
  currentRows = 0;
}

function buildGlyphDatabase() {
  const width = 96;
  const height = 144;
  const glyphCanvas = document.createElement('canvas');
  glyphCanvas.width = width;
  glyphCanvas.height = height;
  const ctx = glyphCanvas.getContext('2d', { willReadFrequently: true });
  const rawVectors = [];

  for (const character of CHARACTERS) {
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, width, height);
    ctx.fillStyle = '#fff';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = `128px ${FONT_STACK}`;
    ctx.fillText(character, width / 2, height / 2 + 4);

    const pixels = ctx.getImageData(0, 0, width, height).data;
    const vector = INTERNAL_CENTERS.map(([cx, cy]) => {
      const px = (cx / TILE_W) * width;
      const py = (cy / TILE_H) * height;
      const radius = (SAMPLE_RADIUS / TILE_W) * width;
      return sampleGlyphCircle(pixels, width, height, px, py, radius);
    });
    rawVectors.push(vector);
  }

  const maxByDimension = new Array(6).fill(0);
  for (const vector of rawVectors) {
    for (let i = 0; i < 6; i++) {
      maxByDimension[i] = Math.max(maxByDimension[i], vector[i]);
    }
  }

  glyphVectors = rawVectors.map((vector) =>
    vector.map((value, i) => maxByDimension[i] > 0 ? value / maxByDimension[i] : 0)
  );
}

function sampleGlyphCircle(pixels, width, height, centerX, centerY, radius) {
  let sum = 0;
  let weightTotal = 0;
  const minX = Math.max(0, Math.floor(centerX - radius));
  const maxX = Math.min(width - 1, Math.ceil(centerX + radius));
  const minY = Math.max(0, Math.floor(centerY - radius));
  const maxY = Math.min(height - 1, Math.ceil(centerY + radius));

  for (let y = minY; y <= maxY; y++) {
    for (let x = minX; x <= maxX; x++) {
      const distance = Math.hypot(x + 0.5 - centerX, y + 0.5 - centerY);
      if (distance >= radius) continue;
      const weight = 1 - distance / radius;
      const value = pixels[(y * width + x) * 4] / 255;
      sum += value * weight;
      weightTotal += weight;
    }
  }
  return weightTotal ? sum / weightTotal : 0;
}

async function enumerateCameras() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  const cameras = devices.filter((device) => device.kind === 'videoinput');
  const previous = cameraSelect.value;
  cameraSelect.innerHTML = '';

  cameras.forEach((camera, index) => {
    const option = document.createElement('option');
    option.value = camera.deviceId;
    option.textContent = camera.label || `Camera ${index + 1}`;
    cameraSelect.append(option);
  });

  cameraLabelsAvailable = cameras.some((camera) => camera.label);
  if (cameras.some((camera) => camera.deviceId === previous)) {
    cameraSelect.value = previous;
  }
}

async function startCamera(deviceId = '') {
  startError.textContent = '';
  startButton.disabled = true;
  status.textContent = 'requesting camera…';

  try {
    stopCurrentStream();
    const constraints = {
      audio: false,
      video: {
        width: { ideal: 1280 },
        height: { ideal: 720 },
        frameRate: { ideal: 30, max: 60 },
        ...(deviceId ? { deviceId: { exact: deviceId } } : { facingMode: 'user' }),
      },
    };

    stream = await navigator.mediaDevices.getUserMedia(constraints);
    video.srcObject = stream;
    await video.play();
    await enumerateCameras();

    const activeDeviceId = stream.getVideoTracks()[0]?.getSettings().deviceId;
    if (activeDeviceId) cameraSelect.value = activeDeviceId;

    running = true;
    welcome.classList.add('hidden');
    status.textContent = 'starting…';
    fpsWindowStart = performance.now();
    renderedFrames = 0;
    frameRequest = requestAnimationFrame(renderLoop);
  } catch (error) {
    console.error(error);
    const message = getCameraErrorMessage(error);
    startError.textContent = message;
    status.textContent = 'camera unavailable';
  } finally {
    startButton.disabled = false;
  }
}

function stopCurrentStream() {
  running = false;
  cancelAnimationFrame(frameRequest);
  if (stream) {
    stream.getTracks().forEach((track) => track.stop());
    stream = null;
  }
}

function getCameraErrorMessage(error) {
  if (error?.name === 'NotAllowedError') {
    return 'Camera permission was denied. Enable it for this browser in System Settings → Privacy & Security → Camera.';
  }
  if (error?.name === 'NotFoundError') return 'No camera was found.';
  if (error?.name === 'NotReadableError') return 'The camera is already in use by another app.';
  return error?.message || 'Could not start the camera.';
}

function configureGrid() {
  const columns = Number(inputs.columns.value);
  const cellAspect = 0.58;
  const rows = Math.max(14, Math.round(columns * (output.height / output.width) * cellAspect));

  if (columns === currentColumns && rows === currentRows) return;

  currentColumns = columns;
  currentRows = rows;
  sampler.width = columns * TILE_W;
  sampler.height = rows * TILE_H;

  const pixelCount = sampler.width * sampler.height;
  grayBuffer = new Float32Array(pixelCount);
  internalBuffer = new Float32Array(columns * rows * 6);
  externalBuffer = new Float32Array(columns * rows * 10);
  matrixStreams = Array.from({ length: columns }, (_, column) => makeMatrixStream(column, rows));
}

function drawCameraIntoSampler() {
  const sourceWidth = video.videoWidth;
  const sourceHeight = video.videoHeight;
  const targetWidth = sampler.width;
  const targetHeight = sampler.height;
  const sourceAspect = sourceWidth / sourceHeight;
  const targetAspect = targetWidth / targetHeight;

  let sx = 0;
  let sy = 0;
  let sw = sourceWidth;
  let sh = sourceHeight;

  if (sourceAspect > targetAspect) {
    sw = sourceHeight * targetAspect;
    sx = (sourceWidth - sw) / 2;
  } else {
    sh = sourceWidth / targetAspect;
    sy = (sourceHeight - sh) / 2;
  }

  sampleCtx.save();
  sampleCtx.fillStyle = '#000';
  sampleCtx.fillRect(0, 0, targetWidth, targetHeight);
  sampleCtx.imageSmoothingEnabled = true;
  sampleCtx.imageSmoothingQuality = 'high';

  if (inputs.mirror.checked) {
    sampleCtx.translate(targetWidth, 0);
    sampleCtx.scale(-1, 1);
  }

  sampleCtx.drawImage(video, sx, sy, sw, sh, 0, 0, targetWidth, targetHeight);
  sampleCtx.restore();
}

function buildGrayBuffer() {
  const rgba = sampleCtx.getImageData(0, 0, sampler.width, sampler.height).data;
  const gamma = Number(inputs.gamma.value);
  const invert = inputs.invert.checked;

  for (let i = 0, p = 0; p < grayBuffer.length; i += 4, p++) {
    let luminance = (0.2126 * rgba[i] + 0.7152 * rgba[i + 1] + 0.0722 * rgba[i + 2]) / 255;
    luminance = Math.pow(luminance, gamma);
    grayBuffer[p] = invert ? 1 - luminance : luminance;
  }
}

function sampleKernel(baseX, baseY, kernel) {
  let sum = 0;
  let total = 0;
  const width = sampler.width;
  const height = sampler.height;

  for (const tap of kernel.taps) {
    const x = Math.max(0, Math.min(width - 1, baseX + tap.x));
    const y = Math.max(0, Math.min(height - 1, baseY + tap.y));
    sum += grayBuffer[y * width + x] * tap.weight;
    total += tap.weight;
  }
  return total ? sum / total : 0;
}

function collectVectors() {
  let internalOffset = 0;
  let externalOffset = 0;

  for (let row = 0; row < currentRows; row++) {
    const baseY = row * TILE_H;
    for (let col = 0; col < currentColumns; col++) {
      const baseX = col * TILE_W;
      for (let i = 0; i < 6; i++) {
        internalBuffer[internalOffset++] = sampleKernel(baseX, baseY, internalKernels[i]);
      }
      for (let i = 0; i < 10; i++) {
        externalBuffer[externalOffset++] = sampleKernel(baseX, baseY, externalKernels[i]);
      }
    }
  }
}

function enhanceVector(cellIndex, vector) {
  const directionalExponent = Number(inputs.directional.value);
  const globalExponent = Number(inputs.contrast.value);
  const externalStart = cellIndex * 10;

  // Directional contrast: brighter samples just outside the cell push the
  // corresponding internal components down, making boundaries read crisply.
  for (let i = 0; i < 6; i++) {
    let maxValue = vector[i];
    for (const externalIndex of AFFECTING_EXTERNAL_INDICES[i]) {
      maxValue = Math.max(maxValue, externalBuffer[externalStart + externalIndex]);
    }
    if (maxValue > 0.0001) {
      vector[i] = Math.pow(vector[i] / maxValue, directionalExponent) * maxValue;
    }
  }

  // Global contrast: preserve the brightest component while crunching the
  // darker components, exaggerating the cell's shape rather than its mean.
  let maxValue = 0;
  for (let i = 0; i < 6; i++) maxValue = Math.max(maxValue, vector[i]);
  if (maxValue > 0.0001) {
    for (let i = 0; i < 6; i++) {
      vector[i] = Math.pow(vector[i] / maxValue, globalExponent) * maxValue;
    }
  }
}

function findBestCharacter(vector) {
  let key = 0;
  const quantized = new Array(6);
  for (let i = 0; i < 6; i++) {
    const q = Math.min(CACHE_RANGE - 1, Math.floor(vector[i] * CACHE_RANGE));
    quantized[i] = (q + 0.5) / CACHE_RANGE;
    key = key * CACHE_RANGE + q;
  }

  const cached = lookupCache[key];
  if (cached >= 0) return cached;

  let bestIndex = 0;
  let bestDistance = Infinity;
  for (let charIndex = 0; charIndex < glyphVectors.length; charIndex++) {
    const glyph = glyphVectors[charIndex];
    let distance = 0;
    for (let i = 0; i < 6; i++) {
      const delta = glyph[i] - quantized[i];
      distance += delta * delta;
    }
    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = charIndex;
    }
  }

  lookupCache[key] = bestIndex;
  return bestIndex;
}

function renderAscii() {
  outputCtx.fillStyle = '#000';
  outputCtx.fillRect(0, 0, output.width, output.height);
  outputCtx.fillStyle = '#fff';
  outputCtx.textAlign = 'left';
  outputCtx.textBaseline = 'middle';

  const cellWidth = output.width / currentColumns;
  const cellHeight = output.height / currentRows;
  const fontSize = cellHeight * 0.88;
  outputCtx.font = `${fontSize}px ${FONT_STACK}`;
  const measuredWidth = outputCtx.measureText('M').width || fontSize * 0.6;
  const xScale = cellWidth / measuredWidth;
  const vector = new Array(6);

  outputCtx.save();
  outputCtx.scale(xScale, 1);

  for (let row = 0; row < currentRows; row++) {
    let line = '';
    for (let col = 0; col < currentColumns; col++) {
      const cellIndex = row * currentColumns + col;
      const start = cellIndex * 6;
      for (let i = 0; i < 6; i++) vector[i] = internalBuffer[start + i];
      enhanceVector(cellIndex, vector);
      line += CHARACTERS[findBestCharacter(vector)];
    }

    const y = (row + 0.5) * cellHeight;
    outputCtx.fillText(line, 0, y);
  }

  outputCtx.restore();
}

// Matrix mode runs after the complete ASCII frame is drawn. Multiplication
// only colors existing glyph pixels, leaving the matcher and glyph shapes
// exactly the same as ASCII mode.
function applyMatrixEffect(timestamp) {
  const paths = Array.from({ length: MATRIX_BRIGHTNESS_BUCKETS + 1 }, () => new Path2D());
  const cellWidth = output.width / currentColumns;
  const cellHeight = output.height / currentRows;
  const time = timestamp / 1000;

  for (let column = 0; column < currentColumns; column++) {
    const stream = matrixStreams[column];
    const progress = (time * stream.speed + stream.phase) % stream.cycle;
    const head = progress - stream.length;
    let runStart = 0;
    let runBucket = matrixBucket(0, head, stream.length);

    for (let row = 1; row <= currentRows; row++) {
      const bucket = row < currentRows ? matrixBucket(row, head, stream.length) : -1;
      if (bucket === runBucket) continue;
      paths[runBucket].rect(
        column * cellWidth,
        runStart * cellHeight,
        cellWidth + 0.5,
        (row - runStart) * cellHeight + 0.5,
      );
      runStart = row;
      runBucket = bucket;
    }
  }

  outputCtx.save();
  outputCtx.globalCompositeOperation = 'multiply';
  for (let bucket = 0; bucket < MATRIX_BRIGHTNESS_BUCKETS; bucket++) {
    const progress = bucket / (MATRIX_BRIGHTNESS_BUCKETS - 1);
    const greenIntensity = 0.55 + 0.40 * progress;
    const red = Math.round(255 * 0.04 * greenIntensity);
    const green = Math.round(255 * greenIntensity);
    const blue = Math.round(255 * 0.12 * greenIntensity);
    outputCtx.fillStyle = `rgb(${red}, ${green}, ${blue})`;
    outputCtx.fill(paths[bucket]);
  }
  outputCtx.fillStyle = 'rgb(100, 255, 140)';
  outputCtx.fill(paths[MATRIX_BRIGHTNESS_BUCKETS]);
  outputCtx.restore();
}

function matrixBucket(row, head, length) {
  const distance = head - row;
  if (Math.abs(distance) < 0.55) return MATRIX_BRIGHTNESS_BUCKETS;
  if (distance < 0 || distance >= length) return 0;
  const trail = Math.pow(1 - distance / length, 1.45);
  return Math.max(1, Math.min(
    MATRIX_BRIGHTNESS_BUCKETS - 1,
    Math.round(trail * (MATRIX_BRIGHTNESS_BUCKETS - 1)),
  ));
}

function makeMatrixStream(column, rows) {
  const seed = matrixHash(column ^ (rows << 16));
  const lengthLimit = Math.max(8, Math.min(28, Math.floor(rows / 2)));
  const length = 8 + ((seed >>> 8) % Math.max(1, lengthLimit - 7));
  const speed = 5 + unitInterval(seed ^ 0x68bc21eb) * 8;
  const gap = 3 + unitInterval(seed ^ 0x02e5be93) * 16;
  const cycle = rows + length + gap;
  const phase = unitInterval(seed ^ 0x967a889b) * cycle;
  return { length, speed, phase, cycle };
}

function unitInterval(value) {
  return matrixHash(value) / 0xffffffff;
}

function matrixHash(input) {
  let value = input >>> 0;
  value = Math.imul(value ^ (value >>> 16), 0x7feb352d);
  value = Math.imul(value ^ (value >>> 15), 0x846ca68b);
  return (value ^ (value >>> 16)) >>> 0;
}

function renderLoop(timestamp) {
  if (!running) return;

  // 30 FPS is enough for calls and keeps the CPU implementation quiet.
  if (timestamp - lastRenderAt >= 1000 / 30 && video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
    lastRenderAt = timestamp;
    configureGrid();
    drawCameraIntoSampler();
    buildGrayBuffer();
    collectVectors();
    renderAscii();
    if (inputs.mode.value === 'matrix') applyMatrixEffect(timestamp);

    renderedFrames++;
    const elapsed = timestamp - fpsWindowStart;
    if (elapsed >= 1000) {
      const fps = Math.round((renderedFrames * 1000) / elapsed);
      status.textContent = `${inputs.mode.value} · ${currentColumns}×${currentRows} · ${fps} fps`;
      renderedFrames = 0;
      fpsWindowStart = timestamp;
    }
  }

  frameRequest = requestAnimationFrame(renderLoop);
}

async function toggleFullscreen() {
  try {
    if (!document.fullscreenElement) await document.documentElement.requestFullscreen();
    else await document.exitFullscreen();
  } catch (error) {
    console.error(error);
  }
}

function toggleControls(forceVisible = null) {
  const shouldHide = forceVisible === null
    ? !document.body.classList.contains('controls-hidden')
    : !forceVisible;
  document.body.classList.toggle('controls-hidden', shouldHide);
}

startButton.addEventListener('click', () => startCamera());
const params = new URLSearchParams(window.location.search);

if (params.has('autostart')) {
  startCamera();
}
cameraSelect.addEventListener('change', () => startCamera(cameraSelect.value));
document.querySelector('#fullscreenButton').addEventListener('click', toggleFullscreen);
document.querySelector('#resetButton').addEventListener('click', resetSettings);
document.querySelector('#hideButton').addEventListener('click', () => toggleControls(false));
document.querySelector('#showButton').addEventListener('click', () => toggleControls(true));
output.addEventListener('dblclick', toggleFullscreen);

for (const [name, input] of Object.entries(inputs)) {
  input.addEventListener('input', () => {
    updateLabels();
    if (name === 'columns') invalidateGrid();
  });
}

document.addEventListener('keydown', (event) => {
  if (event.target instanceof HTMLInputElement || event.target instanceof HTMLSelectElement) return;
  const key = event.key.toLowerCase();
  if (key === 'h') toggleControls();
  if (key === 'f') toggleFullscreen();
  if (key === 'm') inputs.mirror.click();
  if (key === 'i') inputs.invert.click();
  if (key === '[' || key === ']') {
    const delta = key === '[' ? -2 : 2;
    inputs.columns.value = String(Math.max(48, Math.min(240, Number(inputs.columns.value) + delta)));
    inputs.columns.dispatchEvent(new Event('input'));
  }
});

navigator.mediaDevices?.addEventListener?.('devicechange', async () => {
  if (cameraLabelsAvailable) await enumerateCameras();
});

window.addEventListener('beforeunload', stopCurrentStream);

buildGlyphDatabase();
updateLabels();
outputCtx.fillStyle = '#000';
outputCtx.fillRect(0, 0, output.width, output.height);
