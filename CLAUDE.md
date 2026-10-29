# Reprise du projet dans Claude Code

Lire d’abord [AGENTS.md](AGENTS.md), puis [docs/PASSATION-PROJET.md](docs/PASSATION-PROJET.md). Les consignes d’encodage et de validation d’AGENTS.md s’appliquent à tout le projet.

## État à conserver

- Branche publiée : `codex/atelier-2`. Révision fonctionnelle actuelle : IQ-6.3. Le numéro du paquet Python et de l’archive reste `0.2.0`.
- Parcours : WinPE et image Windows, HPIA si sélectionné, logiciels, personnalisation et IQ, redémarrage et bilan.
- Les nouveaux déploiements ne lancent ni KB ni Windows Update automatiques. Le Store reste manuel. Les anciens scripts conservés ne justifient pas de réactiver ces étapes.
- Réglages français suisse du mode interne ; conserver la langue réelle du WIM et les contrôles d’édition.
- Cache HP, actualisation, source utilisée et résultat d’installation sont des informations distinctes. Un détail non transmis n’est pas une réussite déduite.
- Le nettoyage privé exige les reçus du serveur et les contrôles existants. Le dossier IQ et ses rapports doivent survivre.

## Méthode de reprise

Vérifier le statut Git et la branche avant de modifier. Utiliser le README et la passation pour retrouver les composants. Préserver les éventuelles modifications locales de l’utilisateur. Exécuter les contrôles nécessaires à la modification, puis expliquer ce qui a réellement été vérifié et les limites de l’environnement.

Distinguer code publié, console installée, image WinPE importée et déploiement physique validé. Une publication GitHub ne met pas le serveur à jour. Les mesures réseau nécessitent un nouveau WinPE IQ-6.3 et des compteurs disponibles sur le poste.

Le dossier de passation contient un résumé des décisions connues, pas un export exhaustif des discussions ChatGPT. Les données de production, médias et identifiants restent hors du dépôt.
