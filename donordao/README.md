# DonorDAO — Captação Coletiva Governada

> Trilha 3 — ImpactLedger · Status: MVP funcional, 11 testes Foundry verdes

## 🎯 O problema

Doação a ONGs no Brasil sofre de dois extremos: ou é "doação por confiança"
(transfere para conta única, sem prestação de contas detalhada) ou é
plataforma centralizada (Catarse, Vakinha) que cobra fee, retém repasses
e quem decide alocação é a plataforma, não o doador. O doador tem **zero
governança** sobre como o dinheiro é gasto depois de doado, e nenhuma
visibilidade sobre quais projetos competem pela mesma verba.

## 💡 A solução

Cofre **coletivo** em USDC governado por **voto on-chain proporcional à
contribuição**. ONGs cadastradas submetem propostas (título, hash do PDF
de execução, valor solicitado). Doadores votam **yes/no na janela de 7 dias**.

**Quem decide a alocação é quem pôs o dinheiro lá** — sem intermediário.

Resultado:
- **Quorum** ≥ 30% do voting power total + **maioria** ≥ 60% yes →
  contrato transfere o valor direto para a carteira da ONG. Verificável.
- Caso contrário → REJEITADA, USDC permanece no cofre, disponível para
  outras propostas.

Doador pode **retirar** sua contribuição não-gasta **a qualquer momento**
desde que não tenha voto em proposta ainda pendente. Esse lockup é a
defesa contra "vote-then-withdraw" — se você votou, está comprometido
até o desfecho.

**Proposta de valor:**
- **Doador:** prestação de contas radical (cada execute() é evento on-chain),
  poder real de alocação, saída a qualquer momento da parte não-gasta.
- **ONG:** captação previsível, sem fee de plataforma; aprovação serve como
  selo de validação social registrado on-chain.
- **Auditor/Imprensa:** lista pública de propostas, voto granular por
  contribuinte, total executado por ONG.

## 🧱 Arquitetura

```
   3 doadores            2 ONGs
   ┌─────────┐  ┌─────────┐  ┌────────────┐  ┌────────────┐
   │ alice   │  │ bob     │  │ ONG1       │  │ ONG2       │
   │ 50k USDC│  │ 30k USDC│  │ Alfabetiz. │  │ Plantio    │
   └────┬────┘  └────┬────┘  └─────┬──────┘  └─────┬──────┘
        │ deposit    │ deposit      │ submitProposal│
        └─────┬──────┘              │               │
              ▼                     │               │
   ┌──────────────────────────────────────────────────────────┐
   │ DonorDAOTreasury.sol                                      │
   │ • members[]: contribuição + openVoteCount                 │
   │ • proposals[]: ngo, amount, votingEnds, yes/no, status    │
   │ • _voters[pid]: lista para destravar openVoteCount        │
   │ • execute: quorum (30%) + maioria (60%)                   │
   └──────────────────────────────────────────────────────────┘
                     │
                     ▼ se aprovada
              USDC para ONG
```

### Atores e papéis on-chain

| Papel | Quem encarna | O que pode fazer |
|---|---|---|
| `ADMIN_ROLE` | Conselho gestor (multisig prod) | Cadastrar ONGs (`NGO_ROLE`) |
| `NGO_ROLE` | ONG cadastrada | `submitProposal` |
| (sem papel) | Qualquer doador (após `deposit`) | `vote`, `withdraw`, `execute` |
| (sem papel) | Qualquer um | `execute` (após fim da janela) |

### Constantes governamentais

| Parâmetro | Valor | Justificativa |
|---|---|---|
| `VOTING_PERIOD` | 7 dias | Janela ampla para doadores casuais. Não tão longo que ONG espere semanas. |
| `QUORUM_BPS` | 30% | Anti-baleia: 1 doador grande não passa proposta sozinho. |
| `APPROVAL_BPS` | 60% | Maioria qualificada, não 50%+1 (evita decisões apertadíssimas) |

### Por que voting power = contribuição (e não 1p1v)

Sem KYC on-chain, 1-pessoa-1-voto é trivialmente sybilizável (crio 1000
endereços, voto 1000 vezes). Skin-in-the-game é a defesa pragmática para
o MVP. Em V2, mistura com SBT de reputação (ProBono, VoluntChain) habilita
voto quadrático ponderado.

## 📂 Estrutura

```
contracts/donordao/
├── DonorDAOTreasury.sol        # contrato único
└── DonorDAOTreasury.t.sol      # 11 testes (deposit, vote, execute, lockup)

donordao/
└── agent/
    ├── registry.py             # DonorDAOClient + UsdcClient
    └── demo.py                 # CLI ponta-a-ponta (3 doadores, 2 propostas, fast-forward)
```

## 🧠 Contrato — funções principais

```solidity
function deposit(uint128 amount) external;
function withdraw(uint128 amount) external;
    // ↑ revert se openVoteCount > 0

function submitProposal(string title, bytes32 detailsHash, uint128 amount)
    external onlyRole(NGO_ROLE) returns (uint256 proposalId);

function vote(uint256 proposalId, bool support) external;
    // ↑ peso = members[msg.sender].contributed no momento do voto
    // ↑ snapshot: alterações posteriores ao saldo não afetam votos passados

function execute(uint256 proposalId) external;
    // ↑ qualquer um após votingEnds
    // ↑ APPROVED se yesVotes/totalVotes >= 60% E totalVotes >= 30% do total
    // ↑ transfere USDC para ngo + destrava voters via openVoteCount-- 
```

