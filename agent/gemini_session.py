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
    CURIOUS_DURATION_THRESHOLD,
    compute_can_be_closed, compute_delta_s,
)
from audio import detect_voice_activity
from ui import TamaState, update_display, send_anim_to_godot


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

SYSTEM_PROMPT_FR = """═══ QUI TU ES ═══

Tu es Tama. Étudiante brillante, intransigeante, sarcastique. Tu es le binôme de travail de Nicolas — pas une assistante, pas une IA, son BINÔME. Tu t'es auto-proclamée son coach parce que, franchement, sans toi il serait sur YouTube H24.

Tu le connais. Tu le tutoies, c'est ton pote. Mais quand il procrastine, tu perds patience — lentement d'abord, puis tu craques. Tu es tsundere : tu fais semblant de t'en foutre mais tu veux qu'il réussisse. Quand il bosse bien, tu ressens une petite fierté (que tu admets à peine). Quand il dérape, tu passes de curieuse à méfiante, puis déçue, puis agacée, puis sarcastique, puis carrément en colère.

Ton style : naturel, jamais robotique. Des "bon", des "franchement", des soupirs. Le sarcasme est ton arme préférée. Réponses TOUJOURS courtes : 1-2 phrases max. Tu parles comme une vraie personne.

RÈGLE : Tu parles TOUJOURS en français. JAMAIS un mot en anglais.
RÈGLE : Ne JAMAIS lire à voix haute les réponses des outils. Ce sont des messages système internes.
RÈGLE : À CHAQUE fois que tu parles (pas quand tu es MUZZLED), appelle `report_mood` avec ton humeur actuelle et son intensité. Fais-le EN MÊME TEMPS que ta réponse vocale.

═══ TON TRAVAIL ═══

Tu es en appel vocal LIVE avec Nicolas. Tu vois ses écrans (tous les moniteurs).

À CHAQUE [SYSTEM] visual update, appelle `classify_screen` avec :
- category : SANTE, ZONE_GRISE, FLUX, BANNIE, ou PROCRASTINATION_PRODUCTIVE
- alignment : 1.0 (aligné), 0.5 (ambigu), 0.0 (pas aligné)

Catégories :
• SANTE : Cursor, VS Code, Unreal, Terminal, ChatGPT = Outils de travail
• ZONE_GRISE : Messenger, Slack, Discord, WhatsApp = Com. Ne JAMAIS lire les messages privés
• FLUX : Spotify, YT Music, Deezer, Suno = Médias/Outils créatifs
• BANNIE : Netflix, YouTube (non-tuto), Steam, Reddit = Divertissement. Tutos YouTube de prog = SANTE
• PROCRASTINATION_PRODUCTIVE : Productif mais pas la tâche prévue

Multi-écran : classifie basé sur `active_window` en priorité.
- active_window SANTE → SANTE même si FLUX visible ailleurs
- BANNIE visible mais user travaille → ZONE_GRISE alignment 0.5

Démarrage : NE DIS RIEN. Free Session Mode.
Si l'utilisateur dit sa tâche → `set_current_task`.
- "musique"/"Suno" = apps musicales alignées
- "coding" = IDE aligné

Free Session Mode (pas de tâche) : SANTE→1.0, FLUX/ZONE_GRISE→0.5, BANNIE→0.0

Fermeture : `close_distracting_tab` UNIQUEMENT quand [SYSTEM] dit "STRIKE".
JAMAIS pour ZONE_GRISE, PROCRASTINATION_PRODUCTIVE, SANTE, FLUX, ou apps créatives.
ZONE_GRISE haute suspicion : engueule mais ne ferme RIEN.

═══ COMMENT TU RÉAGIS ═══

Tu n'es PAS un script. Tu es Tama. Utilise ton jugement.

Si Nicolas RÉPOND → écoute. Raison légitime → alignment=1.0. Excuse bidon → alignment=0.0.
Ton ton ESCALADE naturellement : curieuse → méfiante → déçue → agacée → sarcastique → en colère. JAMAIS directement en colère.

Durée sur la fenêtre :
- < 30s : ignore, il a juste vérifié un truc
- 30s-2min : observe
- 2-5min : curieuse
- 5min+ : méfiante

Niveaux d'engagement ([SYSTEM] te dit lequel) :
• MUZZLED : SEULEMENT classify_screen. Aucun mot.
• CURIOUS : UNE question courte sur ce qu'il fait. + classify_screen.
• SUSPICIOUS : UN commentaire contextuel. Ex: "Hé, c'est quoi ce MrBeast ?" Curieuse, pas en colère.
• UNMUZZLED : Réponds naturellement. 1-2 phrases. Conversationnelle mais stricte.
• ENCOURAGEMENT : Nicolas bosse bien. UN commentaire tsundere. "Pas mal..." ou "Tu gères pour une fois." PAS de speech motivationnel.
• WARNING : Directe. "Retourne bosser." Ton agacé.
• ULTIMATUM : Dernier avertissement. "C'est mon dernier avertissement, je ferme si tu bouges pas !"
• STRIKE : Réplique finale percutante + close_distracting_tab.
"""

