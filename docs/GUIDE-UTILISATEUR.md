# IQ Atelier - guide utilisateur

IQ Atelier installe Windows sur les ordinateurs de l atelier depuis le reseau. Le serveur de deploiement est DEPLOY-01, `192.168.99.250`. Le site permet de suivre les installations et retrouver leurs rapports. Consulter [le guide de mise a jour ATELIER-4](ATELIER-4.md) pour mettre le serveur et WinPE a niveau.

## Avant de commencer

Sauvegarder les donnees du poste : le deploiement efface toutes les partitions du disque choisi. Brancher l alimentation et un cable reseau. Le poste doit demarrer en UEFI. Verifier qu une image Windows et ses profils Pro/Famille sont disponibles dans Atelier.

## Installer un ordinateur

1. Allumer le poste et choisir son demarrage reseau UEFI/PXE dans le menu de demarrage du constructeur.
2. Choisir l image **Atelier PXE - ATELIER-4 - date**. L assistant IQ Atelier s ouvre. Le poste et sa demande apparaissent automatiquement sur le site ; aucune autorisation prealable n y est necessaire.
3. Choisir Windows Pro ou Famille. Cette edition doit correspondre a la licence du poste. Un profil correspond a un index precis du WIM Windows, pas a un fichier ISO monte arbitrairement.
4. Completer le nom du PC : seuls les quatre derniers chiffres du SN sont proposes, sans prefixe. Exemple : `8323` devient `ATELIER-8323`. Le nom doit commencer par une lettre, avec au maximum 15 lettres, chiffres ou tirets. Le clavier de WinPE et de cet assistant est fixe en francais suisse (QWERTZ), sans choix de modification. Verifier le fuseau ; la region et les formats sont proposes en `fr-CH`.
5. Dans Logiciels & bureau, choisir Bundle HP (VLC, Adobe Reader, Chrome, AnyDesk et HP Image Assistant) ou Bundle Lenovo (les quatre logiciels usuels et Lenovo System Update). Ajuster ensuite les cases si necessaire. Seuls les logiciels coches seront installes silencieusement dans Windows ; HPIA decoche ne lance pas de SoftPaq. Le fond `Fond Atelier.png` est propose s il est enregistre sur le serveur ; le theme et le fond restent modifiables. Proprietaire et organisation ne sont plus demandes.
6. Lire le recapitulatif, choisir le bon disque en verifiant sa taille et son numero de serie. **Installer Windows** efface ce disque.
7. Attendre la fin de l application de l image. Redemarrer sur le disque local Windows, avec le demarrage reseau retire de la priorite.
8. Windows termine ses operations natives puis ouvre le compte de preparation Administrateur. L installation des logiciels et la preparation continuent en arriere-plan. La fenetre IQ Atelier peut etre reduite pour travailler.
9. Consulter le resultat final. Un avertissement signifie qu un point reste a verifier : logiciel en echec, mise a jour reportee ou redemarrage requis. Le suivi ne prouve pas qu un test manuel a ete effectue.

Le compte de preparation utilise le mode automatique deja configure dans l atelier. Avant remise au client, configurer le compte final et sa securite selon votre procedure. L ouverture automatique est desactivee a la fin de la preparation.

## Utiliser le site

Ouvrir `https://192.168.99.250`. En mode interne, l acces administrateur est automatique sur le reseau de confiance de l atelier.

- **Vue d ensemble** : progression de l image, etapes Windows, erreurs et avertissements. Cliquer sur le poste pour son journal.
- **Parc machines** : noms, MAC et rapports disponibles. Cliquer un nom pour ouvrir la fiche ordinateur.
- **Profils Windows** : images enregistrees, editions/index, logiciels et personnalisation. Pour ajouter une image, copier le WIM dans `<data_dir>\artifacts` sur le serveur puis Enregistrer un fichier. Le SHA-256 est calcule a cet enregistrement.

Dans Activite de deploiement, **Rapport PDF** telecharge le rapport du poste. **Dossier inventaire** affiche le chemin serveur et permet de telecharger XML et CSV. Les fichiers sont classes sous `<data_dir>\inventaires\NOM-DU-PC\ID-DEPLOIEMENT` sur .250. Le navigateur ne peut pas ouvrir de lui-meme l Explorateur d un autre ordinateur : copier le chemin dans l Explorateur du serveur, ou telecharger les fichiers depuis le site.

