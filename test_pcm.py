import asyncio
import os
from google import genai
from google.genai import types
from dotenv import load_dotenv

load_dotenv(r'c:\Users\xewi6\Desktop\FocusPals\FocusPals\agent\.env')
client = genai.Client(api_key=os.getenv('GEMINI_API_KEY'))

async def main():
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
    )
    print("Connecting...")
    async with client.aio.live.connect(model='gemini-2.5-flash-native-audio-latest', config=config) as sess:
        print("Connected.")
        
        # Test PCM headerless audio without rate
        blob = types.Blob(data=b'\x00' * 1024, mime_type='audio/pcm')
        await sess.send_realtime_input(audio=blob)
        print("Sent audio/pcm")
        
        async for r in sess.receive():
            print("Received something:", r)
            break

asyncio.run(main())
