"""
FocusPals — Godot Bridge
WebSocket server (Godot ↔ Python), Godot launcher, click-through toggle,
edge mouse monitor, and radial menu handling.
"""

import asyncio
import ctypes
import ctypes.wintypes
import json
import os
import subprocess
import sys
import time
import threading

import websockets

from config import application_path, state, tweaks, BREAK_CHECKPOINTS, BREAK_DURATIONS, get_dynamic_break_checkpoints
from audio import get_available_mics, refresh_mic_cache, select_mic, resolve_default_mic
from ui import TamaState, start_session, quit_app, update_display, broadcast_to_godot
from flash_lite import get_lite_stats, clear_classification_history, generate_session_summary


# ─── Click-Through Toggle ───────────────────────────────────
# ARCHITECTURE: Click-through uses a CENTRALIZED MANAGER pattern.
# Instead of panels toggling click-through directly, each panel sets its own
# state flag, then calls _update_click_through(). The manager checks ALL flags
# and only enables click-through when NO panel needs mouse input.
# This prevents one panel closing from breaking another panel's clicks.
# See CLICK_THROUGH_GUIDE.md for the full documentation.

def _toggle_click_through(enable: bool):
    """Low-level Win32 toggle. DO NOT call directly — use _update_click_through()."""
    hwnd = state["godot_hwnd"]
    if not hwnd:
        return
    user32 = ctypes.windll.user32
    GWL_EXSTYLE = -20
    WS_EX_LAYERED    = 0x80000
    WS_EX_TRANSPARENT = 0x20
    WS_EX_TOOLWINDOW  = 0x80
    if enable:
        user32.SetWindowLongW(hwnd, GWL_EXSTYLE,
                              WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW)
    else:
        user32.SetWindowLongW(hwnd, GWL_EXSTYLE,
                              WS_EX_LAYERED | WS_EX_TOOLWINDOW)


def _update_click_through():
    """Centralized click-through manager — checks ALL panel state flags.
    Click-through is only enabled when NO panel needs mouse input.
    Call this after ANY state flag change."""
    needs_clicks = (
        state.get("radial_shown", False)
        or state.get("_settings_panel_open", False)
        or state.get("_tweaks_panel_open", False)
        or state.get("_quit_dialog_open", False)
    )
    _toggle_click_through(not needs_clicks)


# ─── Menu Action Handler ───────────────────────────────────

def _handle_menu_action(action: str):
    """Handle radial menu item clicks."""
    if action == "session":
        if not state["is_session_active"]:
            start_session("Radial Menu")
        else:
            print("⏸️ Session déjà en cours.")
    elif action == "talk":
        if state["is_session_active"]:
            print("🫰 Déjà en session Deep Work — Tama t'écoute déjà !")
        elif state["conversation_requested"] or state["current_mode"] == "conversation":
            print("🫰 Hey Tama déjà actif.")
        else:
            state["conversation_requested"] = True
            print("🫰 Hey Tama activé !")
            # Immediately notify Godot that we're connecting
            # This gives instant visual feedback before the Gemini API connection is established
            import websockets as _ws_lib
            _connecting_msg = json.dumps({"command": "CONNECTION_STATUS", "status": "connecting"})
            _ws_lib.broadcast(state["connected_ws_clients"], _connecting_msg)
    elif action == "settings":
        # Settings panel is handled via WebSocket GET_SETTINGS, not via menu action
        # This is a fallback if triggered via menu action instead
        _send_settings_to_godot()
    elif action == "quit":
        quit_app(state["tray_icon"], None)


# ─── Debug Tweaks Persistence ──────────────────────────────

def _load_tweaks():
    """Load tweaks from user_prefs.json (under 'tweaks' key)."""
    from audio import _load_prefs
    prefs = _load_prefs()
    saved = prefs.get("tweaks", {})
    for k in tweaks:
        if k in saved:
            try:
                tweaks[k] = float(saved[k])
            except (ValueError, TypeError):
                pass
    # Sync confidence to state
    state["_confidence"] = tweaks["confidence"]


