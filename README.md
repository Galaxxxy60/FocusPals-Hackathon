# FocusPals 🥷

**Tama** — Your AI productivity coach that watches over you as a 3D desktop pet.

## Quick Start

Double-click `Start_FocusPals.bat` — that's it.

Or manually:
```bash
cd agent
python tama_agent.py
```

## Architecture

> **📖 See [ARCHITECTURE.md](ARCHITECTURE.md) for the full technical spec.**

```
Python Agent (6 modules)
    ├── Gemini Live API (voice + vision)
    ├── Screen capture + A.S.C. engine
    │
    ↕ WebSocket (ws://localhost:8080)
    │
Godot 4 Overlay (~25 MB RAM)
    ├── 3D model + animations
    ├── Radial settings menu
    └── Transparent click-through window
```

## Project Structure

```
agent/
├── tama_agent.py        # Entry point (orchestrator)
├── config.py            # Constants, state dict, A.S.C. engine
├── audio.py             # Mic management, VAD
├── ui.py                # Display, tray icon, settings
├── godot_bridge.py      # WebSocket, Godot launcher, edge monitor
├── gemini_session.py    # Gemini Live loop, screen capture, tools
└── hand_animation.py    # Close-tab animation (subprocess)

godot/
├── main.gd              # WebSocket client, animation state machine
├── settings_radial.gd   # Radial menu (edge-triggered)
└── mic_panel.gd         # Mic selection + VU meter
```

## Requirements

- Python 3.10+
- Godot 4.4 (for development only — pre-built .exe included)
- `GEMINI_API_KEY` in `agent/.env`
## Backlog

- **[HIGH PRIORITY] Session Time**: Add a setting at the very top of the Settings panel to adjust the duration of a Deep Work session (e.g., 25min, 50min, custom).
- ~~**Settings UI**: When an API key is already valid and the user clicks to edit it, instead of showing an empty field, display an obfuscated version of the key (e.g., first few and last few characters visible, rest hidden).~~ ✅ Done
- **Settings i18n**: The Settings panel labels ("Clé valide", "Permissions", "Durée du Deep Work", etc.) are hardcoded in French. They should switch to English when the language is set to EN.
