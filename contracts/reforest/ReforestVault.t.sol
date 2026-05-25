// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ReforestVault} from "./ReforestVault.sol";
import {TreeNFT} from "./TreeNFT.sol";
import {MockUSDC} from "../shared/MockUSDC.sol";

contract ReforestVaultTest is Test {
    ReforestVault internal vault;
    TreeNFT internal nft;
    MockUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal planter = makeAddr("planter");
    address internal oracle = makeAddr("oracle");
    address internal donorA = makeAddr("donorA");
    address internal donorB = makeAddr("donorB");

    bytes32 internal GEO_ROLE;
    bytes32 internal MINTER_ROLE;

    function setUp() public {
        usdc = new MockUSDC();
        vm.startPrank(admin);
        nft = new TreeNFT(admin);
        vault = new ReforestVault(admin, IERC20(address(usdc)), nft);
        MINTER_ROLE = nft.MINTER_ROLE();
        GEO_ROLE = vault.GEO_ORACLE_ROLE();
        nft.grantRoleByAdmin(MINTER_ROLE, address(vault));
        vault.grantRoleByAdmin(GEO_ROLE, oracle);
        vm.stopPrank();

        // Funda doadores.
        usdc.mint(donorA, 100_000 * 10 ** 6);
        usdc.mint(donorB, 100_000 * 10 ** 6);
        vm.prank(donorA);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(donorB);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ============================ Project creation ============================

    function test_createProject() public {
        vm.prank(admin);
        uint256 projectId = vault.createProject(
            planter,
            keccak256("polygon-fazenda-XYZ"),
            "Ipe-amarelo",
            int256(-19_900_000), // -19.9 * 1e6
            int256(-43_950_000),
            1_000,
            10_000 * 10 ** 6
        );
        assertEq(projectId, 1);
    }

    function testRevert_createProject_zeroPlanter() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Planter invalido"));
        vault.createProject(address(0), keccak256("g"), "x", 0, 0, 100, 1000);
    }

    function testRevert_createProject_notAdmin() public {
        vm.prank(planter);
        vm.expectRevert();
        vault.createProject(planter, keccak256("g"), "x", 0, 0, 100, 1000);
    }

    // ============================ Donation + NFT ============================

    function test_donateWithoutNft() public {
        uint256 pid = _seedProject();

        vm.prank(donorA);
        vault.donate(pid, 5_000 * 10 ** 6, false);

        assertEq(usdc.balanceOf(address(vault)), 5_000 * 10 ** 6);
        assertEq(nft.balanceOf(donorA), 0, "Sem opt-in pra NFT");
    }

    function test_donateWithNft_mintsCertificate() public {
        uint256 pid = _seedProject();

        vm.prank(donorA);
        vault.donate(pid, 5_000 * 10 ** 6, true);

        assertEq(nft.balanceOf(donorA), 1, "Donor deve receber 1 NFT");
        (uint256 projId, string memory species, , , , address originalDonor) =
            nft.metadata(1);
        assertEq(projId, pid);
        assertEq(species, "Ipe-amarelo");
        assertEq(originalDonor, donorA);
    }

    function testRevert_donateAboveBudget() public {
        uint256 pid = _seedProject(); // budget 10_000 USDC

        vm.prank(donorA);
        vm.expectRevert(bytes("Excede orcamento"));
        vault.donate(pid, 11_000 * 10 ** 6, false);
    }

    // ============================ Planted declaration ============================

    function testRevert_declarePlanted_notPlanter() public {
        uint256 pid = _seedProject();
        vm.prank(donorA);
        vm.expectRevert(bytes("Apenas plantador"));
        vault.declarePlanted(pid);
    }

    function test_declarePlanted_setsTimestamp() public {
        uint256 pid = _seedProject();
        vm.prank(planter);
        vault.declarePlanted(pid);
        (, , , , , , , , , uint64 plantedAt, ) = vault.projects(pid);
        assertEq(plantedAt, uint64(block.timestamp));
    }

    // ============================ Milestones ============================

    function test_milestoneM0_approved_releases10Percent() public {
        uint256 pid = _seedFundedAndPlanted(10_000 * 10 ** 6);

        // M0: prazo = plantedAt + 0 → imediatamente disponível.
        uint256 planterBalanceBefore = usdc.balanceOf(planter);
        vm.prank(oracle);
        vault.reportMilestone(pid, ReforestVault.Milestone.M0, 9_000, bytes32(0)); // 90% sobrevivência

        // 10% de 10_000 = 1_000 USDC.
        assertEq(usdc.balanceOf(planter) - planterBalanceBefore, 1_000 * 10 ** 6);
    }

    function test_milestoneM6_rejected_doesNotRelease() public {
        uint256 pid = _seedFundedAndPlanted(10_000 * 10 ** 6);

        vm.warp(block.timestamp + 180 days);
        uint256 before_ = usdc.balanceOf(planter);
        vm.prank(oracle);
        vault.reportMilestone(pid, ReforestVault.Milestone.M6, 5_000, bytes32(0)); // 50% < 75% threshold
        assertEq(usdc.balanceOf(planter), before_, "Rejeitado nao deve pagar");
    }

    function testRevert_milestoneOutOfWindow() public {
        uint256 pid = _seedFundedAndPlanted(10_000 * 10 ** 6);

        // M6 sem ter passado 180 dias → revert.
        vm.prank(oracle);
        vm.expectRevert(bytes("Milestone fora do prazo"));
        vault.reportMilestone(pid, ReforestVault.Milestone.M6, 9_000, bytes32(0));
    }

    function testRevert_milestoneTwice() public {
        uint256 pid = _seedFundedAndPlanted(10_000 * 10 ** 6);
        vm.prank(oracle);
        vault.reportMilestone(pid, ReforestVault.Milestone.M0, 9_000, bytes32(0));

        vm.prank(oracle);
        vm.expectRevert(bytes("Milestone ja reportado"));
        vault.reportMilestone(pid, ReforestVault.Milestone.M0, 9_000, bytes32(0));
    }

    function testRevert_milestoneByNonOracle() public {
        uint256 pid = _seedFundedAndPlanted(10_000 * 10 ** 6);
        vm.prank(planter);
        vm.expectRevert();
        vault.reportMilestone(pid, ReforestVault.Milestone.M0, 9_000, bytes32(0));
    }

    // ============================ Refund ============================

    function test_refund_proRataAfterM36Failed() public {
        // 2 doadores: donorA 7k, donorB 3k. Total 10k.
        uint256 pid = _seedProject();
        vm.prank(donorA);
        vault.donate(pid, 7_000 * 10 ** 6, false);
        vm.prank(donorB);
        vault.donate(pid, 3_000 * 10 ** 6, false);

        vm.prank(planter);
        vault.declarePlanted(pid);

        // M0 aprovado → 1_000 USDC já saiu para o planter.
        vm.prank(oracle);
        vault.reportMilestone(pid, ReforestVault.Milestone.M0, 9_000, bytes32(0));

        // M6/M12/M36 todos REPROVADOS (survival < threshold). Total released = 1_000.
        vm.warp(block.timestamp + 180 days);
        vm.prank(oracle);
        vault.reportMilestone(pid, ReforestVault.Milestone.M6, 0, bytes32(0));

        vm.warp(block.timestamp + 200 days);
        vm.prank(oracle);
        vault.reportMilestone(pid, ReforestVault.Milestone.M12, 0, bytes32(0));

        vm.warp(block.timestamp + 800 days);
        vm.prank(oracle);
        vault.reportMilestone(pid, ReforestVault.Milestone.M36, 0, bytes32(0));

        // Restante 9_000 USDC para reembolsar. Pro-rata:
        //   donorA = 9_000 * 7_000 / 10_000 = 6_300
        //   donorB = 9_000 * 3_000 / 10_000 = 2_700
        uint256 balABefore = usdc.balanceOf(donorA);
        vm.prank(donorA);
        vault.refund(pid);
        assertEq(usdc.balanceOf(donorA) - balABefore, 6_300 * 10 ** 6);

        uint256 balBBefore = usdc.balanceOf(donorB);
        vm.prank(donorB);
        vault.refund(pid);
        assertEq(usdc.balanceOf(donorB) - balBBefore, 2_700 * 10 ** 6);
    }

    function testRevert_refundBeforeM36Resolved() public {
        uint256 pid = _seedFundedAndPlanted(10_000 * 10 ** 6);
        vm.prank(donorA);
        vm.expectRevert(bytes("Aguardar resolucao do milestone final"));
        vault.refund(pid);
    }

    // ============================ Helpers ============================

    function _seedProject() private returns (uint256) {
        vm.prank(admin);
        return vault.createProject(
            planter,
            keccak256("polygon-fazenda-XYZ"),
            "Ipe-amarelo",
            int256(-19_900_000),
            int256(-43_950_000),
            1_000,
            10_000 * 10 ** 6
        );
    }

    function _seedFundedAndPlanted(uint128 funding) private returns (uint256 pid) {
        pid = _seedProject();
        vm.prank(donorA);
        vault.donate(pid, funding, false);
        vm.prank(planter);
        vault.declarePlanted(pid);
    }
}
