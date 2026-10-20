# IQ Atelier 4 - bureau disponible et preparation en arriere-plan

Cette version unifie le site, WinPE et le suivi Windows en bleu/lilas. Le logo fourni a ete adapte sur fond transparent. Pour utiliser le PNG original sans adaptation, passer `-BrandLogoPath C:\chemin\logo.png` au script de mise a jour.

## Diagnostic du bouton Connexion IQ-5.0.1

Cette correction concerne toutes les marques. Elle ne change ni les pilotes ni la configuration reseau. Le bouton distingue la connexion a l API Atelier, la recuperation des acces au partage, l ouverture du partage des images et le chargement des profils. Une erreur pendant la connexion ouvre une boite de dialogue complete, avec l etape, l adresse du serveur, le code HTTP / transport disponible et le message Windows. Elle ne reste plus tronquee dans la bande d etat de 32 pixels.

Un echec HTTPS ne declenche plus une nouvelle lecture WMI et n est plus presente automatiquement comme un inventaire reseau incomplet. Les erreurs TLS, DNS, delai et connexion sont distinguees quand Windows les expose. La lecture des acces au partage utilise aussi un delai de 20 secondes. Les informations affichees servent a identifier la cause sur le poste ; cette revision ne pretend pas reparer une cause reseau ou certificat encore inconnue.

Mettre a jour et reconstruire avec Upgrade-Atelier4.ps1, puis demarrer sur le nouveau WinPE qui affiche IQ-5.0.1. En cas d echec, la photo de la boite Connexion Atelier - erreur complete suffit pour transmettre le diagnostic, sans commande PowerShell sur le poste. Les tests executent le vrai parcours Connect-Post avec API et partage simules, ainsi que les classifications d exceptions Windows ; le rendu WinForms et la connexion au serveur physique restent a verifier sous Windows.

## Identification par numero de serie IQ-5.0

Les nouveaux WinPE identifient le PC par son numero de serie SMBIOS, lu dans Win32_BIOS puis, si necessaire, Win32_ComputerSystemProduct. La valeur est normalisee en majuscules, sans espaces superflus. Un SN absent, generique ou invalide est refuse ; aucun identifiant MAC ou nom invente ne le remplace dans le nouvel assistant. Le nom Windows propose reste les quatre derniers chiffres du SN, a completer comme auparavant.

La MAC est seulement une observation reseau. Une liste de MAC vide ne bloque plus la connexion au serveur : l assistant envoie le SN et tente directement HTTPS. Les observations reseau sont relues au clic Connexion, avec des lectures WMI et .NET complementaires. Un inventaire WMI incomplet ne prouve pas une panne reseau. Cette revision n ajoute aucun pilote reseau.

Le meme SN retrouve la meme fiche, meme avec un autre dock ou aucune MAC visible. Deux SN differents peuvent partager la MAC d un dock sans partager leur autorisation ni leur historique. Le plan inclut le SN attendu et l agent relit le SN materiel avant de reserver le deploiement puis de nouveau avant l effacement. Les controles du disque, de l UEFI et de l image restent actifs. Le SN est un controle de cible et de suivi, pas une preuve cryptographique ; il doit etre reel et unique sur les PC de l atelier.

Le site affiche le SN dans Parc machines, Activite et la fiche ordinateur. L enregistrement manuel demande le SN ; la MAC est facultative. Les nouvelles preparations indiquent IQ-5.0 et le SN WinPE dans leur rapport. Le fonctionnement HP/CMSL, les logiciels et la reprise BIOS restent ceux de la revision precedente.

La migration SQLite conserve les IDs des machines, deploiements, rapports, fichiers et notes. L ancienne contrainte MAC unique est conservee dans une colonne technique privee, tandis que la MAC observee peut desormais etre partagee. La migration du schema et le rapprochement initial sont transactionnels. Un SN historique est repris automatiquement seulement s il identifie une seule fiche sans historique melange. Une ancienne fiche de dock contenant plusieurs SN reste intacte ; les prochains deploiements utilisent une nouvelle fiche par PC. Plusieurs anciennes fiches portant le meme SN exigent un rapprochement manuel ; aucune fusion destructive n est faite.

Les anciens clients MAC restent compatibles avec leurs fiches sans SN. Ils ne peuvent pas prendre une fiche deja identifiee par SN en reutilisant la MAC du dock. Pour supprimer le blocage Aucune MAC detectee, mettre le serveur a jour et reconstruire WinPE avec Upgrade-Atelier4.ps1 ; le titre de l assistant et /health doivent annoncer IQ-5.0. L image WDS garde le nom de famille ATELIER-4 suivi de sa date de construction.

Les tests couvrent le meme PC avec plusieurs docks, plusieurs PC sur un dock, une liste de MAC vide, les SN generiques, les codes reserves a un autre PC, la rotation des jetons, les controles avant effacement et la migration d une ancienne base a deux reprises. Les tests de laboratoire n executent aucun effacement reel ni aucun deploiement Windows physique.

## Correctif graphique IQ-4.1

Le logo est limite a 40 x 40 pixels et place en haut a droite sur le site, WinPE et le suivi Windows. Le site lui donne aussi des dimensions HTML : une feuille de style absente ou ancienne ne peut plus afficher le PNG a sa taille d origine.

La feuille de style utilise un seul theme : fond clair, cartes blanches, texte bleu nuit, boutons bleus et degrade bleu `#D2E4F1` / lilas `#E9D9EA`. Les anciennes regles vert fonce ont ete retirees.

Chaque adresse CSS, JavaScript et logo contient une empreinte de son contenu. Les pages et ressources du site portent `Cache-Control: no-store`, pour eviter le melange nouveau HTML / ancien CSS lors d une mise a jour. `/health` confirme maintenant `ui_revision: IQ-5.0` ; la mise a jour controle ce marqueur avant de valider le demarrage.

Apres la mise a jour, ouvrir `https://192.168.99.250/?theme=IQ-5.0`. Pour WinPE et la preparation des prochains postes, utiliser l image reconstruite par le script de mise a jour. Les tests navigateur reproduisent le logo geant avec l ancien CSS puis verifient la correction sur ecran 1440, 1920 et mobile 390 pixels. Le rendu WinForms reste a valider sur Windows.

## Assistant et fiche ordinateur IQ-4.2

Les polices WinForms utilisent un constructeur explicitement type : cela evite une interpretation de la taille comme un style italique. Le titre est moins grand, sa description peut revenir a la ligne et la liste Windows ne repete plus les informations du profil. Les reponses JSON annoncent explicitement UTF-8 pour Windows PowerShell 5.1. Les donnees existantes sont conservees : un nom deja enregistre avec des caracteres incorrects doit etre corrige dans sa source.

