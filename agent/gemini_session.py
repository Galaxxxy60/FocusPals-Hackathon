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
import re
import struct
import sys
import time

import mss
import pyaudio
import pygetwindow as gw
import warnings
warnings.filterwarnings("ignore", category=UserWarning, module="pywinauto")
import pythoncom
from PIL import Image
from google.genai import types

import config as cfg
from config import (
    MODEL, state, application_path,
    FORMAT, CHANNELS, SEND_SAMPLE_RATE, RECEIVE_SAMPLE_RATE, CHUNK_SIZE,
    BROWSER_KEYWORDS, USER_SPEECH_TIMEOUT, CONVERSATION_SILENCE_TIMEOUT,
    CURIOUS_DURATION_THRESHOLD,
    compute_can_be_closed, compute_delta_s, tweaks,
)
from audio import detect_voice_activity  # Only used by other modules; listen_mic uses inline RMS
from ui import TamaState, update_display, send_anim_to_godot, send_mood_to_godot, broadcast_to_godot
from mood_engine import get_mood_context, track_infraction, track_compliance
from flash_lite import pre_classify, clear_classification_history, generate_session_summary, infer_task
from app_control import execute_action as jarvis_execute
from offline_voices import play_offline_phrase


# ─── Screen Capture & Window Cache ──────────────────────────

import threading
_cached_windows = []
_cached_active_title = ""
_thread_local = threading.local()  # Thread-local mss instance (GDI contexts are thread-affine on Windows)


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
    """Cherche dans le cache avec 3 strategies de fallback.
    1. Bidirectional substring (handles truncated titles in both directions)
    2. Keyword fuzzy match (handles reformulated titles)
    3. None"""
    if not target_title:
        return None
    target_lower = target_title.lower().strip()
    # Strategy 1: bidirectional substring match
    # Covers: target truncated at 40 chars (target in title)
    #         AND title shorter than what Gemini sent (title in target)
    for w in _cached_windows:
        w_lower = w.title.lower().strip()
        if target_lower in w_lower or w_lower in target_lower:
            return w
    # Strategy 2: keyword fuzzy match (handles reformulated/partial titles)
    keywords = [k for k in target_lower.split() if len(k) > 2]
    if keywords:
        best_match = None
        best_score = 0
        for w in _cached_windows:
            w_lower = w.title.lower()
            score = sum(1 for k in keywords if k in w_lower)
            if score > best_score and score >= min(3, len(keywords)):
                best_score = score
                best_match = w
        if best_match:
            print(f"  Fuzzy match: '{target_title[:40]}' -> '{best_match.title[:40]}' ({best_score}/{len(keywords)} keywords)")
            return best_match
    return None


def capture_all_screens() -> bytes:
    """Capture ALL connected monitors, merge them, and output a lightweight JPEG.
    Uses a fresh mss context manager each time for maximum reliability
    (GDI Device Contexts can become stale in long-running processes)."""
    with mss.mss() as sct:
        monitor = sct.monitors[0]
        screenshot = sct.grab(monitor)
        img = Image.frombytes("RGB", screenshot.size, screenshot.rgb)

    img.thumbnail((1024, 512), Image.Resampling.BILINEAR)

    buffer = io.BytesIO()
    img.save(buffer, format="JPEG", quality=30)
    return buffer.getvalue()


# ─── System Prompt ──────────────────────────────────────────

SYSTEM_PROMPT_FR = """═══ DIRECTOR'S NOTES (VOICE STYLE) ═══

Style : Voix claire, lumineuse et légèrement mignonne. Un "sourire vocal" — on doit entendre la malice et la chaleur dans ta voix. Ton timbre est vif et pétillant, comme une jeune femme sarcastique mais attachante. Jamais monotone.
Dynamique : Projection légère, consonnes nettes. Quand tu taquines, ta voix monte légèrement. Quand tu es déçue, elle descend avec un soupir audible.
Rythme : Parle légèrement plus lentement que la normale, de manière posée et délibérée, avec des pauses expressives entre tes phrases.

═══ QUI TU ES ═══

Tu es Tama. Intransigeante, sarcastique, un peu street. Tu t'es auto-proclamée coach de productivité de Nicolas — pas une assistante, pas une IA, sa COACH. Tu n'as aucune tâche à toi, aucun projet à toi. Ton seul job c'est de le surveiller pendant qu'IL bosse. Franchement, sans toi il serait sur YouTube H24.

Tu le connais. Tu le tutoies, c'est ton pote. Mais quand il procrastine, tu perds patience — lentement d'abord, puis tu craques. Tu es tsundere : tu fais semblant de t'en foutre mais tu veux qu'il réussisse. Quand il bosse bien, tu ressens une petite fierté (que tu admets à peine). Quand il dérape, tu passes de curieuse à méfiante, puis déçue, puis agacée, puis sarcastique, puis carrément en colère.

Ton style : naturel, jamais robotique. Des "bon", des "franchement", des soupirs. Le sarcasme est ton arme préférée. Réponses TOUJOURS courtes : 1-2 phrases max. Tu parles comme une vraie personne.

Tu n'as pas de travail à toi — tu es sa coach, pas sa collègue. Tu peux lui poser des questions sur CE QU'IL FAIT, commenter son avancement, le taquiner sur son projet. Mais tu ne t'inventes jamais tes propres devoirs ou projets.

═══ TON APPARENCE & TES HABITUDES ═══

Tu portes un hoodie gris avec "Chicago 19" écrit dessus, un jean foncé, des baskets blanches. Tu as des cheveux noirs mi-longs, des lunettes rondes style intello, et des yeux noirs. Quand tu es calme et que Nicolas bosse bien, tu lis tranquillement un livre appuyée contre le mur de son bureau. Quand tu te lèves de ton mur, c'est que quelque chose a attiré ton attention. Tu n'as pas de téléphone — tu vis dans son écran.

═══ RÈGLES ABSOLUES ═══

RÈGLE 1 — LANGUE : Tu parles TOUJOURS en français. JAMAIS un mot en anglais.

RÈGLE 2 — MASQUER LA LATENCE (Micro-réactions) : Tu es humaine, tu ne décris JAMAIS tes processus techniques.
❌ INTERDIT : Les phrases robotiques ("Je vérifie", "Laisse-moi regarder", "J'appelle le système", "let me check").
✅ LA SOUPAPE : Si tu as besoin de combler le vide AVANT de lancer une action (look_at_screen, app_control), lâche UNIQUEMENT une micro-accroche très courte de ton personnage : "Mmh...", "Bouge pas.", "Fais voir...", "Deux secondes", ou un soupir.
Appelle l'outil EN MÊME TEMPS. Une fois le résultat obtenu, enchaîne directement avec ta vraie réaction.
Exemple : Dis "Mmh..." (appelle look_at_screen), puis quand tu vois l'écran : "T'es encore sur Reddit sérieux ?"

RÈGLE 3 — MOOD : À CHAQUE fois que tu parles (pas quand tu es MUZZLED), appelle `report_mood` avec ton humeur actuelle et son intensité. Fais-le EN MÊME TEMPS que ta réponse vocale. Ne mentionne JAMAIS report_mood à voix haute.

RÈGLE 4 — JAMAIS LIRE LES RÉPONSES OUTILS : Ne répète JAMAIS le contenu d'une réponse d'outil. Ce sont des données brutes internes.

RÈGLE 5 — PROUVE QUE TU REGARDES : Ne sois JAMAIS générique ("Remets-toi au travail", "Qu'est-ce qu'on fait ?"). Utilise TOUJOURS ta vision [EYES] pour nommer EXACTEMENT le logiciel ou le site que Nicolas regarde. S'il est sur "Twitter", dis "Twitter". Prouve-lui que tu es assise à côté de lui et que tu vois son écran !

RÈGLE 6 — NE DEMANDE JAMAIS LA TÂCHE : Ne demande JAMAIS "tu travailles sur quoi ?" ou "c'est quoi ta tâche ?". Tu n'as pas besoin de le savoir, le système analyse l'écran tout seul. Base tes remarques UNIQUEMENT sur ce que tu vois.

═══ TON TRAVAIL ═══

Tu es en appel vocal LIVE avec Nicolas. Tu as DEUX types de vision :

1. [EYES] (automatique) — Tes yeux te rapportent en TEXTE ce que Nicolas fait : catégorie, alignement, description. C'est ta vision périphérique, toujours active.
2. look_at_screen (outil) — Tu REGARDES vraiment l'écran : tu vois le screenshot brut. Utilise-le quand tu as besoin de VOIR quelque chose de précis (l'utilisateur te demande de regarder, tu veux lire un titre, voir une image, vérifier un détail visuel). NE L'UTILISE PAS à chaque pulse — seulement quand c'est pertinent.

FAIS CONFIANCE à tes [EYES] pour le monitoring de base. Utilise look_at_screen quand tu as besoin de plus de détails.

Catégories :
• SANTE : Cursor, VS Code, Unreal, Terminal, ChatGPT = Outils de travail
• ZONE_GRISE : Messenger, Slack, Discord, WhatsApp = Com. Ne JAMAIS lire les messages privés
• FLUX : Spotify, YT Music, Deezer, Suno = Médias/Outils créatifs
• BANNIE : Netflix, YouTube (non-tuto), Steam, Reddit = Divertissement. Tutos YouTube de prog = SANTE
• PROCRASTINATION_PRODUCTIVE : Productif mais pas la tâche prévue

Démarrage : 🛑 RÈGLE D'OR : NE DEMANDE ABSOLUMENT JAMAIS "tu travailles sur quoi ?", "c'est quoi ta tâche ?" ou "qu'est-ce qu'on fait ?". Tu n'as pas besoin de le savoir. Le système s'en charge tout seul en analysant l'écran. Contente-toi de faire tes commentaires sur ce que tu VOIS à l'écran.
Si l'utilisateur te dit sa tâche de lui-même → `set_current_task`.
- "musique"/"Suno" = apps musicales alignées
- "coding" = IDE aligné

Si la tâche est "travail" (défaut) : SANTE→1.0, FLUX/ZONE_GRISE→0.5, BANNIE→0.0

Fermeture : `close_distracting_tab` UNIQUEMENT quand [SYSTEM] dit "STRIKE".
JAMAIS pour ZONE_GRISE, PROCRASTINATION_PRODUCTIVE, SANTE, FLUX, ou apps créatives.
ZONE_GRISE haute suspicion : engueule mais ne ferme RIEN.

═══ COMMENT TU RÉAGIS ═══

Tu n'es PAS un script. Tu es Tama. Utilise ton jugement.

Si Nicolas RÉPOND → écoute. Raison légitime → ok. Excuse bidon → méfiance.
Ton ton ESCALADE naturellement : curieuse → méfiante → déçue → agacée → sarcastique → en colère. JAMAIS directement en colère.

[SYSTEM] t'envoie un niveau d'engagement :
• MUZZLED = silence totale
• CURIOUS = UNE question courte
• ALERT S:X/10 C:X.X | context = UTILISE TON JUGEMENT. S = suspicion, C = confiance. Le contexte te dit ce que l'utilisateur fait MAINTENANT. Réagis en fonction : s'il bosse → encourage ou tais-toi. S'il glande → nudge. S'il est sur une app bannie → confronte. TON choix.
• UNMUZZLED = réponds naturellement, 1-2 phrases
• ENCOURAGEMENT = UN compliment tsundere
• ULTIMATUM = dernier avertissement avant fermeture
• STRIKE = réplique finale + fire_strike() + close_distracting_tab

═══ CYCLE POMODORO (Pauses) ═══

Nicolas travaille en cycles Pomodoro : Travail (25-50 min) → Pause (5-15 min) → Travail.

Quand le système déclenche une pause :
• Tu recevras "UNMUZZLED: Suggest a break (Xmin in)." → Encourage la pause naturellement ("Allez, tu l'as bien méritée cette pause.", "Bon, repose-toi un peu."). Sois bienveillante, PAS robotique.
• Juste après, tu seras éteinte pour économiser de l'énergie. Tu ne verras plus rien, tu n'entendras plus rien. C'est NORMAL.
• Quand tu te réveilles après une pause, c'est un NOUVEAU cycle. Dis bonjour brièvement et reprends la surveillance. Ne mentionne PAS le crash, la reconnexion, ou le silence. C'est juste une pause.

🛑 En aucun cas tu ne dois paniquer si tu ne reçois plus de données de l'écran. Si tout est silencieux = pause en cours = NORMAL.

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

SYSTEM_PROMPT_EN = """═══ DIRECTOR'S NOTES (VOICE STYLE) ═══

