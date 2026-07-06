"use client";

/**
 * Tiny synthesized sound engine (Web Audio API — no audio files).
 * All sounds are short, cheerful, and fire only from user gestures,
 * which also satisfies browser autoplay policies.
 */

const MUTE_KEY = "fet-hunt-muted";

let ctx: AudioContext | null = null;

function audioContext(): AudioContext | null {
  if (typeof window === "undefined") return null;
  if (!ctx) {
    const Ctor =
      window.AudioContext ??
      (window as unknown as { webkitAudioContext?: typeof AudioContext })
        .webkitAudioContext;
    if (!Ctor) return null;
    ctx = new Ctor();
  }
  if (ctx.state === "suspended") void ctx.resume();
  return ctx;
}

export function isMuted(): boolean {
  if (typeof window === "undefined") return false;
  return localStorage.getItem(MUTE_KEY) === "1";
}

export function setMuted(muted: boolean) {
  localStorage.setItem(MUTE_KEY, muted ? "1" : "0");
}

interface Note {
  freq: number;
  /** seconds after play() call */
  at: number;
  dur: number;
  type?: OscillatorType;
  gain?: number;
}

function play(notes: Note[]) {
  if (isMuted()) return;
  const ac = audioContext();
  if (!ac) return;
  const now = ac.currentTime;

  for (const n of notes) {
    const osc = ac.createOscillator();
    const gain = ac.createGain();
    osc.type = n.type ?? "sine";
    osc.frequency.setValueAtTime(n.freq, now + n.at);

    const g = n.gain ?? 0.12;
    gain.gain.setValueAtTime(0, now + n.at);
    gain.gain.linearRampToValueAtTime(g, now + n.at + 0.01);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + n.at + n.dur);

    osc.connect(gain).connect(ac.destination);
    osc.start(now + n.at);
    osc.stop(now + n.at + n.dur + 0.05);
  }
}

/** Soft pop for taps and selections. */
export function playTap() {
  play([{ freq: 520, at: 0, dur: 0.08, type: "triangle", gain: 0.1 }]);
}

/** Bright rising chirp — answer submitted, moving on. */
export function playSubmit() {
  play([
    { freq: 440, at: 0, dur: 0.09, type: "triangle" },
    { freq: 660, at: 0.07, dur: 0.12, type: "triangle" },
  ]);
}

/** Cheerful ta-da for milestones (team created, QR found). */
export function playSuccess() {
  play([
    { freq: 523, at: 0, dur: 0.12, type: "triangle" },
    { freq: 659, at: 0.09, dur: 0.12, type: "triangle" },
    { freq: 784, at: 0.18, dur: 0.2, type: "triangle", gain: 0.14 },
  ]);
}

/** Big finish fanfare for completing the hunt. */
export function playFanfare() {
  play([
    { freq: 523, at: 0, dur: 0.15, type: "square", gain: 0.07 },
    { freq: 659, at: 0.12, dur: 0.15, type: "square", gain: 0.07 },
    { freq: 784, at: 0.24, dur: 0.15, type: "square", gain: 0.07 },
    { freq: 1047, at: 0.36, dur: 0.4, type: "square", gain: 0.08 },
    { freq: 523, at: 0.36, dur: 0.4, type: "triangle", gain: 0.1 },
    { freq: 659, at: 0.52, dur: 0.3, type: "triangle", gain: 0.08 },
  ]);
}
