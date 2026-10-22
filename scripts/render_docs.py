"""Génération des guides du dépôt avec la seule bibliothèque standard Python."""
from html import escape
import hashlib
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def inline(text):
    text = escape(text)
    text = re.sub(r'`([^`]+)`', r'<code>\1</code>', text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', text)
    return re.sub(r'\[([^]]+)\]\(([^)]+)\)',
                  lambda m: f'<a href="{escape(m[2], quote=True)}">{m[1]}</a>'
                  if re.fullmatch(r'(?:[A-Za-z0-9._/-]+(?:#[A-Za-z0-9-]+)?|https://[A-Za-z0-9./_?#=%&;+-]+)', m[2]) else m[1], text)


def render(source):
    out = []; code = []; table = False; listing = None; in_code = False
    for line in source.splitlines() + ['']:
        if line.startswith('```'):
            if in_code:
                out.append('<pre><code>' + escape('\n'.join(code)) + '</code></pre>'); code = []
            in_code = not in_code
            continue
        if in_code:
            code.append(line); continue
        if not line.startswith('|') and table:
            out.append('</tbody></table></div>'); table = False
        match = re.match(r'^(\d+\. |[-*] )(.*)', line)
        kind = ('ol' if match[1][0].isdigit() else 'ul') if match else None
        if listing and kind != listing:
            out.append(f'</{listing}>'); listing = None
        if match:
            if not listing:
                listing = kind; out.append(f'<{kind}>')
            out.append('<li>' + inline(match[2]) + '</li>')
        elif line.startswith('|'):
            cells = [c.strip() for c in line.strip('|').split('|')]
            if all(re.fullmatch(r'[-: ]+', c) for c in cells):
                continue
            if not table:
                out.append('<div class="table"><table><thead><tr>' + ''.join('<th>'+inline(c)+'</th>' for c in cells) + '</tr></thead><tbody>'); table=True
            else:
                out.append('<tr>' + ''.join('<td>'+inline(c)+'</td>' for c in cells) + '</tr>')
        elif line.startswith('#'):
            heading = re.match(r'^(#{1,6}) (.*)', line)
            if heading:
                n=len(heading[1]); out.append(f'<h{n}>'+inline(heading[2])+f'</h{n}>')
        elif line:
            out.append('<p>' + inline(line) + '</p>')
    return '\n'.join(out)


if __name__ == '__main__':
    for filename, destination in [('GUIDE-UTILISATEUR.md','guide.html'), ('MISE-A-JOUR-ATELIER-2.md','upgrade.html'), ('LOGICIELS-AUTOMATIQUES.md','software-guide.html'), ('ATELIER-3.md','atelier3.html'), ('ATELIER-4.md','atelier4.html'), ('MAINTENANCE-IMAGES-WINDOWS.md','windows-image-maintenance.html'), ('CORRECTIFS-WINDOWS.md','windows-kb.html'), ('VALIDATION-DEPLOIEMENT.md','deployment-validation.html')]:
        body=render((ROOT/'docs'/filename).read_text(encoding='utf-8'))
        body=body.replace('href="CORRECTIFS-WINDOWS.md"','href="/static/windows-kb.html"')
        body=body.replace('href="ATELIER-4.md"','href="/static/atelier4.html"')
        body=body.replace('href="MAINTENANCE-IMAGES-WINDOWS.md"','href="/static/windows-image-maintenance.html"')
        body=body.replace('href="VALIDATION-DEPLOIEMENT.md"','href="/static/deployment-validation.html"')
        body=body.replace('href="ATELIER-3.md"','href="/static/atelier3.html"')
        body=body.replace('href="LOGICIELS-AUTOMATIQUES.md"','href="/static/software-guide.html"')
        body=body.replace('href="MISE-A-JOUR-ATELIER-2.md"','href="/static/upgrade.html"').replace('href="GUIDE-UTILISATEUR.md"','href="/static/guide.html"')
        body=re.sub(r'href="([A-Z][A-Z0-9-]+\.md(?:#[a-z0-9-]+)?)"', r'href="https://github.com/erik-iq/mdt-serveur/blob/main/docs/\1"', body)
        html='<!doctype html><html lang="fr"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Atelier PXE - Documentation</title><link rel="stylesheet" href="/static/guide.css"><body><nav><a href="/">Console Atelier</a> | <a href="/static/guide.html">Guide utilisateur</a> | <a href="/static/atelier4.html">Mise à jour</a><img class="brand-logo" src="/static/brand-logo.png" width="40" height="40" alt="IQ"></nav><main>'+body+'</main></body></html>'
        for asset_name in ('guide.css','brand-logo.png'):
            asset_path=ROOT/'app'/'static'/asset_name
            fingerprint=hashlib.sha256(asset_path.read_bytes()).hexdigest()[:16]
            original='/static/'+asset_name
            html=html.replace('"'+original+'"','"'+original+'?v='+fingerprint+'"')
        (ROOT/'app'/'static'/destination).write_text(html, encoding='utf-8')
