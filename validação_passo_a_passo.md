# Guia de Execução — Avaliador / Professor

> HackWeb Web3 — ImpactLedger (Desafio 3)
> Stack: Solidity 0.8.24 + Foundry · Python 3.11+ · Anvil (blockchain local) · Base Sepolia (testnet pública)

---

## Duas formas de validar

| Modo | Comando | O que demonstra |
|---|---|---|
| **Local (Anvil)** | `make demo` | Fluxo completo: M0→M6→M12→M36 + refund, com fast-forward de tempo |
| **Testnet (Base Sepolia)** | `make demo-testnet` | 5 carteiras reais com ETH de teste, NFT e transações visíveis no Basescan |

Os contratos já estão deployados e verificados na Base Sepolia — a seção 8 mostra como inspecionar sem instalar nada.

---

## Compatibilidade de sistemas operacionais

| SO | Funciona? | Observação |
|---|---|---|
| **Linux** | Sim, nativo | Guia escrito para Linux |
| **macOS** | Sim, nativo | Comandos idênticos |
| **Windows** | Via WSL2 | Leia a seção abaixo antes de continuar |

### Windows — configurar WSL2 (fazer uma vez)

O guia usa `make`, `bash`, `curl | bash` e outras ferramentas Unix que não existem
nativamente no Windows. A solução oficial e mais simples é o **WSL2** (Windows
Subsystem for Linux), que cria um ambiente Linux completo dentro do Windows.

**1. Habilitar o WSL2** — abra o PowerShell como Administrador e execute:

```powershell
wsl --install
```

Isso instala o WSL2 com Ubuntu. Reinicie o computador quando solicitado.

**2. Abrir o terminal Ubuntu**

Após reiniciar, procure "Ubuntu" no menu Iniciar e abra. Na primeira vez, crie
um usuário e senha Unix (não precisa ser igual ao Windows).

**3. Instalar dependências dentro do Ubuntu**

```bash
sudo apt update && sudo apt install -y git make python3 python3-venv curl jq
```

**4. Clonar o repositório dentro do WSL**

Clone o projeto **dentro do WSL**, não em `/mnt/c/...` (o acesso a pastas Windows
é muito lento para compilação Solidity).

```bash
cd ~
git clone <URL-DO-REPO>
```

A partir daqui, **siga o guia normalmente** — todos os comandos funcionam igual ao Linux.

