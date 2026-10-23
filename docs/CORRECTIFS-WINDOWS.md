# Correctifs Windows, IQ-5.8.5

La préparation des nouveaux postes ne lance plus Windows Update et n’installe pas automatiquement de KB. HPIA est exécuté en premier si sélectionné, puis les logiciels et le dossier IQ. La veille des versions et le cache KB du serveur restent consultables et utilisables manuellement.

## Ancien parcours Windows Update, IQ-5.8 à IQ-5.8.4


## Parcours actuel

Les nouveaux déploiements IQ-5.8.2 recherchent et installent automatiquement les mises à jour avec l’API Windows Update Agent, sous SYSTEM, avant les logiciels et HPIA. Les correctifs Windows et .NET, Defender, les pilotes et les firmwares applicables sont inclus. Les changements de version Windows restent exclus et le Store reste manuel.

Chaque installation enregistre son état avant l’appel natif et conserve son résultat individuel. L’indicateur CanRequestUserInput ne bloque plus une tentative silencieuse : ForceQuiet est demandé, les invites de source sont désactivées et un refus réel reste une erreur. Les téléchargements et installations emploient les rappels COM DISPID 0 validés pour la recherche physique sur le HP.

La préparation demande les redémarrages nécessaires et reprend au démarrage. Elle effectue une nouvelle recherche et poursuit les mises à jour restantes, avec un maximum de cinq passes d’installation et six redémarrages. Les recherches indisponibles sont réessayées avec une limite. Une installation interrompue sans résultat confirmé bloque le succès et le nettoyage, sans réinstaller aveuglément le pilote concerné.

Le fichier `windows-update-result.json` est inclus dans les diagnostics du site. Le statut final devient vert seulement après une recherche réussie sans correctif ni pilote restant proposé et sans redémarrage Windows en attente, ainsi qu’après les autres contrôles de préparation. Les rapports sont reçus sur .250 avant suppression du dossier privé du poste.

La tâche quotidienne de 02:00 continue à vérifier les nouvelles versions Windows. Le téléchargement de MSU sur .250 est désormais facultatif : il reste accessible par le bouton du cache KB pour les anciens déploiements, mais n’est pas exécuté automatiquement chaque jour. Le guide historique ci-dessous décrit cette méthode précédente.

## Ancien parcours du cache KB, IQ-5.7


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

## Nouvelles versions de Windows

Le panneau **Nouvelles versions de Windows 11** consulte la publication officielle Microsoft Release Health. La tâche quotidienne de 02:00 demande aussi cette vérification, même si aucun contexte KB n’est encore connu. Le bouton **Vérifier les versions Windows** permet un contrôle immédiat. La lecture de la page et son actualisation automatique ne déclenchent aucune requête Microsoft supplémentaire.

Seules les versions du canal de disponibilité générale dont la date de disponibilité est passée sont retenues. Les versions Insider, les annonces futures et les tableaux dont le format n’est plus reconnu ne sont pas considérés comme une nouvelle version confirmée. La page indique la date du dernier contrôle réussi ; en cas d’échec, les anciens résultats restent visibles avec un avertissement.

Les versions observées proviennent des contextes KB des postes et des rapports WIM existants. Cette comparaison ne certifie pas la version de chaque profil de production. Sans contexte connu, aucune conclusion « à jour » n’est affichée. Une version plus récente que la dernière version observée produit une notification dans ce panneau.

Le lien **Obtenir le média officiel** ouvre le téléchargement Microsoft. La veille ne télécharge pas un ISO automatiquement et ne contourne aucun accès ou droit de licence. Ajouter ensuite le média via la procédure habituelle, préparer Famille et Pro et les réglages français suisse, tester HPIA, les logiciels et les redémarrages, puis sélectionner les profils validés pour les futurs déploiements. Conserver les anciens profils permet un retour en arrière. Aucun remplacement du WIM ni aucune mise à niveau des postes ne sont réalisés par la veille.
