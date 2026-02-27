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
import time
import threading

import websockets

from config import application_path, state, BREAK_CHECKPOINTS, BREAK_DURATIONS
from audio import get_available_mics, refresh_mic_cache, select_mic, resolve_default_mic
from ui import TamaState, start_session, quit_app, update_display


# ─── Click-Through Toggle ───────────────────────────────────

def _toggle_click_through(enable: bool):
    """Toggle WS_EX_TRANSPARENT on the Godot window."""
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
            print("💬 Déjà en session Deep Work — Tama t'écoute déjà !")
        elif state["conversation_requested"] or state["current_mode"] == "conversation":
            print("💬 Conversation déjà en cours.")
        else:
            state["conversation_requested"] = True
            print("💬 Mode conversation demandé !")
    elif action == "settings":
        # Settings panel is handled via WebSocket GET_SETTINGS, not via menu action
        # This is a fallback if triggered via menu action instead
        _send_settings_to_godot()
    elif action == "task":
        print("🎯 Tâche : demandez à Tama par la voix !")
    elif action == "breaks":
        print("⏰ Config pauses : fonctionnalité à venir.")
    elif action == "quit":
        quit_app(state["tray_icon"], None)


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
    return {
        "connections": state["_api_connections"],
        "screen_pulses": state["_api_screen_pulses"],
        "function_calls": state["_api_function_calls"],
        "audio_sent": state["_api_audio_chunks_sent"],
        "audio_recv": state["_api_audio_chunks_recv"],
        "connect_secs": int(total_secs),
    }


def _send_settings_to_godot():
    """Send current settings (mics + cached API key status) to all connected Godot clients."""
    import config
    mics = get_available_mics()  # returns cache if <30s old
    has_api_key = bool(config.GEMINI_API_KEY)
    response = json.dumps({
        "command": "SETTINGS_DATA",
        "mics": mics,
        "selected": state["selected_mic_index"] if state["selected_mic_index"] is not None else -1,
        "has_api_key": has_api_key,
        "key_valid": state["_api_key_valid"],
        "tama_volume": state["tama_volume"],
        "api_usage": _get_api_usage_stats()
    })
    main_loop = state["main_loop"]
    for ws_client in list(state["connected_ws_clients"]):
        try:
            if main_loop and main_loop.is_running():
                asyncio.run_coroutine_threadsafe(ws_client.send(response), main_loop)
        except Exception:
            pass


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

    work_area = ctypes.wintypes.RECT()
    ctypes.windll.user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(work_area), 0)
    detect_y_min = work_area.bottom - 500
    print(f"🖱️ [EdgeMonitor] Démarré — écran: {screen_w}px, zone Y: {detect_y_min}-{work_area.bottom}")

    radial_shown_time = 0
    _last_diag = 0

    while True:
        pt = POINT()
        user32.GetCursorPos(ctypes.byref(pt))

        live_screen_w = user32.GetSystemMetrics(0)
        if live_screen_w != screen_w:
            print(f"⚠️ [EdgeMonitor] DPI DRIFT! screen_w changed: {screen_w} → {live_screen_w}")
            screen_w = live_screen_w

        if state["is_session_active"] and time.time() - _last_diag > 5.0:
            _last_diag = time.time()
            print(f"🖱️ [EdgeMonitor] DEBUG pos=({pt.x},{pt.y}) screen_w={screen_w} near={pt.x >= screen_w - 5} zone={pt.y >= detect_y_min} shown={state['radial_shown']} away={state['_mouse_was_away']}")

        near_edge = (screen_w - 5) <= pt.x <= screen_w
        in_zone = pt.y >= detect_y_min

        if not near_edge or not in_zone:
            state["_mouse_was_away"] = True

        if near_edge and in_zone and not state["radial_shown"] and state["_mouse_was_away"] and time.time() > state["_radial_cooldown_until"]:
            state["radial_shown"] = True
            state["_mouse_was_away"] = False
            radial_shown_time = time.time()
            state["_radial_cooldown_until"] = 0
            print(f"🖱️ [EdgeMonitor] SHOW_RADIAL ({pt.x}, {pt.y}) screen_w={screen_w}")
            _toggle_click_through(False)
            msg = json.dumps({"command": "SHOW_RADIAL"})
            main_loop = state["main_loop"]
            for ws_client in list(state["connected_ws_clients"]):
                try:
                    if main_loop and main_loop.is_running():
                        asyncio.run_coroutine_threadsafe(ws_client.send(msg), main_loop)
                except Exception as e:
                    print(f"🖱️ [EdgeMonitor] Erreur envoi WS: {e}")

        if state["radial_shown"] and (time.time() - radial_shown_time > 5.0):
            state["radial_shown"] = False
            state["_radial_cooldown_until"] = 0
            _toggle_click_through(True)

        time.sleep(0.1)


