const canvas = document.getElementById("pet-canvas");
const ctx = canvas.getContext("2d");
const animationSelect = document.getElementById("animation-select");
const moodLabel = document.getElementById("mood-label");
const animationLabel = document.getElementById("animation-label");
const statusReadout = document.getElementById("status-readout");
const energyRange = document.getElementById("energy-range");
const tapButton = document.getElementById("tap-button");
const napButton = document.getElementById("nap-button");
const randomButton = document.getElementById("random-button");
const idleButton = document.getElementById("idle-button");
const faceModeButton = document.getElementById("face-mode-button");
const moodButtons = Array.from(document.querySelectorAll("[data-mood]") || []);

const VE = window.VectorEngine;

let animations = [];

// ---- State ----
const state = {
  animation: null,
  startedAt: performance.now(),
  mood: "idle",
  prevMood: "idle",
  faceOnly: true,
  currentIndex: 0,
  nextAnimationAt: performance.now() + 3000,
  autoPlay: true,
  lastInteractionAt: performance.now(),
  lastClickAt: 0,
  clickCount: 0,
  smoothedFace: null,
  lookOffset: { x: 0, y: 0 },
  renderPose: {
    lookX: 0,
    lookY: 0,
    swayX: 0,
    swayY: 0,
    tilt: 0,
    squash: 1,
  },
  lastRenderAt: performance.now(),
  lastNeedUpdateAt: performance.now(),
  windowBlurred: false,
  animQueue: [],       // animation sequence queue
  queuePlaying: false,
  wasAsleep: false,
  greetedToday: false,
  lastGreetingDay: -1,
  transcription: {
    mode: "idle",
    visibleMode: "idle",
    startedAt: 0,
    visualAmount: 0,
    lastVisualAt: performance.now(),
  },
};

// ---- Utilities ----
function ease(t) { return t * t * (3 - 2 * t); }
function clamp(v, min, max) { return Math.min(max, Math.max(min, v)); }
function lerp(a, b, t) { return a + (b - a) * t; }

// ---- Canvas ----
function resizeCanvas() {
  const rect = canvas.getBoundingClientRect();
  const scale = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.floor(rect.width * scale));
  canvas.height = Math.max(1, Math.floor(rect.height * scale));
  ctx.setTransform(scale, 0, 0, scale, 0, 0);
}

// ---- Animation loading ----
function normalizeAnimation(raw) {
  const name = Object.keys(raw)[0];
  const frames = raw[name].slice().sort((a, b) => a.triggerTime_ms - b.triggerTime_ms);
  const tracks = {
    face: frames.filter(f => f.Name === "ProceduralFaceKeyFrame"),
    head: frames.filter(f => f.Name === "HeadAngleKeyFrame"),
    lift: frames.filter(f => f.Name === "LiftHeightKeyFrame"),
  };
  const duration = Math.max(1000, ...frames.map(f => f.triggerTime_ms + (f.durationTime_ms || 0)));
  return { name, tracks, duration };
}

async function loadAnimation(index) {
  const item = animations[index];
  if (!item) return;
  if (animationLabel) animationLabel.textContent = "loading " + item.label.toLowerCase();
  const response = await fetch(item.path);
  if (!response.ok) throw new Error("Could not load " + item.path);
  state.animation = normalizeAnimation(await response.json());
  state.startedAt = performance.now();
  state.currentIndex = index;
  scheduleNextAnimation();
  if (animationLabel) animationLabel.textContent = item.label;
}

async function loadAnimationIndex() {
  try {
    const response = await fetch("animation-index.json");
    if (!response.ok) throw new Error("animation index unavailable");
    const indexed = await response.json();
    const byPath = new Map();
    indexed.forEach(item => byPath.set(item.path, item));
    animations = Array.from(byPath.values());
  } catch (e) { console.warn(e); }
  renderAnimationOptions();
}

function renderAnimationOptions() {
  if (!animationSelect) return;
  animationSelect.replaceChildren();
  animations.forEach((item, i) => {
    const o = document.createElement("option");
    o.value = String(i);
    o.textContent = item.label;
    animationSelect.append(o);
  });
}

// ---- Animation index search ----
function findAnimationIndices(match) {
  const lower = match.toLowerCase();
  const indices = [];
  animations.forEach((item, i) => {
    if (item.path.toLowerCase().includes(lower)) indices.push(i);
  });
  return indices;
}

// ---- Behavior tree → animation selection ----
function chooseNextFromBehavior() {
  // Priority: Sleeping if idle
  if (state.isIdle) {
    const sleepIndices = VE.resolveBehaviorToAnimations("sleeping", animations);
    if (sleepIndices.length > 0) {
      return sleepIndices[Math.floor(Math.random() * sleepIndices.length)];
    }
  }

  // If music is playing...
  if (state.isMusicPlaying && Math.random() < 0.2) {
    const danceIndices = VE.resolveBehaviorToAnimations("excited_dance", animations);
    if (danceIndices.length > 0) {
      return danceIndices[Math.floor(Math.random() * danceIndices.length)];
    }
  }

  const mood = state.mood;
  const behavior = VE.chooseBehavior(mood);
  const indices = VE.resolveBehaviorToAnimations(behavior, animations);
  
  if (indices.length === 0) {
    // Fallback: any keepalive or eyepose
    const fallback = findAnimationIndices("keepalive");
    if (fallback.length > 0) return fallback[Math.floor(Math.random() * fallback.length)];
    return Math.floor(Math.random() * animations.length);
  }
  
  // Avoid repeating same animation
  let pick = indices[Math.floor(Math.random() * indices.length)];
  if (indices.length > 1) {
    let tries = 0;
    while (pick === state.currentIndex && tries < 5) {
      pick = indices[Math.floor(Math.random() * indices.length)];
      tries++;
    }
  }
  return pick;
}

