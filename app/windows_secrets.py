"""Lecture du secret DPAPI local au serveur, exclu des catalogues et des WIM."""
import base64
import ctypes
import json
import os
from ctypes import wintypes


def read_share_credentials(path):
    if os.name != 'nt':
        raise RuntimeError('Le secret du partage exige le serveur Windows')
    saved = json.loads(path.read_text(encoding='utf-8-sig'))

    class Blob(ctypes.Structure):
        _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]

    encrypted = base64.b64decode(saved['password_dpapi'], validate=True)
    buffer = (ctypes.c_ubyte * len(encrypted)).from_buffer_copy(encrypted)
    source, target = Blob(len(encrypted), buffer), Blob()
    crypt = ctypes.WinDLL('crypt32', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    crypt.CryptUnprotectData.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                                        ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    crypt.CryptUnprotectData.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    if not crypt.CryptUnprotectData(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        password = ctypes.string_at(target.data, target.size).decode('utf-8')
        return {'username': saved['username'], 'password': password}
    finally:
        ctypes.memset(target.data, 0, target.size)
        kernel.LocalFree(target.data)
