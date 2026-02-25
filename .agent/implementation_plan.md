# 🥷 FocusPals — Plan d'Attaque (Code Review Fixes)

> **Objectif :** Corriger tous les bricolages, lourdeurs et amateurismes identifiés dans la code review, **sans rien casser**, en testant chaque phase avant de passer à la suivante.
>
> **Fichiers concernés :**
> - `agent/tama_agent.py` (923 lignes — le cœur du problème)
> - `godot/scripts/main.gd` (203 lignes)
> - `agent/hand_animation.py` (178 lignes)
> - `Start_FocusPals.bat` (30 lignes)

---

## Phase 0 — Backup & Sécurité (2 min)
> **Règle d'or :** On ne touche à rien tant qu'on n'a pas un backup.

- [ ] Copier `tama_agent.py` → `tama_agent_backup.py`
- [ ] Copier `main.gd` → `main_backup.gd`
- [ ] Copier `hand_animation.py` → `hand_animation_backup.py`

**Test :** Lancer `Start_FocusPals.bat` une fois pour confirmer que tout fonctionne AVANT les modifs.

---

## Phase 1 — Quick Wins Performance (10 min)
> **Impact : GROS | Risque : ZÉRO** — Ce sont des changements isolés, une seule ligne chacun.

### 1.1 — Resampling LANCZOS → BILINEAR
**Fichier :** `agent/tama_agent.py` — Fonction `capture_all_screens()`
**Ligne ~468 :**
```python
# AVANT (CPU killer sur dual-monitor 4K)
img.thumbnail((1024, 512), Image.Resampling.LANCZOS)

# APRÈS (3-5x plus rapide, qualité suffisante pour l'IA)
img.thumbnail((1024, 512), Image.Resampling.BILINEAR)
```
**Pourquoi c'est safe :** L'IA Gemini ne voit pas la différence entre un LANCZOS et un BILINEAR à 40% JPEG quality.

### 1.2 — Qualité JPEG 40 → 30
**Fichier :** `agent/tama_agent.py` — Même fonction
**Ligne ~471 :**
```python
# AVANT
img.save(buffer, format="JPEG", quality=40)

# APRÈS (encore plus léger, Gemini s'en fiche)
img.save(buffer, format="JPEG", quality=30)
```

### 1.3 — Import `time` et `json` dupliqué
**Fichier :** `agent/tama_agent.py`
**Ligne 173-174 :** Supprimer les imports `time` et `json` redondants (déjà importés en haut du fichier).
```python
# SUPPRIMER ces lignes (lines 173-174) :
import time
import json
```

**Test Phase 1 :** Relancer `Start_FocusPals.bat`. Vérifier que la capture d'écran fonctionne toujours (le log doit montrer les scans).

---

## Phase 2 — Extinction Propre (Bye-bye Taskkill) (15 min)
> **Impact : MOYEN | Risque : FAIBLE** — On ajoute un message WebSocket, on ne supprime rien d'existant.

### 2.1 — Côté Python : Envoyer `QUIT` via WebSocket au lieu de `taskkill`
**Fichier :** `agent/tama_agent.py` — Fonction `quit_app()`

```python
# AVANT (bourrin)
def quit_app(icon, item):
    icon.stop()
    subprocess.run("taskkill /F /IM focuspals.exe", ...)
    os._exit(0)

# APRÈS (propre)
def quit_app(icon, item):
    icon.stop()
    print("\n👋 Tama: Fermeture propre...")
    # Envoyer QUIT à Godot via WebSocket
    import json
    quit_msg = json.dumps({"command": "QUIT"})
    for ws_client in list(connected_ws_clients):
        try:
            asyncio.run_coroutine_threadsafe(ws_client.send(quit_msg), main_loop)
        except Exception:
            pass
    # Laisser 1 seconde pour que Godot se ferme, puis exit
    time.sleep(1)
    # Fallback taskkill au cas où Godot ne répond pas
    subprocess.run("taskkill /F /IM focuspals.exe", shell=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os._exit(0)
```

**Note :** Il faut aussi stocker la référence à l'event loop asyncio (`main_loop`) pour pouvoir envoyer depuis le thread du tray. Ajouter dans `run_tama_live()` :
```python
global main_loop
main_loop = asyncio.get_running_loop()
```

### 2.2 — Côté Godot : Recevoir `QUIT` et fermer proprement
**Fichier :** `godot/scripts/main.gd` — Fonction `_handle_message()`

