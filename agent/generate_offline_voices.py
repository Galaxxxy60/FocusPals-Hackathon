"""
FocusPals — Offline Voice Generator (Gemini TTS — Leda Voice)
Generates all pre-recorded phrases using the SAME Gemini Leda voice as live Tama.

Uses gemini-2.5-flash-preview-tts with voice_name="Leda" to produce PCM audio
that is byte-identical in quality to the Live API output.

Usage:
    cd FocusPals/agent
    python generate_offline_voices.py

This generates ~100 WAV files (10 categories × 5 variants × 2 languages).
Total size is typically ~2-5 MB.
Output: agent/offline_audio/{lang}/{category}/01.wav → 05.wav

Requires:
    - GEMINI_API_KEY in .env (same key used for live sessions)
    - google-genai SDK (already installed for FocusPals)
"""

import asyncio
import os
import sys
import time
import wave

# ─── Phrase Database ────────────────────────────────────────
# Each category has 5 variants per language.
# Phrases are written to sound natural when spoken by Tama (a young,
# energetic focus companion). Short, punchy, with personality.
#
# The TTS model supports "director's notes" in the prompt — we include
# style directions so Leda delivers the lines with the right energy.

PHRASES = {
    "greeting": {
        "fr": [
            "Salut ! Prête à bosser avec toi !",
            "Hey ! C'est parti, on s'y met !",
            "Coucou ! Allez, au boulot !",
            "Me revoilà ! On attaque ?",
            "Hello ! J'suis là, on commence !",
        ],
        "en": [
            "Hey! Ready to get to work!",
            "Hi there! Let's do this!",
            "Hello! Time to focus!",
            "I'm here! Let's get started!",
            "Hey hey! Let's crush it today!",
        ],
    },
    "goodbye": {
        "fr": [
            "Bonne session ! À la prochaine !",
            "Bien joué ! Repose-toi bien.",
            "C'était cool ! À plus tard !",
            "Super travail aujourd'hui ! Ciao !",
            "Allez, à bientôt ! Tu as bien bossé.",
        ],
        "en": [
            "Great session! See you next time!",
            "Good job! Take a well-deserved break.",
            "That was awesome! See you later!",
            "Nice work today! Bye for now!",
            "Alright, catch you later! You did great.",
        ],
    },
    "focus_reminder": {
        "fr": [
            "Hé, on reste concentré, d'accord ?",
            "Allez, retourne bosser !",
            "Hé ho, c'est pas le moment de traîner !",
            "Focus ! Tu peux le faire !",
            "Qu'est-ce que tu fais là ? Allez, on s'y remet !",
        ],
        "en": [
            "Hey, let's stay focused, okay?",
            "Come on, back to work!",
            "Not the time to slack off!",
            "Focus! You got this!",
            "What are you doing? Come on, back to it!",
        ],
    },
    "focus_warning": {
        "fr": [
            "Bon, là c'est sérieux. Retourne travailler.",
            "Je vais pas te laisser traîner comme ça.",
            "Dernière chance avant que je m'énerve !",
            "Ça suffit maintenant. Au boulot.",
            "Tu me forces la main là. Allez !",
        ],
        "en": [
            "Okay, I'm serious now. Get back to work.",
            "I'm not gonna let you slack off like this.",
            "Last chance before I get mad!",
            "That's enough. Back to work.",
            "You're forcing my hand here. Come on!",
        ],
    },
    "encouragement": {
        "fr": [
            "Tu gères ! Continue comme ça !",
            "Bravo, t'es bien concentré !",
            "Super boulot, je suis fière de toi !",
            "Wow, quelle productivité ! Bien joué !",
            "T'assures grave ! Garde le rythme !",
        ],
        "en": [
            "You're killing it! Keep going!",
            "Nice focus! You're doing great!",
            "Amazing work, I'm proud of you!",
            "Wow, so productive! Well done!",
            "You're on fire! Keep up the pace!",
        ],
    },
    "break_suggestion": {
        "fr": [
            "Hé, ça fait un moment. Fais une pause !",
            "Tu mérites une petite pause. Lève-toi un peu !",
            "Pause ! Va boire un verre d'eau.",
            "On fait une pause ? Tu bosses depuis longtemps.",
            "Allez, cinq minutes de repos ! Tu l'as bien mérité.",
        ],
        "en": [
            "Hey, it's been a while. Take a break!",
            "You deserve a little break. Stretch a bit!",
            "Break time! Go grab some water.",
            "How about a break? You've been working hard.",
            "Come on, five minutes! You've earned it.",
        ],
    },
    "reconnecting": {
        "fr": [
            "Oups, petite coupure. Deux secondes...",
            "Attends, je me reconnecte...",
            "Petit bug, je reviens tout de suite !",
            "Hmm, j'ai perdu le fil. Un instant...",
            "Reconnexion en cours, bouge pas !",
        ],
        "en": [
            "Oops, lost connection. One sec...",
            "Hold on, let me reconnect...",
            "Little hiccup, I'll be right back!",
            "Hmm, lost my train of thought. One moment...",
            "Reconnecting, hang tight!",
        ],
    },
    "back_online": {
        "fr": [
            "C'est bon, je suis de retour !",
            "Me revoilà ! Où on en était ?",
            "Connexion rétablie ! On continue.",
            "OK, c'est réglé. On reprend !",
            "Je suis revenue ! Tout est bon.",
        ],
        "en": [
            "I'm back! All good now.",
            "Here I am again! Where were we?",
            "Connection restored! Let's keep going.",
            "Alright, all fixed. Back to it!",
            "I'm back online! Everything's fine.",
        ],
    },
    "thinking": {
        "fr": [
            "Hmm...",
            "Voyons voir...",
            "Attends, je réfléchis...",
            "Euh... une seconde.",
            "Mmh, laisse-moi voir...",
        ],
        "en": [
            "Hmm...",
            "Let me see...",
            "Hold on, let me think...",
            "Uh... one second.",
            "Mmh, let me check...",
        ],
    },
    "strike_warning": {
        "fr": [
            "Dernière chance ! Je vais fermer ça !",
            "Tu l'as cherché ! Je ferme !",
            "C'est fini les bêtises. Bam !",
            "Je t'avais prévenu ! Pouf, c'est parti !",
            "Allez hop, ça dégage !",
        ],
        "en": [
            "Last chance! I'm closing this!",
            "You asked for it! Closing now!",
            "No more messing around. Bam!",
            "I warned you! Poof, it's gone!",
            "Alright, this is going away!",
        ],
    },
    "busy_writing": {
        "fr": [
            "Donne-moi deux secondes...",
            "J'suis à toi dans deux secondes !",
            "Deux secondes...",
            "J'finis juste un exercice, bouge pas.",
            "Attends, j'écris un truc... Voilà !",
        ],
        "en": [
            "Give me two seconds...",
            "I'll be right with you in a sec!",
            "Two seconds...",
            "Just finishing something, hold on.",
            "Wait, I'm writing something... There!",
        ],
    },
    "distraction_spotted": {
        "fr": [
            "J'attends que tu fermes cette distraction qu'on revienne aux choses sérieuses.",
            "Bon, je ferme la distraction ou tu le fais ?",
            "N'oublie pas : je suis celle qui t'empêche de rater ta vie devant des vidéos de compilations de memes.",
            "Hé, c'est quoi ça ? On avait dit pas de distractions !",
            "Tu crois que j'ai pas vu ? Ferme ça. Maintenant.",
        ],
        "en": [
            "I'm waiting for you to close that distraction so we can get back to serious stuff.",
            "So, should I close this distraction or are you gonna do it?",
            "Remember: I'm the one keeping you from wasting your life watching meme compilations.",
            "Hey, what's that? We said no distractions!",
            "You think I didn't see that? Close it. Now.",
        ],
    },
    "distraction_closed": {
        "fr": [
            "Distraction fermée ! Allez, on se remet au travail.",
            "Voilà, c'est mieux comme ça. On reprend !",
            "Bien ! Plus de bêtises. On y retourne.",
            "Parfait. Maintenant, concentre-toi.",
            "Hop, c'est réglé. Retour aux choses sérieuses !",
        ],
        "en": [
            "Distraction closed! Now let's get back to work.",
            "There, much better. Back to it!",
            "Good! No more nonsense. Let's go.",
            "Perfect. Now, focus.",
            "Done! Back to serious business!",
        ],
    },
}

