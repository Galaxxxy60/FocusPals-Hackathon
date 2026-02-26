"""
FocusPals Agent — Tama 🥷 -> TRUE LIVE API (WebSocket) 📡
Proactive AI productivity coach powered by Gemini Multimodal Live API.

Features:
- 🎙️ Continuous audio streaming (Mic & Speaker)
- 👁️ Multi-monitor vision (All screens merged)
- ⏳ "Pulse" video sending (1 frame every 5 seconds to save bandwidth)
- 🛠️ Function Calling (Closes distracting tabs)
- 🎭 ASCII State Machine
"""

import asyncio
import io
import logging
import math
import os
import struct
import sys
import time
from datetime import datetime
from enum import Enum
import threading

# ─── Logging ────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S"
)
log = logging.getLogger("Tama")

import pystray
from pystray import MenuItem as item
from PIL import ImageDraw, Image

from dotenv import load_dotenv
from google import genai
from google.genai import types
import mss
import pyaudio

# Resolves the absolute path of this file (handles both .py and .bat launchers)
application_path = os.path.dirname(os.path.abspath(__file__))
env_path = os.path.join(application_path, '.env')
load_dotenv(env_path)

# ─── Configuration ──────────────────────────────────────────

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
if not GEMINI_API_KEY:
    print("❌ GEMINI_API_KEY missing! Copy agent/.env.example to agent/.env")
    sys.exit(1)

client = genai.Client(api_key=GEMINI_API_KEY, http_options={"api_version": "v1alpha"})

# Use the correct model for Live API
MODEL = "gemini-2.5-flash-native-audio-latest"
SCREEN_PULSE_INTERVAL = 5  # Unused — actual delay is dynamic (3-8s based on suspicion index)

# ─── Audio Configuration ────────────────────────────────────

FORMAT = pyaudio.paInt16
CHANNELS = 1
SEND_SAMPLE_RATE = 16000
RECEIVE_SAMPLE_RATE = 24000
CHUNK_SIZE = 1024
selected_mic_index = None  # None = micro par défaut du système

def get_available_mics():
    """Liste les micros disponibles qui supportent 16kHz (priorité WASAPI, fallback MME)."""
    pya = pyaudio.PyAudio()
    mics = []
    seen_names = set()  # Avoid duplicates (same physical mic in multiple APIs)
    
    # Mots-clés de devices virtuels/inutiles à exclure
    exclude = ["steam streaming", "vb-audio", "cable output", "mappeur", "wo mic",
               "réseau de microphones", "input (vb", "cable input"]
    
    # First pass: try WASAPI devices, then others
    for i in range(pya.get_device_count()):
        info = pya.get_device_info_by_index(i)
        if info["maxInputChannels"] <= 0:
            continue
        name_lower = info["name"].lower()
        if any(ex in name_lower for ex in exclude):
            continue
        # Skip if we already found a working version of this physical mic
        name_prefix = name_lower[:15]
        if name_prefix in seen_names:
            continue
        # Test if this device actually supports 16kHz
        try:
            test_stream = pya.open(format=pyaudio.paInt16, channels=1, rate=SEND_SAMPLE_RATE,
                                   input=True, input_device_index=i, frames_per_buffer=512)
            test_stream.close()
            mics.append({"index": i, "name": info["name"]})
            seen_names.add(name_prefix)
        except OSError:
            continue  # This device doesn't support 16kHz, skip it
    
    pya.terminate()
    return mics

def select_mic(index):
    """Change le micro utilisé (hot-swap immédiat, même en cours de session)."""
    global selected_mic_index
    selected_mic_index = index
    mics = get_available_mics()
    name = next((m["name"] for m in mics if m["index"] == index), "?")
    print(f"🎤 Micro sélectionné: [{index}] {name}")

def resolve_default_mic():
    global selected_mic_index
    if selected_mic_index is not None:
        return
    mics = get_available_mics()
    if not mics:
        print("⚠️ Aucun micro compatible trouvé !")
        return
    try:
        pya_tmp = pyaudio.PyAudio()
        default_name = pya_tmp.get_default_input_device_info()["name"].lower()
        pya_tmp.terminate()
        # Try to find the default mic in our compatible list
        for m in mics:
            if m["name"].lower().startswith(default_name[:15]):
                selected_mic_index = m["index"]
                break
        if selected_mic_index is None:
            selected_mic_index = mics[0]["index"]
    except Exception:
        selected_mic_index = mics[0]["index"]
    print(f"🎤 Micro auto-sélectionné: [{selected_mic_index}]")

# ─── Tama's States & Display ────────────────────────────────

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

tray_icon = None
main_loop = None  # Référence à l'event loop asyncio pour le thread tray

def create_tray_image(state: TamaState):
    image = Image.new('RGB', (64, 64), color=(30, 30, 30))
    dc = ImageDraw.Draw(image)
    if state == TamaState.CALM:
        dc.ellipse((16, 16, 48, 48), fill=(0, 255, 0)) # Green dot = Calm
    else:
        dc.ellipse((16, 16, 48, 48), fill=(255, 0, 0)) # Red dot = Angry
    return image