def _save_tweaks():
    """Persist current tweaks to user_prefs.json."""
    from audio import _save_prefs
    _save_prefs({"tweaks": dict(tweaks)})


# Load saved tweaks at import time (startup)
_load_tweaks()


# ─── Settings Helpers ──────────────────────────────────────

def _validate_api_key(key: str) -> bool:
    """Test an API key by making a lightweight Gemini API call."""
    try:
        from google import genai
        test_client = genai.Client(api_key=key, http_options={"api_version": "v1alpha"})
        # Lightweight call — just list models (no tokens consumed)
        test_client.models.get(model="gemini-2.0-flash")
        print(f"✅ API key valid (key: {key[:8]}...)")
        return True
    except Exception as e:
        print(f"❌ API key invalid: {e}")
        return False


def _get_api_usage_stats() -> dict:
    """Collect API usage stats from state for display in settings."""
    total_secs = state["_api_total_connect_secs"]
    # Add live connection time if currently connected
    if state["_api_connect_time_start"] > 0:
        total_secs += time.time() - state["_api_connect_time_start"]
    lite = get_lite_stats()
    return {
        "connections": state["_api_connections"],
        "screen_pulses": state["_api_screen_pulses"],
        "function_calls": state["_api_function_calls"],
        "audio_sent": state["_api_audio_chunks_sent"],
        "audio_recv": state["_api_audio_chunks_recv"],
        "connect_secs": int(total_secs),
        # Flash-Lite (3.1) secondary agent stats
        "lite_calls": lite["lite_calls"],
        "lite_input_tokens": lite["lite_input_tokens"],
        "lite_output_tokens": lite["lite_output_tokens"],
        "lite_errors": lite["lite_errors"],
    }


def _get_key_hint() -> str:
    """Return an obfuscated hint of the API key (last 4 chars visible)."""
    import config
    key = config.GEMINI_API_KEY or ""
    if len(key) < 5:
        return ""
    return "•" * 8 + key[-4:]


def _build_settings_data(mics: list) -> dict:
    """Build the SETTINGS_DATA payload. Single source of truth for all settings updates."""
    import config
    return {
        "command": "SETTINGS_DATA",
        "mics": mics,
        "selected": state["selected_mic_index"] if state["selected_mic_index"] is not None else -1,
        "has_api_key": bool(config.GEMINI_API_KEY),
        "key_valid": state["_api_key_valid"],
        "key_hint": _get_key_hint(),
        "language": state["language"],
        "tama_volume": state["tama_volume"],
        "session_duration": state.get("session_duration_minutes", 50),
        "api_usage": _get_api_usage_stats(),
        "screen_share_allowed": state["screen_share_allowed"],
        "mic_allowed": state["mic_allowed"],
        "tama_scale": state["tama_scale"]
    }


def _send_settings_to_godot():
    """Send current settings to all connected Godot clients."""
    mics = get_available_mics()  # returns cache if <30s old
    broadcast_to_godot(json.dumps(_build_settings_data(mics)))