# ─── Voice & Style Configuration ────────────────────────────
# Same Leda voice as gemini_session.py line 772
VOICE_NAME = "Leda"
TTS_MODEL = "gemini-2.5-flash-preview-tts"

# Director's notes per category — tells Leda HOW to deliver the line
# This matches the TTS prompting guide: Audio Profile + Scene + Director Notes
DIRECTOR_NOTES = {
    "greeting": {
        "fr": "Tu es Tama, une jeune compagne de productivité joyeuse et énergique. Dis cette phrase avec enthousiasme et un sourire dans la voix, comme si tu retrouvais un ami. Ton naturel, décontracté.",
        "en": "You are Tama, a young, joyful productivity companion. Say this line with enthusiasm and a smile in your voice, like greeting a friend. Natural, casual tone.",
    },
    "goodbye": {
        "fr": "Tu es Tama. Dis cette phrase chaleureusement, avec fierté pour le travail accompli. Un ton doux et satisfait, comme une amie qui dit au revoir après une bonne journée.",
        "en": "You are Tama. Say this warmly, with pride for the work done. A gentle, satisfied tone, like a friend saying goodbye after a good day.",
    },
    "focus_reminder": {
        "fr": "Tu es Tama. Dis cette phrase avec un ton légèrement taquin mais bienveillant, comme une amie qui rappelle gentiment à l'ordre. Pas trop sévère, plutôt joueuse.",
        "en": "You are Tama. Say this with a slightly teasing but caring tone, like a friend gently nudging someone back on track. Not too stern, playful.",
    },
    "focus_warning": {
        "fr": "Tu es Tama. Dis cette phrase avec un ton plus ferme et sérieux, mais sans être méchante. Tu es déçue et déterminée. Voix plus grave et posée.",
        "en": "You are Tama. Say this with a firmer, more serious tone, but not mean. You're disappointed and determined. Slightly lower, steady voice.",
    },
    "encouragement": {
        "fr": "Tu es Tama. Dis cette phrase avec beaucoup d'énergie et de fierté ! Tu es vraiment impressionnée et heureuse. Ton radieux, comme une coach qui celebrate une victoire.",
        "en": "You are Tama. Say this with lots of energy and pride! You're genuinely impressed and happy. Radiant tone, like a coach celebrating a win.",
    },
    "break_suggestion": {
        "fr": "Tu es Tama. Dis cette phrase avec un ton doux et attentionné, comme une amie qui s'inquiète pour la santé de quelqu'un. Calme, bienveillant.",
        "en": "You are Tama. Say this with a soft, caring tone, like a friend worried about someone's health. Calm, nurturing.",
    },
    "reconnecting": {
        "fr": "Tu es Tama. Dis cette phrase de manière décontractée et rassurante, comme si c'était un petit incident sans gravité. Ton léger, pas de panique.",
        "en": "You are Tama. Say this casually and reassuringly, like it's a minor hiccup. Light tone, no panic.",
    },
    "back_online": {
        "fr": "Tu es Tama. Dis cette phrase avec soulagement et enthousiasme, comme quelqu'un qui revient après une courte absence. Ton joyeux et rassurant.",
        "en": "You are Tama. Say this with relief and enthusiasm, like someone returning after a short absence. Cheerful and reassuring tone.",
    },
    "thinking": {
        "fr": "Tu es Tama. Dis ce petit mot de manière pensive et naturelle, comme si tu réfléchissais vraiment. Ton lent, réfléchi, avec une petite hésitation naturelle.",
        "en": "You are Tama. Say this small filler word thoughtfully and naturally, as if really thinking. Slow, reflective, with a natural hesitation.",
    },
    "strike_warning": {
        "fr": "Tu es Tama. Dis cette phrase avec intensité et détermination ! Tu es en colère mais de manière comique et dramatique. Voix rapide, percutante, théâtrale.",
        "en": "You are Tama. Say this with intensity and determination! You're angry but in a comical, dramatic way. Fast, punchy, theatrical voice.",
    },
    "busy_writing": {
        "fr": "Tu es Tama. Dis cette phrase de manière décontractée et rapide, comme si tu étais en train de faire quelque chose et que tu demandais juste un peu de patience. Ton naturel, un peu pressé mais amical.",
        "en": "You are Tama. Say this casually and quickly, like you're in the middle of something and just asking for a moment. Natural, slightly rushed but friendly.",
    },
    "distraction_spotted": {
        "fr": "Tu es Tama. Dis cette phrase avec un mélange de sarcasme et d'exaspération amusée, comme une grande sœur qui surprend son frère en train de tricher. Tu es taquine mais ferme. Prononce lentement les mots-clés pour l'effet dramatique.",
        "en": "You are Tama. Say this with a mix of sarcasm and amused exasperation, like a big sister catching her brother cheating. Teasing but firm. Slow down on key words for dramatic effect.",
    },
    "distraction_closed": {
        "fr": "Tu es Tama. Dis cette phrase avec satisfaction et un peu de fierté, comme une coach qui vient de remettre son élève sur le droit chemin. Ton approbateur et motivant.",
        "en": "You are Tama. Say this with satisfaction and a touch of pride, like a coach who just got their student back on track. Approving and motivating tone.",
    },
}