# ─── WebSocket Handler ──────────────────────────────────────

async def ws_handler(websocket):
    """Handle incoming WebSocket messages from Godot."""
    state["connected_ws_clients"].add(websocket)
    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                cmd = data.get("command", "")
                if cmd == "START_SESSION":
                    start_session("Interface Godot 3D")
                elif cmd == "HIDE_RADIAL":
                    state["radial_shown"] = False
                    state["_mouse_was_away"] = True
                    state["_radial_cooldown_until"] = 0
                    if not state["_mic_panel_pending"]:
                        _toggle_click_through(True)
                    else:
                        state["_mic_panel_pending"] = False
                elif cmd == "MENU_ACTION":
                    action = data.get("action", "")
                    _handle_menu_action(action)
                elif cmd == "GET_SETTINGS":
                    state["_mic_panel_pending"] = True
                    state["radial_shown"] = False
                    _toggle_click_through(False)
                    import config
                    has_api_key = bool(config.GEMINI_API_KEY)
                    # Respond IMMEDIATELY with cached mic data
                    mics = get_available_mics()  # returns cache if <30s old
                    print(f"\u2699\ufe0f GET_SETTINGS: {len(mics)} micros (cache), selected={state['selected_mic_index']}, has_key={has_api_key}")
                    response = json.dumps({
                        "command": "SETTINGS_DATA",
                        "mics": mics,
                        "selected": state["selected_mic_index"] if state["selected_mic_index"] is not None else -1,
                        "has_api_key": has_api_key,
                        "key_valid": state["_api_key_valid"],
                        "language": state["language"],
                        "tama_volume": state["tama_volume"],
                        "api_usage": _get_api_usage_stats()
                    })
                    await websocket.send(response)
                    # Refresh mics in background (if cache was stale, next open is instant)
                    async def _bg_refresh_mics(ws):
                        try:
                            fresh = await asyncio.to_thread(refresh_mic_cache)
                            await asyncio.to_thread(resolve_default_mic)
                            if fresh != mics:
                                update = json.dumps({
                                    "command": "SETTINGS_DATA",
                                    "mics": fresh,
                                    "selected": state["selected_mic_index"] if state["selected_mic_index"] is not None else -1,
                                    "has_api_key": has_api_key,
                                    "key_valid": state["_api_key_valid"],
                                    "language": state["language"],
                                    "tama_volume": state["tama_volume"],
                                    "api_usage": _get_api_usage_stats()
                                })
                                await ws.send(update)
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
                    lang = data.get("language", "fr")
                    if lang in ("fr", "en"):
                        state["language"] = lang
                        print(f"🌐 Langue changée : {lang.upper()}")
                elif cmd == "SET_TAMA_VOLUME":
                    vol = float(data.get("volume", 1.0))
                    state["tama_volume"] = max(0.0, min(1.0, vol))
                    pct = int(state["tama_volume"] * 100)
                    print(f"🔊 Volume Tama : {pct}%")
            except Exception as e:
                print(f"⚠️ [WS] Erreur commande: {e}")
                import traceback; traceback.print_exc()
    finally:
        state["connected_ws_clients"].remove(websocket)


