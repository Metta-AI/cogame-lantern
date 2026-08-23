'use strict';
// broadcast_core.js — the lantern board renderer.
//
// Forked from paintbot's client/broadcast_core.js: same public shape
// (BroadcastCore.create -> {ingest, start, stop, setViewportSize, zoomAt,
// setZoom, panBy, panByMap, panTo, resetView, attachMinimap, getPaceStats,
// sendCommand, clickMap}) so replay-viewer/static_replay_worker.js can drive
// it from an OffscreenCanvas in a Worker exactly as CTF's does. What changed
// is what it DRAWS: there are no flags, no bullets and no paint here, there
// is a dark warehouse floor, ten crates, six cogs, three flashlight cones and
// the sound rings they make.
//
// The frame packets come from the wasm module (replay-viewer/lantern_replay.nim),
// which re-derives every tick from seed + map + controls_b64 with the same Nim
// sim the game server ran. The DOM chrome draws the scorebug, clocks, heartbeat
// bars, feed and transport; this file draws the world.
(function (root) {
  var MAP_W = 1235, MAP_H = 659;

  function create(config) {
    var canvas = config.canvas;
    var context = canvas.getContext('2d');
    var viewport = {
      width: config.viewportWidth || 960,
      height: config.viewportHeight || 540,
      dpr: config.devicePixelRatio || 1
    };
    var meta = null;
    var state = null;
    var draws = 0;
    var firstFrameSent = false;
    var zoom = 1, focusX = MAP_W / 2, focusY = MAP_H / 2;
    var minimap = null, minimapContext = null;
    var bursts = [];

    // ---- art ---------------------------------------------------------------
    // Real painted art (scripts/art/build_art.py), loaded once and blitted.
    // Everything degrades to the procedural chassis if a bitmap is missing, so
    // a stripped bundle still renders rather than throwing on every frame.
    var art = {};
    var floorPattern = null;
    var ART_BASE = (config.artBase || './art');
    function loadArt() {
      if (typeof fetch !== 'function' || typeof createImageBitmap !== 'function') return;
      ['floor.jpg', 'crate.png', 'crate_locked.png', 'crate_broken.png',
       'cog_moth.png', 'cog_owl.png'].forEach(function (name) {
        fetch(ART_BASE + '/' + name)
          .then(function (r) { return r.ok ? r.blob() : null; })
          .then(function (blob) { return blob ? createImageBitmap(blob) : null; })
          .then(function (bitmap) {
            if (!bitmap) return;
            art[name] = bitmap;
            if (name === 'floor.jpg') {
              floorPattern = context.createPattern(bitmap, 'repeat');
            }
            if (state) draw();
          })
          .catch(function () { /* procedural fallback */ });
      });
    }
    loadArt();

    function transform() {
      var fit = Math.min(viewport.width / MAP_W, viewport.height / MAP_H);
      var scale = fit * zoom;
      var visW = viewport.width / scale, visH = viewport.height / scale;
      focusX = Math.max(visW / 2, Math.min(MAP_W - visW / 2, focusX));
      focusY = Math.max(visH / 2, Math.min(MAP_H - visH / 2, focusY));
      if (visW >= MAP_W) focusX = MAP_W / 2;
      if (visH >= MAP_H) focusY = MAP_H / 2;
      return {
        scale: scale,
        offsetX: viewport.width / 2 - focusX * scale,
        offsetY: viewport.height / 2 - focusY * scale,
        nativeW: MAP_W, nativeH: MAP_H,
        zoom: zoom, minZoom: 1, maxZoom: 12, fitScale: fit,
        focusX: focusX, focusY: focusY, visW: visW, visH: visH
      };
    }

    function emitTransform() {
      if (config.onTransform) config.onTransform(transform());
    }

    function setViewportSize(width, height, dpr) {
      viewport.width = Math.max(1, width || viewport.width);
      viewport.height = Math.max(1, height || viewport.height);
      viewport.dpr = dpr || viewport.dpr;
      canvas.width = Math.round(viewport.width * viewport.dpr);
      canvas.height = Math.round(viewport.height * viewport.dpr);
      emitTransform();
      if (state) draw();
    }

    // ---- painting helpers --------------------------------------------------
    function withWorld(t, body) {
      context.save();
      context.setTransform(viewport.dpr, 0, 0, viewport.dpr, 0, 0);
      context.translate(t.offsetX, t.offsetY);
      context.scale(t.scale, t.scale);
      body();
      context.restore();
    }

    function drawFloor(t) {
      // Poured concrete: the painted tile when it is in, a subtle grid until
      // then so motion still reads on the very first frames.
      if (floorPattern) {
        context.fillStyle = floorPattern;
        context.fillRect(0, 0, MAP_W, MAP_H);
        return;
      }
      context.fillStyle = '#171310';
      context.fillRect(0, 0, MAP_W, MAP_H);
      context.strokeStyle = 'rgba(242, 232, 216, 0.045)';
      context.lineWidth = 1 / t.scale;
      for (var x = 0; x <= MAP_W; x += 64) {
        context.beginPath(); context.moveTo(x, 0); context.lineTo(x, MAP_H);
        context.stroke();
      }
      for (var y = 0; y <= MAP_H; y += 64) {
        context.beginPath(); context.moveTo(0, y); context.lineTo(MAP_W, y);
        context.stroke();
      }
    }

    function drawWalls() {
      if (!meta || !meta.map) return;
      var walls = meta.map.obstacles || [];
      for (var i = 0; i < walls.length; i++) {
        var w = walls[i];
        context.fillStyle = '#2c231b';
        context.fillRect(w.x, w.y, w.w, w.h);
        context.fillStyle = 'rgba(242, 232, 216, 0.10)';
        context.fillRect(w.x, w.y, w.w, 2);
      }
      var pen = meta.map.pen;
      if (pen) {
        context.strokeStyle = 'rgba(78, 205, 196, 0.35)';
        context.lineWidth = 2;
        context.strokeRect(pen.x, pen.y, pen.w, pen.h);
      }
    }

    function drawCrates() {
      if (!state) return;
      for (var i = 0; i < state.crates.length; i++) {
        var c = state.crates[i];
        var x = c[0] - 24, y = c[1] - 24;
        var sprite = art[c[2] === 1 ? 'crate_locked.png'
                       : c[2] === 2 ? 'crate_broken.png' : 'crate.png'];
        if (sprite) {
          context.drawImage(sprite, x, y, 48, 48);
          continue;
        }
        if (c[2] === 2) {
          // broken: splintered planks left on the floor
          context.strokeStyle = 'rgba(150, 118, 82, 0.55)';
          context.lineWidth = 3;
          context.beginPath();
          context.moveTo(x + 4, y + 10); context.lineTo(x + 42, y + 20);
          context.moveTo(x + 6, y + 34); context.lineTo(x + 40, y + 28);
          context.stroke();
          continue;
        }
        context.fillStyle = c[1] === 1 ? '#8a6a3c' : '#7b5c35';
        context.fillRect(x, y, 48, 48);
        context.strokeStyle = 'rgba(24, 17, 11, 0.85)';
        context.lineWidth = 2;
        context.strokeRect(x + 1, y + 1, 46, 46);
        context.strokeStyle = 'rgba(242, 232, 216, 0.16)';
        context.lineWidth = 2;
        context.beginPath();
        context.moveTo(x + 4, y + 16); context.lineTo(x + 44, y + 16);
        context.moveTo(x + 4, y + 32); context.lineTo(x + 44, y + 32);
        context.stroke();
        if (c[2] === 1) {
          // locked: four visible bolts
          context.fillStyle = '#d8c08a';
          [[8, 8], [40, 8], [8, 40], [40, 40]].forEach(function (p) {
            context.beginPath();
            context.arc(x + p[0], y + p[1], 3, 0, Math.PI * 2);
            context.fill();
          });
        }
      }
    }

    function coneFor(cog) {
      var range = (meta && meta.config && meta.config.lanternRangePx) || 420;
      var half = ((meta && meta.config && meta.config.lanternConeBrads) || 18) *
        Math.PI * 2 / 256;
      var heading = -cog.aim * Math.PI * 2 / 256;
      return { range: range, half: half, heading: heading };
    }

    function drawLight() {
      if (!state || state.act !== 'hunt') return;
      // The lit union is painted into a scratch layer with 'lighter' so
      // overlapping cones add rather than darken, then multiplied over the
      // board by #lightpool in the page. Here we paint the cones themselves.
      for (var i = 0; i < state.cogs.length; i++) {
        var cog = state.cogs[i];
        if (cog.role !== 'seeker') continue;
        var cone = coneFor(cog);
        var gradient = context.createRadialGradient(
          cog.x, cog.y, 8, cog.x, cog.y, cone.range);
        gradient.addColorStop(0, 'rgba(255, 246, 214, 0.42)');
        gradient.addColorStop(1, 'rgba(255, 246, 214, 0.0)');
        context.fillStyle = gradient;
        context.beginPath();
        context.moveTo(cog.x, cog.y);
        context.arc(cog.x, cog.y, cone.range,
                    cone.heading - cone.half, cone.heading + cone.half);
        context.closePath();
        context.fill();
        // hot core along the aim ray
        context.strokeStyle = 'rgba(255, 252, 240, 0.30)';
        context.lineWidth = 6;
        context.beginPath();
        context.moveTo(cog.x, cog.y);
        context.lineTo(cog.x + Math.cos(cone.heading) * cone.range,
                       cog.y + Math.sin(cone.heading) * cone.range);
        context.stroke();
        // the omni bubble
        context.strokeStyle = 'rgba(255, 246, 214, 0.16)';
        context.lineWidth = 2;
        context.beginPath();
        context.arc(cog.x, cog.y, 60, 0, Math.PI * 2);
        context.stroke();
      }
    }

    function drawSounds() {
      if (!state || !state.sounds) return;
      for (var i = 0; i < state.sounds.length; i++) {
        var ring = state.sounds[i];
        var age = ring.age_ticks / 24;
        var alpha = Math.max(0, 0.5 * (1 - age));
        context.strokeStyle = ring.kind === 'break'
          ? 'rgba(255, 255, 255, ' + alpha + ')'
          : 'rgba(232, 163, 61, ' + alpha + ')';
        context.lineWidth = ring.kind === 'break' ? 4 : 2;
        context.setLineDash(ring.kind === 'step' ? [8, 8] : []);
        context.beginPath();
        context.arc(ring.pos[0], ring.pos[1], ring.radius * (0.25 + age * 0.75),
                    0, Math.PI * 2);
        context.stroke();
        context.setLineDash([]);
      }
    }

    function drawCogs() {
      if (!state) return;
      for (var i = 0; i < state.cogs.length; i++) {
        var cog = state.cogs[i];
        if (cog.state === 3) continue;   // found: sitting in the caught pen
        var colour = cog.team === 'Moth' ? '#f2c14e' : '#4ecdc4';
        var lit = cog.role === 'seeker' || cog.lit || state.act === 'build';
        var rig = art[cog.team === 'Moth' ? 'cog_moth.png' : 'cog_owl.png'];
        if (rig) {
          context.save();
          context.globalAlpha = lit ? 1 : 0.3;
          context.translate(cog.x, cog.y);
          context.rotate(-cog.aim * Math.PI * 2 / 256);
          context.drawImage(rig, -18, -18, 36, 36);
          context.restore();
          if (!lit) {
            context.strokeStyle = colour;
            context.lineWidth = 1.5;
            context.beginPath();
            context.arc(cog.x, cog.y, 11, 0, Math.PI * 2);
            context.stroke();
          }
          context.fillStyle = 'rgba(242, 232, 216, ' + (lit ? 0.9 : 0.35) + ')';
          context.font = '11px sans-serif';
          context.textAlign = 'center';
          context.fillText(cog.alias, cog.x, cog.y - 20);
          continue;
        }
        context.save();
        context.globalAlpha = lit ? 1 : 0.3;   // the spectator's dramatic irony
        context.fillStyle = colour;
        context.beginPath();
        context.arc(cog.x, cog.y, 9, 0, Math.PI * 2);
        context.fill();
        context.globalAlpha = 1;
        context.strokeStyle = colour;
        context.lineWidth = 1.5;
        context.beginPath();
        context.arc(cog.x, cog.y, 9, 0, Math.PI * 2);
        context.stroke();
        // the aim stub
        var heading = -cog.aim * Math.PI * 2 / 256;
        context.strokeStyle = 'rgba(20, 14, 9, 0.9)';
        context.lineWidth = 3;
        context.beginPath();
        context.moveTo(cog.x, cog.y);
        context.lineTo(cog.x + Math.cos(heading) * 13,
                       cog.y + Math.sin(heading) * 13);
        context.stroke();
        if (cog.state === 2) {           // crawling
          context.strokeStyle = 'rgba(242, 232, 216, 0.5)';
          context.lineWidth = 1;
          context.beginPath();
          context.arc(cog.x, cog.y, 13, 0, Math.PI * 2);
          context.stroke();
        }
        context.restore();
        // the in-game alias, never the player name
        context.fillStyle = 'rgba(242, 232, 216, ' + (lit ? 0.9 : 0.35) + ')';
        context.font = '11px sans-serif';
        context.textAlign = 'center';
        context.fillText(cog.alias, cog.x, cog.y - 14);
      }
    }

    function drawBursts(now) {
      for (var i = bursts.length - 1; i >= 0; i--) {
        var burst = bursts[i];
        var age = (now - burst.at) / 500;
        if (age > 1) { bursts.splice(i, 1); continue; }
        context.strokeStyle = 'rgba(255, 255, 255, ' + (1 - age) + ')';
        context.lineWidth = 5;
        context.beginPath();
        context.arc(burst.x, burst.y, 20 + age * 240, 0, Math.PI * 2);
        context.stroke();
      }
    }

    function drawMinimap(t) {
      if (!minimapContext || !meta || !meta.map) return;
      var w = minimap.width, h = minimap.height;
      var scale = Math.min(w / MAP_W, h / MAP_H);
      minimapContext.setTransform(1, 0, 0, 1, 0, 0);
      minimapContext.fillStyle = '#100c08';
      minimapContext.fillRect(0, 0, w, h);
      minimapContext.setTransform(scale, 0, 0, scale, 0, 0);
      minimapContext.fillStyle = '#2c231b';
      (meta.map.obstacles || []).forEach(function (r) {
        minimapContext.fillRect(r.x, r.y, r.w, r.h);
      });
      if (state) {
        state.cogs.forEach(function (cog) {
          minimapContext.fillStyle = cog.team === 'Moth' ? '#f2c14e' : '#4ecdc4';
          minimapContext.fillRect(cog.x - 7, cog.y - 7, 14, 14);
        });
      }
      minimapContext.strokeStyle = '#f2e8d8';
      minimapContext.lineWidth = 2 / scale;
      minimapContext.strokeRect(t.focusX - t.visW / 2, t.focusY - t.visH / 2,
                                t.visW, t.visH);
    }

    function draw() {
      var t = transform();
      context.setTransform(viewport.dpr, 0, 0, viewport.dpr, 0, 0);
      context.fillStyle = '#0c0906';
      context.fillRect(0, 0, viewport.width, viewport.height);
      withWorld(t, function () {
        drawFloor(t);
        drawWalls();
        drawCrates();
        drawLight();
        drawSounds();
        drawCogs();
        drawBursts(Date.now());
      });
      drawMinimap(t);
      draws += 1;
      if (!firstFrameSent) {
        firstFrameSent = true;
        if (config.onFirstFrame) config.onFirstFrame();
      }
    }

    function ingest(payload) {
      var text = typeof payload === 'string'
        ? payload
        : new TextDecoder().decode(payload);
      var packet = JSON.parse(text);
      if (packet.type === 'meta') {
        meta = packet;
        if (config.onMeta) config.onMeta(text);
        return;
      }
      state = packet;
      (packet.bursts || []).forEach(function (burst) {
        bursts.push({ x: burst[0], y: burst[1], at: Date.now() });
      });
      draw();
      if (config.onText) config.onText(text);
    }

    return {
      ingest: ingest,
      start: function () { emitTransform(); },
      stop: function () { },
      setViewportSize: setViewportSize,
      sendCommand: function () { },
      clickMap: function (x, y) { focusX = x; focusY = y; emitTransform(); if (state) draw(); },
      zoomAt: function (factor) {
        zoom = Math.max(1, Math.min(12, zoom * factor));
        emitTransform(); if (state) draw();
      },
      setZoom: function (level) {
        zoom = Math.max(1, Math.min(12, level));
        emitTransform(); if (state) draw();
      },
      panBy: function (dx, dy) {
        var t = transform();
        focusX -= dx / t.scale; focusY -= dy / t.scale;
        emitTransform(); if (state) draw();
      },
      panByMap: function (dx, dy) {
        focusX -= dx; focusY -= dy; emitTransform(); if (state) draw();
      },
      panTo: function (x, y) { focusX = x; focusY = y; emitTransform(); if (state) draw(); },
      resetView: function () {
        zoom = 1; focusX = MAP_W / 2; focusY = MAP_H / 2;
        emitTransform(); if (state) draw();
      },
      attachMinimap: function (surface) {
        minimap = surface;
        minimapContext = surface ? surface.getContext('2d') : null;
      },
      getPaceStats: function () {
        return { enabled: false, queued: 0, presented: draws, interval: 1000 / 24, draws: draws };
      }
    };
  }

  root.BroadcastCore = { create: create };
})(typeof self !== 'undefined' ? self : this);
