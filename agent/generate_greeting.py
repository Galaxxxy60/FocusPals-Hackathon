"""
Generate tama_hello.wav using Edge TTS (Microsoft Azure voices).
Uses a natural French female voice. Run once to create the greeting file.

Usage:
    cd FocusPals/agent
    python generate_greeting.py
"""

import asyncio
import os
import edge_tts

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "godot")
OUTPUT_PATH = os.path.join(OUTPUT_DIR, "tama_hello.wav")
# Temp MP3 (edge-tts outputs MP3, we'll convert)
TEMP_MP3 = os.path.join(OUTPUT_DIR, "_tama_hello_temp.mp3")


async def generate_greeting():
    """Generate a cheerful 'Salut !' with a French female voice."""
    # French female voices available in Edge TTS:
    # fr-FR-DeniseNeural — warm, natural female voice (closest to Kore)
    # fr-FR-EloiseNeural — younger, bright
    voice = "fr-FR-DeniseNeural"
    text = "Salut !"

    print(f"🎙️ Generating '{text}' with voice {voice}...")

    communicate = edge_tts.Communicate(text, voice, rate="+10%", pitch="+5Hz")
    await communicate.save(TEMP_MP3)

    print(f"  📦 MP3 saved ({os.path.getsize(TEMP_MP3)} bytes)")

    # Convert MP3 → WAV using ffmpeg or pydub
    try:
        from pydub import AudioSegment
        audio = AudioSegment.from_mp3(TEMP_MP3)
        # Export as WAV (Godot prefers WAV)
        audio.export(OUTPUT_PATH, format="wav")
        os.remove(TEMP_MP3)
        print(f"  🔄 Converted to WAV")
    except ImportError:
        # No pydub — just rename MP3 (Godot can import MP3 too)
        mp3_path = OUTPUT_PATH.replace(".wav", ".mp3")
        os.rename(TEMP_MP3, mp3_path)
        print(f"  ⚠️ pydub not installed — saved as MP3 instead")
        print(f"     Rename to tama_hello.mp3 or install pydub: pip install pydub")
        OUTPUT_FINAL = mp3_path
        print(f"\n🎉 Saved: {OUTPUT_FINAL}")
        print(f"   Size: {os.path.getsize(OUTPUT_FINAL)} bytes")
        return

    duration_ms = len(audio)
    print(f"\n🎉 Saved: {OUTPUT_PATH}")
    print(f"   Size: {os.path.getsize(OUTPUT_PATH)} bytes")
    print(f"   Duration: {duration_ms/1000:.1f}s")
    print(f"\n✅ Restart FocusPals — Tama will greet with this audio!")


if __name__ == "__main__":
    asyncio.run(generate_greeting())
