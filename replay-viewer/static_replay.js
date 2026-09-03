(function () {
  'use strict';

  // Lantern static replay shell. Forked from paintbot's
  // replay-viewer/static_replay.js: the OffscreenCanvas-Worker shell, the
  // createCore / start / stop / advance / resize / transform-and-minimap
  // message protocol with static_replay_worker.js, the
  // `data-replay-loaded` and `data-replay-mismatch-tick` attributes and
  // showFailure are all carried across.
  //
  // Two changes. The loader hands the JSON replay to the wasm module rather
  // than the binary one, and BULLWHIP'S `coworld-replay` postMessage BRIDGE
  // is added: an embedding page (the softmax.com theater, the Observatory
  // episode page) can only see this document's `load` event, which fires long
  // before the wasm module has compiled and the replay has come back from S3.
  // So the shell tells the parent what it is doing: `loading` as soon as this
  // script runs, `ready` once the renderer has drawn its first frame, `error`
  // when the replay cannot be shown, and in between the `phase` marks the
  // Worker reports (bundle_ready, replay_fetch_start, replay_fetch_end with
  // the byte count and the gzip/zlib sniff, replay_parsed). A Worker cannot
  // reach window.parent, so the marks are relayed from here; the host stamps
  // them with its own clock on receipt, so they carry no timestamp.
  function tell(type, message, fields) {
    if (window.parent === window) return;
    var envelope = Object.assign({ src: 'coworld-replay', type: type }, fields);
    if (message) envelope.message = message;
    try { window.parent.postMessage(envelope, '*'); } catch (ignore) {}
  }
  tell('loading');

  var failed = false;
  var scriptUrl = document.currentScript && document.currentScript.src;
  var workerUrl = new URL('./static_replay_worker.js', scriptUrl || location.href);

  function showFailure(error) {
    // First failure wins: an OOM abort reports once from the Worker (with the
    // stage note), then may also surface as an error event. Keep the specific
    // diagnostic instead of overwriting it with the generic one.
    if (failed) return;
    failed = true;
    console.error(error);
    var message = (error && error.message) || String(error);
    var status = document.getElementById('status');
    if (status) {
      status.textContent = 'Replay failed: ' + message;
      status.classList.add('show');
      var retry = document.createElement('button');
      retry.id = 'loading-retry';
      retry.type = 'button';
      retry.textContent = 'Retry';
      retry.onclick = function () { location.reload(); };
      status.appendChild(retry);
    }
    document.documentElement.setAttribute('data-replay-error', message);
    tell('error', message);
  }

  function setMismatchTick(tick) {
    if (tick >= 0) {
      document.documentElement.setAttribute(
        'data-replay-mismatch-tick', String(tick));
    }
  }

  function createCore(config) {
    var canvas = config.canvas;
    var worker = null;
    var started = false;
    var loaded = false;
    var advanceInFlight = false;
    var lastFrame = 0;
    var accumulator = 0;
    var frameMs = 1000 / 24;
    var workerDraws = 0;
    var readyTold = false;
    var transform = {
      scale: 1, offsetX: 0, offsetY: 0, nativeW: 1, nativeH: 1,
      zoom: 1, minZoom: 1, maxZoom: 12, fitScale: 1,
      focusX: 0, focusY: 0, visW: 1, visH: 1
    };
    var viewport = { width: 1, height: 1, dpr: window.devicePixelRatio || 1 };
    var offscreen;
    var pendingMinimap = null;
    var minimapSent = false;

    // transferControlToOffscreen is one-way and one-shot: the canvas is dead
    // to the main thread afterwards, so this must happen exactly once, and
    // only once the Worker exists to receive it.
    function sendMinimap() {
      if (!worker || !pendingMinimap || minimapSent) return;
      try {
        minimapSent = true;
        var surface = pendingMinimap;
        pendingMinimap = null;
        worker.postMessage({ type: 'minimap', canvas: surface }, [surface]);
      } catch (error) {
        console.warn('Minimap unavailable', error);
        pendingMinimap = null;
      }
    }

    if (!canvas || typeof canvas.transferControlToOffscreen !== 'function') {
      showFailure(new Error('This browser does not support OffscreenCanvas Workers'));
    } else {
      try {
        offscreen = canvas.transferControlToOffscreen();
      } catch (error) {
        showFailure(error);
      }
    }

    function readViewport() {
      var rect = canvas.getBoundingClientRect();
      viewport = {
        width: Math.max(1, rect.width || canvas.clientWidth || 1),
        height: Math.max(1, rect.height || canvas.clientHeight || 1),
        dpr: window.devicePixelRatio || 1
      };
      return viewport;
    }

    function postViewport() {
      readViewport();
      if (worker && started) {
        worker.postMessage({
          type: 'resize', width: viewport.width,
          height: viewport.height, dpr: viewport.dpr
        });
      }
    }

    function animate(now) {
      if (failed || !loaded || !worker) return;
      if (!lastFrame) lastFrame = now;
      accumulator = Math.min(accumulator + Math.min(now - lastFrame, 250), 250);
      lastFrame = now;
      if (!advanceInFlight && accumulator >= frameMs) {
        var frames = Math.min(6, Math.floor(accumulator / frameMs));
        accumulator -= frames * frameMs;
        advanceInFlight = true;
        worker.postMessage({ type: 'advance', frames: frames });
      }
      requestAnimationFrame(animate);
    }

    function onWorkerMessage(event) {
      if (failed) return;
      var message = event.data || {};
      try {
        if (message.type === 'text') {
          if (config.onText) config.onText(message.text);
          if (!readyTold) {
            readyTold = true;
            // Yield once after the first drawn frame. Animation frames may be
            // throttled indefinitely in lazy offscreen iframes.
            window.setTimeout(function () { tell('ready'); }, 0);
          }
        } else if (message.type === 'phase') {
          tell('phase', null, message);
        } else if (message.type === 'meta') {
          if (config.onMeta) config.onMeta(message.text);
        } else if (message.type === 'status') {
          if (config.onStatus) config.onStatus(message.status);
        } else if (message.type === 'firstFrame') {
          if (config.onFirstFrame) config.onFirstFrame();
        } else if (message.type === 'transform') {
          transform = message.transform;
          if (config.onTransform) config.onTransform(transform);
        } else if (message.type === 'loaded') {
          setMismatchTick(message.mismatchTick);
          loaded = true;
          document.documentElement.setAttribute('data-replay-loaded', 'true');
          requestAnimationFrame(animate);
        } else if (message.type === 'advanced') {
          setMismatchTick(message.mismatchTick);
          advanceInFlight = false;
          if (typeof message.draws === 'number') workerDraws = message.draws;
        } else if (message.type === 'error') {
          showFailure(new Error(message.message || 'Replay Worker failed'));
          stop();
        }
      } catch (error) {
        showFailure(error);
      }
    }

    function start() {
      if (started || !offscreen || failed) return;
      started = true;
      // `#replay=` first (the fragment is not sent in the HTTP request, so
      // the hosted index.html cache key does not vary per episode), then the
      // legacy `?replay=` query that local viewers still open with.
      var replayUrl = new URLSearchParams(location.hash.slice(1)).get('replay') ||
        new URLSearchParams(location.search).get('replay');
      if (!replayUrl) {
        showFailure(new Error('Missing required replay URL'));
        return;
      }
      readViewport();
      if (config.onStatus) config.onStatus('loading replay');
      try {
        worker = new Worker(workerUrl, { name: 'lantern-static-replay' });
        worker.onmessage = onWorkerMessage;
        worker.onerror = function (event) {
          showFailure(new Error(event.message || 'Replay Worker crashed'));
          stop();
        };
        worker.onmessageerror = function () {
          showFailure(new Error('Replay Worker sent an unreadable message'));
          stop();
        };
        worker.postMessage({
          type: 'init', replayUrl: replayUrl, canvas: offscreen,
          width: viewport.width, height: viewport.height, dpr: viewport.dpr
        }, [offscreen]);
        sendMinimap();
        document.documentElement.setAttribute('data-replay-worker', 'true');
      } catch (error) {
        showFailure(error);
      }
    }

    function stop() {
      if (!worker) return;
      worker.postMessage({ type: 'dispose' });
      worker.terminate();
      worker = null;
    }

    window.addEventListener('pagehide', stop, { once: true });

    return {
      start: start,
      stop: stop,
      sendCommand: function (text) {
        if (worker) worker.postMessage({ type: 'command', text: text });
      },
      clickMap: function (mapX, mapY) {
        if (worker) worker.postMessage({ type: 'click', x: mapX, y: mapY });
      },
      zoomAt: function (factor, x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'zoom', factor: factor, x: x, y: y });
      },
      setZoom: function (level, x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'setZoom', level: level, x: x, y: y });
      },
      panBy: function (dx, dy) {
        if (worker) worker.postMessage({ type: 'view', action: 'pan', dx: dx, dy: dy });
      },
      panByMap: function (dx, dy) {
        if (worker) worker.postMessage({ type: 'view', action: 'panMap', dx: dx, dy: dy });
      },
      panTo: function (x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'panTo', x: x, y: y });
      },
      resetView: function () {
        if (worker) worker.postMessage({ type: 'view', action: 'reset' });
      },
      attachMinimap: function (surface) {
        pendingMinimap = surface || null;
        sendMinimap();
      },
      getTransform: function () { return transform; },
      setViewportFit: postViewport,
      getPaceStats: function () {
        return {
          enabled: false, queued: 0, presented: 0,
          interval: frameMs, draws: workerDraws
        };
      }
    };
  }

  window.LanternStaticReplay = { createCore: createCore, tell: tell };
})();