function playNextAnimation() {
  // Check queue first
  if (state.animQueue.length > 0) {
    const nextIdx = state.animQueue.shift();
    if (animationSelect) animationSelect.value = String(nextIdx);
    loadAnimation(nextIdx).catch(showLoadError);
    return;
  }
  
  const idx = chooseNextFromBehavior();
  if (animationSelect) animationSelect.value = String(idx);
  loadAnimation(idx).catch(showLoadError);
}

function playSequence(indices, loopCount) {
  if (indices.length === 0) return;
  state.animQueue = [];
  // getin
  if (indices[0] !== undefined) state.animQueue.push(indices[0]);
  // loop N times
  if (indices[1] !== undefined) {
    for (let i = 0; i < (loopCount || 2); i++) state.animQueue.push(indices[1]);
  }
  // getout
  if (indices[2] !== undefined) state.animQueue.push(indices[2]);
  
  if (state.animQueue.length > 0) {
    const first = state.animQueue.shift();
    loadAnimation(first).catch(showLoadError);
  }
}

function scheduleNextAnimation(now = performance.now()) {
  if (!state.animation) {
    state.nextAnimationAt = now + 2000;
    return;
  }
  const isSlow = state.mood === "sleeping" || state.mood === "sleepy";
  const baseDwell = isSlow ? 4000 : 800;
  const randDwell = isSlow ? 6000 : 2500;
  const animPart = Math.min(state.animation.duration, isSlow ? 10000 : 5000);
  state.nextAnimationAt = now + animPart + baseDwell + Math.random() * randDwell;
}