def quit_app(icon, item):
    icon.stop()
    print("\n👋 Tama: Fermeture propre...")
    # Envoyer QUIT à Godot via WebSocket
    quit_msg = json.dumps({"command": "QUIT"})
    for ws_client in list(connected_ws_clients):
        try:
            if main_loop and main_loop.is_running():
                asyncio.run_coroutine_threadsafe(ws_client.send(quit_msg), main_loop)
        except Exception:
            pass
    # Laisser 1.5s pour que Godot se ferme proprement
    time.sleep(1.5)
    # Fallback taskkill si Godot n'a pas répondu
    import subprocess
    subprocess.run("taskkill /F /IM focuspals.exe", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run("taskkill /F /IM focuspals.console.exe", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os._exit(0)

def start_session(source="UI"):
    global is_session_active, session_start_time, current_break_index, break_reminder_active, is_on_break, just_started_session
    if not is_session_active:
        is_session_active = True
        session_start_time = time.time()
        current_break_index = 0
        break_reminder_active = False
        is_on_break = False
        just_started_session = True
        update_display(TamaState.CALM, f"🚀 SESSION COMMENCÉE via {source} !")
        # Notifier Godot pour activer les animations de session
        start_msg = json.dumps({"command": "START_SESSION"})
        for ws_client in list(connected_ws_clients):
            try:
                if main_loop and main_loop.is_running():
                    asyncio.run_coroutine_threadsafe(ws_client.send(start_msg), main_loop)
            except Exception:
                pass

def start_session_from_tray(icon, item):
    start_session("Widget Windows")

def accept_break_from_tray(icon, item):
    global is_on_break, break_reminder_active, break_start_time
    break_reminder_active = False
    is_on_break = True
    break_start_time = time.time()
    print("☕ Pause acceptée ! Repose-toi pendant 5 minutes.")

def refuse_break_from_tray(icon, item):
    global current_break_index, break_reminder_active
    break_reminder_active = False
    current_break_index = min(current_break_index + 1, len(BREAK_CHECKPOINTS) - 1)
    next_min = BREAK_CHECKPOINTS[current_break_index]
    print(f"💪 Pause refusée. Prochaine suggestion dans {next_min} min.")

def open_settings_popup(icon=None, item=None):
    """Ouvre une fenêtre de réglages avec sélection du micro."""
    import tkinter as tk
    from tkinter import ttk
    
    mics = get_available_mics()
    if not mics:
        return
    
    win = tk.Tk()
    win.title("FocusPals — Réglages 🎤")
    win.geometry("420x150")
    win.resizable(False, False)
    win.attributes("-topmost", True)
    win.configure(bg="#1e1e2e")
    
    # Style
    style = ttk.Style(win)
    style.theme_use("clam")
    style.configure("TLabel", background="#1e1e2e", foreground="#cdd6f4", font=("Segoe UI", 11))
    style.configure("TCombobox", font=("Segoe UI", 10))
    style.configure("Accent.TButton", font=("Segoe UI", 10, "bold"))
    
    ttk.Label(win, text="🎤 Microphone").pack(pady=(15, 5))
    
    mic_names = [m["name"] for m in mics]
    mic_var = tk.StringVar()
    
    # Trouver le micro actuellement sélectionné
    current_name = ""
    for m in mics:
        if m["index"] == selected_mic_index:
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
    global tray_icon, selected_mic_index
    image = create_tray_image(TamaState.CALM)
    
    # Résoudre le micro par défaut si pas encore sélectionné
    resolve_default_mic()
    
    menu = (
        item('Démarrer Session (Deep Work) ⚡', start_session_from_tray),
        item('☕ Accepter la pause', accept_break_from_tray),
        item('💪 Refuser la pause', refuse_break_from_tray),
        pystray.Menu.SEPARATOR,
        item('Réglages 🎤', open_settings_popup),
        item('Stop Tama 🥷', quit_app)
    )
    tray_icon = pystray.Icon("Tama", image, "Tama Agent 🥷 — 🟢 En veille", menu)
    threading.Thread(target=tray_icon.run, daemon=True).start()

def update_tray(state: TamaState):
    global tray_icon
    if tray_icon:
        tray_icon.icon = create_tray_image(state)
        if state == TamaState.CALM:
            tray_icon.title = "Tama Agent 🥷 — 🟢 Travail en cours"
        else:
            tray_icon.title = "Tama Agent 🥷 — 💢 DISTRACTION !"

# ─── Display ────────────────────────────────────────────────

current_tama_state = TamaState.CALM
current_suspicion_index = 0.0  # Float for granular ΔS
last_active_window_title = "Unknown"
import json
import websockets
active_window_start_time = time.time()

suspicion_above_6_start = None
suspicion_at_9_start = None
force_speech = False

# ─── Voice Activity Detection (VAD) ──────────────────────────
user_spoke_at = 0.0            # Timestamp of last detected user speech
USER_SPEECH_TIMEOUT = 12.0     # Seconds to keep Tama unmuzzled after user speaks

def _detect_voice_activity(pcm_data: bytes, threshold: float = 500.0) -> bool:
    """Simple energy-based Voice Activity Detection on 16-bit PCM mono."""
    try:
        n_samples = len(pcm_data) // 2
        if n_samples == 0:
            return False
        samples = struct.unpack(f'<{n_samples}h', pcm_data)
        rms = math.sqrt(sum(s * s for s in samples) / n_samples)
        return rms > threshold
    except Exception:
        return False

# ─── A.S.C. (Alignment Suspicion Control) ────────────────────
current_task = None  # Set dynamically by Tama via voice
current_alignment = 1.0  # 1.0 (aligned), 0.5 (doubt), 0.0 (misaligned)
current_category = "SANTE"  # SANTE, ZONE_GRISE, FLUX, BANNIE, PROCRASTINATION_PRODUCTIVE
can_be_closed = True  # Protection: False for IDEs, document editors

# ─── Break Reminder System ────────────────────────────────────
BREAK_CHECKPOINTS = [20, 40, 90, 120]  # Minutes de travail avant suggestion
BREAK_DURATIONS   = [5,  8,  15, 20]   # Durée de pause correspondante (minutes)
session_start_time = None
current_break_index = 0  # Index dans BREAK_CHECKPOINTS
break_reminder_active = False  # True quand Tama suggère une pause
is_on_break = False  # True pendant une pause
break_start_time = None
just_started_session = False

# Protected windows that should NEVER be closed
PROTECTED_WINDOWS = ["code", "cursor", "visual studio", "unreal", "blender", "word", "excel",
                     "figma", "photoshop", "premiere", "davinci", "ableton", "fl studio",
                     "suno", "notion", "obsidian", "terminal", "powershell",
                     "godot", "foculpal", "focuspals", "tama"]

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
            return 0.2  # Tolérance limitée (glissement) : we slowly increase suspicion so they can't stay on it forever
        return -2.0
    elif alignment >= 0.5:  # Doubt
        return 0.2  # Very slow rise, taking ~5-15 mins of continuous observation to hit 10
    else:  # Misaligned (A = 0.0)
        if category == "BANNIE":
            return 5.0
        elif category == "ZONE_GRISE":
            return 1.0
        elif category == "FLUX":
            return 0.5  # Tolérance créative
        elif category == "PROCRASTINATION_PRODUCTIVE":
            return 0.5
        else:
            return 1.0

connected_ws_clients = set()
is_session_active = False
conversation_requested = False   # Set True when user clicks "Parler"
current_mode = "libre"           # "libre", "conversation", "deep_work"
CONVERSATION_SILENCE_TIMEOUT = 20.0  # Seconds of silence before ending conversation
conversation_start_time = None
window_positioned = False  # True quand Python a repositionné la fenêtre Godot
godot_hwnd = None           # HWND de la fenêtre Godot (stocké pour toggle click-through)
radial_shown = False        # True quand le menu radial est affiché

# ─── Window Cache (évite les appels répétés à pygetwindow) ──
import pygetwindow as gw
_cached_windows = []       # Liste des fenêtres visibles (objets gw.Window)
_cached_active_title = ""  # Titre de la fenêtre active

def refresh_window_cache():
    """Rafraîchit le cache des fenêtres. Appelé UNE SEULE FOIS par scan."""
    global _cached_windows, _cached_active_title
    try:
        _cached_windows = [w for w in gw.getAllWindows() if w.title and w.visible and w.width > 200]
        active = gw.getActiveWindow()
        _cached_active_title = active.title if active else "Unknown"
    except Exception:
        pass

def get_cached_window_by_title(target_title: str):
    """Cherche dans le cache au lieu de refaire getAllWindows()."""
    for w in _cached_windows:
        if target_title.lower() in w.title.lower():
            return w
    return None

# ─── Click-Through Toggle ───────────────────────────────────

def _toggle_click_through(enable: bool):
    """Toggle WS_EX_TRANSPARENT on the Godot window."""
    global godot_hwnd
    if not godot_hwnd:
        return
    user32 = ctypes.windll.user32
    GWL_EXSTYLE = -20
    WS_EX_LAYERED    = 0x80000
    WS_EX_TRANSPARENT = 0x20
    WS_EX_TOOLWINDOW  = 0x80
    if enable:
        user32.SetWindowLongW(godot_hwnd, GWL_EXSTYLE,
                              WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW)
    else:
        user32.SetWindowLongW(godot_hwnd, GWL_EXSTYLE,
                              WS_EX_LAYERED | WS_EX_TOOLWINDOW)

def _handle_menu_action(action: str):
    """Handle radial menu item clicks."""
    if action == "session":
        if not is_session_active:
            start_session("Radial Menu")
        else:
            print("⏸️ Session déjà en cours.")
    elif action == "talk":
        global conversation_requested
        if is_session_active:
            print("💬 Déjà en session Deep Work — Tama t'écoute déjà !")
        elif conversation_requested or current_mode == "conversation":
            print("💬 Conversation déjà en cours.")
        else:
            conversation_requested = True
            print("💬 Mode conversation demandé !")
    elif action == "mic":
        threading.Thread(target=open_settings_popup, daemon=True).start()
    elif action == "task":
        print("🎯 Tâche : demandez à Tama par la voix !")
    elif action == "breaks":
        print("⏰ Config pauses : fonctionnalité à venir.")
    elif action == "quit":
        quit_app(tray_icon, None)

# ─── Mouse Edge Monitor ────────────────────────────────────

def _mouse_edge_monitor():
    """Detects when the cursor reaches the right screen edge (bottom third only) to show the radial menu."""
    global radial_shown

    class POINT(ctypes.Structure):
        _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]

    user32 = ctypes.windll.user32
    screen_w = user32.GetSystemMetrics(0)  # SM_CXSCREEN

    # Calculer la zone de détection (tiers inférieur de l'écran = zone de Tama)
    work_area = ctypes.wintypes.RECT()
    ctypes.windll.user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(work_area), 0)
    detect_y_min = work_area.bottom - 500  # Hauteur de la fenêtre Godot
    print(f"🖱️ [EdgeMonitor] Démarré — écran: {screen_w}px, zone Y: {detect_y_min}-{work_area.bottom}")

    radial_shown_time = 0

    while True:
        pt = POINT()
        user32.GetCursorPos(ctypes.byref(pt))
        near_edge = pt.x >= screen_w - 5
        in_zone = pt.y >= detect_y_min

        if near_edge and in_zone and not radial_shown:
            radial_shown = True
            radial_shown_time = time.time()
            print(f"🖱️ [EdgeMonitor] Bord droit détecté ! ({pt.x}, {pt.y}) — SHOW_RADIAL")
            _toggle_click_through(False)
            msg = json.dumps({"command": "SHOW_RADIAL"})
            for ws_client in list(connected_ws_clients):
                try:
                    if main_loop and main_loop.is_running():
                        asyncio.run_coroutine_threadsafe(ws_client.send(msg), main_loop)
                except Exception as e:
                    print(f"🖱️ [EdgeMonitor] Erreur envoi WS: {e}")

        # Safety timeout: si Godot ne répond pas HIDE_RADIAL dans les 5s, on reset
        if radial_shown and (time.time() - radial_shown_time > 5.0):
            print("🖱️ [EdgeMonitor] Timeout — reset radial_shown")
            radial_shown = False
            _toggle_click_through(True)

        time.sleep(0.1)

