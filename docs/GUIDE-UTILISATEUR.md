# IQ Atelier - guide utilisateur

IQ Atelier installe Windows sur les ordinateurs de l’atelier depuis le réseau. Le serveur de déploiement est DEPLOY-01, `192.168.99.250`. Le site permet de suivre les installations et retrouver leurs rapports. Consulter [le guide de mise à jour ATELIER-4](ATELIER-4.md) pour mettre le serveur et WinPE à niveau.

## Statistiques réseau

La page **Statistiques** affiche le débit reçu pendant l’application de Windows, en Mbit/s et Mo/s, ainsi que la vitesse de liaison déclarée par le poste. Une liaison à 100 Mbit/s est signalée pour faciliter la comparaison avec les postes à 1 Gbit/s. Le tableau présente le poste, son modèle, son interface, le volume reçu et la durée de mesure.

Le débit repose sur la variation du compteur de réception de l’interface IPv4 routée vers le partage, entre le début et la fin de DISM. Il inclut les autres échanges de cette interface et les périodes où DISM décompresse ou écrit sur disque. La vitesse négociée ne garantit donc pas un débit reçu équivalent. Le compteur ne mesure pas seulement les octets du WIM ; le multicanal SMB n’est pas agrégé.

La moyenne est pondérée par la durée de chaque relevé. Les transferts simultanés sont traités comme des mesures de postes distincts, sans annoncer un débit global du serveur. Le meilleur résultat est une moyenne par application, pas une pointe instantanée. Les mesures s’affichent après l’application de l’image, même si la préparation Windows continue. Les applications en échec et les annulations sont exclues des moyennes.

Les nouveaux relevés nécessitent WinPE IQ-6.3. Les anciens déploiements et les compteurs indisponibles sont indiqués comme non mesurés. La vitesse de liaison peut rester connue même si le compteur de réception est indisponible. Une route différente, une vitesse modifiée ou un compteur décroissant aux bornes invalide le débit. La liste montre les cinquante dernières applications de la période ; les moyennes utilisent toute la période.

## Avant de commencer

Depuis IQ-6.2, **Suivre les étapes** présente Image Windows, HPIA, Logiciels, Dossier IQ, Redémarrage et Bilan, depuis la vue globale ou l’historique du poste. Le compteur part du premier signal reçu, sans repartir à zéro à chaque actualisation. Les résultats absents des anciens agents restent non confirmés. Consulter [la signification des états](ETATS-ET-SUIVI.md).

**HPIA et pilotes** regroupe les plateformes et modèles connus, les SoftPaq conservés, leurs descriptions et versions CVA, les recommandations encore absentes et les actualisations. Le bouton de synchronisation alimente le cache serveur ; il n’installe aucun pilote sur .250. Un cache conservé et une actualisation échouée peuvent coexister. La source déclarée par chaque poste est indépendante de ces deux états.

**Correctifs Windows** présente le cache KB, sa recherche et son téléchargement sur .250, ainsi que la veille des versions Windows. Ces fichiers ne sont pas installés automatiquement pendant les nouveaux déploiements. L’historique des anciennes préparations WIM reste consultable : une candidate prête à tester ne signifie pas qu’elle est en production.

L’espace libre et la répartition des fichiers sont affichés uniquement dans la vue globale. Ce sont des tailles logiques datées ; les montages Windows sont exclus du calcul détaillé. Les métadonnées HPIA sont mises en cache pour éviter de relire toutes les archives à chaque actualisation.

Sauvegarder les données du poste : le déploiement effacé toutes les partitions du disque choisi. Brancher l’alimentation et un câble réseau. Le poste doit démarrer en UEFI. Vérifier qu’une image Windows et ses profils Pro/Famille sont disponibles dans Atelier.

## Identifier le PC, même sur un dock

Avec WinPE IQ-5.0, le numéro de série du PC identifie sa fiche. Le même dock peut servir a plusieurs ordinateurs ; chacun conserve sa fiche et ses rapports. Une MAC absente de l’inventaire WinPE n’empêche plus la tentative de connexion. Le SN doit être réel et lisible dans le firmware ; une valeur générique ou absente bloque l’identification, sans toucher au disque. Les anciennes fiches MAC sans SN restent visibles ; les historiques ambigus ne sont pas fusionnes automatiquement.

## Installer un ordinateur