Le nom propose dans WinPE est uniquement constitue des quatre derniers chiffres du SN, en conservant les zeros initiaux. Aucun prefixe ni nom de remplacement n est ajoute. Si le SN est absent, generique ou contient moins de quatre chiffres, le champ reste vide. **Completer le nom avant de continuer**, par exemple `8323` devient `ATELIER-8323` : le nom Windows valide doit commencer par une lettre et contenir au maximum 15 lettres, chiffres ou tirets. Le champ Prefixe et le bouton Recalculer sont retires.

La region et les formats sont proposes en `fr-CH`. Cela ne change pas la langue du WIM. Depuis IQ-4.4, WinPE impose le clavier francais suisse ; l assistant utilise aussi cette disposition pour le Windows deploye, sans selecteur de clavier. Proprietaire et organisation ne sont plus demandes. Le fond `Fond Atelier.png` ou `fon atelier.png` est selectionne par defaut quand il est disponible. La mise a jour enregistre ce fichier si elle le trouve dans `<data_dir>\artifacts` ; sinon elle affiche un avertissement. Elle ne cree pas de faux fond d ecran. Pour l ajouter ensuite : copier le PNG dans ce dossier, puis Profils Windows, Enregistrer un fichier, type Fond d ecran.

Dans Activite de deploiement, cliquer **Fiche ordinateur**, ou cliquer le nom dans **Parc machines**. La fiche regroupe identite materielle, licence, historique pagine, PDF, XML/CSV, tests, garantie connue et observations datees du technicien. Les observations sont conservees sur le serveur, independamment des rapports. Les tests et la garantie apparaissent apres utilisation de leurs outils et regeneration du rapport ; aucun resultat n est invente.

Chaque nouveau deploiement mesure l application DISM du WIM, les logiciels WinGet, la preparation de l outil constructeur, les mises a jour HP et la collecte XML/CSV. Ces mesures apparaissent dans la fiche et les nouveaux rapports PDF. Les anciennes mesures Windows Update restent visibles dans l historique. Les durees sont mesurees par chronometre dans le processus ; elles n incluent pas les periodes hors tension ni les attentes entre redemarrages. Une fin de mesure non recue reste signalee et les anciens deploiements n obtiennent pas de durees reconstituees. Les transmissions reutilisent les memes identifiants de mesure pour eviter les doublons.

Depuis IQ-5.0, la fiche utilise le numero de serie comme identite du poste. La MAC observee est informative ; les anciennes fiches sont conservees selon les regles de migration ci-dessus.

## Depot HP et execution silencieuse IQ-4.9

La case HP Image Assistant reste l unique declencheur sur le poste. Sans cette case, aucune installation HPIA, aucune demande de depot ni execution SoftPaq. Les autres logiciels et Lenovo System Update gardent leurs selections WinGet.

Sur .250, `Upgrade-Atelier4.ps1` met la console a jour, appelle `Enable-HPRepository.ps1`, puis reconstruit et importe le nouveau WinPE. Le titre de l assistant et `/health` doivent annoncer IQ-5.0. Aucun script manuel n est necessaire sur les prochains postes deployes. Les postes deja termines ne recoivent pas retroactivement ces fichiers.

### Correctif d installation CMSL pour PowerShellGet ancien

Le journal `hp-repository\setup.log` peut indiquer : `Impossible de trouver un parametre correspondant au nom AcceptLicense`. La version initiale IQ-4.9 passait ce parametre a Install-Module sans verifier la version de PowerShellGet fournie avec Windows PowerShell 5.1. CMSL n etait donc pas installe, meme si la creation de la tache continuait ensuite.

Le correctif d `Enable-HPRepository.ps1` met PowerShellGet a niveau vers 2.2.5 pour tous les utilisateurs si necessaire, avec une commande compatible avec l ancienne version. Il installe ensuite HPCMSL dans un nouveau processus Windows PowerShell, sans profil, afin de charger les nouvelles versions de PowerShellGet et PackageManagement. Aucun redemarrage Windows n est necessaire pour ce changement de session.

Le programme verifie le chargement de CMSL et ses cinq commandes de depot avant d annoncer leur disponibilite. Un echec affiche maintenant l etape, son message et le chemin complet du journal. L agent peut rester en attente et les postes conservent leur repli Internet ; la creation de la tache ne signifie plus que le depot est pret.

Pour une console deja mise a jour vers IQ-4.9, remplacer uniquement `scripts\Enable-HPRepository.ps1` dans le dossier de la console et le relancer en Windows PowerShell administrateur sur .250. Le script de localisation existant retrouve l installation par la tache AtelierPXE-Console. Il n est pas necessaire de reconstruire WinPE pour cette reparation serveur. La tache de depot deja active retente le chargement du module dans sa boucle habituelle.

### Parcours du poste

1. WinGet prepare l outil HPIA et verifie l executable signe HP, comme en IQ-4.8.1.
2. Dans Windows, HPIA lance une analyse `Action:List` sans interface. Les IDs des SoftPaq recommandes sont lus dans ses rapports ; les IDs des logiciels deja installes ne sont pas utilises pour demander des telechargements.
3. Atelier demande le depot correspondant au code de plateforme HP (quatre chiffres hexadecimaux), a Windows 10/11 et a sa version reelle lue dans le registre. Le nom libre du profil Windows n est pas une preuve de version.
4. Si le depot date de moins de 24 heures et contient les IDs recommandes, il est copie depuis .250 par HTTPS, controle par SHA-256 puis extrait dans le cache prive du poste.
5. HPIA analyse a nouveau le vrai materiel puis installe seulement les SoftPaq applicables, en utilisant `OfflineMode` avec cette copie CMSL. Aucun `/Force` n est utilise et aucun code constructeur n est transforme en succes artificiel.
6. Si le depot manque, est ancien ou incomplet, une synchronisation serveur est demandee. L attente de preparation est limitee a environ 90 secondes. Si l agent est indisponible, le repli est immediat. Le poste utilise alors HP directement ; le travail de preparation du cache peut continuer sur .250 pour les prochains postes.
7. Un code 256 apres l analyse signifie aucune recommandation : pas de copie du depot, pas de seconde passe d installation. Le serveur peut quand meme entretenir ses references en arriere-plan.

Le premier remplissage telecharge un ensemble coherent pour la plateforme / Windows, pas uniquement un fichier manquant. La copie locale du depot peut donc faire plusieurs Go, meme si un seul paquet doit etre installe. Les demandes identiques sont regroupees ; les paquets existants sont reutilises par CMSL. Une recommandation nouvelle absente du depot declenche une actualisation. Si une synchronisation terminee ne fournit toujours pas ce SoftPaq, la meme demande ne tourne pas en boucle : le poste utilise HP directement.

L installation n est lancee qu une fois par passage. Un echec apres son lancement ne provoque pas une seconde passe Internet pendant le meme demarrage, afin de ne pas repeter un BIOS / firmware. Un autre HPIA deja actif empeche de lancer un deuxieme traitement. Les nouveaux deploiements autorisent la reprise apres un vrai redemarrage Windows, decrite ci-dessous.

### Depot sur le serveur

