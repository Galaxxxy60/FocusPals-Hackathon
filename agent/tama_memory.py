"""
FocusPals — Tama's Long-Term Memory
Persistent JSON-backed memory that survives across sessions.
Stores user identity, session stats, and relationship data.
Separate from user_prefs.json (which handles technical settings).
"""

import json
import os
import time
from datetime import datetime, timezone

from config import application_path, state

# ─── Path ───────────────────────────────────────────────────
MEMORY_PATH = os.path.join(application_path, "tama_memory.json")

# ─── Default Memory Schema ──────────────────────────────────
_DEFAULT_MEMORY = {
    # User identity
    "user_name": None,              # Set when user introduces themselves or via settings

    # Session stats
    "first_session_date": None,     # ISO date of very first session
    "last_session_date": None,      # ISO date of most recent session
    "total_sessions": 0,            # Number of completed work sessions
    "total_focus_minutes": 0,       # Cumulative minutes spent focused
    "total_strikes": 0,             # Total drone strikes fired across all sessions
    "longest_streak_minutes": 0,    # Best single session focus time (minutes)

    # Per-day history for calendar heatmap
    # { "2026-03-16": { "minutes": 50, "sessions": 1 }, ... }
    "daily_history": {},

    # Relationship progression
    "relationship_level": 0,        # 0 = stranger, 1-5 = acquaintance, 6-10 = friend, 11+ = veteran
    "memorable_moments": [],        # Short notable events (max 20, FIFO)

    # Preferences Tama learned
    "known_projects": [],           # Projects user has worked on (max 10, FIFO)
    "preferred_break_style": None,  # "short" | "long" | None — inferred over time
}

# ─── In-memory cache ────────────────────────────────────────
_memory: dict = {}


def load_memory() -> dict:
    """Load tama_memory.json into memory. Creates default if missing."""
    global _memory
    try:
        if os.path.exists(MEMORY_PATH):
            with open(MEMORY_PATH, "r", encoding="utf-8") as f:
                loaded = json.load(f)
            # Merge with defaults (adds new keys from schema updates)
            merged = {**_DEFAULT_MEMORY, **loaded}
            _memory = merged
        else:
            _memory = dict(_DEFAULT_MEMORY)
            _memory["first_session_date"] = datetime.now().isoformat()
            _save_memory()
    except Exception as e:
        print(f"⚠️ Failed to load tama_memory.json: {e}")
        _memory = dict(_DEFAULT_MEMORY)
    return _memory


def _save_memory():
    """Persist current memory to disk."""
    try:
        with open(MEMORY_PATH, "w", encoding="utf-8") as f:
            json.dump(_memory, f, indent=2, ensure_ascii=False)
    except Exception as e:
        print(f"⚠️ Failed to save tama_memory.json: {e}")


def get_memory() -> dict:
    """Return current memory (loaded or cached)."""
    if not _memory:
        load_memory()
    return _memory


def is_first_session() -> bool:
    """True if user has never completed a session (brand new user)."""
    mem = get_memory()
    return mem.get("total_sessions", 0) == 0


def is_memory_empty() -> bool:
    """True if memory has no meaningful data (all defaults).
    Used for the Reset Memory button — greyed out only when truly empty."""
    mem = get_memory()
    if mem.get("user_name"):
        return False
    if mem.get("total_sessions", 0) > 0:
        return False
    if mem.get("total_strikes", 0) > 0:
        return False
    if mem.get("total_focus_minutes", 0) > 0:
        return False
    if mem.get("relationship_level", 0) > 0:
        return False
    if mem.get("memorable_moments"):
        return False
    if mem.get("known_projects"):
        return False
    return True


def reset_memory():
    """Wipe all memory and start fresh. Called from Settings > Reset."""
    global _memory
    _memory = dict(_DEFAULT_MEMORY)
    try:
        if os.path.exists(MEMORY_PATH):
            os.remove(MEMORY_PATH)
        _save_memory()
        print("🗑️ tama_memory.json reset to defaults")
    except Exception as e:
        print(f"⚠️ Failed to reset tama_memory.json: {e}")


# ─── Update Helpers ─────────────────────────────────────────

def set_user_name(name: str):
    """Store the user's name. Called when user introduces themselves."""
    _memory["user_name"] = name.strip()
    _save_memory()
    print(f"💾 User name saved: {name}")


def record_session_start():
    """Called when a work session begins."""
    now = datetime.now().isoformat()
    if _memory.get("first_session_date") is None:
        _memory["first_session_date"] = now
    _memory["last_session_date"] = now
    _save_memory()


