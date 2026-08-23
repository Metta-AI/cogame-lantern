'use strict';

// Lantern static replay Worker. Forked from paintbot's
// replay-viewer/static_replay_worker.js: same message protocol, same
// OffscreenCanvas core, same ABORTING_MALLOC stage note, same bounded fetch.
//
// The playback state (paused / speed / loop / timelapse over the build acts)
// lives HERE rather than in the wasm module, because it is presentation, not
// simulation: the wasm module only ever answers "give me tick N".

// broadcast_core.js is shared with the native client and publishes through
// `window`. A classic Worker can provide that alias without a second bundle.
self.window = self;

var FETCH_TIMEOUT_MS = 20000;
// The wasm runtime is the one step with no failure path of its own: a glue
// that never instantiates, a .wasm that 404s, a compile that is killed --
// none of them raise, they just never call onRuntimeInitialized, and the
// page sits on "loading replay" until the tab dies. Bound it, and report the
// same error envelope every other failure uses so the shell shows an error.
var RUNTIME_TIMEOUT_MS = 30000;
var SPEEDS = [1, 2, 3, 4, 8, 16];

var Module = {};
var runtimeReady = false;
var initMessage = null;
var runtimeLoaded = false;
var core = null;
var minimapSurface = null;
var failed = false;
var disposed = false;
var meta = null;

var play = {
  paused: false,
  speed: 1,
  loop: false,
  skipLulls: true,      // the build acts run as a timelapse by default
  timelapse: false,
  holdUntil: 0,         // wall-clock ms: the find hold and the intermission
  heldTick: -1          // the tick the current hold was armed on
};

function stageNote() {
  try {
    var length = Module._lt_stage_len ? Module._lt_stage_len() : 0;
    if (!length) return '';
    var pointer = Module._lt_stage_ptr();
    return new TextDecoder().decode(Module.HEAPU8.slice(pointer, pointer + length));
  } catch (ignored) {
    return '';
  }
}

function runtimeError() {
  var length = Module._lt_error_len();
  if (!length) {
    var stage = stageNote();
    return stage ? 'Replay runtime failed while: ' + stage
                 : 'Replay runtime rejected the replay';
  }
  var pointer = Module._lt_error_ptr();
  return new TextDecoder().decode(Module.HEAPU8.slice(pointer, pointer + length));
}

function reportFailure(error) {
  if (failed || disposed) return;
  failed = true;
  // The runtime watchdog has nothing left to say once a failure is out; the
  // shell keeps the FIRST failure anyway (showFailure is first-wins).
  clearTimeout(runtimeTimer);
  postMessage({
    type: 'error',
    message: error && error.message ? error.message : String(error),
    stage: stageNote()
  });
}

function readString(pointerFn, lengthFn) {
  var length = lengthFn();
  if (!length) return '';
  var pointer = pointerFn();
  return new TextDecoder().decode(Module.HEAPU8.slice(pointer, pointer + length));
}

function copyIntoRuntime(bytes, callback) {
  var pointer = Module._malloc(bytes.length);
  try {
    Module.HEAPU8.set(bytes, pointer);
    return callback(pointer, bytes.length);
  } finally {
    Module._free(pointer);
  }
}

function inTimelapse(tick) {
  if (!play.skipLulls || !meta || !meta.timelapse_spans) return false;
  for (var i = 0; i < meta.timelapse_spans.length; i++) {
    var span = meta.timelapse_spans[i];
    if (tick >= span[0] && tick <= span[1]) return true;
  }
  return false;
}

