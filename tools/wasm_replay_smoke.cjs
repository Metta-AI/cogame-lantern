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

function loadBytes(module, bytes) {
  const pointer = module._malloc(bytes.length);
  try {
    module.HEAPU8.set(bytes, pointer);
    return module._lt_load_replay(pointer, bytes.length);
  } finally {
    module._free(pointer);
  }
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

  // Advance to the end one tick at a time.
  while (module._lt_tick() < tickCount) {
    if (module._lt_frame() < 0) {
      fail('lt_frame failed: ' +
        readString(module, module._lt_error_ptr, module._lt_error_len));
    }
  }
  if (module._lt_tick() !== tickCount) fail('did not land on the final tick');
  const endPacket = readString(module, module._lt_packet_ptr, module._lt_packet_len);

  // Seek-to-mid and seek-to-end must land exactly, and a rewind must
  // reproduce the same frame the forward pass produced.
  const mid = Math.floor(tickCount / 2);
  if (module._lt_seek(mid) !== mid) fail('seek to mid did not land exactly');
  const midPacket = readString(module, module._lt_packet_ptr, module._lt_packet_len);
  if (module._lt_seek(tickCount) !== tickCount) fail('seek to end did not land');
  if (readString(module, module._lt_packet_ptr, module._lt_packet_len) !== endPacket) {
    fail('seek to end disagrees with the forward pass');
  }
  if (module._lt_seek(mid) !== mid) fail('rewind to mid did not land');
  if (readString(module, module._lt_packet_ptr, module._lt_packet_len) !== midPacket) {
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

  console.log('wasm viewer smoke OK: ' + tickCount + ' ticks, ' +
    meta.events.length + ' events, digests all matched');
})().catch((error) => fail(error && error.stack || String(error)));
