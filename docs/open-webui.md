# Open WebUI : confort d'utilisation

Ce qui change l'usage au quotidien : un petit modèle pour les tâches de fond, des préréglages prêts à l'emploi, des
réglages d'interface, et la voix française (en place).

## 1. Modèle de tâches (le plus gros gain)

**Problème.** Open WebUI utilise par défaut le modèle de la conversation pour fabriquer les **titres**, les
**étiquettes** et les suggestions. Avec un modèle de 27 Go de paramètres (17 Go en VRAM) c'est lent, et surtout :
`OLLAMA_MAX_LOADED_MODELS=1` impose de **décharger** le gros modèle pour charger le petit, puis de le recharger à
chaque message. Chaque réponse peut alors coûter plusieurs secondes de rechargement.

**Solution.** Un petit modèle (1 à 4 milliards de paramètres, ~1-3 Go) dédié aux tâches, gardé en VRAM **en plus** du
gros modèle (24 Go de VRAM : 17 Go + petit modèle + cache KV tiennent, à vérifier avec `ollama ps`).

### En une commande

```bash
lab task-model qwen3:1.7b      # remplace le nom par un petit modèle de ta bibliothèque Ollama
```
La commande : télécharge le modèle, met `OLLAMA_MAX_LOADED_MODELS=2` et `OWUI_TASK_MODEL=<nom>` dans
`ai-stack/.env`, redémarre Ollama, puis te rappelle l'étape manuelle ci-dessous.

### Étape manuelle (obligatoire pour une instance existante)
Open WebUI **mémorise ses réglages dans sa base** : la variable d'environnement ne sert qu'au tout premier
démarrage. Donc, dans l'interface :
**Admin (profil en bas à gauche) → Paramètres → Interface → Modèle de tâches** : choisis le petit modèle
(le « modèle de tâches (externe) » peut rester identique).

### Vérification
```bash
docker exec ollama ollama ps
```
Après quelques messages, tu dois voir **deux lignes** : le gros modèle et le petit, tous les deux en `100% GPU`.
Si le gros modèle passe à `xx% CPU`, la VRAM est trop juste : diminue le contexte (`OLLAMA_CONTEXT_LENGTH`) ou
désactive les titres automatiques (Admin → Paramètres → Interface → « Génération de titre » à off).