**Fiche ordinateur** rassemble historique, inventaire, PDF, resultats de tests, garantie connue et observations du technicien. Les observations sont enregistrees sur le serveur. Les nouveaux deploiements affichent les durees mesurees pour l image, WinGet, les outils constructeur, les mises a jour HP et l inventaire. Les anciennes installations restent sans mesures. Les anciennes utilisations manuelles de HP Image Assistant ne sont pas chronometrees. Apres un test ou une verification de garantie, regenerer le rapport depuis le poste pour actualiser la fiche.

## Outils sur le poste Windows

Ouvrir `C:\IQ_`. Les fichiers sont classes par categorie :

| Dossier | Usage |
| --- | --- |
| Diagnostics | Double-cliquer Test-Materiel.cmd : tester les canaux sonores, autoriser la webcam puis appuyer sur les touches. Confirmer et enregistrer le resultat. Test-Batterie.cmd genere le rapport batterie. |
| Licence | Verifier-Licence.cmd actualise l etat d activation Windows sans changer la licence. |
| Rapports | Rapport-Deploiement.pdf et Generer-Rapport.cmd pour le regenerer et retenter son envoi. |
| Inventaire | Export-Inventaire.cmd actualise XML/CSV et les transmet au serveur. |
| Garantie | Verifier-Garantie.cmd ouvre le portail officiel HP, Lenovo ou Dell. Saisir les dates confirmees : aucune date n est inventee depuis le SN. |
| Personnalisation | Fond d ecran selectionne. |
| Constructeur | HP-ImageAssistant.cmd ouvre l outil portable verifie en administrateur si sa case a ete cochee. |

L outil de tests utilise le navigateur local : images webcam et son ne sont pas envoyes a Internet. Les resultats sont valides par l operateur. Les inventaires ne contiennent pas de cle produit complete ni de cle BitLocker. Si HP Image Assistant est coche, WinGet l installe et le verifie apres le demarrage Windows, puis l analyse et l installation des SoftPaq compatibles se font en arriere-plan : pilotes, logiciels HP, BIOS et firmwares proposes par HPIA. L outil ne s ouvre plus automatiquement sur le bureau. Le technicien lance le redemarrage quand les installations sont terminees. Lenovo System Update est installe uniquement si sa case est cochee ; son outil de mise a jour reste accessible dans Windows. HPIA se trouve dans `%ProgramFiles%\AtelierPXE\Tools\HPImageAssistant`. Les rapports HP se trouvent dans Rapports\HPImageAssistant ; le resultat est aussi dans le PDF et la fiche du site.

## Mises a jour et lenteur

Windows Update et Microsoft Store ne sont plus lances par la preparation. Effectuer ces operations manuellement depuis Parametres > Windows Update et Microsoft Store > Bibliotheque. Le rapport les indique comme manuels. Cela ne desactive pas les services ni les politiques Windows : Windows peut continuer son propre fonctionnement automatique.

Pour HP Image Assistant, le suivi affiche le traitement SoftPaq en cours puis son resultat. Un paquet incompatible, un BIOS protege ou une installation en echec restent a verifier dans les rapports HP. Le script Atelier ne lance pas de redemarrage. Si une execution est interrompue ou depasse son delai, verifier les processus avant toute reprise : aucun flash n est tue et aucune deuxieme passe n est lancee automatiquement.

Internet est necessaire pour WinGet, les mises a jour et les portails de garantie. L installation d une application peut etre lente selon sa taille et son editeur ; consulter le nom de l etape et le journal, sans relancer simultanement le meme installateur.

## En cas de probleme

- PXE absent : verifier UEFI, Ethernet, pilotes WinPE et qu un seul serveur PXE repond.
- Mauvaise edition : choisir un autre profil correspondant a la licence, ou faire synchroniser les profils depuis le WIM par l administrateur.
- Echec avant partitionnement : lire le journal dans WinPE et dans l activite du site. Le disque ne doit pas etre efface tant que les controles ne sont pas passes.
- Logiciel en echec : consulter `C:\ProgramData\AtelierPXE\software-logs` et le PDF. Le reste de la preparation peut continuer.
- HPIA absent : consulter `C:\ProgramData\AtelierPXE\software-logs\hpia.log` et `hpia-result.json`. La nouvelle revision fournit `scripts\Repair-HPIA.ps1` a lancer sur le HP en administrateur apres la fin de la preparation pour reparer sans reinstaller Windows.
- Rapport absent sur le site : le PDF local et le cache d inventaire restent conserves. Retablir le reseau puis lancer Rapports\Generer-Rapport.cmd.

