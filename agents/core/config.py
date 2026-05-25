"""Carregamento de configuração a partir do .env.

A premissa é: cada agente lê o ambiente UMA vez no boot, valida tipos com pydantic,
e a partir daí trabalha com um objeto imutável. Isso evita "magic getenv()" espalhado
pelo código, que é fonte clássica de bug em produção quando uma variável muda de nome.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


# Caminho do .env é resolvido a partir da raiz do repo, independente de onde o
# agente foi invocado. Isso permite rodar `python -m agents.lexproof.demo` de qualquer
# cwd sem quebrar.
# Procura em: raiz do repo e, como fallback, dentro de cada subprojeto.
_REPO_ROOT = Path(__file__).resolve().parents[2]
_ENV_PATH = next(
    (p for p in [_REPO_ROOT / ".env", _REPO_ROOT / "reforest" / ".env"] if p.exists()),
    _REPO_ROOT / ".env",  # caminho padrão para a mensagem de erro
)


@dataclass(frozen=True)
class AgentConfig:
    """Estado de configuração de um agente.

    Mantido propositalmente "magro": só o que é compartilhado entre todos os
    agentes. Configs específicas de cada trilha são struct dataclasses próprios
    nos módulos correspondentes (ex: agents.lexproof.config.LexProofConfig).
    """

    rpc_url: str
    chain_id: int
    deployer_private_key: str
    addresses_path: Path
    repo_root: Path

    @property
    def is_local(self) -> bool:
        """Indica se estamos rodando contra Anvil (decisões de UX dependem disso)."""
        return self.chain_id == 31_337


def load_config(*, prefer_local: bool = False) -> AgentConfig:
    """Lê o .env e devolve um AgentConfig validado.

    Args:
        prefer_local: se True, prioriza ANVIL_RPC_URL sobre BASE_SEPOLIA_RPC_URL.
            Útil para os demos que devem rodar local por padrão.
    """
    # load_dotenv é idempotente — chamar duas vezes não machuca, mas evitamos
    # silenciar logging se o .env não existir.
    if not _ENV_PATH.exists():
        raise RuntimeError(
            f".env não encontrado em {_ENV_PATH}. "
            "Copie .env.example para .env e preencha as variáveis."
        )
    load_dotenv(_ENV_PATH, override=False)

    if prefer_local:
        rpc_url = os.environ.get("ANVIL_RPC_URL", "http://127.0.0.1:8545")
        chain_id = int(os.environ.get("ANVIL_CHAIN_ID", "31337"))
    else:
        rpc_url = _require_env("BASE_SEPOLIA_RPC_URL")
        chain_id = int(os.environ.get("BASE_SEPOLIA_CHAIN_ID", "84532"))

    deployer_pk = _require_env("DEPLOYER_PRIVATE_KEY")
    if not deployer_pk.startswith("0x") or len(deployer_pk) != 66:
        raise ValueError(
            "DEPLOYER_PRIVATE_KEY deve ser uma chave hex de 32 bytes prefixada com 0x."
        )

    return AgentConfig(
        rpc_url=rpc_url,
        chain_id=chain_id,
        deployer_private_key=deployer_pk,
        addresses_path=_REPO_ROOT / "deploy" / "addresses.json",
        repo_root=_REPO_ROOT,
    )


def _require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Variável de ambiente obrigatória ausente: {name}")
    return value


def role_key(role: str, fallback_to_deployer: bool = True) -> str:
    """Devolve a chave privada de um papel funcional (ex: LEXPROOF_PARALEGAL_KEY).

    Em produção cada agente teria sua própria chave, com permissões granulares
    no contrato. Para o MVP, se a variável do papel estiver vazia, caímos para
    a DEPLOYER_PRIVATE_KEY — isso simplifica o demo sem comprometer o desenho
    de segurança (que segue intacto no contrato).
    """
    candidate = os.environ.get(role, "").strip()
    if candidate:
        return candidate
    if fallback_to_deployer:
        return _require_env("DEPLOYER_PRIVATE_KEY")
    raise RuntimeError(f"Chave do papel {role} não configurada.")
