import asyncio
import os
import sys
sys.stdout.reconfigure(line_buffering=True)
from google import genai
from google.genai import types
from dotenv import load_dotenv

load_dotenv(r'c:\Users\xewi6\Desktop\FocusPals\FocusPals\agent\.env')
client = genai.Client(api_key=os.getenv('GEMINI_API_KEY'))

TOOLS = [
    types.Tool(
        function_declarations=[
            types.FunctionDeclaration(
                name="close_distracting_tab",
                description="Close tab",
                parameters=types.Schema(
                    type="OBJECT",
                    properties={"reason": types.Schema(type="STRING", description="Reason for closing")},
                    required=["reason"],
                ),
            )
        ]
    )
]

SYSTEM_PROMPT = "You are Tama"

async def main():
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(parts=[types.Part(text=SYSTEM_PROMPT)]),
        tools=TOOLS
    )
    print("Connecting...")
    try:
        async with client.aio.live.connect(model='gemini-2.5-flash-native-audio-latest', config=config) as sess:
            print("Connected.")
            await asyncio.sleep(2)
            print("Sending text...")
            await sess.send_realtime_input(text="Hello")
            async for r in sess.receive():
                print("Received:", r)
                break
    except Exception as e:
        print(f"FAILED: {e}")

asyncio.run(main())
