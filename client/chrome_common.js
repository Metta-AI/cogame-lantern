'use strict';
// chrome_common.js — the replay chrome shared by the broadcast page and the
// static wasm bundle: team identity/naming, the clock, the transport bar
// (buttons / speed chips / scrubber), beat markers, lull shading, the
// momentum graph and the spoiler gate.
//
// Forked from paintbot's client/chrome_common.js (coworld-ctf). The factory
// shape, the ids it drives, the transport semantics, the lull machinery, the
// beat markers, the momentum SVG and the spoiler URL toggle are all carried
// across unchanged. What is NOT carried is everything that only exists in
// CTF: four teams, perks, lives meters, flag beats and the POV lens. Lantern
// has two teams (Moth, Owl), no perks, no lives, and nothing to look through,
// so those blocks are dropped rather than left as dead code that reads a
// state shape this game never emits.
//
// Served two ways, mirroring wire_constants (this file is inlined into a
// script tag, so it must never contain the literal splice marker or a script
// close tag):
//  - native server: served from /client/chrome_common.js;
//  - static WASM bundle: copied into dist/ and loaded via a script src
//    (Dockerfile.replay-viewer sed's the marker).
//
// window.ChromeCommon(ctx) -> object of shared functions + constants.
// ctx fields:
//  - send(cmd):     deliver one transport command to the playback channel.
//  - getState():    the latest parsed frame packet (or null before the first).
//  - getMeta():     the replay meta (names, results, phases) or null.
window.ChromeCommon = function (ctx) {
  var $ = function (id) { return document.getElementById(id); };

  // ---- palette (mirrors the board tints so chrome matches the arena) ----
  var MOTH = '#f2c14e', OWL = '#4ecdc4', AMBER = '#e8a33d', PAPER = '#f2e8d8';
  var TEAM_ORDER = ['Moth', 'Owl'];
  var TEAM_COLOR = { Moth: MOTH, Owl: OWL };
  function teamCol(team) { return TEAM_COLOR[team] || PAPER; }
  function otherTeam(team) { return team === 'Moth' ? 'Owl' : 'Moth'; }

  var WIRE = window.LANTERN_WIRE || {};
  var SPEEDS = WIRE.speeds || [0.5, 1, 2, 3, 4, 8, 16];
  var FPS = WIRE.fps || 24;

  // Chrome-level toggles read their initial value from the page URL, so
  // whatever launches a replay can preconfigure the chrome.
  function uiToggle(name, dflt) {
    try {
      var raw = new URLSearchParams(location.search).get(name);
      if (raw === null) return dflt;
      return !(raw === '0' || raw === 'false' || raw === 'off');
    } catch (ignore) { return dflt; }
  }
  // Default ON: the tension of hide-and-seek is watching a seeker walk past
  // a cog the spectator can see and the seeker cannot.
  var spoilers = uiToggle('spoilers', true);
  function getSpoilers() { return spoilers; }
  function setSpoilers(on) {
    spoilers = !!on;
    var btn = $('btn-spoilers');
    if (btn) btn.classList.toggle('on', spoilers);
    applySpoilers();
  }

  function esc(t) {
    return String(t).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }
  function setName(id, txt) {
    var el = $(id);
    if (el && el.textContent !== txt) el.textContent = txt;
  }
  function fmt(sec) {
    sec = Math.max(0, Math.floor(sec));
    var m = Math.floor(sec / 60), s = sec % 60;
    return m + ':' + (s < 10 ? '0' : '') + s;
  }

  // ---- scorebug plates -----------------------------------------------------
  // One plate per team: a colour chip, the real PLAYER names (the only place
  // in the whole page they appear — the board itself labels cogs Moth-1..
  // Owl-3), and that team's hidden-seconds clock.
  var platesBuilt = false;
  function ensureScorebug(meta) {
    if (platesBuilt || !meta) return;
    platesBuilt = true;
    TEAM_ORDER.forEach(function (team, index) {
      var host = $(index === 0 ? 'plates-l' : 'plates-r');
      if (!host) return;
      var plate = document.createElement('div');
      plate.className = 'plate ' + (index === 0 ? 'left' : 'right');
      plate.id = 'plate-' + team;
      plate.innerHTML =
        '<span class="plate-chip" style="background:' + teamCol(team) + '"></span>' +
        '<span class="plate-name" id="plate-name-' + team + '"></span>' +
        '<span class="plate-score" id="plate-score-' + team + '">0.0s</span>';
      host.appendChild(plate);
    });
  }
  function teamPlayers(meta, team) {
    var out = [];
    if (!meta || !meta.names) return out;
    for (var i = 0; i < meta.names.teams.length; i++) {
      if (meta.names.teams[i] === team) out.push(meta.names.players[i]);
    }
    return out;
  }
  function teamHeadline(names) {
    var unique = [];
    names.forEach(function (n) { if (unique.indexOf(n) < 0) unique.push(n); });
    if (!unique.length) return '—';
    if (unique.length === 1) return unique[0];
    return unique[0] + ' +' + (unique.length - 1);
  }

  // ---- clock ---------------------------------------------------------------
  function renderClock(s, meta) {
    if (!s) return;
    setName('clock-time', fmt((s.act_left_ticks || 0) / FPS));
    var caption = 'turn ' + ((s.turn || 0) + 1) + '/' + (s.turns || 0);
    setName('clock-caption', caption);
    var chip = $('actchip');
    if (chip) {
      chip.textContent = 'H' + (s.half || 1) + ' ' +
        String(s.act || '').toUpperCase();
    }
    var mini = $('ffwd-mini');
    if (mini) mini.classList.toggle('on', !!s.timelapse);
  }

  // ---- transport -----------------------------------------------------------
  var speedChipEls = {};
  function buildSpeedChips() {
    var host = $('speedchips');
    if (!host || host.childElementCount) return;
    SPEEDS.forEach(function (mult, index) {
      var chip = document.createElement('button');
      chip.className = 'chip';
      chip.innerHTML = '<span class="chip-label">x</span>' + mult;
      chip.title = 'Playback speed x' + mult;
      chip.onclick = function () { ctx.send(String(index + 1)); };
      host.appendChild(chip);
      speedChipEls[mult] = chip;
    });
  }
  function renderTransport(s) {
    buildSpeedChips();
    if (!s) return;
    var play = $('btn-play');
    if (play) play.textContent = s.paused ? '▶' : '❚❚';
    var loop = $('btn-loop');
    if (loop) loop.classList.toggle('on', !!s.loop);
    var skip = $('btn-skip');
    if (skip) skip.classList.toggle('on', !!s.skipLulls);
    var ffwd = $('ffwd-chip');
    if (ffwd) ffwd.classList.toggle('show', !!s.timelapse);
    setName('tick-clock', (s.tick || 0) + ' / ' + (s.tick_count || 0));
    Object.keys(speedChipEls).forEach(function (mult) {
      speedChipEls[mult].classList.toggle('on', Number(mult) === s.speed);
    });
    var total = Math.max(1, s.tick_count || 1);
    var pct = Math.max(0, Math.min(100, (s.tick || 0) * 100 / total));
    var fill = $('scrub-fill');
    if (fill) fill.style.width = pct + '%';
    var head = $('scrub-head');
    if (head) head.style.left = pct + '%';
  }

  // ---- lull shading (the build acts, run as a timelapse) -------------------
  var lullSpans = null;
  var lullsRendered = false;
  function ingestLullSpans(spans) {
    if (spans && spans.length) lullSpans = spans;
  }
  function renderLullSpans(total) {
    var host = $('lulls');
    if (!host || lullsRendered || !lullSpans || !total) return;
    lullsRendered = true;
    host.innerHTML = '';
    lullSpans.forEach(function (span) {
      var el = document.createElement('i');
      el.style.left = (span[0] * 100 / total) + '%';
      el.style.width = ((span[1] - span[0]) * 100 / total) + '%';
      host.appendChild(el);
    });
  }

  // ---- beat markers on the scrubber (finds, locks, breaks) -----------------
  var seenMarkers = {};
  var markerEls = [];
  function markBeat(tick, kind, team, total, label) {
    var key = tick + '|' + kind;
    if (seenMarkers[key]) return;
    seenMarkers[key] = true;
    var host = $('scrub');
    if (!host || !total) return;
    // A button, not an <i>: every beat is a seek target. The page hands us
    // its seek in ctx; without one the click falls through to the scrub
    // track's own click-to-seek, which lands at the same x anyway.
    var el = document.createElement('button');
    el.type = 'button';
    el.className = 'beat beat-' + kind;
    el.style.left = (tick * 100 / total) + '%';
    el.style.background = teamCol(team);
    el.dataset.tick = String(tick);
    if (label) {
      el.title = label;
      el.setAttribute('aria-label', label + ' (seek)');
    }
    if (ctx.seek) {
      el.addEventListener('click', function (event) {
        event.stopPropagation();
        ctx.seek(tick);
      });
    }
    host.appendChild(el);
    markerEls.push(el);
    applySpoilers();
  }
  function applySpoilers() {
    var s = ctx.getState && ctx.getState();
    var now = (s && s.tick) || 0;
    markerEls.forEach(function (el) {
      var ahead = Number(el.dataset.tick) > now;
      el.style.visibility = (ahead && !spoilers) ? 'hidden' : 'visible';
    });
    var win = $('scrub-win');
    if (win) win.style.visibility = spoilers ? 'visible' : 'hidden';
  }

  // ---- momentum: hiders remaining across the whole match -------------------
  var VBW = 1000, VBH = 100;
  var MOM_SVGNS = 'http://www.w3.org/2000/svg';
  function renderMomentum(series, total) {
    var svg = $('momentum');
    if (!svg || !series || !series.length || !total) return;
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    var path = document.createElementNS(MOM_SVGNS, 'polyline');
    var points = series.map(function (point) {
      var x = point[0] * VBW / total;
      var y = VBH - (point[1] / 3) * VBH;
      return x.toFixed(1) + ',' + y.toFixed(1);
    }).join(' ');
    path.setAttribute('points', points);
    path.setAttribute('fill', 'none');
    path.setAttribute('stroke', AMBER);
    path.setAttribute('stroke-width', '3');
    svg.appendChild(path);
  }

  function setVerdict(text, team) {
    var chip = $('win-chip');
    if (!chip) return;
    chip.textContent = text;
    chip.style.color = teamCol(team);
    chip.classList.add('show');
  }

  return {
    MOTH: MOTH, OWL: OWL, AMBER: AMBER, PAPER: PAPER,
    TEAM_ORDER: TEAM_ORDER, TEAM_COLOR: TEAM_COLOR, SPEEDS: SPEEDS, FPS: FPS,
    teamCol: teamCol, otherTeam: otherTeam,
    esc: esc, fmt: fmt, setName: setName,
    ensureScorebug: ensureScorebug, teamPlayers: teamPlayers,
    teamHeadline: teamHeadline,
    renderClock: renderClock, renderTransport: renderTransport,
    ingestLullSpans: ingestLullSpans, renderLullSpans: renderLullSpans,
    markBeat: markBeat, applySpoilers: applySpoilers,
    renderMomentum: renderMomentum, setVerdict: setVerdict,
    getSpoilers: getSpoilers, setSpoilers: setSpoilers
  };
};
