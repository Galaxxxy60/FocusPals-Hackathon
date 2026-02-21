# FocusPals : L'Architecture de Tama 🥷 

Ce document explique le fonctionnement interne du "cerveau" de Tama, notre coach de productivité IA asynchrone, développé pour le Hackathon.

## 1. Vision Globale (Live Vision & Audio)
Tama n'est pas un simple "bloqueur de sites". Elle agit comme une véritable partenaire de travail :
* **Dual-Monitor Vision** : Tama capture tous les écrans actifs et les fusionne en un seul panorama visuel toutes les X secondes.
* **Audio Temps Réel** : Elle est connectée au microphone et aux haut-parleurs via la **Gemini Live API (WebSocket)** pour un flux d'échange vocal bidirectionnel et naturel, sans latence gênante de saisie de texte.

## 2. L'Indice de Suspicion (Le Cœur du Système)
Au lieu de réagir de façon binaire (Fermer l'onglet vs Ne rien faire), l'IA gère une jauge interne de Suspicion baptisée **`S`** qui varie de 0 à 10.

* **La mécanique mathématique** : Chaque fois qu'une analyse visuelle est faite, l'agent utilise un outil (*Function Calling*) interne nommé `update_suspicion_index`. 
* **Temps de Focus** : Si Tama observe un environnement sain (ex: l'IDE est ouvert), le script Python "refroidira" doucement la jauge (`-1 point` par scan).
* **Poids de Distraction** : Si une activité parasite est détectée, la jauge s'affole (`+2 points` maximum par scan).
* **Le "Rythme Cardiaque" Adaptatif** : La fréquence de capture de l'IA est dictée par cet indice.
  * **Score 0 à 2** : Scan très espacé (toutes les 8 secondes) pour sauver de la bande passante.
  * **Score 3 à 5** : Scan toutes les 5 secondes.
  * **Score 6 à 8** : Scan toutes les 3 secondes.
  * **Score 9 à 10** : Mode RAID, scan chaque seconde jusqu'à terminaison de l'onglet.

## 3. Le Protocole "Zone Grise" (4 Catégories Multi-Comportementales)
Tama analyse le bureau selon 4 niveaux de gravité distincts, couplés avec la mesure du temps réel de la fenêtre active pour comprendre le *contexte* de la distraction.

### 🔴 Catégorie 1 : BANNIE (Divertissement)
* **Applications** : Netflix, Jeux (Steam), YouTube (hors tutoriel), TikTok, Reddit.
* **Comportement (Raid immédiat)** : Augmentation drastique de l'indice de suspicion. Tama passe l'indice S à 10 en moins de 15 secondes. L'agent lance le *Function Calling* `close_distracting_tab` OS qui fait apparaître l'animation 3D "🖐️" pour anéantir l'onglet et crie sur l'utilisateur à travers le casque.

### 🟡 Catégorie 2 : ZONE GRISE (Vie Privée & Messageries)
* **Applications** : Messenger, Discord, Slack, WhatsApp.
* **Philosophie (Privacy First)** : Interdiction absolue d'appliquer de l'OCR (Reconnaissance de caractères) ou de lire le dialogue. La détection se base sur l'Interface Utilisateur Globale (UI).
* **Comportement (Temps vs Utilité)** : 
  * Si un Logiciel/IDE est visible à l'arrière : Suspicion très basse.
  * Si l'utilisateur y reste actif **plus de 120 secondes**, l'indice S monte à 5, l'interface 3D de Tama "Pop" en bas de l'écran (elle scrute), puis elle engage directement l'utilisateur vocalement : *"Nicolas, cette discussion est-elle vitale ou dois-je sévir ?"*
  * **Le "Barge-in"** : L'utilisateur peut justifier son acte à l'oral ("C'est mon collègue pour le projet !"). Si Gemini juge la réponse pertinente, il accorde 10 minutes d'impunité temporelle et la jauge diminue.

### 🔵 Catégorie 3 : FLUX (Audiovisuel Modéré)
* **Applications** : Spotify, YouTube Music, Deezer.
* **Comportement (Fuel Intellectuel)** : Si le lecteur de musique est en arrière plan, c'est encouragé (Score maintenu vers 0). Dès que l'application repasse sur l'écran actif principal pendant plus de 60s, l'indice monte. 
* **L'Anti-Clip** : Tama détecte la différence entre une pochette d'album statique et une vidéo musicale au premier-plan (Mouvement / Clips visuels sur YouTube Music). Si ce cas est identifié, elle gronde l'utilisateur oralement de le glisser en arrière-plan.

### 🟢 Catégorie 4 : SANTÉ (Concentration Pur)
* **Applications** : VS Code, Cursor, Visual Studio, Terminaux, Documentation de Code API, ChatGPT.
* **Comportement (Soutien)** : L'indice s'effondre. Tama se replonge dans le silence total, baisse la cadence de ses scans visuels (intervalle maximal) et ne perturbe jamais la concentration du développeur.

## 4. Lien 3D React-Tauri/Electron (Interface Widget)
L'état de suspicion de la logique "Serveur Base Python" sera connecté à un front-end en **React Three Fiber**. Un modèle 3D réagit visuellement aux appels de suspicion de façon asynchrone par-dessus les autres fenêtres OS Window (le tout flottant, avec transparence native).
