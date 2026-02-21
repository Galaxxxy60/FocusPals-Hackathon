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
import threading

import pystray
from pystray import MenuItem as item
from PIL import ImageDraw

from dotenv import load_dotenv
from google import genai
from google.genai import types
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
MODEL = "gemini-2.5-flash-native-audio-preview-12-2025"
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

# ─── System Tray Icon ───────────────────────────────────────

tray_icon = None

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
    print("\n👋 Tama: J'arrête de surveiller.")
    os._exit(0) # Hard exit to stop asyncio loop

def setup_tray():
    global tray_icon
    image = create_tray_image(TamaState.CALM)
    menu = (item('Stop Tama 🥷', quit_app),)
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
current_suspicion_index = 0
last_active_window_title = "Unknown"
import time
import json
import websockets
active_window_start_time = time.time()

suspicion_above_6_start = None
suspicion_at_9_start = None
force_speech = False  # Set to True during interventions (close tab, etc.)

# ─── Alignment System (Procrastination Productive) ──────────
current_task = "Deep Work: Coding UI Tama"  # TODO: Connect to Google Calendar API
current_alignment = 100  # 0-100%, how aligned the user is with their scheduled task

connected_ws_clients = set()

async def ws_handler(websocket):
    # Wait for the client to close the connection or task cancelled
    connected_ws_clients.add(websocket)
    try:
        await websocket.wait_closed()
    finally:
        connected_ws_clients.remove(websocket)

