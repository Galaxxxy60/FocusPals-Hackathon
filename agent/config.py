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
BREAK_CHECKPOINTS = [20, 40, 90, 120]   # Minutes before break suggestion
BREAK_DURATIONS   = [5,  8,  15, 20]    # Break duration per tier (minutes)
USER_SPEECH_TIMEOUT = 12.0              # Seconds to keep Tama unmuzzled
CONVERSATION_SILENCE_TIMEOUT = 20.0     # Seconds of silence before ending convo

# Protected windows that should NEVER be closed
PROTECTED_WINDOWS = ["code", "cursor", "visual studio", "unreal", "blender", "word", "excel",
                     "figma", "photoshop", "premiere", "davinci", "ableton", "fl studio",
                     "suno", "notion", "obsidian", "terminal", "powershell",
                     "godot", "foculpal", "focuspals", "tama"]

# Browser keywords for close-tab mode detection
BROWSER_KEYWORDS = ["chrome", "firefox", "edge", "opera", "brave", "vivaldi", "chromium"]

# ─── Shared Mutable State ───────────────────────────────────
# Single dict replaces all scattered globals. Every module reads/writes here.
state = {
    # Session
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
    "godot_process": None,
    "_session_resume_handle": None,
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
    """Deterministic ΔS formula based on A.S.C. spec."""
    if alignment >= 1.0:  # Aligned
        if category == "BANNIE":
            return 0.2
        return -2.0
    elif alignment >= 0.5:  # Doubt
        return 0.2
    else:  # Misaligned (A = 0.0)
        if category == "BANNIE":
            return 5.0
        elif category == "ZONE_GRISE":
            return 1.0
        elif category == "FLUX":
            return 0.5
        elif category == "PROCRASTINATION_PRODUCTIVE":
            return 0.5
        else:
            return 1.0
