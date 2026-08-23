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
       'cog_moth_rig.png', 'cog_owl_rig.png'].forEach(function (name) {
        fetch(ART_BASE + '/' + name)
          .then(function (r) { return r.ok ? r.blob() : null; })
          .then(function (blob) { return blob ? createImageBitmap(blob) : null; })
          .then(function (bitmap) {
            if (!bitmap) return;
            art[name] = bitmap;
            if (name === 'floor.jpg') {
              floorPattern = context.createPattern(bitmap, 'repeat');
            }
            if (name.indexOf('_rig.png') > 0) rigs[name] = measureRig(bitmap);
            if (state) draw();
          })
          .catch(function () { /* procedural fallback */ });
      });
    }
    loadArt();

    // ---- cog rigs ----------------------------------------------------------
    // Paintbot's soldier masters, used exactly as drawn: the canonical
    // Cogs-vs-Clips cog facing SOUTH, visor visible. As in coworld-ctf's
    // rig_art.nim the body pivot is the centroid of the SOLID pixels
    // (alpha >= 200, the shell - not the feathered outline) and the master is
    // scaled so that solid span stands RigBodyPx tall; the sprite then turns
    // as one rigid unit so the visor faces the aim.
    var RigBodyPx = 34;
    var RigSolidAlpha = 200;
    var rigs = {};
    function measureRig(bitmap) {
      var w = bitmap.width, h = bitmap.height;
      var rig = { bitmap: bitmap, px: w / 2, py: h / 2, scale: RigBodyPx / h };
      if (typeof OffscreenCanvas !== 'function') return rig;
      try {
        var scratch = new OffscreenCanvas(w, h);
        var sc = scratch.getContext('2d');
        sc.drawImage(bitmap, 0, 0);
        var data = sc.getImageData(0, 0, w, h).data;
        var sx = 0, sy = 0, n = 0, top = h, bottom = -1;
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            if (data[(y * w + x) * 4 + 3] >= RigSolidAlpha) {
              sx += x; sy += y; n++;
              if (y < top) top = y;
              if (y > bottom) bottom = y;
            }
          }
        }
        if (n) {
          rig.px = sx / n; rig.py = sy / n;
          rig.scale = RigBodyPx / Math.max(1, bottom - top + 1);
        }
      } catch (ignored) { /* keep the geometric centre */ }
      return rig;
    }

    // ---- the seekers' lit set ----------------------------------------------
    // One byte per FovCell from the wasm module: exactly the sim's teamLit at
    // the cell centre (cone + omni bubble, cut by walls, crates and the pen
    // door through the same lineOfSight the detection rule uses). Kept as a
    // tiny cols x rows bitmap and stretched over the board with bilinear
    // filtering, so the occlusion edges read as soft light rather than tiles.
    var litMask = null;       // { cols, rows, cell, canvas }
    var lightLayer = null;    // board-sized scratch the cones are built in
    function setLitMask(bytes, cols, rows, cell) {
      if (typeof OffscreenCanvas !== 'function' || !cols || !rows) return;
      if (!litMask || litMask.cols !== cols || litMask.rows !== rows) {
        litMask = { cols: cols, rows: rows, cell: cell,
                    canvas: new OffscreenCanvas(cols, rows) };
        litMask.image = litMask.canvas.getContext('2d').createImageData(cols, rows);
      }
      var pixels = litMask.image.data;
      var any = false;
      for (var i = 0; i < cols * rows; i++) {
        var on = bytes[i] ? 255 : 0;
        pixels[i * 4] = 255; pixels[i * 4 + 1] = 255; pixels[i * 4 + 2] = 255;
        pixels[i * 4 + 3] = on;
        if (on) any = true;
      }
      litMask.canvas.getContext('2d').putImageData(litMask.image, 0, 0);
      litMask.any = any;
      if (state) draw();
    }

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

    // The bitmap must match the viewport from the very first frame. The
    // canvas arrives here transferred from the page with whatever size the
    // element had (none declared -> 300x150), and the page stretches the
    // bitmap over the stage: draw a 1700px scene into 300px and the replay
    // opens ~6x "zoomed in", and stays so until a resize message happens to
    // arrive (fullscreen did it). Paintbot's core re-synced the bitmap on
    // every draw; this one sizes it at create and on every resize.
    function syncBitmap() {
      var width = Math.round(viewport.width * viewport.dpr);
      var height = Math.round(viewport.height * viewport.dpr);
      if (canvas.width !== width) canvas.width = width;
      if (canvas.height !== height) canvas.height = height;
    }
    syncBitmap();

    function setViewportSize(width, height, dpr) {
      viewport.width = Math.max(1, width || viewport.width);
      viewport.height = Math.max(1, height || viewport.height);
      viewport.dpr = dpr || viewport.dpr;
      syncBitmap();
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
        // Steel racking: a mid-tone body that separates from the dark floor,
        // a lit top edge and a drop shadow beneath so the slab reads as
        // standing on the floor rather than painted on it.
        context.fillStyle = 'rgba(0, 0, 0, 0.45)';
        context.fillRect(w.x + 2, w.y + 3, w.w, w.h);
        context.fillStyle = '#6b5a47';
        context.fillRect(w.x, w.y, w.w, w.h);
        context.fillStyle = 'rgba(242, 232, 216, 0.28)';
        context.fillRect(w.x, w.y, w.w, 2);
        context.fillStyle = 'rgba(0, 0, 0, 0.35)';
        context.fillRect(w.x, w.y + w.h - 2, w.w, 2);
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

    function paintCones(ctx) {
      for (var i = 0; i < state.cogs.length; i++) {
        var cog = state.cogs[i];
        if (cog.role !== 'seeker') continue;
        var cone = coneFor(cog);
        var gradient = ctx.createRadialGradient(
          cog.x, cog.y, 8, cog.x, cog.y, cone.range);
        gradient.addColorStop(0, 'rgba(255, 246, 214, 0.42)');
        gradient.addColorStop(1, 'rgba(255, 246, 214, 0.0)');
        ctx.fillStyle = gradient;
        ctx.beginPath();
        ctx.moveTo(cog.x, cog.y);
        ctx.arc(cog.x, cog.y, cone.range,
                cone.heading - cone.half, cone.heading + cone.half);
        ctx.closePath();
        ctx.fill();
        // hot core along the aim ray
        ctx.strokeStyle = 'rgba(255, 252, 240, 0.30)';
        ctx.lineWidth = 6;
        ctx.beginPath();
        ctx.moveTo(cog.x, cog.y);
        ctx.lineTo(cog.x + Math.cos(cone.heading) * cone.range,
                   cog.y + Math.sin(cone.heading) * cone.range);
        ctx.stroke();
        // the omni bubble
        ctx.fillStyle = 'rgba(255, 246, 214, 0.10)';
        ctx.beginPath();
        ctx.arc(cog.x, cog.y, 60, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    function drawLight() {
      if (!state || state.act !== 'hunt') return;
      // The cones are painted into a board-sized scratch layer with 'lighter'
      // so overlapping cones add rather than darken, then CUT to the sim's
      // lit set: what is left is exactly what the seekers can see, walls,
      // crates and the pen door throwing the same shadows the detection rule
      // sees. Without the mask (no OffscreenCanvas, or a build act) the raw
      // cones are drawn straight onto the board.
      if (!litMask || typeof OffscreenCanvas !== 'function') {
        context.save();
        context.globalCompositeOperation = 'lighter';
        paintCones(context);
        context.restore();
        return;
      }
      if (!lightLayer) lightLayer = new OffscreenCanvas(MAP_W, MAP_H);
      var lc = lightLayer.getContext('2d');
      lc.setTransform(1, 0, 0, 1, 0, 0);
      lc.globalCompositeOperation = 'source-over';
      lc.clearRect(0, 0, MAP_W, MAP_H);
      if (!litMask.any) return;
      lc.globalCompositeOperation = 'lighter';
      paintCones(lc);
      lc.globalCompositeOperation = 'destination-in';
      lc.imageSmoothingEnabled = true;
      lc.imageSmoothingQuality = 'high';
      // Cell centres were sampled, so the bitmap spans the board shifted by
      // half a cell; stretching cols x rows over cols*cell x rows*cell puts
      // each sample at the centre of its cell.
      lc.drawImage(litMask.canvas, 0, 0,
                   litMask.cols * litMask.cell, litMask.rows * litMask.cell);
      context.drawImage(lightLayer, 0, 0);
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
        var rig = rigs[cog.team === 'Moth' ? 'cog_moth_rig.png' : 'cog_owl_rig.png'];
        if (rig) {
          context.save();
          context.globalAlpha = lit ? 1 : 0.3;   // the spectator's dramatic irony
          context.translate(cog.x, cog.y);
          // The master faces SOUTH (+y); turn it so the visor faces the aim
          // (0 = east, brads counter-clockwise).
          context.rotate(-cog.aim * Math.PI * 2 / 256 - Math.PI / 2);
          var scale = rig.scale * (cog.state === 2 ? 0.82 : 1);   // crawling: low
          context.scale(scale, scale);
          context.drawImage(rig.bitmap, -rig.px, -rig.py);
          context.restore();
          if (!lit) {
            context.strokeStyle = colour;
            context.lineWidth = 1.5;
            context.beginPath();
            context.arc(cog.x, cog.y, RigBodyPx / 2 + 2, 0, Math.PI * 2);
            context.stroke();
          }
          context.fillStyle = 'rgba(242, 232, 216, ' + (lit ? 0.9 : 0.35) + ')';
          context.font = '11px sans-serif';
          context.textAlign = 'center';
          context.fillText(cog.alias, cog.x, cog.y - RigBodyPx / 2 - 5);
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
      syncBitmap();
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
      setLitMask: setLitMask,
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
