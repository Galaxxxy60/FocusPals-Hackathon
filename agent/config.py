"""
FocusPals — Shared Configuration & Mutable State
All constants, API setup, and the global state dict live here.
"""

import os
import sys
import time
import logging

from dotenv import load_dotenv
from google import genai

# ─── Logging ────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S"
)
log = logging.getLogger("Tama")

# ─── Paths ──────────────────────────────────────────────────
application_path = os.path.dirname(os.path.abspath(__file__))
env_path = os.path.join(application_path, '.env')
load_dotenv(env_path)

# ─── API ────────────────────────────────────────────────────
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
_api_key_present_at_start = bool(GEMINI_API_KEY)
if not GEMINI_API_KEY:
    print("⚠️  GEMINI_API_KEY manquante — configurez-la via ⚙️ Settings dans le menu radial")
    client = None
else:
    client = genai.Client(api_key=GEMINI_API_KEY, http_options={"api_version": "v1alpha"})
MODEL = "gemini-2.5-flash-native-audio-latest"

# ─── Audio Constants ────────────────────────────────────────
import pyaudio

FORMAT = pyaudio.paInt16
CHANNELS = 1
SEND_SAMPLE_RATE = 16000
RECEIVE_SAMPLE_RATE = 24000
CHUNK_SIZE = 1024

# ─── Suspicion / Break Constants ────────────────────────────
# Legacy static constants (kept for backward compat, used as fallback)
BREAK_CHECKPOINTS = [20, 40, 90, 120]   # Minutes before break suggestion
BREAK_DURATIONS   = [5,  8,  15, 20]    # Break duration per tier (minutes)

# Reminder interval when user refuses a break (minutes)
BREAK_REFUSE_REMINDER = 15


def get_dynamic_break_checkpoints(session_minutes: int = 50) -> tuple:
    """Compute break checkpoints based on session duration.
    Returns (checkpoints_list, durations_list).
    
    Philosophy: session_duration IS the work interval.
    User sets 90 min → they work 90 min → THEN Tama suggests a break.
    If refused, remind every BREAK_REFUSE_REMINDER minutes.
    
    Break duration scales with session length:
    - ≤15 min session: no break (too short)
    - 16-30 min: 3 min break
    - 31-60 min: 5 min break
    - 61-120 min: 10 min break  
    - >120 min: 15 min break
    """
    if session_minutes <= 15:
        return [], []
    
    # Break duration scales with work time
    if session_minutes <= 30:
        break_dur = 5
    elif session_minutes <= 60:
        break_dur = 10
    elif session_minutes <= 120:
        break_dur = 15
    else:
        break_dur = 20
    
    # First break = at session_duration
    # If refused, remind every BREAK_REFUSE_REMINDER min
    # Generate enough reminder slots (up to 3 extra reminders after the first)
    checkpoints = [session_minutes]
    durations = [break_dur]
    
    for i in range(1, 4):
        reminder = session_minutes + (BREAK_REFUSE_REMINDER * i)
        checkpoints.append(reminder)
        durations.append(break_dur)
    
    return checkpoints, durations
USER_SPEECH_TIMEOUT = 12.0              # Seconds to keep Tama unmuzzled
CONVERSATION_SILENCE_TIMEOUT = 30.0     # Seconds of silence before ending convo
CURIOUS_DURATION_THRESHOLD = 90         # Seconds on ambiguous app before Tama can ask

# Protected windows that should NEVER be closed
PROTECTED_WINDOWS = ["code", "cursor", "visual studio", "unreal", "blender", "word", "excel",
                     "figma", "photoshop", "premiere", "davinci", "ableton", "fl studio",
                     "suno", "notion", "obsidian", "terminal", "powershell",
                     "godot", "foculpal", "focuspals", "tama"]

# Browser keywords for close-tab mode detection
BROWSER_KEYWORDS = ["chrome", "firefox", "edge", "opera", "brave", "vivaldi", "chromium"]