La tache `AtelierPXE-HpRepository` fonctionne en SYSTEM, sans session administrateur ouverte. Elle utilise la bibliotheque officielle HPCMSL 1.9.0 (ou une version plus recente deja installee pour tous les utilisateurs). Le programme d activation l installe depuis PSGallery si necessaire. Les noms actuels et les anciens alias des commandes de depot sont reconnus. CMSL n est pas installe sur les PC deployes.

L agent appelle Initialize-HPRepository, active OfflineCacheMode, applique les filtres de plateforme / Windows, puis Invoke-HPRepositorySync et le nettoyage des paquets obsoletes de la copie de travail. Il n execute aucun SoftPaq sur le serveur. Les EXE sont verifies par signature HP avant publication. Une copie de travail invalide est retiree pour permettre un nouveau telechargement. Une version deja publiee n est jamais ecrasee.

Dossiers sous `<data_dir>\hp-repository` :

| Dossier / fichier | Role |
| --- | --- |
| `work\PLATEFORME\win11-VERSION` | Depot CMSL de travail ; contenu reutilise lors des synchronisations |
| `snapshots\GUID.zip` | Copies publiees pour les postes, sans configuration privee CMSL ni journal SMTP |
| `worker.log` | Activite et erreurs de synchronisation ; rotation a 2 Mo |
| `setup.log` | Erreurs d installation ou de chargement de CMSL |
| `worker-key` | Secret local de l agent ; ne pas diffuser ni copier sur un poste |

Les plateformes deja rencontrees sont resynchronisees quotidiennement lorsque l agent et Internet sont disponibles. Dans Vue d ensemble, ouvrir **Pilotes HP partages** pour voir l etat et demander une actualisation. Cela ne retablit pas les anciennes pages Logiciels / Bundles ou Infrastructure PXE.

Trois versions publiees sont conservees par plateforme / Windows. Une archive transmise a un poste est protegee pendant deux heures, au-dela de la copie client limitee a quinze minutes. Les archives plus anciennes non utilisees sont supprimees apres une publication. Les versions precedentes restent disponibles si une nouvelle synchronisation echoue. La copie de travail conserve les paquets courants ; les anciens snapshots ont leur propre conservation.

Une archive est limitee a 20 Go et 5000 fichiers. La preparation est reportee si le serveur dispose de moins de 4 Go libres ; la publication reserve la place d une copie supplementaire et 2 Go de marge. L agent surveille egalement l espace pendant le telechargement. Sur le poste, la place necessaire a l archive et a son extraction est controlee ; un manque de place provoque le repli direct avant l installation. Le transfert HTTPS refuse les redirections, les tailles / empreintes differentes et une absence de donnees de 30 secondes. Une copie complete est limitee a quinze minutes.

### Silence, progression et rapports

HPIA utilise `/Silent`, sans `/Noninteractive` qui demande une barre HP. L interface IQ reste le suivi visible. Elle affiche l analyse, l attente du depot, les Mo copies, l installation puis, si le journal le permet, le dernier SoftPaq mentionne. Ce n est pas un pourcentage invente de progression d un firmware.

`/AutoReport` est active. Le CSV natif recent est recupere depuis son emplacement HP par defaut et conserve avec les rapports du traitement. Les paquets declares non automatisables sont signales A verifier ; les codes HP 3011 / 3020 et le besoin de redemarrage restent visibles. Un code de redemarrage sur un pilote ordinaire reste manuel. Pour un paquet BIOS identifie explicitement, les nouveaux deploiements peuvent redemarrer et reprendre automatiquement. Le mode silencieux ne garantit pas le comportement natif de tous les installateurs BIOS / firmwares ; verifier sur le modele reel, notamment si le BIOS est protege.

### Redemarrage BIOS et reprise

Pour les nouveaux deploiements IQ-4.9, `allow_bios_restart` est active dans le contenu prepare par WinPE. Avant chaque lancement HPIA, Atelier ecrit un point de reprise de maniere atomique, verifie ses octets et force son ecriture sur disque. Il contient le demarrage Windows, le passage, la phase et le processus HP. Les logiciels WinGet sont deja termines avant ce traitement ; ils ne sont pas relances par la reprise HP.

Un SoftPaq identifie BIOS avec un code 3010 ou 1641 place la preparation en **Redemarrage en attente**. Atelier demande un redemarrage Windows dans 60 secondes, avec un message visible. La demande est enregistree avant la commande et n est emise qu une fois pour ce passage / demarrage. Un echec de la commande reste indique ; un redemarrage manuel permet aussi la reprise. Un besoin de redemarrage dont le paquet BIOS ne peut pas etre etabli reste manuel. Un firmware HP peut aussi redemarrer nativement avant le retour de HPIA.

La tache SYSTEM `AtelierPXE-Maintenance` conserve son declencheur au demarrage, sans ouverture de session. Quand le demarrage Windows a change, elle reprend par une nouvelle analyse du vrai materiel et installe ce que HP recommande encore. Elle ne tente pas de reprendre un flash au milieu de son execution. Les rapports de chaque passage sont isoles dans `Passage-01`, `Passage-02`, etc. L historique avant redemarrage reste dans le PDF / JSON et dans Rapports-HP.zip.

Pendant le meme demarrage, une execution active ou interrompue n est jamais lancee une deuxieme fois. Aucun processus de flash n est tue au depassement du delai. La preparation reste en attente de verification / redemarrage. Une date de demarrage absente interdit la reprise automatique. Trois reprises apres redemarrage sont autorisees au maximum ; au-dela, le resultat reste A verifier et aucune nouvelle installation n est lancee. Le cache prive et les taches ne sont pas supprimes pendant un cycle BIOS.

Le redemarrage et les API Windows sont simules dans les tests ici. Une recette sur un HP reel avec alimentation secteur et Windows PowerShell 5.1 reste necessaire pour valider les particularites de son BIOS, son eventuel mot de passe et ses installateurs. Lenovo System Update garde son fonctionnement existant, sans automatisation de ses firmwares.

Les rapports HTML/XML/JSON, CSV et journaux du traitement courant sont transmis sous **Rapports-HP.zip**, dans le meme dossier serveur que les XML/CSV et Diagnostics-Deploiement.zip. Ils sont telechargeables depuis **Dossier inventaire** ou la fiche du poste. Le PDF indique la source : depot local .250 ou serveurs HP par Internet.

Les rapports HP sont envoyes avant la confirmation finale du rapport, meme si un redemarrage manuel reste necessaire. Une erreur de transmission conserve le cache et le jeton de reprise. Le nettoyage des nouveaux postes ayant HPIA selectionne exige aussi la preuve de reception des rapports HP. Les rapports locaux dans IQ_ et l executable HPIA installe restent disponibles ; le depot local temporaire et ses ZIP sont retires avec ProgramData/AtelierPXE une fois les confirmations obtenues.

