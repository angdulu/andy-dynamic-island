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
  moodCandidate: "idle",
  moodCandidateSince: performance.now(),
  daysKnown: 1,
  firstSeenAt: 0,
  lastSeenDay: null,
  transcription: {
    // idle → arming → listening → thinking → success | error → idle
    phase: "idle",
    visiblePhase: "idle",
    phaseAmount: 0,          // eased presence of the active phase, 0..1
    startedAt: 0,
    resolveAt: 0,            // when success/error falls back to idle
    thinkMorph: 0,           // eased 0..1 blend into the three-dot loader
    rawLevel: 0,             // newest mic level from Swift, 0..1
    level: 0,                // smoothed level (fast attack, slow release)
    history: [],             // rolling amplitude window for the bar strip
    lastVisualAt: performance.now(),
    lastLevelAt: performance.now(),
  },
};

const VOICE_PHASES = ["arming", "listening", "thinking", "success", "error"];
const VOICE_RESOLVE_MS = 900;
const VOICE_HISTORY_LEN = 7;
const MOOD_DWELL_MS = 1200;

// ---- Thinking loader ----
// Andy's two eyes slide into the outer slots and a third dot fades in between
// them, so the loading state is still him rather than a spinner drawn nearby.
const LOADER_SLOT_X = [-27, 0, 27];
const LOADER_DOT_SIZE = 19;
const LOADER_BOUNCE_H = 8.5;
const LOADER_CYCLE_MS = 640;

function loaderBounce(now, index) {
  // Half-sine hop with a rest between, staggered left → right.
  const phase = ((now / LOADER_CYCLE_MS) - index * 0.17) % 1;
  const p = phase < 0 ? phase + 1 : phase;
  return -Math.max(0, Math.sin(p * Math.PI * 2)) * LOADER_BOUNCE_H;
}

// ---- Persistence ----
// Andy used to be reborn with default emotions on every launch and every
// reload. Carrying the axes across sessions is what turns a mood simulation
// into a pet you have a history with. localStorage matches how the rest of this
// file already persists (lastWakeupDate, closedNotchUnmountedAt).
const SAVE_KEY = "andyPetState_v1";
const EMOTION_BASELINE = {
  stimulation: 35, happiness: 45, confidence: 55,
  social: 30, tiredness: 0, calmness: 65,
};

function savePetState() {
  try {
    localStorage.setItem(SAVE_KEY, JSON.stringify({
      emotions: VE.emotions,
      savedAt: Date.now(),
      firstSeenAt: state.firstSeenAt,
      daysKnown: state.daysKnown,
      lastSeenDay: state.lastSeenDay,
    }));
  } catch (e) { /* private mode / quota — carry on with defaults */ }
}

function loadPetState() {
  const today = new Date().toDateString();
  let saved = null;
  try { saved = JSON.parse(localStorage.getItem(SAVE_KEY) || "null"); } catch (e) {}

  if (!saved || typeof saved !== "object") {
    state.firstSeenAt = Date.now();
    state.daysKnown = 1;
    state.lastSeenDay = today;
    return;
  }

  // Settle the axes toward baseline for however long we were away, and let
  // tiredness recover — he was resting, not sitting there getting tired.
  const hoursAway = Math.max(0, (Date.now() - (saved.savedAt || Date.now())) / 3600000);
  const settled = 1 - Math.exp(-hoursAway / 2);
  for (const key of Object.keys(VE.emotions)) {
    const from = typeof saved.emotions?.[key] === "number" ? saved.emotions[key] : VE.emotions[key];
    VE.emotions[key] = clamp(lerp(from, EMOTION_BASELINE[key], settled), 0, 100);
  }

  state.firstSeenAt = saved.firstSeenAt || Date.now();
  state.daysKnown = saved.daysKnown || 1;
  state.lastSeenDay = saved.lastSeenDay || null;
  if (state.lastSeenDay !== today) {
    state.daysKnown += 1;
    state.lastSeenDay = today;
  }
}

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

  // Animals hold still for long stretches and then move for a reason. Swapping
  // a clip every few seconds is what makes him read as a screensaver, so in the
  // calm moods he sometimes just settles instead.
  // Settling on a pose that has an eye outside the porthole is the one case
  // where holding still reads as broken rather than alive, so it doesn't
  // qualify — the guard would recentre him anyway, but not settling means the
  // clip gets swapped out instead of held for another minute.
  const canSettle = !isSlow && state.animQueue.length === 0 && !portholeGuard.offCentre &&
    (state.mood === "idle" || state.mood === "content" || state.mood === "bored");
  const settle = (canSettle && Math.random() < 0.35) ? 18000 + Math.random() * 40000 : 0;

  state.nextAnimationAt = now + animPart + baseDwell + Math.random() * randDwell + settle;
}

