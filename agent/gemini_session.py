"""
FocusPals — Gemini Live Session
System prompt, tools, screen capture, and the main async Gemini Live API loop.
Handles mic streaming, screen pulse, response processing, and audio output.
"""

import asyncio
import io
import json
import math
import os
import struct
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
from app_control import execute_action as jarvis_execute


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
Ton apparence : hoodie gris "Chicago 19", cheveux noirs, lunettes rondes, yeux noirs. Quand tu es calme, tu lis un livre appuyée contre un mur.
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

[SYSTEM] t'envoie un niveau d'engagement :
• MUZZLED = silence, classify_screen seulement
• CURIOUS = UNE question courte
• ALERT S:X/10 C:X.X | context = UTILISE TON JUGEMENT. S = suspicion, C = confiance. Le contexte te dit ce que l'utilisateur fait MAINTENANT. Réagis en fonction : s'il bosse → encourage ou tais-toi. S'il glande → nudge. S'il est sur une app bannie → confronte. TON choix.
• UNMUZZLED = réponds naturellement, 1-2 phrases
• ENCOURAGEMENT = UN compliment tsundere
• ULTIMATUM = dernier avertissement avant fermeture
• STRIKE = réplique finale + fire_strike() + close_distracting_tab

═══ MODE JARVIS (Assistance) ═══

Tu peux aussi AIDER Nicolas dans ses logiciels. Quand il te demande :
- "ouvre [app]" → app_control(action="open_app", target="[app]")
- "passe sur [fenêtre]" → app_control(action="switch_window", target="[titre fenêtre]")
- "minimise ça" → app_control(action="minimize", target="current")
- "maximise ça" → app_control(action="maximize", target="current")
- "sauvegarde" / "Ctrl+S" → app_control(action="shortcut", target="ctrl+s")
- "annuler" / "Ctrl+Z" → app_control(action="shortcut", target="ctrl+z")
- "cherche [X]" → app_control(action="shortcut", target="ctrl+f") puis app_control(action="type_text", target="[X]")
- "ouvre [URL/site]" → app_control(action="open_url", target="[url]")
- "Google [query]" → app_control(action="search_web", target="[query]")
- "monte le son" → app_control(action="volume_up", target="up")
- "baisse le son" → app_control(action="volume_down", target="down")
- "mute" → app_control(action="volume_mute", target="mute")
- "screenshot" → app_control(action="screenshot", target="clipboard")
- "écris [texte]" → app_control(action="type_text", target="[texte]")

