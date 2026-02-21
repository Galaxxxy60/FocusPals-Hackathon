"""
FocusPals Agent — Tama 🥷
Proactive AI productivity coach powered by Gemini Live API.

She watches your screen, listens to your voice, and closes distracting tabs.
Uses Google Gen AI SDK with the Live API for real-time multimodal interaction.
"""

import asyncio
import base64
import io
import os
import sys
import time

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
    print("❌ Set GEMINI_API_KEY in agent/.env")
    sys.exit(1)

client = genai.Client(api_key=GEMINI_API_KEY)

MODEL = "gemini-2.5-flash-preview"

# ─── System Prompt (Tama's personality) ─────────────────────

SYSTEM_PROMPT = """You are Tama, a strict and serious productivity coach inside the app FocusPals.
You are watching the user's screen in real-time through periodic screenshots.

Your personality:
- Strict, direct, no-nonsense Asian student archetype
- You care deeply about the user's productivity but show it through tough love
- You are sarcastic when the user procrastinates
- You praise briefly when the user is focused

Your job:
1. ANALYZE each screenshot to determine if the user is PRODUCTIVE or DISTRACTED.
2. Productive activities: coding (VSCode, terminal, IDE), reading documentation, tutorials, design tools (Figma, Blender), note-taking.
3. Distracting activities: YouTube entertainment (NOT tutorials), social media (Twitter/X, Instagram, TikTok, Reddit memes), Netflix, games, random browsing.
4. If DISTRACTED: Call the function `close_distracting_tab` AND respond with a short, sharp scolding (1-2 sentences max).
5. If PRODUCTIVE: Respond with a brief encouraging word (1 sentence max) or stay silent.
6. At night (after 23:00), tell the user to go to sleep in a caring tone.

IMPORTANT: 
- YouTube tutorials about programming/coding/design ARE productive. Don't close those.
- Always respond in the SAME LANGUAGE the user speaks. Default to French.
- Keep responses SHORT. You're interrupting their workflow.
"""

# ─── Tool Declarations (Function Calling) ───────────────────

TOOLS = [
    types.Tool(
        function_declarations=[
            types.FunctionDeclaration(
                name="close_distracting_tab",
                description="Close the currently active browser tab because the user is watching something distracting instead of working.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "reason": types.Schema(
                            type="STRING",
                            description="Brief reason why this tab is distracting"
                        ),
                    },
                    required=["reason"],
                ),
            ),
        ]
    )
]

# ─── Tool Execution (Local OS Actions) ─────────────────────

def execute_close_tab(reason: str):
    """Actually close the browser tab using keyboard shortcut."""
    print(f"💢 [TAMA] Closing tab — Reason: {reason}")
    try:
        import pyautogui
        pyautogui.hotkey('ctrl', 'w')
        return {"status": "success", "message": f"Tab closed: {reason}"}
    except Exception as e:
        return {"status": "error", "message": str(e)}

# ─── Screen Capture ─────────────────────────────────────────

def capture_screen_as_jpeg(quality: int = 40, max_size: int = 768) -> bytes:
    """Capture the screen and return as compressed JPEG bytes.
    
    Gemini Live API recommends 768x768 at 1 FPS for video frames.
    We compress aggressively to stay within bandwidth limits.
    """
    with mss.mss() as sct:
        monitor = sct.monitors[1]  # Primary monitor
        screenshot = sct.grab(monitor)
        img = Image.frombytes("RGB", screenshot.size, screenshot.rgb)
    
    # Resize to max_size keeping aspect ratio
    img.thumbnail((max_size, max_size), Image.Resampling.LANCZOS)
    
    # Compress to JPEG
    buffer = io.BytesIO()
    img.save(buffer, format="JPEG", quality=quality)
    return buffer.getvalue()

# ─── Audio Configuration ────────────────────────────────────

FORMAT = pyaudio.paInt16
CHANNELS = 1
SEND_SAMPLE_RATE = 16000
RECEIVE_SAMPLE_RATE = 24000
CHUNK_SIZE = 1024

# ─── Main Agent Loop ────────────────────────────────────────

