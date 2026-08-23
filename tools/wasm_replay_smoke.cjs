#!/usr/bin/env node
'use strict';
// Headless wasm viewer smoke. Loads replay-viewer/dist/lantern_replay.js in
// node, feeds it a replay recorded by the real sim, and asserts that the
// module re-derives the episode exactly:
//
//   * the tick total matches the recorded tick_count;
//   * every keyframe digest matched (lt_mismatch_tick() is -1);
//   * seek-to-mid and seek-to-end land on EXACTLY the requested tick;
//   * a rewind reproduces the same frame packet as the forward pass;
//   * one find burst reaches the renderer for every `found` event;
//   * malformed inputs (bad protocol, bad base64 length, truncated JSON,
//     tick_count/payload mismatch) are all REJECTED WITH A MESSAGE rather
//     than crashing the module.
//
//   node tools/wasm_replay_smoke.cjs [dist-dir] [replay.json]
//
// Forked from paintbot's tools/wasm_replay_smoke.cjs.

const fs = require('fs');
const path = require('path');

const distDir = process.argv[2] ||
  path.join(__dirname, '..', 'replay-viewer', 'dist');
const replayPath = process.argv[3] ||
  path.join(__dirname, '..', 'tests', 'fixtures', 'smoke_replay.json');

function fail(message) {
  console.error('wasm viewer smoke FAILED: ' + message);
  process.exit(1);
}

function readString(module, pointerFn, lengthFn) {
  const length = lengthFn();
  if (!length) return '';
  const pointer = pointerFn();
  return Buffer.from(module.HEAPU8.subarray(pointer, pointer + length))
    .toString('utf8');
}

function packetOf(module) {
  return JSON.parse(readString(module, module._lt_packet_ptr,
    module._lt_packet_len));
}

function packetWithoutBursts(module) {
  // `bursts` is the one field that is per-tick-edge rather than per-tick: a
  // scrub deliberately drops it, so it plays no part in "the rewind matches".
  const packet = packetOf(module);
  delete packet.bursts;
  return JSON.stringify(packet);
}

function loadBytes(module, bytes) {
  const pointer = module._malloc(bytes.length);
  try {
    module.HEAPU8.set(bytes, pointer);
    return module._lt_load_replay(pointer, bytes.length);
  } finally {
    module._free(pointer);
  }
}

// Boot replay-viewer/static_replay_worker.js the way a dedicated Worker does:
// a global scope that IS `self`, importScripts() evaluating each file into
// that scope, postMessage() captured. This is the path the browser actually
// takes, and it is not the same as `require(lantern_replay.js)()` above: the
// glue is MODULARIZE=1, so it only defines a factory, and the worker has to
// call it. The original bootstrap never did - the runtime never came up and
// the page said "loading replay" forever - and this harness, which called the
// factory itself, stayed green through it.
function workerSource() {
  return fs.existsSync(path.join(distDir, 'static_replay_worker.js'))
    ? path.join(distDir, 'static_replay_worker.js')
    : path.join(__dirname, '..', 'replay-viewer', 'static_replay_worker.js');
}