1. Allumer le poste et choisir son démarrage réseau UEFI/PXE dans le menu de démarrage du constructeur.
2. Choisir l’image **Atelier PXE - ATELIER-4 - date**. L’assistant IQ Atelier s’ouvre. Le poste et sa demande apparaissent automatiquement sur le site ; aucune autorisation préalable n’y est nécessaire.
3. Choisir Windows Pro ou Famille. Cette édition doit correspondre à la licence du poste. Un profil correspond à un index précis du WIM Windows, pas à un fichier ISO monte arbitrairement.
4. Compléter le nom du PC : seuls les quatre derniers chiffres du SN sont proposés, sans préfixe. Exemple : `8323` devient `ATELIER-8323`. Le nom doit commencer par une lettre, avec au maximum 15 lettres, chiffres ou tirets. Le clavier de WinPE et de cet assistant est fixe en français suisse (QWERTZ), sans choix de modification. Vérifier le fuseau ; la région et les formats sont proposés en `fr-CH`.
5. Dans Logiciels & bureau, choisir Bundle HP (VLC, Adobe Reader, Chrome, AnyDesk et HP Image Assistant) ou Bundle Lenovo (les quatre logiciels usuels et Lenovo System Update). Ajuster ensuite les cases si nécessaire. Seuls les logiciels cochés seront installés silencieusement dans Windows ; HPIA décoche ne lance pas de SoftPaq. Le fond `Fond Atelier.png` est propose s’il est enregistré sur le serveur ; le thème et le fond restent modifiables. Propriétaire et organisation ne sont plus demandes.
6. Lire le récapitulatif, choisir le bon disque en verifiant sa taille et son numéro de série. **Installer Windows** effacé ce disque.
7. Attendre la fin de l’application de l’image. Redémarrer sur le disque local Windows, avec le démarrage réseau retire de la priorité.
8. Une fois l’image et le démarrage vérifiés, WinPE redémarre automatiquement après cinq secondes. En cas d’échec, le journal reste accessible. Windows termine ses opérations natives puis ouvre le compte de préparation Administrateur. L’installation des logiciels et la préparation continuent en arrière-plan. La fenêtre IQ Atelier peut être réduite pour travailler.
9. Consulter le résultat final. Un avertissement signifie qu’un point reste à vérifier : logiciel en échec, mise à jour reportée ou redémarrage requis. Le suivi ne prouve pas qu’un test manuel a été effectué.

Le compte de préparation utilise le mode automatique déjà configuré dans l’atelier. Avant remise au client, configurer le compte final et sa sécurité selon votre procédure. L’ouverture automatique est désactivée à la fin de la préparation.

## Utiliser le site

Ouvrir `https://192.168.99.250`. En mode interne, l’accès administrateur est automatique sur le réseau de confiance de l’atelier.

- **Vue d’ensemble** : progression de l’image, étapes Windows, erreurs et avertissements. Cliquer sur le poste pour son journal.
- **Parc machines** : noms, numéros de série et rapports disponibles. La MAC observée reste informative. Cliquer un nom pour ouvrir la fiche ordinateur.
- **Profils Windows** : images enregistrées, editions/index, logiciels et personnalisation. Pour ajouter une image, copier le WIM dans `<data_dir>\artifacts` sur le serveur puis Enregistrer un fichier. Le SHA-256 est calcule a cet enregistrement.

Dans Activité de déploiement, **Rapport PDF** télécharge le rapport du poste. **Dossier inventaire** affiche le chemin serveur et permet de télécharger XML et CSV. Les fichiers sont classes sous `<data_dir>\inventaires\NOM-DU-PC\ID-DEPLOIEMENT` sur .250. Le navigateur ne peut pas ouvrir de lui-même l’Explorateur d’un autre ordinateur : copier le chemin dans l’Explorateur du serveur, ou télécharger les fichiers depuis le site.

**Fiche ordinateur** rassemble historique, inventaire, PDF, résultats de tests, garantie connue et observations du technicien. Les observations sont enregistrées sur le serveur. Les nouveaux déploiements affichent les durées mesurées pour l’image, WinGet, les outils constructeur, les mises à jour HP et l’inventaire. Les anciennes installations restent sans mesures. Les anciennes utilisations manuelles de HP Image Assistant ne sont pas chronometrees. Après un test ou une vérification de garantie, régénérer le rapport depuis le poste pour actualiser la fiche.

## Outils sur le poste Windows

Ouvrir `C:\IQ_`. Les fichiers sont classes par catégorie :