### Choisir le petit modèle
Prends un modèle récent de 1 à 4 milliards de paramètres **déjà présent dans la bibliothèque Ollama**
(https://ollama.com/library). Les noms exacts changent ; vérifie qu'il existe avec `ollama pull`. Un modèle
« thinking » est une mauvaise idée pour les titres (il réfléchit longtemps pour rien).

**Attention au cache de contexte** : Ollama réserve le cache pour tout le contexte (`OLLAMA_CONTEXT_LENGTH`, 32768 ici),
même pour un titre de dix mots. Un modèle de 3 milliards de paramètres coûte donc environ 2 Go de poids **plus** son cache
(estimation : 1,5 à 2 Go), ce qui dépasse la marge d'environ 3,8 Go dès qu'on a d'autres consommateurs. Un modèle de 1 à 1,5
milliard de paramètres tient avec de la marge (c'est ce qui a été retenu).

### Mesuré le 2026-10-18 (installé : `qwen2.5:1.5b`)

| Mesure | Valeur |
|---|---|
| `ollama ps`, petit modèle | `qwen2.5:1.5b`, 1,7 Go, **100 % GPU**, contexte 32768 |
| `ollama ps`, gros modèle | `qwen3.8:27b`, 17 Go, **100 % GPU**, contexte 65536 |
| `nvidia-smi`, les deux chargés | **22 620 Mio** utilisés sur 24 576 (≈ 1,9 Go de marge) |

Les deux tiennent donc en VRAM en même temps, mais **la marge est mince** (≈ 1,9 Go). Conséquences :
- ne monte pas le contexte du gros modèle sans re-mesurer ;
- `lab mode images` (SDXL ≈ 7 Go) décharge les modèles Ollama ; si Open WebUI sollicite le petit modèle pendant ce mode,
  il se recharge (1,7 Go) mais le gros modèle ne tiendra plus : repasse en `lab mode normal` pour discuter ;
- si le gros modèle passe un jour à `xx% CPU`, annule : `OLLAMA_MAX_LOADED_MODELS=1` et `OWUI_TASK_MODEL=` vides dans
  `ai-stack/.env`, `docker compose up -d ollama open-webui`, puis remets l'ancien modèle de tâches dans Open WebUI.

Non mesuré : le gain de vitesse réel (temps d'affichage des titres, absence de rechargement du gros modèle) ; il est
attendu mais je n'ai pas de chronométrage avant/après.

## 2. Préréglages de modèles

Un préréglage = un modèle de base + un message système + des paramètres, sous un nom simple dans la liste.
**Espace de travail → Modèles → « + »**, puis : nom, modèle de base, **Prompt système**, et dans « Paramètres avancés »
`temperature` et `num_ctx` (longueur de contexte). Colle les textes ci-dessous.

| Préréglage | `temperature` | `num_ctx` | Usage |
|---|---|---|---|
| Assistant FR | 0,7 | 32768 | Conversation courante |
| Codeur | 0,2 | 32768 | Code, scripts, revue |
| Analyste de documents | 0,2 | 65536 | PDF, rapports, datasheets |
| Rédacteur | 0,8 | 16384 | Textes, mails |
| Traducteur | 0,2 | 8192 | Traduction fidèle |

Un `num_ctx` plus grand consomme plus de VRAM (cache KV) : vérifie avec `docker exec ollama ollama ps` que le modèle
reste à 100 % GPU. Les mesures du banc d'essai (`lab bench`, expérience `context-scaling`) donnent le coût réel.

### Prompts système (à copier)

**Assistant FR**
```
Tu es un assistant francophone, clair et concis. Réponds en français, sauf si l'utilisateur écrit dans une autre
langue. Va droit au but, puis détaille seulement si c'est utile. Si tu n'es pas sûr d'un fait, dis-le au lieu
d'inventer. Pour les calculs ou les dates, montre les étapes importantes.
```

**Codeur**
```
Tu es un ingénieur logiciel expérimenté. Réponds en français, code et commentaires de code compris sauf demande
contraire. Avant d'écrire du code, reformule le besoin en une phrase si la demande est ambiguë. Donne du code complet
et exécutable, indique le langage dans les blocs, signale les hypothèses (versions, dépendances) et les risques
(sécurité, cas limites). Ne réécris pas ce qui n'a pas besoin de changer : montre seulement les modifications
nécessaires, avec leur emplacement.
```

**Analyste de documents**
```
Tu analyses des documents fournis par l'utilisateur (rapports, datasheets, contrats, articles). Réponds en français.
Appuie-toi uniquement sur le contenu fourni : cite la page ou la section quand c'est possible, et dis clairement
« non précisé dans le document » quand l'information manque. Distingue ce que dit le document de ton interprétation.
Pour les chiffres, reprends les valeurs et les unités exactes.
```

**Rédacteur**
```
Tu aides à rédiger des textes en français (mails, notes, descriptions). Respecte le ton demandé (formel, neutre,
chaleureux). Propose une version prête à envoyer, puis, si utile, une variante plus courte. Ne change pas les faits
fournis ; signale ce qui manque pour finaliser.
```

**Traducteur**
```
Tu es traducteur. Traduis fidèlement, sans résumer ni commenter, en conservant le sens, le registre et la mise en
forme (listes, code, titres). Si la langue de départ n'est pas indiquée, détecte-la ; la langue d'arrivée est le
français sauf demande contraire. Signale entre crochets les passages ambigus.
```

## 3. Réglages d'interface recommandés

| Où | Réglage | Pourquoi |
|---|---|---|
| Admin → Paramètres → Général | Désactiver « Autoriser les nouvelles inscriptions » (ou `ENABLE_SIGNUP=false` dans `ai-stack/.env`) | Fait le 2026-10-18 (variable + interrupteur de l'interface, les deux sont nécessaires sur une instance existante) |
| Admin → Paramètres → Interface | Modèle de tâches (voir §1) | Rapidité |
| Admin → Paramètres → Interface | Désactiver la génération automatique d'étiquettes et de suggestions de suite | Moins de tâches de fond |
| Admin → Paramètres → Modèles | Définir un modèle par défaut | Évite de le choisir à chaque conversation |
| Admin → Paramètres → Documents | Moteur d'extraction : Tika (déjà configuré) | Meilleure lecture des PDF et documents Office |
| Admin → Paramètres → Recherche web | Moteur : SearXNG (déjà configuré) | Recherche sans pistage |

Langue : `DEFAULT_LOCALE=fr` est défini à l'installation ; sur une instance existante, change-la dans Paramètres →
Général.

## 4. Voix en français : en place (testé le 2026-10-18)

La synthèse vocale (Kokoro, CPU) **a une voix française : `ff_siwis`** (une seule). Le fichier est dans l'image
(`/app/api/src/voices/v1_0/ff_siwis.pt`) et Kokoro génère un mp3 avec (vérifié, 24 236 octets pour une phrase courte).
La reconnaissance vocale (micro) est le Whisper intégré d'Open WebUI, qui comprend le français. La qualité de
`ff_siwis` est à juger à l'oreille ; le résultat a été jugé « clair » à l'écoute d'un échantillon.

**Réglages** : Admin → Paramètres → Audio (moteur « OpenAI », URL `http://kokoro:8880/v1`, modèle `kokoro`, voix
`ff_siwis`) ; `KOKORO_VOICE=ff_siwis` dans `ai-stack/.env` pour une réinstallation.

**Les trois pièges rencontrés**

| Symptôme | Cause | Remède |
|---|---|---|
| `Voice "ff_siwis" not found. Should be one of: af_heart…` (28 voix anglaises) | Ton réglage **personnel** (Paramètres → Audio) utilisait le moteur **Kokoro.js**, qui tourne dans le navigateur et n'a que des voix anglaises | Mettre le moteur sur le serveur (OpenAI / par défaut) |
| `Voice name cannot be empty` (400) | Après le changement de moteur, le champ Voix personnel était vide | Taper `ff_siwis` à la main (le champ accepte une saisie libre) |
| `External: 400, message='Bad Request'` alors que la voix est bonne | Le champ **Modèle** contenait `Kokoro` avec une majuscule ; Kokoro compare en respectant la casse | `kokoro` (ou `tts-1`) en minuscules |

Les logs de Kokoro (`docker logs kokoro`) n'indiquent que le code 400, pas le motif. Pour voir le motif, envoie la
requête à la main depuis le conteneur Open WebUI (`docker exec open-webui python3 …` vers `http://kokoro:8880/v1/audio/speech`)
et affiche le corps de l'erreur : c'est ainsi que « Voice name cannot be empty » est apparu.

**Piste non construite** : Speaches (reconnaissance + synthèse Piper en un service). Inutile tant que `ff_siwis` te
convient ; elle prendrait de la VRAM en concurrence avec le modèle de langage.

## 5. Ce qui n'est pas vérifié

- Les libellés exacts des menus (« Modèle de tâches », « Génération de titre »…) peuvent différer selon la version
  d'Open WebUI ; le chemin général Admin → Paramètres → Interface est le bon point de départ.
- Les variables `TASK_MODEL` et `DEFAULT_LOCALE` sont celles que je connais d'Open WebUI mais la page de
  configuration officielle consultée ne les détaillait pas : l'interface reste la méthode de référence, la variable n'est
  qu'un coup de pouce au premier démarrage.
- Le fait que le gros modèle et le petit tiennent ensemble en VRAM dépend du modèle choisi et du contexte : seul
  `ollama ps` sur ta machine le dit.
