// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";

import {AquaGuardRegistry} from "./AquaGuardRegistry.sol";

contract AquaGuardRegistryTest is Test {
    AquaGuardRegistry internal reg;

    address internal admin = makeAddr("admin");
    address internal g1 = makeAddr("g1");
    address internal g2 = makeAddr("g2");
    address internal g3 = makeAddr("g3");
    address internal g4 = makeAddr("g4");

    uint256 internal stationId;

    function setUp() public {
        vm.prank(admin);
        reg = new AquaGuardRegistry(admin);

        vm.startPrank(admin);
        bytes32 role = reg.GUARDIAN_ROLE();
        reg.grantRoleByAdmin(role, g1);
        reg.grantRoleByAdmin(role, g2);
        reg.grantRoleByAdmin(role, g3);
        reg.grantRoleByAdmin(role, g4);

        stationId = reg.registerStation(
            keccak256("Bacia-Paraiba-do-Sul/PontoX"),
            -22_900_000, -43_200_000,
            600, 900,    // pH 6.00..9.00
            500,         // DO >= 5.00 mg/L
            100          // turb <= 100 NTU
        );
        vm.stopPrank();
    }

    // ============================ Submissão ============================

    function test_submit_accumulates() public {
        _submit(g1, 720, 700, 30);
        _submit(g2, 715, 690, 32);
        _submit(g3, 730, 705, 28);

        uint64 ep = reg.currentEpoch();
        (int64 phSum, int64 doSum, uint64 turbSum, uint8 count, bool finalized) = reg.epochs(stationId, ep);
        assertEq(count, 3);
        assertFalse(finalized);
        assertEq(phSum, 720 + 715 + 730);
        assertEq(doSum, 700 + 690 + 705);
        assertEq(turbSum, 30 + 32 + 28);
    }

    function testRevert_doubleSubmissionSameEpoch() public {
        _submit(g1, 720, 700, 30);
        vm.expectRevert(bytes("Ja reportou neste epoch"));
        _submit(g1, 720, 700, 30);
    }

    function testRevert_nonGuardian() public {
        address rogue = makeAddr("rogue");
        vm.prank(rogue);
        vm.expectRevert();
        reg.submitReading(stationId, 720, 700, 30);
    }

    // ============================ Finalize sem alerta ============================

    function test_finalize_noViolations() public {
        _submit(g1, 720, 700, 30);
        _submit(g2, 715, 690, 32);
        _submit(g3, 730, 705, 28);

        uint64 ep = reg.currentEpoch();
        // Pula para o próximo epoch para liberar finalização.
        vm.warp(block.timestamp + 1 days + 1);

        vm.recordLogs();
        reg.finalizeEpoch(stationId, ep);
        // Não deve ter AlertRaised — todos parâmetros dentro de threshold.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool alertFound = false;
        bytes32 alertTopic = keccak256("AlertRaised(uint256,uint64,uint8)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == alertTopic) {
                alertFound = true;
                break;
            }
        }
        assertFalse(alertFound, "Nao deveria ter alerta");
    }

    // ============================ Finalize com alerta ============================

    function test_finalize_phViolation_raisesAlert() public {
        // pH médio = 545 < 600 → bit0 violado
        _submit(g1, 540, 700, 30);
        _submit(g2, 555, 700, 30);
        _submit(g3, 540, 700, 30);

        uint64 ep = reg.currentEpoch();
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectEmit(true, true, false, true);
        emit AquaGuardRegistry.AlertRaised(stationId, ep, 1); // bit0 = pH
        reg.finalizeEpoch(stationId, ep);
    }

    function test_finalize_multipleViolations_combinedBitmask() public {
        // pH médio 1000 > 900 (bit0); DO médio 100 < 500 (bit1); turb médio 500 > 100 (bit2) = 7
        _submit(g1, 1000, 100, 500);
        _submit(g2, 1000, 100, 500);
        _submit(g3, 1000, 100, 500);
        uint64 ep = reg.currentEpoch();
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectEmit(true, true, false, true);
        emit AquaGuardRegistry.AlertRaised(stationId, ep, 7);
        reg.finalizeEpoch(stationId, ep);
    }

    // ============================ Reputação ============================

    function test_reputation_honestVsOutlier() public {
        // g1, g2, g3 reportam próximos; g4 muito diferente
        _submit(g1, 720, 700, 30);
        _submit(g2, 715, 695, 32);
        _submit(g3, 725, 705, 31);
        _submit(g4, 880, 900, 95);  // outlier — fora da tolerância

        uint64 ep = reg.currentEpoch();
        vm.warp(block.timestamp + 1 days + 1);
        reg.finalizeEpoch(stationId, ep);

        (uint256 hG1, uint256 tG1,) = reg.reputation(g1);
        (uint256 hG4, uint256 tG4,) = reg.reputation(g4);
        assertEq(hG1, 1);
        assertEq(tG1, 1);
        assertEq(hG4, 0);
        assertEq(tG4, 1);
    }

    // ============================ Guard rails ============================

    function testRevert_finalizeBeforeEpochEnd() public {
        _submit(g1, 720, 700, 30);
        _submit(g2, 715, 695, 32);
        _submit(g3, 725, 705, 31);
        uint64 ep = reg.currentEpoch();
        vm.expectRevert(bytes("Epoch ainda aberto"));
        reg.finalizeEpoch(stationId, ep);
    }

    function testRevert_finalizeTooFewReadings() public {
        _submit(g1, 720, 700, 30);
        _submit(g2, 715, 695, 32);
        uint64 ep = reg.currentEpoch();
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(bytes("Insuficientes leituras"));
        reg.finalizeEpoch(stationId, ep);
    }

    function testRevert_doubleFinalize() public {
        _submit(g1, 720, 700, 30);
        _submit(g2, 715, 695, 32);
        _submit(g3, 725, 705, 31);
        uint64 ep = reg.currentEpoch();
        vm.warp(block.timestamp + 1 days + 1);
        reg.finalizeEpoch(stationId, ep);
        vm.expectRevert(bytes("Epoch ja finalizado"));
        reg.finalizeEpoch(stationId, ep);
    }

    // ============================ Helpers ============================

    function _submit(address g, int16 ph, int32 doVal, uint16 turb) internal {
        vm.prank(g);
        reg.submitReading(stationId, ph, doVal, turb);
    }
}