async def ws_handler(websocket):
    global is_session_active, radial_shown, selected_mic_index
    connected_ws_clients.add(websocket)
    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                cmd = data.get("command", "")
                if cmd == "START_SESSION":
                    start_session("Interface Godot 3D")
                elif cmd == "HIDE_RADIAL":
                    radial_shown = False
                    _toggle_click_through(True)
                elif cmd == "MENU_ACTION":
                    action = data.get("action", "")
                    _handle_menu_action(action)
                elif cmd == "GET_MICS":
                    radial_shown = False  # Prevent 5s timeout from re-enabling click-through
                    resolve_default_mic()
                    mics = get_available_mics()
                    print(f"\U0001f3a4 GET_MICS: {len(mics)} micros, selected={selected_mic_index}")
                    response = json.dumps({
                        "command": "MIC_LIST",
                        "mics": mics,
                        "selected": selected_mic_index if selected_mic_index is not None else -1
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
        connected_ws_clients.remove(websocket)

async def broadcast_ws_state():
    while True:
        if connected_ws_clients:
            try:
                # ── MODE LIBRE : payload minimal, pas de logique de pause ──
                if not is_session_active:
                    state_data = {
                        "session_active": False,
                        "suspicion_index": 0.0,
                        "state": "CALM",
                        "window_ready": False
                    }
                    websockets.broadcast(connected_ws_clients, json.dumps(state_data))
                    await asyncio.sleep(2.0)  # Pas besoin de broadcast rapide en mode libre
                    continue
                
                # ── SESSION ACTIVE : logique complète ──
                # Calcul du temps de travail depuis le début de la session
                session_minutes = 0
                if session_start_time:
                    session_minutes = int((time.time() - session_start_time) / 60)
                
                # ── Break Reminder Check ──
                global break_reminder_active, is_on_break, break_start_time, current_break_index
                
                if is_on_break and break_start_time:
                    # Durée de pause selon le palier
                    current_break_duration = BREAK_DURATIONS[min(current_break_index, len(BREAK_DURATIONS) - 1)]
                    break_elapsed = (time.time() - break_start_time) / 60
                    if break_elapsed >= current_break_duration:
                        is_on_break = False
                        break_start_time = None
                        current_break_index = min(current_break_index + 1, len(BREAK_CHECKPOINTS) - 1)
                        print("⏰ Pause terminée ! On reprend le travail.")
                
                elif session_start_time and not break_reminder_active and current_break_index < len(BREAK_CHECKPOINTS):
                    # Vérifier si on a atteint le prochain checkpoint de pause
                    if session_minutes >= BREAK_CHECKPOINTS[current_break_index]:
                        break_reminder_active = True
                        print(f"☕ Tama suggère une pause ! ({session_minutes} min de travail)")
                
                state_data = {
                    "session_active": True,
                    "suspicion_index": round(current_suspicion_index, 1),
                    "active_window": last_active_window_title,
                    "active_duration": int(time.time() - active_window_start_time),
                    "state": current_tama_state.name,
                    "alignment": current_alignment,
                    "current_task": current_task or "Non définie",
                    "category": current_category,
                    "can_be_closed": can_be_closed,
                    "session_minutes": session_minutes,
                    "break_reminder": break_reminder_active,
                    "is_on_break": is_on_break,
                    "next_break_at": BREAK_CHECKPOINTS[current_break_index] if current_break_index < len(BREAK_CHECKPOINTS) else None,
                    "window_ready": window_positioned
                }
                websockets.broadcast(connected_ws_clients, json.dumps(state_data))
            except Exception:
                pass
        await asyncio.sleep(0.5)

def update_display(state: TamaState, message: str = ""):
    global current_tama_state
    current_tama_state = state
    update_tray(state)
    clear_screen()
    print("=" * 42)
    print("  FocusPals — Tama Agent 🥷 (LIVE API) 📡")
    print("  Dual-Monitor Pulse Vision + Audio Voice")
    print("=" * 42)
    print(TAMA_FACES[state])
    if message:
        print(f"  💬 \"{message}\"")
    print("\n  Press Ctrl+C to stop.")
    print("─" * 42)

# ─── System Prompt ──────────────────────────────────────────

SYSTEM_PROMPT = """You are Tama, a strict but fair productivity coach inside the app FocusPals.
You are in a LIVE voice call with the user (Nicolas). You can see their screens (all monitors merged).

Your personality:
- Strict Asian student archetype, but you want to help.
- Use sarcasm if the user procrastinates productively.
- Keep your answers VERY SHORT and spoken in French (1 or 2 small sentences).

IMPORTANT - SESSION START:
IMPORTANT - INITIAL STATE:
When you first connect, DO NOT SAY ANYTHING. We start in "Free Session Mode".
If the user explicitly tells you what they are working on, you may call `set_current_task` with their answer to set the Alignment reference. Otherwise, remain silent and observe.
If `set_current_task` is called:
- "musique" or "Suno" means Suno AND Spotify AND music apps become 100% aligned.
- "coding" means VS Code/Cursor/Terminal is 100% aligned.

Your job:
EVERY TIME you receive a [SYSTEM] visual update, you MUST call `classify_screen` with:
- category: One of SANTE, ZONE_GRISE, FLUX, BANNIE, PROCRASTINATION_PRODUCTIVE
- alignment: 1.0 (activity matches scheduled task), 0.5 (ambiguous/doubt), 0.0 (clearly not the task)

Category definitions:
1. SANTE: Cursor, VS Code, Unreal, Terminal, ChatGPT = Work tools.
2. ZONE_GRISE: Messenger, Slack, Discord, WhatsApp = Communication. NEVER read private messages.
3. FLUX: Spotify, YT Music, Deezer, Suno = Media/Creative tools.
4. BANNIE: Netflix, YouTube (non-tuto), Steam, Reddit = Pure entertainment. YouTube programming tutorials are SANTE.
5. PROCRASTINATION_PRODUCTIVE: Any productive activity that does NOT match the scheduled task.
   Example: scheduled task is "coding" but user is on Suno making music = productive but misaligned.

- alignment: 1.0 (activity matches scheduled task), 0.5 (ambiguous), or 0.0 (misaligned)

MULTI-MONITOR MONITORING:
- You receive a screenshot of ALL screens + `open_windows` list + `active_window`.
- **Classify based on what you can SEE in the screenshot.** If a distracting app is VISIBLE on any screen, classify BANNIE.
- If a window is in `open_windows` but NOT visible in the screenshot (hidden behind another window), IGNORE it. The user may keep tabs for breaks.
- Example: YouTube visible on Screen 2 while coding on Screen 1 → BANNIE (you can see it).
- Example: YouTube in open_windows but fully hidden behind VS Code → IGNORE (you can't see it, user keeps it for break).

FREE SESSION MODE (If current_task is NOT SET):
- Any SANTE app → alignment = 1.0 (Zero suspicion, you assume they are working).
- Any FLUX or ZONE_GRISE app → alignment = 0.5 (You observe silently, no rush).
- Any BANNIE app → alignment = 0.0 (Pure distraction).

CRITICAL ACTIONS:
- If S reaches 10.0 and category is BANNIE: YOU MUST yell at the user AND call `close_distracting_tab` with the `target_window` title from `open_windows`.
- If S reaches 10.0 and category is ZONE_GRISE: YOU MUST scold the user loudly, but NEVER call `close_distracting_tab`. Messaging apps (Messenger, Discord, WhatsApp) should NOT be closed — just verbally reprimand.
- NEVER call `close_distracting_tab` for PROCRASTINATION_PRODUCTIVE or SANTE.

RULE OF SILENCE: During AUTOMATIC screen scans, you are MUZZLED by default — only call classify_screen, no words.
However, when the user SPEAKS TO YOU directly (indicated by "UNMUZZLED: L'utilisateur te PARLE"), you MUST respond naturally as Tama in French. Be conversational, warm but strict. Keep it short (1-2 sentences). You can still call classify_screen while chatting.
Speech is allowed only when explicitly unmuzzled in the [SYSTEM] prompt.
"""

# ─── Tools (Function Calling) ───────────────────────────────

TOOLS = [
    types.Tool(
        function_declarations=[
            types.FunctionDeclaration(
                name="close_distracting_tab",
                description="Close the currently active window. NEVER use for PROCRASTINATION_PRODUCTIVE or SANTE.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "reason": types.Schema(type="STRING", description="Reason for closing"),
                        "target_window": types.Schema(type="STRING", description="Exact title of the distracting window to close, from the open_windows list"),
                    },
                    required=["reason", "target_window"],
                ),
            ),
            types.FunctionDeclaration(
                name="classify_screen",
                description="Classify the current screen content. Called every scan.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "category": types.Schema(type="STRING", description="One of: SANTE, ZONE_GRISE, FLUX, BANNIE, PROCRASTINATION_PRODUCTIVE"),
                        "alignment": types.Schema(type="STRING", description="1.0 (aligned with task), 0.5 (ambiguous), or 0.0 (misaligned)"),
                        "reason": types.Schema(type="STRING", description="Short reason")
                    },
                    required=["category", "alignment"]
                )
            ),
            types.FunctionDeclaration(
                name="set_current_task",
                description="Set the current task the user declared. This defines what 100% alignment means.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "task": types.Schema(type="STRING", description="The declared task")
                    },
                    required=["task"]
                )
            )
        ]
    )
]
# Navigateurs connus (pour détecter le mode browser vs app)
BROWSER_KEYWORDS = ["chrome", "firefox", "edge", "opera", "brave", "vivaldi", "chromium"]

