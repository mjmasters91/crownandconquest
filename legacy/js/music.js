/**
 * Original background music for Crown & Conquest.
 * Generated in the browser with the Web Audio API: a D-dorian lute line,
 * a soft drone, and a quiet frame drum. Nothing here is a recording.
 */

const KEY = "crown_music_v1";
const DEFAULT_VOLUME = 0.35;

const STEP = 0.34;
const LOOP = 32;
const D4 = 293.66;

let ctx = null;
let master = null;
let noise = null;
let timer = 0;
let nextAt = 0;
let step = 0;
let started = false;

const settings = loadSettings();

const MELODY = [
  0, 3, 5, 7, 10, 7, 5, 3,
  2, 3, 5, 7, 5, 2, 0, null,
  7, 5, 3, 5, 7, 10, 12, 10,
  7, 5, 3, 2, 0, null, null, null,
];

function loadSettings() {
  try {
    const raw = JSON.parse(localStorage.getItem(KEY) || "null");
    if (!raw || typeof raw !== "object") return { muted: false, volume: DEFAULT_VOLUME };
    const volume = Number(raw.volume);
    return {
      muted: Boolean(raw.muted),
      volume: Number.isFinite(volume) ? clamp(volume, 0, 1) : DEFAULT_VOLUME,
    };
  } catch {
    return { muted: false, volume: DEFAULT_VOLUME };
  }
}

function saveSettings() {
  localStorage.setItem(KEY, JSON.stringify(settings));
}

function clamp(n, min, max) {
  return Math.min(max, Math.max(min, n));
}

function semi(interval) {
  return D4 * 2 ** (interval / 12);
}

export function musicState() {
  return { muted: settings.muted, volume: settings.volume, started };
}

export function setMuted(muted) {
  settings.muted = Boolean(muted);
  saveSettings();
  applyGain();
}

export function setVolume(volume) {
  settings.volume = clamp(Number(volume) || 0, 0, 1);
  saveSettings();
  applyGain();
}

function applyGain() {
  if (!ctx || !master) return;
  const level = settings.muted ? 0 : settings.volume;
  master.gain.cancelScheduledValues(ctx.currentTime);
  master.gain.setTargetAtTime(level, ctx.currentTime, 0.04);
}

function pluck(time, freq, dur, level) {
  const osc = ctx.createOscillator();
  const filter = ctx.createBiquadFilter();
  const gain = ctx.createGain();
  osc.type = "triangle";
  osc.frequency.setValueAtTime(freq, time);
  filter.type = "lowpass";
  filter.frequency.setValueAtTime(1400, time);
  filter.frequency.exponentialRampToValueAtTime(420, time + dur);
  gain.gain.setValueAtTime(0.0001, time);
  gain.gain.exponentialRampToValueAtTime(level, time + 0.018);
  gain.gain.exponentialRampToValueAtTime(0.0001, time + dur);
  osc.connect(filter);
  filter.connect(gain);
  gain.connect(master);
  osc.start(time);
  osc.stop(time + dur + 0.05);
}

function tap(time, level) {
  const src = ctx.createBufferSource();
  const filter = ctx.createBiquadFilter();
  const gain = ctx.createGain();
  src.buffer = noise;
  filter.type = "bandpass";
  filter.frequency.setValueAtTime(180, time);
  filter.Q.value = 0.7;
  gain.gain.setValueAtTime(level, time);
  gain.gain.exponentialRampToValueAtTime(0.0001, time + 0.18);
  src.connect(filter);
  filter.connect(gain);
  gain.connect(master);
  src.start(time);
  src.stop(time + 0.2);
}

function schedule(time, index) {
  const degree = MELODY[index];
  if (degree != null) pluck(time, semi(degree), 0.55, 0.07);
  if (index % 4 === 0) {
    pluck(time, semi(-12), 0.9, 0.035);
    pluck(time + 0.08, semi(-7), 0.7, 0.025);
  }
  if (index % 8 === 0) tap(time, index % 16 === 0 ? 0.05 : 0.028);
}

function pump() {
  if (!ctx) return;
  const horizon = ctx.currentTime + 0.3;
  while (nextAt < horizon) {
    schedule(nextAt, step % LOOP);
    nextAt += STEP;
    step += 1;
  }
}

function startDrone() {
  for (const [freq, level] of [[73.42, 0.03], [110, 0.018]]) {
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = "sine";
    osc.frequency.value = freq;
    gain.gain.value = level;
    osc.connect(gain);
    gain.connect(master);
    osc.start();
  }
}

export function armMusic() {
  if (started) return;
  const AudioCtx = window.AudioContext || window.webkitAudioContext;
  if (!AudioCtx) return;
  started = true;
  ctx = new AudioCtx();
  master = ctx.createGain();
  master.gain.value = settings.muted ? 0 : settings.volume;
  master.connect(ctx.destination);
  const len = Math.floor(ctx.sampleRate * 0.2);
  noise = ctx.createBuffer(1, len, ctx.sampleRate);
  const data = noise.getChannelData(0);
  for (let i = 0; i < len; i += 1) data[i] = Math.random() * 2 - 1;
  startDrone();
  nextAt = ctx.currentTime + 0.08;
  pump();
  timer = window.setInterval(pump, 90);
  ctx.resume?.();
}
