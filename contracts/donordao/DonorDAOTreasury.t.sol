// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {DonorDAOTreasury} from "./DonorDAOTreasury.sol";
import {MockUSDC} from "../shared/MockUSDC.sol";

contract DonorDAOTreasuryTest is Test {
    DonorDAOTreasury internal dao;
    MockUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal ngo1 = makeAddr("ngo1");
    address internal ngo2 = makeAddr("ngo2");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint128 internal constant K = 1e6; // 1 USDC = 1e6 wei

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(admin);
        dao = new DonorDAOTreasury(admin, usdc);

        vm.startPrank(admin);
        dao.grantRoleByAdmin(dao.NGO_ROLE(), ngo1);
        dao.grantRoleByAdmin(dao.NGO_ROLE(), ngo2);
        vm.stopPrank();

        // Funda doadores e dá approve.
        for (uint256 i = 0; i < 3; i++) {
            address d = [alice, bob, carol][i];
            usdc.mint(d, 100_000 * K);
            vm.prank(d);
            usdc.approve(address(dao), type(uint256).max);
        }
    }

    // ============================ Deposit / Withdraw ============================

    function test_deposit_increasesContribution() public {
        vm.prank(alice);
        dao.deposit(10_000 * K);
        (uint128 contrib, uint32 votes) = dao.members(alice);
        assertEq(contrib, 10_000 * K);
        assertEq(votes, 0);
        assertEq(dao.totalContributed(), 10_000 * K);
    }

    function test_withdraw_returnsUnusedFunds() public {
        vm.prank(alice);
        dao.deposit(10_000 * K);
        vm.prank(alice);
        dao.withdraw(4_000 * K);
        (uint128 contrib,) = dao.members(alice);
        assertEq(contrib, 6_000 * K);
        assertEq(usdc.balanceOf(alice), 94_000 * K);
    }

    function testRevert_withdraw_lockedDuringVote() public {
        vm.prank(alice);
        dao.deposit(10_000 * K);

        vm.prank(ngo1);
        uint256 pid = dao.submitProposal("Aulas reforco", keccak256("ipfs-hash-x"), 5_000 * K);
        vm.prank(alice);
        dao.vote(pid, true);

        vm.prank(alice);
        vm.expectRevert(bytes("Voto pendente trava saldo"));
        dao.withdraw(1_000 * K);
    }

    // ============================ Proposal / Vote / Execute ============================

    function test_approvedProposal_transfersToNGO() public {
        _deposit(alice, 50_000 * K);
        _deposit(bob, 30_000 * K);
        _deposit(carol, 20_000 * K); // total = 100k

        vm.prank(ngo1);
        uint256 pid = dao.submitProposal("Aulas reforco", keccak256("p1"), 25_000 * K);

        // Quorum mínimo = 30k. yes/total >= 60%.
        // alice (50k) yes, bob (30k) yes, carol (20k) no → yes 80k, no 20k → aprovado.
        vm.prank(alice); dao.vote(pid, true);
        vm.prank(bob);   dao.vote(pid, true);
        vm.prank(carol); dao.vote(pid, false);

        vm.warp(block.timestamp + 7 days + 1);
        dao.execute(pid);

        (,,,,,,, DonorDAOTreasury.ProposalStatus status,) = dao.proposals(pid);
        assertEq(uint8(status), uint8(DonorDAOTreasury.ProposalStatus.APPROVED));
        assertEq(usdc.balanceOf(ngo1), 25_000 * K);
        assertEq(dao.totalExecuted(), 25_000 * K);
    }

    function test_rejectedByMajority() public {
        _deposit(alice, 50_000 * K);
        _deposit(bob, 30_000 * K);
        _deposit(carol, 20_000 * K);

        vm.prank(ngo1);
        uint256 pid = dao.submitProposal("Projeto fraco", keccak256("p1"), 10_000 * K);

        vm.prank(alice); dao.vote(pid, false);    // 50k no
        vm.prank(bob);   dao.vote(pid, true);     // 30k yes
        vm.prank(carol); dao.vote(pid, true);     // 20k yes

        // Total = 100k, quorum atingido. yes = 50k / 100k = 50% < 60% → reject.
        vm.warp(block.timestamp + 7 days + 1);
        dao.execute(pid);

        (,,,,,,, DonorDAOTreasury.ProposalStatus status,) = dao.proposals(pid);
        assertEq(uint8(status), uint8(DonorDAOTreasury.ProposalStatus.REJECTED));
        assertEq(usdc.balanceOf(ngo1), 0);
    }

    function test_rejectedByQuorumFail() public {
        _deposit(alice, 50_000 * K);
        _deposit(bob, 30_000 * K);
        _deposit(carol, 20_000 * K); // quorum = 30k

        vm.prank(ngo1);
        uint256 pid = dao.submitProposal("Pouca gente votou", keccak256("p1"), 5_000 * K);
        vm.prank(carol); dao.vote(pid, true); // 20k yes — não bate quorum

        vm.warp(block.timestamp + 7 days + 1);
        dao.execute(pid);

        (,,,,,,, DonorDAOTreasury.ProposalStatus status,) = dao.proposals(pid);
        assertEq(uint8(status), uint8(DonorDAOTreasury.ProposalStatus.REJECTED));
    }

    function test_executeUnlocksWithdraw() public {
        _deposit(alice, 10_000 * K);
        vm.prank(ngo1);
        uint256 pid = dao.submitProposal("X", keccak256("h"), 2_000 * K);
        vm.prank(alice); dao.vote(pid, true);

        (, uint32 openBefore) = dao.members(alice);
        assertEq(openBefore, 1);

        vm.warp(block.timestamp + 7 days + 1);
        dao.execute(pid);

        (, uint32 openAfter) = dao.members(alice);
        assertEq(openAfter, 0);

        // Agora alice pode withdraw da fatia restante.
        vm.prank(alice);
        dao.withdraw(3_000 * K);
    }

    // ============================ Defesas ============================

    function testRevert_proposalExceedsTreasury() public {
        _deposit(alice, 10_000 * K);
        vm.prank(ngo1);
        vm.expectRevert(bytes("Excede saldo da treasury"));
        dao.submitProposal("Gigante", keccak256("h"), 999_999 * K);
    }

    function testRevert_doubleVote() public {
        _deposit(alice, 10_000 * K);
        vm.prank(ngo1);
        uint256 pid = dao.submitProposal("X", keccak256("h"), 1_000 * K);
        vm.prank(alice); dao.vote(pid, true);
        vm.prank(alice);
        vm.expectRevert(bytes("Ja votou"));
        dao.vote(pid, false);
    }

    function testRevert_voteWithoutPower() public {
        // Bob deposita só para que a treasury aceite a proposta — alice (sem deposit)
        // ainda não pode votar.
        _deposit(bob, 5_000 * K);
        vm.prank(ngo1);
        uint256 pid = dao.submitProposal("X", keccak256("h"), 1);
        vm.prank(alice);
        vm.expectRevert(bytes("Sem voting power"));
        dao.vote(pid, true);
    }

    function testRevert_executeBeforeDeadline() public {
        _deposit(alice, 10_000 * K);
        vm.prank(ngo1);
        uint256 pid = dao.submitProposal("X", keccak256("h"), 1_000 * K);
        vm.prank(alice); dao.vote(pid, true);
        vm.expectRevert(bytes("Votacao em andamento"));
        dao.execute(pid);
    }

    // ============================ Helpers ============================

    function _deposit(address d, uint128 amount) internal {
        vm.prank(d);
        dao.deposit(amount);
    }
}
