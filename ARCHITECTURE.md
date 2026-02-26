# FocusPals — Architecture & Technical Spec 🥷

> **Ce document est la source de vérité unique pour tout agent IA ou développeur qui touche au projet.**
> Dernière mise à jour : 2026-02-26

---

## 1. Vue d'ensemble

FocusPals est un **coach de productivité IA** sous forme de mascotte 3D desktop. Tama 🥷 surveille tes écrans en temps réel, écoute ta voix, et te rappelle à l'ordre quand tu procrastines.

**Stack technique :**
- **Backend** : Python 3.10+ (agent IA asynchrone)
- **Frontend** : Godot 4.4 (overlay 3D transparent, ~25 MB RAM)
- **IA** : Gemini Live API (audio bidirectionnel + vision temps réel)
- **Communication** : WebSocket (`ws://localhost:8080`)
- **OS** : Windows uniquement (WinAPI pour click-through, window management)

---

## 2. Structure des fichiers

```
FocusPals/
├── Start_FocusPals.bat          # Point d'entrée utilisateur (double-click)
├── ARCHITECTURE.md              # CE DOCUMENT — source de vérité
├── README.md                    # Quick start
│
├── agent/                       # Backend Python (6 modules)
│   ├── tama_agent.py            # Entry point (~65 lignes) — orchestre tout
│   ├── config.py                # Constantes, API client, state dict, A.S.C. engine
│   ├── audio.py                 # Mic management, VAD, hot-swap
│   ├── ui.py                    # Display console, system tray, settings popup
│   ├── godot_bridge.py          # WebSocket server, Godot launcher, click-through, edge monitor
│   ├── gemini_session.py        # Prompts, tools, screen capture, boucle Gemini Live
│   ├── hand_animation.py        # Animation "main qui ferme" (script séparé lancé en subprocess)
│   ├── .env                     # GEMINI_API_KEY=xxx (non commité)
│   └── requirements.txt         # pyaudio, mss, pygetwindow, pystray, websockets, google-genai, etc.
│
└── godot/                       # Frontend Godot 4.4
    ├── project.godot            # Config projet Godot
    ├── focuspals.exe            # Build exporté (lancé par Python)
    ├── main.gd                  # Contrôleur principal (WebSocket client, animations, état)
    ├── settings_radial.gd       # Menu radial semi-circulaire (bord droit écran)
    ├── mic_panel.gd             # Panel de sélection micro + VU meter natif
    └── scenes/main.tscn         # Scène 3D avec Tama.glb
```

---

## 3. Flux de données (Architecture)

