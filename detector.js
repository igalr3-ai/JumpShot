// Jump detector — same algorithm as the Android app's JumpDetector.kt.
//
// Tracks the hip midpoint. Distances are in "torso lengths" (shoulder-mid to
// hip-mid, learned while standing), so thresholds work at any distance.
// Image y grows downward: "up" = smaller y.
//
//  LEARNING  – person stands still ~0.4 s → baseline hip height learned
//  READY     – watching; a crouch below the baseline is remembered as a dip
//  trigger   – push-off: after a dip, hips move up fast (before feet leave ground)
//              airborne: hips clearly above stance and still rising
//  COOLDOWN  – ignore landing / bouncing

// MediaPipe pose landmark indices (same numbering as ML Kit)
export const LM = {
  L_SHOULDER: 11, R_SHOULDER: 12, L_ELBOW: 13, R_ELBOW: 14, L_WRIST: 15, R_WRIST: 16,
  L_HIP: 23, R_HIP: 24, L_KNEE: 25, R_KNEE: 26, L_ANKLE: 27, R_ANKLE: 28,
};

const NEVER = -1e9;
const MIN_VIS = 0.5;
const MIN_TORSO_PX = 15;
const HISTORY = 1.5;
const LOST_RESET = 0.5;
const STABLE_WINDOW = 0.5;
const STABLE_MIN_SPAN = 0.35;
const STABLE_RANGE = 0.06;
const RELEARN_TOL = 0.15;
const RELEARN_AFTER = 1.5;
const DIP_MEMORY = 1.0;
const VEL_SPAN = 0.06;

const lerp = (a, b, s) => a + (b - a) * s;
const median = (v) => [...v].sort((a, b) => a - b)[v.length >> 1];

export class JumpDetector {
  constructor() {
    this.mode = 'push';        // 'push' | 'air'
    this.sensitivity = 0.5;    // 0 hard … 1 easy
    this.cooldown = 2;         // seconds
    this.lastSeen = NEVER;
    this.cooldownUntil = NEVER;
    this.reset();
  }

  reset() {
    this.samples = [];
    this.baseline = null;
    this.torsoRef = 0;
    this.farStableSince = null;
    this.lastDip = NEVER;
  }

  /**
   * @param lm  MediaPipe landmarks (normalised 0..1) or undefined
   * @param w,h video frame size in px
   * @param tMs timestamp in ms
   */
  update(lm, w, h, tMs, armed) {
    const t = tMs / 1000;
    const pt = (i) => {
      const l = lm && lm[i];
      return l && (l.visibility ?? 1) >= MIN_VIS ? { x: l.x * w, y: l.y * h } : null;
    };
    const ls = pt(LM.L_SHOULDER), rs = pt(LM.R_SHOULDER), lh = pt(LM.L_HIP), rh = pt(LM.R_HIP);
    if (!ls || !rs || !lh || !rh) return this.#lost(t);

    const hipX = (lh.x + rh.x) / 2, hipY = (lh.y + rh.y) / 2;
    const shX = (ls.x + rs.x) / 2, shY = (ls.y + rs.y) / 2;
    const torso = Math.hypot(shX - hipX, shY - hipY);
    if (torso < MIN_TORSO_PX) return this.#lost(t);
    this.lastSeen = t;

    this.samples.push({ t, hip: hipY, torso });
    while (this.samples.length && this.samples[0].t < t - HISTORY) this.samples.shift();

    if (t >= this.cooldownUntil) this.#updateBaseline(t);
    const base = this.baseline;
    if (base == null) return { state: 'learning', hipX, hipY, rise: 0, vUp: 0 };

    const s = Math.min(1, Math.max(0, this.sensitivity));
    const dipThr = lerp(0.25, 0.08, s);
    const riseThr = lerp(0.30, 0.10, s);
    const pushVel = lerp(3.0, 1.2, s);
    const liftVel = lerp(1.5, 0.5, s);

    const rise = (base - hipY) / this.torsoRef;
    const vUp = this.#velocity();
    if (rise < -dipThr) this.lastDip = t;
    const dipped = t - this.lastDip < DIP_MEMORY;

    const res = (state, triggered = false) => ({
      state, triggered, hipX, hipY, rise, vUp,
      baselineY: base,
      riseLineY: base - riseThr * this.torsoRef,
      dipLineY: this.mode === 'push' ? base + dipThr * this.torsoRef : null,
    });

    if (!armed) return res('disarmed');
    if (t < this.cooldownUntil) return res('cooldown');

    const pushOff = this.mode === 'push' && dipped && vUp > pushVel;
    const lifted = rise > riseThr && vUp > liftVel;
    if (pushOff || lifted) {
      this.cooldownUntil = t + this.cooldown;
      this.lastDip = NEVER;
      return res('ready', true);
    }
    return res(dipped ? 'dipping' : 'ready');
  }

  #lost(t) {
    if (t - this.lastSeen > LOST_RESET) this.reset();
    return { state: 'none', rise: 0, vUp: 0 };
  }

  #updateBaseline(t) {
    const win = this.samples.filter((s) => s.t >= t - STABLE_WINDOW);
    if (win.length < 4 || t - win[0].t < STABLE_MIN_SPAN) return;
    const torsoMed = median(win.map((s) => s.torso));
    const hips = win.map((s) => s.hip);
    if (Math.max(...hips) - Math.min(...hips) > STABLE_RANGE * torsoMed) {
      this.farStableSince = null;
      return;
    }
    const cand = median(hips);
    const b = this.baseline;
    if (b == null || Math.abs(cand - b) < RELEARN_TOL * this.torsoRef) {
      this.baseline = cand; this.torsoRef = torsoMed; this.farStableSince = null;
    } else {
      // Holding a different height (e.g. a squat): only accept it after a while.
      if (this.farStableSince == null) this.farStableSince = t;
      if (t - this.farStableSince > RELEARN_AFTER) {
        this.baseline = cand; this.torsoRef = torsoMed; this.farStableSince = null;
      }
    }
  }

  #velocity() {
    const n = this.samples.length;
    if (n < 2 || this.torsoRef <= 0) return 0;
    const cur = this.samples[n - 1];
    for (let i = n - 2; i >= 0; i--) {
      const s = this.samples[i];
      const dt = cur.t - s.t;
      if (dt >= VEL_SPAN) return dt > 0.3 ? 0 : (s.hip - cur.hip) / this.torsoRef / dt;
    }
    return 0;
  }
}
