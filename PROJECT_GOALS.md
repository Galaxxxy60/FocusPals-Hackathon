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
