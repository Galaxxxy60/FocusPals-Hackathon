"""
FocusPals — UI: Display & Godot Communication
Console display and WebSocket broadcast utilities.
"""

import json
import os
import time
import asyncio
import threading

from enum import Enum

from config import state, BREAK_CHECKPOINTS, get_dynamic_break_checkpoints
import tama_memory


# ─── Tama States ────────────────────────────────────────────

class TamaState(Enum):
    CALM = "calm"
    ANGRY = "angry"

TAMA_FACES = {
    TamaState.CALM: r"""
    ╔══════════════════════════════════╗
    ║                                  ║
    ║         ╭─────────────╮          ║
    ║         │   ^     ^   │          ║
    ║         │             │          ║
    ║         │    ╰───╯    │          ║
    ║         │             │          ║
    ║         ╰─────────────╯          ║
    ║                                  ║
    ║    🟢 Tama is watching you.      ║
    ║       Live API connected.        ║
    ╚══════════════════════════════════╝
""",
    TamaState.ANGRY: r"""
    ╔══════════════════════════════════╗
    ║          ╱╲          ╱╲          ║
    ║         ╭─────────────╮          ║
    ║         │  ╲╲   ╱╱    │          ║
    ║         │   👁   👁   │          ║
    ║         │    ╭───╮    │          ║
    ║         │   ╱     ╲   │          ║
    ║         ╰─────────────╯          ║
    ║                                  ║
    ║  💢 STOP PROCRASTINATING !!      ║
    ║     Closing your tab now.        ║
    ╚══════════════════════════════════╝
""",
}


def clear_screen():
    os.system('cls' if os.name == 'nt' else 'clear')


# ─── System Tray Icon ───────────────────────────────────────

def create_tray_image(tama_state: TamaState):
    image = Image.new('RGB', (64, 64), color=(30, 30, 30))
    dc = ImageDraw.Draw(image)
    if tama_state == TamaState.CALM:
        dc.ellipse((16, 16, 48, 48), fill=(0, 255, 0))
    else:
        dc.ellipse((16, 16, 48, 48), fill=(255, 0, 0))
    return image