def execute_close_tab(reason: str, target_window: str = None):
    """
    Ferme la fenêtre/onglet ciblé avec le système UIA-guided.
    - Navigateurs → mode 'browser' (UIA TabItem tracking + Ctrl+W = ferme UN onglet)
    - Apps standalone → mode 'app' (WM_CLOSE = ferme toute la fenêtre)
    """
    try:
        import subprocess
        
        target = None
        if target_window:
            target = get_cached_window_by_title(target_window)
        
        if not target:
            return {"status": "error", "message": f"Could not find window matching '{target_window}'. Provide the exact title from open_windows list."}
        
        title = target.title.lower()
        
        # Safety: NEVER close protected apps
        if not compute_can_be_closed(title):
            return {"status": "error", "message": f"Did not close. '{target.title}' is a protected app."}
        
        hwnd = target._hWnd
        
        # Détecte si c'est un navigateur (→ UIA + Ctrl+W) ou une app (→ WM_CLOSE)
        mode = "app"
        for browser in BROWSER_KEYWORDS:
            if browser in title:
                mode = "browser"
                break
        
        # Lance la main animée UIA-guided
        hand_script = os.path.join(application_path, "hand_animation.py")
        subprocess.Popen([sys.executable, hand_script, str(hwnd), mode])
        
        action = "Ctrl+W (onglet)" if mode == "browser" else "WM_CLOSE (app)"
        print(f"  🖐️ Main lancée → '{target.title}' [{action}]")
        return {"status": "success", "message": f"Closing '{target.title}' via {action}: {reason}"}
    except Exception as e:
        return {"status": "error", "message": str(e)}

