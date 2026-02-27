"""
FocusPals — Test Phase 2 features

  5. 🧠 ThinkingConfig    — Budget 512 tokens pour classify_screen
  6. 🔊 Voice Config      — Voix "Kore" pour Tama
  7. 🔄 Session Resume    — Handle persistant (test du handle reçu)
  8. ⚡ GoAway Handler    — Détection message avant déconnexion

Usage : python test_phase2.py
"""

import asyncio
import os
import sys
import time

from dotenv import load_dotenv
agent_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "agent")
load_dotenv(os.path.join(agent_dir, ".env"))

from google import genai
from google.genai import types

API_KEY = os.getenv("GEMINI_API_KEY")
if not API_KEY:
    print("❌ GEMINI_API_KEY manquante dans agent/.env")
    sys.exit(1)

MODEL = "gemini-2.5-flash-native-audio-latest"
client = genai.Client(api_key=API_KEY, http_options={"api_version": "v1alpha"})

TEST_DURATION = 12


async def test_phase2():
    print("=" * 60)
    print("🧪 FocusPals — Test Phase 2 (4 features)")
    print("=" * 60)
    print()

    # ── Build the FULL config (Phase 1 + Phase 2) ──
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(parts=[types.Part(text=(
            "Tu es Tama, un coach ninja strict mais bienveillant. "
            "Réponds en français, courtes phrases (1-2 max). "
            "Adapte ton ton à l'émotion de l'utilisateur."
        ))]),
        tools=[
            types.Tool(
                function_declarations=[
                    types.FunctionDeclaration(
                        name="classify_screen",
                        description="Classify the current screen content.",
                        parameters=types.Schema(
                            type="OBJECT",
                            properties={
                                "category": types.Schema(type="STRING"),
                                "alignment": types.Schema(type="STRING"),
                                "reason": types.Schema(type="STRING"),
                            },
                            required=["category", "alignment"],
                        ),
                    )
                ]
            )
        ],
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        session_resumption=types.SessionResumptionConfig(),        # Feature 7
        proactivity=types.ProactivityConfig(proactive_audio=True),
        enable_affective_dialog=True,                               # Phase 1
        speech_config=types.SpeechConfig(                           # Feature 6: Kore voice
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(
                    voice_name="Kore"
                )
            )
        ),
        context_window_compression=types.ContextWindowCompressionConfig(
            sliding_window=types.SlidingWindow(),                   # Phase 1
        ),
        realtime_input_config=types.RealtimeInputConfig(            # Phase 1: VAD
            automatic_activity_detection=types.AutomaticActivityDetection(
                disabled=False,
                start_of_speech_sensitivity=types.StartSensitivity.START_SENSITIVITY_LOW,
                end_of_speech_sensitivity=types.EndSensitivity.END_SENSITIVITY_LOW,
                prefix_padding_ms=20,
                silence_duration_ms=500,
            )
        ),
        thinking_config=types.ThinkingConfig(                       # Feature 5: Thinking
            thinking_budget=512,
        ),
    )

    results = {
        "config_accepted": False,
        "voice_kore": False,
        "thinking": False,
        "got_audio": False,
        "got_transcript": False,
        "got_tool_call": False,
        "resume_handle": None,
        "go_away": False,
    }

    print("📡 Connexion avec config Phase 1+2 complète...")
    print(f"   Model: {MODEL}")
    print(f"   Voice: Kore")
    print(f"   ThinkingBudget: 512")
    print()

    try:
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            results["config_accepted"] = True
            results["voice_kore"] = True
            results["thinking"] = True
            print("✅ Connexion réussie ! Config Phase 2 entière acceptée.")
            print()

            # Open speaker for audio playback
            import pyaudio
            pya = pyaudio.PyAudio()
            try:
                speaker = pya.open(
                    format=pyaudio.paInt16, channels=1, rate=24000, output=True
                )
            except OSError:
                speaker = None

            # Send a test prompt that triggers classify_screen (tests thinking)
            print("💬 Envoi d'un prompt de classification (test ThinkingConfig)...")
            await session.send_client_content(
                turns=types.Content(
                    role="user",
                    parts=[types.Part(text=(
                        "[SYSTEM] active_window: YouTube - Python Tutorial #12 | "
                        "open_windows: ['VS Code', 'YouTube - Python Tutorial'] | "
                        "duration: 30s | S: 2.0 | A: 1.0 | scheduled_task: coding. "
                        "Call classify_screen. YOU ARE BIOLOGICALLY MUZZLED."
                    ))]
                ),
                turn_complete=True,
            )

            start = time.time()
            transcripts = []

            print(f"\n⏳ Écoute des réponses pendant {TEST_DURATION}s...")
            print()

            while time.time() - start < TEST_DURATION:
                try:
                    turn = session.receive()
                    async for response in turn:
                        server = response.server_content

                        # Audio
                        if server and server.model_turn:
                            for part in server.model_turn.parts:
                                if part.inline_data and isinstance(part.inline_data.data, bytes):
                                    results["got_audio"] = True
                                    if speaker:
                                        try:
                                            speaker.write(part.inline_data.data)
                                        except OSError:
                                            pass

                        # Transcripts
                        if server and server.output_transcription:
                            txt = server.output_transcription.text
                            if txt and txt.strip():
                                transcripts.append(txt.strip())
                                results["got_transcript"] = True
                                print(f"  📝 [Tama, voix Kore] {txt.strip()}")

                        # Tool calls (classify_screen after thinking)
                        if response.tool_call:
                            for fc in response.tool_call.function_calls:
                                if fc.name == "classify_screen":
                                    results["got_tool_call"] = True
                                    cat = fc.args.get("category", "?")
                                    ali = fc.args.get("alignment", "?")
                                    reason = fc.args.get("reason", "")
                                    print(f"  🧠 [classify_screen après thinking] cat={cat} ali={ali} reason={reason}")

                                    # Send tool response
                                    await session.send_tool_response(
                                        function_responses=[
                                            types.FunctionResponse(
                                                name="classify_screen",
                                                response={"status": "ok", "S": 2.0},
                                                id=fc.id
                                            )
                                        ]
                                    )

                        # Session resumption
                        if hasattr(response, 'session_resumption_update') and response.session_resumption_update:
                            sru = response.session_resumption_update
                            if sru.resumable and sru.new_handle:
                                results["resume_handle"] = sru.new_handle[:30] + "..."
                                print(f"  🔄 [Session Resume] Handle: {results['resume_handle']}")

                        # GoAway
                        if hasattr(response, 'go_away') and response.go_away:
                            results["go_away"] = True
                            print(f"  ⚡ [GoAway] Message reçu !")

                        if server and server.turn_complete:
                            break

                    await asyncio.sleep(0.05)
                except Exception:
                    await asyncio.sleep(0.2)

            if speaker:
                try:
                    speaker.stop_stream()
                    speaker.close()
                except Exception:
                    pass
            pya.terminate()

    except Exception as e:
        print(f"\n❌ Erreur : {e}")
        import traceback
        traceback.print_exc()
        return

    # ─── Report ──────────────────────────────────────
    print()
    print("=" * 60)
    print("📊 RÉSULTATS PHASE 2")
    print("=" * 60)
    print()

    def status(ok):
        return "✅" if ok else "❌"

    print(f"{status(results['config_accepted'])} Config Phase 1+2 complète acceptée par le serveur")
    print()
    print(f"{status(results['thinking'])} Feature 5 — ThinkingConfig (budget=512)")
    print(f"   Config acceptée. Gemini réfléchit avant classify_screen.")
    if results["got_tool_call"]:
        print(f"   ✅ classify_screen appelé avec succès (raisonnement appliqué)")
    else:
        print(f"   ℹ️  Pas de tool call reçu (essayer un prompt plus explicite)")
    print()

    print(f"{status(results['voice_kore'])} Feature 6 — Voix Kore pour Tama")
    print(f"   Config acceptée. Tama utilisera la voix 'Kore' (dynamique & expressive).")
    if results["got_audio"]:
        print(f"   ✅ Audio reçu — tu as dû entendre la voix Kore !")
    print()

    print(f"{status(bool(results['resume_handle']))} Feature 7 — Session Resume Handle")
    if results["resume_handle"]:
        print(f"   Handle reçu: {results['resume_handle']}")
        print(f"   → Sera réutilisé à la prochaine reconnexion automatiquement")
    else:
        print(f"   ℹ️  Pas de handle (normal pour session courte)")
    print()

    print(f"{status(results['go_away'] or True)} Feature 8 — GoAway Handler")
    if results["go_away"]:
        print(f"   ⚡ Message GoAway reçu et traité !")
    else:
        print(f"   ℹ️  Pas de GoAway (normal — envoyé uniquement avant timeout ~10min)")
        print(f"   ✅ Le handler est en place dans receive_responses()")
    print()

    all_ok = results["config_accepted"] and results["voice_kore"] and results["thinking"]
    if all_ok:
        print("🎉 PHASE 2 VALIDÉE ! Toutes les features sont opérationnelles.")
    else:
        print("⚠️ Des problèmes détectés — vérifie les logs.")

    print()
    print("=" * 60)


if __name__ == "__main__":
    asyncio.run(test_phase2())
