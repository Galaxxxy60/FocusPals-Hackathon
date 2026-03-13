"""
FocusPals — Gemini 3.1 Flash-Lite Secondary Agent
Pre-classification, session summary, and lightweight text analysis.
Runs alongside the main 2.5 Flash Native Audio Live API agent.
"""

import asyncio
import io
import json
import time
import logging

from google.genai import types

import config as cfg
from config import state

log = logging.getLogger("FlashLite")

# ─── Model ──────────────────────────────────────────────────
LITE_MODEL = "gemini-3.1-flash-lite-preview"

# ─── Pre-Classification ────────────────────────────────────

_last_pre_classification = None  # Cache for hint injection
_classification_history = []     # Rolling history for session summary
_lite_start_time = 0.0           # Timestamp of first call — warmup delay
WARMUP_DELAY = 15.0              # Don't call Flash-Lite for first 15s (let Live API stabilize)

PRE_CLASSIFY_PROMPT = """You are a screen classification engine. Analyze this screenshot and classify the user's activity.

CRITICAL: Classify based on what you SEE on screen — the actual visible content, not the window title.
The screenshot shows ALL monitors. Focus on what occupies the MOST screen space and what the user is clearly interacting with.
A small foreground window does NOT define the user's activity if 80% of the screen shows something else.

Context (secondary hints — use as TIE-BREAKERS, not primary evidence):
- Active window title: {active_window}
- Other open windows: {open_windows}
- Declared task: {task}

Return ONLY a JSON object with these exact fields:
{{
  "category": "SANTE" | "ZONE_GRISE" | "FLUX" | "BANNIE" | "PROCRASTINATION_PRODUCTIVE",
  "alignment": 1.0 | 0.5 | 0.0,
  "reason": "<brief reason in 5 words max>",
  "description": "<describe SPECIFICALLY what is VISIBLE on screen — include video titles, article headlines, song names, website content, code project name, chat app name, game title, or whatever is visually prominent. Be specific, not generic. Example: 'YouTube: How to play drums in 10 minutes' NOT 'watching a video'. Max 20 words.>"
}}

Categories:
- SANTE: Work tools (IDE, terminal, creative software, ChatGPT, Blender, Godot)
- ZONE_GRISE: Communication apps (Messenger, Slack, Discord, WhatsApp)
- FLUX: Media/music (Spotify, YouTube Music, Deezer, Suno)
- BANNIE: Entertainment (Netflix, YouTube non-tutorial, Steam, Reddit, social media)
- PROCRASTINATION_PRODUCTIVE: Productive but not the scheduled task

Alignment:
- 1.0 = fully aligned with current task
- 0.5 = ambiguous / could be either
- 0.0 = clearly misaligned / procrastinating

If no task is set, use: SANTE→1.0, FLUX/ZONE_GRISE→0.5, BANNIE→0.0"""


async def pre_classify(jpeg_bytes: bytes, active_window: str,
                       open_windows: list, task: str = None) -> dict | None:
    """
    Fast pre-classification via Gemini 3.1 Flash-Lite.
    Returns a dict with {category, alignment, reason} or None on failure.
    Non-blocking — designed to run in parallel with the main scan loop.
    """
    if cfg.client is None:
        return None

    # Warmup guard: don't call Flash-Lite for first 15s
    global _lite_start_time
    if _lite_start_time == 0.0:
        _lite_start_time = time.time()
    if time.time() - _lite_start_time < WARMUP_DELAY:
        return None

    try:
        prompt = PRE_CLASSIFY_PROMPT.format(
            active_window=active_window,
            open_windows=open_windows,
            task=task or "NOT SET (free session)",
        )

        response = await cfg.client.aio.models.generate_content(
            model=LITE_MODEL,
            contents=[
                types.Part(text=prompt),
                types.Part(inline_data=types.Blob(
                    data=jpeg_bytes, mime_type="image/jpeg"
                )),
            ],
            config=types.GenerateContentConfig(
                temperature=0.1,  # Deterministic classification
                max_output_tokens=200,
                response_mime_type="application/json",  # Force valid JSON output
            ),
        )

        # Track telemetry
        state["_lite_api_calls"] += 1
        if hasattr(response, 'usage_metadata') and response.usage_metadata:
            state["_lite_input_tokens"] += response.usage_metadata.prompt_token_count or 0
            state["_lite_output_tokens"] += response.usage_metadata.candidates_token_count or 0

        # Parse JSON response
        text = response.text.strip()
        # Handle markdown code blocks
        if text.startswith("```"):
            text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()

        result = json.loads(text)

        # Validate
        valid_categories = {"SANTE", "ZONE_GRISE", "FLUX", "BANNIE", "PROCRASTINATION_PRODUCTIVE"}
        if result.get("category") not in valid_categories:
            return None
        alignment = float(result.get("alignment", 0.5))
        if alignment not in (0.0, 0.5, 1.0):
            # Snap to nearest valid value
            if alignment > 0.75:
                alignment = 1.0
            elif alignment > 0.25:
                alignment = 0.5
            else:
                alignment = 0.0
            result["alignment"] = alignment

        # Cache result
        global _last_pre_classification
        _last_pre_classification = {
            **result,
            "timestamp": time.time(),
        }

        # Add to history (rolling, max 200 entries)
        _classification_history.append({
            "time": time.time(),
            "window": active_window,
            "category": result["category"],
            "alignment": result["alignment"],
        })
        if len(_classification_history) > 200:
            _classification_history.pop(0)

        log.info(f"⚡ Lite: {result['category']} A:{result['alignment']} — {result.get('reason', '')}")
        return result

    except json.JSONDecodeError as e:
        log.warning(f"Flash-Lite JSON parse error: {e} | raw: {text[:200] if 'text' in dir() else '?'}")
        state["_lite_errors"] += 1
        return None
    except Exception as e:
        log.warning(f"Flash-Lite pre-classify error: {e}")
        state["_lite_errors"] += 1
        return None


