"""
FocusPals — Viseme Detection (Spectral Analysis)
Real-time lip sync via FFT on PCM audio chunks.
Classifies each chunk into a viseme: REST, OH, AH, EE_TEETH.
No ML, just numpy — runs in <0.1ms per chunk.
"""

import numpy as np

# ─── Viseme Constants ──────────────────────────────────────

# Maps to texture slots (UV offsets set in Godot)
VISEME_REST = "REST"          # M0 — Neutral closed (body default)
VISEME_OH = "OH"              # M1 (C1) — Round "O" mouth
VISEME_AH = "AH"             # M2 (D1) — Wide open "A" mouth
VISEME_EE_TEETH = "EE_TEETH"  # M3 (C2) — Teeth visible "I/E/F/S"

# ─── Tuning thresholds ────────────────────────────────────
# These may need adjustment based on Gemini's voice (Kore)

_RMS_SILENCE = 300           # Below this = silence
_HF_THRESHOLD = 0.28         # High-freq ratio above this = fricative/teeth
_CENTROID_LOW = 900          # Spectral centroid below this = round vowel "O/U"
# Above _CENTROID_LOW = open vowel "A"


def detect_viseme(pcm_chunk: bytes, sample_rate: int = 24000) -> tuple[str, float]:
    """
    Analyze a raw PCM16 audio chunk and return the best matching viseme + amplitude.

    Args:
        pcm_chunk: Raw PCM 16-bit signed little-endian audio bytes
        sample_rate: Sample rate in Hz (Gemini outputs 24kHz)

    Returns:
        Tuple of (viseme, amplitude):
        - viseme: One of "REST", "OH", "AH", "EE_TEETH"
        - amplitude: 0.0-1.0 normalized RMS value for jaw/mouth open intensity
    """
    if len(pcm_chunk) < 4:
        return VISEME_REST, 0.0

    # Decode PCM16 → float samples
    samples = np.frombuffer(pcm_chunk, dtype=np.int16).astype(np.float32)

    # 1. Amplitude check (RMS)
    rms = np.sqrt(np.mean(samples ** 2))
    if rms < _RMS_SILENCE:
        return VISEME_REST, 0.0

    # Normalize RMS to 0-1 range (cap at ~8000 which is loud speech)
    amplitude = min(1.0, rms / 8000.0)

    # 2. FFT (real-valued input → rfft)
    n = len(samples)
    fft_mag = np.abs(np.fft.rfft(samples))
    freqs = np.fft.rfftfreq(n, d=1.0 / sample_rate)

    total_energy = np.sum(fft_mag) + 1e-10  # avoid div by zero

    # 3. Spectral centroid (weighted average frequency)
    centroid = np.sum(freqs * fft_mag) / total_energy

    # 4. High-frequency energy ratio (energy above 4kHz / total)
    hf_mask = freqs > 4000
    hf_ratio = np.sum(fft_mag[hf_mask]) / total_energy

    # 5. Classify
    if hf_ratio > _HF_THRESHOLD:
        return VISEME_EE_TEETH, amplitude
    elif centroid < _CENTROID_LOW:
        return VISEME_OH, amplitude
    else:
        return VISEME_AH, amplitude
