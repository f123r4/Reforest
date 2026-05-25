# ReForest+

Solução de rastreabilidade on-chain para projetos de reflorestamento.
Desenvolvida para o HackWeb Web3 — Desafio 3 (ImpactLedger).

---

## O problema

Doadores de reflorestamento não têm como saber se as árvores que financiaram existem, sobreviveram ou já foram derrubadas. Certificações voluntárias dependem de auditoria cara e infrequente.

## A solução

Cada projeto vive on-chain. O orçamento fica travado num contrato e é liberado em 4 etapas (M0 plantio → M6 → M12 → M36), condicionadas à aprovação de um oracle satelital que calcula a taxa de sobrevivência via NDVI (Sentinel-2). Se o projeto falha, doadores resgatam o saldo proporcional automaticamente.

Doadores recebem um **TreeNFT** (ERC-721) com GPS, espécie e data do plantio gravados on-chain — um certificado auditável e transferível.

---

## Stack

- Solidity 0.8.24 + OpenZeppelin — contratos
- Foundry — build, testes e deploy
- Python 3.11 + web3.py — agente oracle e demo
- Base Sepolia — testnet pública

---

## Contratos na Base Sepolia

| Contrato | Endereço |
|---|---|
| ReforestVault | `0xc445823A43c857438bCdA289e8d713DFC183B463` |
| TreeNFT | `0xDd7b07dd2684c4881Df7B1Ba450B69fbc1ddE848` |
| MockUSDC | `0x7D3f460251dd9d04481de14B04507697B2bA36d2` |

Código verificado em [sepolia.basescan.org](https://sepolia.basescan.org/address/0xc445823A43c857438bCdA289e8d713DFC183B463#code).

---

## Rodar localmente

```bash
cd reforest/

make setup      # cria .env com a chave de teste do Anvil
make install    # instala dependências Python
make build      # compila os contratos
make test       # 15 testes Foundry
make anvil      # sobe blockchain local
make deploy     # deploya os contratos
make demo       # demo ponta-a-ponta (M0 → M36 + refund)
```

Para rodar na Base Sepolia com carteiras reais:

```bash
make demo-testnet
```

Veja o [Guia do Avaliador](GUIA_AVALIADOR.md) para instruções completas, incluindo Windows (WSL2) e verificação no Basescan.

---

## Estrutura

```
contracts/reforest/     # ReforestVault.sol, TreeNFT.sol, testes
reforest/               # oracle NDVI, cliente Python, demo CLI
agents/                 # infraestrutura compartilhada (web3, config)
deploy/                 # addresses.json com endereços por rede
GUIA_AVALIADOR.md       # passo a passo para rodar e validar
```

---

## Testes

```
Ran 15 tests for contracts/reforest/ReforestVault.t.sol
Suite result: ok. 15 passed; 0 failed; 0 skipped
```

Cobertura: criação de projeto, doações com e sem NFT, milestones aprovados e reprovados, janela temporal, refund pro-rata, controle de acesso.