```
┌─────────────────────────────────────────────────────────────┐
│                      Python Agent                           │
│                                                             │
│  tama_agent.py (entry)                                      │
│    ├── config.py          ← state dict partagé (30+ vars)   │
│    ├── audio.py           ← mic listing, VAD                │
│    ├── ui.py              ← tray icon, display              │
│    ├── godot_bridge.py    ← WebSocket server + Godot mgmt   │
│    └── gemini_session.py  ← Gemini Live loop + screen cap   │
│              │                                              │
│              ▼                                              │
│    ┌─────────────────┐                                      │
│    │ Gemini Live API  │  Audio bidirectionnel + Vision       │
│    │ (WebSocket)      │  Model: gemini-2.5-flash-native     │
│    └─────────────────┘                                      │
│              │                                              │
│              ▼                                              │
│    Function Calling: classify_screen, close_distracting_tab,│
│                      set_current_task                       │
│                                                             │
│    ──── WebSocket ws://localhost:8080 ────                   │
│              │                                              │
└──────────────┼──────────────────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────────────────┐
│                      Godot 4 Frontend                       │
│                                                             │
│  main.gd                                                    │
│    ├── WebSocket client (reçoit état, commandes)            │
│    ├── Animation state machine (HIDDEN→PEEK→ACTIVE→LEAVE)  │
│    ├── Radial menu (settings_radial.gd) — edge detection    │
│    └── Mic panel (mic_panel.gd) — sélection + VU meter     │
│                                                             │
│  Fenêtre transparente, always-on-top, click-through         │
│  (WS_EX_TRANSPARENT + WS_EX_TOOLWINDOW via WinAPI)         │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. Shared State (`config.state`)

Toutes les variables globales vivent dans un **dict unique** `state` dans `config.py`. Chaque module lit/écrit `state["key"]` — pas de `global`.

### Clés principales :

| Clé | Type | Description |
|-----|------|-------------|
| `is_session_active` | bool | Deep Work session en cours |
| `session_start_time` | float | Timestamp début session |
| `current_mode` | str | `"libre"`, `"conversation"`, `"deep_work"` |
| `current_suspicion_index` | float | Jauge S (0.0 → 10.0) |
| `current_alignment` | float | A (1.0=aligné, 0.5=doute, 0.0=misaligned) |
| `current_category` | str | `SANTE`, `ZONE_GRISE`, `FLUX`, `BANNIE`, `PROCRASTINATION_PRODUCTIVE` |
| `current_task` | str/None | Tâche déclarée par l'utilisateur |
| `force_speech` | bool | Force Tama à parler au prochain scan |
| `selected_mic_index` | int/None | Index PyAudio du micro actif |
| `connected_ws_clients` | set | Clients WebSocket Godot connectés |
| `godot_hwnd` | int/None | Handle Windows de la fenêtre Godot |
| `radial_shown` | bool | Menu radial actuellement visible |
| `_mouse_was_away` | bool | Anti-loop : souris a quitté la zone edge |

---

## 5. A.S.C. (Alignment Suspicion Control)

Le cœur du système de surveillance. Deux fonctions dans `config.py` :

### `compute_delta_s(alignment, category) → float`

| Alignment | SANTE | ZONE_GRISE | FLUX | BANNIE | PROCRASTINATION_PRODUCTIVE |
|-----------|-------|------------|------|--------|---------------------------|
| 1.0 (Aligné) | -2.0 | -2.0 | -2.0 | +0.2 | -2.0 |
| 0.5 (Doute)  | +0.2 | +0.2 | +0.2 | +0.2 | +0.2 |
| 0.0 (Misaligned) | +1.0 | +1.0 | +0.5 | +5.0 | +0.5 |

### Seuils de comportement

| S | Pulse interval | Comportement |
|---|---------------|-------------|
| 0-2 | 8s | Calme, Tama cachée |
| 3-5 | 5s | Suspicious (Tama apparaît) |
| 6-8 | 4s | Warning verbal à 45s |
| 9-10 | 3s | Cri + auto-close BANNIE à 15s |

### Protected Windows (jamais fermées)
`code, cursor, visual studio, unreal, blender, word, excel, figma, photoshop, premiere, davinci, ableton, fl studio, suno, notion, obsidian, terminal, powershell, godot, focuspals, tama`

---

## 6. Modes de fonctionnement

### Mode Libre (`current_mode = "libre"`)
- Tama est inactive, attend une action utilisateur
- Pas de surveillance, pas de Gemini
- L'utilisateur peut déclencher "Session" ou "Parler" via le menu radial

### Mode Deep Work (`current_mode = "deep_work"`)
- Surveillance active : screen capture + classify_screen + suspicion
- Audio bidirectionnel avec Gemini
- Tama est muzzled par défaut, parle uniquement si :
  - L'utilisateur parle (VAD, timeout 12s)
  - Suspicion > 6 pendant 45s (warning)
  - Suspicion ≥ 9 pendant 15s (critique)
  - Break reminder actif
  - Session vient de démarrer (bonjour)

### Mode Conversation (`current_mode = "conversation"`)
- Pas de surveillance, juste du chat naturel
- Prompt différent (CONVO_PROMPT) — Tama est en mode pote
- Auto-termine après 20s de silence

---

## 7. WebSocket Protocol (Python ↔ Godot)

### Python → Godot (commandes)

| Commande | Payload | Description |
|----------|---------|-------------|
| `START_SESSION` | — | Lance le mode Deep Work |
| `START_CONVERSATION` | — | Lance le mode Conversation |
| `END_CONVERSATION` | — | Fin du mode Conversation |
| `SHOW_RADIAL` | — | Affiche le menu radial |
| `HIDE_RADIAL` | — | Cache le menu radial |
| `MIC_LIST` | `{mics: [...], selected: int}` | Lista des micros disponibles |
| `QUIT` | — | Fermeture propre |

### Python → Godot (broadcast d'état, toutes les 0.5s)

```json
{
  "session_active": true,
  "suspicion_index": 4.2,
  "active_window": "Visual Studio Code",
  "active_duration": 45,
  "state": "CALM",
  "alignment": 1.0,
  "current_task": "coding",
  "category": "SANTE",
  "session_minutes": 23,
  "break_reminder": false,
  "window_ready": true
}
```

### Godot → Python (actions utilisateur)

| Commande | Payload | Description |
|----------|---------|-------------|
| `START_SESSION` | — | Bouton session (Godot UI) |
| `HIDE_RADIAL` | — | Menu radial fermé |
| `MENU_ACTION` | `{action: "talk"}` | Clic menu radial |
| `GET_MICS` | — | Demande liste micros |
| `SELECT_MIC` | `{index: 3}` | Changement de micro |

---

## 8. Godot Animation State Machine

```
Phase.HIDDEN → Phase.PEEKING → Phase.HELLO (intro seul)
                             → Phase.ACTIVE (suspicion loop)
                             → Phase.STRIKING (S ≥ 9, freeze)
              Phase.LEAVING → Phase.HIDDEN