def _update_api_key(new_key: str) -> bool:
    """Update the Gemini API key in .env, validate, and reinitialize the client.
    Returns True if the key is valid."""
    import config
    from google import genai

    # Validate FIRST before saving
    valid = _validate_api_key(new_key)

    # Save to .env regardless (user might fix network later)
    env_path = os.path.join(application_path, '.env')
    lines = []
    key_found = False
    if os.path.exists(env_path):
        with open(env_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()

    new_lines = []
    for line in lines:
        if line.strip().startswith('GEMINI_API_KEY='):
            new_lines.append(f'GEMINI_API_KEY={new_key}\n')
            key_found = True
        else:
            new_lines.append(line)

    if not key_found:
        new_lines.append(f'GEMINI_API_KEY={new_key}\n')

    with open(env_path, 'w', encoding='utf-8') as f:
        f.writelines(new_lines)

    # Update config module
    config.GEMINI_API_KEY = new_key
    os.environ["GEMINI_API_KEY"] = new_key

    # Reinitialize client
    config.client = genai.Client(api_key=new_key, http_options={"api_version": "v1alpha"})

    status = "✅ valide" if valid else "❌ invalide"
    print(f"🔑 API key saved to .env ({status}, key: {new_key[:8]}...)")
    state["_api_key_valid"] = valid
    return valid


# ─── Mouse Edge Monitor ────────────────────────────────────

def mouse_edge_monitor():
    """Detects when the cursor reaches the right screen edge (bottom third only) to show the radial menu."""

    class POINT(ctypes.Structure):
        _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]

    user32 = ctypes.windll.user32
    screen_w = user32.GetSystemMetrics(0)

    # MonitorFromPoint constants
    MONITOR_DEFAULTTONULL = 0

    # Get handle to the primary monitor (where Godot lives)
    origin = POINT(0, 0)
    primary_monitor = user32.MonitorFromPoint(origin, MONITOR_DEFAULTTONULL)

    work_area = ctypes.wintypes.RECT()
    ctypes.windll.user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(work_area), 0)
    detect_y_min = work_area.bottom - 500
    print(f"🖱️ [EdgeMonitor] Démarré — écran: {screen_w}px, zone Y: {detect_y_min}-{work_area.bottom}, primary_monitor: {primary_monitor}")

    radial_shown_time = 0

    while True:
        pt = POINT()
        user32.GetCursorPos(ctypes.byref(pt))

        live_screen_w = user32.GetSystemMetrics(0)
        if live_screen_w != screen_w:
            print(f"⚠️ [EdgeMonitor] DPI DRIFT! screen_w changed: {screen_w} → {live_screen_w}")
            screen_w = live_screen_w

        # Check if cursor is on the PRIMARY monitor (where Godot/Tama lives)
        # This prevents false triggers on secondary monitors in any arrangement
        cursor_monitor = user32.MonitorFromPoint(pt, MONITOR_DEFAULTTONULL)
        on_primary = (cursor_monitor == primary_monitor)

        near_edge = on_primary and (screen_w - 5) <= pt.x <= screen_w
        in_zone = pt.y >= detect_y_min

        if not near_edge or not in_zone:
            state["_mouse_was_away"] = True

        if near_edge and in_zone and not state["radial_shown"] and state["_mouse_was_away"] and time.time() > state["_radial_cooldown_until"] and not state.get("_settings_panel_open", False) and not state.get("_tweaks_panel_open", False) and state["connected_ws_clients"]:
            state["radial_shown"] = True
            state["_mouse_was_away"] = False
            radial_shown_time = time.time()
            state["_radial_cooldown_until"] = 0
            print(f"🖱️ [EdgeMonitor] SHOW_RADIAL ({pt.x}, {pt.y}) screen_w={screen_w}")
            _update_click_through()  # radial_shown=True → CT off
            msg = json.dumps({"command": "SHOW_RADIAL"})
            broadcast_to_godot(msg)

        # Safety timeout: if radial shown for >30s, something went wrong — ask Godot to hide it
        if state["radial_shown"] and (time.time() - radial_shown_time > 30.0):
            state["radial_shown"] = False
            state["_radial_cooldown_until"] = 0
            # Let Godot decide whether to re-enable click-through
            # (it checks if settings/quit dialog is open before doing so)
            msg = json.dumps({"command": "HIDE_RADIAL"})
            broadcast_to_godot(msg)
            _update_click_through()  # radial_shown=False → manager decides

        time.sleep(0.1)


# ─── WebSocket Handler ──────────────────────────────────────

