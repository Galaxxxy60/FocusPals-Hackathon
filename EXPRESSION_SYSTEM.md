# 🎭 Tama — Système d'Expressions & Lip Sync

## Architecture Visuelle

Tama utilise un système **PS1-style** d'animation par UV swap sur une texture atlas unique. Les yeux et la bouche sont des îlots UV indépendants, swappables séparément pour créer des combinaisons d'expressions.

---

## 📐 Layout Texture (512×512)

```
         A (0-128)   B (128-256)   C (256-384)   D (384-512)
    ┌────────────────────────────┬─────────────┬─────────────┐
  1 │                            │👀 Plissés   │👀 Fermés    │
    │      BODY TEXTURE          │  fort/susp. │             │
    │      (256×256)             │👄 "O"       │👄 "A"       │
    │   A1 = face neutre         │  ronde      │  ouverte    │
    ├────────────────────────────┼─────────────┼─────────────┤
  2 │                            │👀 Wide      │👀 Happy     │
    │      BODY TEXTURE          │  grands ouv.│             │
    │      (suite)               │👄 "I"       │👄 Happy     │
    │                            │  dents      │  sourire    │
    ├────────────────────────────┼─────────────┼─────────────┤
  3 │                            │👀 Angry     │👀 Semi-     │
    │                            │             │  closed     │
    │        (libre)             │👄 Unhappy   │👄 "Huh"     │
    │                            │  grimace    │  méchant    │
    ├────────────────────────────┼─────────────┼─────────────┤
  4 │                            │👀 Plissés   │👀 Furieux   │
    │        (libre)             │  léger/mal. │             │
    │                            │👄 Sourire   │👄 Furieuse  │
    │                            │  malicieux  │             │
    └────────────────────────────┴─────────────┴─────────────┘
```

Chaque cellule = 128×128px. Moitié haute (128×64) = yeux, moitié basse (128×64) = bouche.
Le visage neutre (E0 + M0) est intégré directement dans la texture body (A1).

---

## 👀 Inventaire Yeux (9 variants)

| ID | Cell | Description | Usage A.S.C. |
|----|------|-------------|-------------|
| **E0** | A1 (body) | Neutre, ouverts | Default — aucun UV swap |
| **E1** | C1 | Plissés fort, très suspicieux | `report_mood: suspicious (>0.7)` |
| **E2** | D1 | Fermés | Blink frame 2 (fermé complet) |
| **E3** | C2 | Grands ouverts | Surprise, attention, choc |
| **E4** | D2 | Happy, doux | `report_mood: calm, proud, amused` |
| **E5** | C3 | Angry, sourcils froncés | `report_mood: angry, annoyed` |
| **E6** | D3 | Semi-fermés (transition) | Blink frame 1 (mi-chemin) |
| **E7** | C4 | Plissés léger, malicieux | `report_mood: suspicious (<0.7), sarcastic` |
| **E8** | D4 | Furieux | `report_mood: furious` / STRIKE |

### Séquence Blink (procédural, timer 3-7s)
```
E0 (neutre) → E6 (semi-fermé) → E2 (fermé) → E6 (semi-fermé) → E0 (neutre)
Durée totale : ~0.2s (0.05s par frame)
```

---

## 👄 Inventaire Bouches (9 variants)

| ID | Cell | Forme | Usage |
|----|------|-------|-------|
| **M0** | A1 (body) | Neutre fermée | Default — aucun UV swap |
| **M1** | C1 | Ronde "O" `○` | **Lip sync** : sons O, U, OU |
| **M2** | D1 | Large ouverte "A" `△` | **Lip sync** : son A |
| **M3** | C2 | Dents visibles "I" `⊓` | **Lip sync** : sons I, E, F, V, S, SH |
| **M4** | D2 | Sourire happy `⌣` | **Expression** : calm, proud |
| **M5** | C3 | Grimace unhappy `⌢` | **Expression** : angry, annoyed |
| **M6** | D3 | "Huh" méchant | **Expression** : sarcastic |
| **M7** | C4 | Sourire malicieux | **Expression** : suspicious |
| **M8** | D4 | Furieuse | **Expression** : furious |

---

## 🔬 Lip Sync — Détection Spectrale (`viseme.py`)

Le lip sync est piloté par analyse FFT temps réel des chunks audio PCM (24kHz).
Pas de ML — juste numpy. Exécution < 0.1ms par chunk.

### Features spectrales analysées

| Feature | Calcul | Distingue |
|---------|--------|-----------|
| **RMS** (amplitude) | `sqrt(mean(samples²))` | Silence vs son |
| **Spectral Centroid** | `sum(freq × mag) / sum(mag)` | Voyelles graves (O) vs aiguës (A) |
| **HF Energy Ratio** | `sum(mag[f>4kHz]) / sum(mag)` | Fricatives/dents (I, E, S, F) |

### Mapping visème → slot bouche

| Visème | Condition | Slot |
|--------|-----------|------|
| `REST` | RMS < 300 | M0 (neutre, body default) |
| `OH` | Centroid < 900Hz | M1 (ronde "O") |
| `AH` | Centroid ≥ 900Hz, HF < 0.28 | M2 (large "A") |
| `EE_TEETH` | HF ratio > 0.28 | M3 (dents "I") |

