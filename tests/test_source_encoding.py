"""Contrôles de livraison : UTF-8, typographie et français réellement affiché."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def source_files():
    names = set(subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True).splitlines())
    names.update(('AGENTS.md', '.editorconfig', 'docs/ENCODAGE.md', 'app/text.py', 'tests/test_utf8_transport.py'))
    return [ROOT / name for name in sorted(names) if not name.endswith('.png') and (ROOT / name).is_file()]


def test_all_text_is_strict_utf8_without_long_dashes_or_mojibake():
    forbidden = ('\u2013', '\u2014', '\ufffd', '\u00c3\u00a9', '\u00c3\u00a8',
                 '\u00c3\u00aa', '\u00c3\u00a0', '\u00c3\u00a7', '\u00c2\u00a0',
                 '\u00e2\u20ac\u2122', '\u00e2\u20ac\u0153', '\u00ef\u00bb\u00bf')
    for path in source_files():
        raw = path.read_bytes()
        text = raw.decode('utf-8-sig', errors='strict')
        assert not any(sequence in text for sequence in forbidden), path
        assert '\ufeff' not in text, path
        assert not re.search(r'\u00c3[\u0080-\u00bf]|\u00c2[\u0080-\u00bf]|[\u0080-\u009f]', text), path
        if path.suffix == '.ps1':
            assert raw.startswith(b'\xef\xbb\xbf'), path


def test_visible_french_and_windows_transport_keep_accents():
    html = (ROOT / 'app/static/index.html').read_text(encoding='utf-8')
    for phrase in ('Activité de déploiement', 'NUMÉRO DE SÉRIE', 'ÉTAT', 'Déconnexion'):
        assert phrase in html
    js = (ROOT / 'app/static/app.js').read_text(encoding='utf-8')
    for phrase in ('Image appliquée', 'Terminé', 'À vérifier', 'Prêt'):
        assert phrase in js
    menu = (ROOT / 'scripts/atelier.cmd').read_text(encoding='utf-8')
    assert 'chcp 65001 >nul' in menu and 'réseau' in menu
    build = (ROOT / 'scripts/Build-WinPE.ps1').read_text(encoding='utf-8-sig')
    assert '$recoveryMenu -Encoding ASCII' not in build
    for name in ('Prepare-IQTools.ps1', 'Finalization.ps1'):
        text = (ROOT / 'scripts' / name).read_text(encoding='utf-8-sig')
        assert "'Lisez-moi.txt') -Encoding ASCII" not in text


def test_maintenance_display_text_is_accented_without_changing_markup():
    text = (ROOT / 'app/static/maintenance.js').read_text(encoding='utf-8')
    for phrase in ('Suivi actualisé', 'préparation des nouveaux postes', 'Comparé au passage',
                   'CORRECTIFS INTÉGRÉS', 'durées détaillées', 'Déjà observé'):
        assert phrase in text
    assert '<details' in text and '<détails' not in text
    assert 'rôle=' not in text