// ---- Helper: pick random from array ----
function randFrom(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

// ---- Play a behavior category as animation ----
function playBehaviorCategory(category) {
  const indices = VE.resolveBehaviorToAnimations(category, animations);
  if (indices.length > 0) {
    const idx = randFrom(indices);
    state.animQueue.push(idx);
    if (state.animQueue.length === 1) playNextAnimation();
  }
}
// Expose globally for Electron IPC calls
window.playBehaviorCategory = playBehaviorCategory;

function setTranscriptionMode(mode) {
  if (state.transcription.mode === mode) return;

  state.transcription.mode = mode;
  if (mode !== "idle") {
    state.transcription.visibleMode = mode;
    state.transcription.startedAt = performance.now();
  }

  if (mode === "listening") {
    VE.emotions.stimulation = Math.min(100, VE.emotions.stimulation + 18);
    VE.emotions.social = Math.min(100, VE.emotions.social + 8);
    VE.emotions.calmness = Math.max(0, VE.emotions.calmness - 8);
    playBehaviorCategory("sound_react");
  } else if (mode === "transcribing") {
    VE.emotions.stimulation = Math.min(100, VE.emotions.stimulation + 8);
    playBehaviorCategory("curious_observe");
  }
}

function setSystemState(newState) {
  if (state.isMusicPlaying !== newState.playing) {
    console.log("[AndyJS] Music " + (newState.playing ? "started" : "stopped"));
    if (newState.playing) {
      VE.emotions.stimulation = Math.min(100, VE.emotions.stimulation + 40);
      VE.emotions.happiness = Math.min(100, VE.emotions.happiness + 20);
    }
  }
  
  if (state.isTyping !== newState.typing) {
    if (newState.typing) {
      state.lookOffset = { x: 0, y: 18 };
    } else {
      state.lookOffset = { x: 0, y: 0 };
    }
  }

  // Organic Gaze Tracking
  if (!newState.typing) {
    const now = performance.now();
    
    // Distraction logic: Every ~8-12 seconds, lose interest for 2-3 seconds
    if (now > (state.nextDistractionAt || 0)) {
        state.isDistracted = Math.random() < 0.25;
        state.nextDistractionAt = now + (state.isDistracted ? 1500 : 4000 + Math.random() * 4000);
    }

    if (state.isDistracted) {
        // Look somewhere random or at a 'phantom' object
        if (!state.distractionOffset) {
            state.distractionOffset = { x: (Math.random() - 0.5) * 40, y: (Math.random() - 0.5) * 20 };
        }
        state.lookOffset.x += (state.distractionOffset.x - state.lookOffset.x) * 0.05;
        state.lookOffset.y += (state.distractionOffset.y - state.lookOffset.y) * 0.05;
    } else {
        state.distractionOffset = null;
        const targetX = (newState.mouseX - 0.5) * 60;
        const targetY = (0.5 - newState.mouseY) * 20;
        
        // Dampened lazy follow, tuned to feel alive without snapping.
        const ease = 0.055; 
        state.lookOffset.x += (targetX - state.lookOffset.x) * ease;
        state.lookOffset.y += (targetY - state.lookOffset.y) * ease;
        
        // Add soft micro-saccades. Keep this tiny so the closed notch does not jitter.
        state.lookOffset.x += (Math.sin(now * 0.006) * 0.45);
        state.lookOffset.y += (Math.cos(now * 0.007) * 0.35);
    }
  }

  if (state.isTranscribing !== newState.transcribing) {
    setTranscriptionMode(newState.transcribing ? "transcribing" : "idle");
  }

  // Thermal state (Overheat)
  state.isHot = newState.hot;
  state.isTranscribing = newState.transcribing;
  
  if (state.isIdle !== newState.idle) {
    if (newState.idle) {
      // Get bored/sleepy
      VE.emotions.tiredness = 95;
      VE.emotions.stimulation = 5;
    } else {
      // Wake up!
      VE.emotions.tiredness = 10;
      VE.emotions.stimulation = 50;
      if (typeof wakePet === "function") wakePet();
    }
    state.isIdle = newState.idle;
  }

  state.isMusicPlaying = newState.playing;
  state.isTyping = newState.typing;
}

window.AndyNotch = {
  setTranscriptionMode,
  setSystemState,
  interact,
};

// ---- Emotion & mood update ----
function updateNeeds(now) {
  const dt = Math.min(0.15, Math.max(0, (now - state.lastNeedUpdateAt) / 1000));
  state.lastNeedUpdateAt = now;
  const idleSeconds = (now - state.lastInteractionAt) / 1000;
  
  VE.updateEmotions(dt, { idleSeconds, windowBlurred: state.windowBlurred });
  VE.updateCursorTracking();
  if (VE.cursorTrack.isNear && !state.windowBlurred) VE.onInteraction("mouse_near");
  
  // --- Gaze & cliff detection ---
  const hitEdge = VE.updateGaze(now);
  if (hitEdge && state.animQueue.length === 0 && state.mood !== "sleeping") {
    playBehaviorCategory("cliff_react");
    VE.gazeState.targetDirX *= -0.5; // back away from edge
    VE.gazeState.targetDirY *= -0.5;
  }
  
  // --- Self-amusement check ---
  if (VE.checkSelfAmuse(now) && state.animQueue.length === 0 && state.mood !== "sleeping") {
    const amuseType = Math.random();
    if (amuseType < 0.35) playBehaviorCategory("dance_full");
    else if (amuseType < 0.55) playBehaviorCategory("keepaway_game");
    else if (amuseType < 0.7) playBehaviorCategory("fistbump_game");
    else if (amuseType < 0.85) playBehaviorCategory("face_react");
    else playBehaviorCategory("referencing");
    setTimeout(() => VE.finishAmuse(), 8000);
  }
  
  const newMood = VE.deriveMood();
  
  // --- Sleep/wake transitions ---
  if (newMood === "sleeping" && state.mood !== "sleeping") {
    state.wasAsleep = true;
    const hour = new Date().getHours();
    // Goodnight greeting before sleep
    if (hour >= 21 || hour < 5) {
      const nightAnims = findAnimationIndices("greeting_goodnight");
      if (nightAnims.length > 0) state.animQueue.push(randFrom(nightAnims));
    }
    const sleepGetin = findAnimationIndices("gotosleep_getin");
    const sleepLoop = findAnimationIndices("gotosleep_sleeping");
    if (sleepGetin.length > 0) state.animQueue.push(randFrom(sleepGetin));
    if (sleepLoop.length > 0) { for (let i = 0; i < 4; i++) state.animQueue.push(randFrom(sleepLoop)); }
    if (state.animQueue.length > 0) playNextAnimation();
  }
  
  if (state.wasAsleep && newMood !== "sleeping" && newMood !== "sleepy") {
    state.wasAsleep = false;
    const wakeAnims = findAnimationIndices("gotosleep_getout");
    const wakeupAnims = findAnimationIndices("gotosleep_wakeup");
    if (wakeAnims.length > 0) state.animQueue.unshift(randFrom(wakeAnims));
    if (wakeupAnims.length > 0) state.animQueue.push(randFrom(wakeupAnims));
  }
  
  // --- Time-of-day greetings ---
  const today = new Date().getDate();
  const hour = new Date().getHours();
  if (!state.greetedToday && today !== state.lastGreetingDay && hour >= 6 && hour < 10) {
    state.greetedToday = true;
    state.lastGreetingDay = today;
    const morningAnims = findAnimationIndices("greeting_goodmorning");
    if (morningAnims.length > 0) state.animQueue.unshift(randFrom(morningAnims));
  }
  
  // --- Return greeting (window refocus after long absence) ---
  if (state.justReturnedFromBlur && !state.windowBlurred) {
    state.justReturnedFromBlur = false;
    const helloAnims = findAnimationIndices("greeting_hello");
    const imhomeAnims = findAnimationIndices("greeting_imhome");
    const greetPool = [...helloAnims, ...imhomeAnims];
    if (greetPool.length > 0 && state.animQueue.length === 0) {
      state.animQueue.push(randFrom(greetPool));
      playNextAnimation();
    }
  }
  
  // --- Mood transition ---
  if (newMood !== state.mood) {
    state.prevMood = state.mood;
    state.mood = newMood;
    if (moodLabel) moodLabel.textContent = newMood.charAt(0).toUpperCase() + newMood.slice(1);
    if (state.animQueue.length === 0) playNextAnimation();
  }
  
  if (statusReadout) {
    const e = VE.emotions;
    statusReadout.textContent = `${state.mood}  stim:${Math.round(e.stimulation)} hap:${Math.round(e.happiness)} conf:${Math.round(e.confidence)} soc:${Math.round(e.social)} tire:${Math.round(e.tiredness)} calm:${Math.round(e.calmness)}`;
  }
}

// ---- Interaction ----
function interact(type) {
  const now = performance.now();
  const rapid = now - state.lastClickAt < 600;
  state.lastInteractionAt = now;
  state.lastClickAt = now;
  state.clickCount++;
  
  if (type === "tap") {
    VE.onInteraction(rapid ? "rapid_click" : "gentle_click");
    
    // Immediate Feedback logic
    if (rapid) {
        state.pokeCount = (state.pokeCount || 0) + 1;
        if (state.pokeCount >= 3) {
            playBehaviorCategory("annoyed_react");
            state.pokeCount = 0;
        }
    } else {
        state.pokeCount = 0; // Reset poke on gentle click
    }

    // Track for petting detection
    VE.trackPetting(now);
    if (VE.petState.isPetting && state.animQueue.length === 0) {
        VE.onInteraction("petting");
        const lvl = VE.petState.pettingLevel;
        const tag = lvl === 1 ? "petting_lvl1" : lvl === 2 ? "petting_lvl2" : "petting_blissloop";
        playBehaviorCategory(tag);
    }
    
    // Regular feedback based on mood
    if (state.clickCount % 10 === 0) {
      const e = VE.emotions;
      if (e.happiness > 70) playBehaviorCategory("feedback_positive");
      else if (e.calmness < 30) playBehaviorCategory("feedback_negative");
    }
  } else if (type === "drag") {
    VE.onInteraction("drag");
  }
  
  // Wake from sleep
  if (state.mood === "sleeping" || state.mood === "sleepy") {
    VE.emotions.tiredness = Math.max(0, VE.emotions.tiredness - 25);
    VE.emotions.stimulation = Math.min(100, VE.emotions.stimulation + 30);
  }
}

function wakePet() {
  const now = performance.now();
  if (now - state.lastInteractionAt > 3000) {
    state.lastInteractionAt = now;
    VE.onInteraction("mouse_move");
  }
}

// ---- Animation interpolation ----
function trackValue(track, time, fallback) {
  if (!track || track.length === 0) return fallback;
  let prev = track[0], next = track[track.length - 1];
  for (let i = 0; i < track.length; i++) {
    if (track[i].triggerTime_ms <= time) prev = track[i];
    if (track[i].triggerTime_ms >= time) { next = track[i]; break; }
  }
  if (prev === next) return prev;
  const span = Math.max(1, next.triggerTime_ms - prev.triggerTime_ms);
  const amount = ease(clamp((time - prev.triggerTime_ms) / span, 0, 1));
  return interpolateFrame(prev, next, amount);
}

function interpolateFrame(a, b, amount) {
  if (a.Name === "HeadAngleKeyFrame") return { angle_deg: lerp(a.angle_deg || 0, b.angle_deg || 0, amount) };
  if (a.Name === "LiftHeightKeyFrame") return { height_mm: lerp(a.height_mm || 0, b.height_mm || 0, amount) };
  const frame = { ...a };
  frame.leftEye = a.leftEye.map((v, i) => lerp(v, b.leftEye[i] ?? v, amount));
  frame.rightEye = a.rightEye.map((v, i) => lerp(v, b.rightEye[i] ?? v, amount));
  frame.faceCenterX = lerp(a.faceCenterX || 0, b.faceCenterX || 0, amount);
  frame.faceCenterY = lerp(a.faceCenterY || 0, b.faceCenterY || 0, amount);
  frame.faceScaleX = lerp(a.faceScaleX || 1, b.faceScaleX || 1, amount);
  frame.faceScaleY = lerp(a.faceScaleY || 1, b.faceScaleY || 1, amount);
  frame.faceAngle = lerp(a.faceAngle || 0, b.faceAngle || 0, amount);
  return frame;
}

function cloneFaceFrame(f) {
  return { ...f, leftEye: f.leftEye.slice(), rightEye: f.rightEye.slice() };
}

function smoothFaceFrame(target, now) {
  if (!target) return null;
  if (!state.smoothedFace) { state.smoothedFace = cloneFaceFrame(target); state.lastRenderAt = now; return state.smoothedFace; }
  const dt = clamp(now - state.lastRenderAt, 0, 80);
  state.lastRenderAt = now;
  const amount = 1 - Math.exp(-dt / 72);
  state.smoothedFace = interpolateFrame(state.smoothedFace, target, amount);
  return state.smoothedFace;
}

// ---- Drawing ----
function drawRoundedRect(context, x, y, w, h, radius) {
  const r = Math.min(radius, w / 2, h / 2);
  context.beginPath();
  context.moveTo(x + r, y);
  context.arcTo(x + w, y, x + w, y + h, r);
  context.arcTo(x + w, y + h, x, y + h, r);
  context.arcTo(x, y + h, x, y, r);
  context.arcTo(x, y, x + w, y, r);
  context.closePath();
}

function drawEyeShape(context, width, height, params) {
  const liX = clamp(params[5] ?? 0.6, 0, 1), liY = clamp(params[6] ?? 0.6, 0, 1);
  const uiX = clamp(params[7] ?? 0.6, 0, 1), uiY = clamp(params[8] ?? 0.6, 0, 1);
  const uoX = clamp(params[9] ?? 0.6, 0, 1), uoY = clamp(params[10] ?? 0.6, 0, 1);
  const loX = clamp(params[11] ?? 0.6, 0, 1), loY = clamp(params[12] ?? 0.6, 0, 1);
  const tl = 4 + Math.max(uiX, uiY) * 9, tr = 4 + Math.max(uoX, uoY) * 9;
  const br = 4 + Math.max(loX, loY) * 9, bl = 4 + Math.max(liX, liY) * 9;
  const x = -width / 2, y = -height / 2;
  context.beginPath();
  context.moveTo(x + tl, y);
  context.lineTo(x + width - tr, y);
  context.quadraticCurveTo(x + width, y, x + width, y + tr);
  context.lineTo(x + width, y + height - br);
  context.quadraticCurveTo(x + width, y + height, x + width - br, y + height);
  context.lineTo(x + bl, y + height);
  context.quadraticCurveTo(x, y + height, x, y + height - bl);
  context.lineTo(x, y + tl);
  context.quadraticCurveTo(x, y, x + tl, y);
  context.closePath();
}

function drawLid(context, width, height, amount, angle, side) {
  if (amount <= 0.01) return;
  const cover = height * clamp(amount, 0, 1);
  context.save();
  context.rotate(angle * 0.38);
  context.fillStyle = "#000000";
  context.beginPath();
  // Use a slightly larger rectangle to ensure glow coverage
  if (side === "top") context.rect(-width * 1.6, -height / 2 - 12, width * 3.2, cover + 12.5);
  else context.rect(-width * 1.6, height / 2 - cover - 0.5, width * 3.2, cover + 12);
  context.fill();
  context.restore();
}

function drawEye(context, params, side, mood, pulse) {
  const centerX = params[0] * 3.0 + VE.saccadeState.offsetX;
  let centerY = params[1] * 2.25 + VE.saccadeState.offsetY;
  
  // Cursor tracking offset
  const trackX = (VE.cursorTrack.smoothX - 0.5) * 6;
  const trackY = (VE.cursorTrack.smoothY - 0.5) * 3;
  
  const scaleX = clamp(params[2] || 1, 0.28, 2.2);
  const scaleY = clamp(params[3] || 1, 0.1, 1.8);
  const rawScale = (scaleX + scaleY) / 2;
  const eyeScale = clamp(1 + (rawScale - 1) * 0.42, 0.82, 1.36);
  const angle = (clamp(params[4] || 0, -14, 14) * Math.PI) / 180;
  let upperLid = clamp(params[13] || 0, 0, 1);
  const upperLidAngle = ((params[14] || 0) * Math.PI) / 180;
  let lowerLid = clamp(params[16] || 0, 0, 1);
  const lowerLidAngle = ((params[17] || 0) * Math.PI) / 180;
  const glow = clamp((params[21] || 0) + (params[24] || 0) + 0.35, 0.15, 1.2);
  const hotspotX = clamp(params[22] || 0, -1, 1);
  const hotspotY = clamp(params[23] || 0, -1, 1);

  // Apply blink overlay
  const blinkAmt = VE.blinkState.blinkProgress;
  upperLid = Math.max(upperLid, blinkAmt * 0.95);

  let width = 28 * eyeScale;
  let height = 28 * eyeScale;

  // Mood-based eye shape adjustments
  if (mood === "happy" || mood === "content" || mood === "affectionate") {
    height *= 0.84; width *= 1.05;
  }
  if (mood === "sleeping" || mood === "sleepy") {
    height *= 0.38; centerY += 6;
  }
  if (mood === "excited") {
    width *= 1.08; height *= 1.04;
  }
  if (mood === "sad") {
    height *= 0.9;
  }

  context.save();
  context.translate(centerX + trackX, centerY + trackY);
  context.rotate(angle);
  context.shadowColor = "rgba(18, 229, 229, 0.45)";
  context.shadowBlur = 2 + glow * 2 + pulse;
  
  const eyeGrad = context.createRadialGradient(hotspotX * width * 0.25, hotspotY * height * 0.25, 2, 0, 0, width * 0.75);
  eyeGrad.addColorStop(0, "#b9ffff");
  eyeGrad.addColorStop(0.28, (mood === "sleeping" || mood === "sleepy") ? "#5ce0e0" : "#5ffafa");
  eyeGrad.addColorStop(1, "#00cdd0");
  context.fillStyle = eyeGrad;
  drawEyeShape(context, width, height, params);
  context.fill();

  // Highlight
  context.globalAlpha = 0.3;
  context.fillStyle = "#e9ffff";
  if (height > 18 && upperLid < 0.55) {
    drawRoundedRect(context, -width * 0.18 + hotspotX * width * 0.1, -height * 0.24 + hotspotY * height * 0.1, width * 0.36, height * 0.13, 2);
    context.fill();
  }
  context.globalAlpha = 1;
  context.shadowBlur = 0;
  drawLid(context, width, height, upperLid, upperLidAngle, "top");
  drawLid(context, width, height, lowerLid, lowerLidAngle, "bottom");
  context.restore();
}

function normalizeFaceForDisplay(face) {
  const safe = cloneFaceFrame(face);
  const minGap = 13.5;
  const lx = safe.leftEye[0], rx = safe.rightEye[0];
  if (lx - rx < minGap) {
    const center = (lx + rx) / 2;
    safe.leftEye[0] = center + minGap / 2;
    safe.rightEye[0] = center - minGap / 2;
  }
  safe.leftEye[2] = clamp(safe.leftEye[2], 0.55, 1.55);
  safe.leftEye[3] = clamp(safe.leftEye[3], 0.55, 1.55);
  safe.rightEye[2] = clamp(safe.rightEye[2], 0.55, 1.55);
  safe.rightEye[3] = clamp(safe.rightEye[3], 0.55, 1.55);
  return safe;
}

function drawEye(context, params, side, mood, pulse, isListening) {
  if (isListening) {
    const now = performance.now();
    context.save();
    context.strokeStyle = "#5ffafa";
    context.lineWidth = 3;
    context.lineCap = "round";
    context.shadowColor = "rgba(18, 229, 229, 0.8)";
    context.shadowBlur = 6;
    context.beginPath();
    for (let i = -14; i <= 14; i += 4) {
      const h = Math.sin(now * 0.015 + i * 0.4) * 10 * (0.4 + Math.random() * 0.6);
      context.moveTo(i, -h);
      context.lineTo(i, h);
    }
    context.stroke();
    context.restore();
    return;
  }

  const centerX = params[0] * 3.0 + VE.saccadeState.offsetX;
  let centerY = params[1] * 2.25 + VE.saccadeState.offsetY;
  const scaleX = clamp(params[2] || 1, 0.28, 2.2);
  const scaleY = clamp(params[3] || 1, 0.1, 1.8);
  const rawScale = (scaleX + scaleY) / 2;
  const eyeScale = clamp(1 + (rawScale - 1) * 0.42, 0.82, 1.36);
  const angle = (clamp(params[4] || 0, -14, 14) * Math.PI) / 180;
  let upperLid = clamp(params[13] || 0, 0, 1);
  const upperLidAngle = ((params[14] || 0) * Math.PI) / 180;
  let lowerLid = clamp(params[16] || 0, 0, 1);
  const lowerLidAngle = ((params[17] || 0) * Math.PI) / 180;
  const glow = clamp((params[21] || 0) + (params[24] || 0) + 0.35, 0.15, 1.2);
  const hotspotX = clamp(params[22] || 0, -1, 1);
  const hotspotY = clamp(params[23] || 0, -1, 1);
  const blinkAmt = VE.blinkState.blinkProgress;
  upperLid = Math.max(upperLid, blinkAmt * 0.95);
  let width = 28 * eyeScale;
  let height = 28 * eyeScale;
  const alivePulse = Math.sin(performance.now() / 680 + (side === "left" ? 0 : 0.35)) * 0.018;
  width *= 1 + alivePulse;
  height *= 1 - alivePulse * 0.55;
  if (mood === "happy" || mood === "content" || mood === "affectionate") { height *= 0.84; width *= 1.05; }
  if (mood === "sleeping" || mood === "sleepy") { height *= 0.38; centerY += 6; }
  if (mood === "excited") { width *= 1.08; height *= 1.04; }
  if (mood === "sad") { height *= 0.9; }

  context.save();
  const floatY = Math.sin(performance.now() / 1100 + (side === "left" ? 0.4 : 0.9)) * 0.28;
  context.translate(centerX, centerY + floatY);
  context.rotate(angle);
  context.shadowColor = "rgba(18, 229, 229, 0.45)";
  context.shadowBlur = 2 + glow * 2 + pulse;
  const eyeGrad = context.createRadialGradient(hotspotX * width * 0.25, hotspotY * height * 0.25, 2, 0, 0, width * 0.75);
  eyeGrad.addColorStop(0, "#b9ffff");
  eyeGrad.addColorStop(0.28, (mood === "sleeping" || mood === "sleepy") ? "#5ce0e0" : "#5ffafa");
  eyeGrad.addColorStop(0.75, (mood === "sleeping" || mood === "sleepy") ? "#298282" : "#32e5e5");
  eyeGrad.addColorStop(1, "rgba(18, 229, 229, 0)");
  context.fillStyle = eyeGrad;
  drawEyeShape(context, width, height, params);
  context.fill();
  context.save();
  drawEyeShape(context, width, height, params);
  context.clip();
  drawLid(context, width, height, upperLid, upperLidAngle, "top");
  drawLid(context, width, height, lowerLid, lowerLidAngle, "bottom");
  context.restore();

  // Final cleanup: Stroke the eye shape with black to cover any glowing "leaks" at the edges
  context.strokeStyle = "#000000";
  context.lineWidth = 1.5;
  drawEyeShape(context, width, height, params);
  context.stroke();
  
  context.restore();
}

function drawFace(context, now, face, mood, pulse, scale) {
  const safe = normalizeFaceForDisplay(face);
  const breath = VE.getBreathScale(now * (state.isHot ? 2.0 : 1.0));
  
  // Music/Transcription effects...
  let beatY = 0;
  let beatScale = 1.0;
  
  if (state.isMusicPlaying && !state.isTranscribing) {
    const bpm = state.isHot ? 160 : 124;
    const msPerBeat = 60000 / bpm;
    const phase = (now % msPerBeat) / msPerBeat;
    const bounce = Math.pow(1.0 - phase, 2.5);
    beatY = -bounce * (state.isHot ? 14 : 10); 
    beatScale += bounce * (state.isHot ? 0.25 : 0.15);
  }

  const isPerforming = state.animQueue.length > 0 || (state.animation && state.animation.duration > 2000);
  const targetLookX = isPerforming ? 0 : (state.lookOffset?.x || 0);
  const targetLookY = isPerforming ? 0 : (state.lookOffset?.y || 0);
  const idleAmount = isPerforming ? 0.35 : 1.0;
  const targetSwayX = Math.sin(now / 2400) * 0.9 * idleAmount;
  const targetSwayY = Math.sin(now / 1700 + 0.8) * 0.7 * idleAmount;
  const targetTilt = Math.sin(now / 3600 + 0.4) * 0.018 * idleAmount;
  const targetSquash = 1 + Math.sin(now / 1900) * 0.012 * idleAmount;

  const poseEase = isPerforming ? 0.08 : 0.12;
  state.renderPose.lookX += (targetLookX - state.renderPose.lookX) * poseEase;
  state.renderPose.lookY += (targetLookY - state.renderPose.lookY) * poseEase;
  state.renderPose.swayX += (targetSwayX - state.renderPose.swayX) * 0.06;
  state.renderPose.swayY += (targetSwayY - state.renderPose.swayY) * 0.06;
  state.renderPose.tilt += (targetTilt - state.renderPose.tilt) * 0.05;
  state.renderPose.squash += (targetSquash - state.renderPose.squash) * 0.08;

  context.save();
  context.translate(
    safe.faceCenterX * 1.1 + state.renderPose.swayX,
    (safe.faceCenterY * 0.78) + beatY + state.renderPose.swayY
  );
  context.rotate(clamp((safe.faceAngle || 0) + state.renderPose.tilt, -0.2, 0.2));
  
  const finalScale = scale * 1.15 * breath * beatScale;
  context.scale(
    (safe.faceScaleX || 1) * finalScale * state.renderPose.squash,
    (safe.faceScaleY || 1) * finalScale / Math.sqrt(state.renderPose.squash)
  );

  context.translate(state.renderPose.lookX, state.renderPose.lookY);

  drawEye(context, safe.leftEye, "left", mood, pulse, state.isTranscribing);
  drawEye(context, safe.rightEye, "right", mood, pulse, state.isTranscribing);
  
  if (state.isHot) {
    context.fillStyle = "#5ffafa";
    const sweat = (now % 1000) / 1000;
    context.fillRect(-20, -10 + sweat * 20, 2, 4);
    context.fillRect(20, -15 + ((now + 500) % 1000) / 1000 * 20, 2, 4);
  }
  
  context.restore();
}

function drawFaceScreen(context, width, height, face, mood, pulse) {
  context.save();
  context.fillStyle = "#000000";
  context.fillRect(0, 0, width, height);
  
  // Subtle scanlines
  context.fillStyle = "rgba(18, 229, 229, 0.02)";
  for (let i = 0; i < height / 4; i++) context.fillRect(0, i * 4, width, 1);
  
  // Slightly more generous scaling for the small notch mode
  const scale = Math.min(width / 123, height / 84); // Adjusted to pull Andy back ~11.5% for perfect notch crop
  context.translate(width / 2, height / 2);
  drawFace(context, performance.now(), face, mood, pulse, scale);
  context.restore();
  drawTranscriptionOverlay(context, width, height);
}

function roundRect(context, x, y, width, height, radius) {
  if (context.roundRect) {
    context.beginPath();
    context.roundRect(x, y, width, height, radius);
    return;
  }

  const r = Math.min(radius, width / 2, height / 2);
  context.beginPath();
  context.moveTo(x + r, y);
  context.arcTo(x + width, y, x + width, y + height, r);
  context.arcTo(x + width, y + height, x, y + height, r);
  context.arcTo(x, y + height, x, y, r);
  context.arcTo(x, y, x + width, y, r);
  context.closePath();
}

function drawTranscriptionOverlay(context, width, height) {
  const now = performance.now();
  const target = state.transcription.mode === "idle" ? 0 : 1;
  const dt = Math.min(80, Math.max(0, now - state.transcription.lastVisualAt));
  state.transcription.lastVisualAt = now;

  const duration = target > state.transcription.visualAmount ? 140 : 220;
  const amount = 1 - Math.exp(-dt / duration);
  state.transcription.visualAmount += (target - state.transcription.visualAmount) * amount;

  if (state.transcription.visualAmount < 0.01) {
    state.transcription.visualAmount = 0;
    if (state.transcription.mode === "idle") state.transcription.visibleMode = "idle";
    return;
  }

  const mode = state.transcription.visibleMode;
  const elapsed = now - state.transcription.startedAt;
  const centerX = width / 2;
  const visualAmount = ease(state.transcription.visualAmount);
  const y = height * (0.72 + (1 - visualAmount) * 0.025);

  context.save();
  context.shadowColor = "rgba(18, 229, 229, 0.38)";
  context.shadowBlur = 6 + 8 * visualAmount;
  context.fillStyle = "rgba(82, 250, 250, 0.9)";
  context.globalAlpha = visualAmount;

  if (mode === "listening") {
    const bars = 7;
    const gap = Math.max(5, width * 0.012);
    const barWidth = Math.max(3, width * 0.008);
    const total = bars * barWidth + (bars - 1) * gap;
    const startX = centerX - total / 2;

    for (let i = 0; i < bars; i++) {
      const wave = Math.sin(elapsed / 120 + i * 0.72);
      const h = height * (0.035 + Math.abs(wave) * 0.055);
      const x = startX + i * (barWidth + gap);
      roundRect(context, x, y - (h * visualAmount) / 2, barWidth, h * visualAmount, barWidth / 2);
      context.fill();
    }
  } else if (mode === "transcribing") {
    const dots = 3;
    const radius = Math.max(4.5, Math.min(width, height) * 0.062) * (0.75 + 0.25 * visualAmount);
    const gap = radius * 3.05;

    for (let i = 0; i < dots; i++) {
      const phase = Math.max(0, Math.sin(elapsed / 230 + i * 0.92));
      const breathe = 0.84 + 0.16 * phase;
      context.globalAlpha = visualAmount * (0.36 + 0.52 * phase);
      context.beginPath();
      context.arc(centerX + (i - 1) * gap, y - phase * radius * 1.45, radius * breathe, 0, Math.PI * 2);
      context.fill();
    }
  }

  context.restore();
}

function drawPet(now) {
  const rect = canvas.getBoundingClientRect();
  const width = rect.width, height = rect.height;
  ctx.clearRect(0, 0, width, height);
  
  if (!state.animation) return;
  
  const elapsed = now - state.startedAt;
  const animTime = elapsed % state.animation.duration;
  const face = smoothFaceFrame(trackValue(state.animation.tracks.face, animTime, null), now);
  const pulse = (Math.sin(now / 260) + 1) / 2;
  
  if (face) drawFaceScreen(ctx, width, height, face, state.mood, pulse);
  drawTranscriptionOverlay(ctx, width, height);
}

// ---- Render loop ----
function render(now) {
  updateNeeds(now);
  VE.updateBlink(now);
  VE.updateSaccade(now);
  
  if (state.autoPlay && state.animation && now > state.nextAnimationAt) {
    playNextAnimation();
  }
  drawPet(now);
  requestAnimationFrame(render);
}

// ---- Event listeners ----
if (animationSelect) animationSelect.addEventListener("change", () => {
  state.autoPlay = true;
  loadAnimation(Number(animationSelect.value)).catch(showLoadError);
});

moodButtons.forEach(btn => btn.addEventListener("click", () => {
  // Force mood emotion axes
  const m = btn.dataset.mood;
  if (m === "happy") { VE.emotions.happiness = 80; VE.emotions.social = 60; }
  else if (m === "sleepy") { VE.emotions.tiredness = 90; VE.emotions.stimulation = 10; }
  else if (m === "curious") { VE.emotions.stimulation = 55; VE.emotions.confidence = 60; }
}));

if (energyRange) energyRange.addEventListener("input", () => {
  VE.emotions.stimulation = Number(energyRange.value);
});

if (tapButton) tapButton.addEventListener("click", () => interact("tap"));
if (napButton) napButton.addEventListener("click", () => {
  VE.emotions.tiredness = 90;
  VE.emotions.stimulation = 10;
});
if (randomButton) randomButton.addEventListener("click", () => playNextAnimation());
if (idleButton) idleButton.addEventListener("click", () => {
  VE.emotions.stimulation = 40; VE.emotions.happiness = 50;
  VE.emotions.confidence = 60; VE.emotions.social = 40;
  VE.emotions.tiredness = 10; VE.emotions.calmness = 70;
});
if (faceModeButton) faceModeButton.addEventListener("click", () => {
  state.faceOnly = !state.faceOnly;
  faceModeButton.textContent = state.faceOnly ? "Show body" : "Face only";
});

canvas.addEventListener("pointerdown", (event) => {
  canvas.setPointerCapture(event.pointerId);
  interact("tap");
});
canvas.addEventListener("pointerup", (event) => {
  canvas.releasePointerCapture(event.pointerId);
});

// Track mouse position for eye following + shake detection
window.addEventListener("mousemove", (event) => {
  const now = performance.now();
  VE.cursorTrack.mouseX = event.clientX / window.innerWidth;
  VE.cursorTrack.mouseY = event.clientY / window.innerHeight;
  
  // Shake detection
  const shakeTriggered = VE.trackMouseForShake(event.clientX, event.clientY, now);
  if (shakeTriggered && state.animQueue.length === 0) {
    VE.onInteraction("shake");
    const intensity = VE.shakeState.intensity;
    if (intensity >= 3) playBehaviorCategory("shake_react");
    else if (intensity >= 2) playBehaviorCategory("pickup_react");
    else playBehaviorCategory("heldonpalm");
  }
  wakePet();
});

window.addEventListener("keydown", () => {
  VE.onInteraction("typing");
  wakePet();
});

let blurStartedAt = 0;
window.addEventListener("focus", () => {
  const blurDuration = performance.now() - blurStartedAt;
  state.windowBlurred = false;
  VE.onInteraction("window_focus");
  // If away for more than 5 minutes, play return greeting
  if (blurDuration > 300000) {
    state.justReturnedFromBlur = true;
  }
});
window.addEventListener("blur", () => {
  state.windowBlurred = true;
  blurStartedAt = performance.now();
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    state.windowBlurred = true;
    blurStartedAt = performance.now();
  } else {
    const blurDuration = performance.now() - blurStartedAt;
    state.windowBlurred = false;
    VE.onInteraction("window_focus");
    if (blurDuration > 300000) state.justReturnedFromBlur = true;
  }
});

