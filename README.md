# FocusPals 🥷

**Tama** — Your AI productivity coach that watches over you as a 3D desktop pet.

## Architecture

```
┌─────────────────────────────────────────────┐
│  Python Agent (agent/tama_agent.py)         │
│  • Gemini Live API (voice + vision)         │
│  • Screen capture + window monitoring       │
│  • Suspicion Index / Alignment engine       │
│         │                                   │
│         ▼  WebSocket (ws://localhost:8080)   │
│                                             │
│  Godot 4 (godot/)                           │
│  • 3D model rendering (Tama.glb, ~512 poly) │
│  • Transparent overlay window               │
│  • Animations driven by suspicion index     │
│  • ~25 MB RAM total                         │
└─────────────────────────────────────────────┘
```

## Quick Start

1. **Start the AI Agent:**
   ```bash
   cd agent
   python tama_agent.py
   ```

2. **Start the 3D Overlay:**
   Open `godot/project.godot` in Godot 4.4 and press F5.

See `godot/README.md` for full setup instructions.
