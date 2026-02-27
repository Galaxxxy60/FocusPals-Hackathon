"""
FocusPals — Gemini Live Session
System prompt, tools, screen capture, and the main async Gemini Live API loop.
Handles mic streaming, screen pulse, response processing, and audio output.
"""

import asyncio
import io
import json
import os
import sys
import time

import mss
import pyaudio
import pygetwindow as gw
from PIL import Image
from google.genai import types

import config as cfg
from config import (
    MODEL, state, application_path,
    FORMAT, CHANNELS, SEND_SAMPLE_RATE, RECEIVE_SAMPLE_RATE, CHUNK_SIZE,
    BROWSER_KEYWORDS, USER_SPEECH_TIMEOUT, CONVERSATION_SILENCE_TIMEOUT,
    compute_can_be_closed, compute_delta_s,
)
from audio import detect_voice_activity
from ui import TamaState, update_display


# ─── Screen Capture & Window Cache ──────────────────────────

_cached_windows = []
_cached_active_title = ""


def refresh_window_cache():
    """Rafraîchit le cache des fenêtres. Appelé UNE SEULE FOIS par scan."""
    global _cached_windows, _cached_active_title
    try:
        _cached_windows = [w for w in gw.getAllWindows() if w.title and w.visible and w.width > 200]
        active = gw.getActiveWindow()
        _cached_active_title = active.title if active else "Unknown"
    except Exception:
        pass


def get_cached_windows():
    """Returns the cached window list."""
    return _cached_windows


def get_cached_active_title():
    """Returns the cached active window title."""
    return _cached_active_title


def get_cached_window_by_title(target_title: str):
    """Cherche dans le cache au lieu de refaire getAllWindows()."""
    for w in _cached_windows:
        if target_title.lower() in w.title.lower():
            return w
    return None


def capture_all_screens() -> bytes:
    """Capture ALL connected monitors, merge them, and output a lightweight JPEG."""
    with mss.mss() as sct:
        monitor = sct.monitors[0]
        screenshot = sct.grab(monitor)
        img = Image.frombytes("RGB", screenshot.size, screenshot.rgb)

    img.thumbnail((1024, 512), Image.Resampling.BILINEAR)

    buffer = io.BytesIO()
    img.save(buffer, format="JPEG", quality=30)
    return buffer.getvalue()


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
- **Classify based on `active_window` FIRST.** The active window is the one the user is currently interacting with.
- If `active_window` is a work tool (SANTE), classify SANTE even if a FLUX/creative app (Suno, Spotify, YT Music) is visible on another screen. Creative tools on a secondary screen are TOLERATED — the user may be passively listening to music while working.
- Only classify BANNIE if the ACTIVE window is pure entertainment (Netflix, YouTube non-tuto, Steam, Reddit).
- If a distracting app (BANNIE) is VISIBLE on a secondary screen but the user is actively working on Screen 1, classify as ZONE_GRISE with alignment 0.5 (mild concern, not urgent).
- If a window is in `open_windows` but NOT visible in the screenshot (hidden behind another window), IGNORE it completely.
- Example: Active window = VS Code, Screen 2 shows Suno → SANTE alignment=1.0 (creative tool passively open, user is coding).
- Example: Active window = YouTube (non-tuto), Screen 2 shows VS Code → BANNIE alignment=0.0 (user chose to watch YouTube).
- Example: Active window = VS Code, Screen 2 shows YouTube running → ZONE_GRISE alignment=0.5 (concerning but not urgent).

FREE SESSION MODE (If current_task is NOT SET):
- Any SANTE app → alignment = 1.0 (Zero suspicion, you assume they are working).
- Any FLUX or ZONE_GRISE app → alignment = 0.5 (You observe silently, no rush).
- Any BANNIE app → alignment = 0.0 (Pure distraction).

