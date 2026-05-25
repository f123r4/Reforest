// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PlasticCreditRegistry} from "./PlasticCreditRegistry.sol";

contract PlasticCreditRegistryTest is Test {
    PlasticCreditRegistry internal reg;

    address internal admin = makeAddr("admin");
    address internal validator = makeAddr("validator");
    address internal otherValidator = makeAddr("otherValidator");
    address internal collector1 = makeAddr("collector1");
    address internal collector2 = makeAddr("collector2");
    address internal company = makeAddr("company");

    bytes32 internal constant COOP_NAME = keccak256("Coopcat Santa Cruz");
    bytes32 internal constant COOP_REGION = keccak256("Salvador-BA");
    bytes32 internal constant COOP_NAME_2 = keccak256("RecicloVivo SP");
    bytes32 internal constant COOP_REGION_2 = keccak256("Sao Paulo-SP");

    uint256 internal coopId1;
    uint256 internal coopId2;

    function setUp() public {
        vm.prank(admin);
        reg = new PlasticCreditRegistry(admin);

        vm.startPrank(admin);
        coopId1 = reg.registerCooperative(COOP_NAME, COOP_REGION);
        coopId2 = reg.registerCooperative(COOP_NAME_2, COOP_REGION_2);
        reg.attachValidator(validator, coopId1);
        reg.attachValidator(otherValidator, coopId2);
        vm.stopPrank();
    }

    // ============================ Mint / Math ============================

    function test_pet_mintsOneTokenPerKg() public {
        bytes32 receipt = keccak256("receipt-A");
        vm.prank(validator);
        reg.registerCollection(collector1, 1_000, PlasticCreditRegistry.PlasticType.PET, receipt);
        // 1.000g PET * 1e15 wei/g * 10000/10000 = 1e18 = 1 PLAST
        assertEq(reg.balanceOf(collector1), 1e18);
        assertEq(reg.totalGramsCollectedBy(collector1), 1_000);
    }

    function test_mixed_appliesFactor() public {
        bytes32 receipt = keccak256("receipt-mix");
        vm.prank(validator);
        reg.registerCollection(collector1, 1_000, PlasticCreditRegistry.PlasticType.MIXED, receipt);
        // 1.000g MIXED * 1e15 wei/g * 4000/10000 = 4e17 = 0.4 PLAST
        assertEq(reg.balanceOf(collector1), 4e17);
    }

    function test_aggregatesAcrossMultipleCollections() public {
        vm.startPrank(validator);
        reg.registerCollection(collector1, 1_500, PlasticCreditRegistry.PlasticType.PET, keccak256("r1"));
        reg.registerCollection(collector1, 2_500, PlasticCreditRegistry.PlasticType.HDPE, keccak256("r2"));
        vm.stopPrank();
        assertEq(reg.totalGramsCollectedBy(collector1), 4_000);
        // 1500g PET = 1.5e18 + 2500g HDPE * 0.9 = 2.25e18 → total 3.75e18
        assertEq(reg.balanceOf(collector1), 1_500 * 1e15 + (2_500 * 1e15 * 9_000) / 10_000);
    }

    // ============================ Anti-fraude ============================

    function testRevert_validatorCannotMintToSelf() public {
        vm.prank(validator);
        vm.expectRevert(bytes("Validator nao pode ser coletor"));
        reg.registerCollection(validator, 1_000, PlasticCreditRegistry.PlasticType.PET, keccak256("r-self"));
    }

    function testRevert_duplicateReceipt() public {
        bytes32 receipt = keccak256("duplicate-receipt");
        vm.startPrank(validator);
        reg.registerCollection(collector1, 1_000, PlasticCreditRegistry.PlasticType.PET, receipt);
        vm.expectRevert(bytes("Recibo ja usado"));
        reg.registerCollection(collector1, 1_000, PlasticCreditRegistry.PlasticType.PET, receipt);
        vm.stopPrank();
    }

    function testRevert_unauthorizedValidator() public {
        address rogue = makeAddr("rogue");
        vm.prank(rogue);
        vm.expectRevert();
        reg.registerCollection(collector1, 1_000, PlasticCreditRegistry.PlasticType.PET, keccak256("x"));
    }

    function testRevert_zeroWeight() public {
        vm.prank(validator);
        vm.expectRevert(bytes("Peso zero"));
        reg.registerCollection(collector1, 0, PlasticCreditRegistry.PlasticType.PET, keccak256("z"));
    }

    // ============================ Retire ============================

    function test_retire_burnsAndEmits() public {
        // Mintar saldo para a company via coleta + transfer
        bytes32 receipt = keccak256("for-company");
        vm.prank(validator);
        reg.registerCollection(collector1, 5_000, PlasticCreditRegistry.PlasticType.PET, receipt);
        vm.prank(collector1);
        reg.transfer(company, 3e18);

        uint256 supplyBefore = reg.totalSupply();
        vm.prank(company);
        reg.retire(2e18, keccak256("ESG-report-2026-Q1"));
        assertEq(reg.balanceOf(company), 1e18);
        assertEq(reg.totalSupply(), supplyBefore - 2e18);
        assertEq(reg.totalGramsRetiredBy(company), 2_000); // 2e18 / 1e15
        assertEq(reg.totalGramsRetired(), 2_000);
    }

    function testRevert_retire_requiresDisclosure() public {
        bytes32 receipt = keccak256("for-disc-test");
        vm.prank(validator);
        reg.registerCollection(collector1, 1_000, PlasticCreditRegistry.PlasticType.PET, receipt);
        vm.prank(collector1);
        vm.expectRevert(bytes("Disclosure obrigatorio"));
        reg.retire(5e17, bytes32(0));
    }

    // ============================ Isolamento entre cooperativas ============================

    function test_validatorIsScopedToItsCooperative() public {
        bytes32 receipt = keccak256("scope-r");
        // otherValidator (vinculado a coop2) registra → deve associar a coop2, não a coop1
        vm.prank(otherValidator);
        uint256 cid = reg.registerCollection(
            collector2, 800, PlasticCreditRegistry.PlasticType.PET, receipt
        );
        (uint256 cooperativeId, address coletor,, uint32 weight,, ,) = reg.collections(cid);
        assertEq(cooperativeId, coopId2);
        assertEq(coletor, collector2);
        assertEq(weight, 800);
    }
}
