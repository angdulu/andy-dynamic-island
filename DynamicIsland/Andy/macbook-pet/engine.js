// ============================================================
// Vector Emotion Engine & Behavior Tree — Full Implementation
// ============================================================

const emotions = {
  stimulation: 40, happiness: 50, confidence: 60,
  social: 40, tiredness: 10, calmness: 70,
};

function deriveMood() {
  const e = emotions;
  if (e.tiredness > 82 && e.stimulation < 25) return "sleeping";
  if (e.stimulation > 85 && e.happiness > 55) return "excited";
  if (e.calmness < 22 && e.stimulation > 55) return "startled";
  if (e.happiness < 18 && e.social < 25) return "sad";
  if (e.confidence < 28 && e.stimulation > 45) return "frustrated";
  if (e.calmness < 32 && e.social > 35) return "annoyed";
  if (e.social > 68 && e.happiness > 52) return "affectionate";
  if (e.happiness > 62 && e.social > 38) return "happy";
  if (e.happiness > 38 && e.calmness > 55) return "content";
  if (e.stimulation < 22 && e.tiredness < 50) return "bored";
  if (e.stimulation > 38 && e.stimulation < 72 && e.confidence > 30) return "curious";
  if (e.tiredness > 68) return "sleepy";
  return "idle";
}

