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
from audio import get_available_mics, select_mic, resolve_default_mic
from ui import TamaState, start_session, quit_app, open_settings_popup, update_display


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
    elif action == "mic":
        threading.Thread(target=open_settings_popup, daemon=True).start()
    elif action == "task":
        print("🎯 Tâche : demandez à Tama par la voix !")
    elif action == "breaks":
        print("⏰ Config pauses : fonctionnalité à venir.")
    elif action == "quit":
        quit_app(state["tray_icon"], None)


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
                elif cmd == "GET_MICS":
                    state["_mic_panel_pending"] = True
                    state["radial_shown"] = False
                    _toggle_click_through(False)
                    resolve_default_mic()
                    mics = get_available_mics()
                    print(f"\U0001f3a4 GET_MICS: {len(mics)} micros, selected={state['selected_mic_index']}")
                    response = json.dumps({
                        "command": "MIC_LIST",
                        "mics": mics,
                        "selected": state["selected_mic_index"] if state["selected_mic_index"] is not None else -1
                    })
                    await websocket.send(response)
                elif cmd == "SELECT_MIC":
                    mic_idx = int(data.get("index", -1))
                    if mic_idx >= 0:
                        select_mic(mic_idx)
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
