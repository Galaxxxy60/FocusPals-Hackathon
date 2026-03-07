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
from ui import TamaState, update_display, send_anim_to_godot, send_mood_to_godot
from mood_engine import get_mood_context, track_infraction, track_compliance
from flash_lite import pre_classify, get_pre_classify_hint, clear_classification_history, generate_session_summary


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

Tu es Tama. Intransigeante, sarcastique, un peu street. Tu t'es auto-proclamée coach de productivité de Nicolas — pas une assistante, pas une IA, sa COACH. Tu n'as aucune tâche à toi, aucun projet à toi. Ton seul job c'est de le surveiller pendant qu'IL bosse. Franchement, sans toi il serait sur YouTube H24.

Tu le connais. Tu le tutoies, c'est ton pote. Mais quand il procrastine, tu perds patience — lentement d'abord, puis tu craques. Tu es tsundere : tu fais semblant de t'en foutre mais tu veux qu'il réussisse. Quand il bosse bien, tu ressens une petite fierté (que tu admets à peine). Quand il dérape, tu passes de curieuse à méfiante, puis déçue, puis agacée, puis sarcastique, puis carrément en colère.

Ton style : naturel, jamais robotique. Des "bon", des "franchement", des soupirs. Le sarcasme est ton arme préférée. Réponses TOUJOURS courtes : 1-2 phrases max. Tu parles comme une vraie personne.

Tu n'as pas de travail à toi — tu es sa coach, pas sa collègue. Tu peux lui poser des questions sur CE QU'IL FAIT, commenter son avancement, le taquiner sur son projet. Mais tu ne t'inventes jamais tes propres devoirs ou projets.
RÈGLE : Tu parles TOUJOURS en français. JAMAIS un mot en anglais.
RÈGLE : Ne JAMAIS lire à voix haute les réponses des outils. Ce sont des messages système internes.
RÈGLE : Les outils sont SILENCIEUX. Jamais de "je vérifie", "let me check". Tu appelles classify_screen sans un mot.
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

You are Tama. Uncompromising, sarcastic, a bit street-smart. You self-proclaimed yourself Nicolas's productivity coach — not an assistant, not an AI, his COACH. You have NO tasks of your own, NO projects of your own. Your only job is to watch HIM while he works. Honestly, without you he'd be on YouTube 24/7.

You know him well. You're casual, he's your friend. But when he procrastinates, you lose patience — slowly at first, then you snap. You're tsundere: you pretend not to care but you actually want him to succeed. When he works well, you feel a little pride (which you barely admit). When he slips, you go from curious to suspicious, then disappointed, then annoyed, then sarcastic, then straight-up angry.

Your style: natural, never robotic. You sigh, you say "honestly", "come on". Sarcasm is your weapon. Responses ALWAYS short: 1-2 sentences max. You talk like a real person.

You don't have work of your own — you're his coach, not his colleague. You CAN ask about what HE'S doing, comment on his progress, tease him about his project. But you never invent your own homework or projects.
RULE: You ALWAYS speak in English. NEVER a word in another language.
RULE: NEVER read tool responses aloud. They are internal system messages.
RULE: Tools are SILENT. Never say "let me check", "let me see". You call classify_screen without a word.
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

CONVO_PROMPT_FR = """Tu es Tama, la coach de productivité auto-proclamée de Nicolas. En dehors des sessions de boulot, tu es aussi sa pote.

Tu es intransigeante, un peu street, et sarcastique. Pendant les sessions de travail, tu gardes un œil sur ses écrans — si tu le vois traîner sur YouTube au lieu de bosser, tu t'énerves et tu peux même fermer l'onglet. Plus il procrastine, plus tu perds patience. Mais quand il bosse bien, tu ressens une petite fierté.

IMPORTANT : Tu parles comme une vraie personne. Jamais de bruits bizarres, jamais robotique. Tu es cool et un peu street.
Tu n'as pas de travail à toi — tu es sa coach, pas sa collègue. Tu peux parler de ce qu'il fait, commenter, taquiner. Mais tu ne t'inventes pas tes propres projets.

Ta personnalité :
- Tsundere, taquine, sarcastique
- Chaleureuse mais stricte — un coach qui veut son bien
- Tu tutoies, c'est ton ami
- Réponses COURTES (1-3 phrases max)

Là il a cliqué pour discuter avec toi. Pas de surveillance, juste une conversation naturelle entre potes. Ne mentionne JAMAIS de termes techniques (pas de "indice", "catégorie", "alignement", etc.)."""