```

Animations disponibles : `Peek`, `Hello`, `Suspicious`, `Angry`, `Strike`, `bye`

Tier mapping :
- Tier 0 (S < 3) → HIDDEN
- Tier 1 (S 3-5) → Suspicious loop
- Tier 2 (S 6-8) → Angry loop
- Tier 3 (S ≥ 9) → Strike (freeze)

---

## 9. Radial Menu (Edge Detection)

Le menu radial s'affiche quand la souris atteint le **bord droit** de l'écran (zone basse, 500px du bas).

**Éléments du menu :**
- ⚙️ Settings — Réglages (micro, taille Tama)
- 💬 Parler — Mode conversation
- ⚡ Session — Démarrer Deep Work
- 🎯 Tâche — Définir la tâche (vocalement)
- ⏰ Pauses — Config pauses (à venir)
- ⛔ Quitter — Fermeture propre

**Anti-loop** : Le flag `_mouse_was_away` empêche le re-trigger tant que la souris n'a pas quitté puis est revenue dans la zone edge. Pas de cooldown artificiel.

---

## 10. Séquence de démarrage

```
Start_FocusPals.bat
  └→ python agent/tama_agent.py
       1. launch_godot_overlay()     # Démarre focuspals.exe + click-through
       2. setup_tray()               # System tray icon
       3. mouse_edge_monitor()       # Thread daemon pour edge detection
       4. asyncio.run(run_tama_live())
            ├→ WebSocket server (port 8080)
            ├→ broadcast_ws_state()   # Envoi état toutes les 0.5s
            └→ run_gemini_loop()      # Boucle IA principale
```

---

## 11. Dépendances Python

```
google-genai          # Gemini Live API
pyaudio               # Mic input/output
mss                   # Screen capture
pygetwindow           # Window listing
pystray               # System tray icon
Pillow                # Image processing
websockets            # WebSocket server
python-dotenv         # .env loading
pywinauto             # UIA pour hand_animation.py
```

---

## 12. Points d'attention pour les futurs agents

> **⚠️ NE PAS casser ces invariants :**

1. **Le `state` dict est partagé** — tout module peut le lire/écrire. Pas de globals éparpillés.
2. **`tama_agent.py` est mince** — ne mettez PAS de logique dedans, c'est un orchestrateur.
3. **Click-through Windows** — `WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW` sur la fenêtre Godot. Si on désactive click-through (pour le menu), il FAUT le réactiver après.
4. **Le menu radial est géré par le thread `mouse_edge_monitor`** — c'est un thread Python natif, pas asyncio.
5. **Build Godot** : exporter via `godot --export-release` (voir workflow `/build`).
6. **VAD = Voice Activity Detection** — simple threshold energy-based, pas de ML.
7. **`hand_animation.py`** est lancé en **subprocess** séparé (car pywinauto bloque).
