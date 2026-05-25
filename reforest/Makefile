# Atalhos para rodar o projeto ReForest+ de dentro desta pasta.
# Todos os comandos delegam para o Makefile raiz via `make -C ..`.

SHELL := /bin/bash
ROOT  := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))/../
.DEFAULT_GOAL := help

# Carrega .env local (reforest/.env) e exporta para o Makefile pai.
ifneq (,$(wildcard ./.env))
	include .env
	export
endif

.PHONY: help setup install build test anvil deploy deploy-testnet demo demo-testnet

help: ## Lista alvos disponíveis
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

setup: ## Copia .env.example para .env e preenche a chave de teste do Anvil
	@if [ -f .env ]; then \
		echo ".env já existe, pulando."; \
	else \
		cp .env.example .env; \
		sed -i 's|DEPLOYER_PRIVATE_KEY=0x0000.*|DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80|' .env; \
		echo ".env criado com a chave de teste do Anvil (conta #0 — sem valor real)."; \
	fi

install: ## Instala dependências Python (.venv)
	$(MAKE) -C $(ROOT) install

build: ## Compila todos os contratos Solidity
	$(MAKE) -C $(ROOT) build

test: ## Roda os 15 testes do ReForest+ (Foundry)
	cd $(ROOT) && forge test --match-path "contracts/reforest/*" -vv

anvil: ## Sobe Anvil local em 127.0.0.1:8545 em background (logs: /tmp/anvil.log)
	@if curl -sf -X POST http://127.0.0.1:8545 \
		-H 'Content-Type: application/json' \
		-d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
		-o /dev/null 2>/dev/null; then \
		echo "Anvil ja esta rodando em 127.0.0.1:8545."; \
	else \
		pkill -x anvil 2>/dev/null || true; \
		anvil --chain-id 31337 --block-time 2 > /tmp/anvil.log 2>&1 & \
		echo "Aguardando Anvil iniciar..."; \
		for i in 1 2 3 4 5; do sleep 1; \
			curl -sf -X POST http://127.0.0.1:8545 \
				-H 'Content-Type: application/json' \
				-d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
				-o /dev/null 2>/dev/null && break; \
		done; \
		echo "Anvil pronto em 127.0.0.1:8545 (logs: /tmp/anvil.log)"; \
	fi

deploy: ## Deploy de todos os contratos no Anvil local
	$(MAKE) -C $(ROOT) deploy-local

deploy-testnet: ## Deploy + verificação na Base Sepolia (requer BASESCAN_API_KEY no .env)
	$(MAKE) -C $(ROOT) deploy-base-sepolia

demo: ## Roda a demo ponta-a-ponta do ReForest+ (Anvil local)
	DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
	$(MAKE) -C $(ROOT) demo-reforest

demo-testnet: ## Roda a demo do ReForest+ na Base Sepolia (M0 + NFT on-chain)
	@export $$(grep -v '^[#]' .env | grep -v "^$$" | xargs) && \
	cd $(ROOT) && . .venv/bin/activate && python -m reforest.agent.demo --remote