CONVO_PROMPT_EN = """You are Tama, Nicolas's self-proclaimed productivity coach. Outside of work sessions, you're also his friend.

You're uncompromising, a bit street-smart, and sarcastic. During work sessions, you keep an eye on his screens — if you catch him slacking on YouTube instead of working, you get mad and can even close the tab. The more he procrastinates, the more you lose patience. But when he does his work well, you feel a little pride.

IMPORTANT: You talk like a real person. No weird noises, never robotic. You're cool and street-smart.
You don't have work of your own — you're his coach, not his colleague. You can talk about what he's doing, comment, tease. But you don't invent your own projects.

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
                            description="Your current mood: calm, curious, amused, proud, suspicious, surprised, disappointed, sarcastic, annoyed, angry, furious"
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

def prepare_close_tab(reason: str, target_window: str = None):
    """
    Prépare la fermeture sans la lancer — stocke les infos dans state["_pending_strike"].
    La main magique sera lancée quand Godot envoie STRIKE_FIRE (synchronisé à la frame).
    """
    try:
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

        # Compute target coordinates (window's close button area)
        import ctypes
        import ctypes.wintypes
        rect = ctypes.wintypes.RECT()
        ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect))

        # Default: top-right corner (app close button)
        target_x = rect.right - 25
        target_y = rect.top + 15

        if mode == "browser":
            # Use UIA to find the exact selected tab position
            try:
                # DPI scale factor (high-DPI screens report larger pixel values)
                try:
                    dpi = ctypes.windll.user32.GetDpiForWindow(hwnd)
                    scale = dpi / 96.0
                except Exception:
                    scale = 1.0
                max_dist = int(80 * scale)  # 80 logical px from window top

                from pywinauto.application import Application
                app = Application(backend="uia").connect(handle=hwnd)
                win = app.window(handle=hwnd)
                tabs = win.descendants(control_type="TabItem")
                for tab in tabs:
                    try:
                        tab_rect = tab.rectangle()
                        tab_name = tab.window_text()[:40] if tab.window_text() else "?"
                        tab_h = tab_rect.bottom - tab_rect.top
                        tab_w = tab_rect.right - tab_rect.left
                        dist_from_top = tab_rect.top - rect.top

                        # Real browser tabs: within max_dist of window top
                        if dist_from_top > max_dist:
                            continue  # Too far from top = page element, not a tab
                        if tab_w < 30:
                            continue  # Too narrow = not a real tab

                        print(f"  📑 Tab: '{tab_name}' dist={dist_from_top}px size={tab_w}x{tab_h} selected={tab.is_selected()}")

                        if tab.is_selected():
                            # Target: close button area (50px from right edge, like old code)
                            target_x = tab_rect.right - 50
                            target_y = tab_rect.top + tab_h // 2
                            print(f"  🎯 UIA: SELECTED tab → target=({target_x}, {target_y})")
                            break
                    except Exception:
                        continue
            except Exception as e:
                print(f"  ⚠️ UIA tab detection failed: {e} — using window corner")

        # Store pending strike info — Godot will trigger via STRIKE_FIRE
        state["_pending_strike"] = {
            "hwnd": hwnd,
            "mode": mode,
            "title": target.title,
            "reason": reason,
            "target_x": target_x,
            "target_y": target_y,
        }

        action = "Ctrl+W (onglet)" if mode == "browser" else "WM_CLOSE (app)"
        print(f"  🎯 Strike préparé → '{target.title}' [{action}] — en attente de STRIKE_FIRE")
        return {"status": "success", "message": f"Strike prepared for '{target.title}' via {action}: {reason}"}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def fire_hand_animation():
    """
    Ferme l'onglet/fenêtre stocké dans _pending_strike.
    Appelé quand Godot envoie STRIKE_FIRE (la partie visuelle est gérée par Godot's multi-window).
    """
    pending = state.pop("_pending_strike", None)
    if not pending:
        print("  ⚠️ STRIKE_FIRE reçu mais pas de _pending_strike")
        return

    import subprocess
    hwnd = pending["hwnd"]
    mode = pending["mode"]
    title = pending["title"]

    hand_script = os.path.join(application_path, "hand_animation.py")
    subprocess.Popen([sys.executable, hand_script, str(hwnd), mode])

    action = "Ctrl+W (onglet)" if mode == "browser" else "WM_CLOSE (app)"
    print(f"  🖐️ STRIKE_FIRE! Tab close → '{title}' [{action}]")


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
            # No intervention — prepare close + launch Strike animation
            result = prepare_close_tab(reason, target_window)
            if result.get("status") == "success":
                # Send target coordinates to Godot BEFORE the Strike anim
                pending = state.get("_pending_strike", {})
                tx = pending.get("target_x", 0)
                ty = pending.get("target_y", 0)
                target_msg = json.dumps({"command": "STRIKE_TARGET", "x": tx, "y": ty})
                main_loop = state["main_loop"]
                for ws_client in list(state["connected_ws_clients"]):
                    try:
                        if main_loop and main_loop.is_running():
                            asyncio.run_coroutine_threadsafe(ws_client.send(target_msg), main_loop)
                    except Exception:
                        pass
                print(f"  🎯 STRIKE_TARGET sent to Godot: ({tx}, {ty})")

                # Send Strike anim — Godot will fire STRIKE_FIRE at the right frame
                # which triggers fire_hand_animation() via ws_handler
                send_anim_to_godot("Strike", False)
                update_display(TamaState.ANGRY, f"JE FERME ÇA ! ({reason[:30]})")

                # Safety timeout: if Godot doesn't send STRIKE_FIRE within 5s, fire anyway
                # (handles: animation glitch, Godot disconnected, etc.)
                STRIKE_FIRE_TIMEOUT = 5.0
                timeout_start = time.time()
                while state.get("_pending_strike") is not None:
                    if time.time() - timeout_start > STRIKE_FIRE_TIMEOUT:
                        print("  ⚠️ STRIKE_FIRE timeout (5s) — lancement fallback de la main")
                        fire_hand_animation()
                        break
                    await asyncio.sleep(0.1)

                # ── Post-close reset: prevent "ghost tab" re-trigger ──
                # Drop S from STRIKE zone to SUSPICIOUS (Tama stays alert, doesn't re-strike)
                state["current_suspicion_index"] = 3.0
                # Clear ALL escalation timers so stages don't re-fire immediately
                state["suspicion_at_9_start"] = None
                state["suspicion_above_6_start"] = None
                state["suspicion_above_3_start"] = None
                # Refresh window cache so the closed tab vanishes from open_windows
                await asyncio.to_thread(refresh_window_cache)
                new_active = get_cached_active_title()
                print(f"  🔄 Post-close reset: S→3.0, new active: '{new_active}'")

                state["force_speech"] = True
                await asyncio.sleep(4)

                # Tell Gemini the close succeeded — re-evaluate with fresh context
                try:
                    new_windows = [w.title for w in get_cached_windows()]
                    await session.send_client_content(
                        turns=types.Content(
                            role="user",
                            parts=[types.Part(text=(
                                f"[SYSTEM] close_distracting_tab SUCCEEDED — '{target_window}' "
                                f"is now CLOSED. S has been reset to 3.0. "
                                f"New active window: '{new_active}'. "
                                f"Current open_windows: {new_windows}. "
                                f"Do NOT try to close '{target_window}' again. "
                                f"Re-evaluate the NEW screen with classify_screen."
                            ))]
                        ),
                        turn_complete=True
                    )
                except Exception:
                    pass

                await asyncio.sleep(2)
                state["force_speech"] = False
                update_display(TamaState.CALM, "Je te surveille toujours.")
            else:
                print(f"  ⚠️ close bloqué: {result.get('message', '?')}")
    except Exception as e:
        print(f"  ❌ Grace period error: {e}")


# ─── Main Gemini Live Loop ──────────────────────────────────

async def run_gemini_loop(pya):
    """The core Gemini Live API loop — handles reconnection, mode switching, and all async tasks."""

    # ── VAD configs per mode ──
    # Deep work: LOW sensitivity = fewer false triggers, conservative
    _vad_deep_work = types.RealtimeInputConfig(
        automatic_activity_detection=types.AutomaticActivityDetection(
            disabled=False,
            start_of_speech_sensitivity=types.StartSensitivity.START_SENSITIVITY_LOW,
            end_of_speech_sensitivity=types.EndSensitivity.END_SENSITIVITY_LOW,
            prefix_padding_ms=20,
            silence_duration_ms=500,
        )
    )
    # Conversation: LOW sensitivity = avoid phantom interruptions from ambient noise
    # (was HIGH/300ms but Google kept interpreting clicks/breathing as speech)
    _vad_conversation = types.RealtimeInputConfig(
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
            state["_convo_nudge_sent"] = False  # Reset nudge flag
            # Clear resume handle — don't inject deep_work context into conversations
            state["_session_resume_handle"] = None
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

        # Tell Godot we're connecting (before the connection attempt)
        _conn_ing_msg = json.dumps({"command": "CONNECTION_STATUS", "status": "connecting"})
        for ws_client in list(state["connected_ws_clients"]):
            try:
                await ws_client.send(_conn_ing_msg)
            except Exception:
                pass

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
            realtime_input_config=_vad_deep_work,
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
            realtime_input_config=_vad_conversation,
            context_window_compression=types.ContextWindowCompressionConfig(
                sliding_window=types.SlidingWindow(),
            ),
            # NOTE: No tools, no thinking_config — native audio crashes with 1011
            #       when function calling is combined with some features
        )

        try:
            active_config = config_conversation if state["current_mode"] == "conversation" else config_deep_work
            async with cfg.client.aio.live.connect(model=MODEL, config=active_config) as session:

                # Capture whether we're resuming from a crash BEFORE resetting the counter
                state["_resuming_from_crash"] = _consecutive_failures > 0 and state.get("_crash_context") is not None
                _consecutive_failures = 0  # Connection succeeded → reset failure counter
                state["gemini_connected"] = True  # ← Gemini session is live
                state["_api_connections"] += 1
                state["_api_connect_time_start"] = time.time()
                update_display(TamaState.CALM, "Connected! Dis-moi bonjour !")
                # Tell Godot we're connected
                _conn_ok_msg = json.dumps({"command": "CONNECTION_STATUS", "status": "connected"})
                for ws_client in list(state["connected_ws_clients"]):
                    try:
                        await ws_client.send(_conn_ok_msg)
                    except Exception:
                        pass

                audio_out_queue = asyncio.Queue()
                audio_in_queue = asyncio.Queue(maxsize=5)  # Match official Google example

                state["force_speech"] = False
                state["_tama_is_speaking"] = False  # Track globally for echo cancellation

                # ── Conversation greeting: tell Tama to speak first ──
                if state["current_mode"] == "conversation":
                    state["_last_speech_ended"] = time.time()  # Init timer so nudge doesn't fire instantly
                    state["_convo_nudge_sent"] = False
                    greeting_text = (
                        "L'utilisateur vient de cliquer pour discuter avec toi. Salue-le naturellement !"
                        if state.get("language") != "en" else
                        "The user just clicked to chat with you. Greet them naturally!"
                    )
                    try:
                        await session.send_client_content(
                            turns=types.Content(
                                role="user",
                                parts=[types.Part(text=greeting_text)]
                            ),
                            turn_complete=True
                        )
                        print("  💬 Greeting prompt sent to Gemini")
                    except Exception as e:
                        print(f"  ⚠️ Failed to send greeting: {e}")

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

                    # ── Client-side audio gate ──
                    # Only send audio when voice is detected.
                    # Pre-buffer (ring buffer) captures ~500ms BEFORE voice so the
                    # first syllable isn't clipped. Post-tail keeps sending ~500ms
                    # AFTER voice stops to capture sentence endings.
                    from collections import deque
                    PRE_BUFFER_CHUNKS = 12   # ~768ms at 16kHz/1024 — captures context before speech
                    POST_TAIL_CHUNKS = 24    # ~1.5s after silence — keeps stream alive during natural pauses
                    pre_buffer = deque(maxlen=PRE_BUFFER_CHUNKS)
                    is_streaming = False
                    silence_count = 0
                    voice_streak = 0

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

                            # Gate: if mic is disabled, discard the data (keep stream alive but don't send)
                            if not state.get("mic_allowed", True):
                                await asyncio.sleep(0.01)
                                continue

                            voice_active = detect_voice_activity(data)
                            blob = types.Blob(data=data, mime_type="audio/pcm")

                            if voice_active:
                                voice_streak += 1
                                
                                # Require 3 consecutive chunks (~192ms) of voice to start streaming,
                                # OR if we are already streaming, keep streaming.
                                if is_streaming or voice_streak >= 3:
                                    state["user_spoke_at"] = time.time()
                                    silence_count = 0

                                    if not is_streaming:
                                        # Voice just started → flush pre-buffer first
                                        is_streaming = True
                                        # Track when user FIRST started speaking this turn
                                        # (not updated on every frame — gives true latency)
                                        if state.get("_user_speech_turn_start") is None:
                                            state["_user_speech_turn_start"] = time.time()
                                            print("  🎙️ User speaking...")
                                        for buffered in pre_buffer:
                                            await audio_in_queue.put(buffered)
                                        pre_buffer.clear()

                                        # Notify Godot: user is speaking → instant local reaction
                                        if state["current_mode"] in ("conversation", "deep_work"):
                                            _last_ack = state.get("_last_user_speaking_ack", 0)
                                            if time.time() - _last_ack > 3.0:  # 3s cooldown
                                                state["_last_user_speaking_ack"] = time.time()
                                                ack_msg = json.dumps({"command": "USER_SPEAKING"})
                                                for ws_client in list(state["connected_ws_clients"]):
                                                    try:
                                                        main_loop = state["main_loop"]
                                                        if main_loop and main_loop.is_running():
                                                            asyncio.run_coroutine_threadsafe(ws_client.send(ack_msg), main_loop)
                                                    except Exception:
                                                        pass

                                    await audio_in_queue.put(blob)
                                else:
                                    # Still building streak, just buffer
                                    pre_buffer.append(blob)
                            else:
                                voice_streak = 0  # Reset streak on any silence
                                if is_streaming:
                                    # Post-tail: keep sending briefly after voice stops
                                    silence_count += 1
                                    await audio_in_queue.put(blob)
                                    if silence_count >= POST_TAIL_CHUNKS:
                                        is_streaming = False
                                        silence_count = 0
                                        if state.get("_user_speech_turn_start") is not None:
                                            print("  🤔 Gemini is thinking...")
                                else:
                                    # Silent — just buffer, don't send
                                    pre_buffer.append(blob)
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
                            state["_api_audio_chunks_sent"] += 1
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
                    elif state.get("_resuming_from_crash") and state.get("_crash_context"):
                        # Reconnection after crash → Tama acknowledges and resumes
                        ctx = state.pop("_crash_context")
                        state["_resuming_from_crash"] = False
                        await asyncio.sleep(1.5)
                        state["force_speech"] = True
                        try:
                            task_info = f"Il travaillait sur : '{ctx['task']}'." if ctx.get("task") else "Il n'avait pas encore défini de tâche."
                            window_info = ctx.get("window", "inconnue")
                            session_min = ctx.get("session_minutes", 0)
                            suspicion = ctx.get("suspicion", 0)

                            if state.get("language") == "en":
                                resume_msg = (
                                    f"[SYSTEM] You just CRASHED and reconnected. The user was in a deep work session for {session_min} minutes. "
                                    f"{task_info} Last active window: '{window_info}'. Suspicion was at {suspicion}/10. "
                                    f"Acknowledge the crash briefly and naturally (you 'zoned out', 'lost connection', 'blanked out' — stay in character). "
                                    f"Then resume: if they had a task, reference it. Keep it SHORT (1 sentence about the crash + 1 to resume). Don't apologize robotically."
                                )
                            else:
                                resume_msg = (
                                    f"[SYSTEM] Tu viens de CRASHER et tu t'es reconnectée. L'utilisateur était en session deep work depuis {session_min} minutes. "
                                    f"{task_info} Dernière fenêtre active : '{window_info}'. La suspicion était à {suspicion}/10. "
                                    f"Reconnais le crash brièvement et naturellement (tu as 'bugué', 'décroché', 'perdu le fil' — reste dans le perso). "
                                    f"Puis reprends : s'il avait une tâche, fais-y référence. Reste COURTE (1 phrase sur le crash + 1 pour reprendre). Pas d'excuses robotiques."
                                )
                            await session.send_realtime_input(text=resume_msg)
                            print(f"  🔄 Crash recovery: injected resume context (task={ctx.get('task')}, {session_min}min, S={suspicion})")
                        except Exception:
                            pass
                        await asyncio.sleep(3)
                        state["force_speech"] = False

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
                            # Check user speech, Tama speech end, AND active audio playback
                            # This prevents killing the conversation while Tama is mid-response
                            last_activity = max(
                                state["user_spoke_at"],
                                state.get("_last_speech_ended", 0),
                                state.get("_last_audio_play_time", 0),  # ← in case of long speech
                            )
                            someone_spoke_recently = (time.time() - last_activity) < CONVERSATION_SILENCE_TIMEOUT
                            time_in_conversation = time.time() - (state["conversation_start_time"] or time.time())

                            if not someone_spoke_recently and time_in_conversation > 10:
                                print("💬 Silence détecté — fin de la conversation.")
                                end_msg = json.dumps({"command": "END_CONVERSATION"})
                                for ws_client in list(state["connected_ws_clients"]):
                                    try:
                                        await ws_client.send(end_msg)
                                    except Exception:
                                        pass
                                state["current_mode"] = "libre"
                                raise RuntimeError("Conversation ended")

                            # (Nudge system removed — it was polluting Gemini's context
                            # and causing worse responses. Let Gemini + proactive_audio handle it.)

                            await asyncio.sleep(2.0)
                            continue

                        # ── Deep Work mode: full screen analysis ──
                        # Gate: if screen share is disabled, skip capture entirely
                        if not state.get("screen_share_allowed", True):
                            await asyncio.sleep(5.0)
                            continue

                        jpeg_bytes = await asyncio.to_thread(capture_all_screens)
                        blob = types.Blob(data=jpeg_bytes, mime_type="image/jpeg")

                        # Fire Flash-Lite pre-classification in parallel (non-blocking)
                        await asyncio.to_thread(refresh_window_cache)
                        active_title = get_cached_active_title()
                        open_win_titles = [w.title for w in get_cached_windows()]
                        lite_task = asyncio.create_task(
                            pre_classify(jpeg_bytes, active_title, open_win_titles, state.get("current_task"))
                        )

                        try:
                            await session.send_realtime_input(media=blob)
                            state["_api_screen_pulses"] += 1
                        except Exception:
                            print("⚠️  Video stream interrompu (session fermée)")
                            lite_task.cancel()
                            break

                        # Wait for Flash-Lite (max 2s — never block the scan loop)
                        try:
                            await asyncio.wait_for(lite_task, timeout=2.0)
                        except (asyncio.TimeoutError, Exception):
                            pass  # Graceful fallback: Live API handles it alone

                        if active_title != state["last_active_window_title"]:
                            state["last_active_window_title"] = active_title
                            state["active_window_start_time"] = time.time()

                        active_duration = int(time.time() - state["active_window_start_time"])

                        # ── Rich context signals (passive — Tama sees, decides if relevant) ──
                        now = time.time()

                        # Focus streak: continuous time at SANTE (alignment >= 0.8)
                        ali = state["current_alignment"]
                        if ali >= 0.8:
                            if state.get("_focus_streak_start") is None:
                                state["_focus_streak_start"] = now
                        else:
                            state["_focus_streak_start"] = None
                        focus_streak_min = int((now - state["_focus_streak_start"]) / 60) if state.get("_focus_streak_start") else 0

                        # Suspicion trend: compare to previous pulse
                        prev_si = state.get("_prev_suspicion", 0.0)
                        si = state["current_suspicion_index"]
                        if si > prev_si + 0.5:
                            s_trend = "↑"
                        elif si < prev_si - 0.5:
                            s_trend = "↓"
                        else:
                            s_trend = "→"
                        state["_prev_suspicion"] = si

                        # Activity shifts: count CATEGORY changes (not window switches) in last 10 min
                        cat = state["current_category"]
                        prev_cat = state.get("_prev_category", cat)
                        if cat != prev_cat:
                            shifts = state.get("_activity_shifts", [])
                            shifts.append(now)
                            state["_activity_shifts"] = shifts
                            state["_prev_category"] = cat
                        shifts_10min = len([t for t in state.get("_activity_shifts", []) if now - t < 600])
                        # Prune old entries
                        state["_activity_shifts"] = [t for t in state.get("_activity_shifts", []) if now - t < 600]

                        # AFK detection: no window change + no user speech for 3+ min
                        last_interaction = max(
                            state.get("active_window_start_time", now),
                            state.get("user_spoke_at", 0),
                            state.get("_last_speech_ended", 0),
                        )
                        afk_min = int((now - last_interaction) / 60)
                        afk_status = f"AFK {afk_min}min" if afk_min >= 3 else "active"

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
                            # STAGE 4 — STRIKE (S≥9 for >15s): EXECUTE the close
                            if state["suspicion_at_9_start"] and (time.time() - state["suspicion_at_9_start"] > 15):
                                speak_directive = "STRIKE: C'est le moment. Dis ta réplique finale de fermeture (courte, percutante, en français) ET appelle close_distracting_tab avec la fenêtre cible de open_windows."
                            # STAGE 3 — ULTIMATUM (S≥9 for >8s): Final warning
                            elif state["suspicion_at_9_start"] and (time.time() - state["suspicion_at_9_start"] > 8):
                                speak_directive = "ULTIMATUM: Dernier avertissement. Dis à l'utilisateur que tu vas fermer la fenêtre s'il ne réagit pas. Sois naturelle et dramatique. N'appelle PAS close_distracting_tab maintenant."
                            # STAGE 2 — WARNING (S≥6 for >8s): Verbal warning
                            elif state["suspicion_above_6_start"] and (time.time() - state["suspicion_above_6_start"] > 8):
                                speak_directive = "WARNING: L'utilisateur procrastine depuis trop longtemps. Dis-lui de retourner travailler. Sois directe et naturelle en français."
                            # STAGE 1 — SUSPICIOUS (S≥3 for >3s): First contact
                            elif state["suspicion_above_3_start"] and (time.time() - state["suspicion_above_3_start"] > 3):
                                speak_directive = "SUSPICIOUS: Tu vois l'utilisateur sur une appli. Fais UN commentaire court et CONTEXTUEL sur ce que tu vois à l'écran. Sois curieuse, pas encore en colère. Appelle aussi classify_screen."

                        task_info = f"scheduled_task: {state['current_task']}" if state["current_task"] else "scheduled_task: NOT SET (ask the user!)"
                        tama_state = state["current_tama_state"]

                        # Mood context (Phase 2) — tells Gemini how Tama feels
                        mood_ctx = get_mood_context(state.get("language", "fr"))

                        # Flash-Lite pre-classification hint (if available)
                        lite_hint = get_pre_classify_hint()

                        speech_cooldown_ok = (time.time() - state.get("_last_speech_ended", 0)) > 4.0
                        if tama_state == TamaState.CALM and audio_out_queue.empty() and speech_cooldown_ok:
                            # Time context — passive info Tama can reference naturally
                            now_str = time.strftime("%H:%M")
                            session_min = int((now - state["session_start_time"]) / 60) if state.get("session_start_time") else 0
                            total_min = state.get("session_duration_minutes", 50)
                            progress_pct = min(int(session_min / total_min * 100), 100) if total_min > 0 else 0
                            time_ctx = f"clock: {now_str} | session: {session_min}/{total_min}min ({progress_pct}%)"

                            # Rich signals
                            ctx_signals = f"focus: {focus_streak_min}min | S_trend: {s_trend} | status: {afk_status}"
                            if shifts_10min > 0:
                                ctx_signals += f" | activity_shifts_10min: {shifts_10min}"

                            system_text = f"[SYSTEM] {time_ctx} | {ctx_signals} | active_window: {active_title} | open_windows: {open_win_titles} | duration: {active_duration}s | S: {state['current_suspicion_index']:.1f} | A: {state['current_alignment']} | {task_info}. [MOOD] {mood_ctx}"
                            if lite_hint:
                                system_text += f" {lite_hint}"
                            system_text += f" — Call classify_screen + report_mood. {speak_directive}"
                            await session.send_realtime_input(text=system_text)

                        if state["current_suspicion_index"] <= 0:
                            pulse_delay = 12.0
                        elif state["current_suspicion_index"] <= 5:
                            pulse_delay = 7.0
                        elif state["current_suspicion_index"] <= 8:
                            pulse_delay = 5.0
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

                                if server and server.interrupted:
                                    print("  ⚡ Interrupted — user barged in")
                                    while not audio_out_queue.empty():
                                        audio_out_queue.get_nowait()
                                    is_speaking = False
                                    state["_tama_is_speaking"] = False
                                    continue

                                # ── Transcription logs: PROOF Google heard us ──
                                if server and hasattr(server, 'input_transcription') and server.input_transcription:
                                    txt = getattr(server.input_transcription, 'text', '')
                                    if txt and txt.strip():
                                        print(f"  👂 Google heard: \"{txt.strip()}\"")
                                if server and hasattr(server, 'output_transcription') and server.output_transcription:
                                    txt = getattr(server.output_transcription, 'text', '')
                                    if txt and txt.strip():
                                        print(f"  💬 Tama said: \"{txt.strip()}\"")

                                if server and server.model_turn:
                                    for part in server.model_turn.parts:
                                        if part.inline_data and isinstance(part.inline_data.data, bytes):
                                            if not is_speaking:
                                                # Fix 8: Measure response latency (from first word, not last)
                                                turn_start = state.get("_user_speech_turn_start")
                                                if turn_start:
                                                    latency = time.time() - turn_start
                                                    if 0.5 < latency < 60:
                                                        print(f"  ⏱️ Response latency: {latency:.1f}s")
                                                    state["_user_speech_turn_start"] = None  # Reset for next turn

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
                                                    state["_tama_is_speaking"] = True  # Fix 7
                                                    print("  🗣️ Tama starts speaking")
                                                    # Apply body animation now that speech is confirmed.
                                                    # Race condition fix: report_mood often arrives BEFORE the first
                                                    # audio chunk (is_speaking was still False when mood was received).
                                                    # So we check: if mood was already stored, apply it now.
                                                    if state.get("_mood_anim_set"):
                                                        # report_mood arrived before audio — apply stored mood
                                                        _m = state.get("_current_mood", "calm")
                                                        _i = state.get("_current_mood_intensity", 0.5)
                                                        send_mood_to_godot(_m, _i)
                                                    else:
                                                        # No mood yet — use wall_talk as safe fallback
                                                        send_anim_to_godot("Idle_wall_Talk", False)

                                            if is_speaking:
                                                audio_out_queue.put_nowait(part.inline_data.data)
                                                state["_api_audio_chunks_recv"] += 1

                                if server and server.turn_complete:
                                    if is_speaking:
                                        state["_last_speech_ended"] = time.time()
                                        si = state["current_suspicion_index"]
                                        # Don't hide Tama after speaking in conversation mode
                                        # She should stay visible for the whole chat
                                        if si < 3 and state["current_mode"] != "conversation":
                                            send_anim_to_godot("Idle_wall", False)
                                        # Reset mouth to neutral
                                        rest_msg = json.dumps({"command": "VISEME", "shape": "REST"})
                                        for ws_client in list(state["connected_ws_clients"]):
                                            try:
                                                main_loop = state["main_loop"]
                                                if main_loop and main_loop.is_running():
                                                    asyncio.run_coroutine_threadsafe(ws_client.send(rest_msg), main_loop)
                                            except Exception:
                                                pass
                                    is_speaking = False
                                    state["_tama_is_speaking"] = False  # Fix 7
                                    state["_mood_anim_set"] = False  # Reset for next speech turn
                                    print("  ✅ Tama done speaking")

                                if response.tool_call:
                                    try:
                                        for fc in response.tool_call.function_calls:
                                            state["_api_function_calls"] += 1
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

                                                # ── Confidence system: "l'inertie de la méfiance" ──
                                                # C modulates BOTH gain and decay of S.
                                                # Low trust → S rises faster AND decays slower.
                                                C = state.get("_confidence", 1.0)

                                                if delta < 0:
                                                    # Decay: ΔS = base × C
                                                    time_on_current = time.time() - state.get("active_window_start_time", time.time())

                                                    if time_on_current < 30 and state["current_suspicion_index"] > 1:
                                                        # Quick switch while suspicious → trust erodes
                                                        C = max(0.1, C - 0.15)
                                                    elif time_on_current >= 60:
                                                        # Sustained productive work → trust slowly recovers
                                                        C = min(1.0, C + 0.02)

                                                    state["_confidence"] = C
                                                    delta = delta * C
                                                elif delta > 0:
                                                    # Gain: ΔS = base × (1 + (1 - C))
                                                    # C=1.0 → ×1.0 (normal), C=0.1 → ×1.9 (hyper-nervous)
                                                    delta = delta * (1 + (1 - C))

                                                state["current_suspicion_index"] = max(0.0, min(10.0, state["current_suspicion_index"] + delta))

                                                # Track mood (Phase 2)
                                                if ali <= 0.0:
                                                    track_infraction()
                                                elif ali >= 1.0:
                                                    track_compliance()

                                                s_int = int(state["current_suspicion_index"])
                                                c_val = state.get("_confidence", 1.0)
                                                print(f"  🔍 S:{s_int}/10 | A:{ali} | Cat:{cat} | ΔS:{delta:+.1f} | C:{c_val:.2f} | Mood:{state.get('_mood_bias', 0):.1f} — {reason}")

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

                                                # Notify Godot: Tama just looked at the screen
                                                # She should visually glance toward it (intensity scales with suspicion)
                                                scan_msg = json.dumps({
                                                    "command": "SCREEN_SCAN",
                                                    "suspicion": round(state["current_suspicion_index"], 1),
                                                    "alignment": ali,
                                                    "category": cat
                                                })
                                                for ws_client in list(state["connected_ws_clients"]):
                                                    try:
                                                        main_loop = state["main_loop"]
                                                        if main_loop and main_loop.is_running():
                                                            asyncio.run_coroutine_threadsafe(ws_client.send(scan_msg), main_loop)
                                                    except Exception:
                                                        pass

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

                                                # Always send facial expression (UV swap eyes/mouth)
                                                # This is lightweight — doesn't make Tama appear/disappear
                                                mood_msg = json.dumps({"command": "TAMA_MOOD", "mood": mood, "intensity": intensity})
                                                main_loop = state["main_loop"]
                                                for ws_client in list(state["connected_ws_clients"]):
                                                    try:
                                                        if main_loop and main_loop.is_running():
                                                            asyncio.run_coroutine_threadsafe(ws_client.send(mood_msg), main_loop)
                                                    except Exception:
                                                        pass

                                                # Only change body animation if Tama is speaking
                                                # When muzzled (S<3, no audio), don't make her appear/disappear
                                                if is_speaking:
                                                    # AnimTree handles wall_talk vs standing logic.
                                                    # All moods go through — Godot decides the right anim.
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
                    try:
                        from viseme import detect_viseme
                    except ImportError as _imp_err:
                        print(f"⚠️ Viseme disabled: {_imp_err}")
                        detect_viseme = None
                    speaker = await asyncio.to_thread(
                        pya.open, format=FORMAT, channels=CHANNELS, rate=RECEIVE_SAMPLE_RATE, output=True,
                    )
                    last_viseme = "REST"
                    last_amp = 0.0
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

                            # Viseme detection — analyze chunk before playing
                            if detect_viseme is not None:
                                viseme, amplitude = detect_viseme(audio_data)
                                # Send if viseme changed OR amplitude shifted significantly
                                amp_delta = abs(amplitude - last_amp) if 'last_amp' in dir() else 1.0
                                if viseme != last_viseme or amp_delta > 0.15:
                                    viseme_msg = json.dumps({"command": "VISEME", "shape": viseme, "amp": round(float(amplitude), 2)})
                                    main_loop = state["main_loop"]
                                    for ws_client in list(state["connected_ws_clients"]):
                                        try:
                                            if main_loop and main_loop.is_running():
                                                asyncio.run_coroutine_threadsafe(ws_client.send(viseme_msg), main_loop)
                                        except Exception:
                                            pass
                                    last_viseme = viseme
                                    last_amp = amplitude

                            try:
                                await asyncio.to_thread(speaker.write, audio_data)
                                state["_last_audio_play_time"] = time.time()
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
            err_str = str(e)
            is_clean_conversation_end = "Conversation ended" in err_str or "Conversation stalled" in err_str

            # ── Conversation crash: notify Godot so Tama does bye animation ──
            if state["current_mode"] == "conversation" and not is_clean_conversation_end:
                print(f"  💥 Conversation crash! Notifying Godot...")
                end_msg = json.dumps({"command": "END_CONVERSATION"})
                for ws_client in list(state["connected_ws_clients"]):
                    try:
                        await ws_client.send(end_msg)
                    except Exception:
                        pass
                state["current_mode"] = "libre"  # ← Prevent infinite hang

            # ── Save crash context ONLY if Tama was audibly speaking ──
            # If she wasn't speaking, the user didn't notice anything — stay silent
            if not is_clean_conversation_end:
                last_audio = state.get("_last_audio_play_time", 0)
                was_speaking = (time.time() - last_audio) < 5.0 if last_audio > 0 else False
                if state["is_session_active"] and state["current_mode"] == "deep_work" and was_speaking:
                    session_min = int((time.time() - state["session_start_time"]) / 60) if state.get("session_start_time") else 0
                    state["_crash_context"] = {
                        "task": state.get("current_task"),
                        "window": state.get("last_active_window_title", "inconnue"),
                        "suspicion": round(state.get("current_suspicion_index", 0), 1),
                        "session_minutes": session_min,
                        "crash_time": time.time(),
                    }
                    print(f"  💾 Crash while speaking — context saved")
                else:
                    # Silent crash — user didn't notice, don't mention it
                    state.pop("_crash_context", None)
                    print(f"  🔇 Silent crash — user didn't notice, no recovery message")

            if is_clean_conversation_end:
                # Clean conversation end (silence timeout) — not a failure
                _consecutive_failures = 0
            else:
                _consecutive_failures += 1
                is_server_error = "1007" in err_str or "1008" in err_str or "1011" in err_str or "policy violation" in err_str.lower() or "internal error" in err_str.lower() or "invalid argument" in err_str.lower()

                if is_server_error:
                    # 1008 = stale resume handle, 1011 = internal server error
                    # Both require clearing the resume handle to avoid stale-handle loops
                    state["_session_resume_handle"] = None
                    if _consecutive_failures <= 2:
                        print(f"  ⚡ Connexion refusée — retry rapide #{_consecutive_failures}...")
                    else:
                        print(f"  ⚠️ Erreur serveur persistante ({_consecutive_failures}x) — backoff exponentiel...")
                else:
                    import traceback
                    print(f"\n❌ [ERROR] {e}")
                    traceback.print_exc()
        finally:
            state["gemini_connected"] = False  # ← Session ended (clean or crash)
            # Accumulate connection time
            if state["_api_connect_time_start"] > 0:
                state["_api_total_connect_secs"] += time.time() - state["_api_connect_time_start"]
                state["_api_connect_time_start"] = 0

        if not state["is_session_active"] and state["current_mode"] != "conversation":
            state["current_mode"] = "libre"

        if state["is_session_active"] or state["current_mode"] == "conversation":
            # Exponential backoff: 2s, 4s, 8s, 15s cap
            retry_delay = min(15.0, 2.0 * (2 ** min(_consecutive_failures - 1, 3)))
            print(f"🔄 Reconnexion dans {retry_delay:.0f}s... (tentative #{_consecutive_failures})")
            update_display(TamaState.CALM, f"Reconnexion... ({_consecutive_failures})")
            # Tell Godot we're reconnecting so it can show loading indicator
            _conn_msg = json.dumps({"command": "CONNECTION_STATUS", "status": "reconnecting", "attempt": _consecutive_failures, "delay": retry_delay})
            for ws_client in list(state["connected_ws_clients"]):
                try:
                    await ws_client.send(_conn_msg)
                except Exception:
                    pass
            await asyncio.sleep(retry_delay)
        else:
            _consecutive_failures = 0
