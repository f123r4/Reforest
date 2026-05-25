"""Wrapper tipado sobre ReforestVault.sol e TreeNFT.sol."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from eth_account.signers.local import LocalAccount

from agents.core.chain import ChainClient, ContractHandle
from reforest.agent.ndvi_oracle import Milestone


_VAULT_ARTIFACT = "out/ReforestVault.sol/ReforestVault.json"
_NFT_ARTIFACT = "out/TreeNFT.sol/TreeNFT.json"


@dataclass(frozen=True)
class ProjectView:
    planter: str
    species: str
    planned_trees: int
    budget_total: int
    budget_raised: int
    budget_released: int
    planted_at: int


class ReforestVaultClient:
    def __init__(
        self,
        chain: ChainClient,
        contract_address: str,
        signer: LocalAccount,
        artifact_root: Path,
    ):
        self._handle: ContractHandle = chain.load_contract(
            address=contract_address,
            abi_artifact_path=artifact_root / _VAULT_ARTIFACT,
            signer=signer,
        )

    # ----- escrita -----
    def create_project(
        self,
        planter: str,
        geo_hash: bytes,
        species: str,
        gps_lat_e6: int,
        gps_lng_e6: int,
        planned_trees: int,
        budget_total: int,
    ) -> int:
        receipt = self._handle.send(
            "createProject",
            planter,
            geo_hash,
            species,
            gps_lat_e6,
            gps_lng_e6,
            planned_trees,
            budget_total,
        )
        events = self._handle.contract.events.ProjectCreated().process_receipt(receipt)  # type: ignore[arg-type]
        return int(events[0]["args"]["projectId"])

    def donate(self, project_id: int, amount: int, mint_nft: bool) -> int:
        receipt = self._handle.send("donate", project_id, amount, mint_nft)
        events = self._handle.contract.events.Donated().process_receipt(receipt)  # type: ignore[arg-type]
        if events:
            return int(events[0]["args"]["nftTokenId"])
        return 0

    def declare_planted(self, project_id: int) -> None:
        self._handle.send("declarePlanted", project_id)

    def report_milestone(
        self,
        project_id: int,
        milestone: Milestone,
        survival_bps: int,
        data_source_hash: bytes = b"\x00" * 32,
    ) -> None:
        self._handle.send("reportMilestone", project_id, int(milestone), survival_bps, data_source_hash)

    def refund(self, project_id: int) -> None:
        self._handle.send("refund", project_id)

    def grant_role(self, role_name: str, addr: str) -> None:
        role = self._handle.contract.functions[role_name]().call()
        self._handle.send("grantRoleByAdmin", role, addr)

    # ----- leitura -----
    def get_project(self, project_id: int) -> ProjectView:
        raw = self._handle.call("projects", project_id)
        return ProjectView(
            planter=str(raw[0]),
            species=str(raw[2]),
            planned_trees=int(raw[5]),
            budget_total=int(raw[6]),
            budget_raised=int(raw[7]),
            budget_released=int(raw[8]),
            planted_at=int(raw[9]),
        )

    def is_milestone_ready(self, project_id: int, milestone: Milestone) -> bool:
        return bool(self._handle.call("isMilestoneReady", project_id, int(milestone)))

    @property
    def address(self) -> str:
        return self._handle.contract.address


class TreeNftClient:
    def __init__(
        self,
        chain: ChainClient,
        contract_address: str,
        signer: LocalAccount,
        artifact_root: Path,
    ):
        self._handle: ContractHandle = chain.load_contract(
            address=contract_address,
            abi_artifact_path=artifact_root / _NFT_ARTIFACT,
            signer=signer,
        )

    def balance_of(self, addr: str) -> int:
        return int(self._handle.call("balanceOf", addr))

    def grant_minter(self, addr: str) -> None:
        role = self._handle.contract.functions.MINTER_ROLE().call()
        self._handle.send("grantRoleByAdmin", role, addr)

    @property
    def address(self) -> str:
        return self._handle.contract.address
