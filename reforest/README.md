# ReForest+ — DAO de Reflorestamento com Fiscal Satelital

> Trilha 3 — ImpactLedger · Status: MVP funcional, 15 testes Foundry verdes

## 🎯 O problema

Greenwashing destrói a credibilidade do mercado de créditos de carbono e
reflorestamento. Doador paga por 1.000 árvores e nunca sabe se elas existem,
se sobreviveram, ou se já foram cortadas dois anos depois. As certificações
voluntárias dependem de auditoria humana cara e infrequente, com escândalos
recorrentes (Verra, Gold Standard).

## 💡 A solução

Cada projeto de reflorestamento é um ativo on-chain (`Project`) com:
- plantador (`planter`) — quem vai a campo
- polígono (`geoHash`) — área a ser plantada
- orçamento total + variedade + quantidade de árvores

Doadores depositam USDC; **opcionalmente recebem um TreeNFT** (ERC-721) como
certificado de impacto, que carrega metadata rica on-chain (GPS, espécie,
projeto, data). NFT é transferível — é o "carbon credit ancestor", pode ser
revendido no futuro enquanto a árvore segue plantada.

**Orçamento liberado em 4 milestones** — payouts milestone-locked com fiscal
satelital. Em cada milestone (M0 plantio, M6, M12, M36), o oráculo geo calcula
NDVI dentro do polígono e atesta a taxa de sobrevivência. Threshold: **75%**.
Acima disso, a fatia daquele milestone é liberada para o plantador. Abaixo,
fica no cofre — e ao final, doadores resgatam pro-rata.

| Milestone | Quando | % do orçamento |
|---|---|---|
| M0 | Plantio | 10% |
| M6 | 6 meses depois | 30% |
| M12 | 1 ano depois | 30% |
| M36 | 3 anos depois | 30% |

**Proposta de valor:** doação rastreável até a árvore individual. Plantador
honesto ganha mais por reputação. Mercado para de financiar fraude.

## 🧱 Arquitetura

```
   Sentinel-2 / MapBiomas / Planet
   ┌──────────────────────────────┐
   │ Leituras NDVI (mock CSV MVP) │
   └──────────────┬───────────────┘
                  │ poll
                  ▼
   ┌──────────────────────────┐                ┌─────────────────────┐
   │ Worker Oracle Geo        │──reportM(...)─▶│ ReforestVault.sol   │
   │ • cruza polígono+NDVI    │                │ • Projects          │
   │ • survival rate em bps   │                │ • Donations         │
   └──────────────────────────┘                │ • Milestone payouts │
                                               │ • Refund pro-rata   │
   ┌──────────────────────────┐                └──────────┬──────────┘
   │ Doador (USDC wallet)     │──donate()────────────────▶│
   │ • opt-in NFT             │                           │
   └──────────────────────────┘                           │
                                                          │ mintTree()
                                                          ▼
                                          ┌─────────────────────────┐
                                          │ TreeNFT.sol (ERC-721)   │
                                          │ • metadata GPS+espécie  │
                                          │ • transferível          │
                                          └─────────────────────────┘
```

### Atores e papéis on-chain

| Papel | Quem encarna | O que pode fazer |
|---|---|---|
| `ADMIN_ROLE` (Vault+NFT) | DAO multisig em prod (deployer no MVP) | `createProject`, gerenciar papéis |
| `GEO_ORACLE_ROLE` (Vault) | Worker Python (satélite) | `reportMilestone` (com survival rate) |
| `MINTER_ROLE` (NFT) | Vault contract | `mintTree` (chamado por `donate(true)`) |
| (`onlyPlanter`) | Plantador do projeto | `declarePlanted` (marca timestamp do plantio) |
| (sem papel) | Qualquer doador | `donate`, `refund` (após M36 resolvido) |

### Defesas embutidas

- **Janela temporal por milestone:** oracle não pode reportar M36 logo após o
  plantio. M6 só após 180 dias, M12 só após 365 dias, M36 só após 1095 dias.
- **`declarePlanted` é gate.** Sem ele, M0..M36 não progridem. Defesa contra
  projeto "fantasma" que recebeu doação mas nunca foi a campo.
- **Mint NFT só pelo Vault.** Evita certificados "fantasma" sem doação real.
- **Refund pro-rata + CEI pattern.** Doador resgata sua fatia da parte não
  liberada, proporcional à sua contribuição. Estado zerado antes da transferência
  (defesa contra reentrância de token hostil).
- **Survival cap em 100% (10_000 bps).** Defesa contra erro do oracle
  (digitar 10001).

## 📂 Estrutura

```
contracts/reforest/
├── ReforestVault.sol           # contrato principal (DAO + escrow + milestones)
├── TreeNFT.sol                 # ERC-721 dos certificados (metadata on-chain)
└── ReforestVault.t.sol         # 15 testes (incl. refund pro-rata multi-doador)

reforest/
├── agent/
│   ├── ndvi_oracle.py          # NdviReading + loader CSV (scene_id → dataSourceHash)
│   ├── registry.py             # ReforestVaultClient + TreeNftClient
│   └── demo.py                 # CLI ponta-a-ponta com fast-forward
└── fixtures/
    └── ndvi_readings.csv       # 6 leituras: projeto #1 saudável, projeto #2 estiagem
```

