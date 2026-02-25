"""Quick test: can we open a Live API session with the new billing?"""
import asyncio, os
from dotenv import load_dotenv
from google import genai
from google.genai import types

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent', '.env'))

client = genai.Client(api_key=os.getenv("GEMINI_API_KEY"))
MODEL = "gemini-2.5-flash-native-audio-latest"

async def test():
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
    )
    print(f"🔌 Tentative de connexion Live API avec modèle: {MODEL}...")
    try:
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            print("✅ CONNEXION LIVE API RÉUSSIE !")
            # Send a simple text and see if we get a response
            await session.send_client_content(
                turns=[types.Content(parts=[types.Part(text="Dis juste: test réussi")])]
            )
            turn = session.receive()
            async for response in turn:
                if response.server_content and response.server_content.model_turn:
                    print("✅ Réponse reçue de Gemini Live !")
                    break
            print("🎉 Tout fonctionne ! On peut lancer Tama.")
    except Exception as e:
        print(f"❌ ERREUR: {type(e).__name__}: {e}")

asyncio.run(test())
