"""
FocusPals Agent — Tama 🥷
Proactive AI productivity coach powered by Gemini.

Background sentinel: captures your screen every ~15 seconds,
sends it to Gemini for analysis, and takes action if you procrastinate.

States:
  😌 CALM      — User is working. Tama reads her book quietly.
  😠 ANGRY     — Distraction detected! Tama closes the tab.
  😴 SLEEPING  — It's late (23h+). Tama tells you to go to bed.
"""

import asyncio
import io
import os
import sys
import time
from datetime import datetime
from enum import Enum

from dotenv import load_dotenv
from google import genai
from google.genai import types
from PIL import Image
import mss

load_dotenv()

# ─── Configuration ──────────────────────────────────────────

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
if not GEMINI_API_KEY:
    print("❌ GEMINI_API_KEY missing! Copy agent/.env.example to agent/.env")
    sys.exit(1)

client = genai.Client(api_key=GEMINI_API_KEY)
MODEL = "gemini-2.5-flash-preview"
SCAN_INTERVAL = 15  # seconds between each screenshot analysis


# ─── Tama's States ──────────────────────────────────────────

class TamaState(Enum):
    CALM = "calm"
    ANGRY = "angry"
    SLEEPING = "sleeping"


TAMA_FACES = {
    TamaState.CALM: r"""
    ╔══════════════════════════════════╗
    ║                                  ║
    ║         ╭─────────────╮          ║
    ║         │   ^     ^   │          ║
    ║         │             │          ║
    ║         │    ╰───╯    │          ║
    ║         │             │          ║
    ║         ╰─────────────╯          ║
    ║                                  ║
    ║    📖 Tama is reading quietly    ║
    ║       Everything is fine.        ║
    ╚══════════════════════════════════╝
""",
    TamaState.ANGRY: r"""
    ╔══════════════════════════════════╗
    ║          ╱╲          ╱╲          ║
    ║         ╭─────────────╮          ║
    ║         │  ╲╲   ╱╱    │          ║
    ║         │   👁   👁   │          ║
    ║         │    ╭───╮    │          ║
    ║         │   ╱     ╲   │          ║
    ║         ╰─────────────╯          ║
    ║                                  ║
    ║  💢 STOP PROCRASTINATING !!      ║
    ║     I'm closing that tab.        ║
    ╚══════════════════════════════════╝
""",
    TamaState.SLEEPING: r"""
    ╔══════════════════════════════════╗
    ║                          z Z    ║
    ║         ╭─────────────╮   Z     ║
    ║         │   ─     ─   │         ║
    ║         │             │         ║
    ║         │    ╰───╯    │         ║
    ║         │             │         ║
    ║         ╰─────────────╯         ║
    ║                                  ║
    ║  🌙 It's late... Go to sleep.   ║
    ║     You did well today.          ║
    ╚══════════════════════════════════╝
""",
}


# ─── Screen Capture ─────────────────────────────────────────

def capture_screen() -> bytes:
    """Take a screenshot and return compressed JPEG bytes."""
    with mss.mss() as sct:
        monitor = sct.monitors[1]
        screenshot = sct.grab(monitor)
        img = Image.frombytes("RGB", screenshot.size, screenshot.rgb)

    # Resize for Gemini (768px max, saves bandwidth)
    img.thumbnail((768, 768), Image.Resampling.LANCZOS)

    buffer = io.BytesIO()
    img.save(buffer, format="JPEG", quality=40)
    return buffer.getvalue()


# ─── Tab Closing (OS Action) ───────────────────────────────

def close_distracting_tab():
    """Force-close the active browser tab with Ctrl+W."""
    try:
        import pyautogui
        time.sleep(0.3)
        pyautogui.hotkey('ctrl', 'w')
        print("   ✅ Tab closed.")
        return True
    except Exception as e:
        print(f"   ❌ Failed to close tab: {e}")
        return False


# ─── Gemini Vision Analysis ─────────────────────────────────

ANALYSIS_PROMPT = """You are Tama, a strict productivity coach. Analyze this screenshot.

Reply with EXACTLY this JSON format, nothing else:
{
  "status": "PRODUCTIVE" or "DISTRACTED" or "UNCLEAR",
  "confidence": 0.0 to 1.0,
  "what_user_is_doing": "brief description",
  "tama_reaction": "what Tama says (1-2 sentences, in French, stay in character: strict but caring)",
  "should_close_tab": true or false
}

Rules:
- Coding, IDE, terminal, documentation, design tools = PRODUCTIVE
- YouTube tutorials about programming/coding = PRODUCTIVE  
- YouTube entertainment, social media, Netflix, memes, games = DISTRACTED
- If unsure, say UNCLEAR and don't close anything
- should_close_tab = true ONLY if clearly distracted on a browser tab
- Keep tama_reaction SHORT and IN FRENCH
"""


