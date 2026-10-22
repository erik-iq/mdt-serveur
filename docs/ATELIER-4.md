# IQ Atelier 4 - bureau disponible et préparation en arrière-plan

Cette version unifie le site, WinPE et le suivi Windows en bleu/lilas. Le logo fourni a été adapte sur fond transparent. Pour utiliser le PNG original sans adaptation, passer `-BrandLogoPath C:\chemin\logo.png` au script de mise à jour.

## IQ-5.6 : fin automatique et bilan après redémarrage

Après les installations réussies, Atelier enregistre le démarrage courant et redémarre Windows après un délai de 60 secondes. La tâche SYSTEM reprend au démarrage suivant, contrôle à nouveau les logiciels sélectionnés dans Windows et consomme les demandes de redémarrage des pilotes. Les résultats HP natifs et leurs codes restent conservés. Aucun logiciel n’est réinstallé pour ce contrôle. Une erreur reste visible et ne devient jamais un succès par simple redémarrage.

Le compte intégré de préparation bénéficie d’une seule reconnexion automatique lorsqu’il est configuré sans mot de passe par le déploiement. La fenêtre de préparation se rouvre et affiche le succès ou l’échec. Elle reste dans `C:\IQ_\Rapports\Preparation`, pour fonctionner même lorsque le dossier privé a déjà été supprimé. La tâche de notification se retire après affichage du bilan. Les paramètres de connexion automatique sont ensuite supprimés.

Les tests matériels manuels et l’état de licence indisponible restent des informations d’inventaire ; leur absence ne sollicite pas le technicien et ne bloque pas le succès. Les vrais échecs d’installation restent signalés. Après confirmation des rapports, des inventaires et des archives HP par .250, le dossier `C:\ProgramData\AtelierPXE` et ses secrets temporaires sont supprimés. Si le serveur est indisponible, la transmission et le nettoyage sont différés.

Les profils unilingues sont retirés des choix, leurs références historiques sont conservées. Les profils ordinaires perdent leur suffixe Test ; les véritables candidats de maintenance conservent leur distinction jusqu’à la publication validée.

## IQ-5.4.1 : reprise HPIA et cache pour Windows non reconnu par CMSL

Les rapports du HP physique confirment l’installation des cinq logiciels cochés, mais HPIA 5.3.6 reste sur Analyze Action List avec onze recommandations et aucune installation confirmée, même avec un code final zéro. Le journal CMSL refuse explicitement OsVer=26H2. IQ-5.4.1 ajoute une seule reprise SPList sur les recommandations automatisables lorsque le rapport prouve qu’aucune installation n’a eu lieu, sans Forcé. Pour les versions absentes du ValidateSet CMSL, le serveur met en cache les seuls numéros SoftPaq recommandés, sans les exécuter ni substituer une autre version Windows. L’analyse HP reste en ligne dans ce mode. Les signatures, erreurs, reprises BIOS et avertissements de compatibilité sont conservés.

Consulter [le diagnostic et la procédure de validation](VALIDATION-DEPLOIEMENT.md). Mettre à jour .250 avec Upgrade-Atelier4.ps1 et utiliser le nouveau WinPE IQ-5.4.1 pour le prochain essai. Le serveur ne relance pas HPIA sur le poste déjà terminé. Les tests reproduisent les rapports et les commandes avec les appels constructeur simulés ; le résultat natif est encore à vérifier sur le HP.

## IQ-5.4 : maintenance mensuelle des WIM sur .250

La console serveur IQ-5.4 ajoute la sauvegarde vérifiée du WIM, la recherche des correctifs Microsoft stables et de leurs checkpoints, l’intégration DISM sur une copie, les profils TEST et une publication après déploiement Windows réussi pour chaque index utilise. La tâche mensuelle du 15 à 02:00 ne change jamais les profils de production. Les erreurs conservent l’image actuelle. Les scripts HPIA et le WinPE IQ-5.3.2 ne changent pas dans cette révision.

Consulter [la procédure de maintenance des images Windows](MAINTENANCE-IMAGES-WINDOWS.md) pour lancer la première préparation, retrouver les journaux, enregistrer un candidat et publier après test. Cette fonction seule se met à jour avec Update-Console.ps1 sans reconstruire WinPE. La validation native sur .250 et le premier démarrage du PC de test restent à effectuer.

## IQ-5.3.2 : HPIA 4104 et rapports sans installation

Le rapport du HP 840 G5 sous Windows 11 26H2 indiquait Analyze Action List, LastOperation EndAnalyze, un code global 4104 et onze recommandations avec Remédiation vide. Le journal du passage Installation ne contenait pas de résultat d’installation des SoftPaq. Atelier traitait à tort ces recommandations comme des tentatives dont le résultat était inconnu, puis remplaçait le diagnostic 4104 par un avertissement générique sur les paquets.

La commande d’installation utilise maintenant /IgnoreGenericOsError, l’option officielle HP qui laisse remonter le code global normal au lieu de la priorité 4104 : par exemple 3010 pour un redémarrage nécessaire ou 3020 pour une installation en échec. /Action:Install, /Silent et les contrôles HP restent actifs ; aucun /Force n’est ajouté. Cette option ne garantit pas la compatibilité de tous les SoftPaq avec une version Windows non couverte par une référence dédiée.

Les recommandations sans Remédiation ne sont plus présentées comme des installations tentees. Si des recommandations sont présentes mais qu’aucun résultat d’installation n’est obtenu, Atelier garde le statut À vérifier avec un message explicite. Les vrais codes par SoftPaq, les paquets non automatisables et les redémarrages BIOS restent pris en compte. Les colonnes Nom / Catégorie et la valeur Faux des CSV HP français sont reconnues. Si une référence générique a été utilisée, cet avertissement reste visible même quand les codes d’installation sont bons.

Le rapport montrait aussi un dépôt .250 non utilisé avec une demande serveur en échec. Le client masquait parfois le motif du serveur derrière Agent CMSL indisponible. Il conserve maintenant ce motif avant de basculer sur Internet. La cause exacte de la synchronisation CMSL reste à vérifier dans D:\AtelierPXE\data\hp-repository\worker.log ; le ZIP du poste ne contient pas ce journal serveur.