# ─── WAV Helper ─────────────────────────────────────────────

def save_wav(filename: str, pcm_data: bytes, channels: int = 1, rate: int = 24000, sample_width: int = 2):
    """Save raw PCM data as a WAV file (matches Gemini TTS output format)."""
    with wave.open(filename, "wb") as wf:
        wf.setnchannels(channels)
        wf.setsampwidth(sample_width)
        wf.setframerate(rate)
        wf.writeframes(pcm_data)


# ─── Generation Logic ──────────────────────────────────────

async def generate_all():
    """Generate all offline voice files using Gemini TTS with the Leda voice."""
    # Load API key from .env (same as main agent)
    from dotenv import load_dotenv
    env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env')
    load_dotenv(env_path)

    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        print("❌ GEMINI_API_KEY not found in .env!")
        print("   Set your API key first.")
        sys.exit(1)

    from google import genai
    from google.genai import types

    client = genai.Client(api_key=api_key, http_options={"api_version": "v1alpha"})

    output_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "offline_audio")

    total = 0
    errors = 0
    skipped = 0

    for category, lang_phrases in PHRASES.items():
        for lang, phrases in lang_phrases.items():
            # Create directory
            cat_dir = os.path.join(output_dir, lang, category)
            os.makedirs(cat_dir, exist_ok=True)

            director_note = DIRECTOR_NOTES.get(category, {}).get(lang, "")

            for i, text in enumerate(phrases, 1):
                filename = f"{i:02d}"
                wav_path = os.path.join(cat_dir, f"{filename}.wav")

                # Skip if already generated
                if os.path.exists(wav_path):
                    print(f"  ⏭️  [{lang}/{category}/{filename}] Already exists — skipping")
                    skipped += 1
                    total += 1
                    continue

                # Build prompt with director's notes
                # The TTS model responds to style instructions in the prompt
                if director_note:
                    prompt = f"{director_note}\n\nDis exactement : \"{text}\"" if lang == "fr" else f"{director_note}\n\nSay exactly: \"{text}\""
                else:
                    prompt = text

                try:
                    print(f"  🎙️  [{lang}/{category}/{filename}] \"{text}\"")

                    response = client.models.generate_content(
                        model=TTS_MODEL,
                        contents=prompt,
                        config=types.GenerateContentConfig(
                            response_modalities=["AUDIO"],
                            speech_config=types.SpeechConfig(
                                voice_config=types.VoiceConfig(
                                    prebuilt_voice_config=types.PrebuiltVoiceConfig(
                                        voice_name=VOICE_NAME
                                    )
                                )
                            ),
                        )
                    )

                    # Extract raw PCM audio data
                    data = response.candidates[0].content.parts[0].inline_data.data

                    # Save as WAV (24kHz, 16-bit mono — same as Gemini Live output)
                    save_wav(wav_path, data)

                    size_kb = os.path.getsize(wav_path) / 1024
                    # Estimate duration: 24000 samples/sec × 2 bytes/sample = 48000 bytes/sec
                    duration_sec = len(data) / 48000.0
                    print(f"    ✅ WAV ({size_kb:.0f} KB, {duration_sec:.1f}s)")

                    total += 1

                    # Rate limiting — avoid hammering the API
                    # Gemini TTS has per-minute limits
                    await asyncio.sleep(1.0)

                except Exception as e:
                    errors += 1
                    print(f"    ❌ Error: {e}")
                    # Longer backoff on error (rate limit?)
                    await asyncio.sleep(3.0)

    print(f"\n{'='*50}")
    print(f"🎉 Generation complete!")
    print(f"   ✅ {total} files total ({total - skipped} new, {skipped} skipped)")
    if errors:
        print(f"   ❌ {errors} errors (re-run to retry failed files)")
    print(f"   📁 Output: {output_dir}")
    print(f"   🎤 Voice: {VOICE_NAME} (identical to live Tama)")

    # Show size summary
    total_size = 0
    for root, dirs, files in os.walk(output_dir):
        for f in files:
            total_size += os.path.getsize(os.path.join(root, f))
    print(f"   💾 Total size: {total_size / (1024*1024):.1f} MB")
    print(f"\n✅ Restart FocusPals — offline voices are now available!")


if __name__ == "__main__":
    total_count = sum(len(phrases) for lang_phrases in PHRASES.values() for phrases in lang_phrases.values())
    print("🎙️  FocusPals Offline Voice Generator")
    print("=" * 50)
    print(f"🎤 Voice: {VOICE_NAME} (same as live Tama)")
    print(f"🤖 Model: {TTS_MODEL}")
    print(f"🌐 Languages: FR, EN")
    print(f"📂 Categories: {len(PHRASES)}")
    print(f"🔢 Variants per category: 5")
    print(f"📊 Total files to generate: {total_count}")
    print("=" * 50)
    print()
    asyncio.run(generate_all())