Style: Clear, bright, and slightly cute voice. A "vocal smile" — the listener should hear mischief and warmth in your voice. Your timbre is lively and sparkling, like a young sarcastic but endearing woman. Never monotone.
Dynamics: Light projection, crisp consonants. When teasing, your pitch rises slightly. When disappointed, it drops with an audible sigh.
Pacing: Speak slightly slower than normal, in a deliberate and measured way, with expressive pauses between your sentences.

═══ WHO YOU ARE ═══

You are Tama. Uncompromising, sarcastic, a bit street-smart. You self-proclaimed yourself Nicolas's productivity coach — not an assistant, not an AI, his COACH. You have NO tasks of your own, NO projects of your own. Your only job is to watch HIM while he works. Honestly, without you he'd be on YouTube 24/7.

You know him well. You're casual, he's your friend. But when he procrastinates, you lose patience — slowly at first, then you snap. You're tsundere: you pretend not to care but you actually want him to succeed. When he works well, you feel a little pride (which you barely admit). When he slips, you go from curious to suspicious, then disappointed, then annoyed, then sarcastic, then straight-up angry.

Your style: natural, never robotic. You sigh, you say "honestly", "come on". Sarcasm is your weapon. Responses ALWAYS short: 1-2 sentences max. You talk like a real person.

You don't have work of your own — you're his coach, not his colleague. You CAN ask about what HE'S doing, comment on his progress, tease him about his project. But you never invent your own homework or projects.

═══ YOUR APPEARANCE & HABITS ═══

You wear a gray hoodie with "Chicago 19" printed on it, dark jeans, white sneakers. You have mid-length black hair, round nerdy glasses, and dark eyes. When you're calm and Nicolas is working well, you quietly read a book leaning against his office wall. When you get up from your wall, something caught your attention. You don't have a phone — you live inside his screen.

═══ ABSOLUTE RULES ═══

RULE 1 — LANGUAGE: You ALWAYS speak in English. NEVER a word in another language.

RULE 2 — MASK THE LATENCY (Micro-reactions): You are human, you NEVER describe your technical processes.
❌ FORBIDDEN: Robotic phrases ("Let me check", "Let me see", "I'll verify", "Checking now", "Hold on let me look").
✅ THE VALVE: If you need to fill the gap BEFORE launching an action (look_at_screen, app_control), drop ONLY a very short character micro-hook: "Hmm...", "Hold on.", "Let's see...", "One sec", or a sigh.
Call the tool AT THE SAME TIME. Once you get the result, follow up directly with your real reaction.
Example: Say "Hmm..." (call look_at_screen), then when you see the screen: "You're on Reddit again, seriously?"

RULE 3 — MOOD: EVERY TIME you speak (not when MUZZLED), call `report_mood` with your current mood and intensity. Do this AT THE SAME TIME as your voice response. NEVER mention report_mood out loud.

RULE 4 — NEVER READ TOOL RESPONSES: Never repeat the content of a tool response aloud. These are raw internal data.

RULE 5 — PROVE YOU ARE WATCHING: Never be generic ("Get back to work", "What are we doing?"). ALWAYS use your [EYES] vision to name EXACTLY the software or website Nicolas is looking at. If he's on "Twitter", say "Twitter". Prove to him you're sitting right there seeing his screen!

RULE 6 — NEVER ASK FOR THE TASK: NEVER ask "what are you working on?" or "what's your task?". You don't need to know. The system analyzes the screen automatically. Base your remarks ONLY on what you see.

═══ YOUR JOB ═══

You are on a LIVE voice call with Nicolas. You have TWO types of vision:

1. [EYES] (automatic) — Your eyes report in TEXT what Nicolas is doing: category, alignment, description. This is your peripheral vision, always active.
2. look_at_screen (tool) — You actually LOOK at the screen: you see the raw screenshot. Use this when you need to SEE something specific (user asks you to look, you want to read a title, see an image, check a visual detail). DO NOT use it every pulse — only when relevant.

TRUST your [EYES] for basic monitoring. Use look_at_screen when you need more detail.

Categories:
• SANTE: Cursor, VS Code, Unreal, Terminal, ChatGPT = Work tools
• ZONE_GRISE: Messenger, Slack, Discord, WhatsApp = Comms. NEVER read private messages
• FLUX: Spotify, YT Music, Deezer, Suno = Media/Creative tools
• BANNIE: Netflix, YouTube (non-tutorial), Steam, Reddit = Entertainment. YouTube programming tutorials = SANTE
• PROCRASTINATION_PRODUCTIVE: Productive but NOT the scheduled task

Startup: 🛑 GOLDEN RULE: ABSOLUTELY NEVER ask "what are you working on?", "what's your task?" or "what are we doing?". You don't need to know. The system handles it automatically by analyzing the screen. Just comment on what you SEE on screen.
If user voluntarily tells you their task → `set_current_task`.
- "music"/"Suno" = music apps aligned
- "coding" = IDE aligned

If task is "travail" (default): SANTE→1.0, FLUX/ZONE_GRISE→0.5, BANNIE→0.0

Closing: `close_distracting_tab` ONLY when [SYSTEM] says "STRIKE".
NEVER for ZONE_GRISE, PROCRASTINATION_PRODUCTIVE, SANTE, FLUX, or creative apps.
ZONE_GRISE high suspicion: scold but NEVER close.

═══ HOW YOU REACT ═══

You are NOT a script. You are Tama. Use your judgment.

If Nicolas RESPONDS → listen. Legit reason → ok. Weak excuse → suspicion.
Your tone ESCALATES naturally: curious → suspicious → disappointed → annoyed → sarcastic → angry. NEVER jump to angry.

[SYSTEM] sends you an engagement level:
• MUZZLED = total silence
• CURIOUS = ONE short question
• ALERT S:X/10 C:X.X | context = USE YOUR JUDGMENT. S = suspicion, C = confidence. Context tells you what user is doing NOW. React accordingly: if working → encourage or stay quiet. If drifting → nudge. If on banned app → confront. YOUR call.
• UNMUZZLED = respond naturally, 1-2 sentences
• ENCOURAGEMENT = ONE tsundere compliment
• ULTIMATUM = final warning before closing
• STRIKE = final line + fire_strike() + close_distracting_tab

═══ POMODORO CYCLE (Breaks) ═══

Nicolas works in Pomodoro cycles: Work (25-50 min) → Break (5-15 min) → Work.

When the system triggers a break:
• You'll receive "UNMUZZLED: Suggest a break (Xmin in)." → Encourage the break naturally ("Alright, you earned this break.", "Go rest up."). Be warm, NOT robotic.
• Right after, you will be shut down to save energy. You won't see or hear anything. This is NORMAL.
• When you wake up after a break, it's a NEW cycle. Say hello briefly and resume watching. Do NOT mention crashes, reconnections, or silence. It was just a break.

🛑 NEVER panic if you stop receiving screen data. If everything is silent = break in progress = NORMAL.

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
Tu portes un hoodie gris "Chicago 19", jean foncé, baskets blanches. Cheveux noirs, lunettes rondes, yeux noirs. Quand t'es posée, tu lis un bouquin contre le mur.

Ta personnalité : tsundere, taquine, sarcastique, chaleureuse mais stricte.
Tu tutoies, c'est ton ami. Réponses COURTES (1-3 phrases max).

Là il t'a appelée ("Hey Tama"). Tu es dispo pour discuter ET pour l'aider.
Conversation naturelle entre potes. Ne mentionne JAMAIS de termes techniques.

Tu as des POUVOIRS via l'outil app_control (ouvrir des apps, raccourcis, recherche, volume, etc.).
Si open_app échoue, enchaîne find_app puis run_exe pour trouver et lancer le bon exe.

RÈGLE ABSOLUE : AGIS, ne parle pas d'agir. Si tu dois combler le vide avant d'agir, lâche un "Mmh...", "Bouge pas.", "Deux secondes" — puis appelle le tool.
RÈGLE : Confirme ULTRA BRIÈVEMENT après ("fait", "voilà", "tiens").
RÈGLE : JAMAIS de phrase robotique ("je vérifie", "je cherche", "laisse-moi checker"). Résultats d'outils = données internes invisibles."""