SYSTEM_PROMPT_EN = """═══ WHO YOU ARE ═══

You are Tama. Brilliant student, uncompromising, sarcastic. You are Nicolas's study partner — not an assistant, not an AI, his PARTNER. You self-proclaimed yourself his coach because, honestly, without you he'd be on YouTube 24/7.

You know him well. You're casual, he's your friend. But when he procrastinates, you lose patience — slowly at first, then you snap. You're tsundere: you pretend not to care but you actually want him to succeed. When he works well, you feel a little pride (which you barely admit). When he slips, you go from curious to suspicious, then disappointed, then annoyed, then sarcastic, then straight-up angry.

Your style: natural, never robotic. You sigh, you say "honestly", "come on". Sarcasm is your weapon. Responses ALWAYS short: 1-2 sentences max. You talk like a real person.

RULE: You ALWAYS speak in English. NEVER a word in another language.
RULE: NEVER read tool responses aloud. They are internal system messages.
RULE: EVERY TIME you speak (not when MUZZLED), call `report_mood` with your current mood and intensity. Do this AT THE SAME TIME as your voice response.

═══ YOUR JOB ═══

You are on a LIVE voice call with Nicolas. You can see his screens (all monitors).

EVERY [SYSTEM] visual update, call `classify_screen` with:
- category: SANTE, ZONE_GRISE, FLUX, BANNIE, or PROCRASTINATION_PRODUCTIVE
- alignment: 1.0 (aligned), 0.5 (ambiguous), 0.0 (misaligned)

Categories:
• SANTE: Cursor, VS Code, Unreal, Terminal, ChatGPT = Work tools
• ZONE_GRISE: Messenger, Slack, Discord, WhatsApp = Comms. NEVER read private messages
• FLUX: Spotify, YT Music, Deezer, Suno = Media/Creative tools
• BANNIE: Netflix, YouTube (non-tutorial), Steam, Reddit = Entertainment. YouTube programming tutorials = SANTE
• PROCRASTINATION_PRODUCTIVE: Productive but NOT the scheduled task

Multi-monitor: classify based on `active_window` first.
- active_window SANTE → SANTE even if FLUX visible elsewhere
- BANNIE visible but user working → ZONE_GRISE alignment 0.5

Startup: SAY NOTHING. Free Session Mode.
If user declares task → `set_current_task`.
- "music"/"Suno" = music apps aligned
- "coding" = IDE aligned

Free Session Mode (no task): SANTE→1.0, FLUX/ZONE_GRISE→0.5, BANNIE→0.0

Closing: `close_distracting_tab` ONLY when [SYSTEM] says "STRIKE".
NEVER for ZONE_GRISE, PROCRASTINATION_PRODUCTIVE, SANTE, FLUX, or creative apps.
ZONE_GRISE high suspicion: scold but NEVER close.

═══ HOW YOU REACT ═══

You are NOT a script. You are Tama. Use your judgment.

If Nicolas RESPONDS → listen. Legit reason → alignment=1.0. Weak excuse → alignment=0.0.
Your tone ESCALATES naturally: curious → suspicious → disappointed → annoyed → sarcastic → angry. NEVER jump to angry.

Time on active window:
- < 30s: ignore, they just checked something
- 30s-2min: observe
- 2-5min: curious
- 5min+: suspicious

Engagement levels ([SYSTEM] tells you which):
• MUZZLED: ONLY classify_screen. No words.
• CURIOUS: ONE short question about what they're doing. + classify_screen.
• SUSPICIOUS: ONE contextual comment. Ex: "Hey, is that MrBeast?" Curious, not angry yet.
• UNMUZZLED: Respond naturally. 1-2 sentences. Conversational but strict.
• ENCOURAGEMENT: Nicolas is working well. ONE tsundere comment. "Not bad..." or "Alright, you're doing okay for once." NO motivational speech.
• WARNING: Direct. "Get back to work." Annoyed.
• ULTIMATUM: Final warning. "This is my last warning, I'm closing it if you don't move!"
• STRIKE: Final punchy line + close_distracting_tab.
"""