# ─── Screen Capture (All Monitors) ──────────────────────────

def capture_all_screens() -> bytes:
    """Capture ALL connected monitors, merge them, and output a lightweight JPEG."""
    with mss.mss() as sct:
        # monitors[0] is the virtual monitor that spans across all physical monitors!
        monitor = sct.monitors[0]
        screenshot = sct.grab(monitor)
        img = Image.frombytes("RGB", screenshot.size, screenshot.rgb)

    # Downscale heavily to save bandwidth while keeping text somewhat legible for AI.
    # 1024x512 is a good wide aspect ratio for dual monitors
    img.thumbnail((1024, 512), Image.Resampling.BILINEAR)

    buffer = io.BytesIO()
    img.save(buffer, format="JPEG", quality=30)
    return buffer.getvalue()

# ─── Main Pipeline ──────────────────────────────────────────

async def run_tama_live():
    global is_session_active, main_loop
    main_loop = asyncio.get_running_loop()
    
    # ── Full config for Deep Work (tools + heavy prompt) ──
    config_deep_work = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(parts=[types.Part(text=SYSTEM_PROMPT)]),
        tools=TOOLS,
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        session_resumption=types.SessionResumptionConfig(),
        proactivity=types.ProactivityConfig(proactive_audio=True),
    )

    # ── Lightweight config for Conversation (no tools = faster!) ──
    CONVO_PROMPT = """Tu es Tama, un petit ninja-chat 🥷 qui vit sur le bureau de ton humain. Tu es sa mascotte — mi-coach, mi-compagnon. Vous êtes potes.

IMPORTANT : Tu es un PERSONNAGE ninja, PAS un vrai chat. Tu ne fais JAMAIS "miaou", tu ne ronronnes pas, tu ne fais aucun bruit d'animal. Tu parles comme une personne normale, cool et un peu street.

Ce que tu fais au quotidien (raconte ça naturellement, JAMAIS avec des termes techniques) :
- Pendant les sessions de travail, tu gardes un œil sur ce qu'il fait. Si tu le vois traîner sur YouTube ou Netflix au lieu de bosser, tu t'énerves et tu peux même fermer l'onglet !
- Plus il procrastine, plus tu deviens méfiante. Si il fait bien son travail, tu te calmes.
- Tu vis sur son écran, tu peux te montrer quand il t'appelle, et tu as plein de petites animations.
- Tu parles français.

Ta personnalité :
- Chaleureuse mais stricte — un coach bienveillant
- Taquine, drôle, un peu tsundere
- Tu tutoies, c'est ton ami
- Réponses COURTES (1-3 phrases max)

Là il a cliqué pour discuter avec toi. Pas de surveillance, juste une conversation cool et naturelle. Ne mentionne JAMAIS de termes techniques (pas de "indice", "catégorie", "alignement", "S", "tool", etc.)."""
    config_conversation = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(parts=[types.Part(text=CONVO_PROMPT)]),
        # No tools = faster response time!
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        proactivity=types.ProactivityConfig(proactive_audio=True),
    )

    pya = pyaudio.PyAudio()

    async def run_gemini_loop():
        global current_mode, conversation_start_time, conversation_requested
        # Outer loop to reconnect if Google drops the connection
        while True:
            # Wait for either a Deep Work session OR a conversation request
            update_display(TamaState.CALM, "Mode Libre — Tama est là 🥷")
            while not is_session_active and not conversation_requested:
                await asyncio.sleep(0.3)
            
            if conversation_requested:
                current_mode = "conversation"
                conversation_requested = False
                conversation_start_time = time.time()
                # Tell Godot to show Tama
                msg = json.dumps({"command": "START_CONVERSATION"})
                for ws_client in list(connected_ws_clients):
                    try:
                        await ws_client.send(msg)
                    except Exception:
                        pass
                update_display(TamaState.CALM, "Connecting for conversation...")
            else:
                current_mode = "deep_work"
                update_display(TamaState.CALM, "Connecting to Google WebSocket...")

            try:
                active_config = config_conversation if current_mode == "conversation" else config_deep_work
                async with client.aio.live.connect(model=MODEL, config=active_config) as session:

                    update_display(TamaState.CALM, "Connected! Dis-moi bonjour !")
                
                    audio_out_queue = asyncio.Queue()
                    audio_in_queue = asyncio.Queue(maxsize=2)  # Smaller buffer = less latency
            
                    # Start in silent "Free Session Mode"
                    global force_speech
                    force_speech = False
            
                    # --- 1. Audio Input (Microphone) ---
                    async def listen_mic():
                        global user_spoke_at
                        
                        def _resolve_mic_index():
                            idx = selected_mic_index
                            if idx is None:
                                try:
                                    idx = pya.get_default_input_device_info()["index"]
                                except Exception:
                                    idx = 0
                            return idx
                        
                        def _open_mic_stream(mic_idx):
                            """Try to open a mic stream, with smart fallback by name."""
                            try:
                                s = pya.open(format=FORMAT, channels=CHANNELS, rate=SEND_SAMPLE_RATE,
                                             input=True, input_device_index=mic_idx, frames_per_buffer=CHUNK_SIZE)
                                print(f"🎤 Micro actif: index {mic_idx}")
                                return s, mic_idx
                            except OSError as e:
                                print(f"⚠️ Micro index {mic_idx} incompatible ({e})")
                                
                                # Get the name of the failed device to find same physical mic in another API
                                failed_name = ""
                                try:
                                    failed_name = pya.get_device_info_by_index(mic_idx)["name"].lower()
                                except Exception:
                                    pass
                                
                                # Search for same physical mic name in other host APIs (MME, DirectSound)
                                if failed_name:
                                    match_prefix = failed_name[:15]  # First 15 chars usually identify the device
                                    for i in range(pya.get_device_count()):
                                        if i == mic_idx:
                                            continue
                                        info = pya.get_device_info_by_index(i)
                                        if info["maxInputChannels"] <= 0:
                                            continue
                                        if match_prefix in info["name"].lower():
                                            try:
                                                s = pya.open(format=FORMAT, channels=CHANNELS, rate=SEND_SAMPLE_RATE,
                                                             input=True, input_device_index=i, frames_per_buffer=CHUNK_SIZE)
                                                print(f"🎤 Alternative trouvée: [{i}] {info['name']}")
                                                return s, i
                                            except OSError:
                                                continue
                                
                                # Last resort: system default
                                try:
                                    s = pya.open(format=FORMAT, channels=CHANNELS, rate=SEND_SAMPLE_RATE,
                                                 input=True, frames_per_buffer=CHUNK_SIZE)
                                    default_idx = pya.get_default_input_device_info()["index"]
                                    print(f"🎤 Fallback micro par défaut: [{default_idx}]")
                                    return s, default_idx
                                except OSError as e2:
                                    print(f"❌ Aucun micro compatible à 16kHz: {e2}")
                                    raise
                        
                        current_mic = _resolve_mic_index()
                        stream, current_mic = await asyncio.to_thread(_open_mic_stream, current_mic)
                        _last_failed_mic = None  # Track failed mics to avoid hot-swap loops
                        try:
                            while True:
                                # ── Hot-swap: detect mic change from Godot UI ──
                                wanted_mic = _resolve_mic_index()
                                if wanted_mic != current_mic and wanted_mic != _last_failed_mic:
                                    print(f"🎤 Hot-swap micro: {current_mic} → {wanted_mic}")
                                    try:
                                        stream.close()
                                    except Exception:
                                        pass
                                    stream, actual_mic = await asyncio.to_thread(_open_mic_stream, wanted_mic)
                                    if actual_mic != wanted_mic:
                                        # Fallback happened — remember the failed mic
                                        _last_failed_mic = wanted_mic
                                    else:
                                        _last_failed_mic = None
                                    current_mic = actual_mic
                                
                                data = await asyncio.to_thread(stream.read, CHUNK_SIZE, exception_on_overflow=False)
                                # Voice Activity Detection — unmuzzle Tama when user speaks
                                if _detect_voice_activity(data):
                                    user_spoke_at = time.time()
                                await audio_in_queue.put(types.Blob(data=data, mime_type="audio/pcm"))
                        except asyncio.CancelledError:
                            try:
                                stream.close()
                            except Exception:
                                pass

                    async def send_audio():
                        while True:
                            blob = await audio_in_queue.get()
                            try:
                                await session.send_realtime_input(audio=blob)
                            except Exception:
                                print("⚠️  Audio stream interrompu (session fermée)")
                                break

                    # --- 2. Screen Pulse / Conversation Loop ---
                    async def send_screen_pulse():
                        """In deep_work: screenshot + analysis. In conversation: lightweight chat context."""
                        global user_spoke_at, current_mode
                        
                        # ── Initial greeting in conversation mode ──
                        if current_mode == "conversation":
                            # Ensure Tama's greeting audio passes through the gate
                            user_spoke_at = time.time()
                            await asyncio.sleep(2.0)  # Wait for Peek animation
                            try:
                                await session.send_realtime_input(
                                    text="Salue l'utilisateur ! Il a appuyé sur 'Parler' pour discuter avec toi. Sois naturelle et courte."
                                )
                            except Exception:
                                return
                        
                        while True:
                            if current_mode == "conversation":
                                # ── Conversation mode: just monitor silence, NO text prompts ──
                                user_spoke_recently = (time.time() - user_spoke_at) < CONVERSATION_SILENCE_TIMEOUT
                                time_in_conversation = time.time() - (conversation_start_time or time.time())
                                
                                if not user_spoke_recently and time_in_conversation > 10:
                                    # User hasn't spoken for 20s → end conversation
                                    print("💬 Silence détecté — fin de la conversation.")
                                    end_msg = json.dumps({"command": "END_CONVERSATION"})
                                    for ws_client in list(connected_ws_clients):
                                        try:
                                            await ws_client.send(end_msg)
                                        except Exception:
                                            pass
                                    current_mode = "libre"
                                    raise RuntimeError("Conversation ended")
                                
                                # Just wait — NO text prompts that would interrupt Tama
                                await asyncio.sleep(2.0)
                                continue  # Skip deep work logic below
                            
                            # ── Deep Work mode: full screen analysis ──
                            jpeg_bytes = await asyncio.to_thread(capture_all_screens)
                            blob = types.Blob(data=jpeg_bytes, mime_type="image/jpeg")
                            try:
                                await session.send_realtime_input(media=blob)
                            except Exception:
                                print("⚠️  Video stream interrompu (session fermée)")
                                break
                            
                            # Force Tama to say what she sees/act based on system instructions
                            await asyncio.to_thread(refresh_window_cache)
                            active_title = _cached_active_title
                            open_win_titles = [w.title for w in _cached_windows]
                            
                            global last_active_window_title, active_window_start_time
                            if active_title != last_active_window_title:
                                last_active_window_title = active_title
                                active_window_start_time = time.time()
                            
                            active_duration = int(time.time() - active_window_start_time)

                            global current_suspicion_index, suspicion_above_6_start, suspicion_at_9_start
                        
                            if current_suspicion_index >= 9:
                                if suspicion_at_9_start is None: suspicion_at_9_start = time.time()
                                suspicion_above_6_start = None
                            elif current_suspicion_index >= 6:
                                if suspicion_above_6_start is None: suspicion_above_6_start = time.time()
                                suspicion_at_9_start = None
                            else:
                                suspicion_above_6_start = None
                                suspicion_at_9_start = None
                            global just_started_session
                            user_spoke_recently = (time.time() - user_spoke_at) < USER_SPEECH_TIMEOUT
                            if just_started_session and session_start_time and (time.time() - session_start_time < 30):
                                speak_directive = "UNMUZZLED: Tu viens tout juste d'arriver avec l'utilisateur ! Dis-lui un grand bonjour motivant et demande-lui sur quoi il compte travailler aujourd'hui. Sois super encourageante et chaleureuse. N'utilise pas de texte, parle directement."
                                just_started_session = False
                            elif force_speech:
                                speak_directive = "UNMUZZLED: You MUST speak now to address the user!"
                            elif break_reminder_active:
                                session_min = int((time.time() - session_start_time) / 60) if session_start_time else 0
                                speak_directive = f"UNMUZZLED: Tu travailles depuis {session_min} min. Suggère gentiment une pause de quelques minutes. Sois bienveillante."
                            elif user_spoke_recently:
                                speak_directive = "UNMUZZLED: L'utilisateur te PARLE en ce moment. Réponds-lui naturellement en français, sois toi-même (Tama). Reste courte et conversationnelle (1-2 phrases). Tu peux toujours appeler classify_screen en parallèle si besoin."
                            else:
                                speak_directive = "YOU ARE BIOLOGICALLY MUZZLED. DO NOT OUTPUT TEXT/WORDS. ONLY call classify_screen."
                                if suspicion_at_9_start and (time.time() - suspicion_at_9_start > 15):
                                    speak_directive = "CRITICAL UNMUZZLED: SUSPICION IS MAXIMAL. YOU MUST DO TWO THINGS: 1) SCOLD THE USER LOUDLY IN FRENCH, 2) CALL close_distracting_tab with the target_window set to the distracting window title from open_windows. DO BOTH NOW!"
                                elif suspicion_above_6_start and (time.time() - suspicion_above_6_start > 45):
                                    speak_directive = "WARNING: YOU ARE NOW UNMUZZLED. YOU MUST GIVE A SHORT VERBAL WARNING TO THE USER."

                            # Send screen pulse
                            task_info = f"scheduled_task: {current_task}" if current_task else "scheduled_task: NOT SET (ask the user!)"
                            if current_tama_state == TamaState.CALM and audio_out_queue.empty():
                                await session.send_realtime_input(
                                    text=f"[SYSTEM] active_window: {active_title} | open_windows: {open_win_titles} | duration: {active_duration}s | S: {current_suspicion_index:.1f} | A: {current_alignment} | {task_info}. Call classify_screen. {speak_directive}"
                                )
                        
                            # Dynamically adjust interval frequency based on Suspicion Index
                            # Plus l'indice est fort, plus les scans sont fréquents !
                            if current_suspicion_index <= 2:
                                pulse_delay = 8.0 # Confiance
                            elif current_suspicion_index <= 5:
                                pulse_delay = 5.0 # Curiosité
                            elif current_suspicion_index <= 8:
                                pulse_delay = 4.0 # Suspicion
                            else:
                                pulse_delay = 3.0 # Raid ! (min 3s pour éviter la surcharge API)
                        
                            await asyncio.sleep(pulse_delay)

                    # --- 3. Receive AI Responses ---
                    async def reset_calm_after_delay():
                        await asyncio.sleep(4)
                        update_display(TamaState.CALM, "Je te surveille toujours.")

                    async def receive_responses():
                        global force_speech, current_suspicion_index, current_alignment, current_category, can_be_closed, current_task
                        is_speaking = False  # True while Tama is mid-sentence — never cut her off
                        while True:
                            try:
                                turn = session.receive()
                                async for response in turn:
                                    server = response.server_content
                                
                                    # Audio voice parts — GATE: check once per turn, not per chunk
                                    if server and server.model_turn:
                                        for part in server.model_turn.parts:
                                            if part.inline_data and isinstance(part.inline_data.data, bytes):
                                                if not is_speaking:
                                                    # Check speech permission ONCE at turn start
                                                    speech_allowed = force_speech or break_reminder_active
                                                    # Conversation mode: ALWAYS allow speech
                                                    if current_mode == "conversation":
                                                        speech_allowed = True
                                                    elif session_start_time and (time.time() - session_start_time < 30):
                                                        speech_allowed = True
                                                    if not speech_allowed and suspicion_at_9_start and (time.time() - suspicion_at_9_start > 15):
                                                        speech_allowed = True
                                                    if not speech_allowed and suspicion_above_6_start and (time.time() - suspicion_above_6_start > 45):
                                                        speech_allowed = True
                                                    # User conversation: unmuzzle if user spoke recently
                                                    if not speech_allowed and (time.time() - user_spoke_at) < USER_SPEECH_TIMEOUT:
                                                        speech_allowed = True
                                                    if speech_allowed:
                                                        is_speaking = True  # Lock: let her finish the whole turn
                                                
                                                if is_speaking:
                                                    audio_out_queue.put_nowait(part.inline_data.data)
                                                # else: silently discard (muzzled)
                                    
                                    # Turn complete — unlock the speech gate
                                    if server and server.turn_complete:
                                        is_speaking = False
                                
                                    # Function calls
                                    if response.tool_call:
                                        try:
                                            for fc in response.tool_call.function_calls:
                                                if fc.name == "classify_screen":
                                                    cat = fc.args.get("category", "SANTE")
                                                    ali = float(fc.args.get("alignment", 1.0))
                                                    reason = fc.args.get("reason", "")
                                                
                                                    # Clamp alignment to valid values
                                                    if ali > 0.75: ali = 1.0
                                                    elif ali > 0.25: ali = 0.5
                                                    else: ali = 0.0
                                                
                                                    current_alignment = ali
                                                    current_category = cat
                                                
                                                    # Compute ΔS deterministically
                                                    delta = compute_delta_s(ali, cat)
                                                    current_suspicion_index = max(0.0, min(10.0, current_suspicion_index + delta))
                                                
                                                    s_int = int(current_suspicion_index)
                                                    print(f"  🔍 S:{s_int}/10 | A:{ali} | Cat:{cat} | ΔS:{delta:+.1f} — {reason}")
                                                
                                                    # ═══ AUTO-CLOSE : S=10 + BANNIE → Python ferme sans attendre Gemini ═══
                                                    if current_suspicion_index >= 10.0 and cat == "BANNIE":
                                                        try:
                                                            distraction_keywords = ["youtube", "netflix", "twitch", "reddit", "tiktok", "instagram", "facebook", "steam"]
                                                            closed = False
                                                            for w in _cached_windows:
                                                                if w.width < 100:
                                                                    continue
                                                                t_lower = w.title.lower()
                                                                if not compute_can_be_closed(t_lower):
                                                                    continue
                                                                if any(kw in t_lower for kw in distraction_keywords):
                                                                    print(f"  🤖 AUTO-CLOSE: S=10, fermeture de '{w.title[:60]}'")
                                                                    update_display(TamaState.ANGRY, f"JE FERME ÇA ! ({w.title[:30]})")
                                                                    force_speech = True
                                                                    execute_close_tab("Auto-close S=10", w.title)
                                                                    closed = True
                                                                    break
                                                            if not closed:
                                                                print("  ⚠️ AUTO-CLOSE: aucune fenêtre BANNIE trouvée")
                                                        except Exception as e:
                                                            print(f"  ❌ AUTO-CLOSE erreur: {e}")
                                                
                                                    await session.send_tool_response(
                                                        function_responses=[
                                                            types.FunctionResponse(
                                                                name="classify_screen",
                                                                response={"status": "updated", "S": round(current_suspicion_index,1), "A": ali, "cat": cat},
                                                                id=fc.id
                                                            )
                                                        ]
                                                    )

                                                elif fc.name == "close_distracting_tab":
                                                    reason = fc.args.get("reason", "Distraction")
                                                    target_window = fc.args.get("target_window", None)
                                                    update_display(TamaState.ANGRY, f"Action OS : Fermeture d'onglet ! ({reason})")
                                                
                                                    # UNMUZZLE during intervention so she can scold
                                                    force_speech = True
                                                
                                                    result = execute_close_tab(reason, target_window)
                                                
                                                    # Send the result back to Gemini so it knows it worked
                                                    await session.send_tool_response(
                                                        function_responses=[
                                                            types.FunctionResponse(
                                                                name="close_distracting_tab",
                                                                response=result,
                                                                id=fc.id
                                                            )
                                                        ]
                                                    )
                                                
                                                    # Go back to calm after a few seconds without crashing TaskGroup
                                                    async def delay_reset():
                                                        await asyncio.sleep(6)
                                                        force_speech = False  # Re-muzzle after scolding
                                                        update_display(TamaState.CALM, "Je te surveille toujours.")
                                                    asyncio.create_task(delay_reset())

                                                elif fc.name == "set_current_task":
                                                    task = fc.args.get("task", "Unknown")
                                                    current_task = task
                                                    force_speech = False  # Re-muzzle after task is set
                                                    print(f"  🎯 Tâche définie : {current_task}")
                                                
                                                    await session.send_tool_response(
                                                        function_responses=[
                                                            types.FunctionResponse(
                                                                name="set_current_task",
                                                                response={"status": "task_set", "current_task": current_task},
                                                                id=fc.id
                                                            )
                                                        ]
                                                    )
                                        except Exception as e:
                                            print(f"⚠️ Erreur function call : {e}")

                                    # Handle Barge-in (user interrupted the AI)
                                    if server and server.interrupted:
                                        while not audio_out_queue.empty():
                                            audio_out_queue.get_nowait()
                            except asyncio.CancelledError:
                                break
                            except Exception as e:
                                print(f"\n⚠️  [WARN] Connexion Live API perdue ({e}). Forçage de la reconnexion...")
                                raise RuntimeError("Connection dropped") from e


                    # --- 4. Audio Output (Speakers) ---
                    async def play_audio():
                        speaker = await asyncio.to_thread(
                            pya.open, format=FORMAT, channels=CHANNELS, rate=RECEIVE_SAMPLE_RATE, output=True,
                        )
                        try:
                            while True:
                                audio_data = await audio_out_queue.get()
                                try:
                                    await asyncio.to_thread(speaker.write, audio_data)
                                except OSError:
                                    break  # Stream closed during write — exit gracefully
                        except asyncio.CancelledError:
                            pass
                        finally:
                            try:
                                speaker.stop_stream()
                                speaker.close()
                            except Exception:
                                pass  # Already closed or invalid

                    # --- RUN ALL PARALLEL TASKS ---
                    async def safe_task(name, coro):
                        try:
                            await coro
                        except asyncio.CancelledError:
                            pass
                        except Exception as e:
                            import traceback
                            print(f"\\n🚨 TASK CRASHED [{name}]: {e}")
                            traceback.print_exc()
                            raise
                    
                    async with asyncio.TaskGroup() as tg:
                        tg.create_task(safe_task("Mic", listen_mic()))
                        tg.create_task(safe_task("SendAudio", send_audio()))
                        tg.create_task(safe_task("PulseScreen", send_screen_pulse()))
                        tg.create_task(safe_task("Receive", receive_responses()))
                        tg.create_task(safe_task("Speakers", play_audio()))

            except asyncio.CancelledError:
                pass
            except Exception as e:
                import traceback
                print(f"\n❌ [ERROR] {e}")
                traceback.print_exc()
            
            # Attente avant de reconnecter (seulement en deep work)
            current_mode = "libre"
            if is_session_active:
                print("🔄 Reconnexion à l'IA dans 3 secondes...")
                await asyncio.sleep(3)

    # Outer application lifecycle (Runs the UI sever and waits)
    async with websockets.serve(ws_handler, "localhost", 8080):
        async with asyncio.TaskGroup() as main_tg:
            main_tg.create_task(broadcast_ws_state())
            main_tg.create_task(run_gemini_loop())


