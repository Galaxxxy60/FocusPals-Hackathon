"""
FocusPals — Audio & Microphone Management
Mic listing, selection, hot-swap, and Voice Activity Detection (VAD).
"""

import math
import struct
import time

import pyaudio

from config import SEND_SAMPLE_RATE, FORMAT, CHANNELS, CHUNK_SIZE, state

# ─── Mic Cache ──────────────────────────────────────────────
_mic_cache = None
_mic_cache_time = 0


def get_available_mics(force_refresh=False):
    """Liste les micros disponibles qui supportent 16kHz (priorité WASAPI, fallback MME)."""
    global _mic_cache, _mic_cache_time
    if not force_refresh and _mic_cache is not None and (time.time() - _mic_cache_time) < 30:
        return _mic_cache

    pya = pyaudio.PyAudio()
    mics = []
    seen_names = set()

    exclude = ["steam streaming", "vb-audio", "cable output", "mappeur", "wo mic",
               "réseau de microphones", "input (vb", "cable input"]

    for i in range(pya.get_device_count()):
        info = pya.get_device_info_by_index(i)
        if info["maxInputChannels"] <= 0:
            continue
        name_lower = info["name"].lower()
        if any(ex in name_lower for ex in exclude):
            continue
        name_prefix = name_lower[:15]
        if name_prefix in seen_names:
            continue
        try:
            test_stream = pya.open(format=pyaudio.paInt16, channels=1, rate=SEND_SAMPLE_RATE,
                                   input=True, input_device_index=i, frames_per_buffer=512)
            test_stream.close()
            mics.append({"index": i, "name": info["name"]})
            seen_names.add(name_prefix)
        except OSError:
            continue

    pya.terminate()
    _mic_cache = mics
    _mic_cache_time = time.time()
    return mics


def select_mic(index):
    """Change le micro utilisé (hot-swap immédiat, même en cours de session)."""
    state["selected_mic_index"] = index
    mics = get_available_mics()
    name = next((m["name"] for m in mics if m["index"] == index), "?")
    print(f"🎤 Micro sélectionné: [{index}] {name}")


def resolve_default_mic():
    """Auto-sélectionne le micro par défaut du système si aucun n'est choisi."""
    if state["selected_mic_index"] is not None:
        return
    mics = get_available_mics()
    if not mics:
        print("⚠️ Aucun micro compatible trouvé !")
        return
    try:
        pya_tmp = pyaudio.PyAudio()
        default_name = pya_tmp.get_default_input_device_info()["name"].lower()
        pya_tmp.terminate()
        for m in mics:
            if m["name"].lower().startswith(default_name[:15]):
                state["selected_mic_index"] = m["index"]
                break
        if state["selected_mic_index"] is None:
            state["selected_mic_index"] = mics[0]["index"]
    except Exception:
        state["selected_mic_index"] = mics[0]["index"]
    print(f"🎤 Micro auto-sélectionné: [{state['selected_mic_index']}]")


def detect_voice_activity(pcm_data: bytes, threshold: float = 500.0) -> bool:
    """Simple energy-based Voice Activity Detection on 16-bit PCM mono."""
    try:
        n_samples = len(pcm_data) // 2
        if n_samples == 0:
            return False
        samples = struct.unpack(f'<{n_samples}h', pcm_data)
        rms = math.sqrt(sum(s * s for s in samples) / n_samples)
        return rms > threshold
    except Exception:
        return False
