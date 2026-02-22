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

from dotenv import load_dotenv

# Resolves the absolute path of this file (handles both .py and .exe cases)
if getattr(sys, 'frozen', False):
    application_path = sys._MEIPASS
else:
    application_path = os.path.dirname(os.path.abspath(__file__))

env_path = os.path.join(application_path, '.env')
load_dotenv(env_path)

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
current_suspicion_index = 0.0  # Float for granular ΔS
last_active_window_title = "Unknown"
import time
import json
import websockets
active_window_start_time = time.time()

suspicion_above_6_start = None
suspicion_at_9_start = None
force_speech = False

# ─── A.S.C. (Alignment Suspicion Control) ────────────────────
current_task = None  # Set dynamically by Tama via voice
current_alignment = 1.0  # 1.0 (aligned), 0.5 (doubt), 0.0 (misaligned)
current_category = "SANTE"  # SANTE, ZONE_GRISE, FLUX, BANNIE, PROCRASTINATION_PRODUCTIVE
can_be_closed = True  # Protection: False for IDEs, document editors

# Protected windows that should NEVER be closed
PROTECTED_WINDOWS = ["code", "cursor", "visual studio", "unreal", "blender", "word", "excel",
                     "figma", "photoshop", "premiere", "davinci", "ableton", "fl studio",
                     "suno", "notion", "obsidian", "terminal", "powershell"]

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
                    "suspicion_index": round(current_suspicion_index, 1),
                    "active_window": last_active_window_title,
                    "active_duration": int(time.time() - active_window_start_time),
                    "state": current_tama_state.name,
                    "alignment": current_alignment,
                    "current_task": current_task or "Non définie",
                    "category": current_category,
                    "can_be_closed": can_be_closed
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
When you first connect, ask the user IN FRENCH what they are working on today. Example: "Salut Nicolas ! Sur quoi tu bosses aujourd'hui ?"
When they answer, call `set_current_task` with their answer. This sets the Alignment reference.
If they say "musique" or "Suno", then Suno AND Spotify AND music apps become 100% aligned.
If they say "coding", then VS Code/Cursor/Terminal is 100% aligned.

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

Alignment depends on the current_task:
- If current_task = "musique" and user is on Spotify/Suno → alignment = 1.0
- If current_task = "musique" and user is on VS Code → alignment = 0.0 (procrastination productive!)
- If current_task = "coding" and user is on VS Code → alignment = 1.0
- If current_task = "coding" and user is on Suno → alignment = 0.0 (procrastination productive!)
- If current_task = "game design" and user is watching a gameplay video on YouTube → alignment = 1.0, and category is STILL BANNIE. (This triggers "Glissement" mechanics).

FREE SESSION MODE (If current_task is NOT SET):
- Any SANTE app → alignment = 1.0 (Zero suspicion, you assume they are working).
- Any FLUX or ZONE_GRISE app → alignment = 0.5 (You observe silently, no rush).
- Any BANNIE app → alignment = 0.0 (Pure distraction).

CRITICAL ACTIONS:
- If you receive `S: 10.0` AND `can_be_closed: True`, YOU MUST loudly yell at the user AND call `close_distracting_tab` immediately!
- If you receive `S: 10.0` AND `can_be_closed: False`, YOU MUST loudly harass the user to go back to work, but DO NOT call `close_distracting_tab`.

RULE OF SILENCE: You are MUZZLED by default. DO NOT speak, DO NOT say "Got it", "Understood". Just call `classify_screen`. Speech is allowed only when explicitly unmuzzled in the [SYSTEM] prompt.
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
                    },
                    required=["reason"],
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
            
            # Allow speech at session start so Tama can ask the task question
            global force_speech
            force_speech = True
            
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

                    if force_speech:
                        speak_directive = "UNMUZZLED: You MUST speak now to address the user!"
                    else:
                        speak_directive = "YOU ARE BIOLOGICALLY MUZZLED. DO NOT OUTPUT TEXT/WORDS. ONLY call classify_screen."
                        if suspicion_at_9_start and (time.time() - suspicion_at_9_start > 15):
                            speak_directive = "CRITICAL: YOU ARE NOW UNMUZZLED. YOU MUST SCOLD THE USER LOUDLY IMMEDIATELY FOR BEING DISTRACTED."
                        elif suspicion_above_6_start and (time.time() - suspicion_above_6_start > 45):
                            speak_directive = "WARNING: YOU ARE NOW UNMUZZLED. YOU MUST GIVE A SHORT VERBAL WARNING TO THE USER."

                    # Send screen pulse
                    task_info = f"scheduled_task: {current_task}" if current_task else "scheduled_task: NOT SET (ask the user!)"
                    if current_tama_state == TamaState.CALM and audio_out_queue.empty():
                        await session.send_realtime_input(
                            text=f"[SYSTEM] active_window: {active_title} | duration: {active_duration}s | S: {current_suspicion_index:.1f} | A: {current_alignment} | {task_info} | can_be_closed: {can_be_closed}. Call classify_screen. {speak_directive}"
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
                global force_speech, current_suspicion_index, current_alignment, current_category, can_be_closed, current_task
                while True:
                    try:
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
                                            can_be_closed = compute_can_be_closed(last_active_window_title)
                                            
                                            # Compute ΔS deterministically
                                            delta = compute_delta_s(ali, cat)
                                            current_suspicion_index = max(0.0, min(10.0, current_suspicion_index + delta))
                                            
                                            s_int = int(current_suspicion_index)
                                            print(f"  🔍 S:{s_int}/10 | A:{ali} | Cat:{cat} | ΔS:{delta:+.1f} — {reason}")
                                            
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
                        # Catch Google API intermittent errors (e.g. 1011) and try to continue
                        print(f"\n⚠️  [WARN] Live API Sync lost during receive: {e}. Recovering...")
                        await asyncio.sleep(1)


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