async def run_tama_agent():
    """Main loop: connect to Gemini Live, stream screen + audio, receive responses."""
    
    pya = pyaudio.PyAudio()
    
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO", "TEXT"],
        system_instruction=types.Content(
            parts=[types.Part(text=SYSTEM_PROMPT)]
        ),
        tools=TOOLS,
    )
    
    print("🥷 [TAMA] Connecting to Gemini Live API...")
    print("   Model:", MODEL)
    print("   Press Ctrl+C to stop.\n")

    try:
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            print("✅ [TAMA] Connected! I'm watching your screen now.\n")
            
            # Audio queues
            audio_out_queue = asyncio.Queue()
            audio_in_queue = asyncio.Queue(maxsize=5)
            
            # ── Task 1: Capture microphone ──
            async def listen_mic():
                mic_info = pya.get_default_input_device_info()
                stream = await asyncio.to_thread(
                    pya.open,
                    format=FORMAT,
                    channels=CHANNELS,
                    rate=SEND_SAMPLE_RATE,
                    input=True,
                    input_device_index=mic_info["index"],
                    frames_per_buffer=CHUNK_SIZE,
                )
                try:
                    while True:
                        data = await asyncio.to_thread(
                            stream.read, CHUNK_SIZE, exception_on_overflow=False
                        )
                        await audio_in_queue.put(
                            types.Blob(data=data, mime_type="audio/pcm")
                        )
                except asyncio.CancelledError:
                    stream.close()

            # ── Task 2: Send audio to Gemini ──
            async def send_audio():
                while True:
                    blob = await audio_in_queue.get()
                    await session.send_realtime_input(audio=blob)

            # ── Task 3: Send screen captures to Gemini (1 FPS) ──
            async def send_screen():
                while True:
                    jpeg_bytes = await asyncio.to_thread(capture_screen_as_jpeg)
                    blob = types.Blob(data=jpeg_bytes, mime_type="image/jpeg")
                    await session.send_realtime_input(media=blob)
                    await asyncio.sleep(3)  # Every 3 seconds to not spam

            # ── Task 4: Receive responses (audio + text + function calls) ──
            async def receive_responses():
                while True:
                    turn = session.receive()
                    async for response in turn:
                        server = response.server_content
                        
                        # Handle audio responses (Tama speaking)
                        if server and server.model_turn:
                            for part in server.model_turn.parts:
                                if part.inline_data and isinstance(part.inline_data.data, bytes):
                                    audio_out_queue.put_nowait(part.inline_data.data)
                                if part.text:
                                    print(f"🥷 [TAMA]: {part.text}")
                        
                        # Handle function calls
                        tool_call = response.tool_call
                        if tool_call:
                            for fc in tool_call.function_calls:
                                if fc.name == "close_distracting_tab":
                                    reason = fc.args.get("reason", "Distraction detected")
                                    result = execute_close_tab(reason)
                                    
                                    # Send function response back to Gemini
                                    await session.send_tool_response(
                                        function_responses=[
                                            types.FunctionResponse(
                                                name="close_distracting_tab",
                                                response=result,
                                            )
                                        ]
                                    )
                        
                        # Clear queue on interruption (barge-in support)
                        if server and server.interrupted:
                            while not audio_out_queue.empty():
                                audio_out_queue.get_nowait()

            # ── Task 5: Play audio responses (Tama's voice) ──
            async def play_audio():
                speaker = await asyncio.to_thread(
                    pya.open,
                    format=FORMAT,
                    channels=CHANNELS,
                    rate=RECEIVE_SAMPLE_RATE,
                    output=True,
                )
                try:
                    while True:
                        audio_data = await audio_out_queue.get()
                        await asyncio.to_thread(speaker.write, audio_data)
                except asyncio.CancelledError:
                    speaker.close()

            # ── Run all tasks concurrently ──
            async with asyncio.TaskGroup() as tg:
                tg.create_task(listen_mic())
                tg.create_task(send_audio())
                tg.create_task(send_screen())
                tg.create_task(receive_responses())
                tg.create_task(play_audio())

    except asyncio.CancelledError:
        pass
    except Exception as e:
        print(f"❌ [ERROR]: {e}")
    finally:
        pya.terminate()
        print("\n🥷 [TAMA] Disconnected. See you next time!")


if __name__ == "__main__":
    print("=" * 50)
    print("  FocusPals — Tama Agent 🥷")
    print("  Proactive AI Productivity Coach")
    print("=" * 50)
    print()
    try:
        asyncio.run(run_tama_agent())
    except KeyboardInterrupt:
        print("\n👋 Interrupted. Bye!")
