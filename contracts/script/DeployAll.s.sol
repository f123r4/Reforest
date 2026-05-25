// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockUSDC} from "../shared/MockUSDC.sol";

import {TreeNFT} from "../reforest/TreeNFT.sol";
import {ReforestVault} from "../reforest/ReforestVault.sol";
import {ProBonoRegistry} from "../probono/ProBonoRegistry.sol";
import {PlasticCreditRegistry} from "../ecostream/PlasticCreditRegistry.sol";
import {AquaGuardRegistry} from "../aquaguard/AquaGuardRegistry.sol";
import {DonorDAOTreasury} from "../donordao/DonorDAOTreasury.sol";
import {MealRelay} from "../mealrelay/MealRelay.sol";

/**
 * @title DeployAll
 * @notice Deploya os 8 contratos da trilha ImpactLedger em um único broadcast e
 *         escreve TODOS os endereços em deploy/addresses.json (sob a chave do chainId).
 *
 * @dev O monorepo cobre 6 projetos da Trilha 3:
 *        - ReForest+         → ReforestVault + TreeNFT (+ USDC mock)
 *        - ProBono Ledger    → ProBonoRegistry
 *        - EcoStream         → PlasticCreditRegistry (ERC-20 nativo)
 *        - AquaGuard         → AquaGuardRegistry
 *        - DonorDAO          → DonorDAOTreasury (+ USDC mock)
 *        - MealRelay         → MealRelay (+ USDC mock)
 *
 *      MockUSDC é compartilhado por ReForest+, DonorDAO e MealRelay — um único
 *      stable-coin de teste mantém o cenário coerente entre os 3 demos.
 */
contract DeployAll is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("=== DeployAll (ImpactLedger) ===");
        console.log("chainId:", block.chainid);
        console.log("deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // ---------- Stable-coin compartilhada ----------
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC:", address(usdc));

        // ---------- ReForest+ ----------
        TreeNFT treeNft = new TreeNFT(deployer);
        console.log("TreeNFT:", address(treeNft));

        ReforestVault vault = new ReforestVault(deployer, IERC20(address(usdc)), treeNft);
        console.log("ReforestVault:", address(vault));
        treeNft.grantRoleByAdmin(treeNft.MINTER_ROLE(), address(vault));

        // ---------- ProBono ----------
        ProBonoRegistry probono = new ProBonoRegistry(deployer);
        console.log("ProBonoRegistry:", address(probono));

        // ---------- EcoStream ----------
        PlasticCreditRegistry plastic = new PlasticCreditRegistry(deployer);
        console.log("PlasticCreditRegistry:", address(plastic));

        // ---------- AquaGuard ----------
        AquaGuardRegistry aqua = new AquaGuardRegistry(deployer);
        console.log("AquaGuardRegistry:", address(aqua));

        // ---------- DonorDAO ----------
        DonorDAOTreasury donordao = new DonorDAOTreasury(deployer, IERC20(address(usdc)));
        console.log("DonorDAOTreasury:", address(donordao));

        // ---------- MealRelay ----------
        MealRelay meal = new MealRelay(deployer, IERC20(address(usdc)));
        console.log("MealRelay:", address(meal));

        vm.stopBroadcast();

        _writeAddresses(
            address(usdc),
            address(treeNft),
            address(vault),
            address(probono),
            address(plastic),
            address(aqua),
            address(donordao),
            address(meal)
        );
    }

    function _writeAddresses(
        address usdc,
        address treeNft,
        address vault,
        address probono,
        address plastic,
        address aqua,
        address donordao,
        address meal
    ) private {
        string memory path = "./deploy/addresses.json";
        string memory chainKey = vm.toString(block.chainid);

        vm.serializeAddress(chainKey, "MockUSDC", usdc);
        vm.serializeAddress(chainKey, "TreeNFT", treeNft);
        vm.serializeAddress(chainKey, "ReforestVault", vault);
        vm.serializeAddress(chainKey, "ProBonoRegistry", probono);
        vm.serializeAddress(chainKey, "PlasticCreditRegistry", plastic);
        vm.serializeAddress(chainKey, "AquaGuardRegistry", aqua);
        vm.serializeAddress(chainKey, "DonorDAOTreasury", donordao);
        string memory inner = vm.serializeAddress(chainKey, "MealRelay", meal);

        vm.writeJson(inner, path, string.concat(".", chainKey));
    }
}