### Pipeline

```
Gemini Audio (PCM 24kHz)
    ↓
audio_out_queue.get()
    ↓
detect_viseme(chunk) → "OH" / "AH" / "EE_TEETH" / "REST"
    ↓
WebSocket → {"command": "VISEME", "shape": "OH"}
    ↓
Godot → mouth UV offset → M1 slot
    ↓
speaker.write(chunk)  ← joué EN MÊME TEMPS → synchronisé
```

---

## 🔗 Mapping Mood → Expression complète

Quand Python envoie `TAMA_MOOD`, Godot choisit les yeux + la bouche idle.
Le lip sync override la bouche pendant la parole.

| Mood (report_mood) | Yeux | Bouche (idle) | Bouche (lip sync) |
|---------------------|------|---------------|-------------------|
| **calm** | E4 happy | M4 sourire | M1/M2/M3 spectral |
| **curious** | E0 neutre | M0 neutre | M1/M2/M3 spectral |
| **amused** | E4 happy | M4 sourire | M1/M2/M3 spectral |
| **proud** | E4 happy | M4 sourire | M1/M2/M3 spectral |
| **suspicious** (< 0.7) | E7 plissés léger | M7 malicieux | M1/M2/M3 spectral |
| **suspicious** (≥ 0.7) | E1 plissés fort | M7 malicieux | M1/M2/M3 spectral |
| **disappointed** | E7 plissés léger | M5 grimace | M1/M2/M3 spectral |
| **sarcastic** | E7 plissés léger | M6 "huh" méchant | M1/M2/M3 spectral |
| **annoyed** | E5 angry | M5 grimace | M1/M2/M3 spectral |
| **angry** | E5 angry | M5 grimace | M1/M2/M3 spectral |
| **furious** | E8 furieux | M8 furieuse | M1/M2/M3 spectral |

### Layers d'animation (parallèles)

```
┌──────────────────────────────────────────────────────┐
│  Layer 3 — PROCÉDURAL (Godot code)                   │
│  Blink aléatoire (E0→E6→E2→E6→E0 toutes les 3-7s)  │
│  → Tourne en permanence, override temporaire les yeux│
├──────────────────────────────────────────────────────┤
│  Layer 2 — LIP SYNC (viseme.py → WebSocket)          │
│  Spectral analysis → M0/M1/M2/M3                    │
│  → Override la bouche pendant la parole              │
├──────────────────────────────────────────────────────┤
│  Layer 1 — EXPRESSION (report_mood → TAMA_MOOD)      │
│  Yeux (Ex) + Bouche idle (Mx) par mood              │
│  → Changent quand le mood change                     │
├──────────────────────────────────────────────────────┤
│  Layer 0 — BODY ANIMATION (bones)                    │
│  Idle, Peek, Suspicious, Angry, Strike, Bye          │
│  → AnimationPlayer classique                         │
└──────────────────────────────────────────────────────┘
```

---

## 🔧 Implémentation Godot (TODO)

### Dans Blender
- Le mesh face a **2 îlots UV séparés** : un pour les yeux, un pour la bouche
- Les deux sont mappés sur la zone neutre A1 par défaut
- **3 material slots** : `body`, `eyes`, `mouth`

### Dans Godot (main.gd)

```gdscript
# UV offsets pour chaque slot (positions relatives depuis le neutre A1)
# Le neutre est sur le body (A1), les expressions sont en C1-D4
# Offset = position_slot - position_neutre (en coordonnées UV 0-1)

const EYE_SLOTS = {
    "E0": Vector3(0, 0, 0),         # neutre (body default)
    "E1": Vector3(offset_C1),       # plissés fort
    "E2": Vector3(offset_D1),       # fermés
    "E3": Vector3(offset_C2),       # wide
    "E4": Vector3(offset_D2),       # happy
    "E5": Vector3(offset_C3),       # angry
    "E6": Vector3(offset_D3),       # semi-closed
    "E7": Vector3(offset_C4),       # plissés léger
    "E8": Vector3(offset_D4),       # furieux
}

# Les offsets exacts dépendent de la position des UV des yeux
# dans la texture body. À calibrer après import du modèle.
```

### WebSocket handler
```gdscript
# Recevoir VISEME
"VISEME":
    var shape = msg.get("shape", "REST")
    match shape:
        "REST": mouth_material.uv1_offset = MOUTH_NEUTRAL
        "OH":   mouth_material.uv1_offset = MOUTH_SLOTS["M1"]
        "AH":   mouth_material.uv1_offset = MOUTH_SLOTS["M2"]
        "EE_TEETH": mouth_material.uv1_offset = MOUTH_SLOTS["M3"]
```

---

## 📊 Combinaisons possibles

- **9 yeux × 9 bouches** = 81 expressions statiques
- **+ 4 visèmes lip sync** = bouche animée en temps réel par-dessus
- **+ blink procédural** = yeux qui clignent naturellement
- **+ body animations** = corps qui bouge indépendamment

**Résultat** : un personnage PS1-style ultra expressif avec lip sync spectral temps réel. 🎯