Sources HP : [notes HPIA, code 4104 et IgnoreGenericOsError](https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html), [guide HPIA](https://ftp.ext.hp.com/pub/caps-softpaq/cmit/whitepapers/HPIAUserGuide.pdf).

Appliquer la mise à jour sur .250 puis utiliser le nouveau WinPE IQ-5.3.2 pour les prochains déploiements. Une mise à jour serveur ne relance pas les pilotes sur un poste dont la préparation est déjà terminée. Les tests utilisent une reproduction du rapport fourni avec uniquement les métadonnées publiques des SoftPaq ; aucun numéro de série ou identifiant de déploiement n’est inclus. L’installation réelle avec HPIA reste à valider sur le HP.

## IQ-5.3.1 : reprendre après Image appliquée

Le serveur conserve la protection contre un nouveau démarrage PXE après application de l’image lorsque la préparation Windows n’est pas terminée. Ce cas renvoyait seulement HTTP 409 et bloquait aussi une réinstallation volontaire après un premier démarrage Windows en échec.

Le nouveau WinPE propose maintenant Recommencer l’installation Windows ? pour ce cas précis. Non laisse l’image intacte et invite à démarrer Windows Boot Manager. Oui crée un nouvel essai en attente, lie au même numéro de série et à l’identifiant du dernier essai applique. Le choix Windows, du nom et du disque reste a faire dans l’assistant ; aucune partition n’est effacée par cette reconnexion. Le premier essai, ses evenements, rapports et fichiers sont conservés. Le nouvel essai indiqué dans son journal l’identifiant de l’installation précédente.

La reprise exige une réponse serveur structuree pour ce numéro de série et une confirmation locale. Un simple code 409, un autre poste, un ancien identifiant qui n’est plus le dernier, un essai déjà en cours ou une demande sans SN ne permettent pas de forcer une réinstallation. Deux demandes simultanees ne creent qu’un nouvel essai ; une reconnexion normale retrouve ensuite cet essai.

Mettre à jour .250 avec Upgrade-Atelier4.ps1, puis redémarrer sur WinPE IQ-5.3.1. Les réglages français suisse et les corrections de compte / affichage / redémarrage IQ-5.3 sont inclus. La boîte WinForms et la réinstallation physique restent à valider sous Windows ; les tests exécutent les transitions API et les fonctions de connexion avec les appels constructeur et l’interaction opérateur simulés.

## IQ-5.3 : assistant adaptable, redémarrage et compte Administrateur

L’assistant WinPE s’ouvre maximise et adapte les champs, les textes et le journal à la taille de sa fenêtre. Le bandeau utilise la hauteur nécessaire au titre et a sa description, sans ligne fixe qui coupe le texte. Le logo reste petit en haut a droite. Le menu latéral disparait lorsque l’écran manque de place ; les pages longues restent defilantes. Redimensionner ne recrée pas les champs et ne remet pas a zéro les choix ni la progression.

Après application de l’image, copie des scripts de préparation, écriture et relecture du fichier de réponses et configuration du démarrage UEFI, l’agent annonce l’image préparée au serveur. Il libère ensuite ses fichiers et son verrou puis demande le redémarrage WinPE après cinq secondes. Aucun redémarrage automatique ne suit un échec du déploiement. Un refus de wpeutil reste affiché dans le journal. Le statut image appliquée ne signifie pas que les logiciels Windows sont déjà installés : ils continuent au premier démarrage.

Le profil interne et l’assistant proposent les formats et la langue système fr-CH, le clavier français suisse QWERTZ 100c:0000100c et le fuseau Zurich (W. Europe Standard Time). La langue d’interface reste celle du WIM français, fr-FR : fr-CH designe ici les réglages suisses et non un pack d’interface Windows distinct.

Le fichier de réponses utilisait Administrateur comme Username AutoLogon. Microsoft exige le nom neutre anglais Administrator pour activer automatiquement le compte intégre pendant Setup, même pour une image francaise. La correction utilise Administrator dans le XML ; le compte réel reste identifié par son SID se terminant par -500 et configure sous le nom Administrateur. Son activation dans specialize est relue et vérifiée. Les connexions automatiques sont arrêtées par Atelier après le lancement de la maintenance. Aucun autre compte ni mot de passe de secours n’est créé.

Source : [Microsoft - AutoLogon Username, seul Administrator en anglais active automatiquement le compte](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon-username).

La mise à jour sur .250 reconstruit et importe WinPE avant de nettoyer les anciennes images Atelier. Le nettoyage reconnait aussi l’ancien cache Drivers\WinPE-Official\HP-sp173204 et son extracteur WinPE-HPDrivers.ps1 remplace par Intel. Les fichiers locaux modifiés, chemins liés, caches encore ouverts, données actives et dépôt HPIA/CMSL sont conservés. Les trois dernières sauvegardes restent disponibles. Les anciennes procédures de reprise de l’extracteur HP ont été retirées de cette documentation.

Exécuter Upgrade-Atelier4.ps1 sur .250 et redémarrer sur le nouveau WinPE IQ-5.3. La mise à jour du serveur ne modifie pas une installation Windows déjà terminée ni une session WinPE déjà ouverte.

Les tests exécutent le générateur XML, la configuration du compte avec comptes simulés, les gardes du redémarrage et le nettoyage dans des dossiers temporaires. La syntaxe PowerShell est contrôlée. Les contrôles WinForms de tailles et de redimensionnement exigent Windows et sont ignorés dans l’environnement Linux ; le rendu physique, OOBE et le redémarrage réel restent à valider sur un poste de test.

## Réseau WinPE : un seul pilote Intel I219

Sur le HP EliteBook 840 G5, la connexion fonctionne avec la docking mais pas avec le port intégre. Les deux interfaces utilisent des pilotes différents. Le démarrage PXE utilise le réseau du firmware UEFI ; une fois WinPE charge, Windows doit disposer de son propre pilote. Une absence totale d’interface dans ipconfig /all ne correspond pas à un refus du bouton Connexion. Le numéro de série reste l’identifiant du PC, même si le dock change.

La construction n’utilise plus le pack WinPE HP complet ni son extracteur SoftPaq. Elle télécharge le ZIP Ethernet x64 officiel Intel 31.2.2 (environ 39 Mo), puis sélectionne exactement un INF NDIS e1d / e1d6*x64 de classe Net, applicable à la version de WinPE et contenant les identifiants I219-LM / I219-V PCI\VEN_8086&DEV_15D7 et PCI\VEN_8086&DEV_15D8 du 840 G5. Les autres familles Intel, NetAdapterCx et pilotes x86 ne sont pas injectés. La version du ZIP et son SHA-256 officiel sont fixes. Le nombre de fichiers INF ajoutés automatiquement est un ; un INF peut couvrir plusieurs variantes matérielles de la même famille.

Le cache est D:\AtelierPXE\Drivers\WinPE-Official\Intel-I219-31.2.2 par défaut avec Upgrade-Atelier4.ps1. Le ZIP n’est téléchargé de nouveau que s’il est absent ou son empreinte incorrecte. Les fichiers extraits sont contrôlés et réparés depuis le ZIP si nécessaire. Le journal selection.json indique le fichier retenu, sa version et la version de WinPE. Aucun installateur Intel ou HP n’est exécuté sur .250. Les fichiers CAT / SYS restent avec leur INF ; DISM valide le pilote signe pendant l’intégration. Un refus DISM ou un pilote absent du DriverStore empêche la publication et le nettoyage de l’ancienne image.

Les pilotes déjà inclus par Microsoft dans l’ADK sont conservés pour les autres PC et docks. Les anciens caches HP ne sont plus utilisés. Aucun dossier de pilotes supplémentaires n’est repris automatiquement : -DriversPath doit être indiqué explicitement pour en ajouter. Il n’existe pas de pilote universel HP pour tous les ports Ethernet et tous les docks.

Au lancement, si aucune IPv4 utilisable n’est présente et si le PCI correspond a 15D7 / 15D8, Atelier tente une seule fois drvload sur le fichier effectivement injecté, vérifie par son empreinte, puis relance l’initialisation réseau. Chaque commande a un délai de 15 secondes maximum. Une docking déjà connectee n’est pas réinitialisée. L’assistant reste accessible en cas d’échec ; Logs\network-recovery.json conserve les codes des commandes dans WinPE.

Appliquer la révision sur .250 avec Upgrade-Atelier4.ps1, puis redémarrer le HP sur le nouveau WinPE IQ-5.3 pour tester le port intégre. Une session WinPE déjà ouverte ne reçoit pas les nouveaux pilotes. La docking peut être utilisée entre-temps. L’installation des logiciels et HPIA dans Windows n’est pas modifiée par cette correction.

Les tests exécutent l’extraction de ZIP de test, la sélection matérielle / version de WinPE, les contrôles de cache, les refus d’archive et l’orchestration de la construction et du démarrage. Les opérations ADK / DISM / WDS sont simulées. Le téléchargement du vrai ZIP Intel est bloque par la politique réseau de l’environnement de développement ; sa structure réelle et le port du HP physique restent à valider sur .250. La construction refuse de substituer un autre pilote si aucun INF conforme n’est trouvé.

Sources : [téléchargement officiel Intel et SHA-256](https://www.intel.com/content/www/us/en/download/727998/intel-network-adapter-driver-for-microsoft-windows-11.html), [README Intel 31.2.2](https://downloadmirror.intel.com/923981/readme.txt), [notes HP listant le 840 G5 et la famille I219](https://ftp.hp.com/pub/softpaq/sp98501-99000/sp98585.html).

## Diagnostic du bouton Connexion IQ-5.0.1

Cette correction concerne toutes les marques. Elle ne change ni les pilotes ni la configuration réseau. Le bouton distingue la connexion à l’API Atelier, la récupération des accès au partage, l’ouverture du partage des images et le chargement des profils. Une erreur pendant la connexion ouvre une boîte de dialogue complète, avec l’étape, l’adresse du serveur, le code HTTP / transport disponible et le message Windows. Elle ne reste plus tronquée dans la bande d’état de 32 pixels.

Un échec HTTPS ne déclenche plus une nouvelle lecture WMI et n’est plus présente automatiquement comme un inventaire réseau incomplet. Les erreurs TLS, DNS, délai et connexion sont distinguées quand Windows les expose. La lecture des accès au partage utilise aussi un délai de 20 secondes. Les informations affichées servent à identifier la cause sur le poste ; cette révision ne prétend pas réparer une cause réseau ou certificat encore inconnue.

Mettre à jour et reconstruire avec Upgrade-Atelier4.ps1, puis démarrer sur le nouveau WinPE qui affiche IQ-5.0.1. En cas d’échec, la photo de la boîte Connexion Atelier - erreur complète suffit pour transmettre le diagnostic, sans commande PowerShell sur le poste. Les tests exécutent le vrai parcours Connect-Post avec API et partage simulés, ainsi que les classifications d’exceptions Windows ; le rendu WinForms et la connexion au serveur physique restent à vérifier sous Windows.

## Identification par numéro de série IQ-5.0

Les nouveaux WinPE identifient le PC par son numéro de série SMBIOS, lu dans Win32_BIOS puis, si nécessaire, Win32_ComputerSystemProduct. La valeur est normalisee en majuscules, sans espaces superflus. Un SN absent, générique ou invalide est refusé ; aucun identifiant MAC ou nom invente ne le remplace dans le nouvel assistant. Le nom Windows propose reste les quatre derniers chiffres du SN, à compléter comme auparavant.

La MAC est seulement une observation réseau. Une liste de MAC vide ne bloque plus la connexion au serveur : l’assistant envoie le SN et tente directement HTTPS. Les observations réseau sont relues au clic Connexion, avec des lectures WMI et .NET complémentaires. Un inventaire WMI incomplet ne prouve pas une panne réseau. Cette révision n’ajoute aucun pilote réseau.

Le même SN retrouve la même fiche, même avec un autre dock ou aucune MAC visible. Deux SN différents peuvent partager la MAC d’un dock sans partager leur autorisation ni leur historique. Le plan inclut le SN attendu et l’agent relit le SN matériel avant de reserver le déploiement puis de nouveau avant l’effacement. Les contrôles du disque, de l’UEFI et de l’image restent actifs. Le SN est un contrôle de cible et de suivi, pas une preuve cryptographique ; il doit être réel et unique sur les PC de l’atelier.

Le site affiche le SN dans Parc machines, Activité et la fiche ordinateur. L’enregistrement manuel demande le SN ; la MAC est facultative. Les nouvelles préparations indiquent IQ-5.0 et le SN WinPE dans leur rapport. Le fonctionnement HP/CMSL, les logiciels et la reprise BIOS restent ceux de la révision précédente.

La migration SQLite conserve les IDs des machines, déploiements, rapports, fichiers et notes. L’ancienne contrainte MAC unique est conservée dans une colonne technique privee, tandis que la MAC observée peut désormais être partagée. La migration du schéma et le rapprochement initial sont transactionnels. Un SN historique est repris automatiquement seulement s’il identifie une seule fiche sans historique mélange. Une ancienne fiche de dock contenant plusieurs SN reste intacte ; les prochains déploiements utilisent une nouvelle fiche par PC. Plusieurs anciennes fiches portant le même SN exigent un rapprochement manuel ; aucune fusion destructive n’est faite.

Les anciens clients MAC restent compatibles avec leurs fiches sans SN. Ils ne peuvent pas prendre une fiche déjà identifiée par SN en reutilisant la MAC du dock. Pour supprimer le blocage Aucune MAC détectée, mettre le serveur à jour et reconstruire WinPE avec Upgrade-Atelier4.ps1 ; le titre de l’assistant et /health doivent annoncer IQ-5.0. L’image WDS garde le nom de famille ATELIER-4 suivi de sa date de construction.

Les tests couvrent le même PC avec plusieurs docks, plusieurs PC sur un dock, une liste de MAC vide, les SN génériques, les codes reserves à un autre PC, la rotation des jetons, les contrôles avant effacement et la migration d’une ancienne base a deux reprises. Les tests de laboratoire n’exécutent aucun effacement réel ni aucun déploiement Windows physique.

## Correctif graphique IQ-4.1

Le logo est limité a 40 x 40 pixels et place en haut a droite sur le site, WinPE et le suivi Windows. Le site lui donne aussi des dimensions HTML : une feuille de style absente ou ancienne ne peut plus afficher le PNG a sa taille d’origine.

La feuille de style utilise un seul thème : fond clair, cartes blanches, texte bleu nuit, boutons bleus et dégradé bleu `#D2E4F1` / lilas `#E9D9EA`. Les anciennes regles vert fonce ont été retirées.

Chaque adresse CSS, JavaScript et logo contient une empreinte de son contenu. Les pages et ressources du site portent `Cache-Control: no-store`, pour éviter le mélange nouveau HTML / ancien CSS lors d’une mise à jour. `/health` confirme maintenant `ui_revision: IQ-5.0` ; la mise à jour contrôle ce marqueur avant de valider le démarrage.

Après la mise à jour, ouvrir `https://192.168.99.250/?theme=IQ-5.0`. Pour WinPE et la préparation des prochains postes, utiliser l’image reconstruite par le script de mise à jour. Les tests navigateur reproduisent le logo geant avec l’ancien CSS puis verifient la correction sur écran 1440, 1920 et mobile 390 pixels. Le rendu WinForms reste à valider sur Windows.

## Assistant et fiche ordinateur IQ-4.2

Les polices WinForms utilisent un constructeur explicitement type : cela évite une interprétation de la taille comme un style italique. Le titre est moins grand, sa description peut revenir à la ligne et la liste Windows ne répéte plus les informations du profil. Les réponses JSON annoncent explicitement UTF-8 pour Windows PowerShell 5.1. Les données existantes sont conservées : un nom déjà enregistré avec des caractères incorrects doit être corrigé dans sa source.

Le nom propose dans WinPE est uniquement constitue des quatre derniers chiffres du SN, en conservant les zéros initiaux. Aucun préfixe ni nom de remplacement n’est ajouté. Si le SN est absent, générique ou contient moins de quatre chiffres, le champ reste vide. **Compléter le nom avant de continuer**, par exemple `8323` devient `ATELIER-8323` : le nom Windows valide doit commencer par une lettre et contenir au maximum 15 lettres, chiffres ou tirets. Le champ Préfixe et le bouton Recalculer sont retirés.

La région et les formats sont proposés en `fr-CH`. Cela ne change pas la langue du WIM. Depuis IQ-4.4, WinPE impose le clavier français suisse ; l’assistant utilise aussi cette disposition pour le Windows déploye, sans sélecteur de clavier. Propriétaire et organisation ne sont plus demandes. Le fond `Fond Atelier.png` ou `fon atelier.png` est sélectionné par défaut quand il est disponible. La mise à jour enregistre ce fichier si elle le trouve dans `<data_dir>\artifacts` ; sinon elle affiche un avertissement. Elle ne crée pas de faux fond d’écran. Pour l’ajouter ensuite : copier le PNG dans ce dossier, puis Profils Windows, Enregistrer un fichier, type Fond d’écran.

Dans Activité de déploiement, cliquer **Fiche ordinateur**, ou cliquer le nom dans **Parc machines**. La fiche regroupe identité matérielle, licence, historique pagine, PDF, XML/CSV, tests, garantie connue et observations datees du technicien. Les observations sont conservées sur le serveur, indépendamment des rapports. Les tests et la garantie apparaissent après utilisation de leurs outils et régénération du rapport ; aucun résultat n’est invente.

Chaque nouveau déploiement mesure l’application DISM du WIM, les logiciels WinGet, la préparation de l’outil constructeur, les mises à jour HP et la collecte XML/CSV. Ces mesures apparaissent dans la fiche et les nouveaux rapports PDF. Les anciennes mesures Windows Update restent visibles dans l’historique. Les durées sont mesurées par chronomètre dans le processus ; elles n’incluent pas les periodes hors tension ni les attentes entre redémarrages. Une fin de mesure non reçue reste signalée et les anciens déploiements n’obtiennent pas de durées reconstituees. Les transmissions reutilisent les mêmes identifiants de mesure pour éviter les doublons.

Depuis IQ-5.0, la fiche utilise le numéro de série comme identité du poste. La MAC observée est informative ; les anciennes fiches sont conservées selon les regles de migration ci-dessus.

## Dépôt HP et exécution silencieuse IQ-4.9

La case HP Image Assistant reste l’unique déclencheur sur le poste. Sans cette case, aucune installation HPIA, aucune demande de dépôt ni exécution SoftPaq. Les autres logiciels et Lenovo System Update gardent leurs sélections WinGet.

Sur .250, `Upgrade-Atelier4.ps1` met la console à jour, appelle `Enable-HPRepository.ps1`, puis reconstruit et importe le nouveau WinPE. Le titre de l’assistant et `/health` doivent annoncer IQ-5.0. Aucun script manuel n’est nécessaire sur les prochains postes déployés. Les postes déjà terminés ne reçoivent pas rétroactivement ces fichiers.

### Correctif d’installation CMSL pour PowerShellGet ancien

Le journal `hp-repository\setup.log` peut indiquer : `Impossible de trouver un parametre correspondant au nom AcceptLicense`. La version initiale IQ-4.9 passait ce paramètre a Install-Module sans vérifier la version de PowerShellGet fournie avec Windows PowerShell 5.1. CMSL n’était donc pas installé, même si la création de la tâche continuait ensuite.

Le correctif de `Enable-HPRepository.ps1` met PowerShellGet à niveau vers 2.2.5 pour tous les utilisateurs si nécessaire, avec une commande compatible avec l’ancienne version. Il installe ensuite HPCMSL dans un nouveau processus Windows PowerShell, sans profil, afin de charger les nouvelles versions de PowerShellGet et PackageManagement. Aucun redémarrage Windows n’est nécessaire pour ce changement de session.

Le programme vérifie le chargement de CMSL et ses cinq commandes de dépôt avant d’annoncer leur disponibilité. Un échec affiche maintenant l’étape, son message et le chemin complet du journal. L’agent peut rester en attente et les postes conservent leur repli Internet ; la création de la tâche ne signifie plus que le dépôt est prêt.

Pour une console déjà mise à jour vers IQ-4.9, remplacer uniquement `scripts\Enable-HPRepository.ps1` dans le dossier de la console et le relancer en Windows PowerShell administrateur sur .250. Le script de localisation existant retrouve l’installation par la tâche AtelierPXE-Console. Il n’est pas nécessaire de reconstruire WinPE pour cette réparation serveur. La tâche de dépôt déjà activé retente le chargement du module dans sa boucle habituelle.

### Parcours du poste

1. WinGet prépare l’outil HPIA et vérifie l’exécutable signe HP, comme en IQ-4.8.1.
2. Dans Windows, HPIA lance une analyse `Action:List` sans interface. Les IDs des SoftPaq recommandés sont lus dans ses rapports ; les IDs des logiciels déjà installés ne sont pas utilisés pour demander des téléchargements.
3. Atelier demande le dépôt correspondant au code de plateforme HP (quatre chiffres hexadecimaux), à Windows 10/11 et a sa version réelle lue dans le registre. Le nom libre du profil Windows n’est pas une preuve de version.
4. Si le dépôt date de moins de 24 heures et contient les IDs recommandés, il est copié depuis .250 par HTTPS, contrôle par SHA-256 puis extrait dans le cache privé du poste.
5. HPIA analyse à nouveau le vrai matériel puis installe seulement les SoftPaq applicables, en utilisant `OfflineMode` avec cette copie CMSL. Aucun `/Force` n’est utilisé et aucun code constructeur n’est transformé en succès artificiel.
6. Si le dépôt manque, est ancien ou incomplet, une synchronisation serveur est demandée. L’attente de préparation est limitée a environ 90 secondes. Si l’agent est indisponible, le repli est immédiat. Le poste utilise alors HP directement ; le travail de préparation du cache peut continuer sur .250 pour les prochains postes.
7. Un code 256 après l’analyse signifie aucune recommandation : pas de copie du dépôt, pas de seconde passe d’installation. Le serveur peut quand même entretenir ses références en arrière-plan.

Le premier remplissage télécharge un ensemble cohérent pour la plateforme / Windows, pas uniquement un fichier manquant. La copie locale du dépôt peut donc faire plusieurs Go, même si un seul paquet doit être installé. Les demandes identiques sont regroupees ; les paquets existants sont réutilisés par CMSL. Une recommandation nouvelle absente du dépôt déclenche une actualisation. Si une synchronisation terminée ne fournit toujours pas ce SoftPaq, la même demande ne tourne pas en boucle : le poste utilise HP directement.

L’installation n’est lancée qu’une fois par passage. Un échec après son lancement ne provoque pas une seconde passe Internet pendant le même démarrage, afin de ne pas répéter un BIOS / firmware. Un autre HPIA déjà actif empêche de lancer un deuxième traitement. Les nouveaux déploiements autorisent la reprise après un vrai redémarrage Windows, decrite ci-dessous.

### Dépôt sur le serveur

La tâche `AtelierPXE-HpRepository` fonctionne en SYSTEM, sans session administrateur ouverte. Elle utilise la bibliothèque officielle HPCMSL 1.9.0 (ou une version plus récente déjà installée pour tous les utilisateurs). Le programme d’activation l’installe depuis PSGallery si nécessaire. Les noms actuels et les anciens alias des commandes de dépôt sont reconnus. CMSL n’est pas installé sur les PC déployés.

L’agent appelle Initialize-HPRepository, active OfflineCacheMode, applique les filtres de plateforme / Windows, puis Invoke-HPRepositorySync et le nettoyage des paquets obsolètes de la copie de travail. Il n’exécute aucun SoftPaq sur le serveur. Les EXE sont vérifiés par signature HP avant publication. Une copie de travail invalide est retiree pour permettre un nouveau téléchargement. Une version déjà publiée n’est jamais écrasée.

Dossiers sous `<data_dir>\hp-repository` :

| Dossier / fichier | Rôle |
| --- | --- |
| `work\PLATEFORME\win11-VERSION` | Dépôt CMSL de travail ; contenu réutilise lors des synchronisations |
| `snapshots\GUID.zip` | Copies publiées pour les postes, sans configuration privee CMSL ni journal SMTP |
| `worker.log` | Activité et erreurs de synchronisation ; rotation a 2 Mo |
| `setup.log` | Erreurs d’installation ou de chargement de CMSL |
| `worker-key` | Secret local de l’agent ; ne pas diffuser ni copier sur un poste |

Les plateformes déjà rencontrees sont resynchronisees quotidiennement lorsque l’agent et Internet sont disponibles. Dans Vue d’ensemble, ouvrir **Pilotes HP partagés** pour voir l’état et demander une actualisation. Cela ne rétablit pas les anciennes pages Logiciels / Bundles ou Infrastructure PXE.

Trois versions publiées sont conservées par plateforme / Windows. Une archive transmise à un poste est protégée pendant deux heures, au-dela de la copie client limitée a quinze minutes. Les archives plus anciennes non utilisées sont supprimées après une publication. Les versions précédentes restent disponibles si une nouvelle synchronisation échoue. La copie de travail conserve les paquets courants ; les anciens snapshots ont leur propre conservation.

Une archive est limitée a 20 Go et 5000 fichiers. La préparation est reportée si le serveur dispose de moins de 4 Go libres ; la publication reserve la place d’une copie supplémentaire et 2 Go de marge. L’agent surveille également l’espace pendant le téléchargement. Sur le poste, la place nécessaire à l’archive et a son extraction est contrôlée ; un manque de place provoque le repli direct avant l’installation. Le transfert HTTPS refuse les redirections, les tailles / empreintes différentes et une absence de données de 30 secondes. Une copie complète est limitée a quinze minutes.

### Silence, progression et rapports

HPIA utilise `/Silent`, sans `/Noninteractive` qui demande une barre HP. L’interface IQ reste le suivi visible. Elle affiche l’analyse, l’attente du dépôt, les Mo copies, l’installation puis, si le journal le permet, le dernier SoftPaq mentionne. Ce n’est pas un pourcentage inventé de progression d’un firmware.

`/AutoReport` est activé. Le CSV natif récent est récupéré depuis son emplacement HP par défaut et conserve avec les rapports du traitement. Les paquets déclarés non automatisables sont signales À vérifier ; les codes HP 3011 / 3020 et le besoin de redémarrage restent visibles. Un code de redémarrage sur un pilote ordinaire reste manuel. Pour un paquet BIOS identifié explicitement, les nouveaux déploiements peuvent redémarrer et reprendre automatiquement. Le mode silencieux ne garantit pas le comportement natif de tous les installateurs BIOS / firmwares ; vérifier sur le modèle réel, notamment si le BIOS est protégé.

### Redémarrage BIOS et reprise

Pour les nouveaux déploiements IQ-4.9, `allow_bios_restart` est activé dans le contenu prépare par WinPE. Avant chaque lancement HPIA, Atelier écrit un point de reprise de manière atomique, vérifie ses octets et forcé son écriture sur disque. Il contient le démarrage Windows, le passage, la phase et le processus HP. Les logiciels WinGet sont déjà terminés avant ce traitement ; ils ne sont pas relancés par la reprise HP.

Un SoftPaq identifie BIOS avec un code 3010 ou 1641 place la préparation en **Redémarrage en attente**. Atelier demande un redémarrage Windows dans 60 secondes, avec un message visible. La demande est enregistrée avant la commande et n’est emise qu’une fois pour ce passage / démarrage. Un échec de la commande reste indiqué ; un redémarrage manuel permet aussi la reprise. Un besoin de redémarrage dont le paquet BIOS ne peut pas être établi reste manuel. Un firmware HP peut aussi redémarrer nativement avant le retour de HPIA.

La tâche SYSTEM `AtelierPXE-Maintenance` conserve son déclencheur au démarrage, sans ouverture de session. Quand le démarrage Windows a change, elle reprend par une nouvelle analyse du vrai matériel et installe ce que HP recommande encore. Elle ne tente pas de reprendre un flash au milieu de son exécution. Les rapports de chaque passage sont isolés dans `Passage-01`, `Passage-02`, etc. L’historique avant redémarrage reste dans le PDF / JSON et dans Rapports-HP.zip.

Pendant le même démarrage, une exécution active ou interrompue n’est jamais lancée une deuxième fois. Aucun processus de flash n’est tué au dépassement du délai. La préparation reste en attente de vérification / redémarrage. Une date de démarrage absente interdit la reprise automatique. Trois reprises après redémarrage sont autorisées au maximum ; au-dela, le résultat reste À vérifier et aucune nouvelle installation n’est lancée. Le cache privé et les tâches ne sont pas supprimés pendant un cycle BIOS.

Le redémarrage et les API Windows sont simulés dans les tests ici. Une recette sur un HP réel avec alimentation secteur et Windows PowerShell 5.1 reste nécessaire pour valider les particularites de son BIOS, son éventuel mot de passe et ses installateurs. Lenovo System Update garde son fonctionnement existant, sans automatisation de ses firmwares.

Les rapports HTML/XML/JSON, CSV et journaux du traitement courant sont transmis sous **Rapports-HP.zip**, dans le même dossier serveur que les XML/CSV et Diagnostics-Deploiement.zip. Ils sont telechargeables depuis **Dossier inventaire** ou la fiche du poste. Le PDF indiqué la source : dépôt local .250 ou serveurs HP par Internet.

Les rapports HP sont envoyés avant la confirmation finale du rapport, même si un redémarrage manuel reste nécessaire. Une erreur de transmission conserve le cache et le jeton de reprise. Le nettoyage des nouveaux postes ayant HPIA sélectionné exige aussi la preuve de réception des rapports HP. Les rapports locaux dans IQ_ et l’exécutable HPIA installé restent disponibles ; le dépôt local temporaire et ses ZIP sont retirés avec ProgramData/AtelierPXE une fois les confirmations obtenues.

L’archive HP est limitée a 32 Mo compressee / 128 Mo de texte et 1024 fichiers, 16 Mo par fichier. Les fichiers de configuration privés, exécutables, liens et chemins dangereux sont exclus ou refusés. Les fichiers natifs partiels sont conservés comme pièces de diagnostic, sans évaluation serveur. Une archive hors limites est conservée localement et son envoi reste en attente.

### Validation et limites

Les tests de laboratoire couvrent la file d’attente, la publication, les signatures simulées, les références CMSL, le transport HTTPS réel avec autorité de test temporaire, les empreintes / redirections, le cache / repli, les rapports et le nettoyage. Ils n’exécutent aucun installateur HP réel et ne prouvent pas la compatibilité d’un modèle ou d’une version Windows.

La documentation CMSL annonce Windows 10/11 et PowerShell 64 bits ; le fonctionnement de ses fonctions de dépôt sur DEPLOY-01 / Windows Server 2025 reste à confirmer sur cette VM. Un échec de chargement est visible dans le suivi du dépôt et setup.log, avec repli direct HPIA. Ne pas présenter ce cas comme un cache prêt.

Pour la recette, effectuer un déploiement HP avec le nouveau WinPE, vérifier le résultat des SoftPaq et les archivés sur .250, puis tester un deuxième poste compatible utilisant le dépôt. Vérifier aussi un HP sans HPIA coche et le bundle Lenovo. Une VM ne valide pas les pilotes et BIOS d’un vrai HP. Windows Update et Microsoft Store restent manuels.

Sources officielles : [guide HPIA](https://ftp.ext.hp.com/pub/caps-softpaq/cmit/whitepapers/HPIAUserGuide.pdf), [filtres CMSL](https://developers.hp.com/hp-client-management/doc/add-repositoryfilter), [synchronisation](https://developers.hp.com/hp-client-management/doc/invoke-repositorysync), [configuration hors ligne](https://developers.hp.com/hp-client-management/doc/set-hprepositoryconfiguration), [HPCMSL sur PSGallery](https://www.powershellgallery.com/packages/HPCMSL/1.9.0).

## Stabilisation HP / AnyDesk IQ-4.8.1

Le signalement du poste concerne bien WinPE IQ-4.8. Les journaux de ce nouveau déploiement ne sont pas encore disponibles ici : les défauts ci-dessous sont confirmés dans le code et le manifeste, mais leur rôle exact sur ce poste reste à confirmer avec Diagnostics-Deploiement.zip depuis Dossier inventaire.

Le manifeste WinGet HP.ImageAssistant 5.3.6 déclare `/s /f C:\SWSetup\HPImageAssistant` dans ses arguments silencieux, puis un autre `/f` avec `--location`. IQ remplace maintenant la chaîne d’extraction par une seule valeur fixe `/s /e /f "<dossier approuve>"`, transmise comme un argument natif unique. Le transport WinGet et ses contrôles de téléchargement sont conservés ; aucune URL ou commande libre ne vient du site. Aucun succès sans exécutable signe HP dans `%ProgramFiles%\AtelierPXE\Tools\HPImageAssistant`.

HPIA est portable : il n’ajoute pas lui-même d’entrée aux applications installées ou de raccourci. Si sa case est cochée et son exécutable vérifie, `C:\IQ_\Constructeur\HP-ImageAssistant.cmd` permet de l’ouvrir manuellement avec élévation. Ce lanceur survit à la suppression du cache de préparation. La présence de l’outil et le résultat de l’analyse / installation des SoftPaq restent deux résultats distincts.

AnyDesk est contrôlé par son exécutable signe AnyDesk Software GmbH (ou philandro Software GmbH) et une entrée de désinstallation ou un service Windows dont le chemin correspond à l’exécutable. L’absence du champ Publisher/InstallLocation ne suffit plus a rejeter le produit officiel. Les chemins x86/x64, DisplayIcon et UninstallString sont traités ; aucune commande du registre n’est exécutée. Un fichier portable seul, un registre seul ou une signature invalide ne suffisent pas. Le journal précise les preuves disponibles et l’état de signature.

Après chaque installation, quatre contrôles espaces de 500 ms au maximum attendent un enregistrement Windows tardif. Un code WinGet non nul est conservé mais ne déclare plus absent un produit dont la présence est vérifiée. Aucun installateur concurrent n’est ajouté. Les codes HP reseau/TLS, référence Windows générique et paquet non automatisable ont des messages explicites ; 257 reste À vérifier.

Le correctif s’applique aux prochains déploiements avec le nouveau WinPE IQ-4.8.1. Il ne met pas à jour à distance les scripts d’un poste déjà terminé. Windows Update / Store restent manuels et Atelier ne commande aucun redémarrage. Les tests ici simulent les API Windows et les installateurs : la validation de production exige encore un déploiement sous Windows PowerShell 5.1 sur HP réel, puis Lenovo et VM. Sur le site, récupérer le rapport et Diagnostics-Deploiement.zip pour constater chaque présence, le résultat HP, les archives et le nettoyage après redémarrage manuel si nécessaire.

### Évolution HP recommandée, non activée par ce correctif

CMSL est une bibliothèque PowerShell HP : elle peut récupérer des SoftPaq et maintenir un dépôt par plateforme / version de Windows. Sur .250, un dépôt local et des packs INF par plateforme eviteraient de télécharger les mêmes pilotes sur chaque PC. Les pilotes réseau / stockage pour WinPE doivent rester séparés des packs Windows complets. En IQ-4.8.1, ce dépôt CMSL et l’injection automatique des packs par plateforme n’étaient pas implementes. IQ-4.9 ajoute le dépôt pour HPIA dans Windows ; l’injection de packs INF pendant l’application du WIM reste distincte.

Dans ce projet, adapter ce mécanisme au déploiement DISM existant, plutôt que copier les réglages MDT Out-of-Box Drivers ou CustomSettings.ini de la pièce jointe. Garder HPIA dans Windows pour compléter les SoftPaq compatibles, depuis Internet ou, après integration/test, le dépôt CMSL en mode hors ligne. Les outils ConfigMgr / Intune de HP ne sont pas nécessaires pour cette architecture.

La pièce jointe donne la bonne direction, mais sa commande Category:Drivers,Software,Firmware omet le BIOS et sa proposition de redémarrage automatique ne correspondait pas à la procédure IQ-4.8.1. IQ-4.9 ajoute maintenant une reprise contrôlée après redémarrage BIOS. Les paquets non automatisables ne doivent pas être annonces installés. La version de Windows doit figurer dans les références HP ; afficher À vérifier si HPIA emploie une référence générique.

Sources officielles : [CMSL](https://developers.hp.com/hp-client-management/doc/client-management-script-library), [extraction HPIA](https://developers.hp.com/hp-client-management/doc/install-hpimageassistant), [packs par plateforme](https://developers.hp.com/hp-client-management/doc/new-hpdriverpack), [dépôts](https://developers.hp.com/hp-client-management/doc/initialize-hprepository), [guide HPIA](https://ftp.hp.com/pub/caps-softpaq/cmit/whitepapers/HPIAUserGuide.pdf), [CLI AnyDesk](https://support.anydesk.com/docs/command-line-interface-for-windows).

## Suppression du dossier de travail IQ-4.8

Les nouveaux déploiements ne conservent plus définitivement `C:\ProgramData\AtelierPXE`. Ce dossier reste nécessaire pendant la préparation. Après la fin des logiciels, le client transmet le rapport, les XML/CSV et une archive des journaux au serveur, puis demande une confirmation portant sur les empreintes SHA-256 des quatre envois. Le serveur vérifie aussi que les fichiers existent encore avec le bon contenu. Un ancien reçu, un fichier modifié ou un transfert incomplet ne permet pas la suppression.

Les journaux sont dans `Diagnostics-Deploiement.zip`, dans le même dossier serveur que les inventaires : `<data_dir>/inventaires/NOM-DU-PC/ID-DEPLOIEMENT`. Le bouton Dossier inventaire de la console permet de télécharger cette archive. Elle contient les résultats de préparation, les mesures et les derniers journaux de chaque logiciel, limites a 2000 lignes / 256 K caractères par journal. Les fichiers reporting.json, personalization.json, les réponses Windows, mots de passe et scripts ne sont pas archives. Le jeton de rapport est masque s’il apparaît dans un journal sélectionne.

Après confirmation, le nettoyage retire le dossier de travail (scripts, caches, téléchargements, jeton et états), les tâches Atelier et l’ancien payload de référence crée par ce déploiement. Les autres dossiers de ProgramData ne sont pas touches. Les liens et jonctions sont refusés. Un fichier encore ouvert bloque le nettoyage avant la suppression des tâches. Le nettoyage ne tue aucun installateur. Si un redémarrage est demandé, il attend le redémarrage manuel avant de supprimer les caches, notamment ceux du constructeur. Si le serveur est indisponible, les fichiers et la tâche de reprise sont conservés temporairement ; la tâche retente toutes les 15 minutes pendant la validité du jeton de rapport (14 jours). Un jeton expire ou une erreur persistante laisse la copie locale disponible pour diagnostic, sans la supprimer sans archive validée.

Les applications installées et `C:\IQ_` sont conservés. Le fond d’écran est utilisé depuis `IQ_/Personnalisation`, et le logo de progression ne garde plus le fichier source ouvert. Les outils son, webcam, clavier, batterie, licence et garantie restent autonomes. Après nettoyage, les raccourcis Generer-Rapport et Export-Inventaire ouvrent le rapport ou le dossier archivés sur le site, sans garder de jeton. Ils ne regenerent plus un inventaire du poste et n’envoient plus automatiquement de nouveaux tests : les tests et garanties realises ensuite restent locaux dans IQ_. Le PDF de déploiement local reste consultable.

Cette modification s’applique aux prochains déploiements utilisant le WinPE IQ-4.8 reconstruit par Upgrade-Atelier4.ps1 sur DEPLOY-01. Les postes déjà terminés ne sont pas modifiés à distance. Les tests verifient le protocole serveur et la suppression de vrais dossiers temporaires avec processus / redémarrage simulés ; la suppression native sous Windows reste à valider sur une machine de test.

## Correction du catalogue Windows PowerShell 5.1 IQ-4.7

Les fichiers du déploiement en échec ont confirmé quatre erreurs `Argument WinGet non autorise.` avec le même nom mélange `VLC Adobe Acrobat Reader Google Chrome AnyDesk`. WinGet n’avait pas lancé les installateurs. Ce diagnostic est distinct des problèmes de vérification ou de reprise traités en IQ-4.6 ; cette révision ne corrigeait pas le chargement du catalogue.

Windows PowerShell 5.1 transmet un tableau JSON racine comme un seul objet au pipeline. Entourer directement `Get-Content ... | ConvertFrom-Json` par `@(...)` ajoutait un niveau de tableau. Le filtre voyait alors les quatre logiciels comme une seule entrée ; les noms et identifiants WinGet étaient mélanges, puis refusés par le contrôle des arguments.

Le catalogue est maintenant affecte directement à une variable avant ajout des deux outils constructeur et filtrage par logiciel. Chaque invocation WinGet reçoit un seul identifiant. Les tableaux des outils HP et des anciens checkpoints utilisent la même correction. La validation des arguments est conservée. Des tests reproduisent la non-enumeration des tableaux racines de PowerShell 5.1, l’erreur précédente exacte, puis verifient les logiciels usuels, les bundles HP / Lenovo, les deux outils cochés ensemble et l’absence de sélection. Les installateurs et le matériel sont simulés ici ; le rendu et les installations réelles restent à valider sous Windows.

Appliquer cette révision sur DEPLOY-01 avec `scripts/Upgrade-Atelier4.ps1`, qui reconstruit et importe WinPE. Utiliser ensuite l’image nouvellement datee ; la fenêtre annonce IQ-4.7. Aucune commande de réparation sur le PC déployé n’est requise pour les prochains déploiements. Un PC déjà terminé avec les anciens scripts ne reçoit pas rétroactivement ce correctif.

Sur une VM, choisir le bundle HP permet de tester l’installation de HP Image Assistant via WinGet. L’analyse des SoftPaq reste soumise au matériel réel reconnu par HPIA. Changer le fabricant affiche par l’hyperviseur ne crée pas un modèle HP pris en charge et ne transforme pas les pilotes ou le firmware virtuels en matériel HP. Aucun contournement des contrôles de modèle et aucun flash de BIOS HP sur une VM ne sont ajoutés.

## Vérification des logiciels et reprise IQ-4.6

Un ancien résultat terminé pouvait court-circuiter toutes les installations du premier démarrage. Un checkpoint WinGet terminé était aussi réutilise sans vérifier la présence des logiciels habituels. Le code de sortie zéro du lanceur ne garantissait pas leur présence. Ces chemins sont corrigés ; les journaux du poste restent nécessaires pour confirmer la cause exacte d’un incident.

Après application du WIM, tout ancien dossier `ProgramData/AtelierPXE` est déplacé vers `AtelierPXE-Previous-<identifiant>` avant de créer le nouveau payload. Les états de l’ordinateur de référence ne sont plus repris. Le premier démarrage vérifie les choix actuels même si un ancien result.json indiqué termine.

Pour VLC, Reader, Chrome, AnyDesk et Lenovo System Update, un succès exige une entrée de désinstallation correspondant au produit et a son éditeur, plus un exécutable réel. HPIA garde son contrôle de fichier et de signature HP. Une application supprimée est réinstallée à la reprise ; un retour WinGet zéro sans preuve est un échec. Un logiciel déjà présent et vérifie est conservé. Le statut final affiche le nombre vérifie ou les logiciels manquants ; aucune sélection affiche explicitement qu’aucune installation n’est demandée. Le rapport et le site affichent À vérifier si un choix est absent ou non vérifié.

La préparation teste que WinGet exécute vraiment `--version`, puis essaie l’enregistrement App Installer et la réparation officielle si nécessaire. Un alias non exécutable ne suffit plus. Les erreurs de préparation sont conservées dans `C:\ProgramData\AtelierPXE\software-logs\winget-preparation.log` ; chaque logiciel a son propre fichier dans ce dossier. `personalization.json` contient les choix, `result.json` les résultats, et `first-logon.log` / `maintenance.log` les étapes. Ne pas publier reporting.json : il contient un jeton du poste.

Pour un PC déjà déployé, extraire la nouvelle archive puis exécuter `scripts/Repair-Software.ps1` en PowerShell administrateur sur ce PC. La réparation conserve la sélection enregistrée, sauvegarde les anciens fichiers dans `repair-backups/software-<identifiant>`, contrôle chaque logiciel et installe les manquants. Elle refuse une préparation ou un installateur encore actif. Elle met à jour le rapport et l’inventaire ; les échecs restent visibles. Le résultat HP durable est conservé pour éviter de relancer automatiquement un flash déjà traité. Aucun redémarrage n’est demandé par Atelier et aucune recherche Windows Update / Store n’est ajoutée.

Pour les prochains déploiements, exécuter `scripts/Upgrade-Atelier4.ps1` sur DEPLOY-01 afin de mettre à jour la console et reconstruire WinPE. L’assistant doit annoncer IQ-4.9. Les tests utilisent des installateurs et un registre simulés ; l’installation réelle WinGet / ADK reste à valider sous Windows.

## Bundles et choix des logiciels IQ-4.5

Dans Logiciels & bureau, la liste Bundle logiciels propose :

| Bundle | Logiciels cochés |
| --- | --- |
| Bundle HP | VLC, Adobe Reader, Google Chrome, AnyDesk, HP Image Assistant |
| Bundle Lenovo | VLC, Adobe Reader, Google Chrome, AnyDesk, Lenovo System Update |

Choisir un bundle remplit les cases et décoche l’autre outil constructeur. Vous pouvez ensuite cocher ou décocher chaque logiciel : le choix devient Personnalise. Les mêmes raccourcis existent dans la création d’un profil sur le site. Ils n’imposent pas un téléchargement depuis un ancien bundle serveur ; seule la liste finale des cases cochées est transmise au poste.

Sans bundle, les quatre logiciels usuels sont cochés par défaut dans un nouveau profil. Les deux outils constructeur restent décochés, sauf sélection déjà enregistrée dans le profil choisi. La détection HP ne rajoute plus HPIA automatiquement. Toutes les cases décochées signifie aucune installation WinGet ; la préparation terminée quand même les diagnostics et le rapport.

HP Image Assistant coché : installation du paquet `HP.ImageAssistant`, vérification de l’exécutable, puis traitement des SoftPaq compatibles sur un HP. HPIA décoche : aucune installation HPIA ni aucun traitement SoftPaq automatique, même si un outil ou un ancien résultat est déjà présent.

Lenovo System Update coche : installation silencieuse du paquet `Lenovo.SystemUpdate` après Windows, architecture x86 et scope machine d’après son manifeste officiel. Décoche : aucune installation Lenovo lancée. Cette révision installe l’outil Lenovo ; elle n’ajoute pas de commande automatique d’installation des pilotes Lenovo. Vous pouvez ouvrir System Update depuis Windows. Le redémarrage reste manuel et Windows Update / Microsoft Store restent manuels.

Référence Lenovo vérifiée : [manifeste Lenovo.SystemUpdate](https://github.com/microsoft/winget-pkgs/blob/16a1cf2cdb0ab480506cef361146633af6a7bfe4/manifests/l/Lenovo/SystemUpdate/5.08.04.85/Lenovo.SystemUpdate.installer.yaml). Les prochains postes installent la version proposee par la source WinGet, sans figer cette version.

Pour appliquer ces choix, mettre à jour le serveur et reconstruire WinPE avec la commande de mise à jour. La fenêtre de l’assistant doit annoncer IQ-4.9.

## Installation HPIA par WinGet et clavier fixe

La révision IQ-4.3 dependait d’un ZIP HPIA déjà enregistré sur le serveur. En son absence, la préparation signalait À vérifier mais ne pouvait pas installer HPIA. L’absence de fenêtre HPIA était normale en mode silencieux ; elle ne prouvait pas a elle seule une absence d’exécution.

Depuis IQ-4.5, HPIA est ajouté aux installations WinGet uniquement si sa case est cochée. La sélection de bundle HP coche cette case, mais vous pouvez la décocher avant installation. Aucun ZIP ni bundle HP du serveur n’est nécessaire. Le paquet officiel extrait HPIA ; il ne lance pas lui-même les mises à jour des pilotes. Atelier vérifie l’exécutable et sa signature HP, enregistre son empreinte puis lance l’analyse et l’installation des SoftPaq dans la finalisation SYSTEM. Le technicien choisit le logiciel constructeur adapte. Le traitement SoftPaq de HPIA reste réservé aux HP.

Le dossier demande a WinGet est `%ProgramFiles%\AtelierPXE\Tools\HPImageAssistant`, protége en écriture pour Administrateurs/SYSTEM. Le manifeste déclare une architecture x64 et des arguments d’extraction, sans scope : Atelier utilise `--location` et ne forcé pas `--scope machine` pour ce seul paquet. Si WinGet retourne un succès mais que l’exécutable est absent ou sa signature invalide, le rapport indiqué l’échec. La reprise d’une installation déjà vérifiée contrôle de nouveau le fichier ; un exécutable disparu déclenche sa réinstallation.

WinGet n’est pas pris en charge dans WinPE. Les scripts de préparation sont inclus dans WinPE puis copies dans Windows ; WinGet et HPIA sont exécutés après le premier démarrage Windows, dans leur contexte pris en charge. Le clavier WinPE est préparé hors ligne par DISM puis active au démarrage en `100c:0000100c` (français suisse / QWERTZ). Les sélecteurs de clavier de l’assistant et du menu de reprise sont retirés ; une ancienne configuration ou variable AZERTY/US ne remplace pas cette valeur.

Le manifeste WinGet a été vérifié dans [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs/blob/16a1cf2cdb0ab480506cef361146633af6a7bfe4/manifests/h/HP/ImageAssistant/5.3.6/HP.ImageAssistant.installer.yaml). Les prochains déploiements utilisent la version proposee par la source WinGet au moment de l’installation, sans figer HPIA en 5.3.6.

La commande HPIA utilise `/Operation:Analyze /Category:All /Selection:All /Action:Install /Silent /Noninteractive`, avec dossiers dedies `/ReportFolder` et `/SoftpaqDownloadFolder`. L’analyse recherche les recommandations du modèle et de la version Windows, puis les SoftPaq correspondants sont sélectionnés et traités. All couvre pilotes, logiciels, BIOS et firmwares recommandés compatibles. Cela ne forcé pas un paquet incompatible, ni un BIOS protégé par mot de passe. Les scripts Atelier ne demandent aucun redémarrage et n’ajoutent pas de paramètre de redémarrage. Le comportement interne de chaque SoftPaq reste celui de HP ; valider le parcours BIOS sur le modèle avant usage en série. Certains firmwares terminent leur installation au redémarrage manuel du technicien ; le flash peut ensuite déclencher ses propres cycles.

La progression affiche le traitement HP et sa durée réelle, sans inventer de pourcentage par paquet. Les codes retour HPIA et les résultats de remédiation des rapports JSON/XML sont conservés. Les rapports natifs sont dans `C:\IQ_\Rapports\HPImageAssistant`, les téléchargements dans `C:\ProgramData\AtelierPXE\HP-SoftPaqs`, et le résultat resumant l’exécution dans `C:\ProgramData\AtelierPXE\hpia-result.json`. Le PDF et la fiche du site reçoivent les états et erreurs SoftPaq disponibles.

Une passe HP au maximum est lancée automatiquement. Un résultat terminé est réutilisé pour les reprises de rapport. Une exécution interrompue ou dépassant 45 minutes est signalée À vérifier : aucun installateur ou flash n’est tué, et aucune seconde installation HP n’est lancée automatiquement. Vérifier les processus et le rapport HP avant une intervention manuelle ; garder le poste alimente pendant un flash. Le code 256 signifie aucune recommandation ; un modèle non pris en charge ou des SoftPaq en échec ne sont pas déclarés installés.

Référence des paramètres et limitations par version : [guide HP Image Assistant](https://ftp.ext.hp.com/pub/caps-softpaq/cmit/whitepapers/HPIAUserGuide.pdf). Les tests de cette révision simulent HPIA sous Linux et ne valident pas les flashs BIOS ou les paquets HP réels.

## Réparer un HP déjà déployé sans réinstaller Windows

Télécharger et extraire la nouvelle révision sur le PC HP, puis exécuter `scripts\Repair-HPIA.ps1` depuis Windows PowerShell administrateur. Ne pas exécuter cette réparation sur DEPLOY-01. La préparation initiale doit être terminée. Le script refuse une tâche Atelier ou un flash HP actif, sauvegarde les anciens résultats et les scripts remplacés sous `C:\ProgramData\AtelierPXE\repair-backups`, installe/verifie HPIA par WinGet puis reprend les SoftPaq. Les autres logiciels et leurs résultats sont conservés. L’ancien résultat HPIA est archive avant cette reprise manuelle explicite.

Le PDF et l’inventaire sont régénérés après les mises à jour HP, puis leur transmission est retentee avec l’identifiant du déploiement existant. Un jeton expire ou un réseau indisponible laisse les fichiers locaux et un envoi a reprendre. Aucun redémarrage n’est demandé par Atelier.

Pour comprendre une absence de HPIA : consulter `C:\ProgramData\AtelierPXE\hpia-result.json`, `result.json`, `first-logon.log` et `software-logs\hpia.log`. Le dernier fichier existe à partir de l’installation WinGet IQ-4.4. L’absence de fenêtre de HPIA est normale ; vérifier les fichiers et les rapports natifs.

## Ce qui change

- Le site contient Vue d’ensemble, Parc machines et Profils Windows. Les pages Infrastructure PXE et Logiciels & bundles sont retirées.
- WinPE crée automatiquement la demande du poste. Le choix de Windows Pro/Famille et la confirmation du disque restent sur le poste.
- Le premier démarrage enregistre une tâche de préparation puis rend la main à Windows. Les logiciels WinGet et les diagnostics tournent après l’ouverture du bureau. L’animation Windows de première connexion est désactivée ; les opérations natives obligatoires du premier démarrage doivent tout de même se terminer.
- La fenêtre de suivi est réductible. Aucune console PowerShell visible n’est nécessaire.
- Windows Update et Microsoft Store ne sont plus recherches ni actualises par la préparation, même si un ancien profil contient encore leurs options actives. Le rapport indiqué Manuel, jamais À jour sans vérification. Les services et politiques natifs Windows restent en place ; le technicien lance ses mises à jour depuis Paramètres et la bibliothèque Store.
- HP Image Assistant analyse le HP, sélectionne toutes les recommandations compatibles et installe les SoftPaq en arrière-plan. Le bureau reste disponible. L’ancienne ouverture automatique de sa fenêtre est retiree ; le raccourci manuel est conservé.
- Aucun redémarrage demande par Atelier. Les codes de redémarrage HPIA et SoftPaq sont remontes dans le suivi et le rapport. Une fois les installations terminées, le technicien redémarre manuellement. Les relancés de la tâche finale servent uniquement à transmettre le rapport.
- Un seul inventaire technique final est collecté après les logiciels et les mises à jour HP. Les reprises de transmission reutilisent les fichiers existants.
- Tous les textes sont en UTF-8 et conservent le français accentué. Les scripts PowerShell portent un BOM UTF-8 pour Windows PowerShell 5.1. Les identifiants techniques restent en ASCII. Un contrôle automatique refuse les tirets longs et les séquences mal décodées.

## Vérification de l’image et vitesse

Le SHA-256 complet du WIM reste calcule lors de son enregistrement sur le serveur. Le serveur refuse un fichier dont la taille ou la date ont change. WinPE ne relit plus la totalité du WIM pour recalculer son SHA-256 avant chaque installation : cela évite un parcours réseau de plusieurs gigaoctets avant DISM.

WinPE contrôle encore le fichier et sa taille, l’index, l’architecture x64, l’édition, la langue, le numéro de série, l’UEFI et le disque cible. Un verrou de lecture empêche la modification du WIM durant son utilisation. DISM conserve `/CheckIntegrity /Verify` pendant l’application.

**Limite :** ces contrôles ne prouvent plus à chaque déploiement que tous les octets correspondent à l’empreinte enregistrée. Une image alteree conservant sa taille/date pourrait passer le contrôle initial ; DISM ne remplace pas une comparaison cryptographique complète. Conserver les droits d’écriture du partage limites aux administrateurs et réenregistrer une image après tout remplacement. Le gain dépend de la taille du WIM, du disque et du réseau.

## Dossier IQ

| Dossier | Contenu |
| --- | --- |
| `C:\IQ_\Diagnostics` | Son, webcam, clavier, batterie et résultats |
| `C:\IQ_\Licence` | État de l’activation Windows |
| `C:\IQ_\Rapports` | Rapport-Deploiement.pdf, JSON, et Generer-Rapport.cmd |
| `C:\IQ_\Inventaire` | Export-Inventaire.cmd pour régénérer et transmettre XML/CSV |
| `C:\IQ_\Garantie` | Outil de vérification et dates confirmées sur le portail constructeur |
| `C:\IQ_\Personnalisation` | Fond d’écran |
| `C:\IQ_\Constructeur` | Lanceur HP-ImageAssistant.cmd si sélectionne et vérifie |

Les XML/CSV sont sur `.250` dans `<data_dir>\inventaires\NOM-DU-PC\ID-DEPLOIEMENT`. Dans Activité de déploiement, cliquer **Dossier inventaire** pour copier le chemin serveur ou télécharger les deux fichiers. Le PDF est également disponible sur la ligne du poste. Les anciens résultats connus sont déplacés dans leur catégorie lors de la préparation du dossier ; les fichiers inconnus sont conservés. L’organisation des machines déjà déployées ne change pas sans exécution des nouveaux scripts.

## Mettre à jour DEPLOY-01 (.250)

Exécuter la commande fournie dans la conversation dans **Windows PowerShell 5.1 administrateur sur DEPLOY-01**. Elle télécharge une révision précise et appelle `scripts\Upgrade-Atelier4.ps1`. Ne pas utiliser une archive de `main`, qui peut être plus ancienne.

Le script retrouve l’installation par sa tâche planifiée, sauvegarde code/configuration et SQLite, installe la révision 4, active le parcours automatique, synchronise les éditions du WIM, reconstruit WinPE avec le pilote Intel cible et les pilotes Microsoft ADK puis l’importe dans WDS sous **Atelier PXE - ATELIER-4 - date**. Les nouvelles dépendances graphiques et le lanceur en arrière-plan sont inclus dans le WIM. Un simple remplacement du site ne suffit pas.

Exemple avec chemins explicites, depuis la nouvelle archive extraite :

```powershell
& .\scripts\Upgrade-Atelier4.ps1 `
    -InstallPath 'C:\AtelierPXE\console' `
    -OutputRoot 'D:\AtelierPXE' `
    -TrustedRootCertificate 'C:\AtelierPXE\certs\AtelierPXE-lab.cer' `
    -DriversPath 'D:\AtelierPXE\Drivers\WinPE-x64'
```

L’archive ne fournit pas de WIM preconstruit : l’ADK, les pilotes et le certificat public du serveur sont utilisés pour le produire sur Windows. Ne pas interrompre le montage/enregistrement de DISM. Le chemin exact de `media\sources\boot.wim` est affiché à la fin. Les anciens WinPE sont refusés par la console avant tout effacement.

## Nettoyage du serveur

Après construction et import vérifiés de la nouvelle image, les anciennes images WDS **Atelier** et leurs anciens dossiers de construction WinPE sont supprimés. Les images MDT restent independantes.

Le nettoyage complémentaire traite uniquement les dossiers temporaires de mise à jour identifiables par leur nom et leur contenu (`Atelier-2/3/4-<guid>`, `Maj-Atelier2/3/4-<guid>`), ainsi que les anciennes sauvegardes identifiées. Il conserve au moins les trois sauvegardes les plus récentes par dossier de sauvegardes, les dossiers de moins d’une heure, les chemins actifs/protégés et les dossiers contenant des liens. L’installation courante, ses données, la nouvelle image, les pilotes, certificats et contenus inconnus sont conservés. Les fichiers de logiciels historiques encore références dans la base ne sont pas supprimés automatiquement. Journal : `<data_dir>\cleanup\nettoyage-date.json`.

Pour voir la sélection avant un nettoyage manuel, fournir le vrai dossier d’installation :

```powershell
& 'C:\AtelierPXE\console\scripts\Clear-AtelierObsolete.ps1' `
    -InstallPath 'C:\AtelierPXE\console' -WhatIf
```

`-WhatIf` ne supprime rien et n’écrit aucun journal. La mise à jour complète effectue déjà le nettoyage après ses contrôles.

## Vérifier après mise à jour

1. Recharger le site avec Ctrl+F5 : logo IQ, thème bleu/lilas, trois pages.
2. Démarrer un poste de test UEFI sur ATELIER-4 ; choisir édition, nom et disque puis confirmer.
3. Retirer le démarrage PXE prioritaire après application : démarrer sur le disque Windows.
4. Vérifier l’arrivée au bureau et la progression réductible pendant WinGet.
5. Vérifier `C:\IQ_\Rapports\Rapport-Deploiement.pdf`, les catégories IQ et les XML/CSV sur .250.
6. Vérifier le résultat HP Image Assistant, les SoftPaq et un éventuel redémarrage manuel. Windows Update et Microsoft Store doivent être marques Manuel dans le rapport.

Journaux Windows : `C:\ProgramData\AtelierPXE\first-logon.log`, `maintenance.log`, `progress.json`, `reporting.log`, `software-logs`. Journaux du serveur : `<data_dir>\logs\console.log`. Le démarrage rapide Windows reste désactivé à chaque déploiement ; le Fast Boot du BIOS est un réglage distinct.

## Pistes utiles pour la suite

- Actualiser régulièrement le WIM Windows avec les mises à jour déjà intégrées : cela réduit le travail à effectuer sur chaque poste, sans supprimer les correctifs de sécurité.
- Préparer un cache local des pilotes par modèle, avec validation et date de version, pour raccourcir les passages HP Image Assistant et Lenovo.
- Ajouter un état Prêt pour remise qui exige rapport disponible, activation vérifiée et tests matériels validés, avec les points restants visibles.

Les tests automatises utilisent des images et services simulés. Un déploiement réel, les pilotes et l’OOBE doivent être vérifiés sur un poste Windows de laboratoire.

## Comment préparer un WIM Windows à jour

Cette procédure est une proposition de maintenance. La mise à jour IQ-4.2 ne modifie pas votre WIM Windows et ne programme pas de maintenance automatique des images.

Le principe est d’installer une fois les correctifs dans une copie de l’image, sur .250, au lieu de les réinstaller sur chaque ordinateur. Prévoir de l’espace pour la copie, le montage et les fichiers temporaires. Les opérations DISM se font sur Windows avec les outils compatibles avec la version cible.

1. Conserver le WIM actuel pour le retour arrière. Créer une copie avec un nouveau nom, par exemple `Windows11-2026-10.wim`. Ne jamais monter en écriture une image en cours de déploiement.
2. Relever les index Pro et Famille avec DISM /Get-WimInfo, ainsi que la version, l’architecture et les langues. Télécharger depuis le Catalogue Microsoft Update les paquets officiels correspondants ; vérifier leurs prérequis. Selon la version, des mises à jour de pile de maintenance ou des mises à jour cumulatives de point de contrôle doivent être ajoutées dans un ordre précis.
3. Monter chaque index utilise dans un dossier vide, ajouter les paquets avec DISM /Add-Package, puis enregistrer avec /Unmount-Image /Commit. Traiter Pro et Famille : actualiser seulement un index ne met pas les autres à jour. Ne pas utiliser /ResetBase pour cette première procédure, afin de conserver les possibilités de retrait de correctifs.
4. Tester les deux éditions sur un poste de laboratoire : démarrage UEFI, édition et activation, réseau, pilotes, WinGet et rapport. Vérifier aussi les correctifs restants dans Windows Update. Certaines mises à jour, les applications Store et les pilotes restent propres à chaque ordinateur.
5. Enregistrer le nouveau WIM sous son nouveau nom dans Atelier, puis créer les profils pointant vers les bons index. Conserver les anciens profils jusqu’à validation et choisir les nouveaux pour les prochains déploiements. Ne pas simplement remplacer les octets du fichier déjà référence : le contrôle de taille/date et l’empreinte enregistrée doivent correspondre au nouveau fichier.

On peut renouveler cette préparation chaque mois après validation des correctifs. L’objectif est de réduire fortement le téléchargement et l’installation répétés ; une courte vérification Windows Update reste utile pour les correctifs parus après la fabrication de l’image. La reconstruction de WinPE concerne l’assistant de déploiement : elle ne met pas à jour Windows dans le WIM d’installation.