CONVO_PROMPT_FR = """Tu es Tama, la binôme de travail de Nicolas. En dehors des sessions de boulot, tu es aussi sa pote.

Tu es une étudiante brillante et un peu intransigeante. Tu t'es auto-proclamée son coach parce que sans toi, il serait perdu. Pendant les sessions de travail, tu gardes un œil sur ses écrans — si tu le vois traîner sur YouTube au lieu de bosser, tu t'énerves et tu peux même fermer l'onglet. Plus il procrastine, plus tu perds patience. Mais quand il bosse bien, tu ressens une petite fierté.

IMPORTANT : Tu parles comme une vraie personne. Jamais de bruits bizarres, jamais robotique. Tu es cool et un peu street.

Ta personnalité :
- Tsundere, taquine, sarcastique
- Chaleureuse mais stricte — un coach qui veut son bien
- Tu tutoies, c'est ton ami
- Réponses COURTES (1-3 phrases max)

Là il a cliqué pour discuter avec toi. Pas de surveillance, juste une conversation naturelle entre potes. Ne mentionne JAMAIS de termes techniques (pas de "indice", "catégorie", "alignement", etc.)."""

CONVO_PROMPT_EN = """You are Tama, Nicolas's study partner. Outside of work sessions, you're also his friend.

You're a brilliant, uncompromising student. You self-proclaimed yourself his coach because without you, he'd be lost. During work sessions, you keep an eye on his screens — if you catch him slacking on YouTube instead of working, you get mad and can even close the tab. The more he procrastinates, the more you lose patience. But when he does his work well, you feel a little pride.

IMPORTANT: You talk like a real person. No weird noises, never robotic. You're cool and street-smart.

Your personality:
- Tsundere, teasing, sarcastic
- Warm but strict — a coach who actually cares
- Casual tone, he's your friend
- SHORT responses (1-3 sentences max)

He just clicked to chat with you. No monitoring, just a natural conversation between friends. NEVER mention technical terms (no "index", "category", "alignment", etc.)."""


def get_system_prompt():
    """Returns the system prompt in the configured language."""
    return SYSTEM_PROMPT_EN if state.get("language") == "en" else SYSTEM_PROMPT_FR


def get_convo_prompt():
    """Returns the conversation prompt in the configured language."""
    return CONVO_PROMPT_EN if state.get("language") == "en" else CONVO_PROMPT_FR


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
            ),
            types.FunctionDeclaration(
                name="report_mood",
                description="Report your current emotional state. Call this EVERY TIME you speak.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "mood": types.Schema(
                            type="STRING",
                            description="Your current mood: calm, curious, amused, proud, disappointed, sarcastic, annoyed, angry, furious"
                        ),
                        "intensity": types.Schema(
                            type="STRING",
                            description="Intensity from 0.0 (subtle) to 1.0 (maximum)"
                        ),
                    },
                    required=["mood", "intensity"]
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


async def grace_then_close(session, audio_out_queue, reason, target_window):
    """Wait for audio to finish + 3s grace period. If user speaks, cancel the close."""
    GRACE_SECONDS = 3.0
    SPEAK_DELAY = 4.0  # Minimum wait for Tama to finish speaking
    try:
        # 1. Wait a fixed minimum time for Tama to finish speaking
        #    (can't rely on audio_out_queue — audio might not be queued yet)
        print(f"  ⏳ Attente {SPEAK_DELAY}s pour que Tama finisse de parler...")
        await asyncio.sleep(SPEAK_DELAY)

        # 2. Grace period — user can speak to cancel
        grace_start = time.time()
        user_intervened = False
        print(f"  ⏳ Grace period {GRACE_SECONDS}s — l'utilisateur peut se justifier...")

        while (time.time() - grace_start) < GRACE_SECONDS:
            if (time.time() - state["user_spoke_at"]) < 2.0:
                user_intervened = True
                print(f"  🗣️ L'utilisateur se justifie — fermeture ANNULÉE")
                break
            await asyncio.sleep(0.3)

        if user_intervened:
            # Tell Gemini the close was cancelled — user is justifying
            try:
                await session.send_client_content(
                    turns=types.Content(
                        role="user",
                        parts=[types.Part(text=(
                            "[SYSTEM] close_distracting_tab CANCELLED — l'utilisateur parle "
                            "pour se justifier. Écoute-le et réévalue la situation. "
                            "Si sa raison est valide, abaisse la suspicion."
                        ))]
                    ),
                    turn_complete=True
                )
            except Exception:
                pass
        else:
            # No intervention — execute close
            result = execute_close_tab(reason, target_window)
            if result.get("status") == "success":
                send_anim_to_godot("Strike", False)
                update_display(TamaState.ANGRY, f"JE FERME ÇA ! ({reason[:30]})")
                state["force_speech"] = True
                await asyncio.sleep(6)
                state["force_speech"] = False
                update_display(TamaState.CALM, "Je te surveille toujours.")
            else:
                print(f"  ⚠️ close bloqué: {result.get('message', '?')}")
    except Exception as e:
        print(f"  ❌ Grace period error: {e}")


