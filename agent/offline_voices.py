"""
FocusPals — Offline Voice Database
Pre-recorded audio phrases for when the Gemini Live API is offline.
Provides 5 variants per category × 2 languages (FR/EN) for natural variety.

Architecture:
- Phrases are stored as OGG files in agent/offline_audio/{lang}/{category}/
- Each category has 5 variants (01.ogg → 05.ogg)
- A random variant is picked each time to avoid repetition
- Audio is decoded to PCM and played through PyAudio (same as Gemini's voice)

Usage:
    from offline_voices import play_offline_phrase
    await play_offline_phrase("focus_reminder", lang="fr")
"""

import asyncio
import os
import random
import struct
import subprocess
import time
import wave

from config import RECEIVE_SAMPLE_RATE, state, tweaks, application_path

# ─── Constants ──────────────────────────────────────────────
OFFLINE_AUDIO_DIR = os.path.join(application_path, "offline_audio")

# Track last played variant per category to avoid immediate repeats
_last_played: dict[str, int] = {}

# Cached ffmpeg path (resolved once)
_ffmpeg_exe: str | None = None

# ─── Phrase Categories ──────────────────────────────────────
# Each category maps to a situation where Tama needs to speak without the API.
# The text content is defined in generate_offline_voices.py — this module
# only handles loading and playing the generated audio files.

CATEGORIES = [
    "greeting",           # Session start / hello
    "goodbye",            # Session end / bye
    "focus_reminder",     # "Stay focused!" when user procrastinates (S > 5)
    "focus_warning",      # Higher suspicion (S > 7) — more stern
    "encouragement",      # "You're doing great!" periodic positive reinforcement
    "break_suggestion",   # "Time for a break!"
    "reconnecting",       # "Hold on, I'm reconnecting..." (API hiccup)
    "back_online",        # "I'm back!" (after reconnection)
    "thinking",           # "Hmm..." / filler while waiting
    "strike_warning",     # "Last chance!" before closing a tab (S = 9+)
    "busy_writing",       # "Give me two seconds..." (Tama is busy writing/working)
    "distraction_spotted",# "Close that distraction!" (procrastination detected)
    "distraction_closed", # "Good, back to work!" (after closing distraction)
]


def _get_ffmpeg() -> str:
    """Get ffmpeg binary path — tries imageio_ffmpeg bundled binary, then system PATH."""
    global _ffmpeg_exe
    if _ffmpeg_exe:
        return _ffmpeg_exe
    # Try imageio_ffmpeg (bundled binary, always works)
    try:
        import imageio_ffmpeg
        _ffmpeg_exe = imageio_ffmpeg.get_ffmpeg_exe()
        return _ffmpeg_exe
    except ImportError:
        pass
    # Fallback: system ffmpeg
    _ffmpeg_exe = "ffmpeg"
    return _ffmpeg_exe


def get_available_languages() -> list[str]:
    """Return list of languages with offline audio available."""
    if not os.path.isdir(OFFLINE_AUDIO_DIR):
        return []
    return [d for d in os.listdir(OFFLINE_AUDIO_DIR)
            if os.path.isdir(os.path.join(OFFLINE_AUDIO_DIR, d))]


def get_variant_count(category: str, lang: str) -> int:
    """Return how many variants exist for a given category and language."""
    cat_dir = os.path.join(OFFLINE_AUDIO_DIR, lang, category)
    if not os.path.isdir(cat_dir):
        return 0
    return len([f for f in os.listdir(cat_dir) if f.endswith((".ogg", ".wav"))])


def _pick_variant(category: str, lang: str) -> str | None:
    """Pick a random audio file for the given category, avoiding immediate repeats."""
    cat_dir = os.path.join(OFFLINE_AUDIO_DIR, lang, category)
    if not os.path.isdir(cat_dir):
        return None
    
    files = sorted([f for f in os.listdir(cat_dir) if f.endswith((".ogg", ".wav"))])
    if not files:
        return None
    
    # Avoid repeating the same variant twice in a row
    key = f"{lang}:{category}"
    last = _last_played.get(key, -1)
    
    if len(files) > 1:
        candidates = [i for i in range(len(files)) if i != last]
        idx = random.choice(candidates)
    else:
        idx = 0
    
    _last_played[key] = idx
    return os.path.join(cat_dir, files[idx])


def _load_audio_pcm(audio_path: str) -> tuple[bytes, int]:
    """Load an audio file (OGG or WAV) and return (raw PCM bytes, sample_rate).
    
    For WAV: uses built-in wave module (fast, no dependencies).
    For OGG: uses ffmpeg to decode to raw PCM (requires imageio_ffmpeg or system ffmpeg).
    """
    if audio_path.endswith(".wav"):
        return _load_wav_pcm(audio_path)
    else:
        return _load_ogg_pcm(audio_path)