# Single dict replaces all scattered globals. Every module reads/writes here.
state = {
    # Session
    "session_duration_minutes": 50,     # User-configurable session length
    "is_session_active": False,
    "session_start_time": None,
    "just_started_session": False,
    "current_mode": "libre",            # "libre", "conversation", "deep_work"
    "conversation_requested": False,
    "conversation_start_time": None,

    # Suspicion / ASC
    "current_suspicion_index": 0.0,
    "current_alignment": 1.0,
    "current_category": "SANTE",
    "current_task": None,
    "can_be_closed": True,
    "suspicion_above_3_start": None,
    "suspicion_above_6_start": None,
    "suspicion_at_9_start": None,
    "force_speech": False,

    # Display
    "current_tama_state": None,         # Set to TamaState.CALM at runtime
    "last_active_window_title": "Unknown",
    "active_window_start_time": time.time(),

    # Break system
    "current_break_index": 0,
    "break_reminder_active": False,
    "is_on_break": False,
    "break_start_time": None,
    "session_completed": False,         # True when session timer expired → triggers auto-end

    # VAD
    "user_spoke_at": 0.0,

    # Godot / UI
    "window_positioned": False,
    "godot_hwnd": None,
    "radial_shown": False,
    "_radial_cooldown_until": 0,
    "_mouse_was_away": True,
    "_mic_panel_pending": False,
    "_api_key_valid": False,
    "connected_ws_clients": set(),
    "main_loop": None,
    "tray_icon": None,
    "selected_mic_index": None,
    "language": "en",  # "en", "fr", "ja", "zh" — configurable via Settings panel
    "tama_volume": 1.0,  # 0.0 (mute) to 1.0 (full) — Tama's voice volume
    "tama_scale": 100,   # 50-150% — Tama window size percentage
    "screen_share_allowed": True,   # User can disable screen capture from Settings
    "mic_allowed": True,            # User can disable microphone from Settings
    "godot_process": None,
    "_session_resume_handle": None,
    # Mood system (Phase 1)
    "_current_mood": "calm",
    "_current_mood_intensity": 0.0,
    "_mood_anim_set": False,
    # Mood engine (Phase 2)
    "_mood_bias": 0.0,
    "_mood_recent_infractions": 0,
    "_mood_compliance_streak_start": None,
    "_mood_last_infraction_time": 0,
    # Confidence system (anti-cheat)
    "_confidence": 1.0,  # 0.1 (zero trust) → 1.0 (full trust) — modulates S decay speed
    # API Usage tracking
    "_api_connections": 0,           # Number of Gemini Live connections
    "_api_screen_pulses": 0,         # Number of screen pulses sent
    "_api_function_calls": 0,        # Total function calls received
    "_api_audio_chunks_sent": 0,     # Audio chunks sent to Gemini
    "_api_audio_chunks_recv": 0,     # Audio chunks received from Gemini
    "_api_connect_time_start": 0,    # Timestamp of current connection start
    "_api_total_connect_secs": 0.0,  # Cumulative connection time in seconds
    # Flash-Lite (3.1) secondary agent telemetry
    "_lite_api_calls": 0,            # Number of Flash-Lite generate_content calls
    "_lite_input_tokens": 0,         # Total input tokens consumed by Lite
    "_lite_output_tokens": 0,        # Total output tokens consumed by Lite
    "_lite_errors": 0,               # Number of Flash-Lite errors
    "_session_summary": None,        # Last generated session summary (markdown)
    # Gemini connection status (for Godot UI feedback)
    "gemini_connected": False,        # True when Gemini Live API session is active
    "_crash_context": None,           # Saved context when Tama crashes mid-speech
    "_resuming_from_crash": False,    # True when reconnecting after a crash
    "_last_audio_play_time": 0,       # Timestamp of last audio chunk played
    "_last_speech_ended": 0,          # Timestamp of last speech turn end
    # Strike fire sync (frame-precise hand animation trigger)
    "_pending_strike": None,          # Dict with hwnd/mode/title/reason — set by prepare_close_tab, consumed by fire_hand_animation
    "_strike_requested": False,       # True when fire_strike() called but close target not ready yet
    "_strike_requested_at": 0,        # Timestamp when _strike_requested was set — for auto-timeout
    "_strike_in_progress": False,     # True from first fire_strike until post-close reset — blocks re-fires
    # API stability guards
    "_api_processing_tool": False,    # True when processing tool calls — pauses audio/image sends to prevent 1011
    "_circuit_breaker_active": False, # True after 3+ crashes in 5min — degrades to text-only (no images)
    "_crash_timestamps": [],          # Rolling list of recent crash times for circuit breaker logic
}

