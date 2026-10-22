"""Libellés français, sans renommer les identifiants des rapports historiques."""
INVENTORY_LABELS = {
    'Modele': 'Modèle', 'Numero de serie': 'Numéro de série',
    'Revision preparation': 'Révision de préparation',
    'Numero de serie WinPE': 'Numéro de série WinPE', 'Reseau': 'Réseau',
    'Edition Windows': 'Édition Windows', 'Demarrage rapide Windows': 'Démarrage rapide Windows',
    'Profil deploye': 'Profil déployé', 'Garantie debut / fin': 'Garantie début / fin',
}
STATUS_LABELS = {
    'completed': 'Terminé', 'failed': 'Échec', 'needs_attention': 'À vérifier',
    'running': 'En cours', 'staged': 'Image appliquée', 'queued': 'En attente',
    'manual': 'Manuel', 'skipped': 'Non applicable', 'unknown': 'Inconnu',
    'passed': 'Conforme', 'not_tested': 'Non testé', 'reboot_pending': 'Redémarrage prévu',
    'retry_pending': 'Nouvelle tentative prévue', 'deferred': 'Reporté',
    'ACTIVE': 'Activée', 'NON ACTIVE': 'Non activée', 'INDETERMINE': 'Indéterminé',
    'non_verifie': 'Non vérifié', 'active_confirmee_operateur': 'Active, confirmée par le technicien',
    'expiree_confirmee_operateur': 'Expirée, confirmée par le technicien',
}


def inventory_label(value):
    return INVENTORY_LABELS.get(value, value)


def status_label(value):
    return STATUS_LABELS.get(value, value)
