"""
Test final: simule exactement ce que tama_agent.py fait (audio+screen+tools+text).
"""
import asyncio, io, os, time, traceback
from dotenv import load_dotenv
from google import genai
from google.genai import types
import pyaudio, mss
from PIL import Image

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent', '.env'))
client = genai.Client(api_key=os.getenv("GEMINI_API_KEY"))
MODEL = "gemini-2.5-flash-native-audio-latest"

SYSTEM_PROMPT = """You are Tama, a productivity coach. Respond in French.
EVERY TIME you receive a [SYSTEM] visual update, call classify_screen.
You are MUZZLED. DO NOT speak. Just call classify_screen."""

TOOLS = [types.Tool(function_declarations=[
    types.FunctionDeclaration(name="classify_screen", description="Classify screen.",
        parameters=types.Schema(type="OBJECT", properties={
            "category": types.Schema(type="STRING"),
            "alignment": types.Schema(type="STRING"),
        }, required=["category", "alignment"]))
])]

FORMAT = pyaudio.paInt16
CHANNELS = 1
SEND_SAMPLE_RATE = 16000
RECEIVE_SAMPLE_RATE = 24000
CHUNK_SIZE = 1024

def capture():
    with mss.mss() as sct:
        img = Image.frombytes("RGB", (s := sct.grab(sct.monitors[0])).size, s.rgb)
    img.thumbnail((1024, 512), Image.Resampling.LANCZOS)
    buf = io.BytesIO(); img.save(buf, format="JPEG", quality=40)
    return buf.getvalue()

async def main():
    DURATION = 30
    pya = pyaudio.PyAudio()
    mic_info = pya.get_default_input_device_info()
    print(f"Micro: {mic_info['name']}")
    
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(parts=[types.Part(text=SYSTEM_PROMPT)]),
        tools=TOOLS,
    )
    
    print(f"Connexion Live API...")
    start = time.time()
    crashed = False
    crash_reason = ""
    
    try:
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            print(f"Connecte! Test de {DURATION}s...")
            audio_q = asyncio.Queue()
            
            async def mic_task():
                stream = await asyncio.to_thread(
                    pya.open, format=FORMAT, channels=CHANNELS, rate=SEND_SAMPLE_RATE,
                    input=True, input_device_index=mic_info["index"], frames_per_buffer=CHUNK_SIZE)
                n = 0
                try:
                    while time.time() - start < DURATION:
                        data = await asyncio.to_thread(stream.read, CHUNK_SIZE, exception_on_overflow=False)
                        await session.send_realtime_input(audio=types.Blob(data=data, mime_type="audio/pcm"))
                        n += 1
                        if n % 100 == 0: print(f"  MIC: {n} chunks ({time.time()-start:.0f}s)")
                finally:
                    stream.close()
                    print(f"  MIC: done ({n} chunks)")
            
            async def screen_task():
                n = 0
                while time.time() - start < DURATION:
                    jpeg = await asyncio.to_thread(capture)
                    await session.send_realtime_input(media=types.Blob(data=jpeg, mime_type="image/jpeg"))
                    await session.send_realtime_input(
                        text=f"[SYSTEM] active_window: Test Window | duration: 5s | S: 0.0 | A: 1.0 | scheduled_task: coding | can_be_closed: False. Call classify_screen. MUZZLED.")
                    n += 1
                    print(f"  SCREEN: #{n} sent ({time.time()-start:.0f}s)")
                    await asyncio.sleep(8)
                print(f"  SCREEN: done ({n} screenshots)")
            
            async def recv_task():
                nonlocal crashed, crash_reason
                while time.time() - start < DURATION:
                    try:
                        turn = session.receive()
                        async for r in turn:
                            if r.tool_call:
                                for fc in r.tool_call.function_calls:
                                    print(f"  FC: {fc.name}({dict(fc.args)})")
                                    await session.send_tool_response(
                                        function_responses=[types.FunctionResponse(name=fc.name, response={"status":"ok"}, id=fc.id)])
                            if r.server_content and r.server_content.model_turn:
                                for p in r.server_content.model_turn.parts:
                                    if p.inline_data: audio_q.put_nowait(p.inline_data.data)
                                    if p.text: print(f"  TXT: {p.text[:60]}")
                    except asyncio.CancelledError:
                        break
                    except Exception as e:
                        crashed = True
                        crash_reason = f"{type(e).__name__}: {e}"
                        print(f"  RECV CRASH: {crash_reason}")
                        raise
            
            async def speaker_task():
                speaker = await asyncio.to_thread(
                    pya.open, format=FORMAT, channels=CHANNELS, rate=RECEIVE_SAMPLE_RATE, output=True)
                try:
                    while time.time() - start < DURATION:
                        try:
                            data = await asyncio.wait_for(audio_q.get(), timeout=1)
                            await asyncio.to_thread(speaker.write, data)
                        except asyncio.TimeoutError:
                            pass
                finally:
                    speaker.close()
            
            tasks = [
                asyncio.create_task(mic_task()),
                asyncio.create_task(screen_task()),
                asyncio.create_task(recv_task()),
                asyncio.create_task(speaker_task()),
            ]
            
            # Wait for all tasks or first crash
            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
            
            # Check if any task raised
            for t in done:
                if t.exception():
                    crashed = True
                    crash_reason = str(t.exception())
                    print(f"  TASK EXCEPTION: {crash_reason}")
            
            # Cancel remaining
            for t in pending:
                t.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
    
    except Exception as e:
        crashed = True
        crash_reason = f"{type(e).__name__}: {e}"
    
    elapsed = time.time() - start
    pya.terminate()
    
    print(f"\n{'='*50}")
    if crashed:
        print(f"  FAIL apres {elapsed:.1f}s")
        print(f"  Raison: {crash_reason}")
    else:
        print(f"  PASS — {elapsed:.0f}s stable!")
    print(f"{'='*50}")

asyncio.run(main())