## 🧠 Contratos — funções principais

### `ReforestVault`
```solidity
function createProject(
    address planter, bytes32 geoHash, string calldata species,
    int256 gpsLatE6, int256 gpsLngE6,
    uint32 plannedTrees, uint128 budgetTotal
) external onlyRole(ADMIN_ROLE) returns (uint256 projectId);

function donate(uint256 projectId, uint128 amount, bool mintNft)
    external nonReentrant;
    // ↑ se mintNft=true, dispara TreeNFT.mintTree na carteira do doador

function declarePlanted(uint256 projectId) external;
    // ↑ apenas o planter; marca block.timestamp como início dos milestones

function reportMilestone(uint256 projectId, Milestone milestone, uint16 survivalBps)
    external onlyRole(GEO_ORACLE_ROLE) nonReentrant;
    // ↑ se survivalBps >= 7500, libera fatia ao planter; senão, fica no cofre

function refund(uint256 projectId) external nonReentrant;
    // ↑ pro-rata da parte não-liberada; só após M36 resolvido (não pendente)
```

### `TreeNFT`
```solidity
struct TreeMetadata {
    uint256 projectId;
    string species;
    int256 gpsLatE6;       // latitude * 1e6 (preserva 6 casas decimais)
    int256 gpsLngE6;
    uint64 plantedAt;
    address originalDonor;
}

function mintTree(...) external onlyRole(MINTER_ROLE) returns (uint256 tokenId);
```

### Math do payout

```
payout(milestone) = budgetRaised * milestoneBps / 10_000

  Note: usamos budgetRaised, NÃO budgetTotal. Projeto sub-financiado paga
  proporcionalmente menos — não força o plantador a esperar 100% do alvo.
```

### Math do refund

```
share(doador) = userDonation / budgetRaised * (budgetRaised - budgetReleased)
```

## 🚀 Como rodar

```bash
make anvil &
make deploy-local
make demo-reforest
```

O que você vai ver:

1. **Setup:** vault, NFT, USDC, doadores fundados.
2. **Etapa 1 — 2 projetos criados:**
   - #1 "Mata Atlântica em Recuperação" — 1.000 Ipê-amarelo (Patrocínio-MG), 10k USDC
   - #2 "Cerrado Renasce" — 500 Pequi (Brasília-DF), 5k USDC
3. **Etapa 2 — Doações:**
   - alice doa 7k USDC ao #1 **e minta TreeNFT #1** (com GPS+espécie on-chain)
   - alice doa 4k USDC ao #2 (sem NFT)
   - bruno doa 3k USDC ao #1 (sem NFT)
4. **Etapa 3 — Plantios declarados.**
5. **Etapa 4 — Pipeline de milestones** (com fast-forward):
   - Projeto #1: M0 95%, M6 90%, M12 84%, M36 85% → **TODOS APROVADOS**
   - Projeto #2: M0 88%, M6 50% (estiagem!), M12 32%, M36 20% → **3 REPROVADOS**
6. **Etapa 5 — Refund:** alice resgata 3.600 USDC (pro-rata) do projeto #2.
7. **Resumo:** alice tem TreeNFT #1 na carteira; planter1 recebeu 10k (100% do
   projeto saudável); planter2 recebeu só 400 USDC (10% do M0 que passou).

## 🛠 Implementação e Teste — Passo a Passo

### 1. Pré-requisitos (primeira vez)

```bash
# Foundry (forge + anvil + cast)
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Dependências Solidity (OpenZeppelin via git submodule)
git submodule update --init --recursive

# Ambiente Python
make install          # cria .venv e instala requirements.txt

# Variáveis de ambiente
cp .env.example .env
# Edite .env: defina DEPLOYER_PRIVATE_KEY com uma chave de teste Anvil, ex:
# DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### 2. Compilar e testar (isolado)

```bash
forge build

