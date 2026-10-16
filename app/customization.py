"""Validated installation settings and catalogue metadata shared by the API."""
from typing import Literal
import re

from pydantic import BaseModel, ConfigDict, Field, field_validator


KEYBOARDS = [
    {'id': '040c:0000040c', 'name': 'Français — AZERTY'},
    {'id': '080c:0000080c', 'name': 'Français — Belgique'},
    {'id': '100c:0000100c', 'name': 'Français — Suisse'},
    {'id': '0409:00000409', 'name': 'Anglais — États-Unis'},
    {'id': '0809:00000809', 'name': 'Anglais — Royaume-Uni'},
    {'id': '0407:00000407', 'name': 'Allemand — Allemagne'},
]
TIMEZONES = [
    {'id': 'Romance Standard Time', 'name': 'Paris / Bruxelles / Madrid'},
    {'id': 'W. Europe Standard Time', 'name': 'Zurich / Berlin / Rome'},
    {'id': 'GMT Standard Time', 'name': 'Londres / Lisbonne'},
    {'id': 'UTC', 'name': 'UTC'},
    {'id': 'Eastern Standard Time', 'name': 'Montréal / New York'},
    {'id': 'Pacific Standard Time', 'name': 'Vancouver / Los Angeles'},
    {'id': 'Arabian Standard Time', 'name': 'Dubaï'},
    {'id': 'Tokyo Standard Time', 'name': 'Tokyo'},
]
REGIONS = [{'id': x, 'name': x} for x in ['fr-FR', 'fr-BE', 'fr-CH', 'en-US', 'en-GB', 'de-DE']]
SOFTWARE_PACKAGES = [{'id': 'vlc', 'name': 'VLC'}, {'id': 'reader', 'name': 'Adobe Reader'},
                     {'id': 'chrome', 'name': 'Google Chrome'}, {'id': 'anydesk', 'name': 'AnyDesk'}]
OPTIONS = {'software_packages': SOFTWARE_PACKAGES, 'keyboards': KEYBOARDS, 'timezones': TIMEZONES, 'regions': REGIONS,
           'themes': [{'id': 'unchanged', 'name': 'Conserver le thème Windows'},
                      {'id': 'light', 'name': 'Clair'}, {'id': 'dark', 'name': 'Sombre'}]}


def defaults_for_locale(locale):
    keyboard = {'fr-FR': '040c:0000040c', 'fr-BE': '080c:0000080c', 'fr-CH': '100c:0000100c',
                'en-US': '0409:00000409', 'en-GB': '0809:00000809', 'de-DE': '0407:00000407'}.get(locale, '0409:00000409')
    return Personalization(keyboard=keyboard, user_locale=locale).model_dump()


class Personalization(BaseModel):
    model_config = ConfigDict(extra='forbid')
    keyboard: str = '040c:0000040c'
    timezone: str = 'Romance Standard Time'
    user_locale: str = Field(default='fr-FR', pattern=r'^[a-z]{2}-[A-Z]{2}$')
    registered_owner: str = Field(default='', max_length=80)
    organization: str = Field(default='', max_length=80)
    theme: Literal['unchanged', 'light', 'dark'] = 'unchanged'
    wallpaper_asset_id: str | None = None
    application_ids: list[str] = Field(default_factory=list, max_length=50)
    bundle_ids: list[str] = Field(default_factory=list, max_length=20)
    central_inventory: bool = False
    software_mode: Literal['catalogue', 'winget'] = 'catalogue'
    winget_packages: list[Literal['vlc', 'reader', 'chrome', 'anydesk']] = Field(default_factory=lambda: ['vlc', 'reader', 'chrome', 'anydesk'], max_length=4)
    unattended: bool = False
    windows_update: bool = False
    store_update: bool = False

    @field_validator('keyboard')
    @classmethod
    def keyboard_supported(cls, value):
        if value not in {x['id'] for x in KEYBOARDS}:
            raise ValueError('Clavier non pris en charge')
        return value

    @field_validator('timezone')
    @classmethod
    def timezone_supported(cls, value):
        if value not in {x['id'] for x in TIMEZONES}:
            raise ValueError('Fuseau horaire non pris en charge')
        return value

    @field_validator('registered_owner', 'organization')
    @classmethod
    def printable(cls, value):
        if any(ord(c) < 32 for c in value):
            raise ValueError('Caractères de contrôle interdits')
        return value

    @field_validator('application_ids', 'bundle_ids', 'winget_packages')
    @classmethod
    def unique_ids(cls, value):
        if len(value) != len(set(value)):
            raise ValueError('Sélection dupliquée')
        return value


class ApplicationInput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    name: str = Field(min_length=1, max_length=80)
    version: str = Field(default='', max_length=40)
    asset_id: str
    arguments: str = Field(default='', max_length=1024)
    entry_point: str = Field(default='', max_length=160)
    install_mode: Literal['install', 'portable'] = 'install'
    manufacturer: Literal['all', 'hp', 'lenovo'] = 'all'

    @field_validator('arguments', 'name', 'version')
    @classmethod
    def printable(cls, value):
        if any(ord(c) < 32 for c in value):
            raise ValueError('Caractères de contrôle interdits')
        return value

    @field_validator('entry_point')
    @classmethod
    def safe_entry(cls, value):
        if value and (not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]*\.(exe|msi)', value, re.I)
                      or any(part in {'', '.', '..'} for part in value.split('/'))):
            raise ValueError('Indiquez un chemin relatif .exe/.msi dans le ZIP, sans traversée de dossier')
        return value


class BundleInput(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    description: str = Field(default='', max_length=240)
    application_ids: list[str] = Field(min_length=1, max_length=50)

    @field_validator('application_ids')
    @classmethod
    def unique(cls, value):
        if len(value) != len(set(value)):
            raise ValueError('Logiciel dupliqué dans le bundle')
        return value


class WizardSelection(BaseModel):
    model_config = ConfigDict(extra='forbid')
    profile_id: str
    hostname: str = Field(pattern=r'^[A-Za-z][A-Za-z0-9-]{0,14}$')
    settings: Personalization
    disk_number: int | None = Field(default=None, ge=0, le=32)


class BootConnection(BaseModel):
    code: str = Field(min_length=16, max_length=24)
    macs: list[str] = Field(min_length=1, max_length=16)


class BootDiscovery(BaseModel):
    release: str = Field(default='', max_length=40)
    macs: list[str] = Field(min_length=1, max_length=16)