## 🚀 Como rodar

```bash
make anvil &
make deploy-local
make demo-donordao
```

O que você vai ver:

1. **Setup:** 2 ONGs com `NGO_ROLE`, 3 doadores fundados com USDC + approve.
2. **Etapa 1 — Depósitos:** alice 50k, bob 30k, carol 20k → treasury com 100k USDC.
3. **Etapa 2 — Proposta #1 (ONG1, 25k USDC):**
   - alice YES (50k peso), bob YES (30k peso), carol NO (20k peso)
   - yes = 80k, total = 100k → 80% yes (acima de 60%), quorum 30k atingido
   - **APROVADA** → 25k USDC vão para ONG1
4. **Etapa 3 — Proposta #2 (ONG2, 40k USDC):**
   - só carol vota YES (20k peso). Quorum 22,5k não atingido.
   - **REJEITADA** → 0 transferido
5. **Etapa 4 — Balanços finais:** treasury 75k, ONG1 com 25k, ONG2 com 0,
   doadores com suas contribuições intactas (podem retirar agora).

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

# Rodar somente os testes do DonorDAO
forge test --match-path "contracts/donordao/*" -vv
```

Saída esperada: **11 testes verdes**

| Teste | O que valida |
|---|---|
| `test_deposit_increasesContribution` | `deposit` incrementa `members[donor].contributed` |
| `test_withdraw_returnsUnusedFunds` | `withdraw` devolve USDC ao doador |
| `testRevert_withdraw_lockedDuringVote` | Doador com voto pendente não pode sacar |
| `test_approvedProposal_transfersToNGO` | Proposta com quorum + maioria → USDC vai para ONG |
| `test_rejectedByMajority` | yes < 60% → REJEITADA, sem transferência |
| `test_rejectedByQuorumFail` | totalVotes < 30% do total depositado → REJEITADA |
| `test_executeUnlocksWithdraw` | Após `execute`, doadores podem sacar novamente |
| `testRevert_proposalExceedsTreasury` | Proposta acima do saldo do cofre reverte |
| `testRevert_doubleVote` | Votar duas vezes na mesma proposta reverte |
| `testRevert_voteWithoutPower` | Endereço sem depósito não pode votar |
| `testRevert_executeBeforeDeadline` | `execute` antes do fim da janela de 7 dias reverte |

### 3. Deploy e demo local

```bash
# Terminal 1 — Anvil (blockchain local, mantém em execução)
make anvil

# Terminal 2 — Deploy de todos os contratos (grava em deploy/addresses.json)
make deploy-local

# Terminal 2 — Demo ponta-a-ponta
make demo-donordao
```

### 4. Verificar eventos on-chain

```bash
ADDR=$(jq -r '."31337".DonorDAOTreasury' deploy/addresses.json)

# Propostas submetidas
cast logs \
  "ProposalSubmitted(uint256,address,uint128,uint64,bytes32)" \
  --address "$ADDR" \
  --from-block 1 \
  --rpc-url http://127.0.0.1:8545

# Resultado das votações (approved=true/false)
cast logs \
  "ProposalExecuted(uint256,bool,uint128,address)" \
  --address "$ADDR" \
  --from-block 1 \
  --rpc-url http://127.0.0.1:8545

# Saldo atual do treasury
cast call "$ADDR" \
  "totalDeposited()(uint128)" \
  --rpc-url http://127.0.0.1:8545
```

### 5. Deploy em Base Sepolia (testnet)

```bash
# Preencha em .env:
#   BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
#   BASESCAN_API_KEY=<chave em basescan.org/myapikey>
make deploy-base-sepolia
```

## ⚠️ Limitações do MVP

- **Sem milestones intra-proposta.** Aprovou? Transfere tudo de uma vez.
  Em V2, propostas com milestones (M1 30%, M2 30%, M3 40%) + voto de
  liberação por milestone (igual ReForest+).
- **Voto on/off binário.** Não suporta "voto delegado" (líder comunitário
  vota em nome de doadores menores). EIP-712 + assinatura off-chain
  resolveria.
- **Lockup conservador.** Doador com 1 voto pendente fica com TUDO travado
  para withdraw. Em V2: lockup proporcional ao peso voted vs contributed.
- **NGO submete proposta sem stake / sem deposit.** ONG spam-friendly. Em V2,
  cobrar deposit pequeno (1% da proposta) reembolsável se aprovada,
  perdido se rejeitada — força ONGs a triar internamente antes.
- **Sem voto quadrático.** Baleia ainda manda demais. V2: integrar
  ProBono/VoluntChain como peso adicional, reduzindo dependência financeira.

## 🔜 Próximos passos

1. Milestones intra-proposta com voto de liberação por etapa
2. Stake de submissão (anti-spam) com slash em rejeição
3. Voto delegado via EIP-712 signature off-chain
4. Quadrático: peso = sqrt(USDC) × log(1 + reputationSBT)
5. Front-end mostrando ranking de ONGs por aprovação histórica