# Rodar somente os testes do ReForest+
forge test --match-path "contracts/reforest/*" -vv
```

Saída esperada: **15 testes verdes**

| Teste | O que valida |
|---|---|
| `test_createProject` | `createProject` emite `ProjectCreated` e retorna projectId |
| `testRevert_createProject_zeroPlanter` | Planter zero reverte |
| `testRevert_createProject_notAdmin` | Sem `ADMIN_ROLE` reverte |
| `test_donateWithoutNft` | `donate(false)` deposita USDC sem mintar NFT |
| `test_donateWithNft_mintsCertificate` | `donate(true)` minta TreeNFT com metadata GPS+espécie |
| `testRevert_donateAboveBudget` | Doação acima do `budgetTotal` reverte |
| `testRevert_declarePlanted_notPlanter` | Apenas o planter pode chamar `declarePlanted` |
| `test_declarePlanted_setsTimestamp` | `declarePlanted` salva `block.timestamp` como `plantedAt` |
| `test_milestoneM0_approved_releases10Percent` | M0 aprovado (≥75%) libera 10% do orçamento ao planter |
| `test_milestoneM6_rejected_doesNotRelease` | M6 reprovado (<75%) não transfere nada |
| `testRevert_milestoneOutOfWindow` | Oracle reporta M6 antes de 180 dias → revert |
| `testRevert_milestoneTwice` | Mesmo milestone reportado duas vezes → revert |
| `testRevert_milestoneByNonOracle` | Sem `GEO_ORACLE_ROLE` → revert |
| `test_refund_proRataAfterM36Failed` | 2 doadores recuperam pro-rata após M36 reprovado |
| `testRevert_refundBeforeM36Resolved` | Refund antes de M36 ser reportado → revert |

### 3. Deploy e demo local

```bash
# Terminal 1 — Anvil (blockchain local, mantém em execução)
make anvil

# Terminal 2 — Deploy de todos os contratos (grava em deploy/addresses.json)
make deploy-local

# Terminal 2 — Demo ponta-a-ponta (inclui fast-forward de blocos)
make demo-reforest
```

### 4. Verificar eventos on-chain

```bash
VAULT=$(jq -r '."31337".ReforestVault' deploy/addresses.json)

# Milestones reportados pelo oracle (survivalBps, aprovado/reprovado, scene_id hash)
cast logs \
  "MilestoneReported(uint256,uint8,uint16,bool,address,bytes32)" \
  --address "$VAULT" \
  --from-block 1 \
  --rpc-url http://127.0.0.1:8545

# Doações (quem doou, quanto, tokenId do NFT se mintado)
cast logs \
  "Donated(uint256,address,uint128,uint256)" \
  --address "$VAULT" \
  --from-block 1 \
  --rpc-url http://127.0.0.1:8545

# Estado atual de um projeto (substituir 1 pelo projectId)
cast call "$VAULT" \
  "projects(uint256)(address,bytes32,string,int256,int256,uint32,uint128,uint128,uint128,uint64,uint8)" 1 \
  --rpc-url http://127.0.0.1:8545
# Campos: planter, geoHash, species, lat, lng, trees, budgetTotal, raised, released, plantedAt, milestonesDone
```

### 5. Auditar um oracle report

O evento `MilestoneReported` inclui o `dataSourceHash` = SHA-256 do `scene_id` Sentinel-2.
Para verificar independentemente:

```bash
# Exemplo: scene_id do M0 do projeto #1
echo -n "S2A_MSIL2A_20260401T130251_N0500_R110_T23KPQ_20260401T163512" | sha256sum
# Compare com o bytes32 nos logs do MilestoneReported
```

### 6. Deploy em Base Sepolia (testnet)

```bash
# Preencha em .env:
#   BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
#   BASESCAN_API_KEY=<chave em basescan.org/myapikey>
make deploy-base-sepolia
```

### Plugar API satelital real

Estrutura está pronta — basta substituir `load_ndvi_feed` por um cliente HTTP
de Sentinel-2 ou MapBiomas Cobertura. Pseudo-código:

```python
def fetch_ndvi(project_geo_hash: bytes, plantio_date: date) -> int:
    polygon = geohash_to_polygon(project_geo_hash)  # off-chain mapping
    ndvi_now = sentinel_client.mean_ndvi(polygon, date.today())
    ndvi_baseline = sentinel_client.mean_ndvi(polygon, plantio_date)
    survival_rate = max(0, (ndvi_now / ndvi_baseline_target) * 10_000)
    return int(survival_rate)
```

## ⚠️ Limitações do MVP

- **NDVI via mock CSV.** Sentinel-2 real exige conta + cliente HTTP (estrutura já
  preparada em `ndvi_oracle.py`).
- **Single oracle.** Em produção, multisig de 2-de-3 oracles independentes evita
  ponto único de fraude.
- **Sem aporte de doação parcial via stable-coin nativa.** Doador precisa ter
  USDC; precisaria de ponte fiat para escala real.
- **Refund é tudo-ou-nada por doador.** Não dá para resgatar fatia agora e deixar
  parte para se M36 finalmente passar (decisão de simplicidade).
- **GPS armazenado on-chain.** Caro em gas — para milhares de árvores, migrar
  para metadata IPFS referenciada por CID.

## 🔜 Próximos passos

1. Cliente Sentinel-2 real (Copernicus Open Access Hub)
2. Multisig de oracles (2-de-3 reportes para liberar payout)
3. Refund parcial (`refundAmount`)
4. `transferTree` com royalty para o plantador (5% em revenda perpétua, padrão EIP-2981)
5. Front-end que mostra cada NFT da carteira em mapa interativo
6. DAO governance: doadores votam em quais projetos aprovar
