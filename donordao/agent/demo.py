"""Demo CLI ponta-a-ponta do DonorDAO.

Roteiro:
  1. Setup — concede NGO_ROLE para 2 ONGs. Funda 3 doadores com USDC.
  2. Doadores depositam (alice 50k, bob 30k, carol 20k = 100k USDC na treasury).
  3. ONG1 submete proposta "Alfabetização Adultos" (25k USDC).
  4. Votação: alice yes, bob yes, carol no → 80k yes, 20k no, quorum OK.
  5. Fast-forward 7 dias. Qualquer um executa → APROVADA, 25k vai para ONG1.
  6. ONG2 submete proposta "Plantio Urbano" (40k USDC).
  7. Votação: só carol vota yes (20k) → quorum 30% (=22,5k) NÃO atingido.
  8. Execute → REJEITADA.
  9. Mostra saldo final da treasury, ONGs, contadores cumulativos.
"""

from __future__ import annotations

from hashlib import sha256
from pathlib import Path

import typer
from rich.table import Table

from agents.core import build_logger, load_addresses, load_config
from agents.core.chain import ChainClient
from donordao.agent.registry import DonorDAOClient, UsdcClient


_ANVIL_NGO1 = "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"
_ANVIL_NGO2 = "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e"
_ANVIL_ALICE = "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356"
_ANVIL_BOB = "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97"
_ANVIL_CAROL = "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6"

_STATUS_LABEL = {0: "PENDENTE", 1: "APROVADA", 2: "REJEITADA"}

app = typer.Typer(add_completion=False, help="DonorDAO — demo ponta-a-ponta")


