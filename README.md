# FocusPals 🥷 — Your AI Productivity Coach as a 3D Desktop Pet

> **Category: Live Agents** | Gemini Live Agent Challenge 2026

FocusPals is a **real-time AI productivity guardian** that lives on your desktop as a 3D animated ninja cat named **Tama**. She watches your screen, listens to your voice, and physically closes distracting tabs when you procrastinate — all powered by **Gemini's Multimodal Live API** with native speech-to-speech audio.

Unlike traditional productivity apps that rely on blocklists or timers, Tama **understands context**. She knows the difference between a YouTube tutorial for work and a YouTube rabbit hole for fun. She has a personality, gets annoyed when you ignore her warnings, and celebrates when you stay focused.

---

## ✨ Key Features

| Feature | Description |
|---------|-------------|
| 🎙️ **Real-time Voice Conversation** | Talk to Tama naturally — she responds with expressive speech. Supports barge-in (interruptions). |
| 👁️ **Multi-Monitor Screen Vision** | Captures all screens every 5 seconds. Gemini classifies what you're doing (work vs. distraction). |
| 🤖 **Intelligent Strike System** | Tama physically closes distracting tabs with an animated drone strike — synchronized to the frame. |
| 🧠 **A.S.C. Engine** | Alignment-Suspicion-Control — a mathematical behavior engine that governs Tama's mood and reactions. |
| 🎭 **9 Emotional States** | Gemini self-reports mood (calm → furious). Each mood drives unique facial expressions and body animations. |
| 🏋️ **Pomodoro Sessions** | Configurable deep work sessions with smart break suggestions. |
| 🌐 **4 Languages** | English, French, Japanese, Chinese — fully voice-driven, no text UI. |
| ☁️ **Cloud Analytics** | Session logs and strike events are persisted to Google Cloud Firestore for productivity tracking. |

---

## 🏗️ Architecture — Privacy-First, Edge-to-Cloud

FocusPals utilizes a **Privacy-First, Edge-to-Cloud architecture**. Because processing continuous screen captures and real-time audio requires zero-latency and strict user privacy, the core Multimodal Live agent runs **locally on the user's desktop (Edge)**. However, it leverages **Google Cloud (Firestore)** as its backend Control Plane to securely persist productivity analytics, log intervention events (Strikes), and build long-term memory across devices.

```
┌─────────────────────────────────────────────────────────────────┐
│                    User's Desktop (Edge)                        │
│                                                                 │
│  ┌──────────────────────┐    ┌──────────────────────────────┐   │
│  │   Godot 4 Overlay    │    │      Python Agent             │   │
│  │   (3D Tama model)    │◄──►│                               │   │
│  │   • Animations       │ WS │  • Gemini Live API ──────────────────┐
│  │   • Radial Menu      │    │    (voice + vision)           │   │  │
│  │   • Settings Panel   │    │  • A.S.C. Engine (S,A,C)      │   │  │
│  │   • Strike Visuals   │    │  • Screen Capture (mss)       │   │  │
│  └──────────────────────┘    │  • OS Control (pywinauto)     │   │  │
│         ▲                    │  • Audio I/O (pyaudio)        │   │  │
│         │ Click-through      │  • Firestore Sync ──────────────────┐│
│         │ (WS_EX_TRANSPARENT)│                               │   ││││
│         └────────────────────┴───────────────────────────────┘   ││││
└─────────────────────────────────────────────────────────────────┘││││
                                                                   ││││
┌─────────────────────────────────────────────────────────────────┐││││
│                    Google Cloud Platform                         ││││
│                                                                  ││││
│  ┌──────────────────────┐    ┌──────────────────────────────┐   ││││
│  │   Gemini Live API    │◄───┘ Speech-to-Speech (native)     │   │││
│  │   (Google servers)   │      Audio + Vision + Tools        │   │││
│  │   gemini-2.5-flash   │      Affective Dialog + Thinking   │   │││
│  └──────────────────────┘                                    │   │││
│                                                              │   │││
│  ┌──────────────────────┐                                    │   │││
│  │   Cloud Firestore    │◄───────────────────────────────────┘   ││
│  │   (europe-west1)     │    Strike logs, session analytics,     ││
│  │                      │    productivity metrics, device memory  ││
│  └──────────────────────┘                                        ││
│                                                                  ││
│  ┌──────────────────────┐                                        ││
│  │   Cloud Run          │    Deployed proxy server (optional)     ││
│  │   tama-cloud-agent   │    Demonstrates full cloud hosting      ││
│  └──────────────────────┘                                        ││
└──────────────────────────────────────────────────────────────────┘│
```