function ingestPacket() {
  var text = readString(Module._lt_packet_ptr, Module._lt_packet_len);
  if (!text) throw new Error('Replay runtime produced an empty frame');
  var packet = JSON.parse(text);
  packet.paused = play.paused;
  packet.speed = play.speed;
  packet.loop = play.loop;
  packet.skipLulls = play.skipLulls;
  packet.timelapse = play.timelapse;
  packet.tick_count = meta ? meta.tick_count : 0;
  // A find, and the half-time swap, are worth holding the playhead on - ONCE
  // per tick. The flags stay in the module's packet buffer for as long as the
  // playhead sits on that tick, and advance() re-reads the packet on every
  // call during the hold; arming from each read would renew the hold 24
  // times a second and the replay would never move again (it did: every
  // replay froze on its first find and at half time).
  var tick = Module._lt_tick();
  if (tick !== play.heldTick) {
    if (packet.bursts && packet.bursts.length) {
      play.holdUntil = Date.now() + 400; play.heldTick = tick;
    }
    if (packet.intermission) {
      play.holdUntil = Date.now() + 2000; play.heldTick = tick;
    }
  }
  core.ingest(JSON.stringify(packet));
}

function createCore(message) {
  core = self.BroadcastCore.create({
    canvas: message.canvas,
    viewportWidth: message.width,
    viewportHeight: message.height,
    devicePixelRatio: message.dpr,
    onText: function (text) { postMessage({ type: 'text', text: text }); },
    onMeta: function (text) { postMessage({ type: 'meta', text: text }); },
    onStatus: function (status) { postMessage({ type: 'status', status: status }); },
    onFirstFrame: function () { postMessage({ type: 'firstFrame' }); },
    onTransform: function (transform) {
      postMessage({ type: 'transform', transform: transform });
    }
  });
  if (minimapSurface) core.attachMinimap(minimapSurface);
  core.start();
}

