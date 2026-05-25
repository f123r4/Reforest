"""Wrappers tipados sobre DonorDAOTreasury.sol + MockUSDC.sol."""

from __future__ import annotations

from pathlib import Path

from eth_account.signers.local import LocalAccount

from agents.core.chain import ChainClient, ContractHandle


_DAO_ARTIFACT = "out/DonorDAOTreasury.sol/DonorDAOTreasury.json"
_USDC_ARTIFACT = "out/MockUSDC.sol/MockUSDC.json"


class UsdcClient:
    def __init__(self, chain: ChainClient, contract_address: str, signer: LocalAccount, artifact_root: Path):
        self._handle: ContractHandle = chain.load_contract(
            address=contract_address,
            abi_artifact_path=artifact_root / _USDC_ARTIFACT,
            signer=signer,
        )

    def balance_of(self, addr: str) -> int:
        return int(self._handle.call("balanceOf", addr))

    def mint(self, to: str, amount: int) -> None:
        self._handle.send("mint", to, amount)

    def approve(self, spender: str, amount: int) -> None:
        self._handle.send("approve", spender, amount)


class DonorDAOClient:
    def __init__(self, chain: ChainClient, contract_address: str, signer: LocalAccount, artifact_root: Path):
        self._handle: ContractHandle = chain.load_contract(
            address=contract_address,
            abi_artifact_path=artifact_root / _DAO_ARTIFACT,
            signer=signer,
        )

    # ---------- Admin ----------

    def grant_ngo(self, addr: str) -> None:
        role = self._handle.contract.functions.NGO_ROLE().call()
        self._handle.send("grantRoleByAdmin", role, addr)

    # ---------- Donor ----------

    def deposit(self, amount: int) -> None:
        self._handle.send("deposit", amount)

    def withdraw(self, amount: int) -> None:
        self._handle.send("withdraw", amount)

    # ---------- NGO ----------

    def submit_proposal(self, title: str, details_hash: bytes, amount: int) -> int:
        receipt = self._handle.send("submitProposal", title, details_hash, amount)
        events = self._handle.contract.events.ProposalSubmitted().process_receipt(receipt)  # type: ignore[arg-type]
        return int(events[0]["args"]["proposalId"])

    # ---------- Vote / execute ----------

    def vote(self, proposal_id: int, support: bool) -> None:
        self._handle.send("vote", proposal_id, support)

    def execute(self, proposal_id: int) -> tuple[int, int]:
        receipt = self._handle.send("execute", proposal_id)
        events = self._handle.contract.events.ProposalExecuted().process_receipt(receipt)  # type: ignore[arg-type]
        status = int(events[0]["args"]["status"])
        transferred = int(events[0]["args"]["transferred"])
        return status, transferred

    # ---------- Views ----------

    def member(self, addr: str) -> tuple[int, int]:
        contrib, open_votes = self._handle.call("members", addr)
        return int(contrib), int(open_votes)

    def proposal(self, pid: int) -> dict:
        (
            ngo, details, title, amount, voting_ends,
            yes_votes, no_votes, status, exists,
        ) = self._handle.call("proposals", pid)
        return {
            "ngo": ngo,
            "details_hash": details,
            "title": title,
            "amount": int(amount),
            "voting_ends": int(voting_ends),
            "yes": int(yes_votes),
            "no": int(no_votes),
            "status": int(status),
            "exists": bool(exists),
        }

    def total_contributed(self) -> int:
        return int(self._handle.call("totalContributed"))

    def quorum_required(self) -> int:
        return int(self._handle.call("quorumRequired"))

    @property
    def address(self) -> str:
        return self._handle.contract.address
