# Panneau web à boutons

Une page unique pour les gestes répétitifs, sans terminal : modes images / normal / agents, état, santé, mise à jour, sauvegarde, et relecture / fusion des branches d'agents Hermes.

## Installation (une fois)

Sur AiBeast :

```
lab panel install
```

La commande crée un service utilisateur (`aibeast-panel`), le démarre, et affiche une adresse du type `http://127.0.0.1:3011/login?t=…`.

Sur ton PC : la ligne `LocalForward 3011 127.0.0.1:3011` fait partie de la configuration générée par `lab client` (voir `docs/acces-distant.md`) ; rouvre le tunnel, puis ouvre l'adresse affichée **une fois**. Un cookie de 30 jours te garde connecté ; ensuite `http://127.0.0.1:3011` suffit (lien aussi dans le portail).

Autres commandes : `lab panel token` (réafficher l'adresse), `status`, `logs`, `restart`, `uninstall`.

## Ce que fait chaque bouton

| Bouton | Commande lancée |
|---|---|
| Mode images / normal / agents | `lab mode images` / `normal` / `agents` |
| État | `lab mode status` |
| Santé | `lab doctor` |
| Mise à jour (confirmation) | `lab update` |
| Sauvegarde (confirmation) | `lab backup run` |
| Hermes : Relire / Diff complet | `lab dev review PROJET BRANCHE [--diff]` |
| Hermes : Fusionner (confirmation) | `lab dev merge PROJET BRANCHE --yes` (tests relancés d'abord ; échec = rien de fusionné) |

Une seule action à la fois : pendant qu'une tourne, les boutons sont grisés et le serveur répond 409 à toute autre demande. La sortie s'affiche en direct.

## Sécurité

- Le serveur n'écoute que sur `127.0.0.1` ; on n'y accède que par le tunnel SSH.
- Accès par jeton (`~/.config/aibeast-panel/token`, droits 0600) échangé contre un cookie `HttpOnly` / `SameSite=Strict`.
- Les requêtes d'action exigent en plus un en-tête `X-Panel`, un `Host` local et une `Origin` locale (contre les pages web tierces et le DNS rebinding).
- Liste fermée d'actions : le navigateur n'envoie jamais de commande, seulement un nom.
- Pour Hermes, projet et branche sont validés par expression régulière **et** doivent figurer dans la liste `dev.sh pending` ; la fusion exige une confirmation explicite.
- Les sorties sont nettoyées des séquences d'échappement et affichées en texte brut.

Le jeton donne le pouvoir de lancer une mise à jour ou une fusion : ne le colle pas dans une conversation ni un dépôt.

## Limites connues

- Le panneau ne lance pas Hermes dans un projet (session interactive) : `lab dev start NOM` ou `AiBeast-Hermes.bat`.
- Le choix du modèle par défaut reste `lab config set MODEL NOM` (pas de bouton).
- Une action ne survit pas à un redémarrage du service ; un `lab update` interrompu se reprend en terminal.

## Ce qui n'est pas vérifié

- Testé ici avec de faux `lab` et `dev.sh` (`scripts/test-panel.sh`, 29 contrôles) : authentification, Host/Origin, liste d'actions, verrou, validation des branches, filtrage des échappements. **Jamais lancé sur AiBeast** : le service systemd (`lab panel install`), `loginctl enable-linger` et l'affichage réel dans un navigateur sont à confirmer.
- L'interface n'a pas été vue dans un navigateur ; seule la syntaxe JavaScript a été contrôlée.
- La sortie du vrai `lab update` (couleurs, barres de progression) peut être moins lisible dans la page qu'en terminal.