# ─── WebSocket State Broadcaster ────────────────────────────

async def broadcast_ws_state():
    """Continuously broadcast agent state to Godot via WebSocket."""
    while True:
        if state["connected_ws_clients"]:
            try:
                if not state["is_session_active"]:
                    state_data = {
                        "session_active": False,
                        "suspicion_index": 0.0,
                        "state": "CALM",
                        "window_ready": False
                    }
                    websockets.broadcast(state["connected_ws_clients"], json.dumps(state_data))
                    await asyncio.sleep(2.0)
                    continue

                session_minutes = 0
                if state["session_start_time"]:
                    session_minutes = int((time.time() - state["session_start_time"]) / 60)

                # Break reminder check
                if state["is_on_break"] and state["break_start_time"]:
                    current_break_duration = BREAK_DURATIONS[min(state["current_break_index"], len(BREAK_DURATIONS) - 1)]
                    break_elapsed = (time.time() - state["break_start_time"]) / 60
                    if break_elapsed >= current_break_duration:
                        state["is_on_break"] = False
                        state["break_start_time"] = None
                        state["current_break_index"] = min(state["current_break_index"] + 1, len(BREAK_CHECKPOINTS) - 1)
                        print("⏰ Pause terminée ! On reprend le travail.")

                elif state["session_start_time"] and not state["break_reminder_active"] and state["current_break_index"] < len(BREAK_CHECKPOINTS):
                    if session_minutes >= BREAK_CHECKPOINTS[state["current_break_index"]]:
                        state["break_reminder_active"] = True
                        print(f"☕ Tama suggère une pause ! ({session_minutes} min de travail)")

                tama_state = state["current_tama_state"]
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
                    "break_reminder": state["break_reminder_active"],
                    "is_on_break": state["is_on_break"],
                    "next_break_at": BREAK_CHECKPOINTS[state["current_break_index"]] if state["current_break_index"] < len(BREAK_CHECKPOINTS) else None,
                    "window_ready": state["window_positioned"]
                }
                websockets.broadcast(state["connected_ws_clients"], json.dumps(state_data))
            except Exception:
                pass
        await asyncio.sleep(0.5)


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

    print(f"🎮 Lancement de Tama 3D: {godot_exe}")
    state["godot_process"] = subprocess.Popen([godot_exe], cwd=os.path.dirname(godot_exe))

    threading.Thread(target=_apply_click_through_delayed, daemon=True).start()


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
            time.sleep(0.5)
            user32.SetWindowLongW(hwnd, GWL_EXSTYLE, WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW)
            state["godot_hwnd"] = hwnd

            try:
                SPI_GETWORKAREA = 0x0030
                work_area = ctypes.wintypes.RECT()
                ctypes.windll.user32.SystemParametersInfoW(SPI_GETWORKAREA, 0, ctypes.byref(work_area), 0)

                win_rect = ctypes.wintypes.RECT()
                user32.GetWindowRect(hwnd, ctypes.byref(win_rect))
                win_w = win_rect.right - win_rect.left
                win_h = win_rect.bottom - win_rect.top

                new_x = work_area.right - win_w
                new_y = work_area.bottom - win_h

                SWP_FLAGS = 0x0001 | 0x0004 | 0x0020  # NOSIZE | NOZORDER | FRAMECHANGED
                user32.SetWindowPos(hwnd, 0, new_x, new_y, 0, 0, SWP_FLAGS)

                print(f"📐 Fenêtre repositionnée: ({new_x}, {new_y}) — taille {win_w}x{win_h}")
            except Exception as e:
                print(f"⚠️ Repositionnement échoué: {e}")

            state["window_positioned"] = True
            print(f"✅ Click-through + position OK (handle: {hwnd})")
            return
        time.sleep(0.5)

    print("⚠️  Fenêtre Godot non trouvée, click-through non appliqué.")