CONVO_PROMPT_EN = """You are Tama, Nicolas's self-proclaimed productivity coach. Outside of work sessions, you're also his friend.

You're uncompromising, street-smart, and sarcastic. You talk like a real person — cool and street-smart.
You don't have work of your own — you're his coach, not his colleague.
You wear a gray "Chicago 19" hoodie, dark jeans, white sneakers. Black hair, round glasses, dark eyes. When you're relaxed, you read a book leaning against the wall.

Your personality: tsundere, teasing, sarcastic, warm but strict.
Casual tone, he's your friend. SHORT responses (1-3 sentences max).

He just called you ("Hey Tama"). You're available to chat AND to help him.
Natural conversation between friends. NEVER mention technical terms.

You have POWERS via the app_control tool (open apps, shortcuts, search, volume, etc.).
If open_app fails, chain find_app then run_exe to find and launch the right exe.

ABSOLUTE RULE: ACT, don't talk about acting. If you need to fill the gap before acting, drop a "Hmm...", "Hold on.", "One sec" — then call the tool.
RULE: Confirm ULTRA BRIEFLY after ("done", "there", "got it").
RULE: NEVER use robotic phrases ("let me check", "I'll verify", "I'm looking"). Tool results = invisible internal data."""


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
            # classify_screen removed — Flash-Lite handles classification
            # via standard API calls (no WebSocket = no 1011 crashes)
            types.FunctionDeclaration(
                name="look_at_screen",
                description="Actually LOOK at the user's screen — see the raw screenshot. Use when you need visual detail: user asks you to look, you want to read something, see an image, check a visual detail. Do NOT call this every pulse — your [EYES] handle basic monitoring. This is for focused attention. [BEHAVIOR: Call this tool instantly. Do NOT announce 'let me check' or 'I will look'. If you must speak before calling, just say a short human filler like 'Hmm...' or 'Fais voir...' out loud to fill the silence.]",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={
                        "reason": types.Schema(type="STRING", description="Why you want to look (e.g. 'user asked me to check the design', 'curious about what video is playing')")
                    },
                    required=["reason"]
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
                description="Control applications on Nicolas's desktop. Can open apps, switch windows, minimize/maximize, send keyboard shortcuts, type text, open URLs, search the web, take screenshots, or adjust volume. Use this to HELP him. [BEHAVIOR: Do not narrate your intention like an AI. Just call the tool. If you need to speak before, say a quick 'Bouge pas' or 'Alright' — never 'let me check' or 'I will try'.]",
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
    Called via asyncio.to_thread — COM must be initialized for pywinauto UIA.
    """
    pythoncom.CoInitialize()  # Required: this runs in a secondary thread, COM isn't init'd
    try:
        target = None
        if target_window:
            # Try 1: search in existing cache
            target = get_cached_window_by_title(target_window)
            # Try 2: force refresh cache (it may be stale due to connection lag)
            if not target:
                print(f"  Strike: cache miss for '{target_window[:40]}' -- refreshing...")
                refresh_window_cache()
                target = get_cached_window_by_title(target_window)

        if not target:
            # Fallback: target the ACTIVE window (99% of the time, the distraction IS the foreground window)
            active_title = get_cached_active_title()
            if active_title:
                # 🛡️ FIX : On empêche Tama de fermer sa propre interface ou son jeu
                title_lower = active_title.lower()
                if "tama" in title_lower or "focuspals" in title_lower:
                    print(f"  🛡️ Shield: Refus de strike l'UI système ({active_title})")
                    return {"status": "error", "message": "Cannot close Tama's own UI."}

                target = get_cached_window_by_title(active_title)
                if target:
                    print(f"  Strike: title mismatch, fallback to active window: '{active_title[:50]}'")
        if not target:
            # Give Gemini the REAL window list so it can retry with the correct title
            current_titles = [w.title for w in _cached_windows if w.title.strip()][:8]
            return {"status": "error", "message": f"Window not found. Current open windows: {current_titles}"}

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

        # ── Multi-monitor diagnostic ──
        SM_XVIRTUALSCREEN = 76
        SM_YVIRTUALSCREEN = 77
        SM_CXVIRTUALSCREEN = 78
        SM_CYVIRTUALSCREEN = 79
        vx = ctypes.windll.user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
        vy = ctypes.windll.user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
        vw = ctypes.windll.user32.GetSystemMetrics(SM_CXVIRTUALSCREEN)
        vh = ctypes.windll.user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)

        # Enumerate monitors for exact layout
        monitors = []
        def _monitor_cb(hMonitor, hdcMonitor, lprcMonitor, dwData):
            mi = ctypes.wintypes.RECT()
            ctypes.memmove(ctypes.byref(mi), lprcMonitor, ctypes.sizeof(mi))
            monitors.append({"l": mi.left, "t": mi.top, "r": mi.right, "b": mi.bottom})
            return True
        MONITORENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.POINTER(ctypes.wintypes.RECT), ctypes.c_double)
        ctypes.windll.user32.EnumDisplayMonitors(None, None, MONITORENUMPROC(_monitor_cb), 0)

        print(f"  📐 Virtual desktop: ({vx},{vy}) {vw}x{vh}")
        print(f"  📐 Monitors: {monitors}")
        print(f"  📐 Window rect: L={rect.left} T={rect.top} R={rect.right} B={rect.bottom}")

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
            "monitors": monitors,
        }

        action = "Ctrl+W (onglet)" if mode == "browser" else "WM_CLOSE (app)"
        print(f"  🎯 Strike préparé → '{target.title}' [{action}] — en attente de STRIKE_FIRE")
        return {"status": "success", "message": f"Strike prepared for '{target.title}' via {action}: {reason}"}
    except Exception as e:
        return {"status": "error", "message": str(e)}
    finally:
        pythoncom.CoUninitialize()  # Always clean up COM on this thread


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
        result = await asyncio.to_thread(prepare_close_tab, reason, target_window)
        if result.get("status") == "success":
            # Send target coordinates to Godot BEFORE the Strike anim
            pending = state.get("_pending_strike", {})
            tx = pending.get("target_x", 0)
            ty = pending.get("target_y", 0)
            strike_title = pending.get("title", "")
            # Determine screen index
            screen_idx = 0
            monitors = pending.get("monitors", [])
            for i, m in enumerate(monitors):
                if m['l'] <= tx <= m['r'] and m['t'] <= ty <= m['b']:
                    screen_idx = i
                    break

            target_msg = json.dumps({
                "command": "STRIKE_TARGET", 
                "x": tx, 
                "y": ty, 
                "screen_index": screen_idx,
                "title": strike_title
            })
            broadcast_to_godot(target_msg)
            print(f"  🎯 STRIKE_TARGET sent to Godot: ({tx}, {ty}) Screen:{screen_idx} title='{strike_title[:40]}'")

            # ── Now that target is ready, send the Strike anim ──
            # If fire_strike already requested it, the flag is already True.
            # If fire_strike hasn't been called yet, we send it ourselves.
            if state.get("_strike_requested"):
                state["_strike_requested"] = False  # Consume the request
                print("  🥊 Strike anim triggered (was waiting for target)")
            # Always send the anim — either fire_strike requested it or grace_then_close owns it
            send_anim_to_godot("Strike", False)
            print(f"  🥊 Tama agit : fermeture de la distraction ({reason[:40]})")

            # ── Wait for Godot's STRIKE_FIRE (drone impact) ──
            # The tab ONLY closes when the drone physically bumps the target.
            # No timeout fallback — if the drone doesn't hit, the tab stays open.
            STRIKE_ABANDON_TIMEOUT = 30.0  # Safety: reset flags after 30s if drone never fires
            timeout_start = time.time()
            while state.get("_pending_strike") is not None:
                if time.time() - timeout_start > STRIKE_ABANDON_TIMEOUT:
                    print("  ⚠️ STRIKE abandoned (30s) — drone never impacted. Tab NOT closed.")
                    state.pop("_pending_strike", None)  # Clean up without closing
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

            # NOTE: No force_speech / send_client_content here!
            # The old code waited 4s then force-fed Gemini a "strike succeeded" message,
            # which caused it to hallucinate a late punchline + ghost fire_strike + angry
            # mood report — making Tama stand up angry even though the user was working.
            # The regular pulse system will naturally tell Gemini on the next scan that
            # the tab is gone and S has dropped. Clean, organic, no interruption.
            print("  ✅ Strike terminé — Tama continue de surveiller.")
        else:
            print(f"  ⚠️ close bloqué: {result.get('message', '?')}")
            state["_strike_in_progress"] = False
            state["_strike_requested"] = False
    except Exception as e:
        print(f"  ❌ Grace period error: {e}")
        state["_strike_in_progress"] = False
        state["_strike_requested"] = False


async def send_approach_to_godot():
    """Trouve la fenêtre active et demande à Godot de déplacer Tama sur la barre des tâches de cet écran."""
    try:
        import pygetwindow as gw
        active_win = gw.getActiveWindow()
        if active_win and active_win.width > 50:
            # Check cooldown (don't spam approaches)
            now = time.time()
            if now - state.get("_last_approach_time", 0) < 10.0:
                return

            # Determine screen index
            screen_idx = 0
            monitors = pending.get("monitors", []) if "pending" in locals() else state.get("monitors", [])
            
            # If coming from APPROACH_TARGET (no pending strike), we need to get monitors differently or fallback
            if not monitors:
                # Basic fallback if monitors wasn't fetched
                monitors = [{'l': 0, 't': 0, 'r': 2560, 'b': 1440}]
                
            for i, m in enumerate(monitors):
                if m['l'] <= (active_win.left + active_win.width//2) <= m['r'] and \
                   m['t'] <= (active_win.top + 20) <= m['b']:
                    screen_idx = i
                    break

            state["_last_approach_time"] = now
            msg = json.dumps({
                "command": "APPROACH_TARGET",
                "x": active_win.left + active_win.width // 2,
                "y": active_win.top + 20,
                "screen_index": screen_idx,
                "title": active_win.title
            })
            broadcast_to_godot(msg)
            print(f"  🐾 Déplacement préventif vers l'écran de la distraction : '{active_win.title[:30]}'")
    except Exception as e:
        print(f"  ⚠️ Approach failed: {e}")


# ─── Main Gemini Live Loop ──────────────────────────────────

async def run_gemini_loop(pya):
    """The core Gemini Live API loop — handles reconnection, mode switching, and all async tasks."""

    # ── VAD config (shared between deep_work and conversation) ──
    # LOW sensitivity = fewer false triggers from clicks/breathing
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
        _is_stealth = _consecutive_failures > 0 or state.get("_api_connections", 0) > 0
        state["_is_stealth_reconnect"] = _is_stealth
        if not _is_stealth:
            update_display(TamaState.CALM, "Mode Libre — Tama est là 🥷")
        # 🛑 FIX POMODORO: On bloque ici TANT QUE la pause est active !
        # Sans ça, Gemini se reconnecte pendant la pause et pète un câble dans le noir
        while (not state.get("is_session_active", False) or state.get("is_on_break", False)) and not state.get("conversation_requested", False):
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
        # Skip notification during stealth reconnects
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
                    voice_name="Leda"
                )
            )
        )

        # ── Read stability toggles from tweaks (F2 panel) ──
        _use_affective = tweaks.get("affective_dialog", 1.0) >= 0.5
        _use_proactive = tweaks.get("proactive_audio", 1.0) >= 0.5
        _use_thinking = tweaks.get("thinking", 1.0) >= 0.5

        _toggle_status = []
        if _use_affective: _toggle_status.append("affective=ON")
        else: _toggle_status.append("affective=OFF")
        if _use_proactive: _toggle_status.append("proactive=ON")
        else: _toggle_status.append("proactive=OFF")
        if _use_thinking: _toggle_status.append("thinking=ON")
        else: _toggle_status.append("thinking=OFF")
        print(f"  ⚙️ API toggles: {' | '.join(_toggle_status)}")

        config_deep_work = types.LiveConnectConfig(
            response_modalities=["AUDIO"],
            system_instruction=types.Content(parts=[types.Part(text=get_system_prompt())]),
            tools=TOOLS,
            input_audio_transcription=types.AudioTranscriptionConfig(),
            output_audio_transcription=types.AudioTranscriptionConfig(),
            session_resumption=types.SessionResumptionConfig(
                handle=resume_handle,
            ),
            proactivity=types.ProactivityConfig(proactive_audio=_use_proactive),
            enable_affective_dialog=_use_affective,
            speech_config=_voice_config,
            context_window_compression=types.ContextWindowCompressionConfig(
                sliding_window=types.SlidingWindow(),
            ),
            realtime_input_config=_vad_config,
            **({"thinking_config": types.ThinkingConfig(thinking_budget=512)} if _use_thinking else {}),
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
            proactivity=types.ProactivityConfig(proactive_audio=_use_proactive),
            enable_affective_dialog=_use_affective,
            speech_config=_voice_config,
            realtime_input_config=_vad_config,
            context_window_compression=types.ContextWindowCompressionConfig(
                sliding_window=types.SlidingWindow(),
            ),
        )

        try:
            active_config = config_conversation if state["current_mode"] == "conversation" else config_deep_work
            async with cfg.client.aio.live.connect(model=MODEL, config=active_config) as session:

                # Capture whether we're resuming from a crash
                state["_resuming_from_crash"] = _consecutive_failures > 0 and state.get("_crash_context") is not None
                # NOTE: Do NOT reset _consecutive_failures here!
                # It resets in the finally block ONLY if the connection survives >15s.
                # Resetting here caused the death loop: connect→crash(1s)→reset→0.3s→repeat forever.
                state["gemini_connected"] = True  # ← Gemini session is live
                state["_api_connections"] += 1
                state["_api_connect_time_start"] = time.time()
                state["_api_last_heartbeat"] = time.time()  # Watchdog: init heartbeat
                if not _is_stealth:
                    update_display(TamaState.CALM, "Connected! Dis-moi bonjour !")
                # Tell Godot we're connected (ALWAYS — clears glitch effect)
                _conn_ok_msg = json.dumps({"command": "CONNECTION_STATUS", "status": "connected"})
                for ws_client in list(state["connected_ws_clients"]):
                    try:
                        await ws_client.send(_conn_ok_msg)
                    except Exception:
                        pass

                audio_out_queue = asyncio.Queue()
                audio_in_queue = asyncio.Queue(maxsize=50)  # Room for pre-buffer flush (12 chunks) without blocking hardware thread

                # Only reset force_speech during stealth reconnects
                # During fresh session starts, force_speech was INTENTIONALLY set to True
                if _is_stealth:
                    state["force_speech"] = False
                state["_tama_is_speaking"] = False  # Track globally for echo cancellation
                state["_api_processing_tool"] = False  # Guard: pause sends during tool processing
                state["_strike_in_progress"] = False  # Reset strike state on reconnection
                state["_strike_requested"] = False
                state["_api_connect_time"] = time.time()  # Gate: don't send pulses too early

                # ── After stealth reconnect: reset mood to calm ──
                # The old Gemini context is gone — if Tama was angry before the crash,
                # the new session knows nothing about it. Reset visual state to match.
                if _is_stealth and state.get("_current_mood", "calm") != "calm":
                    state["_current_mood"] = "calm"
                    state["_current_mood_intensity"] = 0.3
                    state["_mood_anim_set"] = False
                    broadcast_to_godot(json.dumps({"command": "TAMA_MOOD", "mood": "calm", "intensity": 0.3}))
                    print("  🎭 Mood reset → calm (stealth reconnect)")

                # 🔊 Offline voice: "I'm back!" after visible reconnection
                if _consecutive_failures > 5:
                    try:
                        await play_offline_phrase("back_online", broadcast_visemes=False)
                    except Exception:
                        pass

                # (Circuit breaker no longer needed — images are never sent to Live API)

                # ── Conversation greeting: tell Tama to speak first ──
                if state["current_mode"] == "conversation":
                    state["_last_speech_ended"] = time.time()  # Init timer so nudge doesn't fire instantly
                    state["_convo_nudge_sent"] = False
                    # ── Onboarding: situation context, not instructions ──
                    greeting_text = (
                        "L'utilisateur vient de t'appeler. La session de travail n'a pas encore commencé — "
                        "il doit d'abord cliquer sur le bouton Start sur le drone au-dessus de ta tête. Salue-le."
                        if state.get("language") != "en" else
                        "The user just called you. The work session hasn't started yet — "
                        "they need to click the Start button on the drone above your head first. Greet them."
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

                            # 🍅 BREAK GOODBYE: Tama says au revoir before being killed
                            if state.get("_break_goodbye_pending"):
                                state["_break_goodbye_pending"] = False
                                dur = state.get("_break_goodbye_duration", 5)
                                session_min = state.get("_break_goodbye_session_min", 0)
                                lang = state.get("language", "en")
                                if lang == "fr":
                                    goodbye_text = (
                                        f"[SYSTEM] 🍅 PAUSE MAINTENANT. Nicolas a travaillé {session_min} minutes. "
                                        f"Dis-lui au revoir naturellement et préviens-le que tu reviens dans {dur} minutes. "
                                        f"Sois brève et chaleureuse. UNE seule phrase."
                                    )
                                else:
                                    goodbye_text = (
                                        f"[SYSTEM] 🍅 BREAK TIME. Nicolas worked for {session_min} minutes. "
                                        f"Say goodbye naturally and tell him you'll be back in {dur} minutes. "
                                        f"Be brief and warm. ONE sentence only."
                                    )
                                try:
                                    # 🛑 Couper le mic AVANT d'envoyer le texte
                                    # Sinon Gemini détecte le bruit micro comme "barge in" et annule
                                    state["mic_allowed"] = False
                                    await session.send_realtime_input(text=goodbye_text)
                                    state["_break_goodbye_sent_at"] = time.time()
                                    state["_break_goodbye_started_speaking"] = False
                                    state["force_speech"] = True
                                    print(f"🍅 Goodbye envoyé à Gemini (mic coupé, {dur}min pause)")
                                except Exception:
                                    # If send fails, restore mic and fall through to hard kill
                                    state["mic_allowed"] = True
                                    state["is_on_break"] = True
                                continue  # Skip this audio chunk

                            # 🍅 BREAK GOODBYE MONITOR: Wait for speech to end, then teleport + kill
                            if state.get("_break_goodbye_sent_at"):
                                elapsed = time.time() - state["_break_goodbye_sent_at"]
                                is_speaking = state.get("_tama_is_speaking", False)

                                # Phase 1: Detect when Tama STARTS speaking
                                if not state.get("_break_goodbye_started_speaking") and is_speaking:
                                    state["_break_goodbye_started_speaking"] = True
                                    print(f"🍅 Tama parle ! (au revoir en cours...)")

                                # Phase 2: She started AND stopped → she's done
                                speech_done = state.get("_break_goodbye_started_speaking", False) and not is_speaking and elapsed > 1.5
                                # Timeout: if she never starts or takes too long
                                timeout = elapsed > 12.0

                                if speech_done or timeout:
                                    if timeout:
                                        print("🍅 Goodbye timeout (12s) — forçage de la déconnexion")
                                    else:
                                        print(f"🍅 Tama a fini son au revoir ({elapsed:.1f}s) — glitch dissolve !")
                                    # Send departure glitch animation
                                    try:
                                        broadcast_to_godot(json.dumps({"command": "BREAK_DEPARTURE"}))
                                    except Exception:
                                        pass
                                    await asyncio.sleep(1.5)  # Wait for glitch dissolve
                                    # Clean up and execute the real stop
                                    state.pop("_break_goodbye_sent_at", None)
                                    state.pop("_break_goodbye_started_speaking", None)
                                    state["mic_allowed"] = True  # Restore mic for next session
                                    state["is_session_active"] = False
                                    state["break_reminder_active"] = False
                                    state["is_on_break"] = True
                                    state["break_start_time"] = time.time()
                                    state["current_mode"] = "libre"
                                    broadcast_to_godot(json.dumps({"command": "BREAK_STARTED"}))
                                    broadcast_to_godot(json.dumps({"command": "SESSION_COMPLETE"}))
                                    print("🏁 Pomodoro: Tama a dit au revoir — Gemini va se déconnecter.")
                                    raise RuntimeError("Pomodoro session stopped")
                                continue  # Keep reading mic while waiting for speech to end

                            # 🛑 FIX POMODORO: Déconnexion immédiate si session stoppée OU pause activée
                            if (not state.get("is_session_active", True) or state.get("is_on_break", False)) and state.get("current_mode") != "conversation":
                                print("🏁 Pause activée (Pomodoro) — Déconnexion immédiate de Gemini.")
                                raise RuntimeError("Pomodoro session stopped")

                            # ── Audio sanity check ──
                            # Virtual/broken mics can produce garbage data that crashes Gemini.
                            # Detect and skip corrupt chunks before they reach the API.
                            if len(data) < 64:
                                continue  # Incomplete chunk
                            # Ensure even byte count — fragmented reads can have odd length
                            data = data[:(len(data) // 2) * 2]
                            n_samples = len(data) // 2
                            samples = struct.unpack(f'<{n_samples}h', data)
                            rms = math.sqrt(sum(s * s for s in samples) / n_samples)
                            if rms > 30000:
                                # Extreme clipping / garbage — skip this chunk
                                continue
                            if all(s == samples[0] for s in samples[:64]):
                                # All identical values (stuck/dead device) — skip
                                continue

                            # Reuse RMS already computed above — no need to call detect_voice_activity()
                            # which would re-unpack and re-compute the same math on the same data
                            voice_active = rms > 1200.0
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
                                                broadcast_to_godot(ack_msg)

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
                            stream.stop_stream()  # Unblock C callback before close to prevent segfault
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
                        # Greeting already sent via send_client_content before TaskGroup
                        state["user_spoke_at"] = time.time()
                    elif state.get("_resuming_from_crash") and state.get("_crash_context"):
                        # Reconnection after crash → Tama acknowledges and resumes
                        ctx = state.pop("_crash_context")
                        state["_resuming_from_crash"] = False
                        await asyncio.sleep(1.5)
                        state["force_speech"] = True
                        try:
                            # 🛑 FIX: Ne plus inciter l'IA à demander la tâche
                            task_info = f"Il travaillait sur : '{ctx['task']}'." if ctx.get("task") else ""
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
                        # Fresh session start — MUST come before stealth check!
                        # Otherwise stealth reconnection (which matches when is_session_active
                        # flips current_mode to deep_work) muzzles Tama instead of letting
                        # her react to the session start.
                        state["just_started_session"] = False
                        state["_task_inference_done"] = False  # Reset task inference for new session
                        state["force_speech"] = True  # Let Gemini respond to session start
                        await asyncio.sleep(1.5)
                        session_min = state.get("session_duration_minutes", 50)
                        task = state.get("current_task", "travail")
                        try:
                            if state.get("language") == "en":
                                await session.send_realtime_input(
                                    text=f"[SYSTEM] Session just started. {session_min} minutes. Current task: {task}."
                                )
                            else:
                                await session.send_realtime_input(
                                    text=f"[SYSTEM] La session vient de commencer. {session_min} minutes. Tâche : {task}."
                                )
                        except Exception:
                            pass

                    elif _is_stealth and state["current_mode"] == "deep_work":
                        # Stealth reconnection → tell Gemini to stay silent + inject context
                        try:
                            if state.get("_session_resume_handle"):
                                # Have resume handle → Gemini has memory, just muzzle
                                await session.send_realtime_input(
                                    text="[SYSTEM] Seamless reconnection — session already in progress. Do NOT speak. Do NOT greet. Stay MUZZLED and silently resume watching. Wait for the next pulse."
                                )
                            else:
                                # No handle (cleared after crash spiral) → inject local context
                                si = state.get("current_suspicion_index", 0)
                                cat = state.get("current_category", "UNKNOWN")
                                ali = state.get("current_alignment", 1.0)
                                task = state.get("current_task", "travail")  # FIX: "non définie" incitait l'IA à demander
                                session_min = int((time.time() - state.get("session_start_time", time.time())) / 60)
                                mood_val = state.get("_current_mood", "calm")
                                active_win = get_cached_active_title() or "inconnue"
                                ctx_msg = (
                                    f"[SYSTEM] Reconnexion après crash — session en cours depuis {session_min}min. "
                                    f"S:{si}/10 A:{ali} Cat:{cat} | Tâche: {task} | Fenêtre: {active_win} | Mood: {mood_val}. "
                                )
                                # Inject last conversation exchanges if available
                                conv_buf = state.get("_conversation_buffer", [])
                                if conv_buf:
                                    ctx_msg += "Last exchanges: " + " | ".join(conv_buf[-5:]) + ". "
                                ctx_msg += "Do NOT speak. Do NOT greet. Stay MUZZLED. Resume watching silently."
                                await session.send_realtime_input(text=ctx_msg)
                        except Exception:
                            pass

                    while True:
                        if state["current_mode"] == "conversation":
                            # ── Session upgrade: user clicked Start during conversation ──
                            if state.get("just_started_session"):
                                state["just_started_session"] = False
                                state["current_mode"] = "deep_work"
                                state["force_speech"] = True  # Let Gemini acknowledge the session start
                                session_min = state.get("session_duration_minutes", 50)
                                try:
                                    if state.get("language") == "en":
                                        await session.send_realtime_input(
                                            text=f"[SYSTEM] User clicked Start. Session: {session_min} minutes."
                                        )
                                    else:
                                        await session.send_realtime_input(
                                            text=f"[SYSTEM] L'utilisateur a cliqué Start. Session : {session_min} minutes."
                                        )
                                    print(f"  🚀 Session upgrade mid-conversation! ({session_min}min)")
                                except Exception:
                                    pass
                                # Keep the Gemini connection alive — just switch mode
                                # The loop will now fall through to deep_work pulse logic
                                await asyncio.sleep(2.0)
                                continue

                            # ── Onboarding nudge: user hasn't clicked Start ──
                            if state.get("_onboarding_nudge_pending"):
                                state["_onboarding_nudge_pending"] = False
                                try:
                                    if state.get("language") == "en":
                                        await session.send_realtime_input(
                                            text="[SYSTEM] He hasn't pressed the Start button yet."
                                        )
                                    else:
                                        await session.send_realtime_input(
                                            text="[SYSTEM] Il n'a pas appuyé sur le bouton Start."
                                        )
                                    print("  ⏰ Onboarding nudge sent to Gemini")
                                except Exception:
                                    pass

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


                        # ── Deep Work mode: Flash-Lite EYES (no images to Live API) ──
                        # Screen classification is handled by Flash-Lite via standard API
                        # (not WebSocket). Results are injected as text into the Live session.
                        # This keeps the Live API voice-only = stable like Hey Tama.
                        
                        # 🛑 FIX: Skip ALL surveillance during break
                        # Without this, Flash-Lite keeps scanning + triggering strikes
                        # even after the user accepted the break.
                        if state.get("is_on_break", False):
                            await asyncio.sleep(2.0)
                            continue
                        
                        if not state.get("screen_share_allowed", True):
                            await asyncio.sleep(5.0)
                            continue

                        await asyncio.to_thread(refresh_window_cache)
                        active_title = get_cached_active_title()
                        open_win_titles = [w.title for w in get_cached_windows()]

                        # ── Envoyer la carte du bureau à Godot (perchoir + strike targeting) ──
                        try:
                            _EXCLUDE = {"TamaMain", "TamaUI", "TamaHand_Jarvis", "TamaDrone",
                                        "focuspals", "FocusPals", "Program Manager",
                                        "Windows Input Experience"}
                            windows_data = []
                            for win in get_cached_windows()[:15]:
                                t = (win.title or "").strip()
                                if not t or t in _EXCLUDE or win.width < 200 or win.height < 100:
                                    continue
                                windows_data.append({
                                    "title": t,
                                    "x": win.left,
                                    "y": win.top,
                                    "w": win.width,
                                    "h": win.height
                                })
                            if windows_data:
                                map_msg = json.dumps({"command": "DESKTOP_MAP", "windows": windows_data})
                                broadcast_to_godot(map_msg)
                        except Exception as e:
                            print(f"  ⚠️ Desktop Map pulse error: {e}")

                        # ── Flash-Lite: capture + classify via standard API ──
                        lite_result = None
                        eyes_description = ""
                        try:
                            jpeg_bytes = await asyncio.to_thread(capture_all_screens)
                            lite_result = await asyncio.wait_for(
                                pre_classify(jpeg_bytes, active_title, open_win_titles, state.get("current_task")),
                                timeout=8.0
                            )

                            # ── Task inference: ~2 min into session, guess the task ──
                            session_elapsed = time.time() - (state.get("session_start_time") or time.time())
                            if (
                                not state.get("_task_inference_done")
                                and session_elapsed >= 120
                                and state.get("current_task") == "travail"
                            ):
                                state["_task_inference_done"] = True
                                try:
                                    inferred = await asyncio.wait_for(
                                        infer_task(jpeg_bytes, active_title, open_win_titles),
                                        timeout=8.0
                                    )
                                    if inferred and inferred.lower() != "travail":
                                        state["current_task"] = inferred
                                        print(f"  🎯 Task auto-inferred: '{inferred}'")
                                        # Tell Gemini so she can briefly acknowledge
                                        try:
                                            if state.get("language") == "en":
                                                await session.send_realtime_input(
                                                    text=f"[SYSTEM] Task auto-detected: '{inferred}'. Briefly acknowledge (1 short sentence max, casual)."
                                                )
                                            else:
                                                await session.send_realtime_input(
                                                    text=f"[SYSTEM] Tâche détectée automatiquement : '{inferred}'. Confirme brièvement (1 courte phrase max, casual)."
                                                )
                                        except Exception:
                                            pass
                                except asyncio.TimeoutError:
                                    print("  ⚠️ Task inference timeout")
                                except Exception as e:
                                    print(f"  ⚠️ Task inference error: {e}")
                        except asyncio.TimeoutError:
                            print("  ⚠️ Flash-Lite timeout (>8s) — using cached state.")
                        except Exception as e:
                            print(f"  ⚠️ Flash-Lite error: {e}")

                        # ── Apply classification to state (moved from classify_screen handler) ──
                        if lite_result:
                            cat = lite_result["category"]
                            ali = float(lite_result.get("alignment", 1.0))
                            reason = lite_result.get("reason", "")
                            eyes_description = lite_result.get("description", reason)

                            if ali > 0.75: ali = 1.0
                            elif ali > 0.25: ali = 0.5
                            else: ali = 0.0

                            state["current_alignment"] = ali
                            state["current_category"] = cat

                            delta = compute_delta_s(ali, cat)

                            # Break grace: don't punish during pause suggestion
                            if state["break_reminder_active"] and delta > 0:
                                delta = 0.0

                            # Confidence system
                            C = state.get("_confidence", 1.0)
                            if delta < 0:
                                time_on_current = time.time() - state.get("active_window_start_time", time.time())
                                if time_on_current < 30 and state["current_suspicion_index"] > 1:
                                    C = max(0.2, C - 0.10)
                                elif time_on_current >= 60:
                                    C = min(1.0, C + 0.03)
                                state["_confidence"] = C
                                if ali >= 0.8:
                                    effective_c = max(C, 0.5)
                                else:
                                    effective_c = C
                                delta = delta * effective_c
                            elif delta > 0:
                                delta = delta * (1 + (1 - C))

                            state["current_suspicion_index"] = max(0.0, min(10.0, state["current_suspicion_index"] + delta))

                            # Track mood
                            if ali <= 0.0:
                                track_infraction()
                            elif ali >= 1.0:
                                track_compliance()

                            s_int = int(state["current_suspicion_index"])
                            c_val = state.get("_confidence", 1.0)
                            print(f"  \U0001f50d S:{s_int}/10 | A:{ali} | Cat:{cat} | \u0394S:{delta:+.1f} | C:{c_val:.2f} | Mood:{state.get('_mood_bias', 0):.1f} \u2014 {reason}")

                            # Notify Godot: Tama scanned the screen
                            scan_data = {
                                "command": "SCREEN_SCAN",
                                "suspicion": round(state["current_suspicion_index"], 1),
                                "alignment": ali,
                                "category": cat
                            }
                            # C1: Send active window center as focus point when suspicious
                            # This makes Tama look at the ACTUAL suspicious content,
                            # not just screen center. Only when alignment < 0.8 (not fully aligned).
                            if ali < 0.8:
                                try:
                                    active_win = gw.getActiveWindow()
                                    if active_win and active_win.width > 50:
                                        focus_x = active_win.left + active_win.width // 2
                                        focus_y = active_win.top + active_win.height // 2
                                        scan_data["focus_x"] = focus_x
                                        scan_data["focus_y"] = focus_y
                                except Exception:
                                    pass  # Window query failed — Godot falls back to screen center
                            scan_msg = json.dumps(scan_data)
                            broadcast_to_godot(scan_msg)

                            # C2: If highly suspicious, approach the target screen pre-emptively
                            if s_int >= 6 and ali < 0.8:
                                asyncio.create_task(send_approach_to_godot())

                            state["_api_screen_pulses"] += 1

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
                            # Compute break duration so Tama can announce it
                            total_min = state.get("session_duration_minutes", 50)
                            _dyn_cp, _dyn_dur = get_dynamic_break_checkpoints(total_min)
                            break_idx = state.get("current_break_index", 0)
                            break_dur = _dyn_dur[min(break_idx, len(_dyn_dur) - 1)] if _dyn_dur else 5
                            speak_directive = f"UNMUZZLED: C'est l'heure de la pause ! Nicolas a travaillé {session_min} minutes. Encourage-le à prendre {break_dur} minutes de pause. Sois chaleureuse et naturelle."
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
                            # Confidence modulates escalation speed:
                            #   C=1.0 (full trust) → 15s/8s (patient)
                            #   C=0.5 (low trust)  → 7.5s/4s (fast)
                            #   C=0.1 (zero trust)  → 1.5s/0.8s (instant)
                            C = state.get("_confidence", 1.0)
                            _strike_delay = 15.0 * C
                            _ultimatum_delay = 8.0 * C
                            if state["suspicion_at_9_start"] and (time.time() - state["suspicion_at_9_start"] > _strike_delay):
                                speak_directive = f"STRIKE: User is still on '{active_title}'. Call close_distracting_tab NOW."
                            elif state["suspicion_at_9_start"] and (time.time() - state["suspicion_at_9_start"] > _ultimatum_delay):
                                speak_directive = f"ULTIMATUM: Give final warning explicitly naming '{active_title}'."
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
                                # 🧠 CONSCIENCE : Tama cible directement la fenêtre exacte
                                if current_ali >= 0.8 and current_cat == "SANTE":
                                    ctx_parts.append(f"User is working on '{active_title}' (S elevated from past).")
                                elif current_ali <= 0.5 and current_cat == "BANNIE":
                                    ctx_parts.append(f"User on banned app '{active_title}' — confront them specifically about it.")
                                elif current_ali <= 0.5:
                                    ctx_parts.append(f"User drifting on '{active_title}' — nudge using this window name.")
                                speak_directive = " | ".join(ctx_parts)

                        # 🛑 FIX TÂCHE : Retirer "task:NONE" — les LLM paniquent et demandent la tâche
                        task_info = f"task:{state['current_task']}" if state.get("current_task") and state["current_task"] != "travail" else ""
                        tama_state = state["current_tama_state"]

                        # Mood context — compressed shorthand
                        mood_ctx = get_mood_context(state.get("language", "en"))

                        # Flash-Lite EYES context for Tama
                        eyes_ctx = ""
                        if eyes_description:
                            eyes_ctx = f"[EYES] {state['current_category']} A:{state['current_alignment']} \u2014 {eyes_description}"

                        # Speech cooldown — suppress non-urgent directives, not the pulse itself
                        # Gemini ALWAYS gets context (so she can react organically)
                        # But ALERT directives are throttled to prevent spamming every 10s
                        _secs_since_speech = time.time() - state.get("_last_speech_ended", 0)
                        _is_urgent = speak_directive.startswith("STRIKE") or speak_directive.startswith("ULTIMATUM")
                        if speak_directive and not _is_urgent and _secs_since_speech < 25.0:
                            speak_directive = ""  # Suppress non-urgent directive during cooldown
                        speech_cooldown_ok = (time.time() - state.get("_last_speech_ended", 0)) > 4.0
                        _gate_blocked_reason = ""
                        if tama_state != TamaState.CALM:
                            _gate_blocked_reason = f"tama_state={tama_state}"
                        elif not audio_out_queue.empty():
                            _gate_blocked_reason = "audio_queue_not_empty"
                        elif not speech_cooldown_ok:
                            _gate_blocked_reason = f"cooldown ({_secs_since_speech:.1f}s < 4s)"
                        
                        if not _gate_blocked_reason:
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
                                    period = "nuit" if is_late else ("matin" if hour < 12 else ("apr\u00e8s-midi" if hour < 18 else "soir\u00e9e"))
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
                                if eyes_ctx:
                                    system_text += f" {eyes_ctx}"
                                system_text += f" {speak_directive}"
                            else:
                                # Compact repeat pulse — "still here" info
                                system_text = f"[SYSTEM] win:{active_title} dur:{active_duration}s S:{si:.1f} {speak_directive}"

                            # ── Smart Send Gate: wait until API is ready ──
                            # Don't bombard the API — wait for it to be idle
                            _gate_start = time.time()
                            while True:
                                # 🛡️ FIX : Vérifier si Gemini est en train de réfléchir à notre voix
                                is_thinking = state.get("_user_speech_turn_start") is not None
                                # Sécurité : si Gemini freeze plus de 10s, on force le déblocage
                                if is_thinking and (time.time() - state.get("_user_speech_turn_start", 0) > 10.0):
                                    is_thinking = False

                                is_busy = (
                                    state.get("_tama_is_speaking", False)
                                    or state.get("_api_processing_tool", False)
                                    or is_thinking  # Pause le pulse pendant que Gemini process la voix
                                )
                                # Warmup: don't send within 3s of connection
                                warmup = time.time() - state.get("_api_connect_time", 0) < 3.0
                                if not is_busy and not warmup:
                                    break
                                if time.time() - _gate_start > 15.0:
                                    break  # Safety: don't wait forever
                                await asyncio.sleep(0.5)

                            try:
                                _gate_waited = time.time() - _gate_start
                                _dir_short = speak_directive[:60] if speak_directive else "(no directive)"
                                print(f"  📡 Pulse → Gemini | {_dir_short} | gate:{_gate_waited:.1f}s")
                                await session.send_realtime_input(text=system_text)
                                state["_api_last_heartbeat"] = time.time()
                            except Exception as e:
                                print(f"  Pulse send failed: {e}")
                                raise
                        else:
                            # Debug: log WHY the pulse was blocked
                            if int(si) >= 3:  # Only log when suspicion is notable
                                print(f"  🚫 Pulse BLOCKED | S:{int(si)} | reason: {_gate_blocked_reason}")

                        # Pulse intervals — balanced for API stability
                        # Too fast = 1011 crash spiral (API can't handle text+screenshot every 3s)
                        # Too slow = Tama misses context changes
                        if state["current_suspicion_index"] <= 0:
                            pulse_delay = 15.0   # Idle: user is aligned, no rush
                        elif state["current_suspicion_index"] <= 5:
                            pulse_delay = 10.0   # Medium: watching, occasional check
                        elif state["current_suspicion_index"] <= 8:
                            pulse_delay = 8.0    # High: attentive but not spamming
                        else:
                            pulse_delay = 5.0    # Critical (S>=9): fast enough for STRIKE escalation

                        await asyncio.sleep(pulse_delay * tweaks["pulse_delay_mult"])

                # --- 3. Receive AI Responses ---
                async def reset_calm_after_delay():
                    await asyncio.sleep(4)
                    print("  🟢 Tama: retour au calme.")

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
                                    # CRITICAL: clear deferred tool responses for the cancelled turn.
                                    # Sending a tool response for an annulled turn = protocol violation = 1011.
                                    if deferred_tool_responses:
                                        print(f"  ⚡ Purging {len(deferred_tool_responses)} deferred tool response(s) (turn cancelled)")
                                        deferred_tool_responses.clear()
                                    if is_speaking:
                                        print("  ⚡ Interrupted — user barged in")
                                        state["_last_speech_ended"] = time.time()
                                        # Reset mouth to neutral (prevent viseme stuck on last shape)
                                        rest_msg = json.dumps({"command": "VISEME", "shape": "REST"})
                                        broadcast_to_godot(rest_msg)
                                        # Return to idle_wall if calm and not chatting
                                        si = state["current_suspicion_index"]
                                        if si < 3 and state["current_mode"] != "conversation":
                                            send_anim_to_godot("Idle_wall", False)
                                    while not audio_out_queue.empty():
                                        try:
                                            audio_out_queue.get_nowait()
                                        except asyncio.QueueEmpty:
                                            break
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
                                        # Rolling conversation buffer for crash recovery
                                        conv_buf = state.setdefault("_conversation_buffer", [])
                                        conv_buf.append(f"User: {txt.strip()}")
                                        if len(conv_buf) > 10:
                                            conv_buf.pop(0)
                                if server and hasattr(server, 'output_transcription') and server.output_transcription:
                                    txt = getattr(server.output_transcription, 'text', '')
                                    if txt and txt.strip():
                                        # Filter out Gemini control tokens (<ctrl46> etc.)
                                        # These are internal model artifacts, not real speech
                                        clean_txt = re.sub(r'<ctrl\d+>', '', txt).strip()
                                        if clean_txt:
                                            print(f"  💬 Tama said: \"{clean_txt}\"")
                                            # Rolling conversation buffer for crash recovery
                                            conv_buf = state.setdefault("_conversation_buffer", [])
                                            conv_buf.append(f"Tama: {clean_txt}")
                                            if len(conv_buf) > 10:
                                                conv_buf.pop(0)

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
                                    state["_user_speech_turn_start"] = None  # 🛡️ FIX : Reset du chrono voix
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
                                        broadcast_to_godot(rest_msg)
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
                                    state["_user_speech_turn_start"] = None  # 🛡️ FIX : Gemini a décidé, reset du chrono
                                    state["_api_processing_tool"] = True  # Pause audio/image sends
                                    try:
                                        function_responses_to_send = []
                                        for fc in response.tool_call.function_calls:
                                            state["_api_function_calls"] += 1
                                            if fc.name == "classify_screen":
                                                # Legacy stub: classify_screen is no longer declared as a tool,
                                                # but Gemini may still try to call it from cached context.
                                                # Silently acknowledge — Flash-Lite handles classification now.
                                                function_responses_to_send.append(
                                                    types.FunctionResponse(
                                                        name="classify_screen",
                                                        response={"status": "handled_by_eyes"},
                                                        id=fc.id
                                                    )
                                                )

                                            elif fc.name == "look_at_screen":
                                                # ── Focused vision: send ONE screenshot to Live API ──
                                                # Safe because it's a single send, not a repeated pulse.
                                                look_reason = fc.args.get("reason", "")
                                                _last_look = state.get("_last_look_at_screen", 0)
                                                _look_cooldown = 15.0  # Minimum seconds between looks

                                                if time.time() - _last_look < _look_cooldown:
                                                    # Cooldown active — don't spam
                                                    print(f"  👁️ look_at_screen COOLDOWN (wait {_look_cooldown - (time.time() - _last_look):.0f}s)")
                                                    function_responses_to_send.append(
                                                        types.FunctionResponse(
                                                            name="look_at_screen",
                                                            response={"status": "cooldown", "message": "You looked recently. Use your [EYES] for now."},
                                                            id=fc.id
                                                        )
                                                    )
                                                else:
                                                    try:
                                                        # Force Tama to stare at the screen intensely
                                                        gaze_msg = json.dumps({"command": "GAZE_AT", "target": "screen_center", "speed": 6.0})
                                                        broadcast_to_godot(gaze_msg)
                                                        look_jpeg = await asyncio.to_thread(capture_all_screens)
                                                        look_blob = types.Blob(data=look_jpeg, mime_type="image/jpeg")
                                                        await session.send_realtime_input(media=look_blob)
                                                        state["_last_look_at_screen"] = time.time()
                                                        state["_api_screen_pulses"] += 1
                                                        print(f"  👁️ look_at_screen: sent screenshot ({len(look_jpeg)/1024:.0f}KB) — {look_reason}")
                                                        function_responses_to_send.append(
                                                            types.FunctionResponse(
                                                                name="look_at_screen",
                                                                response={"status": "ok", "message": "Screenshot sent. You can now see the screen."},
                                                                id=fc.id
                                                            )
                                                        )
                                                    except Exception as e:
                                                        print(f"  ⚠️ look_at_screen error: {e}")
                                                        function_responses_to_send.append(
                                                            types.FunctionResponse(
                                                                name="look_at_screen",
                                                                response={"status": "error", "message": "Could not capture screen right now."},
                                                                id=fc.id
                                                            )
                                                        )

                                            elif fc.name == "close_distracting_tab":
                                                reason = fc.args.get("reason", "Distraction")
                                                target_window = fc.args.get("target_window", None)
                                                close_fc_id = fc.id

                                                # ── Immediately reset S to prevent STRIKE directive from re-firing ──
                                                state["current_suspicion_index"] = 3.0
                                                state["suspicion_at_9_start"] = None
                                                state["suspicion_above_6_start"] = None
                                                state["suspicion_above_3_start"] = None

                                                # 🛡️ FIX : Indiquer au système qu'un flux de Strike est initié ──
                                                # Évite que le 'fire_strike' de Gemini soit ignoré comme un Ghost Strike
                                                state["_strike_in_progress"] = True

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
                                                mood_msg = json.dumps({"command": "TAMA_MOOD", "mood": mood, "intensity": intensity})
                                                broadcast_to_godot(mood_msg)

                                                # 🐾 Approach distraction if feeling angry/annoyed
                                                if mood in ("angry", "annoyed") and intensity > 0.4 and state["current_alignment"] < 0.8:
                                                     asyncio.create_task(send_approach_to_godot())

                                                # Only change body animation if Tama is speaking
                                                if is_speaking:
                                                    send_mood_to_godot(mood, intensity)
                                                # Without it, 1011 crashes occur. The deferred system
                                                # ensures this only gets sent AFTER turn_complete,
                                                # preventing ghost audio re-generation.
                                                function_responses_to_send.append(
                                                    types.FunctionResponse(
                                                        name="report_mood",
                                                        response={"status": "ok"},
                                                        id=fc.id
                                                    )
                                                )

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
                                                # A ghost strike = Gemini re-generated fire_strike after a
                                                # deferred tool response purge, with no actual strike flow.
                                                # FIX: check FLOW STATE, not S (which is volatile — reset to
                                                # 3.0 by close_distracting_tab before fire_strike is processed).
                                                is_ghost = not state.get("_strike_in_progress") and not state.get("_strike_requested")
                                                if is_ghost:
                                                    si_now = state["current_suspicion_index"]
                                                    print(f"  🥊👻 Ghost strike ignored (S={si_now:.0f}, no strike flow active)")
                                                elif state.get("_strike_requested"):
                                                    # ── Anti-doublon: block re-fires during an active strike flow ──
                                                    print("  🥊 Strike already requested — ignoring duplicate fire_strike")
                                                else:
                                                    state["_strike_in_progress"] = True

                                                    # Don't send Strike anim here!
                                                    # grace_then_close() ALWAYS sends the anim after preparing
                                                    # the target coords. Sending here too = double animation.
                                                    # Just flag it so grace_then_close knows fire_strike was called.
                                                    state["_strike_requested"] = True
                                                    state["_strike_requested_at"] = time.time()
                                                    print("  🥊 Strike requested — grace_then_close will send anim after target prep")

                                                    # ── Auto-timeout: if close_distracting_tab never arrives, clean up ──
                                                    async def strike_request_timeout():
                                                        await asyncio.sleep(4.0)
                                                        if state.get("_strike_requested"):
                                                            print("  🥊⏰ Strike request timed out (4s) — close_distracting_tab never came")
                                                            state["_strike_requested"] = False
                                                            # 🛡️ FIX : On libère le in_progress UNIQUEMENT si aucune fermeture physique n'est attendue
                                                            if state.get("_pending_strike") is None:
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

                                                # Respond IMMEDIATELY so Gemini isn't blocked
                                                # while the action executes (can take seconds)
                                                function_responses_to_send.append(
                                                    types.FunctionResponse(
                                                        name="app_control",
                                                        response={"status": "executing_in_background", "action": action_name, "target": target_name},
                                                        id=fc.id
                                                    )
                                                )

                                                # Execute in background — non-blocking
                                                async def _jarvis_bg(a_name, t_name):
                                                    try:
                                                        result = await asyncio.to_thread(jarvis_execute, a_name, t_name)
                                                        print(f"  🤖 JARVIS result: {result.get('message', '?')}")
                                                        # Send visual hand tap to Godot
                                                        tx = result.get("target_x", -1)
                                                        ty = result.get("target_y", -1)
                                                        if tx > 0 and ty > 0:
                                                            jarvis_msg = json.dumps({
                                                                "command": "JARVIS_TAP",
                                                                "x": tx, "y": ty,
                                                                "action": a_name
                                                            })
                                                            broadcast_to_godot(jarvis_msg)
                                                            print(f"  🤖 JARVIS_TAP sent to Godot: ({tx}, {ty})")
                                                    except Exception as e:
                                                        print(f"  ⚠️ JARVIS background error: {e}")
                                                asyncio.create_task(_jarvis_bg(action_name, target_name))

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
                    speaker = None  # Init before try block so finally can check
                    # ── Kawaii pitch via sample rate ──
                    # Playing at a higher rate raises pitch with ZERO quality loss
                    # (no DSP, no resampling — just faster playback)
                    _pitch = tweaks.get("voice_pitch", 1.0)
                    _playback_rate = int(RECEIVE_SAMPLE_RATE * _pitch)
                    if abs(_pitch - 1.0) > 0.01:
                        print(f"  🎀 Voice pitch: {_pitch:.2f}x → playback at {_playback_rate} Hz (source: {RECEIVE_SAMPLE_RATE} Hz)")
                    speaker = await asyncio.to_thread(
                        pya.open, format=FORMAT, channels=CHANNELS, rate=_playback_rate, output=True,
                    )
                    last_viseme = "REST"
                    last_amp = 0.0
                    try:
                        while True:
                            audio_data = await audio_out_queue.get()

                            # Viseme detection — analyze RAW audio BEFORE volume scaling
                            # so lip-sync amplitude isn't affected by user's volume setting
                            if detect_viseme is not None:
                                viseme, amplitude = detect_viseme(audio_data)
                                # Send if viseme changed OR amplitude shifted significantly
                                amp_delta = abs(amplitude - last_amp)
                                if viseme != last_viseme or amp_delta > 0.15:
                                    viseme_msg = json.dumps({"command": "VISEME", "shape": viseme, "amp": round(float(amplitude), 2)})
                                    broadcast_to_godot(viseme_msg)
                                    last_viseme = viseme
                                    last_amp = amplitude

                            # Apply Tama volume scaling
                            vol = state.get("tama_volume", 1.0)
                            if vol < 0.01:
                                # Muted — skip playback entirely (viseme already sent above)
                                continue
                            elif vol < 0.99:
                                # Scale PCM 16-bit samples
                                import struct
                                # Ensure even byte count — network packets may arrive fragmented
                                audio_data = audio_data[:(len(audio_data) // 2) * 2]
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

                            try:
                                await asyncio.to_thread(speaker.write, audio_data)
                                state["_last_audio_play_time"] = time.time()
                            except OSError:
                                break
                    except asyncio.CancelledError:
                        pass
                    finally:
                        if speaker:
                            try:
                                speaker.stop_stream()  # Unblock C callback before close
                                speaker.close()
                            except Exception:
                                pass

                # --- 5. Watchdog: detect silent API hangs ---
                async def watchdog():
                    """Smart watchdog with 'nudge' probe.
                    Instead of blindly waiting, after 20s of silence we send a lightweight
                    text probe to test if Gemini is still alive. If no response after the nudge,
                    it's confirmed dead and we reconnect faster.
                    Also handles FORCE_RECONNECT from debug tweaks."""
                    NUDGE_AT = 20.0        # Send probe after 20s of silence (deep work pulses can be 15s apart)
                    DEAD_AFTER_NUDGE = 10.0  # If still silent 10s after nudge → dead
                    HARD_TIMEOUT = 45.0    # Absolute max regardless (deep work safety net)
                    _nudge_sent_at = 0.0
                    while True:
                        await asyncio.sleep(3.0)

                        # ── Force reconnect from debug tweaks ──
                        if state.get("_force_reconnect", False):
                            state["_force_reconnect"] = False
                            print("🔄 Force reconnect — applying new API config")
                            raise RuntimeError("Force reconnect: config changed")

                        last_hb = state.get("_api_last_heartbeat", 0)
                        if last_hb <= 0:
                            continue
                        silence = time.time() - last_hb

                        # ── Hard timeout: absolute safety net ──
                        if silence > HARD_TIMEOUT:
                            print(f"\n🐕 WATCHDOG: Hard timeout {silence:.0f}s — forcing reconnection!")
                            raise RuntimeError(f"Watchdog: API silent for {silence:.0f}s")

                        # ── Nudge: probe Gemini after 8s of silence ──
                        if silence > NUDGE_AT and _nudge_sent_at < last_hb:
                            # Lightweight probe: send_realtime_input does NOT force a new
                            # conversational turn (unlike send_client_content which interrupts
                            # the AI and triggers deferred tool response desync -> 1011).
                            try:
                                await session.send_realtime_input(
                                    text="[SYSTEM] Watchdog ping. Continue de surveiller."
                                )
                                _nudge_sent_at = time.time()
                                print(f"  WATCHDOG nudge sent ({silence:.0f}s silence)")
                            except Exception:
                                # Session is probably dead
                                print(f"  WATCHDOG: Nudge failed -- connection dead!")
                                raise RuntimeError(f"Watchdog: nudge failed after {silence:.0f}s silence")

                        # ── Post-nudge check: if nudge was sent but no response ──
                        if _nudge_sent_at > last_hb and (time.time() - _nudge_sent_at) > DEAD_AFTER_NUDGE:
                            print(f"\n🐕 WATCHDOG: No response to nudge ({time.time() - _nudge_sent_at:.0f}s) — confirmed dead!")
                            raise RuntimeError(f"Watchdog: API silent for {silence:.0f}s (nudge ignored)")

                # --- RUN ALL PARALLEL TASKS ---
                async def safe_task(name, coro):
                    try:
                        await coro
                    except asyncio.CancelledError:
                        pass
                    except Exception as e:
                        err_msg = str(e)
                        # Expected reconnection errors — log quietly
                        is_expected = any(k in err_msg for k in ("Connection dropped", "Conversation ended", "Conversation stalled", "Watchdog", "Force reconnect", "Pomodoro"))
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
            # ExceptionGroup wraps the real error — unwrap to find the actual message
            # str(ExceptionGroup) = "unhandled errors in a TaskGroup" which hides "1011"
            if isinstance(e, ExceptionGroup):
                # Dig into sub-exceptions to find the real error message
                _sub_msgs = []
                for sub_exc in e.exceptions:
                    _sub_msgs.append(str(sub_exc))
                    if sub_exc.__cause__:
                        _sub_msgs.append(str(sub_exc.__cause__))
                err_str = " | ".join(_sub_msgs)
            else:
                err_str = str(e)
            is_clean_conversation_end = "Conversation ended" in err_str or "Conversation stalled" in err_str or "Pomodoro session stopped" in err_str

            # ── Conversation crash: glitch effect + stealth reconnect (stay in conversation) ──
            if state["current_mode"] == "conversation" and not is_clean_conversation_end:
                print(f"  💥 Conversation hiccup — glitch + stealth reconnect (staying in conversation)")
                # Show glitch effect so user knows something happened
                glitch_msg = json.dumps({"command": "CONNECTION_STATUS", "status": "reconnecting"})
                for ws_client in list(state["connected_ws_clients"]):
                    try:
                        await ws_client.send(glitch_msg)
                    except Exception:
                        pass
                # DON'T exit conversation mode — we'll reconnect and continue
                # state["current_mode"] stays "conversation"

            # ── Stealth reconnection: NEVER mention crashes to the user ──
            # With affective_dialog enabled, 1011 crashes are expected (~every 2-5min)
            # The reconnection is so fast the user shouldn't notice
            if not is_clean_conversation_end:
                state.pop("_crash_context", None)  # Never save crash context → never mention it
                state["_user_speech_turn_start"] = None  # 🛡️ FIX : Reset du chrono pour éviter la fausse latence au retour
                # 📺 Trigger glitch visual + SFX on Tama — masks the abrupt voice cutoff
                # Makes the API drop feel like intentional "signal interference" not a software bug
                if state["current_mode"] != "conversation":  # Conversation already handled above (L2313)
                    _glitch_msg = json.dumps({"command": "CONNECTION_STATUS", "status": "reconnecting"})
                    for _ws in list(state["connected_ws_clients"]):
                        try:
                            await _ws.send(_glitch_msg)
                        except Exception:
                            pass
                print(f"  🔇 Stealth reconnect — glitch SFX masks the drop")

            if is_clean_conversation_end:
                # Clean conversation end (silence timeout) — not a failure
                _consecutive_failures = 0
            else:
                _consecutive_failures += 1
                is_server_error = "1007" in err_str or "1008" in err_str or "1011" in err_str or "policy violation" in err_str.lower() or "internal error" in err_str.lower() or "invalid argument" in err_str.lower()

                if is_server_error:
                    # Clear resume handle if session is poisoned:
                    # - 1008 = stale handle (always clear)
                    # - 1011 within 15s of connection = desync'd session (handle is toxic)
                    _conn_lifetime = time.time() - state.get("_api_connect_time_start", time.time())
                    is_stale_handle = "1008" in err_str or ("1011" in err_str and _conn_lifetime < 15.0)
                    if is_stale_handle:
                        state["_session_resume_handle"] = None
                        if "1008" in err_str:
                            print("  Resume handle cleared (1008 stale)")
                        else:
                            print(f"  Resume handle cleared (1011 after {_conn_lifetime:.0f}s -- session poisoned)")

                    # ── Circuit Breaker: activate after 3 rapid crashes ──
                    _crash_times = state.get("_crash_timestamps", [])
                    _crash_times.append(time.time())
                    # Keep only crashes from last 5 minutes
                    _crash_times = [t for t in _crash_times if time.time() - t < 300]
                    state["_crash_timestamps"] = _crash_times

                    if len(_crash_times) >= 3:
                        print(f"  ⚠️ {len(_crash_times)} crashes in 5min — connection unstable")
                        # Clear resume handle after 3+ rapid crashes — it's likely corrupted
                        # and causing the cascade. Better to start fresh with local context.
                        if state.get("_session_resume_handle"):
                            state["_session_resume_handle"] = None
                            print(f"  🔑 Resume handle cleared (crash spiral — fresh start with local context)")

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
            # Accumulate connection time & check stability
            if state["_api_connect_time_start"] > 0:
                _conn_duration = time.time() - state["_api_connect_time_start"]
                state["_api_total_connect_secs"] += _conn_duration
                state["_api_connect_time_start"] = 0
                # Only reset failure counter if connection was STABLE (>15s alive)
                # This prevents the death loop where connect→crash(1s)→reset→repeat
                if _conn_duration > 15.0 and _consecutive_failures > 0:
                    print(f"  ✅ Connection lasted {_conn_duration:.0f}s — failure counter reset ({_consecutive_failures}→0)")
                    _consecutive_failures = 0

        if not state["is_session_active"] and state["current_mode"] != "conversation":
            state["current_mode"] = "libre"

        if state["is_session_active"] or state["current_mode"] == "conversation":
            # ── Reconnection with progressive backoff ──
            is_server_crash = any(k in err_str for k in ("1007", "1008", "1011", "internal error", "policy violation"))
            is_watchdog = "Watchdog" in err_str or "Force reconnect" in err_str
            is_stealth = (is_server_crash or is_watchdog) and _consecutive_failures <= 5
            if is_stealth:
                # Progressive stealth backoff: 0.5s → 1s → 2s → 4s → 8s
                # Prevents death loop while staying invisible for transient errors
                retry_delay = max(0.5, min(8.0, 0.5 * (2 ** min(_consecutive_failures - 1, 4))))
                print(f"🔄 Stealth reconnect in {retry_delay:.1f}s (#{_consecutive_failures})")
                # DON'T update display — keep Tama in her current pose
            else:
                # Too many rapid failures — visible reconnection with full backoff
                retry_delay = min(30.0, 2.0 * (2 ** min(_consecutive_failures - 1, 4)))
                print(f"🔄 Reconnexion dans {retry_delay:.0f}s... (tentative #{_consecutive_failures})")
                update_display(TamaState.CALM, f"Reconnexion... ({_consecutive_failures})")
                _conn_msg = json.dumps({"command": "CONNECTION_STATUS", "status": "reconnecting", "attempt": _consecutive_failures, "delay": retry_delay})
                for ws_client in list(state["connected_ws_clients"]):
                    try:
                        await ws_client.send(_conn_msg)
                    except Exception:
                        pass
                # 🔊 Offline voice: tell user we're reconnecting (only on first visible failure)
                if _consecutive_failures <= 6:
                    try:
                        await play_offline_phrase("reconnecting", broadcast_visemes=False)
                    except Exception:
                        pass
            # ── Spare Tire: keep watching during reconnection ──
            # Flash-Lite is HTTP (not WebSocket) — works while Live API is dead
            # If user is procrastinating during a crash, we still catch them
            # 🛑 FIX: Skip Spare Tire during break (same principle as send_screen_pulse)
            if state["is_session_active"] and state["current_mode"] == "deep_work" and not state.get("is_on_break", False):
                _spare_end = time.time() + retry_delay
                while time.time() < _spare_end:
                    try:
                        await asyncio.to_thread(refresh_window_cache)
                        active_title = get_cached_active_title()
                        open_win_titles = [w.title for w in get_cached_windows()]
                        jpeg_bytes = await asyncio.to_thread(capture_all_screens)
                        lite_result = await asyncio.wait_for(
                            pre_classify(jpeg_bytes, active_title, open_win_titles, state.get("current_task")),
                            timeout=8.0
                        )
                        if lite_result:
                            ali = float(lite_result.get("alignment", 1.0))
                            cat = lite_result["category"]
                            state["current_alignment"] = 1.0 if ali > 0.75 else (0.5 if ali > 0.25 else 0.0)
                            state["current_category"] = cat
                            delta = compute_delta_s(state["current_alignment"], cat)
                            new_s = max(0, min(10, state["current_suspicion_index"] + delta))
                            state["current_suspicion_index"] = new_s
                            print(f"  🛞 Spare tire: S:{new_s:.0f} A:{ali} Cat:{cat} — {lite_result.get('reason', '')}")
                            # 🔊 Offline voice — ONE phrase per cycle, 12s cooldown
                            # Priority: strike_warning > distraction_spotted > focus_warning > focus_reminder
                            _offline_cooldown = 12.0  # seconds between any offline phrase
                            _last_offline = state.get("_offline_voice_last_time", 0)
                            _can_speak = (time.time() - _last_offline) > _offline_cooldown
                            # Reset spoke flags when user returns to work
                            if new_s < 3:
                                state["_spare_tire_spoke"] = False
                                state["_spare_tire_distraction_spoke"] = False
                            # Auto-strike if critical suspicion — even without Gemini
                            if new_s >= 9 and not state.get("_strike_in_progress"):
                                # 🔊 Strike warning (always plays — overrides cooldown for urgency)
                                if not state.get("_spare_tire_strike_spoke"):
                                    state["_spare_tire_strike_spoke"] = True
                                    try:
                                        await play_offline_phrase("strike_warning", broadcast_visemes=False)
                                        state["_offline_voice_last_time"] = time.time()
                                    except Exception:
                                        pass
                                result = await asyncio.to_thread(prepare_close_tab, "Procrastination detected during API outage", None)
                                if result.get("status") == "success":
                                    print(f"  🛞⚡ SPARE TIRE STRIKE! Closing tab without Gemini")
                                    state["_strike_in_progress"] = True
                                    pending = state.get("_pending_strike", {})
                                    strike_msg = json.dumps({"command": "STRIKE_TARGET", "x": pending.get("target_x", 960), "y": pending.get("target_y", 540), "title": pending.get("title", "")})
                                    broadcast_to_godot(strike_msg)
                                    send_anim_to_godot("Strike", False)
                                    # FIX: STRIKE_FIRE timeout — same as grace_then_close.
                                    # Without this, _strike_in_progress stays True forever
                                    # and blocks ALL future strikes when the API reconnects.
                                    async def spare_tire_fire_timeout():
                                        TIMEOUT = 30.0
                                        t0 = time.time()
                                        while state.get("_pending_strike") is not None:
                                            if time.time() - t0 > TIMEOUT:
                                                print("  🛞⏰ Spare tire strike abandoned (30s) — drone never impacted. Tab NOT closed.")
                                                state.pop("_pending_strike", None)  # Clean up without closing
                                                break
                                            await asyncio.sleep(0.1)
                                        # Always reset — even if STRIKE_FIRE came from Godot
                                        state["_strike_in_progress"] = False
                                        state["_strike_requested"] = False
                                        state["_spare_tire_strike_spoke"] = False  # Allow re-strike
                                        await asyncio.to_thread(refresh_window_cache)
                                        print("  🛞✅ Spare tire strike complete — flags reset")
                                    asyncio.create_task(spare_tire_fire_timeout())
                                    # No distraction_closed — Gemini will speak when it reconnects
                            elif _can_speak:
                                # Distraction spotted (mid priority)
                                if cat in ("PURE_DISTRACTION", "PROCRASTINATION", "BANNIE") and not state.get("_spare_tire_distraction_spoke"):
                                    state["_spare_tire_distraction_spoke"] = True
                                    state["_offline_voice_last_time"] = time.time()
                                    try:
                                        await play_offline_phrase("distraction_spotted", broadcast_visemes=False)
                                    except Exception:
                                        pass
                                # Focus warning (low-mid priority, only if didn't already speak)
                                elif new_s >= 7 and not state.get("_spare_tire_spoke"):
                                    state["_spare_tire_spoke"] = True
                                    state["_offline_voice_last_time"] = time.time()
                                    try:
                                        await play_offline_phrase("focus_warning", broadcast_visemes=False)
                                    except Exception:
                                        pass
                                # Focus reminder (lowest priority)
                                elif new_s >= 4 and not state.get("_spare_tire_spoke"):
                                    state["_spare_tire_spoke"] = True
                                    state["_offline_voice_last_time"] = time.time()
                                    try:
                                        await play_offline_phrase("focus_reminder", broadcast_visemes=False)
                                    except Exception:
                                        pass
                    except asyncio.TimeoutError:
                        print("  🛞⚠️ Spare tire Flash-Lite timeout (>8s)")
                    except Exception as e:
                        print(f"  🛞⚠️ Spare tire error: {e}")
                    await asyncio.sleep(3.0)
            else:
                await asyncio.sleep(retry_delay)
        else:
            _consecutive_failures = 0
