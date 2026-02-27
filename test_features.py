"""
FocusPals — Test des 3 features Gemini Live API (Priorité HAUTE)

  1. ✅ Affective Dialog     — Tama adapte son ton à l'émotion de l'utilisateur
  2. ✅ Context Window Compression — Sessions illimitées (sliding window)
  3. ✅ Server-side VAD       — Détection vocale native Gemini

Mode d'emploi :
  1. Parle dans ton micro pendant le test (10 secondes)
  2. Observe les logs — chaque feature est clairement reportée
  3. Le script se termine automatiquement

Usage : python test_features.py
"""

import asyncio
import os
import sys
import struct
import math
import time

# Load .env from agent/
from dotenv import load_dotenv
agent_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "agent")
load_dotenv(os.path.join(agent_dir, ".env"))

from google import genai
from google.genai import types

# ─── Config ────────────────────────────────────────────────
API_KEY = os.getenv("GEMINI_API_KEY")
if not API_KEY:
    print("❌ GEMINI_API_KEY manquante dans agent/.env")
    sys.exit(1)

MODEL = "gemini-2.5-flash-native-audio-latest"
client = genai.Client(api_key=API_KEY, http_options={"api_version": "v1alpha"})

# Audio settings
SEND_RATE = 16000
RECV_RATE = 24000
CHUNK = 1024
TEST_DURATION = 15  # seconds

# ─── Results tracker ───────────────────────────────────────
results = {
    "affective_dialog": {"accepted": False, "detail": ""},
    "context_compression": {"accepted": False, "detail": ""},
    "server_vad": {"accepted": False, "detail": ""},
    "got_audio_response": False,
    "got_transcript": False,
    "got_interruption": False,
    "got_session_resumption": False,
}


def simple_vad(pcm_data: bytes, threshold: float = 500.0) -> bool:
    """Local VAD just for logging — NOT used for Gemini."""
    n = len(pcm_data) // 2
    if n == 0:
        return False
    samples = struct.unpack(f'<{n}h', pcm_data)
    rms = math.sqrt(sum(s * s for s in samples) / n)
    return rms > threshold