def record_session_end(focus_minutes: float):
    """Called when a work session ends. Updates cumulative stats.
    Auto-logs memorable moments for notable achievements."""
    prev_record = _memory.get("longest_streak_minutes", 0)
    _memory["total_sessions"] += 1
    _memory["total_focus_minutes"] += int(focus_minutes)

    # Update longest streak + auto-log if record beaten
    if focus_minutes > prev_record:
        _memory["longest_streak_minutes"] = int(focus_minutes)
        if prev_record > 0:  # Don't log the very first session as "record"
            add_memorable_moment(f"Nouveau record ! {int(focus_minutes)}min (ancien: {prev_record}min)")

    # Auto-log marathon sessions (2h+)
    if focus_minutes >= 120:
        add_memorable_moment(f"Session marathon de {int(focus_minutes)}min !")
    elif focus_minutes >= 60 and _memory["total_sessions"] <= 5:
        # First long sessions are memorable for new users
        add_memorable_moment(f"Première grosse session : {int(focus_minutes)}min")

    # Milestone sessions
    if _memory["total_sessions"] in (10, 25, 50, 100, 200):
        add_memorable_moment(f"Cap des {_memory['total_sessions']} sessions !")

    # Strike-free streak (notable if 0 strikes in a 30min+ session)
    session_strikes = _memory.get("_session_strikes", 0)
    if focus_minutes >= 30 and session_strikes == 0 and _memory.get("total_strikes", 0) > 0:
        # They usually get struck but this time they were clean
        add_memorable_moment(f"Session parfaite (0 strike, {int(focus_minutes)}min)")
    _memory.pop("_session_strikes", None)  # Reset per-session counter

    # Update relationship level (1 point per session, bonus for long ones)
    _memory["relationship_level"] += 1
    if focus_minutes >= 60:
        _memory["relationship_level"] += 1  # Bonus for long sessions

    # Track daily history for calendar heatmap
    today = datetime.now().strftime("%Y-%m-%d")
    daily = _memory.get("daily_history", {})
    if today not in daily:
        daily[today] = {"minutes": 0, "sessions": 0}
    daily[today]["minutes"] += int(focus_minutes)
    daily[today]["sessions"] += 1
    _memory["daily_history"] = daily

    _memory["last_session_date"] = datetime.now().isoformat()
    _save_memory()
    print(f"💾 Session recorded: {int(focus_minutes)}min | Total: {_memory['total_sessions']} sessions")


def record_strike():
    """Called when a drone strike is fired."""
    _memory["total_strikes"] = _memory.get("total_strikes", 0) + 1
    # Track per-session strikes for "perfect session" detection
    _memory["_session_strikes"] = _memory.get("_session_strikes", 0) + 1
    _save_memory()


def add_memorable_moment(moment: str):
    """Add a short notable event (max 20, oldest dropped)."""
    moments = _memory.get("memorable_moments", [])
    moments.append({
        "text": moment[:100],  # Cap length
        "date": datetime.now().isoformat()
    })
    if len(moments) > 20:
        moments = moments[-20:]
    _memory["memorable_moments"] = moments
    _save_memory()


def add_known_project(project: str):
    """Track a project the user has worked on (max 10, FIFO)."""
    projects = _memory.get("known_projects", [])
    # Don't add duplicates
    project_clean = project.strip().lower()
    if project_clean not in [p.lower() for p in projects]:
        projects.append(project.strip())
        if len(projects) > 10:
            projects = projects[-10:]
        _memory["known_projects"] = projects
        _save_memory()


# ─── Prompt Injection ──────────────────────────────────────

def get_memory_context(lang: str = "fr") -> str:
    """
    Generate a COMPACT context string for injection into the System Prompt.
    DESIGN: must be ultra-lightweight for returning users — the system prompt
    is already huge, every token counts. Only first-session users get the
    onboarding flavor text.
    """
    mem = get_memory()
    total = mem.get("total_sessions", 0)
    name = mem.get("user_name")

    # ── First session: onboarding context ──
    if total == 0:
        if lang == "fr":
            return "[MÉMOIRE] Première session. Fais connaissance naturellement."
        else:
            return "[MEMORY] First session. Get to know each other naturally."

    # ── Returning users: ultra-compact, one line max ──
    parts = []

    # Name (only if known)
    if name:
        parts.append(name)

    # Compact session stat
    parts.append(f"{total} sessions")

    # Total focus (compact format)
    total_min = mem.get("total_focus_minutes", 0)
    if total_min >= 60:
        parts.append(f"{total_min // 60}h focus")
    elif total_min > 0:
        parts.append(f"{total_min}min focus")

    # Personal best (gives Tama a hook: "tu te rappelles ta session de 5h ?")
    longest = mem.get("longest_streak_minutes", 0)
    if longest >= 30:
        parts.append(f"record: {longest}min")

    # Strikes (only if notable)
    strikes = mem.get("total_strikes", 0)
    if strikes > 3:
        parts.append(f"{strikes} strikes")

    header = "[MÉMOIRE]" if lang == "fr" else "[MEMORY]"
    ctx = f"{header} {' | '.join(parts)}"

    # ── Memorable moments: last 3, ultra-short ──
    moments = mem.get("memorable_moments", [])
    if moments:
        recent = moments[-3:]  # Only the 3 most recent
        moment_texts = [m["text"] if isinstance(m, dict) else str(m) for m in recent]
        ctx += " ★ " + " / ".join(moment_texts)
    return ctx


# ─── Activity Panel Data ──────────────────────────────────

