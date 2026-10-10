// Echora live dashboard. Polls the relay (or, later, Moon's backend) and draws:
// the snapshot Gemini saw with its box, a top-down map of the room, live numbers,
// and the "angle off" curve for the current round.
//
// Data source: same origin by default. Point it elsewhere with ?api=https://host
// (e.g. Moon's backend once it serves the same /live/* endpoints).
//
// World coordinates are ARKit's: meters, +Y up, -Z = the camera's initial forward.
// The map looks straight down with -Z (initial forward) pointing up the screen.

(function () {
  "use strict";

  const params = new URLSearchParams(window.location.search);
  const API = (params.get("api") || "").replace(/\/$/, "");
  const POLL_MS = 200;
  const LIVE_TIMEOUT_S = 3;
  const MIN_MAP_SPAN_M = 1.5;

  const el = (id) => document.getElementById(id);
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  let latest = null;
  let snapshotVersion = -1;
  let mapView = null; // smoothed {cx, cz, span}

  // ---------- canvas helpers ----------

  function fitCanvas(canvas) {
    const rect = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const width = Math.max(1, Math.round(rect.width * dpr));
    const height = Math.max(1, Math.round(rect.height * dpr));
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }
    const ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return { ctx, width: rect.width, height: rect.height };
  }

  function horizontalLength(v) {
    return Math.hypot(v.x, v.z);
  }

  // ---------- polling ----------

  async function poll() {
    try {
      const response = await fetch(API + "/live/state", { cache: "no-store" });
      if (response.ok) {
        latest = await response.json();
      }
    } catch (error) {
      // Relay not reachable; the status pill shows it.
    }
    render();
    setTimeout(poll, POLL_MS);
  }

  // ---------- rendering ----------

  function render() {
    if (!latest) {
      setStatus(false, "dashboard can't reach the relay");
      return;
    }
    const sinceLastPost = latest.serverTime - (latest.lastPostAt || 0);
    const live = latest.lastPostAt && sinceLastPost < LIVE_TIMEOUT_S;
    setStatus(live, live ? "phone connected" : "waiting for phone");

    renderRound();
    renderSnapshot();
    renderMap();
    renderStats();
    renderCurve();
    renderResult();
  }

  function setStatus(live, text) {
    el("status-dot").classList.toggle("live", Boolean(live));
    el("status-text").textContent = text;
  }

  function lastFrame() {
    const frames = latest.frames || [];
    return frames.length ? frames[frames.length - 1] : null;
  }

  function roundFrames() {
    const round = latest.round;
    const frames = latest.frames || [];
    if (!round) {
      return [];
    }
    return frames.filter((f) => f.roundId === round.roundId && typeof f.elapsed === "number");
  }

  function renderRound() {
    const round = latest.round;
    const pill = el("round-mode");
    if (!round) {
      pill.textContent = "idle";
      pill.classList.remove("echora");
      el("round-object").textContent = "Waiting for a request…";
      return;
    }
    pill.textContent = "Echora";
    pill.classList.add("echora");
    const label = round.objectLabel || "object";
    let prefix = "Finding";
    if (round.ended === "found") prefix = "Found";
    if (round.ended === "cancelled") prefix = "Cancelled";
    el("round-object").textContent = `${prefix}: ${label}`;
  }

  function renderSnapshot() {
    const locate = latest.locate;
    const img = el("snapshot");
    el("snapshot-empty").style.display = locate ? "none" : "flex";

    if (locate && locate.snapshotVersion !== snapshotVersion) {
      snapshotVersion = locate.snapshotVersion;
      img.src = API + "/live/snapshot.jpg?v=" + snapshotVersion;
    }

    el("fact-utterance").textContent = locate ? `"${locate.utterance || "–"}"` : "–";
    el("fact-label").textContent = locate ? locate.label || "–" : "–";
    el("fact-latency").textContent = locate && locate.latencyMs ? (locate.latencyMs / 1000).toFixed(1) + " s" : "–";
    el("fact-placement").textContent = locate ? prettyPlacement(locate.placement) : "–";

    const { ctx, width, height } = fitCanvas(el("snapshot-canvas"));
    ctx.clearRect(0, 0, width, height);
    if (!locate || !img.complete || !img.naturalWidth) {
      return;
    }

    const imgW = img.naturalWidth;
    const imgH = img.naturalHeight;
    const box = locate.box || { minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6 };
    const crop = zoomCrop(box, imgW, imgH, width / height);

    // Zoomed view: the crop fills the panel.
    ctx.drawImage(img, crop.x, crop.y, crop.w, crop.h, 0, 0, width, height);
    const scale = width / crop.w;
    const bx = (box.minX * imgW - crop.x) * scale;
    const by = (box.minY * imgH - crop.y) * scale;
    const bw = (box.maxX - box.minX) * imgW * scale;
    const bh = (box.maxY - box.minY) * imgH * scale;

    ctx.lineWidth = 4;
    ctx.strokeStyle = css("--box");
    ctx.strokeRect(bx, by, bw, bh);
    drawTag(ctx, locate.label || "", bx, by, bh);

    // Inset: the full photo with the zoomed area marked, so it's clear where it came from.
    const insetH = Math.min(height * 0.32, 150);
    const insetW = insetH * (imgW / imgH);
    const ix = 12;
    const iy = height - insetH - 12;
    ctx.fillStyle = "rgba(0, 0, 0, 0.6)";
    ctx.fillRect(ix - 4, iy - 4, insetW + 8, insetH + 8);
    ctx.drawImage(img, 0, 0, imgW, imgH, ix, iy, insetW, insetH);
    const k = insetW / imgW;
    ctx.lineWidth = 2;
    ctx.strokeStyle = css("--map-label");
    ctx.strokeRect(ix + crop.x * k, iy + crop.y * k, crop.w * k, crop.h * k);
  }

  /// Crop around the box: ~3x the box size, at least 30% of the photo, matching the
  /// panel's aspect ratio, kept inside the photo.
  function zoomCrop(box, imgW, imgH, aspect) {
    const cx = ((box.minX + box.maxX) / 2) * imgW;
    const cy = ((box.minY + box.maxY) / 2) * imgH;
    const boxW = (box.maxX - box.minX) * imgW;
    const boxH = (box.maxY - box.minY) * imgH;

    let w = Math.max(boxW * 3, boxH * 3 * aspect, imgW * 0.3);
    let h = w / aspect;
    if (h > imgH) {
      h = imgH;
      w = h * aspect;
    }
    if (w > imgW) {
      w = imgW;
      h = w / aspect;
    }
    const x = Math.min(Math.max(cx - w / 2, 0), imgW - w);
    const y = Math.min(Math.max(cy - h / 2, 0), imgH - h);
    return { x, y, w, h };
  }

  function drawTag(ctx, text, x, y, boxHeight) {
    if (!text) return;
    ctx.font = "700 20px " + css("--font");
    const textW = ctx.measureText(text).width + 16;
    const tagY = y > 34 ? y - 34 : y + boxHeight + 6;
    ctx.fillStyle = css("--box");
    ctx.fillRect(x, tagY, textW, 30);
    ctx.fillStyle = "#1a0710";
    ctx.fillText(text, x + 8, tagY + 22);
  }

  function prettyPlacement(method) {
    const names = {
      lidarDepth: "LiDAR depth",
      raycastExistingPlane: "table surface",
      raycastEstimatedPlane: "estimated surface",
      planeIntersection: "plane intersection",
      fixedDepthFallback: "fixed depth",
      manualTap: "tap",
    };
    return names[method] || method || "–";
  }

  function renderMap() {
    const { ctx, width, height } = fitCanvas(el("map"));
    ctx.clearRect(0, 0, width, height);

    const frames = latest.frames || [];
    const frame = lastFrame();
    const locate = latest.locate;
    const trail = roundFrames().length ? roundFrames() : frames.slice(-150);
    const roundTarget = roundFrames().filter((f) => f.target).map((f) => f.target).pop();

    // Points to keep in view.
    const points = [];
    trail.forEach((f) => f.listener && points.push(f.listener));
    if (frame && frame.phone) points.push(frame.phone);
    if (frame && frame.target) points.push(frame.target);
    if (roundTarget) points.push(roundTarget);
    if (locate && locate.target) points.push(locate.target);
    if (locate && locate.camera) points.push(locate.camera);

    if (!points.length) {
      ctx.fillStyle = css("--muted");
      ctx.font = "18px " + css("--font");
      ctx.textAlign = "center";
      ctx.fillText("No position data yet", width / 2, height / 2);
      ctx.textAlign = "left";
      return;
    }

    let minX = Infinity, maxX = -Infinity, minZ = Infinity, maxZ = -Infinity;
    points.forEach((p) => {
      minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
      minZ = Math.min(minZ, p.z); maxZ = Math.max(maxZ, p.z);
    });
    const target = { cx: (minX + maxX) / 2, cz: (minZ + maxZ) / 2,
                     span: Math.max(MIN_MAP_SPAN_M, (maxX - minX) * 1.4, (maxZ - minZ) * 1.4) };
    if (!mapView) {
      mapView = target;
    } else {
      // Ease toward the new view so the map doesn't jitter.
      mapView = {
        cx: mapView.cx + (target.cx - mapView.cx) * 0.15,
        cz: mapView.cz + (target.cz - mapView.cz) * 0.15,
        span: mapView.span + (target.span - mapView.span) * 0.15,
      };
    }

    const pxPerM = Math.min(width, height) / mapView.span;
    const toScreen = (p) => ({
      x: width / 2 + (p.x - mapView.cx) * pxPerM,
      y: height / 2 + (p.z - mapView.cz) * pxPerM,
    });

    drawGrid(ctx, width, height, pxPerM, toScreen);

    // Camera -> object ray, from the snapshot.
    if (locate && locate.camera && locate.target) {
      const a = toScreen(locate.camera);
      const b = toScreen(locate.target);
      ctx.save();
      ctx.setLineDash([10, 8]);
      ctx.lineWidth = 3;
      ctx.strokeStyle = css("--map-ray");
      ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
      ctx.restore();
    }

    // Trail of where the listener has been.
    if (trail.length > 1) {
      ctx.lineWidth = 3;
      ctx.strokeStyle = css("--map-trail");
      ctx.globalAlpha = 0.45;
      ctx.beginPath();
      trail.forEach((f, i) => {
        if (!f.listener) return;
        const s = toScreen(f.listener);
        if (i === 0) ctx.moveTo(s.x, s.y); else ctx.lineTo(s.x, s.y);
      });
      ctx.stroke();
      ctx.globalAlpha = 1;
    }

    // Keep showing the round's object after FOUND, when live frames no longer carry it.
    const roundTargets = roundFrames().filter((f) => f.target);
    const lastRoundTarget = roundTargets.length ? roundTargets[roundTargets.length - 1].target : null;
    const targetPos = (frame && frame.target) || lastRoundTarget || (locate && locate.target);
    if (targetPos) {
      drawTarget(ctx, toScreen(targetPos), latest.result ? "found" : (latest.round && latest.round.objectLabel) || "object");
    }

    if (frame && frame.phone) {
      drawPhone(ctx, toScreen(frame.phone), frame.phoneForward);
    }

    if (frame && frame.listener) {
      const you = toScreen(frame.listener);
      if (targetPos) {
        const t = toScreen(targetPos);
        ctx.save();
        ctx.setLineDash([3, 6]);
        ctx.lineWidth = 2;
        ctx.strokeStyle = css("--map-sightline");
        ctx.beginPath(); ctx.moveTo(you.x, you.y); ctx.lineTo(t.x, t.y); ctx.stroke();
        ctx.restore();
      }
      drawListener(ctx, you, frame.forward, pxPerM);
    }
  }

  function drawGrid(ctx, width, height, pxPerM, toScreen) {
    const step = 0.5;
    ctx.strokeStyle = css("--map-grid");
    ctx.lineWidth = 1;
    const halfSpanX = width / 2 / pxPerM;
    const halfSpanZ = height / 2 / pxPerM;
    const startX = Math.floor((mapView.cx - halfSpanX) / step) * step;
    const startZ = Math.floor((mapView.cz - halfSpanZ) / step) * step;
    for (let x = startX; x <= mapView.cx + halfSpanX; x += step) {
      const s = toScreen({ x, z: 0 });
      ctx.beginPath(); ctx.moveTo(s.x, 0); ctx.lineTo(s.x, height); ctx.stroke();
    }
    for (let z = startZ; z <= mapView.cz + halfSpanZ; z += step) {
      const s = toScreen({ x: 0, z });
      ctx.beginPath(); ctx.moveTo(0, s.y); ctx.lineTo(width, s.y); ctx.stroke();
    }
    // Scale bar.
    ctx.fillStyle = css("--muted");
    ctx.font = "13px " + css("--font");
    ctx.fillRect(12, height - 18, 0.5 * pxPerM, 3);
    ctx.fillText("50 cm", 12, height - 24);
  }

  function drawTarget(ctx, s, label) {
    const pulse = 10 + 4 * Math.sin(Date.now() / 200);
    ctx.fillStyle = css("--map-target");
    ctx.globalAlpha = 0.25;
    ctx.beginPath(); ctx.arc(s.x, s.y, pulse + 10, 0, Math.PI * 2); ctx.fill();
    ctx.globalAlpha = 1;
    ctx.beginPath(); ctx.arc(s.x, s.y, 10, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = css("--map-label");
    ctx.font = "600 16px " + css("--font");
    ctx.fillText(label, s.x + 16, s.y + 5);
  }

  function drawPhone(ctx, s, forward) {
    ctx.fillStyle = css("--map-phone");
    ctx.fillRect(s.x - 7, s.y - 7, 14, 14);
    if (forward && horizontalLength(forward) > 0.01) {
      const len = horizontalLength(forward);
      ctx.strokeStyle = css("--map-phone");
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(s.x, s.y);
      ctx.lineTo(s.x + (forward.x / len) * 22, s.y + (forward.z / len) * 22);
      ctx.stroke();
    }
  }

  function drawListener(ctx, s, forward, pxPerM) {
    ctx.fillStyle = css("--map-listener");
    ctx.beginPath(); ctx.arc(s.x, s.y, 12, 0, Math.PI * 2); ctx.fill();
    if (!forward || horizontalLength(forward) < 0.01) return;

    const len = horizontalLength(forward);
    const dx = forward.x / len;
    const dz = forward.z / len;
    const arrow = Math.max(40, 0.35 * pxPerM);
    const tip = { x: s.x + dx * arrow, y: s.y + dz * arrow };

    ctx.strokeStyle = css("--map-listener");
    ctx.lineWidth = 5;
    ctx.beginPath(); ctx.moveTo(s.x, s.y); ctx.lineTo(tip.x, tip.y); ctx.stroke();

    const angle = Math.atan2(dz, dx);
    ctx.beginPath();
    ctx.moveTo(tip.x, tip.y);
    ctx.lineTo(tip.x - 14 * Math.cos(angle - 0.5), tip.y - 14 * Math.sin(angle - 0.5));
    ctx.lineTo(tip.x - 14 * Math.cos(angle + 0.5), tip.y - 14 * Math.sin(angle + 0.5));
    ctx.closePath();
    ctx.fill();

    ctx.fillStyle = css("--map-label");
    ctx.font = "600 16px " + css("--font");
    ctx.fillText("you", s.x - 14, s.y + 30);
  }

  function renderStats() {
    // After FOUND, live frames no longer carry the object; show the last in-round values.
    const live = lastFrame();
    const inRound = roundFrames().filter((f) => typeof f.angleDeg === "number");
    const frame = live && typeof live.angleDeg === "number" ? live : inRound[inRound.length - 1] || live;
    const round = latest.round;
    const result = latest.result;

    let seconds = null;
    if (result && typeof result.durationSeconds === "number") {
      seconds = result.durationSeconds;
    } else if (frame && round && frame.roundId === round.roundId && typeof frame.elapsed === "number") {
      seconds = frame.elapsed;
    }
    el("stat-time").textContent = seconds === null ? "–" : seconds.toFixed(1) + " s";

    const angleEl = el("stat-angle");
    if (frame && typeof frame.angleDeg === "number") {
      const a = frame.angleDeg;
      const abs = Math.abs(a);
      angleEl.textContent = abs < 3 ? "ahead" : `${abs.toFixed(0)}° ${a > 0 ? "R" : "L"}`;
      angleEl.classList.toggle("on-target", Boolean(frame.onTarget));
    } else {
      angleEl.textContent = "–";
      angleEl.classList.remove("on-target");
    }

    el("stat-distance").textContent =
      frame && typeof frame.distanceM === "number" ? Math.round(frame.distanceM * 100) + " cm" : "–";

    if (frame && typeof frame.headYawDeg === "number" && frame.headTracking) {
      const y = frame.headYawDeg;
      el("stat-head").textContent = Math.abs(y) < 3 ? "straight" : `${Math.abs(y).toFixed(0)}° ${y > 0 ? "L" : "R"}`;
    } else {
      el("stat-head").textContent = frame ? "off" : "–";
    }

    el("stat-cue").textContent =
      frame && typeof frame.cueIntervalS === "number" ? (1 / frame.cueIntervalS).toFixed(1) + " /s" : "–";
  }

  function renderCurve() {
    const { ctx, width, height } = fitCanvas(el("curve"));
    ctx.clearRect(0, 0, width, height);
    const frames = roundFrames().filter((f) => typeof f.angleDeg === "number");

    ctx.strokeStyle = css("--map-grid");
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(40, height - 20); ctx.lineTo(width, height - 20); ctx.stroke();
    ctx.fillStyle = css("--muted");
    ctx.font = "12px " + css("--font");
    if (frames.length < 2) {
      ctx.fillText("0°", 18, height - 22);
      ctx.fillText("Appears during a round", 48, height / 2);
      return;
    }

    // Auto-scale to the biggest angle in this round (at least 30°).
    let maxAngle = 30;
    frames.forEach((f) => { maxAngle = Math.max(maxAngle, Math.abs(f.angleDeg)); });
    maxAngle = Math.min(180, Math.ceil(maxAngle / 15) * 15);
    ctx.fillText(maxAngle + "°", 4, 14);
    ctx.fillText("0°", 18, height - 22);

    // The on-target band (|angle| < 12°).
    const bandTop = height - 20 - (12 / maxAngle) * (height - 30);
    ctx.fillStyle = css("--accent");
    ctx.globalAlpha = 0.12;
    ctx.fillRect(40, bandTop, width - 50, height - 20 - bandTop);
    ctx.globalAlpha = 1;
    ctx.fillStyle = css("--muted");

    const maxT = Math.max(5, frames[frames.length - 1].elapsed);
    const x = (t) => 40 + (t / maxT) * (width - 50);
    const y = (a) => height - 20 - (Math.min(maxAngle, Math.abs(a)) / maxAngle) * (height - 30);

    ctx.strokeStyle = css("--accent");
    ctx.lineWidth = 3;
    ctx.beginPath();
    frames.forEach((f, i) => {
      if (i === 0) ctx.moveTo(x(f.elapsed), y(f.angleDeg)); else ctx.lineTo(x(f.elapsed), y(f.angleDeg));
    });
    ctx.stroke();
    ctx.fillStyle = css("--muted");
    ctx.fillText("0 s", 40, height - 4);
    ctx.fillText((maxT / 2).toFixed(0) + " s", x(maxT / 2) - 8, height - 4);
    ctx.fillText(maxT.toFixed(0) + " s", width - 30, height - 4);
  }

  function renderResult() {
    const banner = el("result-banner");
    const result = latest.result;
    if (!result || result.event !== "found") {
      banner.classList.add("hidden");
      return;
    }
    banner.classList.remove("hidden");
    el("result-time").textContent = (result.durationSeconds || 0).toFixed(1) + " s";
    el("result-detail").textContent = `${result.objectLabel || "object"}, found by sound`;
  }

  window.addEventListener("resize", render);
  poll();
})();
