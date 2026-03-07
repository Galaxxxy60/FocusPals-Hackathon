# FocusPals — Architecture & Technical Spec 🥷

> **Ce document est la source de vérité unique pour tout agent IA ou développeur qui touche au projet.**
> Dernière mise à jour : 2026-02-27 (Phase 1+2 Gemini features)

---

## 1. Vue d'ensemble

FocusPals est un **coach de productivité IA** sous forme de mascotte 3D desktop. Tama 🥷 surveille tes écrans en temps réel, écoute ta voix, et te rappelle à l'ordre quand tu procrastines.

**Stack technique :**
- **Backend** : Python 3.10+ (agent IA asynchrone)
- **Frontend** : Godot 4.4 (overlay 3D transparent, ~25 MB RAM)
- **IA** : Gemini Live API `v1alpha` (audio bidirectionnel + vision + affective dialog + thinking)
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
    ├── settings_panel.gd       # Panel réglages (micro + clé API Gemini + API usage)
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
│    │ Gemini Live API  │  Audio + Vision + Affective Dialog   │
│    │ (WebSocket)      │  Model: gemini-2.5-flash-native     │
│    │  v1alpha         │  VAD serveur + Thinking + Kore voice │
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
│    └── Settings panel (settings_panel.gd) — micro + API key │
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
| `_session_resume_handle` | str/None | Handle Gemini pour reprise de session transparente |
| `_confidence` | float | Confiance C (0.1 → 1.0) — module la vitesse de déclin de S |

---

## 5. A.S.C. (Alignment Suspicion Control)

Le cœur du système de surveillance. Deux fonctions dans `config.py` :

### `compute_delta_s(alignment, category) → float`

| Alignment | SANTE | ZONE_GRISE | FLUX | BANNIE | PROCRASTINATION_PRODUCTIVE |
|-----------|-------|------------|------|--------|---------------------------|
| 1.0 (Aligné) | -2.0 | -2.0 | -2.0 | +0.2 | -2.0 |
| 0.5 (Doute)  | +0.2 | +0.5 | +0.5 | +0.8 | +0.4 |
| 0.0 (Misaligned) | +1.0 | +1.0 | +0.5 | +2.0 | +0.5 |

> **Note** : Le ΔS négatif (decay) est multiplié par la Confiance C : `ΔS_réel = ΔS_base × C`

### Seuils de comportement

| S | Pulse interval | Comportement |
|---|---------------|-------------|
| 0 | 12s | Calme, Tama cachée |
| 1-5 | 7s | Suspicious (scans accélérés) |
| 6-8 | 5s | Warning verbal à 20s |
| 9-10 | 3s | Cri + auto-close BANNIE à 15s |

### Confiance C — "L'Inertie de la Méfiance"

Variable invisible qui module **la nervosité de Tama**. Empêche la triche par quick-switch.

**Formules** :
- **Gain (S monte)** : `ΔS = base × (1 + (1 - C))` — plus C est bas, plus S monte vite
- **Decay (S descend)** : `ΔS = base × C` — plus C est bas, plus S descend lentement

| Événement | Effet sur C |
|-----------|------------|
| Quick switch SANTE (< 30s sur app, S > 1) | C -= 0.15 (min 0.1) |
| Travail soutenu SANTE (> 60s) | C += 0.02 (max 1.0) |
| Non-SANTE (S monte) | C inchangé |

**Impact de C sur les vitesses** :

| C | Multiplicateur Gain | Multiplicateur Decay | Comportement |
|---|-------|-------|------|
| 1.0 | ×1.0 | ×1.0 | Normal — pleine confiance |
| 0.5 | ×1.5 | ×0.5 | Méfiante — monte 50% plus vite, descend 2× plus lent |
| 0.1 | ×1.9 | ×0.1 | Hyper-nerveuse — le moindre écart explose S |

> **Principe** : La confiance se perd en secondes, se regagne en minutes.

### Protected Windows (jamais fermées)
`code, cursor, visual studio, unreal, blender, word, excel, figma, photoshop, premiere, davinci, ableton, fl studio, suno, notion, obsidian, terminal, powershell, godot, focuspals, tama`

### Symbiose Maths ↔ LLM

Les maths (S, C) et le LLM (Gemini) forment une boucle :