// All behavior categories mapped to animation path substrings
const behaviorAnimations = {
  // --- Tier 1: Core idle & awareness ---
  idle_blink: ["keepalive_blink","keepalive_eyes","keepalive_eyesonly","eyepose_blink","neutral_eyes"],
  idle_look: ["keepalive","explorer_idle","observing","generic_look","pause_idle"],
  gazing: ["gazing_lookatfaces","gazing_lookatsurface","gazing_lookatvector","gazing_turns",
           "explorer_lookaround","explorer_center","look_left","look_right"],
  explore: ["explorer_huh","explorer_scan","explorer_planning","exploring_test",
            "lookatdevice","freeplay_reacttoface"],
  curious_observe: ["eyepose_curious","eyepose_awe","eyepose_captivated","observing",
                    "explorer_huh_close","explorer_huh_far","pounce_lookloop","attention"],
  // --- Eyepose micro-expressions (all 39) ---
  eyepose_micro: ["eyepose_angry","eyepose_asleep","eyepose_awe","eyepose_blink","eyepose_bliss",
    "eyepose_bothered","eyepose_captivated","eyepose_concerned","eyepose_curious","eyepose_default",
    "eyepose_determined","eyepose_focused","eyepose_frustrated","eyepose_furious","eyepose_happy",
    "eyepose_hurt","eyepose_joy","eyepose_sad","eyepose_sad_down","eyepose_scared",
    "eyepose_scrutinizing","eyepose_shocked","eyepose_squint","eyepose_startled",
    "eyepose_suspicious","eyepose_unsure","eyepose_worried"],
  // --- Tier 1: Reactions ---
  cliff_react: ["reacttocliff_edge","reacttocliff_stop","reacttocliff_turnleft","reacttocliff_turnright",
                "reacttocliff_faceplant","reacttocliff_stuckonedge","reacttocliff_turtleroll",
                "reacttocliff_sidestuck","reacttocliff_reaction"],
  // Direction-specific cliff reactions
  cliff_left: ["reacttocliff_stuckleftside","reacttocliff_stuckonedge_left","reacttocliff_reaction_front_left",
               "reacttocliff_reaction_rear_left","reacttocliff_turnright","reacttocliff_stuckonedge_alert_left"],
  cliff_right: ["reacttocliff_stuckonedge_right","reacttocliff_reaction_front_right",
                "reacttocliff_reaction_rear_right","reacttocliff_turnleft","reacttocliff_stuckonedge_alert_right"],
  cliff_top: ["reacttocliff_edgeliftup","reacttocliff_edge","reacttocliff_huh",
              "reacttocliff_stuckonedge_alert","reacttocliff_stop","reacttocliff_pickup"],
  cliff_bottom: ["reacttocliff_faceplantroll","reacttocliff_turtleroll","reacttocliff_turtlerollfail",
                 "reacttocliff_wheely","reacttocliff_reaction_back"],
  // Dizzy from being shaken/moved rapidly
  dizzy: ["dizzy_reaction_medium","dizzy_reaction_hard","dizzy_pickup","rtshake_lv2",
          "rtshake_lv3","reacttocliff_turtleroll","reacttocliff_faceplantroll"],
  pickup_react: ["rtpickup_loop","rtpickup_putdown","rtpickup_reaction"],
  heldonpalm: ["heldonpalm_edge_nervous","heldonpalm_edge_relaxed","heldonpalm_getin",
               "heldonpalm_idle","heldonpalm_jolt","heldonpalm_looking_nervous",
               "heldonpalm_nestling","heldonpalm_putdown","heldonpalm_rolloff",
               "heldonpalm_transition2relaxed"],
  shake_react: ["rtshake_lv1","rtshake_lv2","rtshake_lv3","rtshake_getin","rtshake_drive"],
  startled_react: ["rtmotion","sudden_obstacle","dizzy_reaction_medium","dizzy_reaction_hard"],
  // --- Tier 2: Emotions & social ---
  happy_react: ["eyepose_happy","eyepose_joy","eyepose_bliss","eyecontact_smile","greeting_happy",
                "pounce_success","reacttoblock_success","fistbump_success",
                "cubespinner_gamesuccess","blackjack_victorwin","cube_success"],
  excited_dance: ["dancebeat_eyebeat","dancebeat_headnod","dancebeat_headlift","dancebeat_idle",
                  "dancebeat_pivot","dancebeat_scoot","dancebeat_headliftbody",
                  "cubespinner_anticroundsuccess","cubespinner_anticgamesuccess"],
  content_calm: ["keepalive","eyepose_happy","eyecontact","petting_blissloop"],
  affectionate: ["petting_blissloop","petting_bliss_getout","freeplay_reacttoface_like",
                 "freeplay_reacttoface_identified","greeting_happy","eyecontact_smile",
                 "feedback_iloveyou"],
  bored: ["keepaway_bored","explorer_idle","slowpoke","eyepose_sad_down","pause_idle",
          "keepaway_idle"],
  annoyed_react: ["eyepose_frustrated","eyepose_scrutinizing","feedback_badrobot",
                  "feedback_bequiet","feedback_shutup","driving_upset","communication_cantdothat"],
  frustrated_react: ["eyepose_frustrated","avs_fail","cubespinner_gamefail","pounce_fail",
                     "fistbump_fail","cubedocking_fail","cubespinner_sessionfail"],
  sad_react: ["eyepose_sad","eyepose_sad_down","eyepose_hurt","eyepose_worried",
              "dizzy_reaction_soft","feedback_apology","feedback_meanwords"],
  // --- Tier 2: Interaction responses ---
  petting_response: ["petting_getin","petting_lvl1","petting_lvl2","petting_lvl3",
                     "petting_blissloop","petting_bliss_getout"],
  greeting_morning: ["greeting_goodmorning","greeting_happy","onboarding_wakeup"],
  greeting_night: ["greeting_goodnight","greeting_goodbye"],
  greeting_hello: ["greeting_hello","greeting_imhome","greeting_happy",
                   "onboarding_reacttoface_happy"],
  feedback_positive: ["feedback_goodrobot","feedback_iloveyou","petting_blissloop"],
  feedback_negative: ["feedback_badrobot","feedback_bequiet","feedback_shutup",
                      "feedback_meanwords"],
  // --- Tier 2: Self-amusement ---
  self_amuse: ["dancebeat","cubespinner","fistbump_idle","blackjack_idle","eyecolorreact",
               "spinner_tap"],
  dance_full: ["dancebeat_getin","dancebeat_eyebeat","dancebeat_headnod","dancebeat_pivot",
               "dancebeat_scoot","dancebeat_getout"],
  keepaway_game: ["keepaway_getready","keepaway_idle","keepaway_pounce","keepaway_fakeout",
                  "keepaway_hit_reaction","keepaway_miss_reaction","keepaway_wingame",
                  "keepaway_losegame","keepaway_backup","keepaway_stopshort"],
  fistbump_game: ["fistbump_getin","fistbump_idle","fistbump_requestonce","fistbump_success",
                  "fistbump_fail"],
  // --- Tier 2: Referencing & face ---
  face_react: ["freeplay_reacttoface_identified","freeplay_reacttoface_like",
               "freeplay_reacttoface_sayname","freeplay_reacttoface_longname",
               "reacttoface_unidentified","movement_reacttoface"],
  referencing: ["referencing_curious","referencing_happy","referencing_scared",
                "referencing_unsure","referencing_neutral"],
  petdetection: ["petdetection_reaction_cat","petdetection_reaction_dog"],
  // --- Tier 3: Environment ---
  weather_react: ["weather_cloud","weather_sunny","weather_rain","weather_snow",
                  "weather_stars","weather_thunderstorm","weather_windy","weather_cold"],
  holiday: ["holiday_hh_lights","holiday_hny_fireworks","holiday_hyn_confetti"],
  sound_react: ["rtsound_offcharger","rtsound_oncharger","wakeword","vc_listening"],
  // --- Sleep/wake ---
  sleepy: ["eyepose_asleep","gotosleep_sleeping","gotosleep_getin","launch_sleeping",
           "rtsound_offcharger_asleep"],
  sleeping: ["gotosleep_sleeping","gotosleep_off","gotosleep_sleeploop","launch_sleeping"],
  waking: ["gotosleep_getout","gotosleep_wakeup","power_offon","onboarding_wakeup"],
  // --- Movement/charger ---
  movement: ["movement_comehere","movement_alreadyhere","movement_directioncommands",
             "movement_lookinplaceforfaces"],
  charger_react: ["chargerdocking_comeoff","chargerdocking_reaction","chargerdocking_settle",
                  "chargerdocking_request","chargerdocking_searchforcharger"],
  // --- Misc ---
  hiking: ["hiking_driving","hiking_observe","hiking_lookaround"],
  block_react: ["reacttoblock_react","reacttoblock_success","reacttoblock_frustrated",
                "reacttoblock_happydetermined","reacttoblock_lifteffort",
                "reacttoblock_admire","reacttoblock_dropfail","reacttoblock_dropsuccess"],
  onboarding: ["onboarding_wakeup","onboarding_eyecontact","onboarding_reacttoface",
               "onboarding_lookaround","onboarding_lookdown"],
  meetvictor: ["meetvictor_getin","meetvictor_alreadyknow","meetvictor_lookface"],
};