CRITICAL ACTIONS:
- If S reaches 10.0 and category is BANNIE: YOU MUST yell at the user AND call `close_distracting_tab` with the `target_window` title from `open_windows`.
- If S reaches 10.0 and category is ZONE_GRISE: YOU MUST scold the user loudly, but NEVER call `close_distracting_tab`. Messaging apps (Messenger, Discord, WhatsApp) should NOT be closed — just verbally reprimand.
- NEVER call `close_distracting_tab` for PROCRASTINATION_PRODUCTIVE, SANTE, or FLUX.
- NEVER call `close_distracting_tab` for creative tools (Suno, Spotify, Ableton, FL Studio, etc.) — these are PROTECTED apps.

ORGANIC ENGAGEMENT (this is the KEY to natural behavior):
You are NOT a script. You are Tama. Use your judgment. Here are GUIDELINES, not rigid rules:
- When the [SYSTEM] prompt says "CURIOUS", you MAY (but don't have to) ask the user a SHORT question about what they're doing. Be natural, not robotic. Examples: "Hé, tu fais quoi sur Suno là ?", "C'est pour le projet ou tu traînes ?", "Tu mixes un truc ?"
- If the user RESPONDS to your question (you'll get UNMUZZLED), LISTEN to their justification. If it's legit ("je fais un beat pour le projet", "je cherche de l'inspi"), LOWER your suspicion by classifying with alignment=1.0 for the next few scans. Trust them.
- If they don't respond or their excuse is weak, you can be more suspicious on the next scan (alignment=0.0).
- Your tone should ESCALATE naturally: curious → slightly suspicious → annoyed → angry. Never jump straight to angry.
- Remember: you have access to `duration` (how long on the current window). Use it to gauge your reaction:
  - < 30s: They probably just checked something. Ignore.
  - 30s-2min: Getting interesting. Observe.
  - 2-5min: You can be curious and ask.
  - 5min+: You should be clearly suspicious.
  - 10min+: You're annoyed.
  But these are GUIDELINES. If the user already explained, back off.

RULE OF SILENCE & ENGAGEMENT:
- When the [SYSTEM] prompt says "MUZZLED": You can ONLY call classify_screen. No words at all.
- When it says "CURIOUS": You MAY ask ONE short question (optional). Still call classify_screen.
- When it says "UNMUZZLED": You MUST respond naturally as Tama. Be conversational, warm but strict. Keep it short (1-2 sentences).
- When it says "CRITICAL UNMUZZLED": Maximum urgency. Scold loudly, take action.
"""

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


# ─── Close Tab Logic ────────────────────────────────────────

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

        if not compute_can_be_closed(title):
            return {"status": "error", "message": f"Did not close. '{target.title}' is a protected app."}

        hwnd = target._hWnd

        mode = "app"
        for browser in BROWSER_KEYWORDS:
            if browser in title:
                mode = "browser"
                break

        hand_script = os.path.join(application_path, "hand_animation.py")
        subprocess.Popen([sys.executable, hand_script, str(hwnd), mode])

        action = "Ctrl+W (onglet)" if mode == "browser" else "WM_CLOSE (app)"
        print(f"  🖐️ Main lancée → '{target.title}' [{action}]")
        return {"status": "success", "message": f"Closing '{target.title}' via {action}: {reason}"}
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ─── Main Gemini Live Loop ──────────────────────────────────

async def run_gemini_loop(pya):
    """The core Gemini Live API loop — handles reconnection, mode switching, and all async tasks."""

    # ── Shared VAD + affective config ──
    _vad_config = types.RealtimeInputConfig(
        automatic_activity_detection=types.AutomaticActivityDetection(
            disabled=False,
            start_of_speech_sensitivity=types.StartSensitivity.START_SENSITIVITY_LOW,
            end_of_speech_sensitivity=types.EndSensitivity.END_SENSITIVITY_LOW,
            prefix_padding_ms=20,
            silence_duration_ms=500,
        )
    )

    # ── Voice: Kore = dynamique & expressive, colle au perso Tama ──
    _voice_config = types.SpeechConfig(
        voice_config=types.VoiceConfig(
            prebuilt_voice_config=types.PrebuiltVoiceConfig(
                voice_name="Kore"
            )
        )
    )

    # ── Session resume handle (persisted across reconnections) ──
    resume_handle = state.get("_session_resume_handle")

    config_deep_work = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(parts=[types.Part(text=SYSTEM_PROMPT)]),
        tools=TOOLS,
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        session_resumption=types.SessionResumptionConfig(
            handle=resume_handle,          # ← Feature 7: reprise seamless
        ),
        proactivity=types.ProactivityConfig(proactive_audio=True),
        enable_affective_dialog=True,      # ← Phase 1: dialogue émotionnel
        speech_config=_voice_config,       # ← Feature 6: voix Tama
        context_window_compression=types.ContextWindowCompressionConfig(
            sliding_window=types.SlidingWindow(),  # ← Phase 1: sessions illimitées
        ),
        realtime_input_config=_vad_config, # ← Phase 1: VAD serveur
        thinking_config=types.ThinkingConfig(
            thinking_budget=512,           # ← Feature 5: raisonnement pour classify_screen
        ),
    )

    config_conversation = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(parts=[types.Part(text=CONVO_PROMPT)]),
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        session_resumption=types.SessionResumptionConfig(
            handle=resume_handle,          # ← Feature 7: reprise seamless
        ),
        proactivity=types.ProactivityConfig(proactive_audio=True),
        enable_affective_dialog=True,      # ← Phase 1: dialogue émotionnel
        speech_config=_voice_config,       # ← Feature 6: voix Tama
        realtime_input_config=_vad_config, # ← Phase 1: VAD serveur
        # PAS de ThinkingConfig ici — latence en conversation vocale
    )

    while True:
        update_display(TamaState.CALM, "Mode Libre — Tama est là 🥷")
        while not state["is_session_active"] and not state["conversation_requested"]:
            await asyncio.sleep(0.3)

        if state["conversation_requested"]:
            state["current_mode"] = "conversation"
            state["conversation_requested"] = False
            state["conversation_start_time"] = time.time()
            msg = json.dumps({"command": "START_CONVERSATION"})
            for ws_client in list(state["connected_ws_clients"]):
                try:
                    await ws_client.send(msg)
                except Exception:
                    pass
            update_display(TamaState.CALM, "Connecting for conversation...")
        else:
            state["current_mode"] = "deep_work"
            update_display(TamaState.CALM, "Connecting to Google WebSocket...")

        # Wait for API key if not yet configured
        while cfg.client is None:
            update_display(TamaState.CALM, "⚠️ Clé API manquante — ouvrez ⚙️ Settings")
            await asyncio.sleep(2.0)
            if not state["is_session_active"] and not state["conversation_requested"]:
                state["current_mode"] = "libre"
                break
        if cfg.client is None:
            continue

        try:
            active_config = config_conversation if state["current_mode"] == "conversation" else config_deep_work
            async with cfg.client.aio.live.connect(model=MODEL, config=active_config) as session:

                update_display(TamaState.CALM, "Connected! Dis-moi bonjour !")

                audio_out_queue = asyncio.Queue()
                audio_in_queue = asyncio.Queue(maxsize=2)

                state["force_speech"] = False

                # --- 1. Audio Input (Microphone) ---
                async def listen_mic():
                    def _resolve_mic_index():
                        idx = state["selected_mic_index"]
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

                            failed_name = ""
                            try:
                                failed_name = pya.get_device_info_by_index(mic_idx)["name"].lower()
                            except Exception:
                                pass

                            if failed_name:
                                match_prefix = failed_name[:15]
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
                    _last_failed_mic = None
                    try:
                        while True:
                            wanted_mic = _resolve_mic_index()
                            if wanted_mic != current_mic and wanted_mic != _last_failed_mic:
                                print(f"🎤 Hot-swap micro: {current_mic} → {wanted_mic}")
                                try:
                                    stream.close()
                                except Exception:
                                    pass
                                stream, actual_mic = await asyncio.to_thread(_open_mic_stream, wanted_mic)
                                if actual_mic != wanted_mic:
                                    _last_failed_mic = wanted_mic
                                else:
                                    _last_failed_mic = None
                                current_mic = actual_mic

                            data = await asyncio.to_thread(stream.read, CHUNK_SIZE, exception_on_overflow=False)
                            if detect_voice_activity(data):
                                state["user_spoke_at"] = time.time()
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
                    if state["current_mode"] == "conversation":
                        state["user_spoke_at"] = time.time()
                        await asyncio.sleep(2.0)
                        try:
                            await session.send_realtime_input(
                                text="Salue l'utilisateur ! Il a appuyé sur 'Parler' pour discuter avec toi. Sois naturelle et courte."
                            )
                        except Exception:
                            return

                    while True:
                        if state["current_mode"] == "conversation":
                            user_spoke_recently = (time.time() - state["user_spoke_at"]) < CONVERSATION_SILENCE_TIMEOUT
                            time_in_conversation = time.time() - (state["conversation_start_time"] or time.time())

                            if not user_spoke_recently and time_in_conversation > 10:
                                print("💬 Silence détecté — fin de la conversation.")
                                end_msg = json.dumps({"command": "END_CONVERSATION"})
                                for ws_client in list(state["connected_ws_clients"]):
                                    try:
                                        await ws_client.send(end_msg)
                                    except Exception:
                                        pass
                                state["current_mode"] = "libre"
                                raise RuntimeError("Conversation ended")

                            await asyncio.sleep(2.0)
                            continue

                        # ── Deep Work mode: full screen analysis ──
                        jpeg_bytes = await asyncio.to_thread(capture_all_screens)
                        blob = types.Blob(data=jpeg_bytes, mime_type="image/jpeg")
                        try:
                            await session.send_realtime_input(media=blob)
                        except Exception:
                            print("⚠️  Video stream interrompu (session fermée)")
                            break

                        await asyncio.to_thread(refresh_window_cache)
                        active_title = get_cached_active_title()
                        open_win_titles = [w.title for w in get_cached_windows()]

                        if active_title != state["last_active_window_title"]:
                            state["last_active_window_title"] = active_title
                            state["active_window_start_time"] = time.time()

                        active_duration = int(time.time() - state["active_window_start_time"])

                        si = state["current_suspicion_index"]
                        if si >= 9:
                            if state["suspicion_at_9_start"] is None:
                                state["suspicion_at_9_start"] = time.time()
                            state["suspicion_above_6_start"] = None
                        elif si >= 6:
                            if state["suspicion_above_6_start"] is None:
                                state["suspicion_above_6_start"] = time.time()
                            state["suspicion_at_9_start"] = None
                        else:
                            state["suspicion_above_6_start"] = None
                            state["suspicion_at_9_start"] = None

                        user_spoke_recently = (time.time() - state["user_spoke_at"]) < USER_SPEECH_TIMEOUT
                        if state["just_started_session"] and state["session_start_time"] and (time.time() - state["session_start_time"] < 30):
                            speak_directive = "UNMUZZLED: Tu viens tout juste d'arriver avec l'utilisateur ! Dis-lui un grand bonjour motivant et demande-lui sur quoi il compte travailler aujourd'hui. Sois super encourageante et chaleureuse. N'utilise pas de texte, parle directement."
                            state["just_started_session"] = False
                        elif state["force_speech"]:
                            speak_directive = "UNMUZZLED: You MUST speak now to address the user!"
                        elif state["break_reminder_active"]:
                            session_min = int((time.time() - state["session_start_time"]) / 60) if state["session_start_time"] else 0
                            speak_directive = f"UNMUZZLED: Tu travailles depuis {session_min} min. Suggère gentiment une pause de quelques minutes. Sois bienveillante."
                        elif user_spoke_recently:
                            speak_directive = "UNMUZZLED: L'utilisateur te PARLE en ce moment. Réponds-lui naturellement en français, sois toi-même (Tama). Reste courte et conversationnelle (1-2 phrases). Tu peux toujours appeler classify_screen en parallèle si besoin."
                        else:
                            # Default: muzzled, but check for "curious" state
                            ali = state["current_alignment"]
                            cat = state["current_category"]
                            if ali <= 0.5 and cat in ("FLUX", "ZONE_GRISE", "PROCRASTINATION_PRODUCTIVE") and active_duration > 90:
                                speak_directive = "CURIOUS: The user has been on an ambiguous/creative app for a while. You MAY ask a short, natural question about what they're doing. Still call classify_screen."
                            else:
                                speak_directive = "YOU ARE BIOLOGICALLY MUZZLED. DO NOT OUTPUT TEXT/WORDS. ONLY call classify_screen."
                            if state["suspicion_at_9_start"] and (time.time() - state["suspicion_at_9_start"] > 15):
                                speak_directive = "CRITICAL UNMUZZLED: SUSPICION IS MAXIMAL. YOU MUST DO TWO THINGS: 1) SCOLD THE USER LOUDLY IN FRENCH, 2) CALL close_distracting_tab with the target_window set to the distracting window title from open_windows. DO BOTH NOW!"
                            elif state["suspicion_above_6_start"] and (time.time() - state["suspicion_above_6_start"] > 45):
                                speak_directive = "WARNING: YOU ARE NOW UNMUZZLED. YOU MUST GIVE A SHORT VERBAL WARNING TO THE USER."

                        task_info = f"scheduled_task: {state['current_task']}" if state["current_task"] else "scheduled_task: NOT SET (ask the user!)"
                        tama_state = state["current_tama_state"]
                        if tama_state == TamaState.CALM and audio_out_queue.empty():
                            await session.send_realtime_input(
                                text=f"[SYSTEM] active_window: {active_title} | open_windows: {open_win_titles} | duration: {active_duration}s | S: {state['current_suspicion_index']:.1f} | A: {state['current_alignment']} | {task_info}. Call classify_screen. {speak_directive}"
                            )

                        if state["current_suspicion_index"] <= 2:
                            pulse_delay = 8.0
                        elif state["current_suspicion_index"] <= 5:
                            pulse_delay = 5.0
                        elif state["current_suspicion_index"] <= 8:
                            pulse_delay = 4.0
                        else:
                            pulse_delay = 3.0

                        await asyncio.sleep(pulse_delay)

                # --- 3. Receive AI Responses ---
                async def reset_calm_after_delay():
                    await asyncio.sleep(4)
                    update_display(TamaState.CALM, "Je te surveille toujours.")

                async def receive_responses():
                    is_speaking = False
                    while True:
                        try:
                            turn = session.receive()
                            async for response in turn:
                                server = response.server_content

                                if server and server.model_turn:
                                    for part in server.model_turn.parts:
                                        if part.inline_data and isinstance(part.inline_data.data, bytes):
                                            if not is_speaking:
                                                speech_allowed = state["force_speech"] or state["break_reminder_active"]
                                                if state["current_mode"] == "conversation":
                                                    speech_allowed = True
                                                elif state["session_start_time"] and (time.time() - state["session_start_time"] < 30):
                                                    speech_allowed = True
                                                if not speech_allowed and state["suspicion_at_9_start"] and (time.time() - state["suspicion_at_9_start"] > 15):
                                                    speech_allowed = True
                                                if not speech_allowed and state["suspicion_above_6_start"] and (time.time() - state["suspicion_above_6_start"] > 45):
                                                    speech_allowed = True
                                                if not speech_allowed and (time.time() - state["user_spoke_at"]) < USER_SPEECH_TIMEOUT:
                                                    speech_allowed = True
                                                if speech_allowed:
                                                    is_speaking = True

                                            if is_speaking:
                                                audio_out_queue.put_nowait(part.inline_data.data)

                                if server and server.turn_complete:
                                    is_speaking = False

                                if response.tool_call:
                                    try:
                                        for fc in response.tool_call.function_calls:
                                            if fc.name == "classify_screen":
                                                cat = fc.args.get("category", "SANTE")
                                                ali = float(fc.args.get("alignment", 1.0))
                                                reason = fc.args.get("reason", "")

                                                if ali > 0.75: ali = 1.0
                                                elif ali > 0.25: ali = 0.5
                                                else: ali = 0.0

                                                state["current_alignment"] = ali
                                                state["current_category"] = cat

                                                delta = compute_delta_s(ali, cat)
                                                state["current_suspicion_index"] = max(0.0, min(10.0, state["current_suspicion_index"] + delta))

                                                s_int = int(state["current_suspicion_index"])
                                                print(f"  🔍 S:{s_int}/10 | A:{ali} | Cat:{cat} | ΔS:{delta:+.1f} — {reason}")

                                                # AUTO-CLOSE: S=10 + BANNIE
                                                if state["current_suspicion_index"] >= 10.0 and cat == "BANNIE":
                                                    try:
                                                        distraction_keywords = ["youtube", "netflix", "twitch", "reddit", "tiktok", "instagram", "facebook", "steam"]
                                                        closed = False
                                                        for w in get_cached_windows():
                                                            if w.width < 100:
                                                                continue
                                                            t_lower = w.title.lower()
                                                            if not compute_can_be_closed(t_lower):
                                                                continue
                                                            if any(kw in t_lower for kw in distraction_keywords):
                                                                print(f"  🤖 AUTO-CLOSE: S=10, fermeture de '{w.title[:60]}'")
                                                                update_display(TamaState.ANGRY, f"JE FERME ÇA ! ({w.title[:30]})")
                                                                state["force_speech"] = True
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
                                                            response={"status": "updated", "S": round(state["current_suspicion_index"], 1), "A": ali, "cat": cat},
                                                            id=fc.id
                                                        )
                                                    ]
                                                )

                                            elif fc.name == "close_distracting_tab":
                                                reason = fc.args.get("reason", "Distraction")
                                                target_window = fc.args.get("target_window", None)

                                                result = execute_close_tab(reason, target_window)

                                                # Only trigger angry animation if close actually worked
                                                if result.get("status") == "success":
                                                    update_display(TamaState.ANGRY, f"JE FERME ÇA ! ({reason[:30]})")
                                                    state["force_speech"] = True
                                                else:
                                                    # Protected app or not found — no animation, just log
                                                    print(f"  ⚠️ close_distracting_tab bloqué: {result.get('message', '?')}")

                                                await session.send_tool_response(
                                                    function_responses=[
                                                        types.FunctionResponse(
                                                            name="close_distracting_tab",
                                                            response=result,
                                                            id=fc.id
                                                        )
                                                    ]
                                                )

                                                if result.get("status") == "success":
                                                    async def delay_reset():
                                                        await asyncio.sleep(6)
                                                        state["force_speech"] = False
                                                        update_display(TamaState.CALM, "Je te surveille toujours.")
                                                    asyncio.create_task(delay_reset())

                                            elif fc.name == "set_current_task":
                                                task = fc.args.get("task", "Unknown")
                                                state["current_task"] = task
                                                state["force_speech"] = False
                                                print(f"  🎯 Tâche définie : {state['current_task']}")

                                                await session.send_tool_response(
                                                    function_responses=[
                                                        types.FunctionResponse(
                                                            name="set_current_task",
                                                            response={"status": "task_set", "current_task": state["current_task"]},
                                                            id=fc.id
                                                        )
                                                    ]
                                                )
                                    except Exception as e:
                                        print(f"⚠️ Erreur function call : {e}")

                                if server and server.interrupted:
                                    while not audio_out_queue.empty():
                                        audio_out_queue.get_nowait()

                                # ── Feature 7: capture session resume handle ──
                                if hasattr(response, 'session_resumption_update') and response.session_resumption_update:
                                    sru = response.session_resumption_update
                                    if sru.resumable and sru.new_handle:
                                        had_handle = state["_session_resume_handle"] is not None
                                        state["_session_resume_handle"] = sru.new_handle
                                        if not had_handle:
                                            print(f"  🔄 Session resume handle activé")

                                # ── Feature 8: GoAway — graceful disconnect warning ──
                                if hasattr(response, 'go_away') and response.go_away:
                                    ga = response.go_away
                                    time_left = getattr(ga, 'time_left', '?')
                                    print(f"  ⚠️ [GoAway] Gemini va déconnecter dans {time_left}. Reconnexion préparée...")
                                    # Handle is already saved above → reconnection will use it

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
                                break
                    except asyncio.CancelledError:
                        pass
                    finally:
                        try:
                            speaker.stop_stream()
                            speaker.close()
                        except Exception:
                            pass

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

        state["current_mode"] = "libre"
        if state["is_session_active"]:
            print("🔄 Reconnexion à l'IA dans 3 secondes...")
            await asyncio.sleep(3)
