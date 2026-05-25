# Atalhos do dia-a-dia. `make help` lista o que está disponível.
# Tudo aqui assume que Foundry está no PATH (~/.foundry/bin).

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Carrega .env automaticamente para os comandos que dependem dele.
ifneq (,$(wildcard ./.env))
	include .env
	export
endif

.PHONY: help
help: ## Lista alvos disponíveis
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-25s %s\n", $$1, $$2}'

# -----------------------------------------------------------------------------
# Contratos (Solidity / Foundry)
# -----------------------------------------------------------------------------
.PHONY: build test test-gas fmt
build: ## Compila todos os contratos
	forge build

test: ## Roda todos os testes Foundry (verbose)
	forge test -vv

test-gas: ## Roda testes com relatório de gas
	forge test --gas-report

fmt: ## Formata Solidity
	forge fmt

# -----------------------------------------------------------------------------
# Anvil local
# -----------------------------------------------------------------------------
.PHONY: anvil
anvil: ## Sobe Anvil local em 127.0.0.1:8545 com chain ID 31337
	anvil --chain-id 31337 --block-time 2

# -----------------------------------------------------------------------------
# Python (workers / demos)
# -----------------------------------------------------------------------------
.PHONY: venv install demo-reforest demo-probono demo-ecostream demo-aquaguard demo-donordao demo-mealrelay demo-all
venv: ## Cria virtualenv .venv (idempotente)
	test -d .venv || python3 -m venv .venv

install: venv ## Instala dependências Python
	. .venv/bin/activate && pip install -U pip && pip install -r requirements.txt

demo-reforest: ## Roda demo do ReForest+
	. .venv/bin/activate && python -m reforest.agent.demo

demo-probono: ## Roda demo do ProBono Ledger
	. .venv/bin/activate && python -m probono.agent.demo

demo-ecostream: ## Roda demo do EcoStream (Plastic Credits)
	. .venv/bin/activate && python -m ecostream.agent.demo

demo-aquaguard: ## Roda demo do AquaGuard (monitoramento hídrico)
	. .venv/bin/activate && python -m aquaguard.agent.demo

demo-donordao: ## Roda demo do DonorDAO (captação governada)
	. .venv/bin/activate && python -m donordao.agent.demo

demo-mealrelay: ## Roda demo do MealRelay (cozinhas comunitárias)
	. .venv/bin/activate && python -m mealrelay.agent.demo

demo-all: ## Roda todas as 6 demos sequencialmente (assume DeployAll rodado)
	$(MAKE) demo-reforest && $(MAKE) demo-probono && $(MAKE) demo-ecostream && \
	$(MAKE) demo-aquaguard && $(MAKE) demo-donordao && $(MAKE) demo-mealrelay

# -----------------------------------------------------------------------------
# Deploy
# -----------------------------------------------------------------------------
.PHONY: deploy-local deploy-base-sepolia
deploy-local: ## Deploy de TODOS os 8 contratos no Anvil local
	forge script contracts/script/DeployAll.s.sol \
		--rpc-url $(ANVIL_RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY)

deploy-base-sepolia: ## Deploy de TODOS os 8 contratos em Base Sepolia (verifica na Basescan)
	forge script contracts/script/DeployAll.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--private-key $(DEPLOYER_PRIVATE_KEY)
