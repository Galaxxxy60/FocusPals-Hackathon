"""
FocusPals Crash Diagnostic v2 — Tests each component with proper timeouts.
Each test opens a session, sends content, waits, then reports pass/fail.
"""
import asyncio
import io
import os
import time
import traceback

from dotenv import load_dotenv
from google import genai
from google.genai import types
from PIL import Image
import mss

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent', '.env'))
client = genai.Client(api_key=os.getenv("GEMINI_API_KEY"))
MODEL = "gemini-2.5-flash-native-audio-latest"

FULL_SYSTEM_PROMPT = """You are Tama, a strict but fair productivity coach inside the app FocusPals.
You are in a LIVE voice call with the user (Nicolas). You can see their screens (all monitors merged).

Your personality:
- Strict Asian student archetype, but you want to help.
- Use sarcasm if the user procrastinates productively.
- Keep your answers VERY SHORT and spoken in French (1 or 2 small sentences).

IMPORTANT - INITIAL STATE:
When you first connect, DO NOT SAY ANYTHING. We start in "Free Session Mode".

Your job:
EVERY TIME you receive a [SYSTEM] visual update, you MUST call `classify_screen` with:
- category: One of SANTE, ZONE_GRISE, FLUX, BANNIE, PROCRASTINATION_PRODUCTIVE
- alignment: 1.0, 0.5, or 0.0

RULE OF SILENCE: You are MUZZLED by default. DO NOT speak. Just call classify_screen.
"""

SIMPLE_PROMPT = "Tu es Tama, un coach de productivite. Reponds en francais, sois bref."

TOOLS = [
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
                    },
                    required=["category", "alignment"]
                )
            ),
        ]
    )
]

def capture_screen() -> bytes:
    with mss.mss() as sct:
        monitor = sct.monitors[0]
        screenshot = sct.grab(monitor)
        img = Image.frombytes("RGB", screenshot.size, screenshot.rgb)
    img.thumbnail((1024, 512), Image.Resampling.LANCZOS)
    buffer = io.BytesIO()
    img.save(buffer, format="JPEG", quality=40)
    return buffer.getvalue()


async def test(name, system_prompt=None, tools=None, send_screen=False, send_text=None, hold_seconds=15):
    """Open session, optionally send stuff, hold for N seconds, report."""
    print(f"\n{'='*55}")
    print(f"  TEST: {name}")
    print(f"{'='*55}")

    config_kwargs = {"response_modalities": ["AUDIO"]}
    if system_prompt:
        config_kwargs["system_instruction"] = types.Content(parts=[types.Part(text=system_prompt)])
    if tools:
        config_kwargs["tools"] = tools
    config = types.LiveConnectConfig(**config_kwargs)

    try:
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            print(f"  [OK] Connexion ouverte")

            if send_screen:
                jpeg = await asyncio.to_thread(capture_screen)
                blob = types.Blob(data=jpeg, mime_type="image/jpeg")
                await session.send_realtime_input(media=blob)
                print(f"  [OK] Screenshot envoye ({len(jpeg)} bytes)")

            if send_text:
                await session.send_realtime_input(text=send_text)
                print(f"  [OK] Texte envoye: {send_text[:80]}...")

            # Listen for responses / crashes with a timeout
            async def listen():
                while True:
                    try:
                        turn = session.receive()
                        async for response in turn:
                            if response.tool_call:
                                for fc in response.tool_call.function_calls:
                                    print(f"  [FC] {fc.name}({dict(fc.args)})")
                                    await session.send_tool_response(
                                        function_responses=[
                                            types.FunctionResponse(name=fc.name, response={"status": "ok"}, id=fc.id)
                                        ]
                                    )
                            if response.server_content and response.server_content.model_turn:
                                parts = response.server_content.model_turn.parts
                                for p in parts:
                                    if p.text:
                                        print(f"  [TXT] {p.text[:100]}")
                                    elif p.inline_data:
                                        print(f"  [AUDIO] {len(p.inline_data.data)} bytes")
                    except Exception as e:
                        print(f"  [ERR] receive: {e}")
                        raise

            try:
                await asyncio.wait_for(listen(), timeout=hold_seconds)
            except asyncio.TimeoutError:
                pass  # Normal — we just held the session open
            except Exception as e:
                print(f"  [CRASH] {type(e).__name__}: {e}")
                return False

        print(f"  PASS — Session stable pendant {hold_seconds}s")
        return True

    except Exception as e:
        print(f"  FAIL — {type(e).__name__}: {e}")
        return False


async def main():
    print("\n" + "="*55)
    print("  FOCUSPALS CRASH DIAGNOSTIC v2")
    print("="*55)

    results = {}

    # 1) Minimal: simple prompt, just hold open
    results["1-Simple prompt only"] = await test(
        "Simple prompt seul", system_prompt=SIMPLE_PROMPT, hold_seconds=10
    )

    # 2) Full system prompt, no tools, no screen
    results["2-Full prompt only"] = await test(
        "Full system prompt", system_prompt=FULL_SYSTEM_PROMPT, hold_seconds=10
    )

    # 3) Full prompt + tools (no screen)
    results["3-Full + tools"] = await test(
        "Full prompt + tools", system_prompt=FULL_SYSTEM_PROMPT, tools=TOOLS, hold_seconds=10
    )

    # 4) Simple prompt + screenshot
    results["4-Simple + screen"] = await test(
        "Simple prompt + screenshot", system_prompt=SIMPLE_PROMPT, send_screen=True, hold_seconds=10
    )

    # 5) Full prompt + tools + screenshot (no text)
    results["5-Full + tools + screen"] = await test(
        "Full + tools + screenshot", system_prompt=FULL_SYSTEM_PROMPT, tools=TOOLS,
        send_screen=True, hold_seconds=10
    )

    # 6) Full combo: prompt + tools + screenshot + system text
    sys_text = "[SYSTEM] active_window: Visual Studio Code | duration: 5s | S: 0.0 | A: 1.0 | scheduled_task: coding | can_be_closed: False. Call classify_screen. YOU ARE BIOLOGICALLY MUZZLED. DO NOT OUTPUT TEXT/WORDS. ONLY call classify_screen."
    results["6-FULL COMBO"] = await test(
        "FULL COMBO (prompt+tools+screen+text)", system_prompt=FULL_SYSTEM_PROMPT, tools=TOOLS,
        send_screen=True, send_text=sys_text, hold_seconds=15
    )

    # ─── SUMMARY ───
    print("\n" + "="*55)
    print("  RESULTATS")
    print("="*55)
    for k, v in results.items():
        s = "PASS" if v else "FAIL"
        print(f"  [{s}] {k}")

    fails = [k for k, v in results.items() if not v]
    if not fails:
        print("\n  Tout passe! Le crash vient de l'audio (micro/speakers) ou du timing.")
    else:
        print(f"\n  Premier echec: {fails[0]}")


if __name__ == "__main__":
    asyncio.run(main())
