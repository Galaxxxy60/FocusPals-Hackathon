"""
FocusPals — UI: Display, System Tray, Settings Popup
Console display, tray icon management, and tkinter settings window.
"""

import json
import os
import time
import asyncio
import threading

import pystray
from pystray import MenuItem as item
from PIL import ImageDraw, Image
from enum import Enum

from config import state, BREAK_CHECKPOINTS


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
    main_loop = state["main_loop"]
    for ws_client in list(state["connected_ws_clients"]):
        try:
            if main_loop and main_loop.is_running():
                asyncio.run_coroutine_threadsafe(ws_client.send(quit_msg), main_loop)
        except Exception:
            pass
    time.sleep(1.5)
    import subprocess
    subprocess.run("taskkill /F /IM focuspals.exe", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run("taskkill /F /IM focuspals.console.exe", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os._exit(0)


def start_session(source="UI"):
    """Start a deep work session."""
    if not state["is_session_active"]:
        state["is_session_active"] = True
        state["session_start_time"] = time.time()
        state["current_break_index"] = 0
        state["break_reminder_active"] = False
        state["is_on_break"] = False
        state["just_started_session"] = True
        update_display(TamaState.CALM, f"🚀 SESSION COMMENCÉE via {source} !")
        start_msg = json.dumps({"command": "START_SESSION"})
        main_loop = state["main_loop"]
        for ws_client in list(state["connected_ws_clients"]):
            try:
                if main_loop and main_loop.is_running():
                    asyncio.run_coroutine_threadsafe(ws_client.send(start_msg), main_loop)
            except Exception:
                pass


def start_session_from_tray(icon, item):
    start_session("Widget Windows")


def accept_break_from_tray(icon, item):
    state["break_reminder_active"] = False
    state["is_on_break"] = True
    state["break_start_time"] = time.time()
    print("☕ Pause acceptée ! Repose-toi pendant 5 minutes.")


def refuse_break_from_tray(icon, item):
    state["break_reminder_active"] = False
    state["current_break_index"] = min(state["current_break_index"] + 1, len(BREAK_CHECKPOINTS) - 1)
    next_min = BREAK_CHECKPOINTS[state["current_break_index"]]
    print(f"💪 Pause refusée. Prochaine suggestion dans {next_min} min.")


def open_settings_popup(icon=None, item=None):
    """Ouvre une fenêtre de réglages avec sélection du micro."""
    import tkinter as tk
    from tkinter import ttk
    from audio import get_available_mics, select_mic

    mics = get_available_mics()
    if not mics:
        return

    win = tk.Tk()
    win.title("FocusPals — Réglages 🎤")
    win.geometry("420x150")
    win.resizable(False, False)
    win.attributes("-topmost", True)
    win.configure(bg="#1e1e2e")

    style = ttk.Style(win)
    style.theme_use("clam")
    style.configure("TLabel", background="#1e1e2e", foreground="#cdd6f4", font=("Segoe UI", 11))
    style.configure("TCombobox", font=("Segoe UI", 10))
    style.configure("Accent.TButton", font=("Segoe UI", 10, "bold"))

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

    ttk.Button(win, text="✅ Sauvegarder", command=save, style="Accent.TButton").pack(pady=15)
    win.mainloop()


def setup_tray():
    """Initialize system tray icon and menu."""
    from audio import resolve_default_mic
    resolve_default_mic()
    
    image = create_tray_image(TamaState.CALM)
    menu = (
        item('Démarrer Session (Deep Work) ⚡', start_session_from_tray),
        item('☕ Accepter la pause', accept_break_from_tray),
        item('💪 Refuser la pause', refuse_break_from_tray),
        pystray.Menu.SEPARATOR,
        item('Réglages 🎤', open_settings_popup),
        item('Stop Tama 🥷', quit_app)
    )
    state["tray_icon"] = pystray.Icon("Tama", image, "Tama Agent 🥷 — 🟢 En veille", menu)
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


def send_anim_to_godot(anim_name: str, loop: bool = False):
    """Send an animation command to Godot. Only Python decides when to animate."""
    msg = json.dumps({"command": "TAMA_ANIM", "anim": anim_name, "loop": loop})
    main_loop = state["main_loop"]
    for ws_client in list(state["connected_ws_clients"]):
        try:
            if main_loop and main_loop.is_running():
                asyncio.run_coroutine_threadsafe(ws_client.send(msg), main_loop)
        except Exception:
            pass


# ─── Mood → Animation mapping (Gemini drives this) ─────────

_MOOD_ANIM_MAP = {
    # mood: (low_intensity_anim, mid_intensity_anim, high_intensity_anim)
    "calm":         ("Hello", "Hello", "Hello"),
    "curious":      ("Peek",  "Suspicious", "Suspicious"),
    "amused":       ("Hello", "Hello", "Hello"),
    "proud":        ("Hello", "Hello", "Hello"),
    "disappointed": ("Suspicious", "Suspicious", "Angry"),
    "sarcastic":    ("Suspicious", "Suspicious", "Angry"),
    "annoyed":      ("Suspicious", "Angry", "Angry"),
    "angry":        ("Angry", "Angry", "Angry"),
    "furious":      ("Angry", "Angry", "Strike"),
}


def send_mood_to_godot(mood: str, intensity: float):
    """
    Map Gemini's reported mood+intensity to an animation and send to Godot.
    Also sends a TAMA_MOOD message so Godot can do finer transitions later.
    """
    # Pick animation from mood map
    anims = _MOOD_ANIM_MAP.get(mood, ("Hello", "Suspicious", "Angry"))
    if intensity < 0.4:
        anim = anims[0]
    elif intensity < 0.7:
        anim = anims[1]
    else:
        anim = anims[2]

    # Loop for sustained moods, one-shot for strikes
    loop = anim not in ("Strike", "bye", "Peek")

    send_anim_to_godot(anim, loop)

    print(f"  🎭 ┌─ MOOD REPORT ────────────────────")
    print(f"  🎭 │ Mood: {mood} | Intensity: {intensity:.1f}")
    print(f"  🎭 │ → Animation: {anim} ({'loop' if loop else 'once'})")
    print(f"  🎭 └────────────────────────────────────")

    # Also send the raw mood data to Godot for future AnimationTree use
    mood_msg = json.dumps({"command": "TAMA_MOOD", "mood": mood, "intensity": intensity})
    main_loop = state["main_loop"]
    for ws_client in list(state["connected_ws_clients"]):
        try:
            if main_loop and main_loop.is_running():
                asyncio.run_coroutine_threadsafe(ws_client.send(mood_msg), main_loop)
        except Exception:
            pass
