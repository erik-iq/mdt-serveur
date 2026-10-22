# Correctifs Windows depuis le serveur, IQ-5.7

## Fonctionnement

Le serveur .250 télécharge les correctifs cumulatifs Microsoft compatibles avec chaque contexte Windows connu : famille, version exacte, build principal, architecture et version de .NET. Les prérequis et les checkpoints fournis par le catalogue restent groupés avec leur correctif cible. Les mises à jour facultatives, les changements de version et le Store ne sont pas inclus.

Le poste déploie le WIM existant, prépare les logiciels et HPIA, puis copie les MSU depuis .250 par HTTPS. Il vérifie leur taille et leur SHA-256 avant de les installer silencieusement dans Windows avec DISM en ligne et sans redémarrage imposé par DISM. Aucune recherche Windows Update n’est exécutée sur le poste. Le serveur ne lance aucun MSU et ne modifie aucun WIM avec ce parcours.

Les correctifs déjà présents ou les builds Windows déjà plus récents sont ignorés. Les résultats natifs, les paquets ajoutés et le besoin de redémarrage sont enregistrés avant la suite. Un redémarrage demandé reprend la préparation. Le contrôle suivant vérifie le build Windows attendu et la finalisation des paquets ajoutés. Une installation dont le code de retour a été perdu ne donne jamais un succès automatique.

## Page Correctifs Windows

Le bouton **Rechercher et télécharger les KB** actualise les versions connues. Chaque carte indique le contexte, l’état, le dernier message, les KB, les fichiers disponibles, leur taille et leur empreinte. Une version exacte peut être ajoutée au formulaire ; le premier poste transmet aussi automatiquement son propre contexte.

La tâche serveur `AtelierPXE-WindowsKBRepository` lance l’actualisation chaque jour à **02:00, heure du serveur**. Les demandes simultanées pour une même version partagent le téléchargement. Un cache prêt reste réutilisable pendant 24 heures avant une nouvelle vérification ; le bouton permet de demander un contrôle immédiat. Les MSU déjà téléchargés et intacts sont réutilisés par le catalogue.

L’historique des anciennes préparations WIM reste accessible dans un panneau replié. Leur planification est désactivée lors de l’activation du nouveau dépôt. Une préparation WIM active doit être terminée ou annulée avec le script dédié avant de remplacer les scripts de la console. L’annulation abandonne la candidate privée, jamais l’image de production.

## Rapports et reprise

Les MSU sont conservés sur .250 dans `<data_dir>\windows-kb\packages`. Le poste utilise provisoirement `C:\ProgramData\AtelierPXE\Windows-KB`. Le fichier `windows-kb-result.json` conserve les passages, le contexte, les résultats par KB et les preuves de redémarrage. Les journaux `kb-KBNUMERO.log` et ce résultat sont inclus dans `Diagnostics-Deploiement.zip`.

Après la fin réussie, les rapports et inventaires sont reçus sur .250 avant nettoyage du dossier privé du poste. Le cache serveur reste disponible pour les déploiements suivants. Une erreur de téléchargement, de compatibilité ou d’installation reste visible dans le bilan et dans la fiche du site. Un installateur encore actif bloque le nettoyage.

Ce parcours évite la maintenance préalable du WIM. Le temps d’installation des correctifs et les redémarrages se produisent sur chaque poste ; aucun gain de durée totale n’est garanti sans mesure sur le matériel réel.
