"""
Test 8: Audio streaming isolé — Est-ce que le micro seul crash la session ?
"""
import asyncio
import os
import time
import traceback

from dotenv import load_dotenv
from google import genai
from google.genai import types
import pyaudio

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent', '.env'))
client = genai.Client(api_key=os.getenv("GEMINI_API_KEY"))
MODEL = "gemini-2.5-flash-native-audio-latest"

FORMAT = pyaudio.paInt16
CHANNELS = 1
SEND_SAMPLE_RATE = 16000
RECEIVE_SAMPLE_RATE = 24000
CHUNK_SIZE = 1024

async def test_audio_only():
    print("="*55)
    print("  TEST A: Micro seul (pas d'écran, pas de tools)")
    print("="*55)
    
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(parts=[types.Part(text="Tu es Tama. Reponds en francais. Dis bonjour quand tu entends quelque chose.")]),
    )
    
    pya = pyaudio.PyAudio()
    
    # Show available audio devices
    print("\n  Peripheriques audio disponibles:")
    default_input = pya.get_default_input_device_info()
    print(f"  -> Micro par defaut: {default_input['name']} (index={default_input['index']}, rate={int(default_input['defaultSampleRate'])})")
    
    try:
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            print(f"\n  [OK] Session Live ouverte")
            
            audio_out_queue = asyncio.Queue()
            start_time = time.time()
            
            # --- Micro ---
            async def send_mic():
                stream = await asyncio.to_thread(
                    pya.open, format=FORMAT, channels=CHANNELS, rate=SEND_SAMPLE_RATE,
                    input=True, input_device_index=default_input["index"], frames_per_buffer=CHUNK_SIZE,
                )
                print(f"  [OK] Micro ouvert (stream={SEND_SAMPLE_RATE}Hz, chunk={CHUNK_SIZE})")
                chunks_sent = 0
                try:
                    while time.time() - start_time < 20:
                        data = await asyncio.to_thread(stream.read, CHUNK_SIZE, exception_on_overflow=False)
                        await session.send_realtime_input(
                            audio=types.Blob(data=data, mime_type="audio/pcm")
                        )
                        chunks_sent += 1
                        if chunks_sent % 50 == 0:
                            elapsed = time.time() - start_time
                            print(f"  [MIC] {chunks_sent} chunks envoyes ({elapsed:.0f}s)")
                except Exception as e:
                    print(f"  [MIC CRASH] {type(e).__name__}: {e}")
                    raise
                finally:
                    stream.close()
                    print(f"  [MIC] Ferme apres {chunks_sent} chunks")
            
            # --- Receive ---
            async def receive():
                try:
                    while time.time() - start_time < 20:
                        turn = session.receive()
                        async for response in turn:
                            if response.server_content and response.server_content.model_turn:
                                for part in response.server_content.model_turn.parts:
                                    if part.inline_data and isinstance(part.inline_data.data, bytes):
                                        audio_out_queue.put_nowait(part.inline_data.data)
                                        print(f"  [RECV] Audio recu: {len(part.inline_data.data)} bytes")
                                    if part.text:
                                        print(f"  [RECV] Texte: {part.text[:80]}")
                            if response.tool_call:
                                print(f"  [RECV] Tool call inattendu")
                except asyncio.TimeoutError:
                    pass
                except Exception as e:
                    print(f"  [RECV CRASH] {type(e).__name__}: {e}")
                    raise
            
            # --- Speaker ---
            async def play_audio():
                speaker = await asyncio.to_thread(
                    pya.open, format=FORMAT, channels=CHANNELS, rate=RECEIVE_SAMPLE_RATE, output=True,
                )
                print(f"  [OK] Speaker ouvert ({RECEIVE_SAMPLE_RATE}Hz)")
                try:
                    while time.time() - start_time < 20:
                        try:
                            audio_data = await asyncio.wait_for(audio_out_queue.get(), timeout=1.0)
                            await asyncio.to_thread(speaker.write, audio_data)
                        except asyncio.TimeoutError:
                            pass
                except Exception as e:
                    print(f"  [SPEAKER CRASH] {type(e).__name__}: {e}")
                finally:
                    speaker.close()
            
            # Run all three
            try:
                async with asyncio.TaskGroup() as tg:
                    tg.create_task(send_mic())
                    tg.create_task(receive())
                    tg.create_task(play_audio())
            except* Exception as eg:
                for e in eg.exceptions:
                    print(f"  [TASKGROUP ERROR] {type(e).__name__}: {e}")
                    traceback.print_exception(type(e), e, e.__traceback__)
            else:
                elapsed = time.time() - start_time
                print(f"\n  PASS — Audio stable pendant {elapsed:.0f}s")
                return True
            return False
            

            
    except Exception as e:
        elapsed = time.time() - start_time
        print(f"\n  FAIL apres {elapsed:.0f}s — {type(e).__name__}: {e}")
        traceback.print_exc()
        return False
    finally:
        pya.terminate()