> **Dica:** use o [Windows Terminal](https://aka.ms/terminal) para uma experiência
> melhor com abas (uma para o Anvil, outra para os comandos).

---

## Pré-requisitos (instalar uma vez)

### Foundry (forge + anvil + cast)

```bash
curl -L https://foundry.paradigm.xyz | bash
# Abra um novo terminal ou execute:
source ~/.bashrc   # ou ~/.zshrc
foundryup

# Verifique:
forge --version
anvil --version
cast --version
```

### Python 3.11+

```bash
python3 --version   # deve ser >= 3.11
```

### Git

```bash
git --version
```

---

## 1. Clonar e entrar na pasta do projeto

```bash
git clone <URL-DO-REPO>
cd <pasta-do-repo>/reforest   # todos os próximos comandos rodam daqui
```

> Todos os comandos `make` a seguir devem ser executados dentro de **`reforest/`**.

```bash
# Submodules do Solidity (OpenZeppelin, forge-std)
git submodule update --init --recursive

# Cria o .env com a chave de teste do Anvil
make setup

# Ambiente Python
make install        # cria .venv e instala dependências
```

O `make setup` cria o `.env` automaticamente com a chave pública do Anvil:

```env
DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

> Essa é a **conta #0 do Anvil** — pública, conhecida, sem valor real. É usada apenas para `make demo` (local). O `make demo` sobrescreve essa chave automaticamente, então o `.env` não precisa ser alterado para rodar a demo local.

---

## 2. Compilar os contratos

```bash
make build
```

Esperado: `Compiler run successful` (warnings de lint são normais, sem erros).

---

## 3. Rodar os testes Foundry

```bash
make test
```

Saída esperada — 15 testes do ReForest+:

```
Ran 15 tests for contracts/reforest/ReforestVault.t.sol
Suite result: ok. 15 passed; 0 failed; 0 skipped
```

| Teste | O que valida |
|---|---|
| `test_createProject` | Criação de projeto emite evento e retorna ID |
| `test_donateWithNft_mintsCertificate` | Doação com `mintNft=true` minta TreeNFT com metadata GPS+espécie |
| `test_donateWithoutNft` | Doação sem NFT deposita USDC corretamente |
| `test_declarePlanted_setsTimestamp` | `declarePlanted` salva timestamp do plantio |
| `test_milestoneM0_approved_releases10Percent` | M0 aprovado (≥75%) libera 10% ao plantador |
| `test_milestoneM6_rejected_doesNotRelease` | M6 reprovado (<75%) não transfere nada |
| `test_refund_proRataAfterM36Failed` | 2 doadores recuperam pro-rata após M36 reprovado |
| `testRevert_createProject_notAdmin` | Sem `ADMIN_ROLE` reverte |
| `testRevert_createProject_zeroPlanter` | Plantador zero reverte |
| `testRevert_declarePlanted_notPlanter` | Apenas o plantador pode chamar `declarePlanted` |
| `testRevert_donateAboveBudget` | Doação acima do orçamento reverte |
| `testRevert_milestoneByNonOracle` | Sem `GEO_ORACLE_ROLE` reverte |
| `testRevert_milestoneOutOfWindow` | Oracle reporta M6 antes de 180 dias → revert |
| `testRevert_milestoneTwice` | Mesmo milestone reportado duas vezes → revert |
| `testRevert_refundBeforeM36Resolved` | Refund antes de M36 ser reportado → revert |

---

## 4. Subir a blockchain local

```bash
make anvil
# Esperado: Anvil pronto em 127.0.0.1:8545 (logs: /tmp/anvil.log)
```

O Anvil roda em background — não precisa de terminal separado. Rode duas vezes sem problema: se já estiver ativo, imprime "Anvil ja esta rodando" e segue.

---

## 5. Deploy dos contratos

No **terminal principal** (com Anvil rodando ao fundo):

```bash
make deploy
```

Saída esperada — 8 contratos deployados:

```
MockUSDC:              0x5FbDB2315678afecb367f032d93F642f64180aa3
TreeNFT:               0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
ReforestVault:         0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
ProBonoRegistry:       0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9
PlasticCreditRegistry: 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
AquaGuardRegistry:     0x0165878A594ca255338adfa4d48449f69242Eb8F
DonorDAOTreasury:      0xa513E6E4b8f2a923D98304ec87F64353C4D5C853
MealRelay:             0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6
```

Arquivo gerado automaticamente: `../deploy/addresses.json`.

---

## 6. Rodar a demo do ReForest+ (local — fluxo completo)

```bash
make demo
```

### O que acontece em cada etapa

| Etapa | Descrição |
|---|---|
| **Setup** | Vault, NFT, USDC e carteiras fundadas |
| **Projetos** | #1 Mata Atlântica — 1.000 Ipê-amarelo, 10k USDC (Patrocínio-MG) |
| | #2 Cerrado Renasce — 500 Pequi, 5k USDC (Brasília-DF) |
| **Doações** | alice doa 7k USDC ao #1 e **minta TreeNFT** com GPS+espécie on-chain |
| | alice doa 4k USDC ao #2 (sem NFT) |
| | bruno doa 3k USDC ao #1 (sem NFT) |
| **Plantios** | Plantadores declaram plantio on-chain (`declarePlanted`) |
| **Milestones** | Oracle NDVI processa 4 checkpoints com fast-forward de tempo |
| | Projeto #1 — M0 95% ✓, M6 90% ✓, M12 84% ✓, M36 85% ✓ → **todos aprovados** |
| | Projeto #2 — M0 88% ✓, M6 50% ✗, M12 32% ✗, M36 20% ✗ → **3 reprovados (estiagem)** |
| **Refund** | alice resgata 3.600 USDC pro-rata do projeto #2 |

### Tabela final esperada

```
┏━━━━━━━━━━┳━━━━━━━━━━┳━━━━━━━━━━┓
┃ Conta    ┃     USDC ┃ TreeNFTs ┃
┡━━━━━━━━━━╇━━━━━━━━━━╇━━━━━━━━━━┩
│ alice    │ 22600.00 │        1 │
│ bruno    │  7000.00 │        0 │
│ planter1 │ 10000.00 │        0 │
│ planter2 │   400.00 │        0 │
└──────────┴──────────┴──────────┘
  projeto #1 [Mata Atlântica]: raised=10000.00  released=10000.00 USDC
  projeto #2 [Cerrado Renasce]: raised=4000.00  released=400.00 USDC
```

> Os valores de USDC podem aparecer maiores se o Anvil não for reiniciado entre runs — isso é normal, pois o Anvil mantém estado entre execuções. O que importa é a diferença relativa entre início e fim de cada run.

---

## 7. Verificar estado on-chain localmente (opcional)

Com o Anvil ainda rodando após a demo:

```bash
VAULT=$(jq -r '."31337".ReforestVault' ../deploy/addresses.json)
RPC=http://127.0.0.1:8545

# Estado do projeto #1
cast call "$VAULT" \
  "projects(uint256)(address,bytes32,string,int256,int256,uint32,uint128,uint128,uint128,uint64,bool)" \
  1 --rpc-url $RPC

# Eventos de milestones (survivalBps, aprovado/reprovado, hash do satélite)
cast logs \
  "MilestoneReported(uint256,uint8,uint16,bool,address,bytes32)" \
  --address "$VAULT" --from-block 1 --rpc-url $RPC

# Verificar auditabilidade: SHA-256 do scene_id Sentinel-2 deve bater com o evento on-chain
echo -n "S2A_MSIL2A_20260401T130251_N0500_R110_T23KPQ_20260401T163512" | sha256sum
# Compare o resultado com o bytes32 no evento MilestoneReported do M0 do projeto #1
```

---

## 8. Demo na testnet com carteiras reais (Base Sepolia)

Esta modalidade conecta em uma rede pública real. Os contratos já estão deployados
e verificados — não é necessário fazer deploy de novo.

```bash
make demo-testnet
```

A demo deriva 5 endereços distintos deterministicamente e financia cada um com ETH
de teste antes de executar. Cada transação é rastreável no Basescan em tempo real.

### O que acontece

| Etapa | Descrição |
|---|---|
| **Funding** | 4 carteiras derivadas recebem ETH de teste para pagar gas |
| **Projetos** | Dois projetos criados on-chain na Base Sepolia |
| **Doações** | alice doa 7k USDC e minta TreeNFT real (ERC-721 on-chain) |
| | alice doa 4k USDC ao projeto #2; bruno doa 3k ao projeto #1 |
| **Plantios** | planter1 e planter2 declaram plantio on-chain |
| **M0** | Oracle reporta 95% e 88% de sobrevivência → ambos aprovados |
| | planter1 recebe 1.000 USDC; planter2 recebe 400 USDC automaticamente |
| **M6/M12/M36** | Omitidos — requerem 180-1.095 dias reais na testnet |

### Saída esperada

```
deployer (admin+oracle): 0x67c65f6e06a231203bE9DaE9e97F07F740e65e68
planter1:                0x7540D78112D8063Ae805C15077BEc39EDcc0bcc5
planter2:                0x52e79B204e3254C5CA6eF83752c7692974539a14
alice (doadora c/ NFT):  0x69fB0Dd6A108d7c0605b0F2c4956ED3D8FAB8da9
bruno (doador s/ NFT):   0xdcC5E8242115cc5235f360c4EB18a7e94434bbfA

  ✓ alice doou 7.000 USDC ao projeto #N e mintou TreeNFT #M
  oracle M0 #N: 95.0% sobrevivência → APROVADO
  oracle M0 #N+1: 88.0% sobrevivência → APROVADO
```

---

## 9. Verificação na Base Sepolia (Basescan) — já deployado

Os contratos estão deployados e verificados na **Base Sepolia** (testnet pública).
Você pode inspecionar tudo sem rodar nada localmente.

### Contratos verificados

| Contrato | Endereço | Basescan |
|---|---|---|
| **ReforestVault** | `0xc445823A43c857438bCdA289e8d713DFC183B463` | [ver código](https://sepolia.basescan.org/address/0xc445823A43c857438bCdA289e8d713DFC183B463#code) |
| **TreeNFT** | `0xDd7b07dd2684c4881Df7B1Ba450B69fbc1ddE848` | [ver código](https://sepolia.basescan.org/address/0xDd7b07dd2684c4881Df7B1Ba450B69fbc1ddE848#code) |
| **MockUSDC** | `0x7D3f460251dd9d04481de14B04507697B2bA36d2` | [ver código](https://sepolia.basescan.org/address/0x7D3f460251dd9d04481de14B04507697B2bA36d2#code) |

### Atores — endereços com histórico de transações

| Papel | Endereço | Basescan |
|---|---|---|
| **deployer** (admin + oracle) | `0x67c65f6e06a231203bE9DaE9e97F07F740e65e68` | [ver txs](https://sepolia.basescan.org/address/0x67c65f6e06a231203bE9DaE9e97F07F740e65e68) |
| **planter1** | `0x7540D78112D8063Ae805C15077BEc39EDcc0bcc5` | [ver txs](https://sepolia.basescan.org/address/0x7540D78112D8063Ae805C15077BEc39EDcc0bcc5) |
| **planter2** | `0x52e79B204e3254C5CA6eF83752c7692974539a14` | [ver txs](https://sepolia.basescan.org/address/0x52e79B204e3254C5CA6eF83752c7692974539a14) |
| **alice** (doadora c/ NFT) | `0x69fB0Dd6A108d7c0605b0F2c4956ED3D8FAB8da9` | [ver txs](https://sepolia.basescan.org/address/0x69fB0Dd6A108d7c0605b0F2c4956ED3D8FAB8da9) |
| **bruno** (doador s/ NFT) | `0xdcC5E8242115cc5235f360c4EB18a7e94434bbfA` | [ver txs](https://sepolia.basescan.org/address/0xdcC5E8242115cc5235f360c4EB18a7e94434bbfA) |

### O que checar no Basescan

1. **TreeNFT mintado para alice** — em `TreeNFT → Token Transfers`, confirme que alice recebeu NFTs nas doações de 7.000 USDC.
2. **Eventos `MilestoneReported`** — em `ReforestVault → Events`, veja os eventos M0 com 95% e 88% de sobrevivência registrados imutavelmente.
3. **Código verificado** — em qualquer contrato, aba `Contract → Code`: o Solidity do repositório é idêntico ao deployado.
4. **`data_source_hash` auditável** — o campo `bytes32` no evento M0 é o SHA-256 do scene ID Sentinel-2. Qualquer auditor pode verificar:
   ```bash
   echo -n "S2A_MSIL2A_20260401T130251_N0500_R110_T23KPQ_20260401T163512" | sha256sum
   ```
   O resultado deve ser idêntico ao `bytes32` no evento on-chain.

---

## Fluxo mínimo para validação local

```
cd reforest/

make setup  →  make install  →  make build  →  make test
                                                    ↓
                                          (15 testes verdes)
                                                    ↓
                                    make anvil  (background)
                                                    ↓
                                    make deploy  →  make demo
```

Para validação na testnet pública, basta:

```
make demo-testnet   # sem Anvil, sem deploy — usa contratos já publicados
```

---

## Referência de comandos

| Comando | O que faz |
|---|---|
| `make help` | Lista todos os comandos disponíveis |
| `make setup` | Cria o `.env` com a chave de teste do Anvil (fazer uma vez) |
| `make install` | Cria `.venv` e instala dependências Python |
| `make build` | Compila todos os contratos Solidity |
| `make test` | Roda os 15 testes do ReForest+ |
| `make anvil` | Sobe blockchain local na porta 8545 (background) |
| `make deploy` | Deploya os 8 contratos no Anvil |
| `make demo` | Roda a demo completa localmente (M0→M36 + refund) |
| `make demo-testnet` | Roda a demo na Base Sepolia com carteiras reais |

---

## Troubleshooting

| Problema | Solução |
|---|---|
| `forge: command not found` | Execute `foundryup` e abra um novo terminal |
| `Error: connection refused` na demo | Anvil não está rodando — execute `make anvil` |
| `addresses.json` vazio `{}` | Execute `make deploy` antes da demo |
| `ModuleNotFoundError: No module named 'reforest'` | Execute `make install` para criar o `.venv` |
| `Insufficient funds for gas` na demo local | Certifique-se de usar `make demo` (não `python -m reforest.agent.demo` direto) — o `make demo` garante a chave correta do Anvil |
| Warnings `MismatchedABI` no terminal | Inofensivos — web3.py tenta decodificar logs de outros contratos com o ABI do Vault |
| `git submodule` falhou | Execute `git submodule update --init --recursive` na raiz do repositório |
| Saldos maiores que o esperado na tabela final | Normal — o Anvil acumula estado entre runs. O que importa é a diferença dentro de cada run |
