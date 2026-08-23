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
async function smokeWorkerBootstrap() {
  const vm = require('vm');
  const workerPath = fs.existsSync(path.join(distDir, 'static_replay_worker.js'))
    ? path.join(distDir, 'static_replay_worker.js')
    : path.join(__dirname, '..', 'replay-viewer', 'static_replay_worker.js');
  const posted = [];
  const sandbox = {
    console, TextDecoder, TextEncoder, WebAssembly, URL, JSON, Math, Date,
    setTimeout, clearTimeout, fetch, AbortController, Promise,
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
      const file = path.join(distDir, name.replace(/^\.\//, ''));
      if (!fs.existsSync(file)) fail('worker importScripts: no ' + file);
      vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
    }
  };
  vm.runInContext(fs.readFileSync(workerPath, 'utf8'), sandbox,
    { filename: workerPath });

  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    const errorPost = posted.find((m) => m && m.type === 'error');
    if (errorPost) fail('worker bootstrap reported: ' + errorPost.message);
    if (sandbox.runtimeReady === true &&
        typeof sandbox.Module._lt_load_replay === 'function') {
      console.log('  worker bootstrap OK: onRuntimeInitialized fired, ' +
        'lt_load_replay reachable through the worker\'s Module');
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

(async function main() {
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

  console.log('wasm viewer smoke OK: ' + tickCount + ' ticks, ' +
    meta.events.length + ' events, ' + bursts +
    ' find bursts, digests all matched');
})().catch((error) => fail(error && error.stack || String(error)));
