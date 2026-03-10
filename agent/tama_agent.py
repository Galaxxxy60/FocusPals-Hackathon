"""
FocusPals Agent — Tama 🥷 -> TRUE LIVE API (WebSocket) 📡
Proactive AI productivity coach powered by Gemini Multimodal Live API.

Features:
- 🎙️ Continuous audio streaming (Mic & Speaker)
- 👁️ Multi-monitor vision (All screens merged)
- ⏳ "Pulse" video sending (1 frame every 5 seconds to save bandwidth)
- 🛠️ Function Calling (Closes distracting tabs)
- 🎭 ASCII State Machine

This file is the thin entry point. All logic lives in:
- config.py          — Constants, API client, shared state dict
- audio.py           — Mic management, VAD
- suspicion.py       — A.S.C. engine (ΔS, alignment, categories)
- screen_capture.py  — Multi-monitor capture, window cache
- ui.py              — Display, tray icon, settings popup
- godot_bridge.py    — WebSocket server, Godot launcher, click-through, edge monitor
- gemini_session.py  — System prompt, tools, Gemini Live loop
- crash_logger.py    — Crash logging, file logging, state dumps
"""

# ── DPI AWARENESS: must be set BEFORE any ctypes/Win32 calls ──
# Without this, GetWindowRect returns virtualized 0×0 for transparent/layered
# windows on high-DPI screens (e.g. 2560px with 150% scaling).
import ctypes
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)  # Per-Monitor V2
except Exception:
    try:
        ctypes.windll.user32.SetProcessDPIAware()   # Fallback
    except Exception:
        pass

# ── CRASH LOGGER: must init BEFORE any other imports ──
from crash_logger import init_crash_logger, install_async_exception_handler
init_crash_logger()

import asyncio
import threading
import logging

# Silence spammy google.genai logs ("AFC is enabled with max remote calls: 10")
logging.getLogger("google.genai").setLevel(logging.WARNING)
logging.getLogger("google.genai.live").setLevel(logging.WARNING)

import pyaudio
import websockets

from config import state
from ui import TamaState, setup_tray
from godot_bridge import launch_godot_overlay, mouse_edge_monitor, ws_handler, broadcast_ws_state
from gemini_session import run_gemini_loop


# Initialize TamaState in shared state
state["current_tama_state"] = TamaState.CALM


async def run_tama_live():
    """Main async entry point: WebSocket server + Gemini loop."""
    state["main_loop"] = asyncio.get_running_loop()
    install_async_exception_handler(asyncio.get_running_loop())

    # Port 8080 cleanup is done in launch_godot_overlay() BEFORE Godot starts,
    # ensuring the new Godot connects to our WS server (not a stale one).

    pya = pyaudio.PyAudio()

    async with websockets.serve(ws_handler, "localhost", 8080):
        async with asyncio.TaskGroup() as main_tg:
            main_tg.create_task(broadcast_ws_state())
            main_tg.create_task(run_gemini_loop(pya))


if __name__ == "__main__":
    # 1. Lance l'overlay 3D Godot
    launch_godot_overlay()

    # 2. Lance le system tray
    setup_tray()

    # 2.5 Validate existing API key in background (non-blocking)
    import config as _cfg
    if _cfg._api_key_present_at_start:
        def _bg_validate():
            from godot_bridge import _validate_api_key
            state["_api_key_valid"] = _validate_api_key(_cfg.GEMINI_API_KEY)
        threading.Thread(target=_bg_validate, daemon=True).start()

    # 3. Lance le moniteur de souris (bordure écran → menu radial)
    threading.Thread(target=mouse_edge_monitor, daemon=True).start()

    # 4. Lance l'agent IA (WebSocket + Gemini)
    try:
        asyncio.run(run_tama_live())
    except KeyboardInterrupt:
        pass
    finally:
        print("👋 Tama: Au revoir. N'oublie pas de travailler.")