```gdscript
# Ajouter en haut de _handle_message(), après le null-check :
if data.get("command", "") == "QUIT":
    print("👋 Signal QUIT reçu, fermeture propre.")
    get_tree().quit()
    return
```

**Test Phase 2 :** Lancer l'app, puis cliquer "Stop Tama" dans le system tray. Vérifier que Godot se ferme proprement SANS que `taskkill` soit nécessaire.

---

## Phase 3 — Déduplication `pygetwindow` (15 min)
> **Impact : MOYEN | Risque : FAIBLE** — On factorise la logique, mêmes résultats.

### 3.1 — Créer un cache de fenêtres
**Fichier :** `agent/tama_agent.py`

Ajouter un cache global juste après les variables globales existantes (~ligne 232) :
```python
# ─── Window Cache (évite les appels répétés à pygetwindow) ──
_cached_windows = []       # Liste des fenêtres (objets gw.Window)
_cached_active_title = ""  # Titre de la fenêtre active
_cache_timestamp = 0.0     # Quand le cache a été rafraîchi

def refresh_window_cache():
    """Rafraîchit le cache des fenêtres. Appelé UNE SEULE FOIS par scan."""
    global _cached_windows, _cached_active_title, _cache_timestamp
    import pygetwindow as gw
    try:
        _cached_windows = [w for w in gw.getAllWindows() if w.title and w.visible and w.width > 200]
        active = gw.getActiveWindow()
        _cached_active_title = active.title if active else "Unknown"
    except Exception:
        pass
    _cache_timestamp = time.time()

def get_cached_window_by_title(target_title: str):
    """Cherche dans le cache au lieu de refaire getAllWindows()."""
    for w in _cached_windows:
        if target_title.lower() in w.title.lower():
            return w
    return None
```

### 3.2 — Utiliser le cache dans `send_screen_pulse()`
Remplacer les appels directs `gw.getActiveWindow()` et `gw.getAllWindows()` dans `send_screen_pulse()` par le cache :
```python
# Au lieu de :
active_win = gw.getActiveWindow()
for w in gw.getAllWindows(): ...

# Utiliser :
refresh_window_cache()
active_title = _cached_active_title
open_win_titles = [w.title for w in _cached_windows]
```

### 3.3 — Utiliser le cache dans `execute_close_tab()`
```python
# Au lieu de :
for w in gw.getAllWindows():
    if w.title and target_window.lower() in w.title.lower():

# Utiliser :
target = get_cached_window_by_title(target_window)
```

### 3.4 — Utiliser le cache dans l'auto-close S=10
Même logique : remplacer `gw.getAllWindows()` par `_cached_windows`.

**Test Phase 3 :** Lancer l'app, ouvrir YouTube, attendre que S monte. Vérifier que les fenêtres sont toujours détectées correctement.

---

## Phase 4 — Recherche Godot par PID (10 min)
> **Impact : MOYEN | Risque : FAIBLE** — On remplace la recherche par texte par une recherche par PID.

### 4.1 — Stocker le PID du process Godot
**Fichier :** `agent/tama_agent.py` — Fonction `launch_godot_overlay()`

```python
# AVANT
subprocess.Popen([godot_exe], cwd=os.path.dirname(godot_exe))

# APRÈS
global godot_process
godot_process = subprocess.Popen([godot_exe], cwd=os.path.dirname(godot_exe))
```

### 4.2 — Trouver la fenêtre par PID au lieu du titre
**Fichier :** `agent/tama_agent.py` — Fonction `_apply_click_through_delayed()`

Remplacer le `find_window()` qui cherche par texte :
```python
def find_window():
    """Trouve le HWND du process Godot par son PID."""
    result = []
    pid = godot_process.pid if godot_process else None
    if not pid:
        return None

    def callback(hwnd, lparam):
        if user32.IsWindowVisible(hwnd):
            lpdw_pid = ctypes.wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(lpdw_pid))
            if lpdw_pid.value == pid:
                result.append(hwnd)
        return True
    user32.EnumWindows(WNDENUMPROC(callback), 0)
    return result[0] if result else None
```

**Test Phase 4 :** Lancer l'app. Ouvrir l'explorateur Windows dans le dossier "FocusPals". Vérifier que le click-through s'applique UNIQUEMENT à la fenêtre Godot et PAS à l'explorateur.

---

## Phase 5 — AnimationPlayer propre dans Godot (5 min)
> **Impact : FAIBLE | Risque : ZÉRO** — Simplification cosmétique.

### 5.1 — Supprimer `_find_animation_player()` et utiliser un chemin direct
**Fichier :** `godot/scripts/main.gd`