async def analyze_screenshot(screenshot_bytes: bytes) -> dict:
    """Send screenshot to Gemini and get productivity analysis."""
    try:
        response = await client.aio.models.generate_content(
            model=MODEL,
            contents=[
                types.Content(
                    parts=[
                        types.Part(text=ANALYSIS_PROMPT),
                        types.Part(
                            inline_data=types.Blob(
                                data=screenshot_bytes,
                                mime_type="image/jpeg",
                            )
                        ),
                    ]
                )
            ],
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
            ),
        )

        import json
        result = json.loads(response.text)
        return result

    except Exception as e:
        print(f"   ⚠️ Analysis error: {e}")
        return {
            "status": "UNCLEAR",
            "confidence": 0,
            "what_user_is_doing": "Could not analyze",
            "tama_reaction": "",
            "should_close_tab": False,
        }


# ─── Display ────────────────────────────────────────────────

def clear_screen():
    os.system('cls' if os.name == 'nt' else 'clear')


def display_tama(state: TamaState, message: str = "", scan_count: int = 0):
    """Show Tama's current state in the terminal."""
    clear_screen()

    print("=" * 42)
    print("  FocusPals — Tama Agent 🥷")
    print("  Gemini Live Agent Challenge")
    print("=" * 42)
    print(TAMA_FACES[state])

    if message:
        print(f"  💬 \"{message}\"")
        print()

    now = datetime.now().strftime("%H:%M:%S")
    print(f"  🕐 {now}  |  Scans: {scan_count}  |  Every {SCAN_INTERVAL}s")
    print(f"  State: {state.value.upper()}")
    print()
    print("  Press Ctrl+C to stop.")
    print("─" * 42)


# ─── Main Sentinel Loop ────────────────────────────────────

async def run_sentinel():
    """Main loop: screenshot → analyze → react → repeat."""

    current_state = TamaState.CALM
    scan_count = 0
    consecutive_distractions = 0

    display_tama(current_state, "Initializing... I'm watching you.", scan_count)
    await asyncio.sleep(2)

    while True:
        scan_count += 1
        hour = datetime.now().hour

        # ── Night mode (23h - 6h) ──
        if hour >= 23 or hour < 6:
            current_state = TamaState.SLEEPING
            display_tama(
                current_state,
                "Il est tard... Va dormir. Tu as assez travaillé.",
                scan_count,
            )
            await asyncio.sleep(60)  # Check less often at night
            continue

        # ── Capture & Analyze ──
        display_tama(current_state, "📸 Scanning your screen...", scan_count)

        screenshot = await asyncio.to_thread(capture_screen)
        analysis = await analyze_screenshot(screenshot)

        status = analysis.get("status", "UNCLEAR")
        reaction = analysis.get("tama_reaction", "")
        doing = analysis.get("what_user_is_doing", "")
        should_close = analysis.get("should_close_tab", False)
        confidence = analysis.get("confidence", 0)

        print(f"\n  📊 Analysis: {status} (confidence: {confidence:.0%})")
        print(f"  👀 Doing: {doing}")

        # ── React based on status ──
        if status == "DISTRACTED" and confidence > 0.6:
            consecutive_distractions += 1
            current_state = TamaState.ANGRY
            display_tama(current_state, reaction, scan_count)

            # Close tab on 2nd consecutive distraction (give 1 chance)
            if should_close and consecutive_distractions >= 2:
                print("\n  🔥 CLOSING DISTRACTING TAB...")
                await asyncio.to_thread(close_distracting_tab)
                consecutive_distractions = 0

            elif consecutive_distractions == 1:
                print("\n  ⚠️ First warning... One more and I close it.")

        elif status == "PRODUCTIVE":
            consecutive_distractions = 0
            current_state = TamaState.CALM
            display_tama(current_state, reaction or "Bien, continue.", scan_count)

        else:
            # UNCLEAR — don't change state
            display_tama(current_state, "Hmm... je t'observe.", scan_count)

        # ── Wait for next scan ──
        await asyncio.sleep(SCAN_INTERVAL)


# ─── Entry Point ────────────────────────────────────────────

if __name__ == "__main__":
    try:
        asyncio.run(run_sentinel())
    except KeyboardInterrupt:
        print("\n\n👋 Tama: Au revoir ! Reste productif sans moi...")