async def ws_handler(websocket):
    """Handle incoming WebSocket messages from Godot."""
    state["connected_ws_clients"].add(websocket)
    try:
      try:
        async for message in websocket:
            try:
                data = json.loads(message)
                cmd = data.get("command", "")
                if cmd == "START_SESSION":
                    clear_classification_history()  # Fresh history for new session
                    start_session("Interface Godot 3D")
                elif cmd == "HIDE_RADIAL":
                    state["radial_shown"] = False
                    state["_mouse_was_away"] = True
                    state["_radial_cooldown_until"] = 0
                    _update_click_through()  # manager checks all flags
                elif cmd == "MENU_ACTION":
                    action = data.get("action", "")
                    _handle_menu_action(action)
                elif cmd == "SHOW_QUIT":
                    state["_quit_dialog_open"] = True
                    _update_click_through()
                elif cmd == "QUIT_CLOSED":
                    state["_quit_dialog_open"] = False
                    _update_click_through()
                elif cmd == "SETTINGS_CLOSED":
                    state["_settings_panel_open"] = False
                    _update_click_through()  # manager checks all flags
                    print("⚙️ Settings panel closed")
                elif cmd == "GET_SETTINGS":
                    state["_settings_panel_open"] = True
                    state["radial_shown"] = False
                    _update_click_through()  # settings_panel_open=True → CT off
                    # Respond IMMEDIATELY with cached mic data
                    mics = get_available_mics()  # returns cache if <30s old
                    print(f"\u2699\ufe0f GET_SETTINGS: {len(mics)} micros (cache), selected={state['selected_mic_index']}")
                    response = json.dumps(_build_settings_data(mics))
                    await websocket.send(response)
                    # Refresh mics in background (if cache was stale, next open is instant)
                    async def _bg_refresh_mics(ws):
                        try:
                            fresh = await asyncio.to_thread(refresh_mic_cache)
                            await asyncio.to_thread(resolve_default_mic)
                            if fresh != mics:
                                await ws.send(json.dumps(_build_settings_data(fresh)))
                        except Exception:
                            pass
                    asyncio.create_task(_bg_refresh_mics(websocket))
                elif cmd == "SET_API_KEY":
                    new_key = data.get("key", "").strip()
                    if new_key:
                        valid = await asyncio.to_thread(_update_api_key, new_key)
                        await websocket.send(json.dumps({"command": "API_KEY_UPDATED", "success": True, "valid": valid}))
                elif cmd == "SELECT_MIC":
                    mic_idx = int(data.get("index", -1))
                    if mic_idx >= 0:
                        select_mic(mic_idx)
                elif cmd == "SET_LANGUAGE":
                    lang = data.get("language", "en")
                    if lang in ("fr", "en", "ja", "zh"):
                        state["language"] = lang
                        # Persist to user_prefs.json so it survives restarts
                        from audio import _save_prefs
                        _save_prefs({"language": lang})
                        print(f"🌐 Langue changée : {lang.upper()} (sauvegardée)")
                elif cmd == "SET_TAMA_VOLUME":
                    vol = float(data.get("volume", 1.0))
                    state["tama_volume"] = max(0.0, min(1.0, vol))
                    pct = int(state["tama_volume"] * 100)
                    print(f"🔊 Volume Tama : {pct}%")
                elif cmd == "SET_SESSION_DURATION":
                    duration = int(data.get("duration", 50))
                    state["session_duration_minutes"] = max(5, min(180, duration))
                    # Persist to user_prefs.json so it survives restarts
                    from audio import _save_prefs
                    _save_prefs({"session_duration": state["session_duration_minutes"]})
                    print(f"⏱️ Durée de session réglée sur : {state['session_duration_minutes']} min (sauvegardée)")
                elif cmd == "SET_SCREEN_SHARE":
                    enabled = bool(data.get("enabled", True))
                    state["screen_share_allowed"] = enabled
                    status = "✅ activé" if enabled else "❌ désactivé"
                    print(f"🖥️ Partage d'écran : {status}")
                elif cmd == "SET_MIC_ALLOWED":
                    enabled = bool(data.get("enabled", True))
                    state["mic_allowed"] = enabled
                    status = "✅ activé" if enabled else "❌ désactivé"
                    print(f"🎤 Microphone : {status}")
                elif cmd == "SET_TAMA_SCALE":
                    scale = int(data.get("scale", 100))
                    state["tama_scale"] = max(50, min(150, scale))
                    print(f"📐 Taille Tama : {state['tama_scale']}%")
                elif cmd == "SHOW_TWEAKS":
                    state["_tweaks_panel_open"] = True
                    _update_click_through()  # tweaks=True → CT off
                    print("🔧 Tweaks panel opened")
                elif cmd == "HIDE_TWEAKS":
                    state["_tweaks_panel_open"] = False
                    _update_click_through()  # manager checks all flags
                    print("🔧 Tweaks panel closed")
                elif cmd == "GET_TWEAKS":
                    _load_tweaks()  # Refresh from disk
                    response = json.dumps({
                        "command": "TWEAKS_DATA",
                        "values": dict(tweaks)
                    })
                    await websocket.send(response)
                    print(f"🔧 GET_TWEAKS → {tweaks}")
                elif cmd == "SET_TWEAK":
                    key = data.get("key", "")
                    val = float(data.get("value", 0))
                    if key in tweaks:
                        tweaks[key] = val
                        # Sync confidence to state dict too
                        if key == "confidence":
                            state["_confidence"] = val
                        _save_tweaks()
                        print(f"🔧 TWEAK {key} = {val}")
                elif cmd == "FORCE_RECONNECT":
                    reason = data.get("reason", "manual")
                    state["_force_reconnect"] = True
                    print(f"🔄 FORCE_RECONNECT requested: {reason}")
                elif cmd == "STRIKE_FIRE":
                    # Godot handles the visual hand animation (multi-window)
                    # Python just closes the tab/window
                    from gemini_session import fire_hand_animation
                    print("🎯 STRIKE_FIRE reçu de Godot — fermeture de l'onglet")
                    await asyncio.to_thread(fire_hand_animation)
            except Exception as e:
                print(f"⚠️ [WS] Erreur commande: {e}")
                import traceback; traceback.print_exc()
      except websockets.exceptions.ConnectionClosedError:
          print("🔌 [WS] Godot disconnected (no close frame) — reconnection will be automatic")
      except ConnectionResetError:
          print("🔌 [WS] Godot connection reset — reconnection will be automatic")
      except OSError as e:
          if e.winerror == 64:  # WinError 64: network name no longer available
              print("🔌 [WS] Network name unavailable — Godot likely restarted")
          else:
              raise
    finally:
        state["connected_ws_clients"].discard(websocket)