def quit_app(icon, item):
    icon.stop()
    print("\n👋 Tama: Fermeture propre...")
    quit_msg = json.dumps({"command": "QUIT"})
    broadcast_to_godot(quit_msg)
    time.sleep(1.5)
    import subprocess
    subprocess.run("taskkill /F /IM focuspals.exe", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run("taskkill /F /IM focuspals.console.exe", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os._exit(0)


def start_session(source="UI"):
    """Start a deep work session."""
    if not state["is_session_active"]:
        # Detect if this is a post-break restart
        was_on_break = state.get("is_on_break", False)
        state["is_session_active"] = True
        state["session_start_time"] = time.time()
        state["current_break_index"] = 0
        state["break_reminder_active"] = False
        state["is_on_break"] = False
        state["session_completed"] = False
        state["just_started_session"] = True
        # ── Tama Memory: record session start ──
        tama_memory.load_memory()
        tama_memory.record_session_start()
        # ── Cloud: Log session start to Firestore ──
        try:
            from firestore_sync import log_session_start
            cloud_session_id = log_session_start(
                state.get("session_duration_minutes", 50),
                state.get("language", "en")
            )
            state["_cloud_session_id"] = cloud_session_id
        except Exception:
            pass  # Cloud sync is best-effort

        if was_on_break:
            state["_post_break_restart"] = True
            # Reset stealth counters — the disconnect was intentional (break), not a crash
            # Without this, Gemini reconnects in stealth mode and stays MUZZLED
            state["_api_connections"] = 0
        # Log dynamic break schedule
        total_min = state.get("session_duration_minutes", 50)
        dyn_cp, dyn_dur = get_dynamic_break_checkpoints(total_min)
        print(f"  📋 Session: {total_min}min | Breaks at: {dyn_cp} | Durations: {dyn_dur}")
        update_display(TamaState.CALM, f"🚀 SESSION COMMENCÉE via {source} !")
        start_msg = json.dumps({"command": "START_SESSION", "session_duration_secs": total_min * 60})
        broadcast_to_godot(start_msg)


def start_session_from_tray(icon, item):
    start_session("Widget Windows")


def accept_break_from_tray(icon, item):
    state["break_reminder_active"] = False
    state["is_on_break"] = True
    state["break_start_time"] = time.time()
    print("☕ Pause acceptée ! Repose-toi pendant 5 minutes.")


def refuse_break_from_tray(icon, item):
    state["break_reminder_active"] = False
    total_min = state.get("session_duration_minutes", 50)
    dyn_cp, _ = get_dynamic_break_checkpoints(total_min)
    if dyn_cp and state["current_break_index"] < len(dyn_cp):
        state["current_break_index"] = min(state["current_break_index"] + 1, len(dyn_cp) - 1)
        if state["current_break_index"] < len(dyn_cp):
            next_min = dyn_cp[state["current_break_index"]]
            print(f"💪 Pause refusée. Prochaine suggestion à {next_min} min.")
        else:
            print("💪 Pause refusée. Plus de pauses prévues.")
    else:
        print("💪 Pause refusée.")


def open_settings_popup(icon=None, item=None):
    """Ouvre une fenêtre de réglages avec sélection du micro."""
    import tkinter as tk
    from tkinter import ttk, messagebox
    from audio import get_available_mics, select_mic

    mics = get_available_mics()
    if not mics:
        return

    win = tk.Tk()
    win.title("FocusPals — Réglages 🎤")
    win.geometry("420x220")
    win.resizable(False, False)
    win.attributes("-topmost", True)
    win.configure(bg="#1e1e2e")

    style = ttk.Style(win)
    style.theme_use("clam")
    style.configure("TLabel", background="#1e1e2e", foreground="#cdd6f4", font=("Segoe UI", 11))
    style.configure("TCombobox", font=("Segoe UI", 10))
    style.configure("Accent.TButton", font=("Segoe UI", 10, "bold"))
    style.configure("Danger.TButton", font=("Segoe UI", 9))

    ttk.Label(win, text="🎤 Microphone").pack(pady=(15, 5))

    mic_names = [m["name"] for m in mics]
    mic_var = tk.StringVar()

    current_name = ""
    for m in mics:
        if m["index"] == state["selected_mic_index"]:
            current_name = m["name"]
            break
    if current_name:
        mic_var.set(current_name)
    elif mic_names:
        mic_var.set(mic_names[0])

    combo = ttk.Combobox(win, textvariable=mic_var, values=mic_names, state="readonly", width=50)
    combo.pack(padx=20, pady=5)

    def save():
        name = mic_var.get()
        for m in mics:
            if m["name"] == name:
                select_mic(m["index"])
                break
        win.destroy()

    def reset_memory():
        if messagebox.askyesno("Reset Memory", "Effacer toute la mémoire de Tama ?\n(sessions, prénom, moments mémorables)\n\nTama te traitera comme un inconnu."):
            tama_memory.reset_memory()
            messagebox.showinfo("Reset", "Mémoire effacée ! Tama repartira de zéro.")
            print("🗑️ Tama memory reset by user")

    ttk.Button(win, text="✅ Sauvegarder", command=save, style="Accent.TButton").pack(pady=(10, 5))
    ttk.Button(win, text="🗑️ Reset Memory", command=reset_memory, style="Danger.TButton").pack(pady=(0, 10))
    win.mainloop()


def setup_tray():
    """Initialize system tray icon and menu."""
    from audio import resolve_default_mic, _load_prefs
    resolve_default_mic()

    # Restore saved language preference
    prefs = _load_prefs()
    saved_lang = prefs.get("language", "")
    if saved_lang in ("en", "fr", "ja", "zh"):
        state["language"] = saved_lang
        print(f"🌐 Langue restaurée depuis les préférences : {saved_lang.upper()}")

    # Restore saved session duration
    saved_duration = prefs.get("session_duration", 0)
    if isinstance(saved_duration, (int, float)) and 5 <= saved_duration <= 180:
        state["session_duration_minutes"] = int(saved_duration)
        print(f"⏱️ Durée de session restaurée : {state['session_duration_minutes']} min")
    
    image = create_tray_image(TamaState.CALM)
    menu = (
        item('Stop FocusPals', quit_app),
    )
    state["tray_icon"] = pystray.Icon("FocusPals", image, "FocusPals 🥷", menu)
    threading.Thread(target=state["tray_icon"].run, daemon=True).start()


def update_tray(tama_state: TamaState):
    tray = state["tray_icon"]
    if tray:
        tray.icon = create_tray_image(tama_state)
        if tama_state == TamaState.CALM:
            tray.title = "Tama Agent 🥷 — 🟢 Travail en cours"
        else:
            tray.title = "Tama Agent 🥷 — 💢 DISTRACTION !"


def update_display(tama_state: TamaState, message: str = ""):
    state["current_tama_state"] = tama_state
    update_tray(tama_state)
    # Skip the full screen clear during stealth reconnects — preserve console history
    if state.get("_is_stealth_reconnect"):
        if message:
            print(f"  💬 \"{message}\"")
        return
    clear_screen()
    print("=" * 42)
    print("  FocusPals — Tama Agent 🥷 (LIVE API) 📡")
    print("  Dual-Monitor Pulse Vision + Audio Voice")
    print("=" * 42)
    print(TAMA_FACES[tama_state])
    if message:
        print(f"  💬 \"{message}\"")
    print("\n  Press Ctrl+C to stop.")
    print("─" * 42)


def broadcast_to_godot(msg: str):
    """Send a WebSocket message to all connected Godot clients (thread-safe).
    This is the SINGLE place for the broadcast pattern — use it everywhere."""
    main_loop = state["main_loop"]
    for ws_client in list(state["connected_ws_clients"]):
        try:
            if main_loop and main_loop.is_running():
                asyncio.run_coroutine_threadsafe(ws_client.send(msg), main_loop)
        except Exception:
            pass


def send_anim_to_godot(anim_name: str, loop: bool = False):
    """Send an animation command to Godot. Only Python decides when to animate."""
    broadcast_to_godot(json.dumps({"command": "TAMA_ANIM", "anim": anim_name, "loop": loop}))


# ─── Mood → Animation mapping (Gemini drives this) ─────────

_MOOD_ANIM_MAP = {
    # mood: (low_intensity_anim, mid_intensity_anim, high_intensity_anim)
    # Idle_wall_Talk: AnimTree plays only if Tama IS on wall, otherwise ignored
    "calm":         ("Idle_wall_Talk", "Idle_wall_Talk", "Idle_wall_Talk"),
    "curious":      ("Idle_wall_Talk", "Suspicious", "Suspicious"),
    "amused":       ("Idle_wall_Talk", "Idle_wall_Talk", "Idle_wall_Talk"),
    "proud":        ("Idle_wall_Talk", "Idle_wall_Talk", "Idle_wall_Talk"),
    "suspicious":   ("Suspicious",  "Suspicious", "Suspicious"),
    "surprised":    ("Idle_wall_Talk", "Idle_wall_Talk", "Idle_wall_Talk"),
    "disappointed": ("Suspicious", "Suspicious", "Angry"),
    "sarcastic":    ("Suspicious", "Suspicious", "Angry"),
    "annoyed":      ("Suspicious", "Angry", "Angry"),
    "angry":        ("Angry", "Angry", "Angry"),
    "furious":      ("Angry", "Angry", "Angry"),  # NEVER "Strike" — that's fire_strike's job
}


def send_mood_to_godot(mood: str, intensity: float):
    """
    Map Gemini's reported mood+intensity to a BODY animation and send to Godot.
    NOTE: TAMA_MOOD (facial expressions) is now sent directly in gemini_session.py.
    """
    # Pick animation from mood map
    anims = _MOOD_ANIM_MAP.get(mood, ("Idle_wall", "Suspicious", "Angry"))
    if intensity < 0.4:
        anim = anims[0]
    elif intensity < 0.7:
        anim = anims[1]
    else:
        anim = anims[2]

    # Loop for sustained moods, one-shot for dramatic poses (play once → freeze on last frame)
    loop = anim not in ("Strike", "GoAway", "Suspicious", "Angry")

    send_anim_to_godot(anim, loop)

    print(f"  🎭 ┌─ MOOD REPORT ────────────────────")
    print(f"  🎭 │ Mood: {mood} | Intensity: {intensity:.1f}")
    print(f"  🎭 │ → Animation: {anim} ({'loop' if loop else 'once'})")
    print(f"  🎭 └────────────────────────────────────")
