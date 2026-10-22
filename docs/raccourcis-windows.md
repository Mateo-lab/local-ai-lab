# Raccourcis Windows : agir sur AiBeast sans taper de commande

## La console : une fenêtre avec des boutons (le plus simple)

Double-clic sur **`AiBeast.bat`** (le seul fichier à la racine du dossier `windows\`, avec la config SSH ; tout le reste est dans `outils\`). Une fenêtre s'ouvre avec des boutons, rangés par thème :

1. **Connexion** : ouvrir / fermer les tunnels, tester la connexion. L'état des tunnels (ouverts ou fermés) s'affiche en haut et se met à jour seul.
2. **Navigateur** : portail, panneau de boutons, ComfyUI, Open WebUI, n8n (un message t'indique si les tunnels sont fermés).
3. **Livraison** : déployer la nouvelle version sur AiBeast, copier les sauvegardes sur ce PC.
4. **Modes** : images, normal, agents, état, santé.
5. **Maintenance** : mise à jour, sauvegarde, Hermes (projets, relecture, fusion).

Les actions qui modifient AiBeast (déployer, mise à jour, sauvegarde) demandent une confirmation. Chaque action longue s'ouvre dans sa propre fenêtre, qui reste ouverte jusqu'à ce que tu appuies sur Entrée : elle réutilise les scripts ci-dessous, inchangés. Les `.bat` individuels restent utilisables dans `outils\`.

**Non vérifié :** la console n'a jamais été lancée (pas de PowerShell dans mon environnement). Si elle ne s'ouvre pas, lance `outils\AiBeast-Console.ps1` par clic droit > Exécuter avec PowerShell et colle-moi l'erreur.

Double-clic sur un fichier `.bat` du dossier `windows\outils\` de ton PC. Chaque raccourci se connecte à AiBeast par SSH (comme `Ouvrir-AiBeast.bat`),
lance la commande `lab` correspondante et affiche le résultat. Il faut le réseau (VPN si tu es dehors), la clé SSH et le raccourci `aibeast` dans la configuration SSH du PC,
généré par `lab client` sur AiBeast (voir `docs/acces-distant.md`). Le dossier `windows\` peut être n'importe où sur le PC :
l'archive `ai-lab.tar.gz` et la copie des sauvegardes `aibeast-backup\` sont cherchées à côté de lui.

| Raccourci | Ce qu'il fait | Commande équivalente |
|---|---|---|
| `AiBeast-Menu.bat` | Menu numéroté avec toutes les actions ci-dessous | — |
| `AiBeast-Images.bat` | Décharge le modèle de langage, démarre ComfyUI, ouvre `http://127.0.0.1:8188` si le tunnel est actif | `lab mode images` |
| `AiBeast-Normal.bat` | Arrête ComfyUI, rétablit Kokoro et Tika | `lab mode normal` |
| `AiBeast-Agents.bat` | Libère la VRAM pour Hermes | `lab mode agents` |
| `AiBeast-Sante.bat` | Contrôle de santé complet | `lab doctor` |
| `AiBeast-Mise-a-jour.bat` | Sauvegarde puis mise à jour des images, dans une session `tmux` (continue si la connexion coupe) | `lab update` |
| `AiBeast-Hermes.bat` | Relire et fusionner le travail de l'agent, ouvrir Hermes dans un projet, créer un projet | `lab dev …` |

Le menu ajoute l'état (`lab mode status`), la sauvegarde (`lab backup run` sous tmux) et l'ouverture du portail.

## Modèle par défaut

Plus besoin de donner `--model` : `lab bench`, `lab dev start` et `lab dev ctx64` utilisent le **modèle principal**, choisi dans cet ordre :
1. la variable `LAB_MODEL` (ponctuel) ;
2. le réglage mémorisé : `lab config set MODEL NOM` (`lab config list` pour le voir, `lab config unset MODEL` pour le retirer) ;
3. sinon le **plus gros modèle installé**, jamais le petit modèle de tâches d'Open WebUI ni un modèle d'embeddings.

`lab main-model` affiche le choix actuel. Le modèle par défaut d'**Open WebUI** n'est pas géré ici : à ma connaissance il se règle dans son interface
(Réglages → Modèles), et une variable d'environnement serait ignorée une fois ce réglage enregistré (non vérifié).

## Autres fichiers du dossier `outils\`

| Fichier | Rôle |
|---|---|
| `Installer-config-SSH.bat` | Installe ou met à jour le raccourci `aibeast` dans `%USERPROFILE%\.ssh\config` à partir de `windows\ssh_config_aibeast.txt` (généré par `lab client`) ; sauvegarde l'ancienne configuration, ne touche pas aux autres blocs |
| `Isoler-machine-de-test.ps1` | À lancer **en administrateur sur la machine de test** des agents (pas sur ton PC) : coupe Internet et le DNS pour cette machine, interdit les tunnels SSH au compte de Hermes ; `-Annuler` pour revenir (voir `docs/isolation-agents.md`) |
| `recuperer-work-hermes.bat` | À lancer sur la machine de test Windows (`lab remote add … --windows`) avec ton compte : copie `C:\Users\hermes\work` vers `Documents\hermes-work` (robocopy, ne supprime rien) |
| `Deployer-sur-AiBeast.ps1` | Livre `ai-lab.tar.gz` (produite sur AiBeast par `scripts/release.sh`). Refuse si le dépôt git d'AiBeast a des modifications non commitées, affiche `git status` après extraction. Sauvegarde de sécurité `~/avant-*.tgz` (≈ 1 Mo : sans `bench/.venv` ni `bench/results`, que la livraison ne touche jamais) |

## Sécurité des raccourcis

- Aucun nouveau service sur AiBeast : un raccourci est une commande SSH avec ta clé.
- Les noms de projets et de branches affichés par le menu viennent d'AiBeast, donc en partie de l'agent. `lab dev pending` n'émet que des noms
  composés de caractères sûrs, le menu les **revalide** avant de les placer dans une commande, et la revue retire les séquences d'échappement du texte écrit
  par l'agent. La fusion relance toujours le check dans le bac à sable et te demande confirmation.

## Ce qui n'est pas vérifié

- **Les scripts PowerShell (`AiBeast.ps1` et les `.bat`) n'ont jamais été exécutés** : je n'ai pas PowerShell dans mon environnement. La logique côté AiBeast
  (`lab config`, `lab main-model`, `lab dev pending/names`, noms hostiles) est testée par `scripts/test-dev.sh` ; la partie Windows ne l'est pas.
  Au premier essai, lance `AiBeast-Sante.bat` (le plus simple) et colle-moi l'erreur éventuelle.
- Actions interactives (Hermes, mise à jour sous tmux) : lancées avec `Start-Process … -NoNewWindow -Wait` pour garder le terminal ; non essayé.
- `lab tmux update` : la session `lab-update` n'a jamais tourné ; si elle existe déjà, le raccourci s'y rattache.
- Le chemin `~/.local/bin/lab` suppose que `lab install` a été fait sur AiBeast (c'est le cas si `lab` marche dans ton terminal).