@app.command()
def main(use_local: bool = typer.Option(True, "--local/--remote")):
    console, _ = build_logger("donordao.demo")
    console.rule("[bold magenta]DonorDAO — Captação Coletiva Governada")

    config = load_config(prefer_local=use_local)
    chain = ChainClient(config)
    addrs = load_addresses(config.addresses_path).get(str(config.chain_id), {})
    dao_addr = addrs.get("DonorDAOTreasury")
    usdc_addr = addrs.get("MockUSDC")
    if not (dao_addr and usdc_addr):
        console.print("[red]DonorDAOTreasury ou MockUSDC ausente em addresses.json[/red]")
        raise typer.Exit(1)

    deployer = chain.account_from_key(config.deployer_private_key)
    ngo1 = chain.account_from_key(_ANVIL_NGO1)
    ngo2 = chain.account_from_key(_ANVIL_NGO2)
    alice = chain.account_from_key(_ANVIL_ALICE)
    bob = chain.account_from_key(_ANVIL_BOB)
    carol = chain.account_from_key(_ANVIL_CAROL)

    admin_client = DonorDAOClient(chain, dao_addr, deployer, config.repo_root)
    usdc_admin = UsdcClient(chain, usdc_addr, deployer, config.repo_root)

    console.print(f"deployer (admin): {deployer.address}")
    console.print(f"ngo1:  {ngo1.address}")
    console.print(f"ngo2:  {ngo2.address}")
    console.print(f"alice: {alice.address}")
    console.print(f"bob:   {bob.address}")
    console.print(f"carol: {carol.address}\n")

    # ----- Setup -----
    console.rule("Setup — papéis e funding")
    for ngo in (ngo1, ngo2):
        try:
            admin_client.grant_ngo(ngo.address)
        except Exception:
            pass
    console.print("[dim]  ✓ NGO_ROLE concedido às 2 ONGs[/dim]")

    # Mint USDC para os doadores + ETH para gas (Anvil já tem) + approve.
    K = 1_000_000
    contributions = [(alice, 50_000 * K), (bob, 30_000 * K), (carol, 20_000 * K)]
    for donor, amount in contributions:
        # Mint usdc
        usdc_admin.mint(donor.address, amount * 2)  # com folga
        # Approve via signer do próprio doador
        donor_usdc = UsdcClient(chain, usdc_addr, donor, config.repo_root)
        donor_usdc.approve(dao_addr, amount * 10)
    console.print("[dim]  ✓ doadores fundados e approve ok[/dim]\n")

    # ----- Depósitos -----
    console.rule("Etapa 1 — Doadores depositam na treasury")
    for donor, amount in contributions:
        donor_client = DonorDAOClient(chain, dao_addr, donor, config.repo_root)
        donor_client.deposit(amount)
        console.print(f"  ✓ {donor.address[:8]}…  +{amount/K:>6.0f} USDC")
    console.print(
        f"\n  total contribuído: {admin_client.total_contributed()/K:,.0f} USDC\n"
        f"  quorum atual:     {admin_client.quorum_required()/K:,.0f} USDC (30%)"
    )

    # ----- Proposta 1: aprovada -----
    console.rule("Etapa 2 — Proposta 1 (ONG1 — Alfabetização Adultos)")
    ngo1_client = DonorDAOClient(chain, dao_addr, ngo1, config.repo_root)
    pid1 = ngo1_client.submit_proposal(
        "Alfabetizacao Adultos Periferia",
        sha256(b"ipfs://QmAlfabetizacao2026Q1-detalhes-completos.pdf").digest(),
        25_000 * K,
    )
    console.print(f"  proposta #{pid1} submetida: 25.000 USDC solicitados, janela 7 dias")
    console.print("  votos:")
    DonorDAOClient(chain, dao_addr, alice, config.repo_root).vote(pid1, True)
    console.print("    alice: YES (peso 50.000)")
    DonorDAOClient(chain, dao_addr, bob, config.repo_root).vote(pid1, True)
    console.print("    bob:   YES (peso 30.000)")
    DonorDAOClient(chain, dao_addr, carol, config.repo_root).vote(pid1, False)
    console.print("    carol: NO  (peso 20.000)")

    chain.web3.provider.make_request("evm_increaseTime", [7 * 86400 + 1])
    chain.web3.provider.make_request("evm_mine", [])

    status, transferred = admin_client.execute(pid1)
    console.print(
        f"  [bold]execute → {_STATUS_LABEL[status]}[/bold]  "
        f"transferido: {transferred/K:,.0f} USDC para ONG1"
    )

    # ----- Proposta 2: rejeitada por quorum -----
    console.rule("Etapa 3 — Proposta 2 (ONG2 — Plantio Urbano)")
    ngo2_client = DonorDAOClient(chain, dao_addr, ngo2, config.repo_root)
    pid2 = ngo2_client.submit_proposal(
        "Plantio Urbano Av. Brasil",
        sha256(b"ipfs://QmPlantioUrbano2026-plano-execucao.pdf").digest(),
        40_000 * K,
    )
    console.print(f"  proposta #{pid2} submetida: 40.000 USDC solicitados")
    console.print("  votos:")
    DonorDAOClient(chain, dao_addr, carol, config.repo_root).vote(pid2, True)
    console.print("    carol: YES (peso 20.000)  — único voto, quorum 22.500 NÃO atingido")

    chain.web3.provider.make_request("evm_increaseTime", [7 * 86400 + 1])
    chain.web3.provider.make_request("evm_mine", [])

    status, transferred = admin_client.execute(pid2)
    console.print(
        f"  [bold]execute → {_STATUS_LABEL[status]}[/bold]  "
        f"transferido: {transferred/K:,.0f} USDC"
    )

    # ----- Tabela final -----
    console.rule("Etapa 4 — Estado final")
    treasury_now = int(admin_client._handle.contract.functions.availableBalance().call())
    table = Table(title="Balanços finais")
    table.add_column("Conta", style="cyan")
    table.add_column("USDC", justify="right", style="bold green")
    table.add_row("Treasury", f"{treasury_now/K:,.0f}")
    table.add_row("ONG1", f"{usdc_admin.balance_of(ngo1.address)/K:,.0f}")
    table.add_row("ONG2", f"{usdc_admin.balance_of(ngo2.address)/K:,.0f}")
    for donor, _ in contributions:
        m_contrib, _ = admin_client.member(donor.address)
        table.add_row(
            f"{donor.address[:8]}… (saldo treasury)", f"{m_contrib/K:,.0f}"
        )
    console.print(table)

    console.rule("Demo concluído")


if __name__ == "__main__":
    app()