# ─── WebSocket State Broadcaster ────────────────────────────

async def broadcast_ws_state():
    """Continuously broadcast agent state to Godot via WebSocket."""
    _session_ended = False  # Track session end to generate summary once
    while True:
        if state["connected_ws_clients"]:
            try:
                if not state["is_session_active"]:
                    # Check if session just ended → generate summary
                    if _session_ended:
                        _session_ended = False
                        asyncio.create_task(_generate_end_summary())
                    state_data = {
                        "session_active": False,
                        "suspicion_index": 0.0,
                        "state": "CALM",
                        "window_ready": False,
                        "gemini_connected": state["gemini_connected"],
                    }
                    websockets.broadcast(state["connected_ws_clients"], json.dumps(state_data))
                    await asyncio.sleep(2.0)
                    continue
                else:
                    _session_ended = True  # Session is active → flag for end detection

                session_minutes = 0
                if state["session_start_time"]:
                    session_minutes = int((time.time() - state["session_start_time"]) / 60)

                # ── Compute dynamic break checkpoints based on session duration ──
                # session_duration = work interval before first break
                # e.g. 90 min → first break at 90 min, reminders at 105, 120, 135
                total_session_min = state.get("session_duration_minutes", 50)
                dyn_checkpoints, dyn_durations = get_dynamic_break_checkpoints(total_session_min)

                # Note: session does NOT auto-end when the timer expires.
                # The timer reaching session_duration just triggers the break suggestion
                # (handled by the checkpoint system below). The session ends only
                # when the user explicitly says so (via manage_break(end_session)).

                # Break reminder check
                if state["is_on_break"] and state["break_start_time"]:
                    brk_idx = min(state["current_break_index"], len(dyn_durations) - 1) if dyn_durations else 0
                    current_break_duration = dyn_durations[brk_idx] if dyn_durations else 5
                    break_elapsed = (time.time() - state["break_start_time"]) / 60
                    if break_elapsed >= current_break_duration:
                        state["is_on_break"] = False
                        state["break_start_time"] = None
                        state["current_break_index"] = min(state["current_break_index"] + 1, max(len(dyn_checkpoints) - 1, 0))
                        print("⏰ Pause terminée ! On reprend le travail.")

                elif state["session_start_time"] and not state["break_reminder_active"] and not state.get("session_completed"):
                    if dyn_checkpoints and state["current_break_index"] < len(dyn_checkpoints):
                        if session_minutes >= dyn_checkpoints[state["current_break_index"]]:
                            state["break_reminder_active"] = True
                            next_cp = dyn_checkpoints[state["current_break_index"]]
                            print(f"☕ Tama suggère une pause ! ({session_minutes} min de travail, checkpoint: {next_cp} min)")

                tama_state = state["current_tama_state"]

                # ── Organic mood decay ──
                # After Tama stops speaking, her mood fades gradually back to calm,
                # like a human's emotions naturally subsiding.
                # Gemini remains the authority — any new report_mood overrides this.
                MOOD_GRACE_SECS = 3.0    # Brief hold after speech (was 5.0 → too slow)
                MOOD_DECAY_SECS = tweaks["mood_decay_secs"]  # Total fade duration (tweakable via F2)
                current_mood = state.get("_current_mood", "calm")
                if current_mood != "calm" and not state.get("_tama_is_speaking", False):
                    mood_set_at = state.get("_mood_set_at", 0)
                    last_speech = state.get("_last_speech_ended", 0)
                    # Decay starts from whichever is later: mood set or speech end
                    decay_anchor = max(mood_set_at, last_speech)
                    elapsed = time.time() - decay_anchor

                    if elapsed > MOOD_GRACE_SECS:
                        decay_progress = min(1.0, (elapsed - MOOD_GRACE_SECS) / MOOD_DECAY_SECS)
                        # Ease-IN curve: fast drop at start, slow at end
                        # (opposite of previous ease-out which lingered too long)
                        decay_factor = (1.0 - decay_progress) ** 0.5
                        peak = state.get("_mood_peak_intensity", 0.5)
                        decayed_intensity = peak * decay_factor

                        if decayed_intensity < 0.15:
                            # Fully decayed → return to calm
                            if state.get("_current_mood") != "calm":
                                state["_current_mood"] = "calm"
                                state["_current_mood_intensity"] = 0.3
                                mood_msg = json.dumps({"command": "TAMA_MOOD", "mood": "calm", "intensity": 0.3})
                                broadcast_to_godot(mood_msg)
                                print(f"  🎭 Mood decayed → calm")
                        else:
                            # Send intermediate mood updates to Godot so the face
                            # transitions smoothly during decay (eyes/mouth/brows)
                            # Only send when intensity crosses a meaningful threshold
                            prev_intensity = state.get("_current_mood_intensity", 1.0)
                            if abs(prev_intensity - decayed_intensity) > 0.1:
                                state["_current_mood_intensity"] = decayed_intensity
                                mood_msg = json.dumps({"command": "TAMA_MOOD", "mood": current_mood, "intensity": round(decayed_intensity, 2)})
                                broadcast_to_godot(mood_msg)
                            else:
                                state["_current_mood_intensity"] = decayed_intensity

                state_data = {
                    "session_active": True,
                    "suspicion_index": round(state["current_suspicion_index"], 1),
                    "active_window": state["last_active_window_title"],
                    "active_duration": int(time.time() - state["active_window_start_time"]),
                    "state": tama_state.name if tama_state else "CALM",
                    "alignment": state["current_alignment"],
                    "current_task": state["current_task"] or "Non définie",
                    "category": state["current_category"],
                    "can_be_closed": state["can_be_closed"],
                    "session_minutes": session_minutes,
                    "session_elapsed_secs": int(time.time() - state["session_start_time"]) if state["session_start_time"] else 0,
                    "session_duration_secs": state.get("session_duration_minutes", 50) * 60,
                    "break_reminder": state["break_reminder_active"],
                    "is_on_break": state["is_on_break"],
                    "next_break_at": dyn_checkpoints[state["current_break_index"]] if (dyn_checkpoints and state["current_break_index"] < len(dyn_checkpoints)) else None,
                    "window_ready": state["window_positioned"],
                    "gemini_connected": state["gemini_connected"],
                }
                websockets.broadcast(state["connected_ws_clients"], json.dumps(state_data))
            except Exception:
                pass
        await asyncio.sleep(0.5)


