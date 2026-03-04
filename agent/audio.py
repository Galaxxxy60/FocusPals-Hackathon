"""
FocusPals — Audio & Microphone Management
Mic listing, selection, hot-swap, and Voice Activity Detection (VAD).
"""

import json
import math
import os
import struct
import time

import pyaudio

from config import SEND_SAMPLE_RATE, FORMAT, CHANNELS, CHUNK_SIZE, state, application_path

# ─── Mic Cache ──────────────────────────────────────────────
_mic_cache = None
_mic_cache_time = 0

# ─── User Preferences Persistence ───────────────────────────
_PREFS_PATH = os.path.join(application_path, "user_prefs.json")


def _load_prefs() -> dict:
    """Load user_prefs.json, returns {} on any failure."""
    try:
        if os.path.exists(_PREFS_PATH):
            with open(_PREFS_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
    except Exception:
        pass
    return {}


def _save_prefs(prefs: dict):
    """Write user_prefs.json (merge with existing)."""
    try:
        existing = _load_prefs()
        existing.update(prefs)
        with open(_PREFS_PATH, "w", encoding="utf-8") as f:
            json.dump(existing, f, indent=2, ensure_ascii=False)
    except Exception as e:
        print(f"⚠️ Impossible de sauvegarder les préférences: {e}")


def get_available_mics():
    """Return cached mic list — NEVER blocks. Call refresh_mic_cache() in a thread for fresh data."""
    if _mic_cache is not None:
        return _mic_cache
    return []  # Empty on very first call, background thread fills it


def refresh_mic_cache():
    """Heavy WASAPI mic probing — ONLY call from a background thread.
    Opens a test stream per device to check 16kHz support. Takes 2-5s."""
    global _mic_cache, _mic_cache_time

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
    """Change le micro utilisé (hot-swap immédiat, même en cours de session).
    Persists the mic name to user_prefs.json for next launch."""
    state["selected_mic_index"] = index
    mics = get_available_mics()
    name = next((m["name"] for m in mics if m["index"] == index), "?")
    print(f"🎤 Micro sélectionné: [{index}] {name}")
    # Persist by name (indices change between restarts)
    if name != "?":
        _save_prefs({"selected_mic_name": name})
        print(f"💾 Micro sauvegardé dans les préférences: {name}")


def resolve_default_mic():
    """Auto-sélectionne le micro: d'abord les préférences sauvegardées,
    puis le micro par défaut du système.
    Called at startup from setup_tray() — OK to be slow here."""
    if state["selected_mic_index"] is not None:
        return
    mics = get_available_mics()
    if not mics:
        # Cache empty — do the heavy refresh (only at startup)
        mics = refresh_mic_cache()
    if not mics:
        print("⚠️ Aucun micro compatible trouvé !")
        return

    # 1) Try to restore saved mic from user_prefs.json
    prefs = _load_prefs()
    saved_name = prefs.get("selected_mic_name", "")
    if saved_name:
        # Try exact match first
        for m in mics:
            if m["name"] == saved_name:
                state["selected_mic_index"] = m["index"]
                print(f"🎤 Micro restauré depuis les préférences: [{m['index']}] {m['name']}")
                return
        # Try prefix match (device names can vary slightly between restarts)
        saved_lower = saved_name.lower()[:20]
        for m in mics:
            if m["name"].lower().startswith(saved_lower):
                state["selected_mic_index"] = m["index"]
                print(f"🎤 Micro restauré (match partiel): [{m['index']}] {m['name']}")
                return
        print(f"⚠️ Micro sauvegardé '{saved_name}' non trouvé, fallback sur le défaut système")

    # 2) Fallback: system default mic
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