def _calculate_streak() -> int:
    """Calculate current consecutive-day streak."""
    daily = get_memory().get("daily_history", {})
    if not daily:
        return 0
    from datetime import timedelta
    today = datetime.now().date()
    streak = 0
    day = today
    while True:
        key = day.strftime("%Y-%m-%d")
        if key in daily and daily[key].get("minutes", 0) > 0:
            streak += 1
            day -= timedelta(days=1)
        else:
            break
    return streak


_ACHIEVEMENT_DEFS = [
    # Streaks
    {"id": "streak_3",   "name_fr": "Volontaire",  "name_en": "Dedicated",    "desc_fr": "3 jours de suite",       "desc_en": "3 days in a row",       "req": 3,   "icon": "\U0001f525",  "type": "streak"},
    {"id": "streak_10",  "name_fr": "Sérieux",     "name_en": "Serious",     "desc_fr": "10 jours de suite",      "desc_en": "10 days in a row",      "req": 10,  "icon": "\U0001f525\U0001f525", "type": "streak"},
    {"id": "streak_30",  "name_fr": "Fiable",      "name_en": "Reliable",    "desc_fr": "30 jours de suite",      "desc_en": "30 days in a row",      "req": 30,  "icon": "\U0001f31f", "type": "streak"},
    # Volume (per day)
    {"id": "vol_4h",     "name_fr": "Travailleur", "name_en": "Hard Worker", "desc_fr": "4h en une journée",      "desc_en": "4h in a single day",    "req": 240, "icon": "\U0001f4aa", "type": "daily_vol"},
    {"id": "vol_8h",     "name_fr": "Besogneux",   "name_en": "Workaholic",  "desc_fr": "8h en une journée",      "desc_en": "8h in a single day",    "req": 480, "icon": "\U0001f4aa\U0001f4aa", "type": "daily_vol"},
    # Total sessions
    {"id": "sess_10",    "name_fr": "10 sessions", "name_en": "10 Sessions", "desc_fr": "Compléter 10 sessions",  "desc_en": "Complete 10 sessions",  "req": 10,  "icon": "\u26a1",    "type": "total_sess"},
    {"id": "sess_25",    "name_fr": "25 sessions", "name_en": "25 Sessions", "desc_fr": "Compléter 25 sessions",  "desc_en": "Complete 25 sessions",  "req": 25,  "icon": "\u26a1\u26a1", "type": "total_sess"},
    {"id": "sess_50",    "name_fr": "50 sessions", "name_en": "50 Sessions", "desc_fr": "Compléter 50 sessions",  "desc_en": "Complete 50 sessions",  "req": 50,  "icon": "\u26a1\u26a1\u26a1", "type": "total_sess"},
    {"id": "sess_100",   "name_fr": "Centurion",   "name_en": "Centurion",   "desc_fr": "Compléter 100 sessions", "desc_en": "Complete 100 sessions", "req": 100, "icon": "\U0001f3c6", "type": "total_sess"},
    # Total focus hours
    {"id": "focus_10h",  "name_fr": "10h focus",   "name_en": "10h Focus",   "desc_fr": "10 heures de focus",     "desc_en": "10 hours of focus",     "req": 600, "icon": "\u23f0",    "type": "total_min"},
    {"id": "focus_50h",  "name_fr": "50h focus",   "name_en": "50h Focus",   "desc_fr": "50 heures de focus",     "desc_en": "50 hours of focus",     "req": 3000,"icon": "\u23f0\u23f0", "type": "total_min"},
    {"id": "focus_100h", "name_fr": "100h focus",  "name_en": "100h Focus",  "desc_fr": "100 heures cumulées",    "desc_en": "100 cumulative hours",  "req": 6000,"icon": "\U0001f451", "type": "total_min"},
]


def get_activity_data(lang: str = "fr") -> dict:
    """Return all data needed for the Activity panel in Godot."""
    mem = get_memory()
    daily = mem.get("daily_history", {})
    streak = _calculate_streak()
    total_sessions = mem.get("total_sessions", 0)
    total_minutes = mem.get("total_focus_minutes", 0)
    max_daily = max((d.get("minutes", 0) for d in daily.values()), default=0)
    # Use "en" as fallback for non-fr languages
    lk = lang if lang == "fr" else "en"

    achievements = []
    for defn in _ACHIEVEMENT_DEFS:
        progress = 0
        if defn["type"] == "streak":
            progress = streak
        elif defn["type"] == "daily_vol":
            progress = max_daily
        elif defn["type"] == "total_sess":
            progress = total_sessions
        elif defn["type"] == "total_min":
            progress = total_minutes
        achievements.append({
            "id": defn["id"],
            "name": defn.get(f"name_{lk}", defn.get("name_en", "")),
            "desc": defn.get(f"desc_{lk}", defn.get("desc_en", "")),
            "icon": defn["icon"],
            "req": defn["req"],
            "progress": min(progress, defn["req"]),
            "unlocked": progress >= defn["req"],
        })

    return {
        "daily_history": daily,
        "streak": streak,
        "total_sessions": total_sessions,
        "total_minutes": total_minutes,
        "achievements": achievements,
    }