Le nœud `Tama` est un `.glb` importé avec un `AnimationPlayer` auto-généré. Dans Godot 4, le chemin est prévisible.

```gdscript
# AVANT (récursion brute sur tous les enfants)
func _ready():
    var tama = get_node_or_null("Tama")
    if tama:
        anim_player_ref = _find_animation_player(tama)

# APRÈS (accès direct, propre)
func _ready():
    # Le .glb de Godot 4 génère toujours AnimationPlayer au même endroit
    anim_player_ref = get_node_or_null("Tama/AnimationPlayer")
    if anim_player_ref == null:
        # Fallback : parfois c'est sous un sous-nœud
        var tama = get_node_or_null("Tama")
        if tama:
            anim_player_ref = _find_animation_player(tama)
```

> **⚠️ IMPORTANT :** Il faut d'abord vérifier le nom exact de l'AnimationPlayer dans Godot Editor avant ce changement. Si le chemin direct ne marche pas, le fallback récursif est gardé.

### 5.2 — Supprimer les variables globales hors-fonction
**Fichier :** `godot/scripts/main.gd` — Lignes 97-99

Déplacer `has_done_intro`, `intro_step`, `intro_timer` en haut du script avec les autres variables :
```gdscript
# Déplacer ces 3 lignes de la ligne 97 vers la ligne 32 (avec les autres vars)
var has_done_intro: bool = false
var intro_step: String = ""
var intro_timer: float = 0.0
```

**Test Phase 5 :** Lancer l'app. Vérifier que la séquence d'intro (Peek → Hello → Bye → Idle) fonctionne toujours.

---

## Phase 6 — Nettoyage Cosmétique (10 min)
> **Impact : FAIBLE | Risque : ZÉRO** — Pur nettoyage, aucun changement de logique.

### 6.1 — Ajouter `import logging` et remplacer les prints critiques
**Fichier :** `agent/tama_agent.py`

```python
# En haut du fichier, après les imports existants :
import logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S"
)
log = logging.getLogger("Tama")

# Remplacer progressivement les prints les plus importants :
# print("❌ ...") → log.error("...")
# print("⚠️ ...") → log.warning("...")
# print("✅ ...") → log.info("...")
```

> **Note :** On ne remplace PAS tous les prints d'un coup. On garde les emojis pour le côté fun (c'est un hackathon !), mais on ajoute le format avec timestamp pour le debugging.

### 6.2 — Supprimer les fichiers morts
- `godot/scripts/main_old.gd` — Fichier mort, doublon
- `godot/scripts/main_original.gd` — Fichier mort, doublon
- `diagnose.py`, `diagnose_audio.py`, `diagnose_combo.py` — Scripts de debug temporaires
- `agent_dump.log`, `agent_logs.txt`, `agent_logs_crash.txt`, `error.log`, `error2.log`, `output.log`, `log.txt` — Logs de développement
- `test_live.py`, `test_media.py`, `test_pcm.py`, `test_tools.py`, `trigger.py` — Scripts de test isolés

### 6.3 — Supprimer `node_modules/` à la racine
Il y a un dossier `node_modules/` à la racine du projet qui n'a rien à faire là (pas de `package.json`). C'est un résidu qui alourdit le repo.

**Test Phase 6 :** `Start_FocusPals.bat` fonctionne toujours après nettoyage.

---

## Récap & Ordre d'Exécution

| Phase | Quoi | Risque | Temps | Fichiers |
|-------|------|--------|-------|----------|
| **0** | Backup | 🟢 Zéro | 2 min | tous |
| **1** | Quick Wins Perf | 🟢 Zéro | 10 min | `tama_agent.py` |
| **2** | Extinction propre | 🟡 Faible | 15 min | `tama_agent.py` + `main.gd` |
| **3** | Cache fenêtres | 🟡 Faible | 15 min | `tama_agent.py` |
| **4** | PID Godot | 🟡 Faible | 10 min | `tama_agent.py` |
| **5** | AnimPlayer Godot | 🟢 Zéro | 5 min | `main.gd` |
| **6** | Nettoyage | 🟢 Zéro | 10 min | tous |

**Temps total estimé : ~65 min**

---

## 🛟 Stratégie de Rollback

Si une phase casse quelque chose :
1. **Annuler uniquement la phase en cours** → copier le backup correspondant
2. **Ne JAMAIS annuler les phases précédentes** (elles ont été testées et validées)
3. **Les phases sont indépendantes** : si Phase 3 casse, on peut passer à Phase 4 sans problème