async function fetchReplay(url) {
  // AbortController bounds the wait: a fetch that never answers (a dead CDN
  // edge, a proxy holding the socket) is otherwise indistinguishable from a
  // slow one, and the page would say LOADING until the tab died.
  var controller = typeof AbortController === 'function' ? new AbortController() : null;
  var timer = setTimeout(function () { if (controller) controller.abort(); },
                         FETCH_TIMEOUT_MS);
  try {
    var response = await fetch(url, {
      credentials: 'omit', mode: 'cors',
      signal: controller ? controller.signal : undefined
    });
    if (!response.ok) throw new Error('Replay request returned HTTP ' + response.status);
    var bytes = new Uint8Array(await response.arrayBuffer());
    if (!bytes.length) throw new Error('Replay response was empty');
    return bytes;
  } catch (error) {
    if (error && error.name === 'AbortError') {
      throw new Error('replay fetch timed out after ' +
        Math.round(FETCH_TIMEOUT_MS / 1000) + 's');
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

async function start() {
  if (!runtimeReady || !initMessage || runtimeLoaded || failed || disposed) return;
  var message = initMessage;
  initMessage = null;
  try {
    createCore(message);
    var bytes = await fetchReplay(message.replayUrl);
    var loaded = copyIntoRuntime(bytes, function (pointer, length) {
      return Module._lt_load_replay(pointer, length);
    });
    if (!loaded) throw new Error(runtimeError());
    runtimeLoaded = true;
    var metaText = readString(Module._lt_meta_ptr, Module._lt_meta_len);
    meta = JSON.parse(metaText);
    core.ingest(metaText);
    ingestPacket();
    postMessage({ type: 'loaded', mismatchTick: Module._lt_mismatch_tick() });
  } catch (error) {
    reportFailure(error);
  }
}

function advance(frames) {
  if (!runtimeLoaded || failed || disposed) return;
  try {
    var now = Date.now();
    var tick = Module._lt_tick();
    play.timelapse = inTimelapse(tick);
    var multiplier = play.speed * (play.timelapse ? 4 : 1);
    var count = play.paused || now < play.holdUntil
      ? 0
      : Math.max(1, Math.min(64, Math.round((Number(frames) || 1) * multiplier)));
    for (var i = 0; i < count; i++) {
      if (Module._lt_tick() >= meta.tick_count) {
        if (!play.loop) { play.paused = true; break; }
        if (Module._lt_seek(0) < 0) throw new Error(runtimeError());
        continue;
      }
      if (Module._lt_frame() < 0) throw new Error(runtimeError());
    }
    ingestPacket();
    postMessage({
      type: 'advanced',
      mismatchTick: Module._lt_mismatch_tick(),
      draws: core ? core.getPaceStats().draws : 0
    });
  } catch (error) {
    reportFailure(error);
  }
}

function command(text) {
  if (!runtimeLoaded) return;
  try {
    if (text === ' ') play.paused = !play.paused;
    else if (text === ',') Module._lt_seek(0);
    else if (text === 'b') Module._lt_seek(Math.max(0, Module._lt_tick() - 1));
    else if (text === '.') Module._lt_seek(Module._lt_tick() + 5 * 24);
    else if (text === 'e') Module._lt_seek(meta.tick_count);
    else if (text === 'r') play.loop = !play.loop;
    else if (text === 'f') play.skipLulls = !play.skipLulls;
    else if (text.indexOf('s:') === 0) Module._lt_seek(parseInt(text.slice(2), 10) || 0);
    else if (/^[1-9]$/.test(text)) play.speed = SPEEDS[Number(text) - 1] || 1;
    ingestPacket();
  } catch (error) {
    reportFailure(error);
  }
}

Module.locateFile = function (path) {
  return new URL(path, self.location.href).toString();
};
Module.onAbort = function (what) {
  var stage = stageNote();
  reportFailure(new Error('Replay runtime ran out of memory (' + what +
    ') - wasm32 is limited to 2 GB' + (stage ? '. Failed while: ' + stage : '')));
};
var runtimeTimer = setTimeout(function () {
  if (runtimeReady) return;
  reportFailure(new Error('wasm runtime did not initialize in ' +
    Math.round(RUNTIME_TIMEOUT_MS / 1000) + 's'));
}, RUNTIME_TIMEOUT_MS);

Module.onRuntimeInitialized = function () {
  runtimeReady = true;
  clearTimeout(runtimeTimer);
  start();
};
self.Module = Module;

// lantern_replay.js is built with -s MODULARIZE=1 (config.nims), so unlike
// paintbot's glue it does NOT run on import: it only defines the
// `LanternReplayModule` factory and waits to be called. Forgetting this call
// is a silent hang, not an error - onRuntimeInitialized never fires, start()
// never runs, the replay is never fetched, and the page says "loading
// replay" forever. tools/wasm_replay_smoke.cjs boots this script the way a
// Worker does and asserts the runtime actually comes up.
function bootRuntime() {
  if (typeof self.LanternReplayModule !== 'function') {
    reportFailure(new Error('lantern_replay.js did not define LanternReplayModule'));
    return;
  }
  self.LanternReplayModule(Module).catch(reportFailure);
}

self.onmessage = function (event) {
  var message = event.data || {};
  try {
    if (message.type === 'init') {
      initMessage = message;
      start();
    } else if (message.type === 'advance') {
      advance(message.frames);
    } else if (message.type === 'command') {
      command(message.text || '');
    } else if (message.type === 'click' && core) {
      core.clickMap(Number(message.x) || 0, Number(message.y) || 0);
    } else if (message.type === 'resize' && core) {
      core.setViewportSize(message.width, message.height, message.dpr);
    } else if (message.type === 'view' && core) {
      if (message.action === 'zoom') core.zoomAt(message.factor, message.x, message.y);
      else if (message.action === 'setZoom') core.setZoom(message.level, message.x, message.y);
      else if (message.action === 'pan') core.panBy(message.dx, message.dy);
      else if (message.action === 'panMap') core.panByMap(message.dx, message.dy);
      else if (message.action === 'panTo') core.panTo(message.x, message.y);
      else if (message.action === 'reset') core.resetView();
    } else if (message.type === 'minimap') {
      minimapSurface = message.canvas || null;
      if (core && minimapSurface) core.attachMinimap(minimapSurface);
    } else if (message.type === 'dispose') {
      disposed = true;
      if (core) core.stop();
      close();
    }
  } catch (error) {
    reportFailure(error);
  }
};

importScripts('./wire_constants.js', './broadcast_core.js', './lantern_replay.js');
bootRuntime();
