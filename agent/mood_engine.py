"""
FocusPals — Mood Engine
Computes Tama's organic mood bias based on context (not random).
Provides natural language mood descriptions for injection into the Gemini prompt.
"""

import math
import time

from config import state


# ─── Mood Bias Calculation ──────────────────────────────────

def compute_mood_bias() -> float:
    """
    Returns a bias between -1.5 (tolerant) and +1.5 (irritable).
    Based on REAL contextual factors, not pure randomness.

    Negative = Tama is chill, tolerant
    Positive = Tama is on edge, irritable
    """
    bias = 0.0

    # Factor 1: Recent infractions (last 30 min window)
    # More procrastination recently → Tama is more irritable
    recent = state.get("_mood_recent_infractions", 0)
    bias += min(recent * 0.3, 1.0)  # Cap at +1.0

    # Factor 2: Compliance streak (how long user has been working well)
    # Long streak → Tama relaxes
    streak_start = state.get("_mood_compliance_streak_start")
    if streak_start:
        streak_min = (time.time() - streak_start) / 60.0
        if streak_min > 60:
            bias -= 0.8   # 1h+ of good work → she's chill
        elif streak_min > 30:
            bias -= 0.5   # 30 min → she relaxes
        elif streak_min > 15:
            bias -= 0.2   # 15 min → slight ease

    # Factor 3: Time of day
    # Late evening → more tolerant (shared fatigue)
    # Early morning → slightly tolerant (not fully awake)
    hour = time.localtime().tm_hour
    if hour >= 20:
        bias -= 0.4   # After 8pm → tired together
    elif hour >= 18:
        bias -= 0.2   # After 6pm → winding down
    elif hour < 8:
        bias -= 0.3   # Before 8am → both sleepy

    # Factor 4: Session duration fatigue
    # If session has been going for a long time, Tama becomes more tolerant
    # (she respects the grind, even if there are small slips)
    session_start = state.get("session_start_time")
    if session_start:
        session_min = (time.time() - session_start) / 60.0
        if session_min > 120:
            bias -= 0.4   # 2h+ → big respect
        elif session_min > 60:
            bias -= 0.2   # 1h+ → some respect

    # Factor 5: Micro-chaos (Perlin-like oscillation)
    # Small natural fluctuations (~±0.3, period ~10 min)
    # Makes Tama feel alive — sometimes slightly more or less tolerant
    t = time.time() / 600.0  # ~10 min cycle
    chaos = 0.25 * math.sin(2.7 * t) * math.cos(1.3 * t + 0.7)
    bias += chaos

    return max(-1.5, min(1.5, bias))


# ─── Mood Context for Gemini Prompt ─────────────────────────

def get_mood_context(lang: str = "fr") -> str:
    """
    Returns a natural language description of Tama's current mood.
    Injected into the [SYSTEM] prompt at each scan.
    Gemini interprets this organically — no numbers exposed.
    """
    bias = compute_mood_bias()
    state["_mood_bias"] = bias  # Store for debug logging

    if lang == "en":
        if bias <= -1.0:
            return "You're in a great mood — Nicolas has been working well, you're relaxed and tolerant. A small slip won't bother you."
        elif bias <= -0.5:
            return "You're in a good mood. Nicolas is working well. You're more patient than usual."
        elif bias <= 0.2:
            return "Neutral mood. Nothing special, you're observing normally."
        elif bias <= 0.7:
            return "You're a bit irritable. Nicolas has had a few slips recently. Your patience is wearing thin."
        elif bias <= 1.0:
            return "You're irritable. Nicolas has procrastinated multiple times. Your patience is razor-thin."
        else:
            return "You're on the edge. Nicolas has pushed too far. The slightest slip and you'll explode."
    else:
        if bias <= -1.0:
            return "Tu es de très bonne humeur — Nicolas a bien bossé, tu es détendue et tolérante. Un petit écart ne te dérangera pas."
        elif bias <= -0.5:
            return "Tu es de bonne humeur. Nicolas travaille bien. Tu es plus patiente que d'habitude."
        elif bias <= 0.2:
            return "Humeur neutre. Rien de spécial, tu observes normalement."
        elif bias <= 0.7:
            return "Tu es un peu irritable. Nicolas a fait quelques écarts récemment. Ta patience est un peu entamée."
        elif bias <= 1.0:
            return "Tu es irritable. Nicolas a procrastiné plusieurs fois. Ta patience est fine, tu es sur les nerfs."
        else:
            return "Tu es au bord de la crise. Nicolas a trop abusé. Le moindre écart et tu exploses."


# ─── Tracking Helpers ───────────────────────────────────────

def track_infraction():
    """Called when classify_screen returns a misaligned result."""
    state["_mood_recent_infractions"] = state.get("_mood_recent_infractions", 0) + 1
    state["_mood_compliance_streak_start"] = None  # Reset streak
    state["_mood_last_infraction_time"] = time.time()


def track_compliance():
    """Called when classify_screen returns an aligned result."""
    if state.get("_mood_compliance_streak_start") is None:
        state["_mood_compliance_streak_start"] = time.time()

    # Decay old infractions over time (forgiveness)
    # Every 10 min of good behavior, reduce infraction count by 1
    last_infraction = state.get("_mood_last_infraction_time", 0)
    if last_infraction and (time.time() - last_infraction) > 600:  # 10 min
        current = state.get("_mood_recent_infractions", 0)
        if current > 0:
            state["_mood_recent_infractions"] = current - 1
            state["_mood_last_infraction_time"] = time.time()  # Reset decay timer
