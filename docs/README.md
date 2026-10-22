# Documentation

AiBeast = la machine IA (nom de la machine d'origine du projet). Les mesures et retours d'expérience ont été faits sur
cette machine de référence : RTX 3090 24 Go, 64 Go de RAM, Ubuntu 26.04.

| Document | Pour quoi faire |
|---|---|
| [installation.md](installation.md) | **Commencer ici** : installer le lab sur une nouvelle machine, de zéro à l'accès depuis ton PC |
| [acces-distant.md](acces-distant.md) | SSH par clé, configuration du PC (`lab client`), tunnels, bureau à distance (RDP), démarrage, secours |
| [lab.md](lab.md) | La commande `lab` : référence, mises à jour, retour arrière |
| [configuration.md](configuration.md) | `lab.conf` : réglages propres à la machine (disque de données, modèle, accès distant), séparation code / configuration / secrets |
| [portail.md](portail.md) | Page d'accueil unique (http://127.0.0.1:3010), tunnels Windows, ajout d'un service |
| [open-webui.md](open-webui.md) | Modèle de tâches, préréglages, réglages, état de la voix en français |
| [performance.md](performance.md) | Limite de puissance du GPU, réglages d'Ollama, marche à suivre des mesures |
| [comprendre-les-mesures.md](comprendre-les-mesures.md) | Pourquoi tester puissance, contexte, cache KV…, comment lire un rapport, glossaire |
| [remote-desktop-gpu.md](remote-desktop-gpu.md) | Analyse : le bureau à distance coûte ≈ 100 W |
| [alertes.md](alertes.md) | Prometheus → Alertmanager → ntfy : règles, test, réaction |
| [sauvegardes.md](sauvegardes.md) | Sauvegardes chiffrées (restic) et restauration |
| [raccourcis-windows.md](raccourcis-windows.md) | Double-clic sur ton PC : mode images, santé, mise à jour, Hermes ; modèle par défaut (`lab config`) |
| [panneau-web.md](panneau-web.md) | Page à boutons (modes, santé, mise à jour, sauvegarde, revue Hermes) via le tunnel SSH (`lab panel`) |
| [hermes-ssh.md](hermes-ssh.md) | Donner à Hermes un accès SSH limité à une machine de test (`lab remote`) |
| [n8n-gmail.md](n8n-gmail.md) | Tri des mails Gmail par le modèle local dans n8n, anciens mails, corbeille validée (workflows dans `n8n/`) |
| [developpement-agents.md](developpement-agents.md) | Développer avec Hermes : projets git, boucle code → test → review, fusion par toi (`lab dev`) |
| [generation-images.md](generation-images.md) | Images avec Qwen-Image-2.1 dans ComfyUI : installation, réglages, mesures, exemples, pièges |
| [openclaw.md](openclaw.md) | OpenClaw : installation, pièges rencontrés (réseau, clé factice, modèle, contexte 64k), sécurité, mise à jour |
| [agents-langfuse.md](agents-langfuse.md) | Langfuse, brancher Hermes, mode agents, ComfyUI (1er démarrage), pièges rencontrés |

Documentation à la racine : `README.md` (installation, étapes 1 à 8), `bench/README.md` (banc d'essai).

Convention : chaque document se termine par **« Ce qui n'est pas vérifié »**. Ce qui est écrit avant cette section a été
mesuré sur ta machine ou contrôlé ; ce qui est dedans ne l'a pas été.