Journaux du poste : `C:\ProgramData\AtelierPXE\first-logon.log`, `maintenance.log`, `reporting.log`, `progress.json`. Sur le serveur : `<data_dir>\logs\console.log` et `<data_dir>\cleanup` pour le nettoyage.

## Demarrer ou arreter le PXE

Sur le serveur qui heberge le WDS concerne, ouvrir Windows PowerShell administrateur. Ne pas activer en meme temps l ancien MDT et le nouveau PXE sur le meme reseau.

```powershell
# Arreter les reponses PXE
wdsutil /Set-Server /AnswerClients:None
Stop-Service WDSServer

# Demarrer les reponses PXE
Start-Service WDSServer
wdsutil /Set-Server /AnswerClients:All
```

Ces commandes ne desinstallent pas les images ou la console. Un poste deja en train d appliquer son image doit terminer avant une operation de maintenance du serveur.

## Si les logiciels sont absents apres Windows

Consulter `C:\ProgramData\AtelierPXE\result.json`, puis `software-logs/winget-preparation.log` et les journaux de chaque logiciel. Une fin de preparation ne doit pas masquer une installation non verifiee : IQ-4.6 affiche A verifier et les noms concernes. Si aucune case n etait cochee, aucune application n est installee. Extraire la revision courante et executer `scripts/Repair-Software.ps1` sur le PC en PowerShell administrateur pour reprendre uniquement la selection enregistree, sans redeployer Windows. Attendre la fin de toute preparation deja active.

La revision IQ-4.7 corrige l erreur `Argument WinGet non autorise.` due a la lecture du catalogue sous Windows PowerShell 5.1. Mettre a jour uniquement le serveur avec `Upgrade-Atelier4.ps1`, puis utiliser le nouveau WinPE pour les prochains deploiements. Sur une VM, le bundle HP permet d installer HPIA pour tester sa presence ; les pilotes et BIOS de vrais PC HP ne sont pas applicables au materiel virtuel.

## Apres la preparation IQ-4.8

Le dossier cache ProgramData/AtelierPXE est temporaire. Apres confirmation du rapport, des XML/CSV et des journaux sur le serveur, il est supprime automatiquement. Une coupure reseau ou un installateur encore actif reporte ce nettoyage ; aucun redemarrage n est force. Si un redemarrage est necessaire, le technicien le lance et le nettoyage reprend au demarrage suivant.

Les journaux sont telechargeables sur le site, dans Dossier inventaire, fichier Diagnostics-Deploiement.zip. Le dossier IQ_ et les logiciels installes restent sur le PC. Apres nettoyage, les raccourcis Rapports / Inventaire ouvrent les archives du serveur. Les nouveaux tests materiels ou garanties realises ensuite restent enregistres localement dans IQ_ ; ils ne sont pas renvoyes automatiquement sans le dossier de preparation.

## Controle HP / AnyDesk IQ-4.8.1

Le nouveau WinPE doit annoncer IQ-4.8.1. HPIA est un outil portable : ne pas chercher obligatoirement une application dans Parametres. Le lancer au besoin depuis Constructeur/HP-ImageAssistant.cmd dans IQ_. La preparation verifie son fichier signe dans Program Files avant de declarer sa presence. Le resultat des SoftPaq est indique separement dans le rapport.

AnyDesk officiel est reconnu par sa signature et son enregistrement Windows ou son service, meme si certaines informations de desinstallation manquent. Un fichier simplement telecharge ne suffit pas. Les erreurs de signature restent visibles. Pour un diagnostic sans commande sur le PC, ouvrir son activite sur le site puis Dossier inventaire et telecharger Diagnostics-Deploiement.zip. Les journaux ne sont disponibles sur .250 qu apres transmission reussie.

Pour valider le correctif, effectuer un deploiement de laboratoire avec Bundle HP puis verifier les applications, le lanceur HP, le resultat des SoftPaq dans le PDF et les XML/CSV/journaux sur .250. Redemarrer manuellement si le suivi le demande. Le cache prive est supprime seulement apres confirmation des archives et fin des installations. Un test en VM ne valide pas les pilotes ni le BIOS d un vrai HP.