| Dossier | Usage |
| --- | --- |
| Diagnostics | Double-cliquer Test-Materiel.cmd : tester les canaux sonores, autoriser la webcam puis appuyer sur les touches. Confirmer et enregistrer le résultat. Test-Batterie.cmd génère le rapport batterie. |
| Licence | Verifier-Licence.cmd actualise l’état d’activation Windows sans changer la licence. |
| Rapports | Rapport-Deploiement.pdf et Generer-Rapport.cmd pour le régénérer et retenter son envoi. |
| Inventaire | Export-Inventaire.cmd actualise XML/CSV et les transmet au serveur. |
| Garantie | Verifier-Garantie.cmd ouvre le portail officiel HP, Lenovo ou Dell. Saisir les dates confirmées : aucune date n’est inventee depuis le SN. |
| Personnalisation | Fond d’écran sélectionne. |
| Constructeur | HP-ImageAssistant.cmd ouvre l’outil portable vérifie en administrateur si sa case a été cochée. |

L’outil de tests utilise le navigateur local : images webcam et son ne sont pas envoyés à Internet. Les résultats sont validés par l’opérateur. Les inventaires ne contiennent pas de clé produit complète ni de clé BitLocker. Si HP Image Assistant est coché, WinGet l’installe et le vérifie après le démarrage Windows, puis l’analyse et l’installation des SoftPaq compatibles se font en arrière-plan : pilotes, logiciels HP, BIOS et firmwares proposés par HPIA. L’outil ne s’ouvre plus automatiquement sur le bureau. Un pilote ordinaire demandant un redémarrage reste manuel. Depuis IQ-4.9, un paquet BIOS identifié peut déclencher un redémarrage dans 60 secondes ; la préparation reprend automatiquement après le démarrage Windows, sans ouverture de session. Lenovo System Update est installé uniquement si sa case est cochée ; son outil de mise à jour reste accessible dans Windows. HPIA se trouve dans `%ProgramFiles%\AtelierPXE\Tools\HPImageAssistant`. Les rapports HP se trouvent dans Rapports\HPImageAssistant ; le résultat est aussi dans le PDF et la fiche du site.

Pour retester seulement HPIA sur un HP déjà installé, utiliser Constructeur/Tester-HPIA.cmd (IQ-5.4.2). Le test silencieux fonctionne sous SYSTEM, reprend après un redémarrage BIOS et conserve ses rapports dans Rapports/HPImageAssistant/Tests. Il utilise HP Internet, sans réutiliser les identifiants d’un ancien déploiement. Consulter [la validation de déploiement](VALIDATION-DEPLOIEMENT.md).

Depuis IQ-5.4.3, le bilan HTML natif de l’installation HPIA est conservé sous un nom simple : `C:\IQ_\Rapports\Rapport-Installation-HP.html`. Double-cliquer pour lire la liste des SoftPaq, leurs versions et leurs résultats. Le site propose **Rapport HP (HTML)** dans l’activité de déploiement et dans l’historique de la fiche ordinateur. Le même fichier et Rapports-HP.zip sont aussi disponibles dans Dossier inventaire. Le rapport HTML est téléchargé comme un fichier, puis ouvert localement dans le navigateur. Les rapports de tous les passages, notamment avant et après un redémarrage BIOS, restent dans le ZIP.

## Mises à jour et lenteur

La maintenance mensuelle des images Windows peut intégrer les correctifs avant déploiement, sur une copie du WIM sur .250. L’administrateur doit tester cette image puis la publier. Les profils TEST ne sont jamais choisis automatiquement ; ne les sélectionner que pour une validation. Consulter [la procédure de maintenance](MAINTENANCE-IMAGES-WINDOWS.md).

Windows Update et Microsoft Store ne sont plus lancés par la préparation. Effectuer ces opérations manuellement depuis Paramètres > Windows Update et Microsoft Store > Bibliothèque. Le rapport les indiqué comme manuels. Cela ne désactive pas les services ni les politiques Windows : Windows peut continuer son propre fonctionnement automatique.

Pour HP Image Assistant, le suivi affiche le traitement SoftPaq en cours puis son résultat. Un paquet incompatible, un BIOS protégé ou une installation en échec restent à vérifier dans les rapports HP. Les nouveaux déploiements IQ-4.9 enregistrent leur phase avant HPIA. Après un redémarrage BIOS, une nouvelle analyse installe les mises à jour restantes ; les logiciels déjà vérifiés ne sont pas réinstallés. Pendant le même démarrage, aucun flash n’est tué et aucune deuxième exécution n’est lancée. Si le suivi reste en attente après une interruption, vérifier les processus avant de redémarrer. Après trois reprises, un problème persistant reste À vérifier.

