import asyncio, os, sys
sys.stdout.reconfigure(line_buffering=True)
from google import genai
from google.genai import types
from dotenv import load_dotenv

load_dotenv(r'c:\Users\xewi6\Desktop\FocusPals\FocusPals\agent\.env')
client = genai.Client(api_key=os.getenv('GEMINI_API_KEY'))

async def main():
    config = types.LiveConnectConfig(response_modalities=["AUDIO"])
    async with client.aio.live.connect(model='gemini-2.5-flash-native-audio-latest', config=config) as sess:
        print("Connected.")
        import mss
        from PIL import Image
        import io
        with mss.mss() as sct:
            screenshot = sct.grab(sct.monitors[0])
            img = Image.frombytes("RGB", screenshot.size, screenshot.rgb)
        img.thumbnail((1024, 512))
        buffer = io.BytesIO()
        img.save(buffer, format="JPEG", quality=40)
        blob = types.Blob(data=buffer.getvalue(), mime_type="image/jpeg")
        
        print("Sending media...")
        await sess.send_realtime_input(media=blob)
        print("Sent. Waiting 2s...")
        await asyncio.sleep(2)
        print("Sending text...")
        await sess.send_realtime_input(text="Hello")
        
        print("Receiving...")
        async for r in sess.receive():
            print("Received:", r)
            break

asyncio.run(main())
