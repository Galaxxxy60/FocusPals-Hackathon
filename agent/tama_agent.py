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
"""

import asyncio
import threading

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

    # 3. Lance le moniteur de souris (bordure écran → menu radial)
    threading.Thread(target=mouse_edge_monitor, daemon=True).start()

    # 4. Lance l'agent IA (WebSocket + Gemini)
    try:
        asyncio.run(run_tama_live())
    except KeyboardInterrupt:
        pass
    finally:
        print("👋 Tama: Au revoir. N'oublie pas de travailler.")