### Why Edge-to-Cloud?

| Concern | Why Local (Edge) | Why Cloud |
|---------|-----------------|-----------|
| **Latency** | Screen + audio must be processed in <100ms | Analytics don't need real-time |
| **Privacy** | Screen captures never leave the user's machine* | Only anonymized event logs are stored |
| **OS Access** | `pywinauto` needs local window handles | Firestore provides cross-device memory |
| **Reliability** | App works offline — cloud sync is best-effort | Dashboard/analytics always available |

*\*Screen images are sent directly to Google's Gemini API servers — never through our infrastructure.*

---

## 🚀 Quick Start

### Prerequisites

- **Windows 10/11** (required for desktop overlay + window management)
- **Python 3.10+**
- **Google Cloud account** (for Firestore analytics)
- **Gemini API key** (get one free at [aistudio.google.com](https://aistudio.google.com/apikey))

### Installation

```bash
# 1. Clone the repository
git clone https://github.com/Galaxxxy60/FocusPals-Hackathon.git
cd FocusPals-Hackathon/FocusPals

# 2. Install Python dependencies
cd agent
pip install -r requirements.txt

# 3. Set up your Gemini API key
#    Option A: Create agent/.env file
echo GEMINI_API_KEY=your_key_here > .env

#    Option B: Enter it in the Settings panel after launch (⚙️ icon)
```

### Google Cloud Setup (Firestore)

```bash
# 1. Install Google Cloud CLI (if not already)
# Download from: https://cloud.google.com/sdk/docs/install

# 2. Authenticate
gcloud auth login
gcloud auth application-default login   # ← Check ALL boxes when prompted!

# 3. Set project
gcloud config set project focuspals-cloud-agent

# 4. Enable Firestore API (already done for our project)
gcloud services enable firestore.googleapis.com
```

> **Note:** Firestore sync is **best-effort**. The app works perfectly without cloud connectivity — analytics are simply not persisted.

### Launch

```bash
# Option 1: Double-click (recommended)
Start_FocusPals.bat

# Option 2: Manual
cd agent
python tama_agent.py
```

Tama will appear on the right edge of your screen. Move your mouse to the right edge (bottom third) to open the radial menu.

---

## 🎮 How to Use

1. **First Launch** → Tama appears and introduces herself. Set your API key in Settings (⚙️) if not already in `.env`.
2. **Start a Work Session** → Click the ⚡ button in the radial menu, or click the drone's "Start" button.
3. **Work normally** → Tama watches your screen silently. She only speaks when something is wrong.
4. **Get distracted?** → Tama's suspicion rises. She warns you verbally, then sends a drone strike to close the tab.
5. **Talk to Tama** → Click 💬 in the radial menu for a casual conversation (no surveillance).
6. **Take a break** → Tama suggests breaks based on your session duration. Accept or refuse.

---

## 🧠 Technical Deep Dive

### Google Cloud Services Used

| Service | Purpose | Integration Point |
|---------|---------|-------------------|
| **Gemini Live API** | Real-time multimodal AI (voice + vision + tools) | `gemini_session.py` — WebSocket streaming |
| **Google GenAI SDK** | Python client for Gemini | `google-genai` package, `client.aio.live.connect()` |
| **Cloud Firestore** | Productivity analytics persistence | `firestore_sync.py` — strike logs, session data |
| **Cloud Run** | Deployed agent proxy (demonstrates cloud hosting) | `tama-cloud-agent` service on `europe-west1` |

### Gemini Live API Features

- **Native Speech-to-Speech** — Single model inference (no STT→LLM→TTS pipeline)
- **Affective Dialog** — Tama adapts her vocal tone to the user's emotional state
- **Server-side VAD** — Natural turn-taking with barge-in support
- **Context Window Compression** — Unlimited session length (SlidingWindow)
- **Thinking Budget** — 512-token reasoning before screen classification
- **Session Resume** — Seamless reconnection every ~10 minutes without context loss
- **Proactive Audio** — Gemini decides when to speak without explicit prompting
- **Function Calling** — `classify_screen`, `close_distracting_tab`, `report_mood`, `set_current_task`, `manage_break`

### A.S.C. Engine (Alignment-Suspicion-Control)

A deterministic mathematical engine that governs Tama's behavior:

- **Alignment (A)** — How well the current activity aligns with the user's stated task (0.0 → 1.0)
- **Suspicion (S)** — A gauge (0 → 10) that rises with misalignment and decays with compliance
- **Confidence (C)** — Trust level (0.1 → 1.0) that modulates S decay speed. Lost in seconds, regained in minutes.

The LLM (Gemini) provides the *judgment* (A + category), the math does the *enforcement* (S, C thresholds), and the mood engine translates both into *natural behavior*.

### Godot 4 Frontend

- **3D animated character** with spring bone physics (hair, tail, accessories)
- **Gaze tracking** — Tama looks at the cursor and interesting screen areas
- **9 facial expression states** driven by Gemini's mood self-reports
- **Frame-precise strike sync** using bone markers in the animation rig
- **Click-through overlay** — Transparent, always-on-top window that doesn't interfere with work
- **Radial menu** — Edge-triggered semi-circular menu for all interactions

---

## 📂 Project Structure

```
FocusPals/
├── Start_FocusPals.bat              # One-click launcher
├── README.md                        # This file
├── ARCHITECTURE.md                  # Full technical specification
│
├── agent/                           # Python backend
│   ├── tama_agent.py                # Entry point (orchestrator)
│   ├── config.py                    # Constants, state dict, A.S.C. engine
│   ├── gemini_session.py            # Gemini Live loop, prompts, tools, screen capture
│   ├── godot_bridge.py              # WebSocket server, Godot launcher, edge monitor
│   ├── firestore_sync.py            # ☁️ Google Cloud Firestore integration
│   ├── flash_lite.py                # Secondary Gemini agent (classification verification)
│   ├── mood_engine.py               # Emotional state machine
│   ├── audio.py                     # Mic management, VAD
│   ├── ui.py                        # System tray, display
│   ├── hand_animation.py            # Tab close animation (subprocess)
│   ├── crash_logger.py              # Crash logging, state dumps
│   ├── tama_memory.py               # Long-term memory (sessions, user name)
│   └── requirements.txt             # Python dependencies
│
└── godot/                           # Godot 4.4 frontend
    ├── focuspals.exe                # Pre-built Godot executable
    ├── main.gd                      # WebSocket client, animation state machine
    ├── tama_anim_tree.gd            # AnimationTree controller
    ├── settings_panel.gd            # Settings UI (mic, API key, language, volume)
    ├── settings_radial.gd           # Edge-triggered radial menu
    ├── gaze_modifier.gd             # Cursor/screen gaze tracking
    ├── spring_bones.gd              # Physics-based bone simulation
    └── Tama._ver2.glb               # 3D model with animations
```

---

## 🔑 Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `GEMINI_API_KEY` | Yes | Your Gemini API key (in `agent/.env`) |
| `GOOGLE_APPLICATION_CREDENTIALS` | No | Path to GCP service account key (auto-detected) |

---

## 📊 Cloud Deployment Proof

The following Google Cloud services are active on project `focuspals-cloud-agent`:

- **Firestore** (`europe-west1`) — Stores strike events, session data, and productivity metrics
- **Cloud Run** — `tama-cloud-agent` service deployed and serving
- **Artifact Registry** — Container images for Cloud Run deployment

Proof of deployment can be verified at:
- Firestore Console: `console.cloud.google.com/firestore/databases/-default-/data/`
- Cloud Run Console: `console.cloud.google.com/run` → `tama-cloud-agent`

---

## 🛠️ Built With

- **[Google Gemini Live API](https://ai.google.dev/gemini-api/docs/live)** — Multimodal real-time AI (v1alpha)
- **[Google GenAI SDK](https://pypi.org/project/google-genai/)** — Python client
- **[Google Cloud Firestore](https://cloud.google.com/firestore)** — NoSQL document database
- **[Google Cloud Run](https://cloud.google.com/run)** — Serverless container hosting
- **[Godot Engine 4.4](https://godotengine.org/)** — 3D game engine (desktop overlay)
- **[Blender](https://www.blender.org/)** — 3D modeling & animation
- **[Rokoko](https://www.rokoko.com/)** — Motion capture for character animations

---

## 👥 Team

Built for the **Gemini Live Agent Challenge** hackathon.

---

## 📄 License

This project was created for the Gemini Live Agent Challenge 2026.