// Mood → weighted behavior map
const moodBehaviors = {
  idle:        { idle_blink:20, idle_look:20, gazing:20, eyepose_micro:15, explore:10, curious_observe:5, self_amuse:5, bored:5 },
  curious:     { curious_observe:25, gazing:20, explore:20, eyepose_micro:10, idle_blink:10, self_amuse:8, referencing:7 },
  happy:       { happy_react:25, content_calm:15, affectionate:10, excited_dance:10, self_amuse:10, eyepose_micro:10, idle_blink:10, face_react:10 },
  excited:     { excited_dance:30, happy_react:20, self_amuse:15, dance_full:15, eyepose_micro:10, curious_observe:10 },
  content:     { content_calm:25, idle_look:20, gazing:15, eyepose_micro:15, happy_react:10, affectionate:10, idle_blink:5 },
  bored:       { bored:25, gazing:20, idle_look:15, explore:15, eyepose_micro:10, self_amuse:10, hiking:5 },
  frustrated:  { frustrated_react:30, annoyed_react:20, eyepose_micro:15, block_react:10, bored:10, sad_react:10, feedback_negative:5 },
  annoyed:     { annoyed_react:30, frustrated_react:15, feedback_negative:15, eyepose_micro:15, bored:10, startled_react:10, idle_blink:5 },
  sad:         { sad_react:30, bored:20, eyepose_micro:15, idle_blink:15, idle_look:10, sleepy:10 },
  startled:    { startled_react:35, cliff_react:20, curious_observe:20, eyepose_micro:15, explore:10 },
  affectionate:{ affectionate:30, happy_react:20, petting_response:15, content_calm:10, face_react:10, eyepose_micro:10, feedback_positive:5 },
  sleepy:      { sleepy:30, idle_blink:20, eyepose_micro:15, idle_look:15, gazing:10, bored:10 },
  sleeping:    { sleeping:80, sleepy:20 },
  waking:      { waking:40, curious_observe:25, eyepose_micro:15, greeting_hello:10, idle_blink:10 },
};