Internet est nécessaire pour WinGet, les mises à jour et les portails de garantie. L’installation d’une application peut être lente selon sa taille et son éditeur ; consulter le nom de l’étape et le journal, sans relancer simultanément le même installateur.

## En cas de problème

Pour vérifier un poste complet et réunir les bons fichiers depuis .250, consulter [la validation du déploiement et de HPIA](VALIDATION-DEPLOIEMENT.md).

- PXE absent : vérifier UEFI, Ethernet, pilotes WinPE et qu’un seul serveur PXE repond.
- HP À vérifier avec code 4104 : HPIA utilise une référence Windows générique. IQ-5.3.2 distingue les recommandations des installations réelles et conserve l’avertissement de compatibilité. Le fichier Rapports-HP.zip du dossier inventaire contient le détail.
- HTTP 409 avec Image appliquée : démarrer Windows Boot Manager pour terminer. Si Windows est bloque et doit être réinstallé, WinPE IQ-5.3.1 propose de recommencer ; confirmer ce choix puis le disque dans l’assistant. L’historique reste conservé.
- Connexion WinPE impossible avec NetworkUnreachable et aucune interface dans ipconfig /all : la reconstruction IQ-5.3.1 ajoute un seul pilote Intel I219 cible pour le port intégre du HP 840 G5. Une docking qui fonctionne utilise une autre carte réseau. Démarrer le PC sur la nouvelle image datee. Le fonctionnement sur un Dell ou une VM ne garantit pas que les pilotes du HP soient déjà présents.
- Mauvaise édition : choisir un autre profil correspondant à la licence, ou faire synchroniser les profils depuis le WIM par l’administrateur.
- Échec avant partitionnement : lire le journal dans WinPE et dans l’activité du site. Le disque ne doit pas être effacé tant que les contrôles ne sont pas passés.
- Logiciel en échec : consulter `C:\ProgramData\AtelierPXE\software-logs` et le PDF. Le reste de la préparation peut continuer.
- HPIA absent : consulter `C:\ProgramData\AtelierPXE\software-logs\hpia.log` et `hpia-result.json`. La nouvelle révision fournit `scripts\Repair-HPIA.ps1` à lancer sur le HP en administrateur après la fin de la préparation pour réparer sans réinstaller Windows.
- Rapport absent sur le site : le PDF local et le cache d’inventaire restent conservés. Rétablir le réseau puis lancer Rapports\Generer-Rapport.cmd.

Journaux du poste : `C:\ProgramData\AtelierPXE\first-logon.log`, `maintenance.log`, `reporting.log`, `progress.json`. Sur le serveur : `<data_dir>\logs\console.log` et `<data_dir>\cleanup` pour le nettoyage.

## Démarrer ou arrêter le PXE

Sur le serveur qui heberge le WDS concerne, ouvrir Windows PowerShell administrateur. Ne pas activer en même temps l’ancien MDT et le nouveau PXE sur le même réseau.

```powershell
# Arreter les reponses PXE
wdsutil /Set-Server /AnswerClients:None
Stop-Service WDSServer

# Demarrer les reponses PXE
Start-Service WDSServer
wdsutil /Set-Server /AnswerClients:All
```

Ces commandes ne desinstallent pas les images ou la console. Un poste déjà en train d’appliquer son image doit terminer avant une opération de maintenance du serveur.

## Si les logiciels sont absents après Windows

Consulter `C:\ProgramData\AtelierPXE\result.json`, puis `software-logs/winget-preparation.log` et les journaux de chaque logiciel. Une fin de préparation ne doit pas masquer une installation non vérifiée : IQ-4.6 affiche À vérifier et les noms concernes. Si aucune case n’était cochée, aucune application n’est installée. Extraire la révision courante et exécuter `scripts/Repair-Software.ps1` sur le PC en PowerShell administrateur pour reprendre uniquement la sélection enregistrée, sans redéployer Windows. Attendre la fin de toute préparation déjà activé.

La révision IQ-4.7 corrige l’erreur `Argument WinGet non autorise.` due à la lecture du catalogue sous Windows PowerShell 5.1. Mettre à jour uniquement le serveur avec `Upgrade-Atelier4.ps1`, puis utiliser le nouveau WinPE pour les prochains déploiements. Sur une VM, le bundle HP permet d’installer HPIA pour tester sa présence ; les pilotes et BIOS de vrais PC HP ne sont pas applicables au matériel virtuel.

## Après la préparation IQ-4.8