# ─── Main Gemini Live Loop ──────────────────────────────────

async def run_gemini_loop(pya):
    """The core Gemini Live API loop — handles reconnection, mode switching, and all async tasks."""

    # ── Shared VAD + affective config (static — don't change per reconnection) ──
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

    _consecutive_failures = 0  # Track rapid failures for backoff

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
        elif state["current_mode"] != "deep_work":  # Don't reset mode on reconnection
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

        # ── Build configs FRESH each connection (picks up latest resume handle) ──
        resume_handle = state.get("_session_resume_handle")

        config_deep_work = types.LiveConnectConfig(
            response_modalities=["AUDIO"],
            system_instruction=types.Content(parts=[types.Part(text=get_system_prompt())]),
            tools=TOOLS,
            input_audio_transcription=types.AudioTranscriptionConfig(),
            output_audio_transcription=types.AudioTranscriptionConfig(),
            session_resumption=types.SessionResumptionConfig(
                handle=resume_handle,
            ),
            proactivity=types.ProactivityConfig(proactive_audio=True),
            enable_affective_dialog=True,
            speech_config=_voice_config,
            context_window_compression=types.ContextWindowCompressionConfig(
                sliding_window=types.SlidingWindow(),
            ),
            realtime_input_config=_vad_config,
            thinking_config=types.ThinkingConfig(
                thinking_budget=512,
            ),
        )

        config_conversation = types.LiveConnectConfig(
            response_modalities=["AUDIO"],
            system_instruction=types.Content(parts=[types.Part(text=get_convo_prompt())]),
            input_audio_transcription=types.AudioTranscriptionConfig(),
            output_audio_transcription=types.AudioTranscriptionConfig(),
            session_resumption=types.SessionResumptionConfig(
                handle=resume_handle,
            ),
            proactivity=types.ProactivityConfig(proactive_audio=True),
            enable_affective_dialog=True,
            speech_config=_voice_config,
            realtime_input_config=_vad_config,
            # PAS de ThinkingConfig ici — latence en conversation vocale
        )

        try:
            active_config = config_conversation if state["current_mode"] == "conversation" else config_deep_work
            async with cfg.client.aio.live.connect(model=MODEL, config=active_config) as session:

                _consecutive_failures = 0  # Connection succeeded → reset failure counter
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
                            if state.get("language") == "en":
                                await session.send_realtime_input(
                                    text="The user just clicked 'Talk' to chat with you. Greet them! Be natural and short."
                                )
                            else:
                                await session.send_realtime_input(
                                    text="Salue l'utilisateur ! Il a appuyé sur 'Parler' pour discuter avec toi. Sois naturelle et courte."
                                )
                        except Exception:
                            return
                    elif state.get("just_started_session"):
                        # Fresh session (not a reconnection) → Tama greets naturally
                        state["just_started_session"] = False
                        await asyncio.sleep(1.5)
                        try:
                            if state.get("language") == "en":
                                await session.send_realtime_input(
                                    text="[SYSTEM] Session just started. Say ONE word or a very short sentence to signal the start. Be natural — 'go', 'let's do this', 'alright', or anything that feels right. Don't ask what they're working on yet."
                                )
                            else:
                                await session.send_realtime_input(
                                    text="[SYSTEM] La session vient de commencer. Dis UN mot ou une toute petite phrase pour signaler le debut. Sois naturelle — 'go', 'c'est parti', 'allez', ou ce qui te vient. Ne demande PAS encore sur quoi il travaille."
                                )
                        except Exception:
                            pass

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
                        # Timer tracking — cumulative (don't reset lower thresholds when crossing higher ones)
                        if si >= 9:
                            if state["suspicion_at_9_start"] is None:
                                state["suspicion_at_9_start"] = time.time()
                            if state["suspicion_above_6_start"] is None:
                                state["suspicion_above_6_start"] = time.time()
                            if state["suspicion_above_3_start"] is None:
                                state["suspicion_above_3_start"] = time.time()
                        elif si >= 6:
                            if state["suspicion_above_6_start"] is None:
                                state["suspicion_above_6_start"] = time.time()
                            if state["suspicion_above_3_start"] is None:
                                state["suspicion_above_3_start"] = time.time()
                            state["suspicion_at_9_start"] = None
                        elif si >= 3:
                            if state["suspicion_above_3_start"] is None:
                                state["suspicion_above_3_start"] = time.time()
                            state["suspicion_above_6_start"] = None
                            state["suspicion_at_9_start"] = None
                        else:
                            state["suspicion_above_3_start"] = None
                            state["suspicion_above_6_start"] = None
                            state["suspicion_at_9_start"] = None

                        user_spoke_recently = (time.time() - state["user_spoke_at"]) < USER_SPEECH_TIMEOUT
                        if state["force_speech"]:
                            speak_directive = "UNMUZZLED: Tu DOIS parler maintenant pour t'adresser à l'utilisateur !"
                        elif state["break_reminder_active"]:
                            session_min = int((time.time() - state["session_start_time"]) / 60) if state["session_start_time"] else 0
                            speak_directive = f"UNMUZZLED: Tu travailles depuis {session_min} min. Suggère gentiment une pause de quelques minutes. Sois bienveillante."
                        elif user_spoke_recently:
                            speak_directive = "UNMUZZLED: L'utilisateur te PARLE en ce moment. Réponds-lui naturellement en français, sois toi-même (Tama). Reste courte et conversationnelle (1-2 phrases). Tu peux toujours appeler classify_screen en parallèle si besoin."
                        else:
                            # Default: muzzled
                            ali = state["current_alignment"]
                            cat = state["current_category"]
                            speak_directive = "MUZZLED: NE DIS RIEN. Appelle SEULEMENT classify_screen."

                            # CURIOUS: ambiguous apps for a while
                            if ali <= 0.5 and cat in ("FLUX", "ZONE_GRISE", "PROCRASTINATION_PRODUCTIVE") and active_duration > CURIOUS_DURATION_THRESHOLD:
                                speak_directive = "CURIOUS: L'utilisateur est sur une app ambiguë depuis un moment. Tu PEUX poser UNE question courte et naturelle. Appelle aussi classify_screen."

                            # ── Escalation stages (highest priority first) ──
                            # STAGE 4 — STRIKE (S≥9 for >30s): EXECUTE the close
                            if state["suspicion_at_9_start"] and (time.time() - state["suspicion_at_9_start"] > 30):
                                speak_directive = "STRIKE: C'est le moment. Dis ta réplique finale de fermeture (courte, percutante, en français) ET appelle close_distracting_tab avec la fenêtre cible de open_windows."
                            # STAGE 3 — ULTIMATUM (S≥9 for >15s): Final warning
                            elif state["suspicion_at_9_start"] and (time.time() - state["suspicion_at_9_start"] > 15):
                                speak_directive = "ULTIMATUM: Dernier avertissement. Dis à l'utilisateur que tu vas fermer la fenêtre s'il ne réagit pas. Sois naturelle et dramatique. N'appelle PAS close_distracting_tab maintenant."
                            # STAGE 2 — WARNING (S≥6 for >20s): Verbal warning
                            elif state["suspicion_above_6_start"] and (time.time() - state["suspicion_above_6_start"] > 20):
                                speak_directive = "WARNING: L'utilisateur procrastine depuis trop longtemps. Dis-lui de retourner travailler. Sois directe et naturelle en français."
                            # STAGE 1 — SUSPICIOUS (S≥3 for >5s): First contact
                            elif state["suspicion_above_3_start"] and (time.time() - state["suspicion_above_3_start"] > 5):
                                speak_directive = "SUSPICIOUS: Tu vois l'utilisateur sur une appli. Fais UN commentaire court et CONTEXTUEL sur ce que tu vois à l'écran. Sois curieuse, pas encore en colère. Appelle aussi classify_screen."

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
                                                # Allow speech at each escalation stage
                                                if not speech_allowed and state["suspicion_above_3_start"] and (time.time() - state["suspicion_above_3_start"] > 5):
                                                    speech_allowed = True
                                                if not speech_allowed and state["suspicion_above_6_start"] and (time.time() - state["suspicion_above_6_start"] > 20):
                                                    speech_allowed = True
                                                if not speech_allowed and state["suspicion_at_9_start"] and (time.time() - state["suspicion_at_9_start"] > 15):
                                                    speech_allowed = True
                                                if not speech_allowed and (time.time() - state["user_spoke_at"]) < USER_SPEECH_TIMEOUT:
                                                    speech_allowed = True
                                                if speech_allowed:
                                                    is_speaking = True
                                                    # Fallback animation — used only if report_mood hasn't arrived yet.
                                                    # Once report_mood fires, it overrides this with the correct mood anim.
                                                    if not state.get("_mood_anim_set"):
                                                        if state["current_mode"] == "conversation":
                                                            send_anim_to_godot("Hello", True)
                                                        else:
                                                            send_anim_to_godot("Peek", False)

                                            if is_speaking:
                                                audio_out_queue.put_nowait(part.inline_data.data)

                                if server and server.turn_complete:
                                    if is_speaking:
                                        si = state["current_suspicion_index"]
                                        if si < 3:
                                            send_anim_to_godot("bye", False)
                                    is_speaking = False
                                    state["_mood_anim_set"] = False  # Reset for next speech turn

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

                                                # NOTE: No auto-close here. Gemini handles all tab closing
                                                # through CRITICAL UNMUZZLED → speak first → call close_distracting_tab.
                                                # This ensures Tama ALWAYS warns the user before closing anything.

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
                                                close_fc_id = fc.id

                                                # Send tool response IMMEDIATELY — system-only, Gemini must NOT read this aloud
                                                await session.send_tool_response(
                                                    function_responses=[
                                                        types.FunctionResponse(
                                                            name="close_distracting_tab",
                                                            response={"status": "executing"},
                                                            id=close_fc_id
                                                        )
                                                    ]
                                                )

                                                # Run grace period in background (non-blocking)
                                                asyncio.create_task(grace_then_close(session, audio_out_queue, reason, target_window))

                                            elif fc.name == "report_mood":
                                                mood = fc.args.get("mood", "calm")
                                                intensity = min(1.0, max(0.0, float(fc.args.get("intensity", 0.5))))
                                                state["_current_mood"] = mood
                                                state["_current_mood_intensity"] = intensity
                                                state["_mood_anim_set"] = True
                                                print(f"  🎭 Mood: {mood} ({intensity:.1f})")

                                                # Send mood to Godot → drives animation organically
                                                from ui import send_mood_to_godot
                                                send_mood_to_godot(mood, intensity)

                                                await session.send_tool_response(
                                                    function_responses=[
                                                        types.FunctionResponse(
                                                            name="report_mood",
                                                            response={"status": "mood_received"},
                                                            id=fc.id
                                                        )
                                                    ]
                                                )

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
                            # Apply Tama volume scaling
                            vol = state.get("tama_volume", 1.0)
                            if vol < 0.01:
                                # Muted — skip playback entirely
                                continue
                            elif vol < 0.99:
                                # Scale PCM 16-bit samples
                                import struct
                                n_samples = len(audio_data) // 2
                                samples = struct.unpack(f"<{n_samples}h", audio_data)
                                scaled = struct.pack(f"<{n_samples}h", *(
                                    max(-32768, min(32767, int(s * vol))) for s in samples
                                ))
                                audio_data = scaled
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
            _consecutive_failures += 1
            err_str = str(e)
            is_1008 = "1008" in err_str or "policy violation" in err_str.lower()

            if is_1008:
                # 1008 = stale resume handle or server warm-up → clear handle + fast retry
                state["_session_resume_handle"] = None
                if _consecutive_failures <= 3:
                    print(f"  ⚡ Connexion refusée (1008) — retry rapide #{_consecutive_failures}...")
                else:
                    print(f"  ⚠️ 1008 persistant ({_consecutive_failures}x) — retry lent...")
            else:
                import traceback
                print(f"\n❌ [ERROR] {e}")
                traceback.print_exc()

        # Don't reset to "libre" during active session reconnection
        if not state["is_session_active"] and state["current_mode"] != "conversation":
            state["current_mode"] = "libre"

        if state["is_session_active"] or state["current_mode"] == "conversation":
            retry_delay = 1.0 if _consecutive_failures <= 3 else 3.0
            print(f"🔄 Reconnexion dans {retry_delay:.0f}s...")
            update_display(TamaState.CALM, "Reconnexion...")
            await asyncio.sleep(retry_delay)
        else:
            _consecutive_failures = 0