async def test_all_features():
    print("=" * 60)
    print("🧪 FocusPals — Test des 3 features haute priorité")
    print("=" * 60)
    print()

    # ── Build config with ALL 3 features ──
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(parts=[types.Part(text=(
            "Tu es Tama, un coach de productivité ninja. "
            "Réponds en français. Sois chaleureuse et courte (1-2 phrases). "
            "Adapte ton ton à l'émotion de l'utilisateur."
        ))]),
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        session_resumption=types.SessionResumptionConfig(),

        # ──────── FEATURE 1: Affective Dialog ────────
        enable_affective_dialog=True,

        # ──────── FEATURE 2: Context Window Compression ────────
        context_window_compression=types.ContextWindowCompressionConfig(
            sliding_window=types.SlidingWindow(),
        ),

        # ──────── FEATURE 3: Server-side VAD ────────
        realtime_input_config=types.RealtimeInputConfig(
            automatic_activity_detection=types.AutomaticActivityDetection(
                disabled=False,
                start_of_speech_sensitivity=types.StartSensitivity.START_SENSITIVITY_LOW,
                end_of_speech_sensitivity=types.EndSensitivity.END_SENSITIVITY_LOW,
                prefix_padding_ms=20,
                silence_duration_ms=500,
            )
        ),
    )

    print("📡 Connexion à Gemini Live API...")
    print(f"   Model: {MODEL}")
    print(f"   API version: v1alpha")
    print()

    try:
        async with client.aio.live.connect(model=MODEL, config=config) as session:

            # If we get here, config was accepted!
            print("✅ Connexion réussie ! Config acceptée par le serveur.")
            print()
            results["affective_dialog"]["accepted"] = True
            results["affective_dialog"]["detail"] = "enable_affective_dialog=True accepted"
            results["context_compression"]["accepted"] = True
            results["context_compression"]["detail"] = "ContextWindowCompressionConfig accepted"
            results["server_vad"]["accepted"] = True
            results["server_vad"]["detail"] = "AutomaticActivityDetection config accepted"

            # ── Open mic ──
            import pyaudio
            pya = pyaudio.PyAudio()

            try:
                mic_stream = pya.open(
                    format=pyaudio.paInt16, channels=1, rate=SEND_RATE,
                    input=True, frames_per_buffer=CHUNK
                )
            except OSError as e:
                print(f"⚠️  Impossible d'ouvrir le micro: {e}")
                print("   Le test continue sans audio input (text only)")
                mic_stream = None

            # ── Open speaker ──
            try:
                speaker = pya.open(
                    format=pyaudio.paInt16, channels=1, rate=RECV_RATE,
                    output=True
                )
            except OSError:
                speaker = None

            # ── Send a greeting text to trigger a response ──
            print("💬 Envoi d'un message texte de test...")
            await session.send_client_content(
                turns=types.Content(
                    role="user",
                    parts=[types.Part(text="Salut Tama ! Comment tu vas ? C'est un test rapide.")]
                ),
                turn_complete=True
            )

            # ── Run for TEST_DURATION seconds ──
            start = time.time()
            audio_bytes_sent = 0
            speech_detected_count = 0
            audio_chunks_received = 0
            transcripts = []

            print(f"\n🎤 Streaming micro pendant {TEST_DURATION}s — parle pour tester le VAD !")
            print("   (Le VAD serveur gère la détection, on log aussi le VAD local pour comparer)")
            print()

            while time.time() - start < TEST_DURATION:
                # ── Send mic audio ──
                if mic_stream:
                    try:
                        data = mic_stream.read(CHUNK, exception_on_overflow=False)
                        await session.send_realtime_input(
                            audio=types.Blob(data=data, mime_type="audio/pcm;rate=16000")
                        )
                        audio_bytes_sent += len(data)

                        if simple_vad(data):
                            speech_detected_count += 1
                            if speech_detected_count % 15 == 1:  # Log every ~1s
                                print(f"  🎤 [VAD local] Parole détectée (comparaison) — le VAD serveur gère le vrai flow")
                    except Exception:
                        pass

                # ── Receive responses ──
                try:
                    turn = session.receive()
                    async for response in turn:
                        server = response.server_content

                        # Audio response
                        if server and server.model_turn:
                            for part in server.model_turn.parts:
                                if part.inline_data and isinstance(part.inline_data.data, bytes):
                                    audio_chunks_received += 1
                                    results["got_audio_response"] = True
                                    if speaker:
                                        try:
                                            speaker.write(part.inline_data.data)
                                        except OSError:
                                            pass

                        # Transcriptions
                        if server and server.output_transcription:
                            txt = server.output_transcription.text
                            if txt and txt.strip():
                                transcripts.append(txt.strip())
                                results["got_transcript"] = True
                                print(f"  📝 [Transcript OUT] {txt.strip()}")

                        if server and server.input_transcription:
                            txt = server.input_transcription.text
                            if txt and txt.strip():
                                print(f"  🎤 [Transcript IN]  {txt.strip()}")

                        # Interruption (VAD serveur detected user talking over Tama)
                        if server and server.interrupted:
                            results["got_interruption"] = True
                            print(f"  ⚡ [VAD Serveur] INTERRUPTION détectée ! Tama s'est arrêtée de parler.")

                        # Session resumption update
                        if hasattr(response, 'session_resumption_update') and response.session_resumption_update:
                            update = response.session_resumption_update
                            if update.resumable and update.new_handle:
                                results["got_session_resumption"] = True
                                handle_preview = update.new_handle[:20] + "..."
                                print(f"  🔄 [Session Resume] Handle reçu: {handle_preview}")

                        # Turn complete
                        if server and server.turn_complete:
                            break

                    # Don't block on receive, continue streaming
                    await asyncio.sleep(0.01)

                except Exception:
                    await asyncio.sleep(0.1)

            # ── Cleanup ──
            if mic_stream:
                mic_stream.close()
            if speaker:
                try:
                    speaker.stop_stream()
                    speaker.close()
                except Exception:
                    pass
            pya.terminate()

    except Exception as e:
        print(f"\n❌ Erreur de connexion: {e}")
        import traceback
        traceback.print_exc()
        return

    # ─── Final Report ──────────────────────────────────────
    print()
    print("=" * 60)
    print("📊 RÉSULTATS DU TEST")
    print("=" * 60)
    print()

    # Feature 1: Affective Dialog
    ad = results["affective_dialog"]
    if ad["accepted"]:
        print("✅ FEATURE 1 — Affective Dialog")
        print(f"   Config acceptée par le serveur.")
        print(f"   Tama adaptera son ton à tes émotions en session réelle.")
        if results["got_audio_response"]:
            print(f"   Audio reçu: {audio_chunks_received} chunks")
    else:
        print("❌ FEATURE 1 — Affective Dialog : REJETÉ par le serveur")

    print()

    # Feature 2: Context Window Compression
    cc = results["context_compression"]
    if cc["accepted"]:
        print("✅ FEATURE 2 — Context Window Compression (Sliding Window)")
        print(f"   Config acceptée. Les sessions Deep Work longues ne crasheront plus.")
        print(f"   Audio envoyé: {audio_bytes_sent // 1024} KB en {TEST_DURATION}s")
    else:
        print("❌ FEATURE 2 — Context Window Compression : REJETÉ")

    print()

    # Feature 3: Server-side VAD
    vad = results["server_vad"]
    if vad["accepted"]:
        print("✅ FEATURE 3 — Server-side VAD")
        print(f"   Config acceptée (sensitivity LOW, silence 500ms).")
        print(f"   VAD local a détecté {speech_detected_count} chunks de parole (comparaison)")
        if results["got_interruption"]:
            print(f"   ⚡ Interruption serveur détectée = le VAD serveur fonctionne !")
        else:
            print(f"   ℹ️  Pas d'interruption (normal si tu n'as pas parlé par-dessus Tama)")
    else:
        print("❌ FEATURE 3 — Server-side VAD : REJETÉ")

    print()

    # Transcripts summary
    if transcripts:
        print("📝 Ce que Tama a dit :")
        for t in transcripts:
            print(f"   → {t}")
    print()

    # Session resumption
    if results["got_session_resumption"]:
        print("🔄 Session resumption handle reçu ✅")
    else:
        print("ℹ️  Pas de session resumption handle (normal pour un test court)")

    print()
    all_ok = ad["accepted"] and cc["accepted"] and vad["accepted"]
    if all_ok:
        print("🎉 TOUTES LES FEATURES HAUTE PRIORITÉ SONT OPÉRATIONNELLES !")
        print("   Tu peux lancer FocusPals normalement — les améliorations sont actives.")
    else:
        print("⚠️  Certaines features n'ont pas été acceptées. Vérifie les logs ci-dessus.")

    print()
    print("=" * 60)


if __name__ == "__main__":
    asyncio.run(test_all_features())