async def test_audio_plus_screen():
    """Test B: Audio + screenshots combines"""
    print("\n" + "="*55)
    print("  TEST B: Micro + Screenshot combines")
    print("="*55)
    
    import mss
    from PIL import Image
    import io
    
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(parts=[types.Part(text="Tu es Tama, un coach de productivite. Reponds en francais.")]),
        tools=[
            types.Tool(
                function_declarations=[
                    types.FunctionDeclaration(
                        name="classify_screen",
                        description="Classify screen.",
                        parameters=types.Schema(type="OBJECT", properties={
                            "category": types.Schema(type="STRING"),
                            "alignment": types.Schema(type="STRING"),
                        }, required=["category", "alignment"])
                    ),
                ]
            )
        ],
    )
    
    pya = pyaudio.PyAudio()
    default_input = pya.get_default_input_device_info()
    
    def capture():
        with mss.mss() as sct:
            monitor = sct.monitors[0]
            screenshot = sct.grab(monitor)
            img = Image.frombytes("RGB", screenshot.size, screenshot.rgb)
        img.thumbnail((1024, 512), Image.Resampling.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=40)
        return buf.getvalue()
    
    try:
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            print(f"  [OK] Session Live ouverte")
            
            audio_out_queue = asyncio.Queue()
            start_time = time.time()
            
            async def send_mic():
                stream = await asyncio.to_thread(
                    pya.open, format=FORMAT, channels=CHANNELS, rate=SEND_SAMPLE_RATE,
                    input=True, input_device_index=default_input["index"], frames_per_buffer=CHUNK_SIZE,
                )
                print(f"  [OK] Micro ouvert")
                chunks = 0
                try:
                    while time.time() - start_time < 25:
                        data = await asyncio.to_thread(stream.read, CHUNK_SIZE, exception_on_overflow=False)
                        await session.send_realtime_input(audio=types.Blob(data=data, mime_type="audio/pcm"))
                        chunks += 1
                        if chunks % 100 == 0:
                            print(f"  [MIC] {chunks} chunks ({time.time()-start_time:.0f}s)")
                except Exception as e:
                    print(f"  [MIC CRASH] {e}")
                    raise
                finally:
                    stream.close()
            
            async def send_screen():
                screens_sent = 0
                try:
                    while time.time() - start_time < 25:
                        jpeg = await asyncio.to_thread(capture)
                        await session.send_realtime_input(media=types.Blob(data=jpeg, mime_type="image/jpeg"))
                        screens_sent += 1
                        print(f"  [SCREEN] Screenshot #{screens_sent} envoye ({len(jpeg)} bytes)")
                        
                        # Also send the system text like tama does
                        await session.send_realtime_input(
                            text=f"[SYSTEM] active_window: Test | duration: 5s | S: 0.0. Call classify_screen. MUZZLED."
                        )
                        
                        await asyncio.sleep(8)  # Like the real pulse interval
                except Exception as e:
                    print(f"  [SCREEN CRASH] {e}")
                    raise
            
            async def receive():
                try:
                    while time.time() - start_time < 25:
                        turn = session.receive()
                        async for response in turn:
                            if response.tool_call:
                                for fc in response.tool_call.function_calls:
                                    print(f"  [FC] {fc.name}({dict(fc.args)})")
                                    await session.send_tool_response(
                                        function_responses=[types.FunctionResponse(name=fc.name, response={"status": "ok"}, id=fc.id)]
                                    )
                            if response.server_content and response.server_content.model_turn:
                                for part in response.server_content.model_turn.parts:
                                    if part.inline_data:
                                        audio_out_queue.put_nowait(part.inline_data.data)
                except Exception as e:
                    print(f"  [RECV CRASH] {e}")
                    raise
            
            async def play():
                speaker = await asyncio.to_thread(
                    pya.open, format=FORMAT, channels=CHANNELS, rate=RECEIVE_SAMPLE_RATE, output=True,
                )
                try:
                    while time.time() - start_time < 25:
                        try:
                            data = await asyncio.wait_for(audio_out_queue.get(), timeout=1.0)
                            await asyncio.to_thread(speaker.write, data)
                        except asyncio.TimeoutError:
                            pass
                finally:
                    speaker.close()
            
            try:
                async with asyncio.TaskGroup() as tg:
                    tg.create_task(send_mic())
                    tg.create_task(send_screen())
                    tg.create_task(receive())
                    tg.create_task(play())
            except* Exception as eg:
                for e in eg.exceptions:
                    print(f"  [TASKGROUP ERROR] {type(e).__name__}: {e}")
            else:
                print(f"\n  PASS — Audio+Screen stable pendant {time.time()-start_time:.0f}s")
                return True
            return False
            

    except Exception as e:
        print(f"\n  FAIL — {type(e).__name__}: {e}")
        traceback.print_exc()
        return False
    finally:
        pya.terminate()


async def main():
    print("\n  DIAGNOSTIC AUDIO FOCUSPALS")
    print("  ========================\n")
    
    r1 = await test_audio_only()
    r2 = await test_audio_plus_screen()
    
    print("\n" + "="*55)
    print("  RESULTATS AUDIO")
    print("="*55)
    print(f"  [{'PASS' if r1 else 'FAIL'}] Test A: Micro seul")
    print(f"  [{'PASS' if r2 else 'FAIL'}] Test B: Micro + Screenshot")
    
    if r1 and r2:
        print("\n  Tout passe! Le crash dans tama_agent.py vient d'un bug de code, pas de l'API.")
    elif r1 and not r2:
        print("\n  Le micro seul marche, mais le combo micro+screen crash.")
        print("  -> C'est la combinaison simultanée qui pose problème.")
    elif not r1:
        print("\n  Le micro seul crash deja!")
        print("  -> Problème de format audio ou de configuration PyAudio.")

if __name__ == "__main__":
    asyncio.run(main())