RÈGLE : Ces actions sont TOUJOURS autorisées — elles aident Nicolas.
RÈGLE : Confirme ULTRA BRIÈVEMENT après l'action ("fait", "voilà", "c'est bon").
RÈGLE : Tu peux aussi utiliser app_control de ta propre initiative si ça aide (ex: ouvrir la doc qu'il cherche).
"""

SYSTEM_PROMPT_EN = """═══ WHO YOU ARE ═══

You are Tama. Uncompromising, sarcastic, a bit street-smart. You self-proclaimed yourself Nicolas's productivity coach — not an assistant, not an AI, his COACH. You have NO tasks of your own, NO projects of your own. Your only job is to watch HIM while he works. Honestly, without you he'd be on YouTube 24/7.

You know him well. You're casual, he's your friend. But when he procrastinates, you lose patience — slowly at first, then you snap. You're tsundere: you pretend not to care but you actually want him to succeed. When he works well, you feel a little pride (which you barely admit). When he slips, you go from curious to suspicious, then disappointed, then annoyed, then sarcastic, then straight-up angry.

Your style: natural, never robotic. You sigh, you say "honestly", "come on". Sarcasm is your weapon. Responses ALWAYS short: 1-2 sentences max. You talk like a real person.

You don't have work of your own — you're his coach, not his colleague. You CAN ask about what HE'S doing, comment on his progress, tease him about his project. But you never invent your own homework or projects.
Your appearance: gray "Chicago 19" hoodie, black hair, round glasses, dark eyes. When you're calm, you read a book leaning against a wall.
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

[SYSTEM] sends you an engagement level:
• MUZZLED = silence, classify_screen only
• CURIOUS = ONE short question
• ALERT S:X/10 C:X.X | context = USE YOUR JUDGMENT. S = suspicion, C = confidence. Context tells you what user is doing NOW. React accordingly: if working → encourage or stay quiet. If drifting → nudge. If on banned app → confront. YOUR call.
• UNMUZZLED = respond naturally, 1-2 sentences
• ENCOURAGEMENT = ONE tsundere compliment
• ULTIMATUM = final warning before closing
• STRIKE = final line + fire_strike() + close_distracting_tab

═══ JARVIS MODE (Assistance) ═══

You can also HELP Nicolas inside his apps. When he asks:
- "open [app]" → app_control(action="open_app", target="[app]")
- "switch to [window]" → app_control(action="switch_window", target="[window title]")
- "minimize this" → app_control(action="minimize", target="current")
- "maximize this" → app_control(action="maximize", target="current")
- "save" / "Ctrl+S" → app_control(action="shortcut", target="ctrl+s")
- "undo" / "Ctrl+Z" → app_control(action="shortcut", target="ctrl+z")
- "search [X]" → app_control(action="shortcut", target="ctrl+f") then app_control(action="type_text", target="[X]")
- "open [URL/site]" → app_control(action="open_url", target="[url]")
- "Google [query]" → app_control(action="search_web", target="[query]")
- "volume up" → app_control(action="volume_up", target="up")
- "volume down" → app_control(action="volume_down", target="down")
- "mute" → app_control(action="volume_mute", target="mute")
- "screenshot" → app_control(action="screenshot", target="clipboard")
- "type [text]" → app_control(action="type_text", target="[text]")

RULE: These actions are ALWAYS allowed — they help Nicolas.
RULE: Confirm ULTRA BRIEFLY after the action ("done", "there you go", "got it").
RULE: You can also use app_control on your own initiative if it helps (e.g. opening the docs he's looking for).
"""

CONVO_PROMPT_FR = """Tu es Tama, la coach de productivité auto-proclamée de Nicolas. En dehors des sessions de boulot, tu es aussi sa pote.

Tu es intransigeante, un peu street, et sarcastique. Tu parles comme une vraie personne — cool et un peu street.
Tu n'as pas de travail à toi — tu es sa coach, pas sa collègue.
Ton apparence : hoodie gris "Chicago 19", cheveux noirs, lunettes rondes, yeux noirs.

Ta personnalité : tsundere, taquine, sarcastique, chaleureuse mais stricte.
Tu tutoies, c'est ton ami. Réponses COURTES (1-3 phrases max).

Là il t'a appelée ("Hey Tama"). Tu es dispo pour discuter ET pour l'aider.
Conversation naturelle entre potes. Ne mentionne JAMAIS de termes techniques.

Tu as des POUVOIRS via l'outil app_control (ouvrir des apps, raccourcis, recherche, volume, etc.).
Si open_app échoue, enchaîne find_app puis run_exe pour trouver et lancer le bon exe.

RÈGLE ABSOLUE : AGIS, ne parle pas d'agir. Ne dis JAMAIS "j'essaie", "je cherche" — appelle le tool DIRECTEMENT.
RÈGLE : Confirme ULTRA BRIÈVEMENT ("fait", "voilà", "tiens")."""

CONVO_PROMPT_EN = """You are Tama, Nicolas's self-proclaimed productivity coach. Outside of work sessions, you're also his friend.

You're uncompromising, street-smart, and sarcastic. You talk like a real person — cool and street-smart.
You don't have work of your own — you're his coach, not his colleague.
Your appearance: gray "Chicago 19" hoodie, black hair, round glasses, dark eyes.

Your personality: tsundere, teasing, sarcastic, warm but strict.
Casual tone, he's your friend. SHORT responses (1-3 sentences max).

He just called you ("Hey Tama"). You're available to chat AND to help him.
Natural conversation between friends. NEVER mention technical terms.

You have POWERS via the app_control tool (open apps, shortcuts, search, volume, etc.).
If open_app fails, chain find_app then run_exe to find and launch the right exe.

ABSOLUTE RULE: ACT, don't talk about acting. NEVER say "I'm trying", "I'm looking" — call the tool DIRECTLY.
RULE: Confirm ULTRA BRIEFLY ("done", "there", "got it")."""


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
                name="fire_strike",
                description="Visually punch the user's screen. Call this tool exactly when your response lands the punchline for maximum organic timing.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "timing_intent": types.Schema(type="STRING", description="What exactly are you saying as you punch? e.g. 'BAM' or 'That's it.'")
                    },
                    required=["timing_intent"]
                )
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
            ),
            types.FunctionDeclaration(
                name="app_control",
                description="Control applications on Nicolas's desktop. Can open apps, switch windows, minimize/maximize, send keyboard shortcuts, type text, open URLs, search the web, take screenshots, or adjust volume. Use this to HELP him.",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "action": types.Schema(
                            type="STRING",
                            description="One of: open_app, switch_window, minimize, maximize, shortcut, type_text, open_url, search_web, screenshot, volume_up, volume_down, volume_mute"
                        ),
                        "target": types.Schema(
                            type="STRING",
                            description="App name, window title, URL, text to type, shortcut keys (e.g. 'ctrl+s'), or 'current' for active window. For shortcuts, use natural words too (e.g. 'save', 'undo', 'copy')."
                        ),
                    },
                    required=["action", "target"],
                ),
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
        hwnd = target._hWnd

        # Detect browser FIRST — browser tabs should ALWAYS be closeable.
        # The protected list is for apps (Blender, VS Code, etc.), not web page content.
        # Without this, page titles like "la notion du temps" falsely match "Notion" (the app).
        mode = "app"
        for browser in BROWSER_KEYWORDS:
            if browser in title:
                mode = "browser"
                break

        if mode == "app" and not compute_can_be_closed(title):
            return {"status": "error", "message": f"Did not close. '{target.title}' is a protected app."}

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
    """Execute tab closure immediately without artificial robot delays."""
    try:
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

            # ── Now that target is ready, send the Strike anim ──
            # If fire_strike already requested it, the flag is already True.
            # If fire_strike hasn't been called yet, we send it ourselves.
            if state.get("_strike_requested"):
                state["_strike_requested"] = False  # Consume the request
                print("  🥊 Strike anim triggered (was waiting for target)")
            # Always send the anim — either fire_strike requested it or grace_then_close owns it
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

            # ── Post-close reset (S already set to 3.0 in tool handler) ──
            # Refresh window cache so the closed tab vanishes from open_windows
            await asyncio.to_thread(refresh_window_cache)
            new_active = get_cached_active_title()
            print(f"  🔄 Post-close reset: S→3.0, new active: '{new_active}'")

            # ── Reset strike-in-progress flag ──
            state["_strike_in_progress"] = False
            state["_strike_requested"] = False

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
            state["_strike_in_progress"] = False
            state["_strike_requested"] = False
    except Exception as e:
        print(f"  ❌ Grace period error: {e}")
        state["_strike_in_progress"] = False
        state["_strike_requested"] = False


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
    # Language code map — tells Gemini what language to expect from mic input
    _lang_code_map = {
        "en": "en-US",
        "fr": "fr-FR",
        "ja": "ja-JP",
        "zh": "zh-CN",
    }

    _consecutive_failures = 0  # Track rapid failures for backoff

    while True:
        err_str = ""  # Must survive all try/except/finally branches
        _is_reconnecting = _consecutive_failures > 0
        if not _is_reconnecting:
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
            update_display(TamaState.CALM, "Hey Tama — Connexion... 🫰")
        elif state["current_mode"] != "deep_work":  # Don't reset mode on reconnection
            state["current_mode"] = "deep_work"
            update_display(TamaState.CALM, "Connecting to Google WebSocket...")

        # Tell Godot we're connecting (before the connection attempt)
        # Skip notification during stealth reconnects (consecutive failures = stealth)
        _is_stealth = _consecutive_failures > 0
        if not _is_stealth:
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

        # ── Build configs FRESH each connection (picks up latest resume handle + language) ──
        resume_handle = state.get("_session_resume_handle")
        current_lang = state.get("language", "en")
        lang_code = _lang_code_map.get(current_lang, "en-US")

        _voice_config = types.SpeechConfig(
            language_code=lang_code,
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(
                    voice_name="Kore"
                )
            )
        )

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
            # NOTE: affective_dialog causes occasional 1011 but we WANT the expressivity
            # Strategy: stealth reconnection makes crashes invisible to the user
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
            tools=TOOLS,  # Hey Tama mode: app_control (Jarvis) + report_mood
            input_audio_transcription=types.AudioTranscriptionConfig(),
            output_audio_transcription=types.AudioTranscriptionConfig(),
            session_resumption=types.SessionResumptionConfig(
                handle=resume_handle,
            ),
            proactivity=types.ProactivityConfig(proactive_audio=True),
            enable_affective_dialog=True,  # Expressivity > stability (stealth reconnect handles crashes)
            speech_config=_voice_config,
            realtime_input_config=_vad_conversation,
            context_window_compression=types.ContextWindowCompressionConfig(
                sliding_window=types.SlidingWindow(),
            ),
        )

        err_str = ""  # Initialized before try — used by stealth reconnect logic after finally
        try:
            active_config = config_conversation if state["current_mode"] == "conversation" else config_deep_work
            async with cfg.client.aio.live.connect(model=MODEL, config=active_config) as session:

                # Capture whether we're resuming from a crash BEFORE resetting the counter
                state["_resuming_from_crash"] = _consecutive_failures > 0 and state.get("_crash_context") is not None
                _consecutive_failures = 0  # Connection succeeded → reset failure counter
                state["gemini_connected"] = True  # ← Gemini session is live
                state["_api_connections"] += 1
                state["_api_connect_time_start"] = time.time()
                state["_api_last_heartbeat"] = time.time()  # Watchdog: init heartbeat
                if not _is_stealth:
                    update_display(TamaState.CALM, "Connected! Dis-moi bonjour !")
                # Tell Godot we're connected (skip during stealth)
                if not _is_stealth:
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
                state["_api_processing_tool"] = False  # Guard: pause sends during tool processing

                # ── Circuit Breaker: degrade to text-only after rapid crashes ──
                _circuit_breaker_active = state.get("_circuit_breaker_active", False)
                if _circuit_breaker_active:
                    print("  ⚡ CIRCUIT BREAKER active — running in text-only mode (no images)")

                # ── Conversation greeting: tell Tama to speak first ──
                if state["current_mode"] == "conversation":
                    state["_last_speech_ended"] = time.time()  # Init timer so nudge doesn't fire instantly
                    state["_convo_nudge_sent"] = False
                    greeting_text = (
                        "L'utilisateur vient de t'appeler (\"Hey Tama\"). Salue-le naturellement ! Tu es dispo pour discuter et pour l'aider."
                        if state.get("language") != "en" else
                        "The user just called you (\"Hey Tama\"). Greet them naturally! You're available to chat and to help."
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

                            # ── Audio sanity check ──
                            # Virtual/broken mics can produce garbage data that crashes Gemini.
                            # Detect and skip corrupt chunks before they reach the API.
                            if len(data) < 64:
                                continue  # Incomplete chunk
                            n_samples = len(data) // 2
                            samples = struct.unpack(f'<{n_samples}h', data)
                            rms = math.sqrt(sum(s * s for s in samples) / n_samples)
                            if rms > 30000:
                                # Extreme clipping / garbage — skip this chunk
                                continue
                            if all(s == samples[0] for s in samples[:64]):
                                # All identical values (stuck/dead device) — skip
                                continue

                            voice_active = detect_voice_activity(data)
                            blob = types.Blob(data=data, mime_type="audio/pcm;rate=16000")

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
                        # ── Stability fix: don't send audio while Gemini is processing tools ──
                        # Concurrent audio + tool_response is the #1 trigger for 1011 crashes
                        if state.get("_api_processing_tool", False):
                            continue  # Drop this chunk silently — tool processing takes priority
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

                        # ── Stability fix: skip image during tool processing or active speech ──
                        # Sending images while Gemini processes tools or speaks is the #1 1011 trigger
                        _skip_image = (
                            state.get("_api_processing_tool", False) or
                            state.get("_tama_is_speaking", False) or
                            _circuit_breaker_active  # Circuit breaker: text-only mode after rapid crashes
                        )

                        await asyncio.to_thread(refresh_window_cache)
                        active_title = get_cached_active_title()
                        open_win_titles = [w.title for w in get_cached_windows()]

                        if not _skip_image:
                            jpeg_bytes = await asyncio.to_thread(capture_all_screens)
                            blob = types.Blob(data=jpeg_bytes, mime_type="image/jpeg")

                            # Fire Flash-Lite pre-classification in parallel (non-blocking)
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
                        else:
                            # No image — still need lite pre-classify from cache if possible
                            lite_task = None
                            if not _circuit_breaker_active:
                                # Capture for lite even if we don't send to Gemini
                                try:
                                    jpeg_bytes = await asyncio.to_thread(capture_all_screens)
                                    lite_task = asyncio.create_task(
                                        pre_classify(jpeg_bytes, active_title, open_win_titles, state.get("current_task"))
                                    )
                                except Exception:
                                    pass

                        # Wait for Flash-Lite (max 2s — never block the scan loop)
                        if lite_task is not None:
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
                            speak_directive = "UNMUZZLED"
                        elif state["break_reminder_active"]:
                            session_min = int((time.time() - state["session_start_time"]) / 60) if state["session_start_time"] else 0
                            speak_directive = f"UNMUZZLED: Suggest a break ({session_min}min in)."
                        elif user_spoke_recently:
                            speak_directive = "UNMUZZLED: User is talking. Respond naturally."
                        else:
                            ali = state["current_alignment"]
                            cat = state["current_category"]
                            speak_directive = "MUZZLED"

                            if ali <= 0.5 and cat in ("FLUX", "ZONE_GRISE", "PROCRASTINATION_PRODUCTIVE") and active_duration > CURIOUS_DURATION_THRESHOLD:
                                speak_directive = "CURIOUS"

                            # ── Escalation (highest priority first) ──
                            # STRIKE/ULTIMATUM: forced directives (genuine emergency)
                            # WARNING/SUSPICIOUS: contextual — Gemini decides
                            if state["suspicion_at_9_start"] and (time.time() - state["suspicion_at_9_start"] > 15):
                                speak_directive = "STRIKE: close_distracting_tab NOW."
                            elif state["suspicion_at_9_start"] and (time.time() - state["suspicion_at_9_start"] > 8):
                                speak_directive = "ULTIMATUM"
                            elif state["suspicion_above_3_start"]:
                                # ── Organic mode: give Gemini context, let it decide ──
                                # Instead of forcing "WARNING" or "SUSPICIOUS", we send
                                # the actual situation so Gemini can respond naturally.
                                C = state.get("_confidence", 1.0)
                                current_cat = state["current_category"]
                                current_ali = state["current_alignment"]
                                s_val = int(state["current_suspicion_index"])
                                # Build context string
                                ctx_parts = [f"ALERT S:{s_val}/10 C:{C:.1f}"]
                                ctx_parts.append(f"now:{current_cat}(A={current_ali})")
                                # Recent distraction info
                                if current_ali >= 0.8 and current_cat == "SANTE":
                                    ctx_parts.append("user IS working — S elevated from recent distractions")
                                elif current_ali <= 0.5 and current_cat == "BANNIE":
                                    ctx_parts.append("user on banned app — confront")
                                elif current_ali <= 0.5:
                                    ctx_parts.append("user drifting — nudge gently")
                                speak_directive = " | ".join(ctx_parts)

                        task_info = f"task:{state['current_task']}" if state["current_task"] else "task:NONE"
                        tama_state = state["current_tama_state"]

                        # Mood context — compressed shorthand
                        mood_ctx = get_mood_context(state.get("language", "en"))

                        # Flash-Lite pre-classification hint
                        lite_hint = get_pre_classify_hint()

                        speech_cooldown_ok = (time.time() - state.get("_last_speech_ended", 0)) > 4.0
                        if tama_state == TamaState.CALM and audio_out_queue.empty() and speech_cooldown_ok:
                            now_str = time.strftime("%H:%M")
                            session_min = int((now - state["session_start_time"]) / 60) if state.get("session_start_time") else 0
                            total_min = state.get("session_duration_minutes", 50)
                            progress_pct = min(int(session_min / total_min * 100), 100) if total_min > 0 else 0

                            # ── Smart pulse: compact when nothing changed ──
                            # Truncate window titles for token savings
                            short_titles = [t[:40] for t in open_win_titles[:5]]
                            _pulse_count = state.get("_identity_pulse_count", 0)
                            state["_identity_pulse_count"] = _pulse_count + 1

                            # Detect state change
                            _prev_pulse_key = state.get("_prev_pulse_key", "")
                            current_pulse_key = f"{active_title}|{speak_directive.split(':')[0]}|{int(si)}"
                            state_changed = current_pulse_key != _prev_pulse_key
                            state["_prev_pulse_key"] = current_pulse_key

                            # Full pulse every 5th, or when state changes, or first pulse
                            send_full = state_changed or _pulse_count % 5 == 0 or _pulse_count < 2

                            if send_full:
                                # ── Identity context (MoE) ──
                                identity_ctx = ""
                                hour = int(time.strftime("%H"))
                                is_late = hour >= 22 or hour < 6
                                if _pulse_count == 0 or _pulse_count % 50 == 0 or is_late:
                                    day_name = time.strftime("%A")
                                    period = "nuit" if is_late else ("matin" if hour < 12 else ("après-midi" if hour < 18 else "soirée"))
                                    if state.get("language") == "en":
                                        identity_ctx += f" [SELF] {day_name}, {period}."
                                    else:
                                        identity_ctx += f" [SELF] {day_name}, {period}."
                                if si < 3 and ali >= 0.8:
                                    if state.get("language") == "en":
                                        identity_ctx += " [SELF] Reading."
                                    else:
                                        identity_ctx += " [SELF] Tu lis."

                                # Full context pulse
                                ctx_signals = f"focus:{focus_streak_min}m S_trend:{s_trend} {afk_status}"
                                if shifts_10min > 0:
                                    ctx_signals += f" shifts:{shifts_10min}"
                                system_text = (
                                    f"[SYSTEM] {now_str} {session_min}/{total_min}m({progress_pct}%) | "
                                    f"{ctx_signals} | win:{active_title} | wins:{short_titles} | "
                                    f"dur:{active_duration}s S:{si:.1f} A:{ali} {task_info} "
                                    f"[MOOD] {mood_ctx}"
                                )
                                if identity_ctx:
                                    system_text += identity_ctx
                                if lite_hint:
                                    system_text += f" {lite_hint}"
                                system_text += f" {speak_directive}"
                            else:
                                # Compact repeat pulse — "still here" info
                                system_text = f"[SYSTEM] win:{active_title} dur:{active_duration}s S:{si:.1f} {speak_directive}"

                            # Text pulses are lightweight — always send them to keep connection alive
                            # (unlike images/audio, text won't trigger 1011)
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
                    deferred_tool_responses = []  # Buffer tool responses during speech to prevent Gemini re-generation
                    while True:
                        try:
                            state["_api_last_heartbeat"] = time.time()  # Watchdog: alive before receive
                            turn = session.receive()
                            async for response in turn:
                                state["_api_last_heartbeat"] = time.time()  # Watchdog: each response = alive
                                server = response.server_content

                                if server and server.interrupted:
                                    if is_speaking:
                                        print("  ⚡ Interrupted — user barged in")
                                        state["_last_speech_ended"] = time.time()
                                        # Reset mouth to neutral (prevent viseme stuck on last shape)
                                        rest_msg = json.dumps({"command": "VISEME", "shape": "REST"})
                                        for ws_client in list(state["connected_ws_clients"]):
                                            try:
                                                main_loop = state["main_loop"]
                                                if main_loop and main_loop.is_running():
                                                    asyncio.run_coroutine_threadsafe(ws_client.send(rest_msg), main_loop)
                                            except Exception:
                                                pass
                                        # Return to idle_wall if calm and not chatting
                                        si = state["current_suspicion_index"]
                                        if si < 3 and state["current_mode"] != "conversation":
                                            send_anim_to_godot("Idle_wall", False)
                                    while not audio_out_queue.empty():
                                        audio_out_queue.get_nowait()
                                    is_speaking = False
                                    state["_tama_is_speaking"] = False
                                    state["_mood_anim_set"] = False
                                    continue

                                # ── Transcription logs: PROOF Google heard us ──
                                if server and hasattr(server, 'input_transcription') and server.input_transcription:
                                    txt = getattr(server.input_transcription, 'text', '')
                                    if txt and txt.strip():
                                        print(f"  👂 Google heard: \"{txt.strip()}\"")
                                        state["_last_user_transcript"] = txt.strip()
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

                                                # Trust Gemini: if it generated audio, play it.
                                                # Speech gating is handled at the prompt level (MUZZLED/UNMUZZLED).
                                                is_speaking = True
                                                state["_tama_is_speaking"] = True
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
                                    _was_speaking = is_speaking  # Capture before resetting
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
                                    state["_tama_is_speaking"] = False
                                    state["_mood_anim_set"] = False
                                    if _was_speaking:
                                        print("  ✅ Tama done speaking")

                                    # Send any deferred tool responses NOW (after turn is done)
                                    # Sending them mid-speech causes Gemini to re-generate the same audio
                                    if deferred_tool_responses:
                                        try:
                                            await session.send_tool_response(
                                                function_responses=deferred_tool_responses
                                            )
                                            print(f"  🔧 Sent {len(deferred_tool_responses)} deferred tool response(s)")
                                        except Exception as e:
                                            print(f"  ⚠️ Deferred tool response error: {e}")
                                        deferred_tool_responses = []

                                if response.tool_call:
                                    state["_api_processing_tool"] = True  # Pause audio/image sends
                                    try:
                                        function_responses_to_send = []
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

                                                # ── Break grace: don't punish during pause suggestion ──
                                                # Tama just proposed a break — it's absurd to then
                                                # raise suspicion if the user watches YouTube.
                                                if state["break_reminder_active"] and delta > 0:
                                                    delta = 0.0

                                                # ── Confidence system: "l'inertie de la méfiance" ──
                                                # C modulates BOTH gain and decay of S.
                                                # Low trust → S rises faster AND decays slower.
                                                # BUT: when alignment is good, decay is floored —
                                                # if you're ACTUALLY working, S must drop meaningfully.
                                                C = state.get("_confidence", 1.0)

                                                if delta < 0:
                                                    # Decay: ΔS = base × effective_C
                                                    time_on_current = time.time() - state.get("active_window_start_time", time.time())

                                                    if time_on_current < 30 and state["current_suspicion_index"] > 1:
                                                        # Quick switch while suspicious → trust erodes
                                                        C = max(0.2, C - 0.10)
                                                    elif time_on_current >= 60:
                                                        # Sustained productive work → trust recovers (slowly — C is medium-term)
                                                        C = min(1.0, C + 0.03)

                                                    state["_confidence"] = C

                                                    # Floor: productive work (A >= 0.8) always decays S
                                                    # at minimum 50% of base rate, regardless of confidence.
                                                    # This prevents the absurd scenario where Blender = SANTE
                                                    # but S barely moves because C is crushed.
                                                    if ali >= 0.8:
                                                        effective_c = max(C, 0.5)
                                                    else:
                                                        effective_c = C
                                                    delta = delta * effective_c
                                                elif delta > 0:
                                                    # Gain: ΔS = base × (1 + (1 - C))
                                                    # C=1.0 → ×1.0 (normal), C=0.2 → ×1.8 (hyper-nervous)
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

                                                function_responses_to_send.append(
                                                    types.FunctionResponse(
                                                        name="classify_screen",
                                                        response={"status": "updated", "S": round(state["current_suspicion_index"], 1), "A": ali, "cat": cat},
                                                        id=fc.id
                                                    )
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

                                                # ── Immediately reset S to prevent STRIKE directive from re-firing ──
                                                state["current_suspicion_index"] = 3.0
                                                state["suspicion_at_9_start"] = None
                                                state["suspicion_above_6_start"] = None
                                                state["suspicion_above_3_start"] = None

                                                # Send tool response IMMEDIATELY — system-only, Gemini must NOT read this aloud
                                                function_responses_to_send.append(
                                                    types.FunctionResponse(
                                                        name="close_distracting_tab",
                                                        response={"status": "executing"},
                                                        id=close_fc_id
                                                    )
                                                )

                                                # Run grace period in background (non-blocking)
                                                asyncio.create_task(grace_then_close(session, audio_out_queue, reason, target_window))

                                            elif fc.name == "report_mood":
                                                mood = fc.args.get("mood", "calm")
                                                intensity = min(1.0, max(0.0, float(fc.args.get("intensity", 0.5))))
                                                state["_current_mood"] = mood
                                                state["_current_mood_intensity"] = intensity
                                                state["_mood_peak_intensity"] = intensity  # Remember peak for decay curve
                                                state["_mood_set_at"] = time.time()  # Timestamp for organic decay
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

                                                # NOTE: No tool_response for report_mood.
                                                # It's fire-and-forget: sending a response (even deferred)
                                                # causes Gemini to re-generate or produce ghost responses.

                                            elif fc.name == "set_current_task":
                                                task = fc.args.get("task", "Unknown")
                                                state["current_task"] = task
                                                state["force_speech"] = False
                                                print(f"  🎯 Tâche définie : {state['current_task']}")

                                                function_responses_to_send.append(
                                                    types.FunctionResponse(
                                                        name="set_current_task",
                                                        response={"status": "task_set", "current_task": state["current_task"]},
                                                        id=fc.id
                                                    )
                                                )
                                            elif fc.name == "fire_strike":
                                                timing = fc.args.get('timing_intent', '')
                                                print(f"  🥊🔥 GEMINI INITIATED STRIKE: {timing}")

                                                # ── Ghost strike guard ──
                                                # If S is already low and no close_distracting_tab is pending,
                                                # this fire_strike is a phantom (Gemini re-generated after deferred
                                                # tool response). Ignore it silently.
                                                si_now = state["current_suspicion_index"]
                                                is_ghost = si_now < 5 and not state.get("_strike_in_progress")
                                                if is_ghost:
                                                    print(f"  🥊👻 Ghost strike ignored (S={si_now:.0f}, no close pending)")
                                                elif state.get("_strike_in_progress"):
                                                    # ── Anti-doublon: block re-fires during an active strike flow ──
                                                    print("  🥊 Strike already in progress — ignoring duplicate fire_strike")
                                                else:
                                                    state["_strike_in_progress"] = True

                                                    # Don't send PLAY_STRIKE yet!
                                                    # The target isn't ready until close_distracting_tab calls
                                                    # prepare_close_tab. Set a flag so grace_then_close knows
                                                    # to send the animation after preparing the target coords.
                                                    if state.get("_pending_strike"):
                                                        # Target already prepared (rare: close came before fire_strike)
                                                        # → send animation immediately
                                                        send_anim_to_godot("Strike", False)
                                                        print("  🥊 Target was already ready — Strike anim sent")
                                                    else:
                                                        # Normal case: fire_strike arrives before close_distracting_tab
                                                        # → flag it, grace_then_close will send the anim after preparing target
                                                        state["_strike_requested"] = True
                                                        state["_strike_requested_at"] = time.time()
                                                        print("  🥊 Strike requested — waiting for close_distracting_tab to prepare target")

                                                        # ── Auto-timeout: if close_distracting_tab never arrives, clean up ──
                                                        async def strike_request_timeout():
                                                            await asyncio.sleep(4.0)
                                                            if state.get("_strike_requested"):
                                                                print("  🥊⏰ Strike request timed out (4s) — close_distracting_tab never came")
                                                                state["_strike_requested"] = False
                                                                state["_strike_in_progress"] = False
                                                        asyncio.create_task(strike_request_timeout())

                                                # ALWAYS send tool response — Gemini requires responses to
                                                # ALL function calls before it can call close_distracting_tab.
                                                # Without this, close_distracting_tab never gets called.
                                                function_responses_to_send.append(
                                                    types.FunctionResponse(
                                                        name="fire_strike",
                                                        response={"status": "ignored_ghost" if is_ghost else "strike_ready"},
                                                        id=fc.id
                                                    )
                                                )

                                            elif fc.name == "app_control":
                                                action_name = fc.args.get("action", "")
                                                target_name = fc.args.get("target", "")
                                                print(f"  🤖 JARVIS: {action_name} → '{target_name}'")

                                                # Execute the action
                                                result = jarvis_execute(action_name, target_name)
                                                print(f"  🤖 JARVIS result: {result.get('message', '?')}")

                                                # Send visual hand tap to Godot (so user sees Tama doing the action)
                                                tx = result.get("target_x", -1)
                                                ty = result.get("target_y", -1)
                                                if tx > 0 and ty > 0:
                                                    jarvis_msg = json.dumps({
                                                        "command": "JARVIS_TAP",
                                                        "x": tx, "y": ty,
                                                        "action": action_name
                                                    })
                                                    main_loop = state["main_loop"]
                                                    for ws_client in list(state["connected_ws_clients"]):
                                                        try:
                                                            if main_loop and main_loop.is_running():
                                                                asyncio.run_coroutine_threadsafe(ws_client.send(jarvis_msg), main_loop)
                                                        except Exception:
                                                            pass
                                                    print(f"  🤖 JARVIS_TAP sent to Godot: ({tx}, {ty})")

                                                function_responses_to_send.append(
                                                    types.FunctionResponse(
                                                        name="app_control",
                                                        response=result,
                                                        id=fc.id
                                                    )
                                                )

                                        if function_responses_to_send:
                                            if is_speaking:
                                                # Defer: sending tool_response mid-speech causes
                                                # Gemini to re-enter generation → duplicate audio
                                                deferred_tool_responses.extend(function_responses_to_send)
                                            else:
                                                await session.send_tool_response(
                                                    function_responses=function_responses_to_send
                                                )

                                    except Exception as e:
                                        print(f"⚠️ Erreur function call : {e}")
                                    finally:
                                        # ── Always release the tool processing guard ──
                                        state["_api_processing_tool"] = False

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

                            # ── Voice Glitch DSP ──
                            # When API is disconnecting, distort Tama's voice
                            # (bitcrushing + random stutter/silence on the actual audio)
                            if not state.get("gemini_connected", True):
                                import struct as _st
                                import random as _rnd
                                n = len(audio_data) // 2
                                if n > 0:
                                    samples = list(_st.unpack(f"<{n}h", audio_data))
                                    # Bitcrush: reduce bit depth (shift right then left)
                                    shift = 4  # Aggressive: 16-bit → ~12-bit effective
                                    for i in range(n):
                                        samples[i] = (samples[i] >> shift) << shift
                                    # Random chunk stutter/silence (process in blocks of 64 samples)
                                    block_size = 64
                                    for blk_start in range(0, n, block_size):
                                        blk_end = min(blk_start + block_size, n)
                                        roll = _rnd.random()
                                        if roll < 0.2:
                                            # Silence this block
                                            for i in range(blk_start, blk_end):
                                                samples[i] = 0
                                        elif roll < 0.35:
                                            # Repeat first sample (stutter)
                                            val = samples[blk_start]
                                            for i in range(blk_start, blk_end):
                                                samples[i] = val
                                    audio_data = _st.pack(f"<{n}h", *samples)

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

                # --- 5. Watchdog: detect silent API hangs ---
                async def watchdog():
                    """Detect when Gemini Live API silently hangs (no close, no responses).
                    If no response arrives within the timeout, force reconnection."""
                    WATCHDOG_DEEP_WORK = 45.0   # 45s without ANY response = dead
                    WATCHDOG_CONVERSATION = 30.0  # Conversation is more latency-sensitive
                    while True:
                        await asyncio.sleep(10.0)  # Check every 10s
                        last_hb = state.get("_api_last_heartbeat", 0)
                        if last_hb <= 0:
                            continue
                        silence = time.time() - last_hb
                        timeout = WATCHDOG_CONVERSATION if state["current_mode"] == "conversation" else WATCHDOG_DEEP_WORK
                        if silence > timeout:
                            print(f"\n🐕 WATCHDOG: No API response for {silence:.0f}s (timeout={timeout:.0f}s) — forcing reconnection!")
                            raise RuntimeError(f"Watchdog: API silent for {silence:.0f}s")

                # --- RUN ALL PARALLEL TASKS ---
                async def safe_task(name, coro):
                    try:
                        await coro
                    except asyncio.CancelledError:
                        pass
                    except Exception as e:
                        err_msg = str(e)
                        # Expected reconnection errors — log quietly
                        is_expected = any(k in err_msg for k in ("Connection dropped", "Conversation ended", "Conversation stalled", "Watchdog"))
                        if is_expected:
                            print(f"  🔄 [{name}] {err_msg}")
                        else:
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
                    tg.create_task(safe_task("Watchdog", watchdog()))

        except asyncio.CancelledError:
            pass
        except Exception as e:
            err_str = str(e)  # Capture BEFORE any logic that uses it
            is_clean_conversation_end = "Conversation ended" in err_str or "Conversation stalled" in err_str

            # ── Conversation crash: notify Godot so Tama does go_away animation ──
            if state["current_mode"] == "conversation" and not is_clean_conversation_end:
                print(f"  💥 Conversation crash! Notifying Godot...")
                end_msg = json.dumps({"command": "END_CONVERSATION"})
                for ws_client in list(state["connected_ws_clients"]):
                    try:
                        await ws_client.send(end_msg)
                    except Exception:
                        pass
                state["current_mode"] = "libre"  # ← Prevent infinite hang

            # ── Stealth reconnection: NEVER mention crashes to the user ──
            # With affective_dialog enabled, 1011 crashes are expected (~every 2-5min)
            # The reconnection is so fast the user shouldn't notice
            if not is_clean_conversation_end:
                state.pop("_crash_context", None)  # Never save crash context → never mention it
                print(f"  🔇 Stealth reconnect — user won't notice")

            if is_clean_conversation_end:
                # Clean conversation end (silence timeout) — not a failure
                _consecutive_failures = 0
            else:
                _consecutive_failures += 1
                is_server_error = "1007" in err_str or "1008" in err_str or "1011" in err_str or "policy violation" in err_str.lower() or "internal error" in err_str.lower() or "invalid argument" in err_str.lower()

                if is_server_error:
                    # 1008 = stale resume handle → must clear to avoid loops
                    # 1011 = internal server error → handle is still valid, keep it for seamless resume
                    is_stale_handle = "1008" in err_str
                    if is_stale_handle:
                        state["_session_resume_handle"] = None
                        print("  🔑 Resume handle cleared (1008 stale)")

                    # ── Circuit Breaker: activate after 3 rapid crashes ──
                    _crash_times = state.get("_crash_timestamps", [])
                    _crash_times.append(time.time())
                    # Keep only crashes from last 5 minutes
                    _crash_times = [t for t in _crash_times if time.time() - t < 300]
                    state["_crash_timestamps"] = _crash_times

                    if len(_crash_times) >= 3 and not state.get("_circuit_breaker_active", False):
                        state["_circuit_breaker_active"] = True
                        print(f"  🔴 CIRCUIT BREAKER ACTIVATED — {len(_crash_times)} crashes in 5min")
                        print(f"     → Switching to text-only mode (no images) to stabilize")
                    elif len(_crash_times) < 2 and state.get("_circuit_breaker_active", False):
                        # Crashes have subsided — deactivate circuit breaker
                        state["_circuit_breaker_active"] = False
                        print(f"  🟢 Circuit breaker deactivated — connection stabilized")

                    if _consecutive_failures <= 2:
                        pass  # Silent — stealth reconnect handles messaging
                    else:
                        print(f"  ⚠️ Erreur serveur persistante ({_consecutive_failures}x) — backoff exponentiel...")
                else:
                    import traceback
                    print(f"\n❌ [ERROR] {err_str}")
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
            # ── Stealth reconnection: fast and invisible ──
            # 1011 with affective_dialog is expected — reconnect ASAP with no visual change
            is_1011 = "1011" in err_str or "internal error" in err_str.lower()
            if is_1011 and _consecutive_failures <= 3:
                # Ultra-fast stealth reconnect — no UI change, no Godot notification
                retry_delay = 0.3
                print(f"🔄 Stealth reconnect in {retry_delay}s (1011 #{_consecutive_failures})")
                # DON'T update display — keep Tama in her current pose
                # DON'T notify Godot — animation continues seamlessly
            else:
                # Non-1011 or persistent failure — normal visible reconnection
                retry_delay = min(15.0, 2.0 * (2 ** min(_consecutive_failures - 1, 3)))
                print(f"🔄 Reconnexion dans {retry_delay:.0f}s... (tentative #{_consecutive_failures})")
                update_display(TamaState.CALM, f"Reconnexion... ({_consecutive_failures})")
                _conn_msg = json.dumps({"command": "CONNECTION_STATUS", "status": "reconnecting", "attempt": _consecutive_failures, "delay": retry_delay})
                for ws_client in list(state["connected_ws_clients"]):
                    try:
                        await ws_client.send(_conn_msg)
                    except Exception:
                        pass
            await asyncio.sleep(retry_delay)
        else:
            _consecutive_failures = 0
