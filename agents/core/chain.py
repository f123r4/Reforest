"""Helpers web3 — provider, nonce e ABI centralizados aqui."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from eth_account import Account
from eth_account.signers.local import LocalAccount
from web3 import Web3
from web3.contract import Contract
from web3.types import TxReceipt

from agents.core.config import AgentConfig


@dataclass
class ContractHandle:
    contract: Contract
    account: LocalAccount
    web3: Web3

    def call(self, function_name: str, *args: Any) -> Any:
        fn = getattr(self.contract.functions, function_name)
        return fn(*args).call()

    def send(
        self,
        function_name: str,
        *args: Any,
        wait: bool = True,
    ) -> TxReceipt | str:
        fn = getattr(self.contract.functions, function_name)
        nonce = self.web3.eth.get_transaction_count(self.account.address, "pending")
        estimated_gas = fn(*args).estimate_gas({"from": self.account.address})
        gas_with_margin = int(estimated_gas * 1.20)  # margem pra não dar out-of-gas

        tx = fn(*args).build_transaction(
            {
                "from": self.account.address,
                "nonce": nonce,
                "gas": gas_with_margin,
                "chainId": self.web3.eth.chain_id,
            }
        )
        signed = self.account.sign_transaction(tx)
        raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
        tx_hash = self.web3.eth.send_raw_transaction(raw)
        if not wait:
            return tx_hash.hex()
        receipt = self.web3.eth.wait_for_transaction_receipt(tx_hash)
        # na testnet o RPC às vezes retorna antes do bloco propagar
        if self.web3.eth.chain_id != 31337:
            confirmed = receipt["blockNumber"]
            while self.web3.eth.block_number < confirmed + 1:
                import time; time.sleep(1)
        return receipt


class ChainClient:
    def __init__(self, config: AgentConfig):
        self._config = config
        self.web3 = Web3(Web3.HTTPProvider(config.rpc_url, request_kwargs={"timeout": 30}))
        try:
            self.web3.eth.block_number
        except Exception:
            raise RuntimeError(f"Não consegui conectar ao RPC {config.rpc_url}")

    def account_from_key(self, private_key: str) -> LocalAccount:
        return Account.from_key(private_key)

    def load_contract(
        self,
        *,
        address: str,
        abi_artifact_path: Path | str,
        signer: LocalAccount,
    ) -> ContractHandle:
        path = Path(abi_artifact_path)
        artifact = json.loads(path.read_text())
        abi = artifact["abi"]
        contract = self.web3.eth.contract(
            address=Web3.to_checksum_address(address), abi=abi
        )
        return ContractHandle(contract=contract, account=signer, web3=self.web3)


def load_addresses(addresses_path: Path) -> dict[str, dict[str, str]]:
    """Lê deploy/addresses.json → {chain_id: {nome: endereço}}."""
    if not addresses_path.exists():
        return {}
    return json.loads(addresses_path.read_text())