```
Gemini → A + Catégorie → compute_delta_s → S, C (maths)
                                              ↓
                                    mood_engine traduit S + C
                                    en langage naturel
                                              ↓
                                    Prompt Gemini : "Tu ne lui
                                    fais plus confiance, il a
                                    esquivé ta surveillance"
                                              ↓
                                    Gemini parle organiquement
                                    avec le bon ton et contexte
```

- **LLM → Maths** : Gemini fait UN jugement (A + Cat), les maths font le reste
- **Maths → LLM** : `mood_engine.get_mood_context()` traduit C en émotion naturelle
- **Le LLM ne contrôle PAS les maths** — il les nourrit (A) et les interprète (mood), rien de plus

> **⚠️ À simplifier** : le mood_engine actuel est un peu tarabiscoté (bias + C + infractions + streak + heure + chaos). Trouver un truc plus élégant.

---

## 6. Gemini Live API — Features actives

Toutes les features sont configurées dans `gemini_session.py` via `LiveConnectConfig`. L'API version est `v1alpha`.

| Feature | Config | Mode | Description |
|---------|--------|------|-------------|
| **Server-side VAD** | `AutomaticActivityDetection` | Deep Work + Convo | VAD native Gemini (remplace le VAD energy-based pour la gestion de tour). Sensitivity LOW, silence 500ms. Le VAD local (`audio.py`) reste pour le flag `user_spoke_at` |
| **Affective Dialog** | `enable_affective_dialog=True` | Deep Work + Convo | Tama adapte son ton vocal à l'émotion de l'utilisateur (frustré → douce, excité → matche l'énergie) |
| **Context Compression** | `SlidingWindow()` | Deep Work | Sessions illimitées (sans ça : 2 min max avec vidéo). Compression automatique de la fenêtre de contexte |
| **Thinking** | `ThinkingConfig(budget=512)` | Deep Work seul | Raisonnement avant `classify_screen` — meilleure distinction YouTube tuto (SANTE) vs Netflix (BANNIE) |
| **Voice Kore** | `SpeechConfig(voice_name="Kore")` | Deep Work + Convo | Voix dynamique et expressive qui colle au personnage Tama ninja-chat tsundere |
| **Session Resume** | `SessionResumptionConfig(handle=...)` | Deep Work + Convo | Handle persisté dans `state["_session_resume_handle"]`. À chaque reconnexion (~10 min), Tama reprend sans perte de contexte |
| **GoAway Handler** | dans `receive_responses()` | Deep Work + Convo | Capte le message serveur avant déconnexion → reconnexion transparente |
| **Proactive Audio** | `proactive_audio=True` | Deep Work + Convo | Gemini décide intelligemment quand répondre vs rester silencieux |
| **Mood Tagging** | `report_mood` function call | Deep Work + Convo | Gemini s'auto-évalue émotionnellement (mood + intensity) à chaque prise de parole → pilote les animations Godot organiquement |

---

## 6bis. Architecture Audio — Speech-to-Speech Natif

### Modèle

FocusPals utilise **`gemini-2.5-flash-native-audio-latest`** via l'API **Gemini Live** (WebSocket bidirectionnel). C'est du **speech-to-speech natif** : un seul modèle prend de l'audio brut en entrée et génère de l'audio brut en sortie. **Pas de pipeline STT → LLM → TTS** — une seule inférence fait tout.

### Pipeline streaming

```
ENTRÉE (utilisateur → Gemini) :
  Microphone → PyAudio (PCM 16-bit, 16kHz, mono)
    → chunks de 1024 samples (~64ms)
    → audio_in_queue (maxsize=2, anti-accumulation)
    → session.send_realtime_input(audio=blob)
    → WebSocket vers Gemini Live API

SORTIE (Gemini → utilisateur) :
  Gemini Live API → WebSocket
    → part.inline_data.data (PCM 24kHz)
    → audio_out_queue (unbounded)
    → PyAudio speaker (lecture immédiate chunk par chunk)
```

### Latence

| Source | Durée estimée | Côté |
|--------|--------------|------|
| Micro → chunk buffer | ~64ms (1024/16kHz) | Client |
| Réseau aller (WebSocket) | ~50-150ms | Réseau |
| Inférence Gemini (speech-to-speech) | ~300-600ms | Serveur Google |
| Speaker buffer | ~43ms (1024/24kHz) | Client |
| **Total perçu** | **~450-850ms** | — |

> **~80% de la latence est côté serveur** (inférence du modèle). Le client est déjà optimisé : pas de buffering, streaming chunk-par-chunk immédiat, queue bornée en entrée.

### Transcriptions

Les options `input_audio_transcription` et `output_audio_transcription` sont activées mais **ne font PAS partie du pipeline principal**. Elles fournissent des transcriptions texte à côté du flux audio pour le debug/logging (affichage dans la console Python et détection de `user_spoke_at`).

### Langue

La langue de Tama est contrôlée par le **system prompt** (FR ou EN, configurable dans Settings). Le modèle native audio adapte automatiquement sa prononciation — pas de changement de voix ou de TTS nécessaire.

---

## 7. Modes de fonctionnement

### Mode Libre (`current_mode = "libre"`)
- Tama est inactive, attend une action utilisateur
- Pas de surveillance, pas de Gemini
- L'utilisateur peut déclencher "Session" ou "Parler" via le menu radial

### Mode Deep Work (`current_mode = "deep_work"`)
- Surveillance active : screen capture + classify_screen + suspicion
- Audio bidirectionnel avec Gemini (voix Kore, affective dialog)
- **ThinkingConfig** activé (budget 512) pour classify_screen plus précis
- **Context Window Compression** active (sessions illimitées)
- Tama est muzzled par défaut, parle uniquement si :
  - L'utilisateur parle (VAD serveur + local, timeout 12s)
  - Suspicion > 6 pendant 45s (warning)
  - Suspicion ≥ 9 pendant 15s (critique)
  - Break reminder actif
  - Session vient de démarrer (bonjour)

### Mode Conversation (`current_mode = "conversation"`)
- Pas de surveillance, juste du chat naturel
- Prompt différent (CONVO_PROMPT) — Tama est en mode pote
- **Pas de ThinkingConfig** — priorité à la latence vocale faible
- Auto-termine après 20s de silence

---

## 8. WebSocket Protocol (Python ↔ Godot)

### Python → Godot (commandes)

| Commande | Payload | Description |
|----------|---------|-------------|
| `START_SESSION` | — | Lance le mode Deep Work |
| `START_CONVERSATION` | — | Lance le mode Conversation |
| `END_CONVERSATION` | — | Fin du mode Conversation |
| `SHOW_RADIAL` | — | Affiche le menu radial |
| `HIDE_RADIAL` | — | Cache le menu radial |
| `MIC_LIST` | `{mics: [...], selected: int}` | Lista des micros disponibles |
| `SETTINGS_DATA` | `{mics: [...], selected: int, has_api_key: bool, api_usage: {...}}` | Données settings complètes + stats API |
| `API_KEY_UPDATED` | `{success: bool}` | Confirmation MAJ clé API |
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
| `GET_SETTINGS` | — | Demande settings (micros + API key status) |
| `SELECT_MIC` | `{index: 3}` | Changement de micro |
| `SET_API_KEY` | `{key: "AIza..."}` | Mettre à jour la clé API Gemini |
| `STRIKE_FIRE` | — | Strike anim frame atteinte → lance main magique |

---

## 9. Godot Animation State Machine & Mood System

### State Machine

```
Phase.HIDDEN → Phase.PEEKING → Phase.HELLO (intro seul)
                             → Phase.ACTIVE (mood-driven loop)
                             → Phase.STRIKING (furious, freeze)
              Phase.LEAVING → Phase.HIDDEN
```

### Mood System (`report_mood` tool)

Gemini **s'auto-évalue émotionnellement** à chaque prise de parole via le function call `report_mood({mood, intensity})`. Python traduit le mood en animation et l'envoie à Godot. **C'est Gemini qui pilote les animations**, pas des if/else hardcodés.

```
Gemini parle → report_mood({mood: "sarcastic", intensity: 0.8})
  → Python: _MOOD_ANIM_MAP["sarcastic"][high] = "Angry"
  → WebSocket: TAMA_ANIM {anim: "Angry", loop: true}
  → WebSocket: TAMA_MOOD {mood: "sarcastic", intensity: 0.8}
  → Godot joue l'animation
```

### 9 Moods disponibles

| Mood | Description | Quand |
|------|------------|-------|
| `calm` | Tama est tranquille | Nicolas bosse, tout va bien |
| `curious` | Elle observe, intéressée | App ambiguë, elle regarde |
| `amused` | Elle trouve ça drôle | Blague, situation cocasse |
| `proud` | Fierté tsundere discrète | Long streak de bon travail |
| `disappointed` | Déçue, pas contente | Il a replongé après un warning |
| `sarcastic` | Mode sarcasme activé | Il procrastine, elle commente |
| `annoyed` | Visiblement agacée | Il continue malgré les rappels |
| `angry` | En colère | Procrastination prolongée |
| `furious` | Furieuse, prête à strike | Juste avant la fermeture |

### Mood → Animation mapping

| Mood | Intensité basse (< 0.4) | Intensité moyenne (0.4-0.7) | Intensité haute (> 0.7) |
|------|------------------------|---------------------------|----------------------|
| `calm` | Hello | Hello | Hello |
| `curious` | Peek | Suspicious | Suspicious |
| `amused` | Hello | Hello | Hello |
| `proud` | Hello | Hello | Hello |
| `disappointed` | Suspicious | Suspicious | Angry |
| `sarcastic` | Suspicious | Suspicious | Angry |
| `annoyed` | Suspicious | Angry | Angry |
| `angry` | Angry | Angry | Angry |
| `furious` | Angry | Angry | Strike |

### Animations — État actuel & à créer

| Animation | État | Utilisée par |
|-----------|------|-------------|
| `Peek` | ✅ Existe | Apparition initiale, curiosité basse |
| `Hello` | ✅ Existe | Calm, amused, proud, conversation |
| `Suspicious` | ✅ Existe | Curious, sarcastic, disappointed, annoyed (low) |
| `Angry` | ✅ Existe | Angry, annoyed (high), furious (low/mid) |
| `Strike` | ✅ Existe | Furious (high) — fermeture d'onglet |
| `bye` | ✅ Existe | Tama se cache (fin de turn calme) |
| `ArmsCrossed` | 🔲 À créer | Pre-action state (Phase 3) — avertissement visuel silencieux |
| `Sigh` | 🔲 À créer | Disappointed — soupir de déception |
| `HeadTilt` | 🔲 À créer | Curious — penche la tête, observe |
| `SmugSmile` | 🔲 À créer | Proud, amused — sourire en coin tsundere |
| `EyeRoll` | 🔲 À créer | Sarcastic — lève les yeux au ciel |
| `Facepalm` | 🔲 À créer | Disappointed high — consternation |
| `TapFoot` | 🔲 À créer | Annoyed — tape du pied, impatiente |

> **Note** : Les animations "à créer" sont optionnelles. Le système fonctionne déjà avec les 6 animations existantes — les nouvelles enrichiront l'expressivité de Tama quand elles seront prêtes.

### Legacy Tier mapping (fallback si report_mood ne fire pas)

- Tier 0 (S < 3) → HIDDEN
- Tier 1 (S 3-5) → Suspicious loop
- Tier 2 (S 6-8) → Angry loop
- Tier 3 (S ≥ 9) → Strike (freeze)

### Strike Fire Sync (synchronisation frame-précise via bone marker)

La "main magique" (`hand_animation.py`) est synchronisée avec l'animation Strike de Tama via un **bone marqueur** dans le rig Blender.

#### Principe
Un bone `StrikeMarker` est à **scale (0,0,0)** par défaut dans toutes les animations.
À la frame **exacte** où la main doit partir → son scale passe à **(0.1, 0.1, 0.1)**.
Godot détecte ce changement de scale → envoie `STRIKE_FIRE` à Python.

```
grace_then_close() → prepare_close_tab() → state["_pending_strike"] = {hwnd, mode, title}
  → send_anim_to_godot("Strike") → Godot joue Strike_Base
  → Godot _process() vérifie StrikeMarker bone scale
  → Scale > 0.01 → STRIKE_FIRE via WebSocket
  → Python ws_handler() → fire_hand_animation() → subprocess hand_animation.py
```

#### Comment ajouter un nouveau Strike dans Blender
1. Créer l'animation (ex: `Strike_Snap`)
2. Keyframer `StrikeMarker` à scale (0,0,0) sur toutes les frames
3. À la frame du fire → keyframer scale à (0.1, 0.1, 0.1)
4. Exporter le GLB — Godot détecte automatiquement

| Variable | Côté | Description |
|----------|------|-------------|
| `STRIKE_MARKER_SCALE_THRESHOLD` | Godot | Seuil de détection (0.01 par défaut) |
| `_strike_marker_bone_idx` | Godot | Index du bone (auto-découvert au lancement) |
| `_strike_fire_sent` | Godot | Flag anti-doublon (reset à chaque entrée en STRIKING) |
| `_pending_strike` | Python | Dict `{hwnd, mode, title, reason}` — consommé par `fire_hand_animation()` |

> **Noms de bone acceptés** (case-insensitive) : `StrikeMarker`, `Strike_Marker`, `FireMarker`, `Fire_Marker`

> **Safety timeout** : Si Godot ne renvoie pas `STRIKE_FIRE` dans les 5 secondes (bone absent, bug anim), Python lance la main en fallback.


---

## 10. Radial Menu (Edge Detection)

Le menu radial s'affiche quand la souris atteint le **bord droit** de l'écran (zone basse, 500px du bas).

**Éléments du menu :**
- ⚙️ Settings — Réglages (micro, clé API Gemini)
- 💬 Parler — Mode conversation
- ⚡ Session — Démarrer Deep Work
- 🎯 Tâche — Définir la tâche (vocalement)
- ⏰ Pauses — Config pauses (à venir)
- ⛔ Quitter — Fermeture propre

**Anti-loop** : Le flag `_mouse_was_away` empêche le re-trigger tant que la souris n'a pas quitté puis est revenue dans la zone edge. Pas de cooldown artificiel.

---

## 11. Séquence de démarrage

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

## 12. Dépendances Python

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

## 13. Points d'attention pour les futurs agents

> **⚠️ NE PAS casser ces invariants :**

1. **Le `state` dict est partagé** — tout module peut le lire/écrire. Pas de globals éparpillés.
2. **`tama_agent.py` est mince** — ne mettez PAS de logique dedans, c'est un orchestrateur.
3. **Click-through Windows** — `WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW` sur la fenêtre Godot. Si on désactive click-through (pour le menu), il FAUT le réactiver après.
4. **Le menu radial est géré par le thread `mouse_edge_monitor`** — c'est un thread Python natif, pas asyncio.
5. **Build Godot** : exporter via `godot --export-release` (voir workflow `/build`).
6. **VAD double** — Le VAD serveur Gemini gère les tours de parole et interruptions. Le VAD local (`audio.py`, energy-based 500 RMS) gère le flag `user_spoke_at` pour le muzzle system **ET le audio gate** (ne stream que quand il y a de la voix + 500ms pre-buffer + 500ms post-tail). Ne pas supprimer le VAD local.
7. **`hand_animation.py`** est lancé en **subprocess** séparé (car pywinauto bloque).
8. **API version `v1alpha`** — Nécessaire pour `enable_affective_dialog`, `proactivity`, et `ThinkingConfig`. Configuré dans `config.py`.
9. **Session Resume Handle** — `state["_session_resume_handle"]` est mis à jour automatiquement par `receive_responses()`. Ne pas le reset manuellement.
10. **ThinkingConfig** uniquement en Deep Work — NE PAS l'activer en mode conversation (ajoute de la latence vocale).

---

## 14. Interventions Naturelles (Organic Context Enrichment)

> **Principe : Ne scripte jamais les mots. Enrichis la perception.**

Tama produit ses meilleures interventions quand elle a **beaucoup de contexte passif** et **aucune instruction de quoi dire**. Le système injecte des signaux environnementaux dans chaque pulse — Gemini décide seul si le contexte mérite un commentaire.

### Signaux injectés dans chaque pulse (`[SYSTEM]`)

| Signal | Exemple | Ce que ça permet |
|--------|---------|------------------|
| `clock` | `00:54` | "Il est 1h du mat'..." |
| `session` | `28/70min (40%)` | "T'es à mi-chemin" |
| `focus` | `15min` | "15 min de focus, bien joué" |
| `S_trend` | `↑` / `↓` / `→` | "Ça remonte là..." |
| `status` | `active` / `AFK 5min` | "Euh... t'es parti ?" |
| `activity_shifts_10min` | `3` | "T'arrêtes pas de changer" |
| `active_window` | `VS Code` | Contexte visuel |
| `duration` | `45s` | Temps sur la fenêtre courante |

### Pourquoi ça marche

1. **Passif** — Les données sont toujours là, comme une horloge sur le mur. Tama n'est jamais forcée de les mentionner.
2. **Transitions** — Les changements de catégorie (Discord → VS Code) sont les plus riches en commentaires naturels.
3. **Accumulation** — Gemini voit le flux de pulses et synthétise des tendances ("tu switchais beaucoup → maintenant t'es focus").
4. **Proactive Audio** — `proactive_audio=True` permet à Gemini de décider quand parler sans instruction explicite.