# ─── Debug Tweaks (runtime-adjustable via F2 menu) ──────────
# These are global multipliers that modulate the A.S.C. engine.
# Saved to user_prefs.json so they persist across restarts.
tweaks = {
    "suspicion_gain_mult": 1.0,   # Multiplier on positive ΔS (higher = angrier faster)
    "suspicion_decay_mult": 1.0,  # Multiplier on negative ΔS (higher = calms faster)
    "confidence": 1.0,            # Direct override for C (0.1–1.0), synced to state["_confidence"]
    "mood_decay_secs": 20.0,      # Seconds for mood to fade back to calm
    "pulse_delay_mult": 1.0,      # Multiplier on pulse interval (higher = less frequent scans)
    # ── Stability toggles (ON/OFF for crash isolation) ──
    "affective_dialog": 1.0,      # 1.0 = ON, 0.0 = OFF — expressive voice (suspected 1011 trigger)
    "proactive_audio": 1.0,       # 1.0 = ON, 0.0 = OFF — Tama speaks spontaneously
    "thinking": 1.0,              # 1.0 = ON, 0.0 = OFF — thinking budget for Deep Work
    "voice_pitch": 1.0,           # Pitch shift multiplier: 1.0 = normal, 1.2 = kawaii, 0.8 = deeper
}


# ─── A.S.C. (Alignment Suspicion Control) Engine ────────────

def compute_can_be_closed(window_title: str) -> bool:
    """Returns False if the window contains unsaved work or is a creative tool."""
    title_lower = window_title.lower()
    for protected in PROTECTED_WINDOWS:
        if protected in title_lower:
            return False
    return True


def compute_delta_s(alignment: float, category: str) -> float:
    """Deterministic ΔS formula based on A.S.C. spec.
    Applies tweaks["suspicion_gain_mult"] and tweaks["suspicion_decay_mult"]."""
    if alignment >= 1.0:  # Aligned
        if category == "BANNIE":
            base = 0.3
        else:
            base = -3.0       # Fast decay when working — reward compliance
    elif alignment >= 0.5:  # Doubt — category matters!
        if category == "BANNIE":
            base = 1.5   # Banned app even in doubt → fast escalation
        elif category in ("FLUX", "ZONE_GRISE"):
            base = 0.8   # Foreground music/messaging → meaningful buildup
        elif category == "PROCRASTINATION_PRODUCTIVE":
            base = 0.6
        else:
            base = 0.3        # SANTE in doubt → minimal
    else:  # Misaligned (A = 0.0)
        if category == "BANNIE":
            base = 3.0    # ~3 pulses to S=9 (15 seconds)
        elif category == "ZONE_GRISE":
            base = 1.5
        elif category == "FLUX":
            base = 0.8
        elif category == "PROCRASTINATION_PRODUCTIVE":
            base = 0.8
        else:
            base = 1.5

    # Apply tweak multipliers
    if base > 0:
        return base * tweaks["suspicion_gain_mult"]
    else:
        return base * tweaks["suspicion_decay_mult"]
