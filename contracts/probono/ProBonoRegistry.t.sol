// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {ProBonoRegistry} from "./ProBonoRegistry.sol";

contract ProBonoRegistryTest is Test {
    ProBonoRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal validator = makeAddr("validator");
    address internal lawyerA = makeAddr("lawyerA");
    address internal lawyerB = makeAddr("lawyerB");

    bytes32 internal constant CASE_REF_1 = keccak256("processo-X-2026");
    bytes32 internal constant CASE_REF_2 = keccak256("processo-Y-2026");

    function setUp() public {
        vm.prank(admin);
        registry = new ProBonoRegistry(admin);
        bytes32 role = registry.DJE_VALIDATOR_ROLE();
        vm.prank(admin);
        registry.grantRoleByAdmin(role, validator);
    }

    function test_validateHour_mintsSbt() public {
        vm.prank(validator);
        uint256 tokenId = registry.validateHour(
            lawyerA, CASE_REF_1, 5, 1, 1, "DJE-2026-001"
        );
        assertEq(tokenId, 1);
        assertEq(registry.ownerOf(tokenId), lawyerA);
        assertEq(registry.totalHoursOf(lawyerA), 1);
        assertEq(registry.hoursByOdsOf(lawyerA, 5), 1);
    }

    function test_multipleHoursAccumulate() public {
        vm.startPrank(validator);
        registry.validateHour(lawyerA, CASE_REF_1, 5, 1, 1, "DJE-1");
        registry.validateHour(lawyerA, CASE_REF_1, 5, 1, 2, "DJE-1");
        registry.validateHour(lawyerA, CASE_REF_1, 5, 1, 3, "DJE-1");
        vm.stopPrank();

        assertEq(registry.totalHoursOf(lawyerA), 3);
        assertEq(registry.hoursByOdsOf(lawyerA, 5), 3);
        assertEq(registry.balanceOf(lawyerA), 3);
    }

    function test_hoursAcrossOdsTrackedSeparately() public {
        vm.startPrank(validator);
        registry.validateHour(lawyerA, CASE_REF_1, 5, 1, 1, "DJE-1");
        registry.validateHour(lawyerA, CASE_REF_2, 13, 8, 1, "DJE-2");
        vm.stopPrank();

        assertEq(registry.totalHoursOf(lawyerA), 2);
        assertEq(registry.hoursByOdsOf(lawyerA, 5), 1);
        assertEq(registry.hoursByOdsOf(lawyerA, 13), 1);
    }

    // ============================ Defesas ============================

    function testRevert_duplicateHourIndex() public {
        vm.startPrank(validator);
        registry.validateHour(lawyerA, CASE_REF_1, 5, 1, 1, "DJE-1");
        vm.expectRevert(bytes("Hora ja validada"));
        registry.validateHour(lawyerA, CASE_REF_1, 5, 1, 1, "DJE-1");
        vm.stopPrank();
    }

    function testRevert_odsOutOfRange() public {
        vm.startPrank(validator);
        vm.expectRevert(bytes("ODS deve estar em 1..17"));
        registry.validateHour(lawyerA, CASE_REF_1, 0, 1, 1, "DJE-1");
        vm.expectRevert(bytes("ODS deve estar em 1..17"));
        registry.validateHour(lawyerA, CASE_REF_1, 18, 1, 1, "DJE-1");
        vm.stopPrank();
    }

    function testRevert_emptyDjeProof() public {
        vm.prank(validator);
        vm.expectRevert(bytes("Prova DJE obrigatoria"));
        registry.validateHour(lawyerA, CASE_REF_1, 5, 1, 1, "");
    }

    function testRevert_validateByNonValidator() public {
        vm.prank(lawyerA);
        vm.expectRevert();
        registry.validateHour(lawyerA, CASE_REF_1, 5, 1, 1, "DJE-1");
    }

    // ============================ Soulbound ============================

    function testRevert_sbtTransferIsBlocked() public {
        vm.prank(validator);
        uint256 tokenId = registry.validateHour(lawyerA, CASE_REF_1, 5, 1, 1, "DJE-1");

        vm.prank(lawyerA);
        vm.expectRevert(bytes("SBT: nao transferivel"));
        registry.transferFrom(lawyerA, lawyerB, tokenId);
    }

    function testRevert_safeTransferFromIsBlocked() public {
        vm.prank(validator);
        uint256 tokenId = registry.validateHour(lawyerA, CASE_REF_1, 5, 1, 1, "DJE-1");

        vm.prank(lawyerA);
        vm.expectRevert(bytes("SBT: nao transferivel"));
        registry.safeTransferFrom(lawyerA, lawyerB, tokenId);
    }
}