window.addEventListener("resize", resizeCanvas);

window.addEventListener("unload", () => {
  if (window.innerWidth < 200) {
    localStorage.setItem("closedNotchUnmountedAt", Date.now());
  } else {
    localStorage.setItem("expandedTabUnmountedAt", Date.now());
  }
});

function showLoadError(error) {
  if (animationLabel) animationLabel.textContent = "asset load failed";
  console.error(error);
}

// ---- Start ----
async function start() {
  resizeCanvas();
  
  // Request initial system state (music, typing, etc.)
  try { window.webkit.messageHandlers.andyRequestSystemState.postMessage(""); } catch(e) {}

  await loadAnimationIndex();
  
  // Start with a wakeup or idle animation
  const hour = new Date().getHours();
  let startAnims;
  
  const now = Date.now();
  const isClosedNotch = window.innerWidth < 200;
  const closedUnmountedAt = parseInt(localStorage.getItem("closedNotchUnmountedAt") || "0");
  const expandedUnmountedAt = parseInt(localStorage.getItem("expandedTabUnmountedAt") || "0");
  
  // If booting in closed notch, and he was unmounted previously (not first boot)
  // And it wasn't just because the user closed the expanded tab
  if (isClosedNotch && closedUnmountedAt > 0 && (now - expandedUnmountedAt) > 2000) {
    // He was displaced by music, mic, or hover!
    VE.emotions.calmness = 15;
    VE.emotions.social = 40;
    VE.emotions.happiness = 20;
    VE.emotions.stimulation = 70;
    startAnims = findAnimationIndices("annoyed_react");
  } else if (hour >= 6 && hour < 10) {
    const todayStr = new Date().toDateString();
    const lastWakeupDate = localStorage.getItem("lastWakeupDate");
    if (lastWakeupDate !== todayStr) {
      startAnims = findAnimationIndices("onboarding_wakeup");
      localStorage.setItem("lastWakeupDate", todayStr);
    }
  }
  if (!startAnims || startAnims.length === 0) {
    startAnims = findAnimationIndices("keepalive_eyes");
  }
  if (!startAnims || startAnims.length === 0) {
    startAnims = findAnimationIndices("eyepose_curious");
  }
  
  const startIdx = startAnims.length > 0 ? startAnims[0] : 0;
  await loadAnimation(startIdx).catch(showLoadError);
  requestAnimationFrame(render);
}

start();
