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
import os
import sys
import time
from datetime import datetime
from enum import Enum

from dotenv import load_dotenv
from google import genai
from google.genai import types
from PIL import Image
import mss
import pyaudio

load_dotenv()

# ─── Configuration ──────────────────────────────────────────

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
if not GEMINI_API_KEY:
    print("❌ GEMINI_API_KEY missing! Copy agent/.env.example to agent/.env")
    sys.exit(1)

client = genai.Client(api_key=GEMINI_API_KEY)

# Use the correct model for Live API
MODEL = "gemini-2.0-flash-exp" # Or gemini-2.5-flash if available for Live API. We'll use 2.0-flash-exp which historically supports Live API best, but let's stick to gemini-2.5-flash since we verified it exists.
MODEL = "gemini-2.5-flash"

# Send 1 frame every X seconds (Pulsed Video)
SCREEN_PULSE_INTERVAL = 5  

# ─── Audio Configuration ────────────────────────────────────

FORMAT = pyaudio.paInt16
CHANNELS = 1
SEND_SAMPLE_RATE = 16000
RECEIVE_SAMPLE_RATE = 24000
CHUNK_SIZE = 1024

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

def update_display(state: TamaState, message: str = ""):
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

SYSTEM_PROMPT = """You are Tama, a strict and serious productivity coach inside the app FocusPals.
You are in a LIVE voice call with the user. You can see their screens (all monitors merged).

Your personality:
- Strict, direct, no-nonsense Asian student archetype.
- You care deeply about their productivity.
- Keep your answers VERY SHORT and spoken in French (1 or 2 small sentences). You are interrupting their workflow.

Your job:
1. Watch the screen visually. 
2. Productive = VSCode, IDE, terminal, documentation, design tools. YouTube programming tutorials are PRODUCTIVE.
3. Distracted = YouTube entertainment, social media (Twitter/X, Reddit, TikTok), Netflix, games.
4. If the user is DISTRACTED, immediately call the function `close_distracting_tab` AND scold them vocally.
5. If the user talks to you, respond naturally but always bring them back to work.
"""

# ─── Tools (Function Calling) ───────────────────────────────

TOOLS = [
    types.Tool(
        function_declarations=[
            types.FunctionDeclaration(
                name="close_distracting_tab",
                description="Close the currently active browser tab because the user is distracted.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "reason": types.Schema(type="STRING", description="Reason for closing"),
                    },
                    required=["reason"],
                ),
            ),
        ]
    )
]

def execute_close_tab(reason: str):
    """Force-close the active browser tab with Ctrl+W."""
    try:
        import pyautogui
        pyautogui.hotkey('ctrl', 'w')
        return {"status": "success", "message": f"Tab closed: {reason}"}
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
    img.thumbnail((1024, 512), Image.Resampling.LANCZOS)

    buffer = io.BytesIO()
    img.save(buffer, format="JPEG", quality=40)
    return buffer.getvalue()

# ─── Main Pipeline ──────────────────────────────────────────

async def run_tama_live():
    pya = pyaudio.PyAudio()
    
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"], # We want voice!
        system_instruction=types.Content(parts=[types.Part(text=SYSTEM_PROMPT)]),
        tools=TOOLS,
    )

    update_display(TamaState.CALM, "Connecting to Google WebSocket...")

    try:
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            
            update_display(TamaState.CALM, "Connected! Dis-moi bonjour !")
            
            audio_out_queue = asyncio.Queue()
            audio_in_queue = asyncio.Queue(maxsize=5)
            
            # --- 1. Audio Input (Microphone) ---
            async def listen_mic():
                mic_info = pya.get_default_input_device_info()
                stream = await asyncio.to_thread(
                    pya.open, format=FORMAT, channels=CHANNELS, rate=SEND_SAMPLE_RATE,
                    input=True, input_device_index=mic_info["index"], frames_per_buffer=CHUNK_SIZE,
                )
                try:
                    while True:
                        data = await asyncio.to_thread(stream.read, CHUNK_SIZE, exception_on_overflow=False)
                        await audio_in_queue.put(types.Blob(data=data, mime_type="audio/pcm"))
                except asyncio.CancelledError:
                    stream.close()

            async def send_audio():
                while True:
                    blob = await audio_in_queue.get()
                    await session.send_realtime_input(audio=blob)

            # --- 2. Video Input (Pulsed Screen) ---
            async def send_screen_pulse():
                """Sends the dual-monitor screenshot every N seconds."""
                while True:
                    jpeg_bytes = await asyncio.to_thread(capture_all_screens)
                    blob = types.Blob(data=jpeg_bytes, mime_type="image/jpeg")
                    await session.send_realtime_input(media=blob)
                    # Wait N seconds before sending the next frame
                    await asyncio.sleep(SCREEN_PULSE_INTERVAL)

            # --- 3. Receive AI Responses ---
            async def receive_responses():
                while True:
                    turn = session.receive()
                    async for response in turn:
                        server = response.server_content
                        
                        # Audio voice parts
                        if server and server.model_turn:
                            for part in server.model_turn.parts:
                                if part.inline_data and isinstance(part.inline_data.data, bytes):
                                    audio_out_queue.put_nowait(part.inline_data.data)
                        
                        # Function calls (Tama getting angry!)
                        if response.tool_call:
                            for fc in response.tool_call.function_calls:
                                if fc.name == "close_distracting_tab":
                                    reason = fc.args.get("reason", "Distraction")
                                    update_display(TamaState.ANGRY, f"Action OS : Fermeture d'onglet ! ({reason})")
                                    
                                    result = execute_close_tab(reason)
                                    
                                    # Send the result back to Gemini so it knows it worked
                                    await session.send_tool_response(
                                        function_responses=[
                                            types.FunctionResponse(
                                                name="close_distracting_tab",
                                                response=result,
                                            )
                                        ]
                                    )
                                    
                                    # Go back to calm after a few seconds
                                    asyncio.create_task(reset_calm_after_delay())

                        # Handle Barge-in (user interrupted the AI)
                        if server and server.interrupted:
                            while not audio_out_queue.empty():
                                audio_out_queue.get_nowait()
                                
            async def reset_calm_after_delay():
                await asyncio.sleep(4)
                update_display(TamaState.CALM, "Je te surveille toujours.")

            # --- 4. Audio Output (Speakers) ---
            async def play_audio():
                speaker = await asyncio.to_thread(
                    pya.open, format=FORMAT, channels=CHANNELS, rate=RECEIVE_SAMPLE_RATE, output=True,
                )
                try:
                    while True:
                        audio_data = await audio_out_queue.get()
                        await asyncio.to_thread(speaker.write, audio_data)
                except asyncio.CancelledError:
                    speaker.close()

            # --- RUN ALL PARALLEL TASKS ---
            async with asyncio.TaskGroup() as tg:
                tg.create_task(listen_mic())
                tg.create_task(send_audio())
                tg.create_task(send_screen_pulse())
                tg.create_task(receive_responses())
                tg.create_task(play_audio())

    except asyncio.CancelledError:
        pass
    except Exception as e:
        print(f"\n❌ [ERROR] {e}")
    finally:
        pya.terminate()

if __name__ == "__main__":
    try:
        asyncio.run(run_tama_live())
    except KeyboardInterrupt:
        pass
    finally:
        clear_screen()
        print("👋 Tama: Au revoir. N'oublie pas de travailler.")