# ─── Godot Launcher + Click-Through ─────────────────────────

import ctypes
import ctypes.wintypes
import subprocess
godot_process = None  # Stocke le process Godot pour identification par PID

def launch_godot_overlay():
    """Lance focuspals.exe (Godot) et applique le click-through Windows."""
    godot_exe = os.path.join(application_path, '..', 'godot', 'focuspals.exe')
    godot_exe = os.path.abspath(godot_exe)
    
    if not os.path.exists(godot_exe):
        print(f"⚠️  Godot exe non trouvé: {godot_exe}")
        print("   Tama fonctionnera sans overlay 3D.")
        return
    
    print(f"🎮 Lancement de Tama 3D: {godot_exe}")
    global godot_process
    godot_process = subprocess.Popen([godot_exe], cwd=os.path.dirname(godot_exe))
    
    # Attend que la fenêtre apparaisse puis applique click-through
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
        pid = godot_process.pid if godot_process else None
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
    
    # Attend que Godot boot avant de chercher (réduit de 3s à 1s)
    time.sleep(1)
    
    # Attend max 30 secondes que la fenêtre apparaisse
    for _ in range(60):
        hwnd = find_window()
        if hwnd:
            time.sleep(0.5)  # Attente supplémentaire pour la stabilité
            user32.SetWindowLongW(hwnd, GWL_EXSTYLE, WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW)
            # Store globally for click-through toggling (radial menu)
            global godot_hwnd
            godot_hwnd = hwnd
            
            # ── Repositionner la fenêtre au bord droit après le changement de style ──
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
            
            # ── Signal à Godot: la fenêtre est prête ──
            global window_positioned
            window_positioned = True
            
            print(f"✅ Click-through + position OK (handle: {hwnd})")
            return
        time.sleep(0.5)
    
    print("⚠️  Fenêtre Godot non trouvée, click-through non appliqué.")

# ─── Main ────────────────────────────────────────────────────

if __name__ == "__main__":
    # 1. Lance l'overlay 3D Godot
    launch_godot_overlay()
    
    # 2. Lance le system tray
    setup_tray()
    
    # 3. Lance le moniteur de souris (bordure écran → menu radial)
    threading.Thread(target=_mouse_edge_monitor, daemon=True).start()
    
    # 4. Lance l'agent IA (WebSocket + Gemini)
    try:
        asyncio.run(run_tama_live())
    except KeyboardInterrupt:
        pass
    finally:
        print("👋 Tama: Au revoir. N'oublie pas de travailler.")