// `stubGlue` replaces lantern_replay.js with a factory that never settles, so
// the runtime watchdog can be exercised; `fastForward` collapses the long
// timeouts (the 30 s runtime watchdog) so that test costs milliseconds.
function bootWorker(options) {
  const settings = options || {};
  const vm = require('vm');
  const workerPath = workerSource();
  const posted = [];
  const pending = new Set();
  const sandbox = {
    console, TextDecoder, TextEncoder, WebAssembly, URL, JSON, Math, Date,
    fetch, AbortController, Promise,
    setTimeout: (fn, ms) => {
      const delay = settings.fastForward && ms > 1000 ? 5 : ms;
      const handle = setTimeout(() => { pending.delete(handle); fn(); }, delay);
      pending.add(handle);
      return handle;
    },
    clearTimeout: (handle) => { pending.delete(handle); clearTimeout(handle); },
    // The Node branch of the emscripten glue reads the wasm with fs, keyed
    // off these three; a real Worker would fetch() it instead.
    process, require, __filename: path.join(distDir, 'lantern_replay.js'),
    __dirname: distDir,
    location: { href: 'file://' + distDir + '/' },
    postMessage: (message) => posted.push(message),
    close: () => {},
  };
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  sandbox.importScripts = (...names) => {
    for (const name of names) {
      const leaf = name.replace(/^\.\//, '');
      if (settings.stubGlue && leaf === 'lantern_replay.js') {
        vm.runInContext(
          'self.LanternReplayModule = function () ' +
          '{ return new Promise(function () {}); };', sandbox,
          { filename: 'stub-' + leaf });
        continue;
      }
      const file = path.join(distDir, leaf);
      if (!fs.existsSync(file)) fail('worker importScripts: no ' + file);
      vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
    }
  };
  vm.runInContext(fs.readFileSync(workerPath, 'utf8'), sandbox,
    { filename: workerPath });
  return { sandbox, posted, pending };
}

async function smokeWorkerBootstrap() {
  const { sandbox, posted, pending } = bootWorker();

  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    const errorPost = posted.find((m) => m && m.type === 'error');
    if (errorPost) fail('worker bootstrap reported: ' + errorPost.message);
    if (sandbox.runtimeReady === true &&
        typeof sandbox.Module._lt_load_replay === 'function') {
      // A live watchdog left behind would fire 30 s into a HEALTHY replay and
      // replace the picture with an error, so the clear is part of the contract.
      if (pending.size !== 0) {
        fail('the runtime watchdog was not cleared once the runtime came up (' +
          pending.size + ' timer(s) still pending)');
      }
      console.log('  worker bootstrap OK: onRuntimeInitialized fired, ' +
        'lt_load_replay reachable through the worker\'s Module, ' +
        'runtime watchdog cleared');
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  fail('worker bootstrap never initialised the wasm runtime: ' +
    'static_replay_worker.js imported lantern_replay.js but the runtime ' +
    'never came up (runtimeReady=' + sandbox.runtimeReady + ', ' +
    'Module._lt_load_replay=' + typeof (sandbox.Module || {})._lt_load_replay +
    '). Is the MODULARIZE=1 factory being called?');
}

// A runtime that never comes up must SAY SO. Anything that leaves
// onRuntimeInitialized unfired - a 404 on the .wasm, a factory that rejects
// nothing and resolves never, a killed compile - is otherwise a silent hang:
// the theater's spinner spins until the tab dies. The worker bounds it and
// posts the same {type:'error'} envelope every other failure uses, which the
// shell turns into data-replay-error plus a coworld-replay `error` message.
async function smokeRuntimeWatchdog() {
  const { posted } = bootWorker({ stubGlue: true, fastForward: true });
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const errorPost = posted.find((m) => m && m.type === 'error');
    if (errorPost) {
      if (!/did not initialize/.test(errorPost.message || '')) {
        fail('the runtime watchdog fired with an unexpected message: ' +
          errorPost.message);
      }
      console.log('  runtime watchdog OK: ' + errorPost.message);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  fail('a runtime that never initialises produced NO error: the worker has no ' +
    'watchdog, so a dead wasm runtime hangs the page on "loading replay"');
}

// The board canvas is transferred to the Worker with whatever bitmap size the
// element had - <canvas id="board"> carries none, so 300x150 - and the core
// draws a full-viewport scene into it. Unless the core sizes the bitmap to the
// viewport it was CREATED with, the page stretches that 300x150 picture over
// the stage until the first `resize` message (fullscreen, a window resize)
// fixes it: the replay opens "zoomed in" and no zoom control can undo it,
// because none of them touch the bitmap. This is exactly what a fresh load
// looked like on softmax.com.
function smokeCanvasBitmapSize() {
  const vm = require('vm');
  const corePath = fs.existsSync(path.join(distDir, 'broadcast_core.js'))
    ? path.join(distDir, 'broadcast_core.js')
    : path.join(__dirname, '..', 'client', 'broadcast_core.js');
  const noop = () => {};
  const context = new Proxy({}, {
    get: (target, key) => (key in target ? target[key] : noop),
    set: (target, key, value) => { target[key] = value; return true; }
  });
  const canvas = { width: 300, height: 150, getContext: () => context };
  const sandbox = { console, Math, JSON };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(corePath, 'utf8'), sandbox, { filename: corePath });
  const core = sandbox.BroadcastCore.create({
    canvas, viewportWidth: 1700, viewportHeight: 907, devicePixelRatio: 2
  });
  core.start();
  if (canvas.width !== 3400 || canvas.height !== 1814) {
    fail('the board bitmap was not sized to the viewport the core was created ' +
      'with: got ' + canvas.width + 'x' + canvas.height + ', wanted 3400x1814 ' +
      '(1700x907 css px at dpr 2). The replay opens stretched/"zoomed in" ' +
      'until the first resize message.');
  }
  core.setViewportSize(800, 400, 1);
  if (canvas.width !== 800 || canvas.height !== 400) {
    fail('setViewportSize did not resize the bitmap: ' + canvas.width + 'x' + canvas.height);
  }
  // Exercise the lit-mask and light paths with a stub OffscreenCanvas, so a
  // helper that is referenced but not defined (it happened: a rebase dropped
  // scratchCanvas and every hosted replay showed "scratchCanvas is not
  // defined") throws HERE rather than in the browser.
  sandbox.OffscreenCanvas = function (w, h) {
    this.width = w; this.height = h;
    this.getContext = () => context;
  };
  context.createImageData = (w, h) => ({ data: new Uint8ClampedArray(w * h * 4) });
  context.getImageData = (x, y, w, h) => ({ data: new Uint8ClampedArray(w * h * 4) });
  context.createRadialGradient = () => ({ addColorStop: noop });
  context.createPattern = () => ({});
  try {
    core.ingest(JSON.stringify({ type: 'meta', map: { obstacles: [], pen: null },
      config: { lanternRangePx: 420, lanternConeBrads: 18 }, tick_count: 1 }));
    core.ingest(JSON.stringify({ type: 'frame', tick: 0, act: 'hunt', cogs: [
      { alias: 'Owl-1', team: 'Owl', role: 'seeker', x: 100, y: 100, aim: 0, state: 0 },
      { alias: 'Moth-1', team: 'Moth', role: 'hider', x: 300, y: 100, aim: 0, state: 0, lit: true }
    ], crates: [], sounds: [], hb: [], bursts: [] }));
    core.setLitMask(new Uint8Array(155 * 83).fill(1), 155, 83, 8);
  } catch (error) {
    fail('broadcast_core threw while drawing a lit frame: ' + error.message);
  }
  console.log('  board bitmap OK: sized to the viewport at create and on resize');
}

// The playhead holds on a find burst (400 ms) and on the half-time
// intermission (2 s). Both flags live in the wasm module's packet buffer for
// the tick they happen on, and advance() re-reads that packet on every call,
// including the calls it makes while the hold is still running. Arm the hold
// from every read and the replay never moves again: the burst re-arms it 24
// times a second, forever. Softmax.com showed exactly that - every lantern
// replay froze on its first find, and on half time. Drive the worker's own
// advance() across the fixture's find with a fake clock and insist the
// playhead comes out the other side.
async function smokeHoldReleases(replay) {
  const { sandbox, posted } = bootWorker();
  const deadline = Date.now() + 10000;
  while (!(sandbox.runtimeReady && typeof sandbox.Module._lt_load_replay === 'function')) {
    if (Date.now() > deadline) fail('hold smoke: runtime never came up');
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const Module = sandbox.Module;
  const bytes = Buffer.from(JSON.stringify(replay), 'utf8');
  if (!loadBytes(Module, bytes)) fail('hold smoke: module rejected the fixture');
  const found = replay.events.find((e) => e.type === 'found');
  if (!found) fail('hold smoke: the fixture has no found event');
  // Stand in for start(): the core is a sink, the clock is ours.
  sandbox.meta = { tick_count: replay.tick_count, timelapse_spans: [] };
  sandbox.core = { ingest: () => {}, getPaceStats: () => ({ draws: 0 }) };
  sandbox.runtimeLoaded = true;
  let now = 0;
  sandbox.Date = { now: () => now };
  const from = Math.max(0, found.t - 3);
  Module._lt_seek(from);
  // 24 fps for 6 wall seconds: a 400 ms hold is ~10 calls, a 2 s one ~48.
  let reached = -1;
  for (let call = 0; call < 144; call++) {
    now += 1000 / 24;
    sandbox.advance(1);
    const errorPost = posted.find((m) => m && m.type === 'error');
    if (errorPost) fail('hold smoke: worker reported ' + errorPost.message);
    if (Module._lt_tick() >= found.t + 12) { reached = call; break; }
  }
  if (reached < 0) {
    fail('the playhead never released its hold after the find at tick ' +
      found.t + ': stuck at tick ' + Module._lt_tick() + ' after 6 s. ' +
      'advance() re-arms holdUntil from a packet it already held on.');
  }
  console.log('  find hold OK: released after ' + reached + ' frames, playhead past tick ' +
    (found.t + 12));
}

// The lit mask is the sim's own occlusion, not a cone painted over the
// board: every seeker's own cell is lit (the omni bubble), and the first
// cell BEHIND a wall on a seeker's aim ray, inside lantern range, is dark.
function smokeLitMask(module, replay) {
  if (typeof module._lt_lit_ptr !== 'function') {
    fail('the module does not export lt_lit_ptr: the renderer has no occlusion');
  }
  const cols = module._lt_lit_cols(), rows = module._lt_lit_rows();
  const cell = module._lt_lit_cell();
  const mask = () => {
    const n = module._lt_lit_len();
    const p = module._lt_lit_ptr();
    return module.HEAPU8.subarray(p, p + n);
  };
  const meta = JSON.parse(readString(module, module._lt_meta_ptr, module._lt_meta_len));
  const walls = (meta.map && meta.map.obstacles) || [];
  const inWall = (x, y) => walls.some((w) =>
    x >= w.x && x < w.x + w.w && y >= w.y && y < w.y + w.h);
  const at = (x, y) => mask()[Math.floor(y / cell) * cols + Math.floor(x / cell)];
  const range = (meta.config && meta.config.lanternRangePx) || 420;

  // Build act: the lanterns are off and the mask is all dark.
  module._lt_seek(1);
  if (mask().some((v) => v)) fail('the lit mask is not dark during the build act');

  const hunt = replay.events.find((e) => e.type === 'act_start' && e.act === 'hunt');
  if (!hunt) fail('no hunt act_start in the fixture');
  module._lt_seek(hunt.t + 48);
  const packet = packetOf(module);
  const seekers = packet.cogs.filter((c) => c.role === 'seeker');
  if (!seekers.length) fail('no seekers in the hunt packet');
  let shadowed = 0;
  for (const cog of seekers) {
    if (!at(cog.x, cog.y)) {
      fail(`seeker ${cog.alias} at (${cog.x},${cog.y}) is not in its own lit set`);
    }
    // Walk the aim ray until it enters a wall, then one cell further.
    const heading = -cog.aim * Math.PI * 2 / 256;
    let hit = null;
    for (let d = 8; d < range; d += 2) {
      const x = Math.round(cog.x + Math.cos(heading) * d);
      const y = Math.round(cog.y + Math.sin(heading) * d);
      if (x < 0 || y < 0 || x >= meta.map.width || y >= meta.map.height) break;
      if (inWall(x, y)) { hit = { x, y, d }; break; }
    }
    if (!hit) continue;
    const d = hit.d + 2 * cell + 2;
    if (d >= range - cell) continue;
    const bx = Math.round(cog.x + Math.cos(heading) * d);
    const by = Math.round(cog.y + Math.sin(heading) * d);
    if (inWall(bx, by)) continue;
    if (at(bx, by)) {
      fail(`cell (${bx},${by}) behind the wall at (${hit.x},${hit.y}) on ` +
        `${cog.alias}'s aim ray is lit: the mask ignores occlusion`);
    }
    shadowed++;
  }
  console.log('  lit mask OK: ' + cols + 'x' + rows + ' cells of ' + cell +
    ' px, seekers lit at their own cell, ' + shadowed +
    ' wall shadow(s) on aim rays checked');
}

(async function main() {
  smokeCanvasBitmapSize();
  const modulePath = path.join(distDir, 'lantern_replay.js');
  if (!fs.existsSync(modulePath)) fail('no wasm module at ' + modulePath);
  if (!fs.existsSync(replayPath)) fail('no replay fixture at ' + replayPath);

  const factory = require(modulePath);
  const module = await factory();
  const replayText = fs.readFileSync(replayPath, 'utf8');
  const replay = JSON.parse(replayText);
  const bytes = Buffer.from(replayText, 'utf8');

  if (!loadBytes(module, bytes)) {
    fail('module rejected a good replay: ' +
      readString(module, module._lt_error_ptr, module._lt_error_len));
  }

  const tickCount = module._lt_tick_count();
  if (tickCount !== replay.tick_count) {
    fail(`tick_count mismatch: module ${tickCount}, replay ${replay.tick_count}`);
  }
  const mismatch = module._lt_mismatch_tick();
  if (mismatch !== -1) fail('keyframe digest mismatch at tick ' + mismatch);

  const meta = JSON.parse(readString(module, module._lt_meta_ptr, module._lt_meta_len));
  if (meta.protocol !== 'lantern.replay.v1') fail('bad meta protocol');
  if (!meta.events.length || !meta.results) fail('meta is missing events/results');
  smokeLitMask(module, replay);
  module._lt_seek(0);

  // Advance to the end one tick at a time, collecting the find bursts the
  // renderer draws its expanding ring on.
  let bursts = 0;
  while (module._lt_tick() < tickCount) {
    if (module._lt_frame() < 0) {
      fail('lt_frame failed: ' +
        readString(module, module._lt_error_ptr, module._lt_error_len));
    }
    const frame = packetOf(module);
    for (const burst of frame.bursts || []) {
      if (!Array.isArray(burst) || burst.length !== 2) {
        fail('a find burst is not an [x, y] pair: ' + JSON.stringify(burst));
      }
      bursts++;
    }
  }
  if (module._lt_tick() !== tickCount) fail('did not land on the final tick');
  const endPacket = packetWithoutBursts(module);

  const finds = replay.events.filter((e) => e.type === 'found').length;
  if (!finds) fail('the smoke fixture has no found event to burst on');
  if (bursts !== finds) {
    fail(`find bursts ${bursts} do not match the ${finds} found events`);
  }

  // Seek-to-mid and seek-to-end must land exactly, and a rewind must
  // reproduce the same frame the forward pass produced.
  const mid = Math.floor(tickCount / 2);
  if (module._lt_seek(mid) !== mid) fail('seek to mid did not land exactly');
  const midPacket = packetWithoutBursts(module);
  if (module._lt_seek(tickCount) !== tickCount) fail('seek to end did not land');
  if (packetWithoutBursts(module) !== endPacket) {
    fail('seek to end disagrees with the forward pass');
  }
  if (module._lt_seek(mid) !== mid) fail('rewind to mid did not land');
  if (packetWithoutBursts(module) !== midPacket) {
    fail('rewind to mid disagrees with the forward pass');
  }

  // Malformed inputs: rejected with a message, never a crash.
  const broken = [
    ['bad protocol', JSON.stringify(Object.assign({}, replay, { protocol: 'nope' }))],
    ['bad base64 length', JSON.stringify(Object.assign({}, replay,
      { controls_b64: replay.controls_b64.slice(0, 8) }))],
    ['tick_count mismatch', JSON.stringify(Object.assign({}, replay,
      { tick_count: replay.tick_count + 7 }))],
    ['truncated JSON', replayText.slice(0, Math.floor(replayText.length / 2))],
    ['empty', '']
  ];
  for (const [label, text] of broken) {
    const ok = loadBytes(module, Buffer.from(text, 'utf8'));
    if (ok) fail('module ACCEPTED a malformed replay: ' + label);
    const message = readString(module, module._lt_error_ptr, module._lt_error_len);
    if (!message) fail('no error message for the malformed case: ' + label);
    console.log('  rejected (' + label + '): ' + message.slice(0, 90));
  }

  await smokeWorkerBootstrap();
  await smokeRuntimeWatchdog();
  await smokeHoldReleases(replay);

  console.log('wasm viewer smoke OK: ' + tickCount + ' ticks, ' +
    meta.events.length + ' events, ' + bursts +
    ' find bursts, digests all matched');
})().catch((error) => fail(error && error.stack || String(error)));
