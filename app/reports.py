"""Rapports de déploiement bornés et imprimables, sans navigateur ni dépendance PDF."""
from typing import Literal
from app.text import inventory_label, status_label
import textwrap

from pydantic import BaseModel, ConfigDict, Field, model_validator


class ReportStep(BaseModel):
    model_config = ConfigDict(extra='forbid')
    name: str = Field(max_length=100)
    status: str = Field(max_length=40)
    message: str = Field(default='', max_length=1500)
    timestamp: str = Field(default='', max_length=50)


class ComputerReport(BaseModel):
    model_config = ConfigDict(extra='forbid')
    hostname: str = Field(pattern=r'^[A-Za-z][A-Za-z0-9-]{0,14}$')
    status: Literal['completed', 'needs_attention', 'failed']
    generated_at: str = Field(max_length=50)
    # Valeurs d’affichage nommées, sans environnement de processus ni clé de licence.
    inventory: dict[str, str] = Field(max_length=60)
    steps: list[ReportStep] = Field(max_length=250)
    warnings: list[str] = Field(default_factory=list, max_length=60)


class WindowsProgress(BaseModel):
    model_config = ConfigDict(extra='forbid')
    status: Literal['running', 'reboot_pending', 'retry_pending', 'completed', 'needs_attention', 'failed']
    progress: int = Field(ge=0, le=100)
    message: str = Field(min_length=1, max_length=1500)
    stage: Literal['hpia','software','iq','restart','summary'] | None = None
    stage_status: Literal['running','reboot_pending','completed','failed','needs_attention','skipped'] | None = None

    @model_validator(mode='after')
    def paired_stage(self):
        if (self.stage is None) != (self.stage_status is None):
            raise ValueError('L’étape et son état doivent être transmis ensemble')
        return self


def report_lines(report, events=()):
    yield 'ATELIER PXE - Rapport de déploiement'
    yield f"Poste : {report['hostname']} | État : {status_label(report['status'])}"
    yield f"Généré : {report['generated_at']}"
    yield ''
    yield 'INVENTAIRE'
    for label, value in report['inventory'].items():
        yield f'{inventory_label(label)} : {status_label(value)}'
    yield ''
    yield 'DÉROULEMENT'
    for step in report['steps']:
        yield f"{step.get('timestamp', '')} [{status_label(step['status'])}] {step['name']} : {step.get('message', '')}"
    if events:
        yield ''
        yield 'HISTORIQUE WINPE (CONSOLE)'
        for event in events:
            yield f"{event['created_at']} [{status_label(event['status'])}] {event['message']}"
    yield ''
    yield 'AVERTISSEMENTS ET LIMITES'
    yield from report.get('warnings', [])
    yield 'Les tests son, webcam et clavier exigent une vérification humaine.'
    yield 'Windows Update et Microsoft Store restent à effectuer manuellement.'


def make_pdf(lines):
    """PDF A4 multipage, Helvetica WinAnsi, texte échappé et références aux octets exacts."""
    wrapped = []
    for line in lines:
        clean = ''.join(c if ord(c) >= 32 else ' ' for c in str(line))
        wrapped.extend(textwrap.wrap(clean, 100, break_long_words=True) or [''])
    pages = [wrapped[i:i + 48] for i in range(0, len(wrapped), 48)] or [[]]
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>']
    page_ids = []
    for number, page in enumerate(pages, 1):
        page_id = len(objects) + 1
        page_ids.append(page_id)
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents {page_id + 1} 0 R >>'.encode())
        content = ['BT /F1 10 Tf 14 TL 40 800 Td']
        for line in [*page, f'Page {number}/{len(pages)}']:
            escaped = line.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')
            content.append(f'({escaped}) Tj T*')
        content.append('ET')
        stream = '\n'.join(content).encode('cp1252', 'replace')
        objects.append(f'<< /Length {len(stream)} >>\nstream\n'.encode() + stream + b'\nendstream')
    objects[1] = f"<< /Type /Pages /Count {len(pages)} /Kids [{' '.join(f'{i} 0 R' for i in page_ids)}] >>".encode()
    result = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for number, obj in enumerate(objects, 1):
        offsets.append(len(result))
        result.extend(f'{number} 0 obj\n'.encode() + obj + b'\nendobj\n')
    start = len(result)
    result.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]:
        result.extend(f'{offset:010d} 00000 n \n'.encode())
    result.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode())
    return bytes(result)