def _load_wav_pcm(wav_path: str) -> tuple[bytes, int]:
    """Load a WAV file and return (raw PCM bytes, sample_rate)."""
    with wave.open(wav_path, 'rb') as wf:
        n_channels = wf.getnchannels()
        sample_width = wf.getsampwidth()
        sample_rate = wf.getframerate()
        n_frames = wf.getnframes()
        raw = wf.readframes(n_frames)
    
    # Convert to mono if stereo
    if n_channels == 2 and sample_width == 2:
        n_samples = len(raw) // 4
        stereo = struct.unpack(f"<{n_samples * 2}h", raw)
        mono = [(stereo[i * 2] + stereo[i * 2 + 1]) // 2 for i in range(n_samples)]
        raw = struct.pack(f"<{n_samples}h", *mono)
    
    return raw, sample_rate


def _load_ogg_pcm(ogg_path: str) -> tuple[bytes, int]:
    """Decode an OGG file to raw PCM using ffmpeg.
    Returns (raw_pcm_bytes, 24000) — always 16-bit mono 24kHz."""
    ffmpeg = _get_ffmpeg()
    sample_rate = 24000
    
    result = subprocess.run([
        ffmpeg, '-i', ogg_path,
        '-f', 's16le',        # raw PCM 16-bit little-endian
        '-acodec', 'pcm_s16le',
        '-ar', str(sample_rate),
        '-ac', '1',            # mono
        '-v', 'error',         # suppress verbose output
        'pipe:1'               # output to stdout
    ], capture_output=True)
    
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg decode failed: {result.stderr.decode()[:200]}")
    
    return result.stdout, sample_rate


async def play_offline_phrase(
    category: str,
    lang: str | None = None,
    broadcast_visemes: bool = True,
) -> bool:
    """Play a random pre-recorded phrase for the given category.
    
    Args:
        category: One of the CATEGORIES (e.g. "focus_reminder")
        lang: Language code ("fr" or "en"). Defaults to state["language"].
        broadcast_visemes: If True, send VISEME commands to Godot for lip sync.
    
    Returns:
        True if a phrase was played, False if no audio available.
    """
    import pyaudio
    from ui import broadcast_to_godot, send_anim_to_godot
    import json
    
    if lang is None:
        lang = state.get("language", "en")
    
    # Map language codes to our directory names
    lang_map = {"fr": "fr", "en": "en", "ja": "en", "zh": "en"}
    lang_dir = lang_map.get(lang, "en")
    
    audio_path = _pick_variant(category, lang_dir)
    if not audio_path:
        # Try fallback language
        fallback = "en" if lang_dir == "fr" else "fr"
        audio_path = _pick_variant(category, fallback)
        if not audio_path:
            print(f"  🔇 No offline audio for {category}/{lang_dir}")
            return False
    
    print(f"  🔊 Offline voice: {category} ({os.path.basename(audio_path)})")
    
    try:
        pcm_data, sample_rate = await asyncio.to_thread(_load_audio_pcm, audio_path)
    except Exception as e:
        print(f"  ⚠️ Failed to load offline audio: {e}")
        return False
    
    # Apply pitch shift (same as Gemini voice)
    _pitch = tweaks.get("voice_pitch", 1.0)
    playback_rate = int(sample_rate * _pitch)
    
    # Apply volume scaling
    vol = state.get("tama_volume", 1.0)
    if vol < 0.01:
        return True  # Muted
    elif vol < 0.99:
        n_samples = len(pcm_data) // 2
        samples = struct.unpack(f"<{n_samples}h", pcm_data)
        scaled = struct.pack(f"<{n_samples}h", *(
            max(-32768, min(32767, int(s * vol))) for s in samples
        ))
        pcm_data = scaled
    
    # Signal Tama is "speaking"
    state["_tama_is_speaking"] = True
    
    # Set talking animation
    send_anim_to_godot("Idle_wall_Talk", False)
    
    # Play audio in chunks (non-blocking, through asyncio)
    pya = pyaudio.PyAudio()
    try:
        speaker = pya.open(
            format=pyaudio.paInt16,
            channels=1,
            rate=playback_rate,
            output=True,
        )
        
        chunk_size = 2048
        chunk_bytes = chunk_size * 2
        
        for offset in range(0, len(pcm_data), chunk_bytes):
            chunk = pcm_data[offset:offset + chunk_bytes]
            
            # Simple viseme from energy (lightweight, no ML needed)
            if broadcast_visemes and len(chunk) >= 4:
                n = len(chunk) // 2
                samples = struct.unpack(f"<{n}h", chunk)
                rms = (sum(s * s for s in samples) / n) ** 0.5
                amplitude = min(1.0, rms / 8000.0)
                
                if amplitude > 0.05:
                    shape = "AA" if amplitude > 0.4 else "OH" if amplitude > 0.2 else "EE"
                else:
                    shape = "REST"
                
                viseme_msg = json.dumps({"command": "VISEME", "shape": shape, "amp": round(amplitude, 2)})
                broadcast_to_godot(viseme_msg)
            
            await asyncio.to_thread(speaker.write, chunk)
            state["_last_audio_play_time"] = time.time()
        
        # Send REST viseme after speech
        rest_msg = json.dumps({"command": "VISEME", "shape": "REST"})
        broadcast_to_godot(rest_msg)
        
    except Exception as e:
        print(f"  ⚠️ Offline playback error: {e}")
        return False
    finally:
        try:
            speaker.stop_stream()
            speaker.close()
        except Exception:
            pass
        pya.terminate()
        
        state["_tama_is_speaking"] = False
        state["_last_speech_ended"] = time.time()
    
    return True


def get_offline_stats() -> dict:
    """Return stats about available offline audio."""
    stats = {}
    for lang in ["fr", "en"]:
        lang_stats = {}
        for cat in CATEGORIES:
            count = get_variant_count(cat, lang)
            if count > 0:
                lang_stats[cat] = count
        if lang_stats:
            stats[lang] = lang_stats
    return stats


# ─── Quick Test ─────────────────────────────────────────────

if __name__ == "__main__":
    print("📊 Offline Voice Database Stats:")
    stats = get_offline_stats()
    if not stats:
        print("  ❌ No offline audio found!")
        print(f"  📁 Expected directory: {OFFLINE_AUDIO_DIR}")
        print(f"  💡 Run: python generate_offline_voices.py")
    else:
        for lang, cats in stats.items():
            print(f"\n  🌐 {lang.upper()}:")
            for cat, count in cats.items():
                print(f"    {cat}: {count} variants")
