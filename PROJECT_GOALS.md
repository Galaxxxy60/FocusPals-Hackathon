# FocusPals — Project Goals 🎯

## 1. Favoriser les interventions naturelles

### Vision

Tama doit se comporter comme un **vrai ami dans la pièce** — pas un assistant scripté. Elle observe, elle comprend, et elle commente *quand c'est pertinent*. La majorité du temps, elle se tait. Quand elle parle, c'est parce que le contexte l'y pousse naturellement.

### Principe fondamental

> **"Ne scripte jamais les mots. Enrichis la perception."**

On n'écrit jamais "dis X quand Y se passe". On donne à Gemini un maximum de **contexte passif** (comme des sens) et on le laisse décider seul quand et quoi dire. C'est ce qui rend les interactions organiques et surprenantes.

### Comment on y arrive

#### Enrichir le contexte (les "sens" de Tama)
- **Vision** : Screenshots toutes les ~12s + Flash Lite classification (catégorie, alignement)
- **Horloge** : Heure actuelle, durée de session, progression %
- **Mémoire courte** : Focus streak, tendance suspicion (↑↓→), shifts d'activité
- **Présence** : Détection AFK (pas de changement de fenêtre + silence)
- **Audio** : VAD local détecte quand l'utilisateur parle

#### Ne PAS forcer
- ❌ "Si focus > 20 min, dire bravo" → scripté, prévisible
- ✅ Envoyer `focus: 20min` dans le pulse → Gemini décide seul si c'est pertinent
- ❌ "Si AFK > 5 min, demander si tout va bien" → robotique
- ✅ Envoyer `status: AFK 5min` → Gemini fait le lien naturellement

#### Laisser Gemini connecter les points
L'interaction magique "Bon, t'es retourné au code, c'est déjà ça" est née parce que :
1. Gemini a vu Discord (zone grise) pendant plusieurs pulses
2. Puis a vu VS Code (santé) 
3. Il a synthétisé la transition tout seul
4. `proactive_audio=True` lui a permis de parler sans y être invité

### Métriques de succès
- Tama fait des commentaires **contextuels** que l'utilisateur n'attend pas
- L'utilisateur dit "comment elle sait ?" plutôt que "encore ce message..."
- Les interventions sont **variées** (pas la même phrase pour le même contexte)
- Tama se tait quand ya rien d'intéressant à dire

### Ce qu'on ne veut surtout PAS
- Des phrases qui se répètent ("Bravo, 20 minutes !" à chaque session)
- Des interventions mécaniques déclenchées par des seuils fixes
- Des notifications déguisées en conversation
- Un assistant qui commente chaque action

### Évolution future
- **Patterns sur plusieurs sessions** : "Tu commences toujours par Discord avant de bosser, c'est ton rituel ?"
- **Conscience du projet** : Savoir sur quoi l'utilisateur travaille et commenter les progrès
- **Mémoire inter-session** : Se souvenir de ce qui s'est passé hier

---

## 2. Messages `[SYSTEM]` : contexte, jamais de directives

### Règle absolue

Les messages injectés à Gemini en runtime décrivent **ce qui s'est passé**. Jamais ce que Tama doit dire, comment elle doit réagir, ni quel ton adopter.

#### ❌ Directive (scripté)
```
"Dis quelque chose comme 'C'est parti pour 50 minutes de concentration ! Je te surveille' — 
sois naturelle et dynamique. Tu DOIS mentionner la durée."
```

#### ✅ Contexte (organique)
```
"La session vient de commencer. 50 minutes."
```

### Règles

1. **`[SYSTEM]` = faits.** Ce qui s'est passé, ce qui est à l'écran, ce qui a changé. Jamais "dis X" ou "réagis comme Y".
2. **Le system prompt définit la personnalité.** Le caractère de Tama, son ton, ses comportements vivent dans le system prompt. Les messages runtime ne font pas de rappels de personnalité.
3. **Les nudges = nouveaux faits.** Si l'utilisateur n'a pas fait quelque chose, le message est "il n'a pas appuyé sur Start" — pas "rappelle-lui d'appuyer sur Start."
4. **Le body language suit l'architecture.** Si Tama ne peut pas physiquement interagir avec un élément (ex: le drone est une fenêtre OS séparée), elle ne fait pas semblant.

### Exemples

| Événement | Le système envoie | Tama décide |
|-----------|-------------------|-------------|
| User appelle Tama | "Il y a un bouton Start sur le drone au-dessus de ta tête — c'est comme ça qu'il lance une session." | Comment saluer, si elle mentionne le Start |
| User clique Start | "La session vient de commencer. 50 minutes." | Sa réaction, si elle mentionne la durée |
| 15s sans clic Start | "Il n'a pas appuyé sur le bouton Start." | Si elle relance, taquine, ou attend |
| Pause suggérée | "Ça fait 50 minutes de travail." | Comment proposer la pause |
| Distraction | "Fenêtre active : YouTube. Catégorie : DISTRACTION." | Si elle intervient, à quel degré |
| Retour au travail | "Fenêtre active : VS Code. Catégorie : PRODUCTIVE." | Si elle commente ou reste silencieuse |

### Anti-patterns

- **"Dis UN mot ou une toute petite phrase"** → prescrit la longueur
- **"Sois naturelle et dynamique"** → prescrit le ton (déjà dans le system prompt)
- **"Ne demande PAS encore sur quoi il travaille"** → prescrit ce qu'il ne faut PAS dire
- **"MUST mention the duration"** → force le contenu
- **"Keep it SHORT (1 sentence)"** → prescrit le format

Tous ces patterns rendent Tama prévisible. Prévisible ≠ organique.