L archive HP est limitee a 32 Mo compressee / 128 Mo de texte et 1024 fichiers, 16 Mo par fichier. Les fichiers de configuration prives, executables, liens et chemins dangereux sont exclus ou refuses. Les fichiers natifs partiels sont conserves comme pieces de diagnostic, sans evaluation serveur. Une archive hors limites est conservee localement et son envoi reste en attente.

### Validation et limites

Les tests de laboratoire couvrent la file d attente, la publication, les signatures simulees, les references CMSL, le transport HTTPS reel avec autorite de test temporaire, les empreintes / redirections, le cache / repli, les rapports et le nettoyage. Ils n executent aucun installateur HP reel et ne prouvent pas la compatibilite d un modele ou d une version Windows.

La documentation CMSL annonce Windows 10/11 et PowerShell 64 bits ; le fonctionnement de ses fonctions de depot sur DEPLOY-01 / Windows Server 2025 reste a confirmer sur cette VM. Un echec de chargement est visible dans le suivi du depot et setup.log, avec repli direct HPIA. Ne pas presenter ce cas comme un cache pret.

Pour la recette, effectuer un deploiement HP avec le nouveau WinPE, verifier le resultat des SoftPaq et les archives sur .250, puis tester un deuxieme poste compatible utilisant le depot. Verifier aussi un HP sans HPIA coche et le bundle Lenovo. Une VM ne valide pas les pilotes et BIOS d un vrai HP. Windows Update et Microsoft Store restent manuels.