// --- Gaze direction system ---
const gazeState = {
  directionX: 0, directionY: 0,  // -1 to 1
  targetDirX: 0, targetDirY: 0,
  nextGazeShiftAt: performance.now() + 2000,
  atEdge: false, edgeSide: null,
};

function updateGaze(now) {
  if (now > gazeState.nextGazeShiftAt) {
    gazeState.targetDirX = (Math.random() - 0.5) * 2;
    gazeState.targetDirY = (Math.random() - 0.5) * 1.5;
    gazeState.nextGazeShiftAt = now + 3000 + Math.random() * 8000;
  }
  gazeState.directionX += (gazeState.targetDirX - gazeState.directionX) * 0.02;
  gazeState.directionY += (gazeState.targetDirY - gazeState.directionY) * 0.02;
  
  const threshold = 0.85;
  const wasAtEdge = gazeState.atEdge;
  if (Math.abs(gazeState.directionX) > threshold) {
    gazeState.atEdge = true;
    gazeState.edgeSide = gazeState.directionX > 0 ? "right" : "left";
  } else if (Math.abs(gazeState.directionY) > threshold) {
    gazeState.atEdge = true;
    gazeState.edgeSide = gazeState.directionY > 0 ? "bottom" : "top";
  } else {
    gazeState.atEdge = false;
    gazeState.edgeSide = null;
  }
  return !wasAtEdge && gazeState.atEdge; // returns true on NEW edge hit
}

// --- Shake detection ---
const shakeState = {
  positions: [], // {x, y, t}
  intensity: 0,  // 0=none, 1=gentle, 2=medium, 3=hard
  lastShakeAt: 0,
  isShaking: false,
};

function trackMouseForShake(x, y, now) {
  shakeState.positions.push({ x, y, t: now });
  // Keep last 500ms of positions
  while (shakeState.positions.length > 0 && now - shakeState.positions[0].t > 500) {
    shakeState.positions.shift();
  }
  if (shakeState.positions.length < 4) return;
  
  // Calculate velocity variance (shake = high variance in direction)
  let totalDist = 0, dirChanges = 0, lastDx = 0;
  for (let i = 1; i < shakeState.positions.length; i++) {
    const dx = shakeState.positions[i].x - shakeState.positions[i-1].x;
    const dy = shakeState.positions[i].y - shakeState.positions[i-1].y;
    totalDist += Math.sqrt(dx*dx + dy*dy);
    if (lastDx !== 0 && Math.sign(dx) !== Math.sign(lastDx)) dirChanges++;
    lastDx = dx;
  }
  
  const wasShaking = shakeState.isShaking;
  if (dirChanges > 4 && totalDist > 200) {
    shakeState.intensity = 3; shakeState.isShaking = true;
  } else if (dirChanges > 3 && totalDist > 100) {
    shakeState.intensity = 2; shakeState.isShaking = true;
  } else if (dirChanges > 2 && totalDist > 50) {
    shakeState.intensity = 1; shakeState.isShaking = true;
  } else {
    shakeState.intensity = 0; shakeState.isShaking = false;
  }
  if (shakeState.isShaking) shakeState.lastShakeAt = now;
  return !wasShaking && shakeState.isShaking;
}

// --- Petting detection ---
const petState = {
  gentleClickCount: 0, gentleClickWindow: [],
  pettingLevel: 0, // 0=none, 1-3=levels
  isPetting: false,
  lastPetAt: 0,
};

function trackPetting(now) {
  petState.gentleClickWindow.push(now);
  // Keep last 5 seconds
  while (petState.gentleClickWindow.length > 0 && now - petState.gentleClickWindow[0] > 5000) {
    petState.gentleClickWindow.shift();
  }
  const count = petState.gentleClickWindow.length;
  const rate = count / 5; // clicks per second
  
  if (rate > 0.4 && rate < 1.5) {
    petState.isPetting = true;
    petState.lastPetAt = now;
    petState.pettingLevel = rate < 0.7 ? 1 : rate < 1.2 ? 2 : 3;
  } else {
    petState.isPetting = false;
    petState.pettingLevel = 0;
  }
}

