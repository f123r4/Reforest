"""SDK comum dos agentes.

Tudo que é reaproveitável entre os 6 projetos vive aqui: cliente web3, signer,
logging com rich, leitura de endereços de contrato, helpers de hash.

Se uma função vai ser usada por dois ou mais projetos, ela mora aqui. Se é
específica de uma trilha, fica no módulo da trilha.
"""

from agents.core.chain import ChainClient, ContractHandle, load_addresses
from agents.core.config import AgentConfig, load_config
from agents.core.hashing import file_sha256, bytes_sha256
from agents.core.logging import build_logger

__all__ = [
    "AgentConfig",
    "ChainClient",
    "ContractHandle",
    "bytes_sha256",
    "build_logger",
    "file_sha256",
    "load_addresses",
    "load_config",
]
