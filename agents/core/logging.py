"""Logging com rich. Substitui a UI no MVP — todos os demos rodam no terminal.

Decisão: NÃO usamos logging.basicConfig nem o módulo logging padrão como cidadão
de primeira classe. Em vez disso, retornamos uma instância de `rich.console.Console`
porque os demos vão querer tabelas, painéis e progress bars — coisas que `logging`
não oferece bem.

Para mensagens "system" (warning de erro de RPC, retry de tx) usamos o logger
nativo nivelado por env var LOG_LEVEL.
"""

from __future__ import annotations

import logging
import os

from rich.console import Console
from rich.logging import RichHandler


_HANDLER_INSTALLED = False


def build_logger(name: str) -> tuple[Console, logging.Logger]:
    """Cria um Console rich + logger nomeado integrados.

    O console é o que você usa para qualquer "narrativa" da demo (cabeçalhos,
    tabelas, ✓ / ✗ inline). O logger é para mensagens estruturadas de sistema.
    """
    global _HANDLER_INSTALLED
    console = Console()

    if not _HANDLER_INSTALLED:
        # Instala RichHandler uma única vez para todos os loggers do processo.
        # Idempotente: se chamarem build_logger() em dois agentes do mesmo demo,
        # não duplicamos handlers (causa #1 de log duplicado em apps Python).
        logging.basicConfig(
            level=os.environ.get("LOG_LEVEL", "INFO"),
            format="%(message)s",
            datefmt="[%X]",
            handlers=[RichHandler(console=console, rich_tracebacks=True, markup=True)],
        )
        _HANDLER_INSTALLED = True

    logger = logging.getLogger(name)
    return console, logger