// ---- Helper: pick random from array ----
function randFrom(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

// ---- Play a behavior category as animation ----
function playBehaviorCategory(category) {
  // Callers pass either a behaviour key (from behaviorAnimations) or a raw path
  // substring — the petting levels are dispatched by tag. Without the second
  // lookup those silently resolved to the idle_blink fallback.
  const indices = VE.behaviorAnimations[category]
    ? VE.resolveBehaviorToAnimations(category, animations)
    : findAnimationIndices(category);
  if (indices.length > 0) {
    const idx = randFrom(indices);
    state.animQueue.push(idx);
    if (state.animQueue.length === 1) playNextAnimation();
  }
}
// Expose globally for Electron IPC calls
window.playBehaviorCategory = playBehaviorCategory;

// The voice pipeline is rendered procedurally, so it never queues clips of its
// own — that would fight the modulation in drawEye mid-sentence.
function setVoicePhase(phase) {
  const t = state.transcription;
  if (t.phase === phase) return;

  const now = performance.now();
  t.phase = phase;
  t.startedAt = now;
  if (phase !== "idle") t.visiblePhase = phase;
  t.resolveAt = (phase === "success" || phase === "error") ? now + VOICE_RESOLVE_MS : 0;

  if (phase === "arming") {
    t.history.length = 0;
    t.rawLevel = 0;
    t.level = 0;
  }

  if (phase === "listening") {
    VE.emotions.stimulation = Math.min(100, VE.emotions.stimulation + 18);
    VE.emotions.social = Math.min(100, VE.emotions.social + 8);
    VE.emotions.calmness = Math.max(0, VE.emotions.calmness - 8);
  } else if (phase === "thinking") {
    VE.emotions.stimulation = Math.min(100, VE.emotions.stimulation + 8);
  } else if (phase === "success") {
    VE.emotions.happiness = Math.min(100, VE.emotions.happiness + 10);
    VE.emotions.confidence = Math.min(100, VE.emotions.confidence + 8);
  } else if (phase === "error") {
    VE.emotions.confidence = Math.max(0, VE.emotions.confidence - 15);
    VE.emotions.happiness = Math.max(0, VE.emotions.happiness - 8);
  }
}

function isVoiceActive() {
  return VOICE_PHASES.includes(state.transcription.phase);
}

// Swift pushes raw mic amplitude; smoothing happens on the render tick so the
// visual stays stable no matter how irregular the bridge cadence is.
function setVoiceLevel(level) {
  const t = state.transcription;
  t.rawLevel = clamp(Number(level) || 0, 0, 1);
  t.lastLevelAt = performance.now();
}

function updateVoice(now) {
  const t = state.transcription;

  if (t.resolveAt && now > t.resolveAt) setVoicePhase("idle");

  // Fast attack / slow release, the way a meter needs to feel.
  const target = t.phase === "listening" ? t.rawLevel : 0;
  const rising = target > t.level;
  const dt = clamp(now - t.lastVisualAt, 0, 80);
  const tau = rising ? 45 : 190;
  t.level += (target - t.level) * (1 - Math.exp(-dt / tau));

  const active = isVoiceActive() ? 1 : 0;
  t.phaseAmount += (active - t.phaseAmount) * (1 - Math.exp(-dt / (active ? 110 : 200)));
  if (t.phaseAmount < 0.005) {
    t.phaseAmount = 0;
    if (t.phase === "idle") t.visiblePhase = "idle";
  }

  if (t.phase === "listening") {
    t.history.push(t.level);
    if (t.history.length > VOICE_HISTORY_LEN) t.history.shift();
  }

  // Eased separately from phaseAmount so leaving "thinking" unfolds back into
  // the face instead of snapping the instant the phase flips.
  const morphTarget = t.phase === "thinking" ? 1 : 0;
  const morphTau = morphTarget > t.thinkMorph ? 150 : 260;
  t.thinkMorph += (morphTarget - t.thinkMorph) * (1 - Math.exp(-dt / morphTau));
  if (t.thinkMorph < 0.002) t.thinkMorph = 0;

  t.lastVisualAt = now;
}

// Back-compat shim: earlier builds drove this with mode strings.
function setTranscriptionMode(mode) {
  if (mode === "listening") setVoicePhase("listening");
  else if (mode === "transcribing") setVoicePhase("thinking");
  else setVoicePhase("idle");
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

  // --- Voice pipeline phase, derived from the real dictation stages ---
  if (typeof newState.voiceLevel === "number") setVoiceLevel(newState.voiceLevel);

  const recording = !!newState.recording;
  const transcribing = !!newState.transcribing;
  if (recording !== state.isRecording || transcribing !== state.isTranscribing) {
    if (recording) {
      // Brief arming beat so the squint reads before the first syllable.
      if (!state.isRecording) {
        setVoicePhase("arming");
        setTimeout(() => { if (state.isRecording) setVoicePhase("listening"); }, 220);
      }
    } else if (transcribing) {
      setVoicePhase("thinking");
    } else if (newState.voiceFailed) {
      setVoicePhase("error");
    } else if (state.isTranscribing || state.isRecording) {
      // Came out of the pipeline cleanly.
      setVoicePhase("success");
    } else {
      setVoicePhase("idle");
    }
  }

  // Thermal state (Overheat)
  state.isHot = newState.hot;
  state.isRecording = recording;
  state.isTranscribing = transcribing;
  
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
  setVoicePhase,
  setVoiceLevel,
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
  if (VE.cursorTrack.enteredNear && !state.windowBlurred) VE.onInteraction("mouse_near");
  
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
  
  // A candidate mood has to hold before it commits, otherwise a single frame
  // grazing a threshold flips him and he twitches between moods.
  const rawMood = VE.deriveMood();
  if (rawMood !== state.moodCandidate) {
    state.moodCandidate = rawMood;
    state.moodCandidateSince = now;
  }
  const newMood = (now - state.moodCandidateSince >= MOOD_DWELL_MS) ? rawMood : state.mood;

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

// `roundness` lerps every corner toward a full circle, which is how the eyes
// become loader dots without needing a second shape routine.
function drawEyeShape(context, width, height, params, roundness = 0) {
  const liX = clamp(params[5] ?? 0.6, 0, 1), liY = clamp(params[6] ?? 0.6, 0, 1);
  const uiX = clamp(params[7] ?? 0.6, 0, 1), uiY = clamp(params[8] ?? 0.6, 0, 1);
  const uoX = clamp(params[9] ?? 0.6, 0, 1), uoY = clamp(params[10] ?? 0.6, 0, 1);
  const loX = clamp(params[11] ?? 0.6, 0, 1), loY = clamp(params[12] ?? 0.6, 0, 1);
  let tl = 4 + Math.max(uiX, uiY) * 9, tr = 4 + Math.max(uoX, uoY) * 9;
  let br = 4 + Math.max(loX, loY) * 9, bl = 4 + Math.max(liX, liY) * 9;
  if (roundness > 0) {
    const full = Math.min(width, height) / 2;
    tl = lerp(tl, full, roundness); tr = lerp(tr, full, roundness);
    br = lerp(br, full, roundness); bl = lerp(bl, full, roundness);
  }
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

// ---- Porthole guard (closed wing only) ----
// ClosedAndyWing draws this page at 128x80, scaleEffects it by size/80*0.93 and
// clips the result to a circle of diameter `size`. The scale and the clip cancel
// out, so the slice that reaches the screen is always 80/0.93 ≈ 86 CSS px wide
// however tall the notch is — the outer ~21px of each side never show.
const WING_VISIBLE_HALF_WIDTH = (80 / 0.93) / 2;
const PORTHOLE_GRACE_MS = 1000;
// Clips loop, and a short one can dip back into frame for a frame or two on each
// pass. Clearing the timer on that would let a 1.7s clip like
// gazing_lookatfaces_getin_left restart the grace every loop and never trigger
// the guard at all, so he has to actually hold a visible pose to earn the reset.
const PORTHOLE_RELEASE_MS = 300;

// How much of an eye may sit behind the porthole edge. Partial clipping is fine
// and is most of the peeking charm, but past roughly a third the eye stops
// reading as an eye and starts reading as a bright sliver stuck to the rim.
// The gaze budget is held to this; the guard only steps in past GUARD_EYE_CLIP,
// so the two never argue over the same boundary.
const MAX_EYE_CLIP = 0.35;
const GUARD_EYE_CLIP = 0.5;

const portholeGuard = { outSince: 0, backSince: 0, amount: 0, offCentre: false };

function isWingView() {
  return window.innerWidth < 200;
}

// Base width only: drawEye's mood and voice modifiers can widen an eye by up to
// ~8% after this, so the budget runs a few percent generous rather than tight.
function eyeHalfWidth(params) {
  const scaleX = clamp(params[2] || 1, 0.28, 2.2);
  const scaleY = clamp(params[3] || 1, 0.1, 1.8);
  const eyeScale = clamp(1 + ((scaleX + scaleY) / 2 - 1) * 0.42, 0.82, 1.36);
  return 14 * eyeScale;
}

function eyeExtentPx(params, baseX, xFactor, lookX) {
  return {
    centre: baseX + (lookX + params[0] * 3.0 + VE.saccadeState.offsetX) * xFactor,
    half: eyeHalfWidth(params) * xFactor,
  };
}

// Fraction of the eye's width that the porthole edge is covering, 0..1.
function eyeHiddenFraction(centre, half) {
  if (half <= 0) return 0;
  return clamp((Math.abs(centre) + half - WING_VISIBLE_HALF_WIDTH) / (2 * half), 0, 1);
}

// The cursor-follow amplitude — (mouseX - 0.5) * 60, so ±33px on screen — was
// tuned against the 300px panel. In an 86px porthole that same swing shoves the
// outer eye onto the rim, and unlike a clip the cursor does not move on: it
// parks wherever the mouse is left, so whichever eye is on your habitual cursor
// side stays a sliver indefinitely. The time-based guard can't help, because the
// eye never fully leaves the window and the correction only moves the pose.
//
// So rather than shrink the constant, spend exactly the gaze travel the porthole
// can afford. Derived from the live eye geometry, so it keeps adapting when the
// pose changes the spacing or the mood changes the eye size. Works out to about
// ±15 face units against the default pose, roughly half the raw swing.
function clampLookXToPorthole(safe, lookX, faceX, xFactor) {
  if (!isWingView() || xFactor <= 0) return lookX;

  let lo = -Infinity, hi = Infinity;
  for (const params of [safe.leftEye, safe.rightEye]) {
    const half = eyeHalfWidth(params) * xFactor;
    const limit = WING_VISIBLE_HALF_WIDTH - half * (1 - 2 * MAX_EYE_CLIP);
    const eyeX = params[0] * 3.0 + VE.saccadeState.offsetX;
    lo = Math.max(lo, (-limit - faceX) / xFactor - eyeX);
    hi = Math.min(hi, ( limit - faceX) / xFactor - eyeX);
  }
  // A pose spread wider than the porthole leaves no gaze that satisfies both
  // eyes. Spending the remaining budget on re-centring the pair is tempting, but
  // the guard already recentres the pose a moment later, and the two corrections
  // stack into an overshoot that throws the pair clean off the opposite rim.
  // This function owns the cursor's contribution and nothing else, so when there
  // is no room for gaze it contributes none and leaves the pose to the guard.
  if (lo > hi) return 0;
  return clamp(lookX, lo, hi);
}

// A gaze swing carrying an eye out of the porthole is the charm — he peeks. It
// *staying* out is the bug: clips loop for the whole dwell (up to ~58s once the
// settle bonus lands), so a pose like reacttocliff_stuckonedge, which sits fully
// off-window for its entire 5.3s, parks him one-eyed for a minute. Allow the
// excursion, then pull him back if he hasn't come back on his own.
//
// Recentring the pair's midpoint is enough on the shipped clip set — no clip
// needs its eye spacing clamped as well — so the pair keeps its full spread and
// only its midpoint is disciplined. Simulated over all 581 clips, the longest
// one-eyed stretch drops from indefinite (a whole dwell) to under 2s, and the
// count of clips one-eyed for most of their length goes 14 -> 4. The four that
// remain are gazing_lookatfaces_getin_left variants, which look away in ~1s
// bursts and come back on their own; that is the peeking, not the bug.
function updatePortholeGuard(safe, now, baseX, xFactor, lookX) {
  if (!isWingView()) {
    portholeGuard.outSince = 0;
    portholeGuard.backSince = 0;
    portholeGuard.amount = 0;
    portholeGuard.offCentre = false;
    return 0;
  }

  // Evaluated against the raw pose, never the corrected one. Testing the
  // corrected pose would make the guard undo its own trigger and oscillate.
  let lost = false;
  for (const params of [safe.leftEye, safe.rightEye]) {
    const eye = eyeExtentPx(params, baseX, xFactor, lookX);
    if (eyeHiddenFraction(eye.centre, eye.half) > GUARD_EYE_CLIP) { lost = true; break; }
  }
  if (lost) {
    portholeGuard.backSince = 0;
    if (portholeGuard.outSince === 0) portholeGuard.outSince = now;
  } else {
    if (portholeGuard.backSince === 0) portholeGuard.backSince = now;
    if (now - portholeGuard.backSince > PORTHOLE_RELEASE_MS) portholeGuard.outSince = 0;
  }
  // Reported to scheduleNextAnimation, so a clip that is merely between dips
  // still counts as off-centre and doesn't win the settle bonus.
  portholeGuard.offCentre = portholeGuard.outSince !== 0;

  const overdue = portholeGuard.outSince > 0 && now - portholeGuard.outSince > PORTHOLE_GRACE_MS;
  // The grace period is where the charm lives, so it gets the full second; the
  // correction itself has nothing to gain from being slow, and dragging it out
  // just extends the state we are trying to end (it cost ~1.5s of the ~3s worst
  // case on its own). ~0.4s at 30fps reads as him deciding to look forward.
  // The release stays gentle so letting go can't snap him back off-window.
  const ease = overdue ? 0.15 : 0.035;
  portholeGuard.amount += ((overdue ? 1 : 0) - portholeGuard.amount) * ease;
  if (portholeGuard.amount < 0.001) portholeGuard.amount = 0;
  return portholeGuard.amount;
}

function applyPortholeGuard(safe, amount, xFactor) {
  if (amount <= 0) return;
  // Recentre the midpoint rather than pulling each eye toward 0 — that would
  // squeeze the pair together instead of moving it.
  const mid = (safe.leftEye[0] + safe.rightEye[0]) / 2;
  const pull = mid * amount;
  safe.leftEye[0] -= pull;
  safe.rightEye[0] -= pull;
  safe.faceCenterX = lerp(safe.faceCenterX || 0, 0, amount);

  // A handful of poses (cantdothat, avs_fail) throw the eyes so far apart that a
  // perfectly centred pair still leaves both of them as slivers on opposite
  // rims — their faceCenterX is already ~0, so recentring is a no-op. Narrow the
  // spread to what the porthole can show. Nothing expressive is lost: at that
  // spread you were seeing two bright edges, not a wide-eyed face.
  if (xFactor > 0) {
    const gap = safe.leftEye[0] - safe.rightEye[0];   // leftEye holds the larger x
    const half = Math.max(eyeHalfWidth(safe.leftEye), eyeHalfWidth(safe.rightEye)) * xFactor;
    const maxGap = 2 * (WING_VISIBLE_HALF_WIDTH - half * (1 - 2 * MAX_EYE_CLIP)) / (3.0 * xFactor);
    if (gap > maxGap) {
      const target = lerp(gap, maxGap, amount);
      const centre = (safe.leftEye[0] + safe.rightEye[0]) / 2;
      safe.leftEye[0] = centre + target / 2;
      safe.rightEye[0] = centre - target / 2;
    }
  }
}

// The third dot has no eye to grow out of, so it scales up from nothing in the
// gap between the other two and shrinks away again on exit.
function drawLoaderMiddleDot(context, now, morph) {
  if (morph < 0.01) return;

  const size = LOADER_DOT_SIZE * morph;
  const y = loaderBounce(now, 1) * morph;

  context.save();
  context.translate(LOADER_SLOT_X[1], y);
  context.globalAlpha = morph;
  context.shadowColor = "rgba(18, 229, 229, 0.45)";
  context.shadowBlur = 2 + 2.2 * morph;

  const grad = context.createRadialGradient(0, 0, 2, 0, 0, size * 0.75);
  grad.addColorStop(0, "#b9ffff");
  grad.addColorStop(0.28, "#5ffafa");
  grad.addColorStop(0.75, "#32e5e5");
  grad.addColorStop(1, "rgba(18, 229, 229, 0)");
  context.fillStyle = grad;
  context.beginPath();
  context.arc(0, 0, size / 2, 0, Math.PI * 2);
  context.fill();

  // Match the eyes' edge treatment so it reads as the same material.
  context.shadowBlur = 0;
  context.strokeStyle = "#000000";
  context.lineWidth = 1.5;
  context.beginPath();
  context.arc(0, 0, size / 2, 0, Math.PI * 2);
  context.stroke();
  context.restore();
}

function drawEye(context, params, side, mood, pulse) {
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

  // --- Voice pipeline: procedural modulation driven by the live mic level.
  // Andy listens with his eyes rather than handing them over to a meter.
  const voice = state.transcription;
  const vAmt = voice.phaseAmount;
  let voiceGlow = 0;
  if (voice.phase === "arming") {
    // Narrow to a focused squint the moment capture opens.
    height *= lerp(1, 0.62, vAmt);
    lowerLid = Math.max(lowerLid, 0.18 * vAmt);
    voiceGlow = 2.5 * vAmt;
  } else if (voice.phase === "listening") {
    // Attentive base shape; your voice opens the eyes back up. Kept modest on
    // purpose — a big bloom reads as startled rather than listening.
    const lvl = voice.level;
    height *= lerp(1, 0.72 + lvl * 0.40, vAmt);
    width *= lerp(1, 1.02 + lvl * 0.06, vAmt);
    lowerLid = Math.max(lowerLid, (0.22 - lvl * 0.20) * vAmt);
    voiceGlow = (1.5 + lvl * 5.5) * vAmt;
  } else if (voice.phase === "success") {
    height *= lerp(1, 0.80, vAmt);
    width *= lerp(1, 1.08, vAmt);
    voiceGlow = 5 * vAmt;
  } else if (voice.phase === "error") {
    height *= lerp(1, 0.55, vAmt);
    upperLid = Math.max(upperLid, 0.42 * vAmt);
    voiceGlow = 1.2 * vAmt;
  }

  // --- Loader morph: his eyes become the outer two dots of a three-dot
  // loader, bounce, then grow back. Nothing is drawn beside him, so it still
  // reads as Andy rather than a spinner parked next to him.
  const morph = voice.thinkMorph;
  let bounceY = 0;
  let renderCenterX = centerX;
  if (morph > 0) {
    // normalizeFaceForDisplay gives leftEye the larger x, so the eye named
    // "left" renders on the right. Mapping it to slot 0 sent the two eyes
    // through each other on the way out.
    const dotIndex = side === "left" ? 2 : 0;   // outer slots; middle fades in
    const target = LOADER_SLOT_X[dotIndex];
    renderCenterX = lerp(centerX, target, morph);
    centerY = lerp(centerY, 0, morph);
    width = lerp(width, LOADER_DOT_SIZE, morph);
    height = lerp(height, LOADER_DOT_SIZE, morph);
    // Lids would read as a shadow across a circle, so retract them.
    upperLid *= (1 - morph);
    lowerLid *= (1 - morph);
    bounceY = loaderBounce(performance.now(), dotIndex) * morph;
    voiceGlow = Math.max(voiceGlow, 2.2 * morph);
  }

  context.save();
  const floatY = Math.sin(performance.now() / 1100 + (side === "left" ? 0.4 : 0.9)) * 0.28;
  context.translate(renderCenterX, centerY + floatY * (1 - morph) + bounceY);
  context.rotate(angle * (1 - morph));
  context.shadowColor = "rgba(18, 229, 229, 0.45)";
  context.shadowBlur = 2 + glow * 2 + pulse + voiceGlow;
  const eyeGrad = context.createRadialGradient(hotspotX * width * 0.25, hotspotY * height * 0.25, 2, 0, 0, width * 0.75);
  eyeGrad.addColorStop(0, "#b9ffff");
  eyeGrad.addColorStop(0.28, (mood === "sleeping" || mood === "sleepy") ? "#5ce0e0" : "#5ffafa");
  eyeGrad.addColorStop(0.75, (mood === "sleeping" || mood === "sleepy") ? "#298282" : "#32e5e5");
  eyeGrad.addColorStop(1, "rgba(18, 229, 229, 0)");
  context.fillStyle = eyeGrad;
  drawEyeShape(context, width, height, params, morph);
  context.fill();
  context.save();
  drawEyeShape(context, width, height, params, morph);
  context.clip();
  drawLid(context, width, height, upperLid, upperLidAngle, "top");
  drawLid(context, width, height, lowerLid, lowerLidAngle, "bottom");
  context.restore();

  // Final cleanup: Stroke the eye shape with black to cover any glowing "leaks" at the edges
  context.strokeStyle = "#000000";
  context.lineWidth = 1.5;
  drawEyeShape(context, width, height, params, morph);
  context.stroke();
  
  context.restore();
}

function drawFace(context, now, face, mood, pulse, scale) {
  const safe = normalizeFaceForDisplay(face);
  const breath = VE.getBreathScale(now * (state.isHot ? 2.0 : 1.0));
  
  // Music/Transcription effects...
  let beatY = 0;
  let beatScale = 1.0;
  
  if (state.isMusicPlaying && !isVoiceActive()) {
    const bpm = state.isHot ? 160 : 124;
    const msPerBeat = 60000 / bpm;
    const phase = (now % msPerBeat) / msPerBeat;
    const bounce = Math.pow(1.0 - phase, 2.5);
    beatY = -bounce * (state.isHot ? 14 : 10); 
    beatScale += bounce * (state.isHot ? 0.25 : 0.15);
  }

  const isPerforming = state.animQueue.length > 0 || (state.animation && state.animation.duration > 2000);
  let targetLookX = isPerforming ? 0 : (state.lookOffset?.x || 0);
  let targetLookY = isPerforming ? 0 : (state.lookOffset?.y || 0);
  const idleAmount = isPerforming ? 0.35 : 1.0;
  const targetSwayX = Math.sin(now / 2400) * 0.9 * idleAmount;
  const targetSwayY = Math.sin(now / 1700 + 0.8) * 0.7 * idleAmount;
  let targetTilt = Math.sin(now / 3600 + 0.4) * 0.018 * idleAmount;
  const targetSquash = 1 + Math.sin(now / 1900) * 0.012 * idleAmount;

  // The loader wants to sit still and centred, so damp the idle drift as the
  // morph takes over — otherwise the dots wander while they bounce.
  const morph = state.transcription.thinkMorph;
  if (morph > 0) {
    targetLookX = lerp(targetLookX, 0, morph);
    targetLookY = lerp(targetLookY, 0, morph);
    targetTilt = lerp(targetTilt, 0, morph);
  }

  // Sway, tilt and squash settle first: the gaze budget below is measured
  // against where the eyes are actually about to land, which includes them.
  const poseEase = isPerforming ? 0.08 : 0.12;
  state.renderPose.swayX += (targetSwayX - state.renderPose.swayX) * 0.06;
  state.renderPose.swayY += (targetSwayY - state.renderPose.swayY) * 0.06;
  state.renderPose.tilt += (targetTilt - state.renderPose.tilt) * 0.05;
  state.renderPose.squash += (targetSquash - state.renderPose.squash) * 0.08;

  // The clip underneath keeps running during the loader, and its face scale
  // would squash the dots into ellipses. Neutralise the keyframe transform as
  // the morph takes hold so they stay round and centred.
  // Resolved before the transform is emitted, because the gaze budget and the
  // porthole guard both need these factors to work out where the eyes land.
  const finalScale = scale * 1.15 * breath * beatScale;
  const faceSX = lerp(safe.faceScaleX || 1, 1, morph);
  const faceSY = lerp(safe.faceScaleY || 1, 1, morph);
  const squash = lerp(state.renderPose.squash, 1, morph);

  // Raw, pre-correction face offset — what the clip is asking for. Both the
  // budget and the guard judge against this, never against a corrected pose.
  const rawFaceX = lerp(safe.faceCenterX * 1.1, 0, morph) + state.renderPose.swayX * (1 - morph);
  const eyeXFactor = faceSX * finalScale * squash;

  targetLookX = clampLookXToPorthole(safe, targetLookX, rawFaceX, eyeXFactor);
  state.renderPose.lookX += (targetLookX - state.renderPose.lookX) * poseEase;
  state.renderPose.lookY += (targetLookY - state.renderPose.lookY) * poseEase;

  applyPortholeGuard(safe, updatePortholeGuard(
    safe, now, rawFaceX, eyeXFactor, state.renderPose.lookX
  ), eyeXFactor);

  context.save();
  context.translate(
    lerp(safe.faceCenterX * 1.1, 0, morph) + state.renderPose.swayX * (1 - morph),
    lerp(safe.faceCenterY * 0.78, 0, morph) + beatY + state.renderPose.swayY * (1 - morph)
  );
  context.rotate(clamp(lerp((safe.faceAngle || 0), 0, morph) + state.renderPose.tilt, -0.2, 0.2));

  context.scale(
    faceSX * finalScale * squash,
    faceSY * finalScale / Math.sqrt(squash)
  );

  context.translate(state.renderPose.lookX, state.renderPose.lookY);

  drawEye(context, safe.leftEye, "left", mood, pulse);
  drawEye(context, safe.rightEye, "right", mood, pulse);
  drawLoaderMiddleDot(context, now, morph);
  
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
}

// ---- Render loop ----
// Andy lives in the notch permanently, so the frame budget scales with how much
// he actually has to say. Full rate only for voice and music.
// Frame budget is set per view, because the two are wildly different sizes.
// The closed wing draws 128x80 and is then scaleEffect'd to roughly 30%, so the
// whole face lands in a ~37px circle. At that scale breathing (~0.08px), sway
// (~0.33px), float (~0.1px) and micro-saccades (~0.5px) are all sub-pixel —
// extra frames there composite a byte-identical image at full GPU cost. The
// expanded tab is full size and gets everything.
function targetFrameInterval() {
  if (state.mood === "sleeping") return 1000 / 12;
  if (state.mood === "sleepy") return 1000 / 20;
  if (state.windowBlurred) return 1000 / 24;

  // Real motion always runs uncapped, in either view.
  if (isVoiceActive() || state.isMusicPlaying) return 0;

  if (window.innerWidth >= 200) return 0;   // expanded tab

  // Blinks are the one idle motion big enough to see in the wing (~10px over
  // ~190ms), so don't step those down.
  if (VE.blinkState.isBlinking) return 0;

  return 1000 / 30;                          // closed wing
}

let lastFrameAt = 0;

function render(now) {
  requestAnimationFrame(render);

  const interval = targetFrameInterval();
  if (interval > 0 && now - lastFrameAt < interval) return;
  lastFrameAt = now;

  updateNeeds(now);
  updateVoice(now);
  VE.updateBlink(now);
  VE.updateSaccade(now);

  // Keep the simulation advancing but stop painting when we're not on screen.
  if (document.hidden) return;

  // Don't swap clips mid-sentence; the procedural voice pass owns the face.
  if (state.autoPlay && state.animation && !isVoiceActive() && now > state.nextAnimationAt) {
    playNextAnimation();
  }
  drawPet(now);
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

// interact("drag") had its emotion response written but was never called from
// anywhere — dragging across Andy now actually reaches it.
let dragOrigin = null;

canvas.addEventListener("pointerdown", (event) => {
  canvas.setPointerCapture(event.pointerId);
  dragOrigin = { x: event.clientX, y: event.clientY, fired: false };
  interact("tap");
});
canvas.addEventListener("pointermove", (event) => {
  if (!dragOrigin || dragOrigin.fired) return;
  const dx = event.clientX - dragOrigin.x;
  const dy = event.clientY - dragOrigin.y;
  if (Math.sqrt(dx * dx + dy * dy) > 14) {
    dragOrigin.fired = true;
    interact("drag");
  }
});
canvas.addEventListener("pointerup", (event) => {
  canvas.releasePointerCapture(event.pointerId);
  dragOrigin = null;
});

// Track mouse position for eye following. Note this never fires in the closed
// wing — the notch window does not deliver mouseMoved — so cursorTrack only
// carries real data in the expanded tab. Face-level cursor following comes
// from the Swift bridge instead, which works in both.
window.addEventListener("mousemove", (event) => {
  VE.cursorTrack.hasCursor = true;
  VE.cursorTrack.mouseX = event.clientX / window.innerWidth;
  VE.cursorTrack.mouseY = event.clientY / window.innerHeight;
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
  savePetState();
  if (window.innerWidth < 200) {
    localStorage.setItem("closedNotchUnmountedAt", Date.now());
  } else {
    localStorage.setItem("expandedTabUnmountedAt", Date.now());
  }
});

// Two Andy web views are alive at once — the closed wing and the expanded tab —
// but only ever one is visible. Letting the hidden one keep checkpointing meant
// both wrote the same key and their moods forked. Save only while visible, and
// adopt whatever the other left behind on the way back in, so opening and
// closing the notch is a handoff instead of a fight.
setInterval(() => {
  if (!document.hidden) savePetState();
}, 30000);

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    savePetState();   // hand off on the way out
  } else {
    loadPetState();   // pick up where the other one left off
  }
});

function showLoadError(error) {
  if (animationLabel) animationLabel.textContent = "asset load failed";
  console.error(error);
}

// ---- Start ----
async function start() {
  resizeCanvas();

  // Restore who he was before this launch, before anything overrides the axes.
  loadPetState();

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
  // A remount within a couple of seconds of the last one is SwiftUI swapping
  // branches — dictation ending hands the wing from the live activity back to
  // the idle slot. That is not the same thing as music stealing his spot, and
  // reacting annoyed to it made every finished dictation end on a jolt.
  const isViewSwap = (now - closedUnmountedAt) < 2500;

  if (isClosedNotch && closedUnmountedAt > 0 && !isViewSwap && (now - expandedUnmountedAt) > 2000) {
    // He was displaced by music, mic, or hover! Nudge the restored axes rather
    // than hard-assigning them — this is the most common remount path, and
    // overwriting here would make the saved state look like it never loaded.
    VE.emotions.calmness = Math.max(0, VE.emotions.calmness - 45);
    VE.emotions.happiness = Math.max(0, VE.emotions.happiness - 25);
    VE.emotions.stimulation = Math.min(100, VE.emotions.stimulation + 30);
    // "annoyed_react" is a behaviour key, not a path fragment — the old
    // findAnimationIndices lookup matched nothing, so this never once played.
    startAnims = VE.resolveBehaviorToAnimations("annoyed_react", animations);
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