Sources officielles : [guide HPIA](https://ftp.ext.hp.com/pub/caps-softpaq/cmit/whitepapers/HPIAUserGuide.pdf), [filtres CMSL](https://developers.hp.com/hp-client-management/doc/add-repositoryfilter), [synchronisation](https://developers.hp.com/hp-client-management/doc/invoke-repositorysync), [configuration hors ligne](https://developers.hp.com/hp-client-management/doc/set-hprepositoryconfiguration), [HPCMSL sur PSGallery](https://www.powershellgallery.com/packages/HPCMSL/1.9.0).

## Stabilisation HP / AnyDesk IQ-4.8.1

Le signalement du poste concerne bien WinPE IQ-4.8. Les journaux de ce nouveau deploiement ne sont pas encore disponibles ici : les defauts ci-dessous sont confirmes dans le code et le manifeste, mais leur role exact sur ce poste reste a confirmer avec Diagnostics-Deploiement.zip depuis Dossier inventaire.

Le manifeste WinGet HP.ImageAssistant 5.3.6 declare `/s /f C:\SWSetup\HPImageAssistant` dans ses arguments silencieux, puis un autre `/f` avec `--location`. IQ remplace maintenant la chaine d extraction par une seule valeur fixe `/s /e /f "<dossier approuve>"`, transmise comme un argument natif unique. Le transport WinGet et ses controles de telechargement sont conserves ; aucune URL ou commande libre ne vient du site. Aucun succes sans executable signe HP dans `%ProgramFiles%\AtelierPXE\Tools\HPImageAssistant`.

HPIA est portable : il n ajoute pas lui-meme d entree aux applications installees ou de raccourci. Si sa case est cochee et son executable verifie, `C:\IQ_\Constructeur\HP-ImageAssistant.cmd` permet de l ouvrir manuellement avec elevation. Ce lanceur survit a la suppression du cache de preparation. La presence de l outil et le resultat de l analyse / installation des SoftPaq restent deux resultats distincts.

AnyDesk est controle par son executable signe AnyDesk Software GmbH (ou philandro Software GmbH) et une entree de desinstallation ou un service Windows dont le chemin correspond a l executable. L absence du champ Publisher/InstallLocation ne suffit plus a rejeter le produit officiel. Les chemins x86/x64, DisplayIcon et UninstallString sont traites ; aucune commande du registre n est executee. Un fichier portable seul, un registre seul ou une signature invalide ne suffisent pas. Le journal precise les preuves disponibles et l etat de signature.

Apres chaque installation, quatre controles espaces de 500 ms au maximum attendent un enregistrement Windows tardif. Un code WinGet non nul est conserve mais ne declare plus absent un produit dont la presence est verifiee. Aucun installateur concurrent n est ajoute. Les codes HP reseau/TLS, reference Windows generique et paquet non automatisable ont des messages explicites ; 257 reste A verifier.

Le correctif s applique aux prochains deploiements avec le nouveau WinPE IQ-4.8.1. Il ne met pas a jour a distance les scripts d un poste deja termine. Windows Update / Store restent manuels et Atelier ne commande aucun redemarrage. Les tests ici simulent les API Windows et les installateurs : la validation de production exige encore un deploiement sous Windows PowerShell 5.1 sur HP reel, puis Lenovo et VM. Sur le site, recuperer le rapport et Diagnostics-Deploiement.zip pour constater chaque presence, le resultat HP, les archives et le nettoyage apres redemarrage manuel si necessaire.

### Evolution HP recommandee, non activee par ce correctif

CMSL est une bibliotheque PowerShell HP : elle peut recuperer des SoftPaq et maintenir un depot par plateforme / version de Windows. Sur .250, un depot local et des packs INF par plateforme eviteraient de telecharger les memes pilotes sur chaque PC. Les pilotes reseau / stockage pour WinPE doivent rester separes des packs Windows complets. En IQ-4.8.1, ce depot CMSL et l injection automatique des packs par plateforme n etaient pas implementes. IQ-4.9 ajoute le depot pour HPIA dans Windows ; l injection de packs INF pendant l application du WIM reste distincte.

Dans ce projet, adapter ce mecanisme au deploiement DISM existant, plutot que copier les reglages MDT Out-of-Box Drivers ou CustomSettings.ini de la piece jointe. Garder HPIA dans Windows pour completer les SoftPaq compatibles, depuis Internet ou, apres integration/test, le depot CMSL en mode hors ligne. Les outils ConfigMgr / Intune de HP ne sont pas necessaires pour cette architecture.

La piece jointe donne la bonne direction, mais sa commande Category:Drivers,Software,Firmware omet le BIOS et sa proposition de redemarrage automatique ne correspondait pas a la procedure IQ-4.8.1. IQ-4.9 ajoute maintenant une reprise controlee apres redemarrage BIOS. Les paquets non automatisables ne doivent pas etre annonces installes. La version de Windows doit figurer dans les references HP ; afficher A verifier si HPIA emploie une reference generique.

Sources officielles : [CMSL](https://developers.hp.com/hp-client-management/doc/client-management-script-library), [extraction HPIA](https://developers.hp.com/hp-client-management/doc/install-hpimageassistant), [packs par plateforme](https://developers.hp.com/hp-client-management/doc/new-hpdriverpack), [depots](https://developers.hp.com/hp-client-management/doc/initialize-hprepository), [guide HPIA](https://ftp.hp.com/pub/caps-softpaq/cmit/whitepapers/HPIAUserGuide.pdf), [CLI AnyDesk](https://support.anydesk.com/docs/command-line-interface-for-windows).

## Suppression du dossier de travail IQ-4.8

Les nouveaux deploiements ne conservent plus definitivement `C:\ProgramData\AtelierPXE`. Ce dossier reste necessaire pendant la preparation. Apres la fin des logiciels, le client transmet le rapport, les XML/CSV et une archive des journaux au serveur, puis demande une confirmation portant sur les empreintes SHA-256 des quatre envois. Le serveur verifie aussi que les fichiers existent encore avec le bon contenu. Un ancien recu, un fichier modifie ou un transfert incomplet ne permet pas la suppression.

Les journaux sont dans `Diagnostics-Deploiement.zip`, dans le meme dossier serveur que les inventaires : `<data_dir>/inventaires/NOM-DU-PC/ID-DEPLOIEMENT`. Le bouton Dossier inventaire de la console permet de telecharger cette archive. Elle contient les resultats de preparation, les mesures et les derniers journaux de chaque logiciel, limites a 2000 lignes / 256 K caracteres par journal. Les fichiers reporting.json, personalization.json, les reponses Windows, mots de passe et scripts ne sont pas archives. Le jeton de rapport est masque s il apparait dans un journal selectionne.

Apres confirmation, le nettoyage retire le dossier de travail (scripts, caches, telechargements, jeton et etats), les taches Atelier et l ancien payload de reference cree par ce deploiement. Les autres dossiers de ProgramData ne sont pas touches. Les liens et jonctions sont refuses. Un fichier encore ouvert bloque le nettoyage avant la suppression des taches. Le nettoyage ne tue aucun installateur. Si un redemarrage est demande, il attend le redemarrage manuel avant de supprimer les caches, notamment ceux du constructeur. Si le serveur est indisponible, les fichiers et la tache de reprise sont conserves temporairement ; la tache retente toutes les 15 minutes pendant la validite du jeton de rapport (14 jours). Un jeton expire ou une erreur persistante laisse la copie locale disponible pour diagnostic, sans la supprimer sans archive validee.

Les applications installees et `C:\IQ_` sont conserves. Le fond d ecran est utilise depuis `IQ_/Personnalisation`, et le logo de progression ne garde plus le fichier source ouvert. Les outils son, webcam, clavier, batterie, licence et garantie restent autonomes. Apres nettoyage, les raccourcis Generer-Rapport et Export-Inventaire ouvrent le rapport ou le dossier archives sur le site, sans garder de jeton. Ils ne regenerent plus un inventaire du poste et n envoient plus automatiquement de nouveaux tests : les tests et garanties realises ensuite restent locaux dans IQ_. Le PDF de deploiement local reste consultable.

Cette modification s applique aux prochains deploiements utilisant le WinPE IQ-4.8 reconstruit par Upgrade-Atelier4.ps1 sur DEPLOY-01. Les postes deja termines ne sont pas modifies a distance. Les tests verifient le protocole serveur et la suppression de vrais dossiers temporaires avec processus / redemarrage simules ; la suppression native sous Windows reste a valider sur une machine de test.

## Correction du catalogue Windows PowerShell 5.1 IQ-4.7

Les fichiers du deploiement en echec ont confirme quatre erreurs `Argument WinGet non autorise.` avec le meme nom melange `VLC Adobe Acrobat Reader Google Chrome AnyDesk`. WinGet n avait pas lance les installateurs. Ce diagnostic est distinct des problemes de verification ou de reprise traites en IQ-4.6 ; cette revision ne corrigeait pas le chargement du catalogue.

Windows PowerShell 5.1 transmet un tableau JSON racine comme un seul objet au pipeline. Entourer directement `Get-Content ... | ConvertFrom-Json` par `@(...)` ajoutait un niveau de tableau. Le filtre voyait alors les quatre logiciels comme une seule entree ; les noms et identifiants WinGet etaient melanges, puis refuses par le controle des arguments.

Le catalogue est maintenant affecte directement a une variable avant ajout des deux outils constructeur et filtrage par logiciel. Chaque invocation WinGet recoit un seul identifiant. Les tableaux des outils HP et des anciens checkpoints utilisent la meme correction. La validation des arguments est conservee. Des tests reproduisent la non-enumeration des tableaux racines de PowerShell 5.1, l erreur precedente exacte, puis verifient les logiciels usuels, les bundles HP / Lenovo, les deux outils coches ensemble et l absence de selection. Les installateurs et le materiel sont simules ici ; le rendu et les installations reelles restent a valider sous Windows.

Appliquer cette revision sur DEPLOY-01 avec `scripts/Upgrade-Atelier4.ps1`, qui reconstruit et importe WinPE. Utiliser ensuite l image nouvellement datee ; la fenetre annonce IQ-4.7. Aucune commande de reparation sur le PC deploye n est requise pour les prochains deploiements. Un PC deja termine avec les anciens scripts ne recoit pas retroactivement ce correctif.

Sur une VM, choisir le bundle HP permet de tester l installation de HP Image Assistant via WinGet. L analyse des SoftPaq reste soumise au materiel reel reconnu par HPIA. Changer le fabricant affiche par l hyperviseur ne cree pas un modele HP pris en charge et ne transforme pas les pilotes ou le firmware virtuels en materiel HP. Aucun contournement des controles de modele et aucun flash de BIOS HP sur une VM ne sont ajoutes.

## Verification des logiciels et reprise IQ-4.6

Un ancien resultat termine pouvait court-circuiter toutes les installations du premier demarrage. Un checkpoint WinGet termine etait aussi reutilise sans verifier la presence des logiciels habituels. Le code de sortie zero du lanceur ne garantissait pas leur presence. Ces chemins sont corriges ; les journaux du poste restent necessaires pour confirmer la cause exacte d un incident.

Apres application du WIM, tout ancien dossier `ProgramData/AtelierPXE` est deplace vers `AtelierPXE-Previous-<identifiant>` avant de creer le nouveau payload. Les etats de l ordinateur de reference ne sont plus repris. Le premier demarrage verifie les choix actuels meme si un ancien result.json indique termine.

Pour VLC, Reader, Chrome, AnyDesk et Lenovo System Update, un succes exige une entree de desinstallation correspondant au produit et a son editeur, plus un executable reel. HPIA garde son controle de fichier et de signature HP. Une application supprimee est reinstallee a la reprise ; un retour WinGet zero sans preuve est un echec. Un logiciel deja present et verifie est conserve. Le statut final affiche le nombre verifie ou les logiciels manquants ; aucune selection affiche explicitement qu aucune installation n est demandee. Le rapport et le site affichent A verifier si un choix est absent ou non verifie.

La preparation teste que WinGet execute vraiment `--version`, puis essaie l enregistrement App Installer et la reparation officielle si necessaire. Un alias non executable ne suffit plus. Les erreurs de preparation sont conservees dans `C:\ProgramData\AtelierPXE\software-logs\winget-preparation.log` ; chaque logiciel a son propre fichier dans ce dossier. `personalization.json` contient les choix, `result.json` les resultats, et `first-logon.log` / `maintenance.log` les etapes. Ne pas publier reporting.json : il contient un jeton du poste.

Pour un PC deja deploye, extraire la nouvelle archive puis executer `scripts/Repair-Software.ps1` en PowerShell administrateur sur ce PC. La reparation conserve la selection enregistree, sauvegarde les anciens fichiers dans `repair-backups/software-<identifiant>`, controle chaque logiciel et installe les manquants. Elle refuse une preparation ou un installateur encore actif. Elle met a jour le rapport et l inventaire ; les echecs restent visibles. Le resultat HP durable est conserve pour eviter de relancer automatiquement un flash deja traite. Aucun redemarrage n est demande par Atelier et aucune recherche Windows Update / Store n est ajoutee.

Pour les prochains deploiements, executer `scripts/Upgrade-Atelier4.ps1` sur DEPLOY-01 afin de mettre a jour la console et reconstruire WinPE. L assistant doit annoncer IQ-4.9. Les tests utilisent des installateurs et un registre simules ; l installation reelle WinGet / ADK reste a valider sous Windows.

## Bundles et choix des logiciels IQ-4.5

Dans Logiciels & bureau, la liste Bundle logiciels propose :

| Bundle | Logiciels coches |
| --- | --- |
| Bundle HP | VLC, Adobe Reader, Google Chrome, AnyDesk, HP Image Assistant |
| Bundle Lenovo | VLC, Adobe Reader, Google Chrome, AnyDesk, Lenovo System Update |

Choisir un bundle remplit les cases et decoche l autre outil constructeur. Vous pouvez ensuite cocher ou decocher chaque logiciel : le choix devient Personnalise. Les memes raccourcis existent dans la creation d un profil sur le site. Ils n imposent pas un telechargement depuis un ancien bundle serveur ; seule la liste finale des cases cochees est transmise au poste.

Sans bundle, les quatre logiciels usuels sont coches par defaut dans un nouveau profil. Les deux outils constructeur restent decoches, sauf selection deja enregistree dans le profil choisi. La detection HP ne rajoute plus HPIA automatiquement. Toutes les cases decochees signifie aucune installation WinGet ; la preparation termine quand meme les diagnostics et le rapport.

HP Image Assistant coche : installation du paquet `HP.ImageAssistant`, verification de l executable, puis traitement des SoftPaq compatibles sur un HP. HPIA decoche : aucune installation HPIA ni aucun traitement SoftPaq automatique, meme si un outil ou un ancien resultat est deja present.

Lenovo System Update coche : installation silencieuse du paquet `Lenovo.SystemUpdate` apres Windows, architecture x86 et scope machine d apres son manifeste officiel. Decoche : aucune installation Lenovo lancee. Cette revision installe l outil Lenovo ; elle n ajoute pas de commande automatique d installation des pilotes Lenovo. Vous pouvez ouvrir System Update depuis Windows. Le redemarrage reste manuel et Windows Update / Microsoft Store restent manuels.

Reference Lenovo verifiee : [manifeste Lenovo.SystemUpdate](https://github.com/microsoft/winget-pkgs/blob/16a1cf2cdb0ab480506cef361146633af6a7bfe4/manifests/l/Lenovo/SystemUpdate/5.08.04.85/Lenovo.SystemUpdate.installer.yaml). Les prochains postes installent la version proposee par la source WinGet, sans figer cette version.

Pour appliquer ces choix, mettre a jour le serveur et reconstruire WinPE avec la commande de mise a jour. La fenetre de l assistant doit annoncer IQ-4.9.

## Installation HPIA par WinGet et clavier fixe

La revision IQ-4.3 dependait d un ZIP HPIA deja enregistre sur le serveur. En son absence, la preparation signalait A verifier mais ne pouvait pas installer HPIA. L absence de fenetre HPIA etait normale en mode silencieux ; elle ne prouvait pas a elle seule une absence d execution.

Depuis IQ-4.5, HPIA est ajoute aux installations WinGet uniquement si sa case est cochee. La selection de bundle HP coche cette case, mais vous pouvez la decocher avant installation. Aucun ZIP ni bundle HP du serveur n est necessaire. Le paquet officiel extrait HPIA ; il ne lance pas lui-meme les mises a jour des pilotes. Atelier verifie l executable et sa signature HP, enregistre son empreinte puis lance l analyse et l installation des SoftPaq dans la finalisation SYSTEM. Le technicien choisit le logiciel constructeur adapte. Le traitement SoftPaq de HPIA reste reserve aux HP.

Le dossier demande a WinGet est `%ProgramFiles%\AtelierPXE\Tools\HPImageAssistant`, protege en ecriture pour Administrateurs/SYSTEM. Le manifeste declare une architecture x64 et des arguments d extraction, sans scope : Atelier utilise `--location` et ne force pas `--scope machine` pour ce seul paquet. Si WinGet retourne un succes mais que l executable est absent ou sa signature invalide, le rapport indique l echec. La reprise d une installation deja verifiee controle de nouveau le fichier ; un executable disparu declenche sa reinstallation.

WinGet n est pas pris en charge dans WinPE. Les scripts de preparation sont inclus dans WinPE puis copies dans Windows ; WinGet et HPIA sont executes apres le premier demarrage Windows, dans leur contexte pris en charge. Le clavier WinPE est prepare hors ligne par DISM puis active au demarrage en `100c:0000100c` (francais suisse / QWERTZ). Les selecteurs de clavier de l assistant et du menu de reprise sont retires ; une ancienne configuration ou variable AZERTY/US ne remplace pas cette valeur.

Le manifeste WinGet a ete verifie dans [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs/blob/16a1cf2cdb0ab480506cef361146633af6a7bfe4/manifests/h/HP/ImageAssistant/5.3.6/HP.ImageAssistant.installer.yaml). Les prochains deploiements utilisent la version proposee par la source WinGet au moment de l installation, sans figer HPIA en 5.3.6.

La commande HPIA utilise `/Operation:Analyze /Category:All /Selection:All /Action:Install /Silent /Noninteractive`, avec dossiers dedies `/ReportFolder` et `/SoftpaqDownloadFolder`. L analyse recherche les recommandations du modele et de la version Windows, puis les SoftPaq correspondants sont selectionnes et traites. All couvre pilotes, logiciels, BIOS et firmwares recommandes compatibles. Cela ne force pas un paquet incompatible, ni un BIOS protege par mot de passe. Les scripts Atelier ne demandent aucun redemarrage et n ajoutent pas de parametre de redemarrage. Le comportement interne de chaque SoftPaq reste celui de HP ; valider le parcours BIOS sur le modele avant usage en serie. Certains firmwares terminent leur installation au redemarrage manuel du technicien ; le flash peut ensuite declencher ses propres cycles.

La progression affiche le traitement HP et sa duree reelle, sans inventer de pourcentage par paquet. Les codes retour HPIA et les resultats de remediation des rapports JSON/XML sont conserves. Les rapports natifs sont dans `C:\IQ_\Rapports\HPImageAssistant`, les telechargements dans `C:\ProgramData\AtelierPXE\HP-SoftPaqs`, et le resultat resumant l execution dans `C:\ProgramData\AtelierPXE\hpia-result.json`. Le PDF et la fiche du site recoivent les etats et erreurs SoftPaq disponibles.

Une passe HP au maximum est lancee automatiquement. Un resultat termine est reutilise pour les reprises de rapport. Une execution interrompue ou depassant 45 minutes est signalee A verifier : aucun installateur ou flash n est tue, et aucune seconde installation HP n est lancee automatiquement. Verifier les processus et le rapport HP avant une intervention manuelle ; garder le poste alimente pendant un flash. Le code 256 signifie aucune recommandation ; un modele non pris en charge ou des SoftPaq en echec ne sont pas declares installes.

Reference des parametres et limitations par version : [guide HP Image Assistant](https://ftp.ext.hp.com/pub/caps-softpaq/cmit/whitepapers/HPIAUserGuide.pdf). Les tests de cette revision simulent HPIA sous Linux et ne valident pas les flashs BIOS ou les paquets HP reels.

## Reparer un HP deja deploye sans reinstaller Windows

Telecharger et extraire la nouvelle revision sur le PC HP, puis executer `scripts\Repair-HPIA.ps1` depuis Windows PowerShell administrateur. Ne pas executer cette reparation sur DEPLOY-01. La preparation initiale doit etre terminee. Le script refuse une tache Atelier ou un flash HP actif, sauvegarde les anciens resultats et les scripts remplaces sous `C:\ProgramData\AtelierPXE\repair-backups`, installe/verifie HPIA par WinGet puis reprend les SoftPaq. Les autres logiciels et leurs resultats sont conserves. L ancien resultat HPIA est archive avant cette reprise manuelle explicite.

Le PDF et l inventaire sont regeneres apres les mises a jour HP, puis leur transmission est retentee avec l identifiant du deploiement existant. Un jeton expire ou un reseau indisponible laisse les fichiers locaux et un envoi a reprendre. Aucun redemarrage n est demande par Atelier.

Pour comprendre une absence de HPIA : consulter `C:\ProgramData\AtelierPXE\hpia-result.json`, `result.json`, `first-logon.log` et `software-logs\hpia.log`. Le dernier fichier existe a partir de l installation WinGet IQ-4.4. L absence de fenetre de HPIA est normale ; verifier les fichiers et les rapports natifs.

## Ce qui change

- Le site contient Vue d ensemble, Parc machines et Profils Windows. Les pages Infrastructure PXE et Logiciels & bundles sont retirees.
- WinPE cree automatiquement la demande du poste. Le choix de Windows Pro/Famille et la confirmation du disque restent sur le poste.
- Le premier demarrage enregistre une tache de preparation puis rend la main a Windows. Les logiciels WinGet et les diagnostics tournent apres l ouverture du bureau. L animation Windows de premiere connexion est desactivee ; les operations natives obligatoires du premier demarrage doivent tout de meme se terminer.
- La fenetre de suivi est reductible. Aucune console PowerShell visible n est necessaire.
- Windows Update et Microsoft Store ne sont plus recherches ni actualises par la preparation, meme si un ancien profil contient encore leurs options actives. Le rapport indique Manuel, jamais A jour sans verification. Les services et politiques natifs Windows restent en place ; le technicien lance ses mises a jour depuis Parametres et la bibliotheque Store.
- HP Image Assistant analyse le HP, selectionne toutes les recommandations compatibles et installe les SoftPaq en arriere-plan. Le bureau reste disponible. L ancienne ouverture automatique de sa fenetre est retiree ; le raccourci manuel est conserve.
- Aucun redemarrage demande par Atelier. Les codes de redemarrage HPIA et SoftPaq sont remontes dans le suivi et le rapport. Une fois les installations terminees, le technicien redemarre manuellement. Les relances de la tache finale servent uniquement a transmettre le rapport.
- Un seul inventaire technique final est collecte apres les logiciels et les mises a jour HP. Les reprises de transmission reutilisent les fichiers existants.
- Les sources des scripts et les textes de l interface sont en ASCII sans accents. Les donnees collectees restent en UTF-8 : les vrais noms du materiel et les valeurs d inventaire ne sont pas translitteres.

## Verification de l image et vitesse

Le SHA-256 complet du WIM reste calcule lors de son enregistrement sur le serveur. Le serveur refuse un fichier dont la taille ou la date ont change. WinPE ne relit plus la totalite du WIM pour recalculer son SHA-256 avant chaque installation : cela evite un parcours reseau de plusieurs gigaoctets avant DISM.

WinPE controle encore le fichier et sa taille, l index, l architecture x64, l edition, la langue, le numero de serie, l UEFI et le disque cible. Un verrou de lecture empeche la modification du WIM durant son utilisation. DISM conserve `/CheckIntegrity /Verify` pendant l application.

**Limite :** ces controles ne prouvent plus a chaque deploiement que tous les octets correspondent a l empreinte enregistree. Une image alteree conservant sa taille/date pourrait passer le controle initial ; DISM ne remplace pas une comparaison cryptographique complete. Conserver les droits d ecriture du partage limites aux administrateurs et reenregistrer une image apres tout remplacement. Le gain depend de la taille du WIM, du disque et du reseau.

## Dossier IQ

| Dossier | Contenu |
| --- | --- |
| `C:\IQ_\Diagnostics` | Son, webcam, clavier, batterie et resultats |
| `C:\IQ_\Licence` | Etat de l activation Windows |
| `C:\IQ_\Rapports` | Rapport-Deploiement.pdf, JSON, et Generer-Rapport.cmd |
| `C:\IQ_\Inventaire` | Export-Inventaire.cmd pour regenerer et transmettre XML/CSV |
| `C:\IQ_\Garantie` | Outil de verification et dates confirmees sur le portail constructeur |
| `C:\IQ_\Personnalisation` | Fond d ecran |
| `C:\IQ_\Constructeur` | Lanceur HP-ImageAssistant.cmd si selectionne et verifie |

Les XML/CSV sont sur `.250` dans `<data_dir>\inventaires\NOM-DU-PC\ID-DEPLOIEMENT`. Dans Activite de deploiement, cliquer **Dossier inventaire** pour copier le chemin serveur ou telecharger les deux fichiers. Le PDF est egalement disponible sur la ligne du poste. Les anciens resultats connus sont deplaces dans leur categorie lors de la preparation du dossier ; les fichiers inconnus sont conserves. L organisation des machines deja deployees ne change pas sans execution des nouveaux scripts.

## Mettre a jour DEPLOY-01 (.250)

Executer la commande fournie dans la conversation dans **Windows PowerShell 5.1 administrateur sur DEPLOY-01**. Elle telecharge une revision precise et appelle `scripts\Upgrade-Atelier4.ps1`. Ne pas utiliser une archive de `main`, qui peut etre plus ancienne.

Le script retrouve l installation par sa tache planifiee, sauvegarde code/configuration et SQLite, installe la revision 4, active le parcours automatique, synchronise les editions du WIM, reconstruit WinPE avec les pilotes detectes puis l importe dans WDS sous **Atelier PXE - ATELIER-4 - date**. Les nouvelles dependances graphiques et le lanceur en arriere-plan sont inclus dans le WIM. Un simple remplacement du site ne suffit pas.

Exemple avec chemins explicites, depuis la nouvelle archive extraite :

```powershell
& .\scripts\Upgrade-Atelier4.ps1 `
    -InstallPath 'C:\AtelierPXE\console' `
    -OutputRoot 'D:\AtelierPXE' `
    -TrustedRootCertificate 'C:\AtelierPXE\certs\AtelierPXE-lab.cer' `
    -DriversPath 'D:\AtelierPXE\Drivers\WinPE-x64'
```

L archive ne fournit pas de WIM preconstruit : l ADK, les pilotes et le certificat public du serveur sont utilises pour le produire sur Windows. Ne pas interrompre le montage/enregistrement de DISM. Le chemin exact de `media\sources\boot.wim` est affiche a la fin. Les anciens WinPE sont refuses par la console avant tout effacement.

## Nettoyage du serveur

Apres construction et import verifies de la nouvelle image, les anciennes images WDS **Atelier** et leurs anciens dossiers de construction WinPE sont supprimes. Les images MDT restent independantes.

Le nettoyage complementaire traite uniquement les dossiers temporaires de mise a jour identifiables par leur nom et leur contenu (`Atelier-2/3/4-<guid>`, `Maj-Atelier2/3/4-<guid>`), ainsi que les anciennes sauvegardes identifiees. Il conserve au moins les trois sauvegardes les plus recentes par dossier de sauvegardes, les dossiers de moins d une heure, les chemins actifs/proteges et les dossiers contenant des liens. L installation courante, ses donnees, la nouvelle image, les pilotes, certificats et contenus inconnus sont conserves. Les fichiers de logiciels historiques encore references dans la base ne sont pas supprimes automatiquement. Journal : `<data_dir>\cleanup\nettoyage-date.json`.

Pour voir la selection avant un nettoyage manuel, fournir le vrai dossier d installation :

```powershell
& 'C:\AtelierPXE\console\scripts\Clear-AtelierObsolete.ps1' `
    -InstallPath 'C:\AtelierPXE\console' -WhatIf
```

`-WhatIf` ne supprime rien et n ecrit aucun journal. La mise a jour complete effectue deja le nettoyage apres ses controles.

## Verifier apres mise a jour

1. Recharger le site avec Ctrl+F5 : logo IQ, theme bleu/lilas, trois pages.
2. Demarrer un poste de test UEFI sur ATELIER-4 ; choisir edition, nom et disque puis confirmer.
3. Retirer le demarrage PXE prioritaire apres application : demarrer sur le disque Windows.
4. Verifier l arrivee au bureau et la progression reductible pendant WinGet.
5. Verifier `C:\IQ_\Rapports\Rapport-Deploiement.pdf`, les categories IQ et les XML/CSV sur .250.
6. Verifier le resultat HP Image Assistant, les SoftPaq et un eventuel redemarrage manuel. Windows Update et Microsoft Store doivent etre marques Manuel dans le rapport.

Journaux Windows : `C:\ProgramData\AtelierPXE\first-logon.log`, `maintenance.log`, `progress.json`, `reporting.log`, `software-logs`. Journaux du serveur : `<data_dir>\logs\console.log`. Le demarrage rapide Windows reste desactive a chaque deploiement ; le Fast Boot du BIOS est un reglage distinct.

## Pistes utiles pour la suite

- Actualiser regulierement le WIM Windows avec les mises a jour deja integrees : cela reduit le travail a effectuer sur chaque poste, sans supprimer les correctifs de securite.
- Preparer un cache local des pilotes par modele, avec validation et date de version, pour raccourcir les passages HP Image Assistant et Lenovo.
- Ajouter un etat Pret pour remise qui exige rapport disponible, activation verifiee et tests materiels valides, avec les points restants visibles.

Les tests automatises utilisent des images et services simules. Un deploiement reel, les pilotes et l OOBE doivent etre verifies sur un poste Windows de laboratoire.

## Comment preparer un WIM Windows a jour

Cette procedure est une proposition de maintenance. La mise a jour IQ-4.2 ne modifie pas votre WIM Windows et ne programme pas de maintenance automatique des images.

Le principe est d installer une fois les correctifs dans une copie de l image, sur .250, au lieu de les reinstaller sur chaque ordinateur. Prevoir de l espace pour la copie, le montage et les fichiers temporaires. Les operations DISM se font sur Windows avec les outils compatibles avec la version cible.

1. Conserver le WIM actuel pour le retour arriere. Creer une copie avec un nouveau nom, par exemple `Windows11-2026-10.wim`. Ne jamais monter en ecriture une image en cours de deploiement.
2. Relever les index Pro et Famille avec DISM /Get-WimInfo, ainsi que la version, l architecture et les langues. Telecharger depuis le Catalogue Microsoft Update les paquets officiels correspondants ; verifier leurs prerequis. Selon la version, des mises a jour de pile de maintenance ou des mises a jour cumulatives de point de controle doivent etre ajoutees dans un ordre precis.
3. Monter chaque index utilise dans un dossier vide, ajouter les paquets avec DISM /Add-Package, puis enregistrer avec /Unmount-Image /Commit. Traiter Pro et Famille : actualiser seulement un index ne met pas les autres a jour. Ne pas utiliser /ResetBase pour cette premiere procedure, afin de conserver les possibilites de retrait de correctifs.
4. Tester les deux editions sur un poste de laboratoire : demarrage UEFI, edition et activation, reseau, pilotes, WinGet et rapport. Verifier aussi les correctifs restants dans Windows Update. Certaines mises a jour, les applications Store et les pilotes restent propres a chaque ordinateur.
5. Enregistrer le nouveau WIM sous son nouveau nom dans Atelier, puis creer les profils pointant vers les bons index. Conserver les anciens profils jusqu a validation et choisir les nouveaux pour les prochains deploiements. Ne pas simplement remplacer les octets du fichier deja reference : le controle de taille/date et l empreinte enregistree doivent correspondre au nouveau fichier.

On peut renouveler cette preparation chaque mois apres validation des correctifs. L objectif est de reduire fortement le telechargement et l installation repetes ; une courte verification Windows Update reste utile pour les correctifs parus apres la fabrication de l image. La reconstruction de WinPE concerne l assistant de deploiement : elle ne met pas a jour Windows dans le WIM d installation.