async def _generate_end_summary():
    """Generate a session summary via Flash-Lite when a session ends."""
    try:
        lang = state.get("language", "en")
        summary = await generate_session_summary(lang)
        if summary:
            state["_session_summary"] = summary
            print("\n" + "=" * 50)
            print("📊 SESSION SUMMARY (Flash-Lite 3.1)")
            print("=" * 50)
            print(summary)
            print("=" * 50 + "\n")
        else:
            print("📊 Session summary: no data (too short or Flash-Lite unavailable)")
    except Exception as e:
        print(f"⚠️ Session summary error: {e}")
    finally:
        clear_classification_history()


# ─── Godot Launcher ─────────────────────────────────────────

def launch_godot_overlay():
    """Lance focuspals.exe (Godot) et applique le click-through Windows."""
    import sys
    godot_exe = os.path.join(application_path, '..', 'godot', 'focuspals.exe')
    godot_exe = os.path.abspath(godot_exe)

    if not os.path.exists(godot_exe):
        print(f"⚠️  Godot exe non trouvé: {godot_exe}")
        print("   Tama fonctionnera sans overlay 3D.")
        return

    # ── Kill any leftover focuspals.exe from a previous session ──
    # If an old Godot is still alive, the new one would connect to the old
    # Python's WS server (port 8080), which then gets killed — leaving the
    # new Godot disconnected and unable to receive SHOW_RADIAL commands.
    my_pid = os.getpid()
    try:
        result = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq focuspals.exe", "/FO", "CSV", "/NH"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.strip().splitlines():
            parts = line.replace('"', '').split(',')
            if len(parts) >= 2:
                try:
                    old_pid = int(parts[1])
                    if old_pid != my_pid:
                        print(f"🧹 Killing leftover focuspals.exe (PID {old_pid})")
                        subprocess.run(["taskkill", "/F", "/PID", str(old_pid)],
                                       capture_output=True, timeout=5)
                except (ValueError, IndexError):
                    pass
    except Exception as e:
        print(f"  ⚠️ Cleanup check failed: {e}")

    # ── Also free port 8080 if an old Python agent is still hogging it ──
    _free_port_sync(8080)

    print(f"🎮 Lancement de Tama 3D: {godot_exe}")
    state["godot_process"] = subprocess.Popen([godot_exe], cwd=os.path.dirname(godot_exe))

    threading.Thread(target=_apply_click_through_delayed, daemon=True).start()


