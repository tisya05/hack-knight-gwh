#!/usr/bin/env python3
"""Generate placeholder cue and earcon WAVs (mono, 48 kHz, 16-bit).

Qimin replaces these with designed sounds. Run from the repo root:
    python3 scripts/make_placeholder_sounds.py
"""
import math
import os
import random
import struct
import wave

SAMPLE_RATE = 48000
PEAK = 10 ** (-1.0 / 20.0)  # -1 dBFS
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "ios", "Echora", "Resources", "Sounds")


def write_wav(name, samples):
    loudest = max(abs(s) for s in samples) or 1.0
    scale = PEAK / loudest
    frames = bytearray()
    for s in samples:
        value = int(max(-1.0, min(1.0, s * scale)) * 32767)
        frames += struct.pack("<h", value)
    path = os.path.join(OUT_DIR, name + ".wav")
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SAMPLE_RATE)
        f.writeframes(bytes(frames))
    print("wrote", os.path.relpath(path))


def envelope(i, count, attack_s, decay_power):
    attack = int(attack_s * SAMPLE_RATE)
    if i < attack:
        return i / max(attack, 1)
    remaining = (count - i) / max(count - attack, 1)
    return remaining ** decay_power


def noise_burst(duration_s, lowpass, highpass, seed):
    """Filtered noise burst with a fast attack. lowpass/highpass are one-pole coefficients."""
    rng = random.Random(seed)
    count = int(duration_s * SAMPLE_RATE)
    samples = []
    low = 0.0
    prev_low = 0.0
    high = 0.0
    for i in range(count):
        white = rng.uniform(-1.0, 1.0)
        low = low + lowpass * (white - low)
        high = highpass * (high + low - prev_low)
        prev_low = low
        samples.append(high * envelope(i, count, 0.002, 2.0))
    return samples


def chirp(freqs, tone_s, gap_s):
    samples = []
    for index, freq in enumerate(freqs):
        count = int(tone_s * SAMPLE_RATE)
        for i in range(count):
            t = i / SAMPLE_RATE
            samples.append(math.sin(2 * math.pi * freq * t) * envelope(i, count, 0.005, 1.5))
        if index < len(freqs) - 1:
            samples.extend([0.0] * int(gap_s * SAMPLE_RATE))
    return samples


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    # Cue candidates: broadband, ~120 ms, different colors so the A/B is meaningful.
    write_wav("cue_primary", noise_burst(0.12, lowpass=0.6, highpass=0.95, seed=1))
    write_wav("cue_alt1", noise_burst(0.12, lowpass=0.9, highpass=0.98, seed=2))
    write_wav("cue_alt2", noise_burst(0.12, lowpass=0.35, highpass=0.9, seed=3))

    # Earcons: short two-tone chirps. not_found descends, found ascends.
    write_wav("earcon_listen_start", chirp([660, 880], 0.06, 0.02))
    write_wav("earcon_listen_end", chirp([880, 660], 0.06, 0.02))
    write_wav("earcon_located", chirp([784, 1047], 0.08, 0.03))
    write_wav("earcon_not_found", chirp([392, 262], 0.14, 0.04))
    write_wav("earcon_found", chirp([523, 659, 784], 0.08, 0.02))


if __name__ == "__main__":
    main()