def get_last_pre_classification() -> dict | None:
    """Return the most recent pre-classification, or None if stale (>30s)."""
    global _last_pre_classification
    if _last_pre_classification is None:
        return None
    if time.time() - _last_pre_classification["timestamp"] > 30:
        _last_pre_classification = None
        return None
    return _last_pre_classification


def get_pre_classify_hint() -> str:
    """Format the pre-classification as a hint string for the Live API prompt."""
    pc = get_last_pre_classification()
    if pc is None:
        return ""
    return f"[LITE_HINT] Pre-scan: {pc['category']} A:{pc['alignment']} ({pc.get('reason', 'n/a')}). You may agree or override."


# ─── Session Summary ───────────────────────────────────────

SESSION_SUMMARY_PROMPT = """You are a productivity analyst. Based on the following session data, generate a concise session summary.

## Session Data
- Duration: {duration_min} minutes
- Task: {task}
- Total scans: {total_scans}
- Language: {language}

## Activity Breakdown
{activity_breakdown}

## Classification Timeline (sampled)
{timeline}

## Instructions
Generate a SHORT, structured summary in {language_name} with:
1. **Productivity Score**: A percentage (0-100%) based on alignment ratio
2. **Focus Summary**: 1-2 sentences about how the session went
3. **Top Distractions**: List the top 3 distracting apps/sites if any
4. **Time Distribution**: Break down time by category (approximate %)
5. **Recommendation**: One actionable tip for next session

Keep it under 200 words. Be direct, like a coach reviewing performance."""


async def generate_session_summary(language: str = "en") -> str | None:
    """
    Generate a session summary using Gemini 3.1 Flash-Lite.
    Called at session end. Returns markdown text or None on failure.
    """
    if cfg.client is None or not _classification_history:
        return None

    try:
        # Calculate activity breakdown
        total = len(_classification_history)
        categories = {}
        aligned_count = 0
        for entry in _classification_history:
            cat = entry["category"]
            categories[cat] = categories.get(cat, 0) + 1
            if entry["alignment"] >= 1.0:
                aligned_count += 1

        breakdown_lines = []
        for cat, count in sorted(categories.items(), key=lambda x: -x[1]):
            pct = (count / total) * 100
            breakdown_lines.append(f"- {cat}: {count} scans ({pct:.0f}%)")
        activity_breakdown = "\n".join(breakdown_lines)

        # Sample timeline (every 5th entry to keep it manageable)
        sampled = _classification_history[::5][:20]
        timeline_lines = []
        session_start = _classification_history[0]["time"] if _classification_history else time.time()
        for entry in sampled:
            elapsed_min = int((entry["time"] - session_start) / 60)
            timeline_lines.append(
                f"  +{elapsed_min}min: {entry['window'][:40]} → {entry['category']} (A:{entry['alignment']})"
            )
        timeline = "\n".join(timeline_lines) if timeline_lines else "No data"

        # Duration
        if len(_classification_history) >= 2:
            duration = ((_classification_history[-1]["time"] - _classification_history[0]["time"]) / 60)
        else:
            duration = 0

        language_name = "français" if language == "fr" else "English"

        prompt = SESSION_SUMMARY_PROMPT.format(
            duration_min=int(duration),
            task=state.get("current_task") or "Non définie / Not set",
            total_scans=total,
            language=language,
            activity_breakdown=activity_breakdown,
            timeline=timeline,
            language_name=language_name,
        )

        response = await cfg.client.aio.models.generate_content(
            model=LITE_MODEL,
            contents=[types.Part(text=prompt)],
            config=types.GenerateContentConfig(
                temperature=0.7,
                max_output_tokens=500,
            ),
        )

        # Track telemetry
        state["_lite_api_calls"] += 1
        if hasattr(response, 'usage_metadata') and response.usage_metadata:
            state["_lite_input_tokens"] += response.usage_metadata.prompt_token_count or 0
            state["_lite_output_tokens"] += response.usage_metadata.candidates_token_count or 0

        summary = response.text.strip()
        log.info(f"📊 Session summary generated ({len(summary)} chars)")
        return summary

    except Exception as e:
        log.warning(f"Flash-Lite summary error: {e}")
        state["_lite_errors"] += 1
        return None


def clear_classification_history():
    """Reset classification history for a new session."""
    global _last_pre_classification, _lite_start_time
    _classification_history.clear()
    _last_pre_classification = None
    _lite_start_time = 0.0  # Reset warmup for next session


def get_lite_stats() -> dict:
    """Return Flash-Lite usage statistics."""
    return {
        "lite_calls": state.get("_lite_api_calls", 0),
        "lite_input_tokens": state.get("_lite_input_tokens", 0),
        "lite_output_tokens": state.get("_lite_output_tokens", 0),
        "lite_errors": state.get("_lite_errors", 0),
        "classifications_logged": len(_classification_history),
    }