Le dossier cache ProgramData/AtelierPXE est temporaire. Après confirmation du rapport, des XML/CSV et des journaux sur le serveur, il est supprimé automatiquement. Une coupure réseau ou un installateur encore actif reporte ce nettoyage ; aucun redémarrage n’est forcé. Si un redémarrage est nécessaire, le technicien le lance et le nettoyage reprend au démarrage suivant.

Les journaux sont telechargeables sur le site, dans Dossier inventaire, fichier Diagnostics-Deploiement.zip. Le dossier IQ_ et les logiciels installés restent sur le PC. Après nettoyage, les raccourcis Rapports / Inventaire ouvrent les archives du serveur. Les nouveaux tests matériels ou garanties realises ensuite restent enregistrés localement dans IQ_ ; ils ne sont pas renvoyes automatiquement sans le dossier de préparation.

## Contrôle HP / AnyDesk IQ-4.8.1

Le nouveau WinPE doit annoncer IQ-4.9. HPIA est un outil portable : ne pas chercher obligatoirement une application dans Paramètres. Le lancer au besoin depuis Constructeur/HP-ImageAssistant.cmd dans IQ_. La préparation vérifie son fichier signe dans Program Files avant de déclarer sa présence. Le résultat des SoftPaq est indiqué séparément dans le rapport.

AnyDesk officiel est reconnu par sa signature et son enregistrement Windows ou son service, même si certaines informations de désinstallation manquent. Un fichier simplement télécharge ne suffit pas. Les erreurs de signature restent visibles. Pour un diagnostic sans commande sur le PC, ouvrir son activité sur le site puis Dossier inventaire et télécharger Diagnostics-Deploiement.zip. Les journaux ne sont disponibles sur .250 qu’après transmission réussie.

Pour valider le correctif, effectuer un déploiement de laboratoire avec Bundle HP puis vérifier les applications, le lanceur HP, le résultat des SoftPaq dans le PDF et les XML/CSV/journaux sur .250. Redémarrer manuellement si le suivi le demande. Le cache privé est supprimé seulement après confirmation des archives et fin des installations. Un test en VM ne valide pas les pilotes ni le BIOS d’un vrai HP.

## Pilotes HP partagés IQ-4.9

Mettre à jour uniquement le serveur avec Upgrade-Atelier4.ps1 et utiliser le WinPE reconstruit IQ-4.9. La mise à jour prépare aussi l’agent CMSL sur .250. Il ne faut pas installer CMSL ou coller une commande sur les PC déployés.

Avec HP Image Assistant coché, chaque poste HP est analysé. Si des mises à jour sont recommandées, Atelier utilise le dépôt local correspondant à sa plateforme et à Windows quand il est prêt. HPIA contrôle le vrai matériel et installe les paquets applicables. Aucun paquet BIOS n’est forcé sur un modèle ou une VM incompatible. Sans recommandation, le poste passe directement à la finalisation sans recopier le dépôt.

Le dépôt est alimenté automatiquement sur .250 et entretenu chaque jour pour les plateformes connues. Le premier remplissage peut prendre du temps et contenir plusieurs Go de paquets. Le poste n’attend sa préparation qu’environ 90 secondes, puis peut utiliser HP directement pendant que le serveur termine son dépôt. Si l’agent est indisponible, ce repli est immédiat. Le dépôt complet est copié par le réseau local ; seul le nécessaire est installé.

Dans Vue d’ensemble, ouvrir **Pilotes HP partagés** pour voir les synchronisations ou cliquer **Actualiser les pilotes HP**. Trois versions du dépôt sont conservées ; une copie en cours d’utilisation est protégée. Un échec conserve les versions précédentes.

Le suivi indiqué la source et les étapes ; HPIA reste sans fenêtre propre. Les paquets manuels ou en échec sont À vérifier. Le technicien lance le redémarrage. Windows Update et Microsoft Store restent manuels.

Dans l’activité du poste ou sa fiche, ouvrir **Dossier inventaire**, puis télécharger **Rapports-HP.zip** pour les rapports HP detailles. **Diagnostics-Deploiement.zip** contient le bilan Atelier et les journaux logiciels. La transmission HP fait partie des confirmations nécessaires avant de supprimer le cache temporaire du poste. Les fichiers IQ_ restent accessibles localement.

En cas de dépôt indisponible, consulter sur .250 `<data_dir>\hp-repository\setup.log` et `worker.log`. La bibliothèque HP et les installateurs doivent encore être validés sur votre serveur et vos vrais modèles HP ; les tests du projet utilisent du matériel simule.