def _free_port_sync(port: int):
    """Kill any process occupying the given port (Windows only)."""
    my_pid = os.getpid()
    pids_to_kill = set()
    try:
        result = subprocess.run(
            ["netstat", "-ano", "-p", "TCP"], capture_output=True, text=False, timeout=5
        )
        stdout = result.stdout.decode("utf-8", errors="replace")
        for line in stdout.splitlines():
            if f":{port}" not in line or "LISTENING" not in line:
                continue
            try:
                pid = int(line.strip().split()[-1])
                if pid != my_pid and pid > 0:
                    pids_to_kill.add(pid)
            except (ValueError, IndexError):
                continue
    except Exception as exc:
        print(f"  ⚠️ netstat failed: {exc}")

    for pid in pids_to_kill:
        print(f"⚠️ Port {port} occupé par PID {pid} — kill automatique...")
        try:
            subprocess.run(["taskkill", "/F", "/PID", str(pid)],
                           capture_output=True, timeout=5)
        except Exception:
            pass

    if pids_to_kill:
        time.sleep(1.5)  # Wait for OS to release sockets


def _apply_click_through_delayed():
    """Cherche la fenêtre Godot et applique WS_EX_TRANSPARENT + WS_EX_TOOLWINDOW."""
    user32 = ctypes.windll.user32
    GWL_EXSTYLE = -20
    WS_EX_LAYERED = 0x80000
    WS_EX_TRANSPARENT = 0x20
    WS_EX_TOOLWINDOW = 0x80

    WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.wintypes.BOOL, ctypes.wintypes.HWND, ctypes.wintypes.LPARAM)

    def find_window():
        """Trouve le HWND du process Godot par son PID (plus fiable que le titre)."""
        result = []
        godot_proc = state["godot_process"]
        pid = godot_proc.pid if godot_proc else None
        if not pid:
            return None
        def callback(hwnd, lparam):
            if user32.IsWindowVisible(hwnd):
                lpdw_pid = ctypes.wintypes.DWORD()
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(lpdw_pid))
                if lpdw_pid.value == pid:
                    result.append(hwnd)
            return True
        user32.EnumWindows(WNDENUMPROC(callback), 0)
        return result[0] if result else None

    time.sleep(1)

    for _ in range(60):
        hwnd = find_window()
        if hwnd:
            # ── Read window size BEFORE applying WS_EX_TRANSPARENT ──
            # The transparent flag can interfere with GetWindowRect on some
            # drivers/DPI configs, so we read the rect first.
            win_w, win_h = 0, 0
            for _wait in range(30):  # Up to 15s
                win_rect = ctypes.wintypes.RECT()
                user32.GetWindowRect(hwnd, ctypes.byref(win_rect))
                win_w = win_rect.right - win_rect.left
                win_h = win_rect.bottom - win_rect.top
                if win_w > 0 and win_h > 0:
                    break
                if _wait % 4 == 3:
                    print(f"  ⏳ Waiting for Godot window size... (rect: L={win_rect.left} T={win_rect.top} R={win_rect.right} B={win_rect.bottom})")
                time.sleep(0.5)

            # ── NOW apply click-through style ──
            user32.SetWindowLongW(hwnd, GWL_EXSTYLE, WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW)
            state["godot_hwnd"] = hwnd

            # NOTE: We do NOT reposition the window here.
            # Godot handles its own positioning in _ready() → _reposition_bottom_right().
            # Doing SetWindowPos from Python would conflict with Godot's internal
            # viewport coordinates and make CanvasLayer UI elements invisible.

            state["window_positioned"] = True
            print(f"✅ Click-through OK (handle: {hwnd}, taille: {win_w}x{win_h})")
            return
        time.sleep(0.5)

    print("⚠️  Fenêtre Godot non trouvée, click-through non appliqué.")

