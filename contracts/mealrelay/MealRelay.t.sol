// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {MealRelay} from "./MealRelay.sol";
import {MockUSDC} from "../shared/MockUSDC.sol";

contract MealRelayTest is Test {
    MealRelay internal relay;
    MockUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal operator1 = makeAddr("operator1");
    address internal operator2 = makeAddr("operator2");
    address internal validator = makeAddr("validator");
    address internal donor = makeAddr("donor");

    uint128 internal constant K = 1e6; // 1 USDC
    uint128 internal constant PRICE = 5 * K; // 5 USDC por refeição

    uint256 internal k1;
    uint256 internal k2;

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(admin);
        relay = new MealRelay(admin, usdc);

        vm.startPrank(admin);
        relay.grantRoleByAdmin(relay.ORG_VALIDATOR_ROLE(), validator);
        k1 = relay.registerKitchen(operator1, keccak256("Mare-RJ"), PRICE);
        k2 = relay.registerKitchen(operator2, keccak256("Capao-Redondo-SP"), PRICE);
        vm.stopPrank();

        usdc.mint(donor, 10_000 * K);
        vm.prank(donor);
        usdc.approve(address(relay), type(uint256).max);
    }

    // ============================ Donate ============================

    function test_donate_increasesFunded() public {
        vm.prank(donor);
        relay.donate(k1, 500 * K);
        (, , , uint128 funded, uint128 spent, , ) = relay.kitchens(k1);
        assertEq(funded, 500 * K);
        assertEq(spent, 0);
        assertEq(relay.availableBalanceOf(k1), 500 * K);
    }

    function test_donations_isolatedByKitchen() public {
        vm.startPrank(donor);
        relay.donate(k1, 300 * K);
        relay.donate(k2, 200 * K);
        vm.stopPrank();
        assertEq(relay.availableBalanceOf(k1), 300 * K);
        assertEq(relay.availableBalanceOf(k2), 200 * K);
    }

    // ============================ Submit + Validate ============================

    function test_submitAndValidate_paysOperator() public {
        vm.prank(donor);
        relay.donate(k1, 1_000 * K);

        vm.prank(operator1);
        uint256 eid = relay.submitMealEvent(k1, 80, keccak256("foto-2026-04-15"), 0, 0);

        uint256 balBefore = usdc.balanceOf(operator1);
        vm.prank(validator);
        relay.validateAndPay(eid);

        uint256 balAfter = usdc.balanceOf(operator1);
        assertEq(balAfter - balBefore, 80 * PRICE);

        (, , uint128 pricePerMeal, uint128 funded, uint128 spent, uint64 mealsServed,) = relay.kitchens(k1);
        assertEq(pricePerMeal, PRICE);
        assertEq(funded, 1_000 * K);
        assertEq(spent, 80 * PRICE);
        assertEq(mealsServed, 80);
    }

    // ============================ Defesas ============================

    function testRevert_nonOperatorCannotSubmit() public {
        vm.prank(donor);
        vm.expectRevert(bytes("Apenas operador"));
        relay.submitMealEvent(k1, 10, keccak256("x"), 0, 0);
    }

    function testRevert_doubleValidation() public {
        vm.prank(donor);
        relay.donate(k1, 1_000 * K);
        vm.prank(operator1);
        uint256 eid = relay.submitMealEvent(k1, 10, keccak256("x"), 0, 0);
        vm.prank(validator);
        relay.validateAndPay(eid);
        vm.prank(validator);
        vm.expectRevert(bytes("Ja validado"));
        relay.validateAndPay(eid);
    }

    function testRevert_validatorCannotBeOperator() public {
        // operator1 ganha role de validator por engano administrativo.
        // Lemos a role ANTES do prank — staticcall depois do prank consome o token.
        bytes32 validatorRole = relay.ORG_VALIDATOR_ROLE();
        vm.prank(admin);
        relay.grantRoleByAdmin(validatorRole, operator1);
        vm.prank(donor);
        relay.donate(k1, 1_000 * K);
        vm.prank(operator1);
        uint256 eid = relay.submitMealEvent(k1, 10, keccak256("x"), 0, 0);
        vm.prank(operator1);
        vm.expectRevert(bytes("Validator nao pode ser operador"));
        relay.validateAndPay(eid);
    }

    function testRevert_insufficientFunds() public {
        vm.prank(donor);
        relay.donate(k1, 20 * K);   // só 4 refeições cabem (preço 5)

        vm.prank(operator1);
        uint256 eid = relay.submitMealEvent(k1, 10, keccak256("x"), 0, 0);
        vm.prank(validator);
        vm.expectRevert(bytes("Saldo da cozinha insuficiente"));
        relay.validateAndPay(eid);
    }

    function testRevert_mealCountTooLarge() public {
        vm.prank(operator1);
        vm.expectRevert(bytes("Count invalido"));
        relay.submitMealEvent(k1, 9_999, keccak256("x"), 0, 0);
    }

    function testRevert_zeroMealCount() public {
        vm.prank(operator1);
        vm.expectRevert(bytes("Count invalido"));
        relay.submitMealEvent(k1, 0, keccak256("x"), 0, 0);
    }

    function testRevert_emptyPhoto() public {
        vm.prank(operator1);
        vm.expectRevert(bytes("Foto obrigatoria"));
        relay.submitMealEvent(k1, 10, bytes32(0), 0, 0);
    }

    // ============================ Views ============================

    function test_avgCostPerMeal() public {
        vm.prank(donor);
        relay.donate(k1, 500 * K);

        vm.prank(operator1);
        uint256 eid = relay.submitMealEvent(k1, 50, keccak256("a"), 0, 0);
        vm.prank(validator); relay.validateAndPay(eid);

        vm.prank(operator1);
        uint256 eid2 = relay.submitMealEvent(k1, 30, keccak256("b"), 0, 0);
        vm.prank(validator); relay.validateAndPay(eid2);

        // total spent = 80 * 5 = 400 USDC, total meals = 80. avg = 5 USDC.
        assertEq(relay.avgCostPerMeal(k1), PRICE);
    }
}