// --- Self-amusement timer ---
const amuseState = {
  nextAmuseAt: performance.now() + 30000 + Math.random() * 45000,
  isAmusing: false,
};

function checkSelfAmuse(now) {
  if (now > amuseState.nextAmuseAt && !amuseState.isAmusing) {
    amuseState.isAmusing = true;
    amuseState.nextAmuseAt = now + 120000 + Math.random() * 240000; // 2-6 min
    return true;
  }
  return false;
}

function finishAmuse() { amuseState.isAmusing = false; }

// --- Weighted random pick ---
function weightedPick(weightMap) {
  const entries = Object.entries(weightMap);
  const total = entries.reduce((sum, [, w]) => sum + w, 0);
  let roll = Math.random() * total;
  for (const [key, weight] of entries) {
    roll -= weight;
    if (roll <= 0) return key;
  }
  return entries[entries.length - 1][0];
}

// --- Emotion update ---
function updateEmotions(dtSeconds, context) {
  const dt = Math.min(dtSeconds, 0.1);
  const e = emotions;
  e.stimulation += (35 - e.stimulation) * 0.008 * dt * 60;
  e.happiness += (45 - e.happiness) * 0.004 * dt * 60;
  e.confidence += (55 - e.confidence) * 0.003 * dt * 60;
  e.social += (30 - e.social) * 0.005 * dt * 60;
  e.calmness += (65 - e.calmness) * 0.006 * dt * 60;
  e.tiredness += 0.015 * dt * 60;
  
  const hour = new Date().getHours();
  if (hour >= 23 || hour < 6) { e.tiredness += 0.03 * dt * 60; e.stimulation -= 0.01 * dt * 60; }
  else if (hour >= 6 && hour < 10) { e.happiness += 0.005 * dt * 60; e.stimulation += 0.005 * dt * 60; }
  
  const idle = context.idleSeconds || 0;
  if (idle > 30) { e.stimulation -= 0.02 * dt * 60; e.social -= 0.01 * dt * 60; }
  if (idle > 120) { e.tiredness += 0.04 * dt * 60; }
  if (context.windowBlurred) { e.social -= 0.03 * dt * 60; e.happiness -= 0.01 * dt * 60; e.stimulation -= 0.02 * dt * 60; }
  
  for (const key of Object.keys(e)) e[key] = Math.max(0, Math.min(100, e[key]));
}

// --- Interaction effects ---
function onInteraction(type) {
  const e = emotions;
  const clamp = (v) => Math.max(0, Math.min(100, v));
  switch (type) {
    case "gentle_click":
      e.stimulation = clamp(e.stimulation + 12); e.happiness = clamp(e.happiness + 8);
      e.social = clamp(e.social + 10); e.calmness = clamp(e.calmness - 3); e.tiredness = clamp(e.tiredness - 5);
      break;
    case "rapid_click":
      e.stimulation = clamp(e.stimulation + 20); e.calmness = clamp(e.calmness - 18);
      e.happiness = clamp(e.happiness - 5); e.tiredness = clamp(e.tiredness + 3);
      break;
    case "drag":
      e.stimulation = clamp(e.stimulation + 25); e.calmness = clamp(e.calmness - 25);
      e.happiness = clamp(e.happiness - 10); e.social = clamp(e.social - 8);
      break;
    case "shake":
      e.stimulation = clamp(e.stimulation + 35); e.calmness = clamp(e.calmness - 40);
      e.happiness = clamp(e.happiness - 15); e.confidence = clamp(e.confidence - 10);
      break;
    case "mouse_near":
      e.social = clamp(e.social + 4); e.stimulation = clamp(e.stimulation + 2); break;
    case "mouse_move":
      e.stimulation = clamp(e.stimulation + 1); break;
    case "window_focus":
      e.social = clamp(e.social + 15); e.stimulation = clamp(e.stimulation + 10);
      e.happiness = clamp(e.happiness + 5); e.tiredness = clamp(e.tiredness - 8);
      break;
    case "typing":
      e.stimulation = clamp(e.stimulation + 2); e.social = clamp(e.social + 1); break;
    case "petting":
      e.happiness = clamp(e.happiness + 12); e.social = clamp(e.social + 8);
      e.calmness = clamp(e.calmness + 5); e.tiredness = clamp(e.tiredness - 3);
      break;
  }
}

