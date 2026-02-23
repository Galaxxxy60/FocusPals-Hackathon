# FocusPals — Godot 4 Frontend

Ultra-lightweight 3D overlay for Tama, replacing the Electron + React + Three.js stack.

## Requirements

- **Godot 4.4** — [Download here](https://godotengine.org/download/)
- **Python 3.10+** — For the Tama agent backend

## Setup

### 1. Open in Godot
1. Download and extract Godot 4.4
2. Open Godot → "Import" → Navigate to this `godot/` folder → Select `project.godot`
3. The project will open in the editor

### 2. Import Tama Model
1. Copy `Tama.glb` from `public/Tama.glb` into `godot/models/Tama.glb`
2. Godot will auto-import it
3. In the editor, open `scenes/main.tscn`
4. Drag `Tama.glb` from the FileSystem panel onto the `TamaModel` node
5. If the model has animations, an `AnimationPlayer` node will be created automatically

### 3. Run
1. Start the Python backend first:
   ```
   cd agent
   python tama_agent.py
   ```
2. Then press F5 in Godot (or click ▶ Play)

### 4. Export (Build .exe)
1. In Godot: Project → Export → Add Windows Desktop preset
2. Click "Export Project" → Choose output location
3. The resulting `.exe` will be ~30-40 MB (vs ~150 MB for Electron)

## Architecture

```
Python Agent (tama_agent.py)
    ↓ WebSocket (ws://localhost:8080)
Godot 4 (this project)
    ↓ Updates 3D model + animations
Transparent Window Overlay (native, no browser)
```

## RAM Usage

| Component          | Estimated RAM  |
|--------------------|----------------|
| Godot runtime      | ~15-20 MB      |
| Tama 3D scene      | ~2-5 MB        |
| WebSocket client   | ~1 MB          |
| **Total**          | **~20-30 MB**  |

Compare: Electron version used ~250 MB.
