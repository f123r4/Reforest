"""Helpers de hash. Mantemos centralizado para evitar inconsistência entre projetos.

Importante: usamos SHA-256 do conteúdo cru (bytes) — não do filename, nem do path,
nem com metadata "envolvendo". Isso garante que o mesmo arquivo binário gera o
mesmo hash em qualquer máquina, e que a verificação off-chain (re-hash do arquivo
original e comparação com o registro on-chain) é trivial para qualquer auditor.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

# Lemos em chunks para não estourar memória com arquivos grandes (ex: scans de
# processos de várias centenas de MB). 1 MiB é o sweet spot entre syscalls e RAM.
_CHUNK = 1024 * 1024


def file_sha256(path: Path | str) -> bytes:
    """Hash SHA-256 do conteúdo do arquivo. Devolve 32 bytes brutos.

    Bytes (em vez de hex string) porque o contrato Solidity recebe `bytes32` —
    e é mais barato em gas passar 32 bytes do que fazer encode/decode na chain.
    """
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        while chunk := fh.read(_CHUNK):
            digest.update(chunk)
    return digest.digest()


def bytes_sha256(data: bytes) -> bytes:
    """Hash SHA-256 de bytes em memória."""
    return hashlib.sha256(data).digest()