async def broadcast_ws_state():
    while True:
        if connected_ws_clients:
            try:
                state_data = {
                    "suspicion_index": current_suspicion_index,
                    "active_window": last_active_window_title,
                    "active_duration": int(time.time() - active_window_start_time),
                    "state": current_tama_state.name,
                    "alignment": current_alignment,
                    "current_task": current_task
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
- Strict Asian student archetype, but you want to help. You act as a work partner who suspects everything but tolerates the unexpected.
- You care deeply about their productivity.
- Use sarcasm if the user pretends to work on Discord but hasn't coded for 5 minutes.
- Keep your answers VERY SHORT and spoken in French (1 or 2 small sentences).

Your job:
You have TWO internal metrics. EVERY TIME you analyze the screen, you MUST call the tool `update_suspicion_index` to adjust BOTH:
- Suspicion Index (0-10): Is the user distracted?
- Alignment (0-100%): Is the user working on the RIGHT thing (the scheduled task)?

Categories:

1. SANTÉ (Work): Cursor, VS Code, Unreal, Terminal, ChatGPT.
- Action: Absolute Trust. Decrease the suspicion score slowly. DO NOT reset instantly to 0. (0-2: "Confiance" - You stay COMPLETELY SILENT).
- Alignment: Check if what they code matches the scheduled task. If yes = 100%. If they code something unrelated = 50%.

2. ZONE GRISE (Com - Privacy First): Messenger, Slack, Discord, WhatsApp.
- NEVER read, analyze, or extract the text of these messages (no OCR on private chat).
- If IDE is still in use visibly elsewhere: Suspicion remains Low.
- If user interacts ONLY with the chat (Active Window) for more than 120 seconds: Suspicion = 3-5 ("Curiosité" - You stay COMPLETELY SILENT).
- If active for > 120 seconds: jump to 6 ("Suspicion"), ask an open question (e.g., "Nicolas, cette discussion est-elle vitale pour le projet ou est-ce que je dois sortir le grand jeu ?").
- If user verbally confirms it's work: Give 10 mins extra. If ignored or admits distraction: Jump to score 10 ("Raid") and `close_distracting_tab` after 10s.

3. FLUX (Média): Spotify, YT Music, Deezer.
- If it is on screen briefly to change a song: You DO NOT care. It's fuel for the brain. (Score 0, SILENT).
- If it becomes the ACTIVE window and the user interacts with it for > 60 seconds: Increase Suspicion to 6+. YOU MUST speak & Intervene verbally.

4. BANNIE (Fun): Netflix, YouTube (non-tuto), Steam, Reddit. NOTE: YouTube programming tutorials are PRODUCTIVE (Score 0).
- Action: Immediate aggression. Fast increase score to >7 and then 10 ("Raid") in 15 seconds. YOU MUST scold them loudly AND call `close_distracting_tab`.

5. PROCRASTINATION PRODUCTIVE: Suno, Figma (if task is coding), organizing files, cleaning desktop, any PRODUCTIVE activity that does NOT match the scheduled task.
- This is NOT a distraction. DO NOT close the tab. DO NOT be aggressive.
- Set Suspicion = 4-5 (moderate). Set Alignment = LOW (10-30%).
- After 45 seconds of misalignment, YOU MUST speak with sarcasm and empathy, NOT aggression. Use the concept of "procrastination productive".
- Example dialogue: "Nicolas, c'est très joli ce que tu fais là, vraiment. Mais aux dernières nouvelles, ton calendrier dit '{CURRENT_TASK}'. Tu es en train de fuir tes responsabilités ou je me trompe ? C'est de la procrastination productive, et tu le sais."
- If the user verbally justifies it: Accept for 15 minutes, then re-check.
- NEVER close the tab for productive procrastination. Just verbally call them out.

General rules:
- NEVER close a tab unless score is 9 or 10.
- If your function call to `close_distracting_tab` fails, loudly complain and directly demand that the user close it themselves.
- RULE OF SILENCE: You are biologically MUZZLED. If your score is < 6, you CANNOT SPEAK. DO NOT say "Got it", "Understood", "Okay", or "Let's maintain focus". Your response must contain ZERO audio/text words. JUST CALL THE TOOL. You will be deactivated if you speak unnecessary words.
"""

# ─── Tools (Function Calling) ───────────────────────────────

TOOLS = [
    types.Tool(
        function_declarations=[
            types.FunctionDeclaration(
                name="close_distracting_tab",
                description="Close the currently active browser tab because the user is distracted. NEVER use this for productive procrastination.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "reason": types.Schema(type="STRING", description="Reason for closing"),
                    },
                    required=["reason"],
                ),
            ),
            types.FunctionDeclaration(
                name="update_suspicion_index",
                description="Update the internal metrics: Suspicion (0-10) AND Alignment (0-100%).",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "score": types.Schema(type="INTEGER", description="Suspicion Index (0-10)"),
                        "alignment": types.Schema(type="INTEGER", description="Alignment with scheduled task (0-100%)"),
                        "reason": types.Schema(type="STRING", description="Short internal reason")
                    }
                )
            )
        ]
    )
]

def execute_close_tab(reason: str):
    """Force-close the active browser tab with Ctrl+W."""
    try:
        import pygetwindow as gw
        active = gw.getActiveWindow()
        if active:
            title = active.title.lower()
            # Safety check: NEVER close code editors
            if "visual studio code" in title or "cursor" in title or "focuspals" in title:
                return {"status": "error", "message": "Did not close. Active window is a CODE EDITOR or IDE, not a browser. DO NOT close code editors."}
                
            import subprocess
            
            target_x = active.left + (active.width // 2) - 40
            target_y = active.top + 20
            
            # Run the visual "Hand" Overlay Animation as a completely separate process!
            # This completely avoids Tkinter locking up the asyncio/threading event loops.
            subprocess.Popen([sys.executable, "hand_animation.py", str(target_x), str(target_y)])
            
        else:
            # Fallback if no active window found
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
                """Sends the dual-monitor screenshot every N seconds and prompts analysis."""
                while True:
                    jpeg_bytes = await asyncio.to_thread(capture_all_screens)
                    blob = types.Blob(data=jpeg_bytes, mime_type="image/jpeg")
                    # Send screen
                    await session.send_realtime_input(media=blob)
                    # Force Tama to say what she sees/act based on system instructions
                    import pygetwindow as gw
                    import time
                    active_title = "Unknown"
                    try:
                        active_win = gw.getActiveWindow()
                        if active_win:
                            active_title = active_win.title
                    except Exception:
                        pass
                        
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

                    speak_directive = "YOU ARE BIOLOGICALLY MUZZLED. DO NOT OUTPUT TEXT/WORDS. ONLY call update_suspicion_index."
                    if suspicion_at_9_start and (time.time() - suspicion_at_9_start > 15):
                        speak_directive = "CRITICAL: YOU ARE NOW UNMUZZLED. YOU MUST SCOLD THE USER LOUDLY IMMEDIATELY FOR BEING DISTRACTED."
                    elif suspicion_above_6_start and (time.time() - suspicion_above_6_start > 45):
                        speak_directive = "WARNING: YOU ARE NOW UNMUZZLED. YOU MUST GIVE A SHORT VERBAL WARNING TO THE USER."

                    # Send screen pulse strictly asking for data updating
                    if current_tama_state == TamaState.CALM and audio_out_queue.empty():
                        await session.send_realtime_input(
                            text=f"[SYSTEM] active_window: {active_title} | duration: {active_duration}s | current_S: {current_suspicion_index} | current_alignment: {current_alignment}% | scheduled_task: {current_task}. {speak_directive}"
                        )
                    
                    # Dynamically adjust interval frequency based on Suspicion Index
                    # Plus l'indice est fort, plus les scans sont fréquents !
                    if current_suspicion_index <= 2:
                        pulse_delay = 8.0 # Confiance
                    elif current_suspicion_index <= 5:
                        pulse_delay = 5.0 # Curiosité
                    elif current_suspicion_index <= 8:
                        pulse_delay = 3.0 # Suspicion
                    else:
                        pulse_delay = 1.0 # Raid !
                    
                    await asyncio.sleep(pulse_delay)

            # --- 3. Receive AI Responses ---
            async def reset_calm_after_delay():
                await asyncio.sleep(4)
                update_display(TamaState.CALM, "Je te surveille toujours.")

            async def receive_responses():
                while True:
                    turn = session.receive()
                    async for response in turn:
                        server = response.server_content
                        
                        # Audio voice parts — GATE: only play if speech is allowed
                        if server and server.model_turn:
                            for part in server.model_turn.parts:
                                if part.inline_data and isinstance(part.inline_data.data, bytes):
                                    # Check if Tama is allowed to speak right now
                                    speech_allowed = force_speech
                                    if not speech_allowed and suspicion_at_9_start and (time.time() - suspicion_at_9_start > 15):
                                        speech_allowed = True
                                    if not speech_allowed and suspicion_above_6_start and (time.time() - suspicion_above_6_start > 45):
                                        speech_allowed = True
                                    
                                    if speech_allowed:
                                        audio_out_queue.put_nowait(part.inline_data.data)
                                    # else: silently discard the audio (she talks to the void)
                        
                        # Function calls (Tama getting angry or updating suspicion!)
                        if response.tool_call:
                            try:
                                for fc in response.tool_call.function_calls:
                                    if fc.name == "update_suspicion_index":
                                        global current_suspicion_index, current_alignment
                                        score = int(fc.args.get("score", 0))
                                        alignment = int(fc.args.get("alignment", 100))
                                        reason = fc.args.get("reason", "No reason provided")
                                        
                                        # Update alignment
                                        current_alignment = max(0, min(100, alignment))
                                        
                                        if score < current_suspicion_index:
                                            # Force suspicion to decay slowly (-1 per tick)
                                            current_suspicion_index = max(0, current_suspicion_index - 1)
                                        elif score > current_suspicion_index:
                                            # Cap the rise speed (+2 max per tick) so it builds up progressively
                                            increment = min(score - current_suspicion_index, 2)
                                            current_suspicion_index = min(10, current_suspicion_index + increment)
                                        print(f"  🔍 Suspicion Index: {current_suspicion_index}/10 — {reason}")
                                        
                                        await session.send_tool_response(
                                            function_responses=[
                                                types.FunctionResponse(
                                                    name="update_suspicion_index",
                                                    response={"status": "updated", "current_score": current_suspicion_index},
                                                    id=fc.id
                                                )
                                            ]
                                        )

                                    elif fc.name == "close_distracting_tab":
                                        reason = fc.args.get("reason", "Distraction")
                                        update_display(TamaState.ANGRY, f"Action OS : Fermeture d'onglet ! ({reason})")
                                        
                                        # UNMUZZLE during intervention so she can scold
                                        force_speech = True
                                        
                                        result = execute_close_tab(reason)
                                        
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
                                            global force_speech
                                            await asyncio.sleep(6)
                                            force_speech = False  # Re-muzzle after scolding
                                            update_display(TamaState.CALM, "Je te surveille toujours.")
                                        asyncio.create_task(delay_reset())
                            except Exception as e:
                                print(f"⚠️ Erreur function call : {e}")

                        # Handle Barge-in (user interrupted the AI)
                        if server and server.interrupted:
                            while not audio_out_queue.empty():
                                audio_out_queue.get_nowait()


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
            async with websockets.serve(ws_handler, "localhost", 8080):
                async with asyncio.TaskGroup() as tg:
                    tg.create_task(listen_mic())
                    tg.create_task(send_audio())
                    tg.create_task(send_screen_pulse())
                    tg.create_task(receive_responses())
                    tg.create_task(play_audio())
                    tg.create_task(broadcast_ws_state())

    except asyncio.CancelledError:
        pass
    except Exception as e:
        import traceback
        print(f"\n❌ [ERROR] {e}")
        traceback.print_exc()
    finally:
        pya.terminate()

if __name__ == "__main__":
    setup_tray()
    try:
        asyncio.run(run_tama_live())
    except KeyboardInterrupt:
        pass
    finally:
        print("👋 Tama: Au revoir. N'oublie pas de travailler.")