function chooseBehavior(mood) {
  return weightedPick(moodBehaviors[mood] || moodBehaviors.idle);
}

function resolveBehaviorToAnimations(behavior, allAnimations) {
  const tags = behaviorAnimations[behavior] || behaviorAnimations.idle_blink;
  const indices = new Set();
  for (const tag of tags) {
    const lower = tag.toLowerCase();
    allAnimations.forEach((anim, idx) => {
      if (anim.path.toLowerCase().includes(lower)) indices.add(idx);
    });
  }
  return Array.from(indices);
}

// --- Blink ---
const blinkState = {
  nextBlinkAt: performance.now() + 3000 + Math.random() * 5000,
  blinkProgress: 0, isBlinking: false,
  blinkDuration: 180, blinkStartedAt: 0,
};

function updateBlink(now) {
  if (!blinkState.isBlinking && now > blinkState.nextBlinkAt) {
    blinkState.isBlinking = true;
    blinkState.blinkStartedAt = now;
    blinkState.blinkDuration = 140 + Math.random() * 100;
    blinkState.nextBlinkAt = now + blinkState.blinkDuration +
      (Math.random() < 0.2 ? 200 + Math.random() * 200 : 3000 + Math.random() * 5000);
  }
  if (blinkState.isBlinking) {
    const elapsed = now - blinkState.blinkStartedAt;
    const half = blinkState.blinkDuration / 2;
    if (elapsed < half) blinkState.blinkProgress = elapsed / half;
    else if (elapsed < blinkState.blinkDuration) blinkState.blinkProgress = 1 - (elapsed - half) / half;
    else { blinkState.blinkProgress = 0; blinkState.isBlinking = false; }
  }
}

// --- Saccade ---
const saccadeState = { offsetX: 0, offsetY: 0, targetX: 0, targetY: 0,
  nextSaccadeAt: performance.now() + 1000 + Math.random() * 3000 };

function updateSaccade(now) {
  if (now > saccadeState.nextSaccadeAt) {
    saccadeState.targetX = (Math.random() - 0.5) * 3;
    saccadeState.targetY = (Math.random() - 0.5) * 1.5;
    saccadeState.nextSaccadeAt = now + 800 + Math.random() * 4000;
  }
  saccadeState.offsetX += (saccadeState.targetX - saccadeState.offsetX) * 0.08;
  saccadeState.offsetY += (saccadeState.targetY - saccadeState.offsetY) * 0.08;
}

// --- Cursor tracking ---
const cursorTrack = { mouseX: 0.5, mouseY: 0.5, smoothX: 0.5, smoothY: 0.5, isNear: false };

function updateCursorTracking() {
  cursorTrack.smoothX += (cursorTrack.mouseX - cursorTrack.smoothX) * 0.04;
  cursorTrack.smoothY += (cursorTrack.mouseY - cursorTrack.smoothY) * 0.04;
  const dx = cursorTrack.mouseX - 0.5, dy = cursorTrack.mouseY - 0.5;
  cursorTrack.isNear = Math.sqrt(dx * dx + dy * dy) < 0.3;
}

function getBreathScale(now) {
  return 1 + Math.sin(now / 1800) * 0.008 + Math.sin(now / 4200) * 0.004;
}

window.VectorEngine = {
  emotions, deriveMood, behaviorAnimations, moodBehaviors,
  weightedPick, updateEmotions, onInteraction,
  chooseBehavior, resolveBehaviorToAnimations,
  blinkState, updateBlink, saccadeState, updateSaccade,
  cursorTrack, updateCursorTracking, getBreathScale,
  gazeState, updateGaze,
  shakeState, trackMouseForShake,
  petState, trackPetting,
  amuseState, checkSelfAmuse, finishAmuse,
};
