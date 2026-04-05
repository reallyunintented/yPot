// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {yPot} from "../../src/yPot.sol";
import {YearnWrapper} from "../../src/YearnWrapper.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";

contract SybilTruthBountyTest is Test {
    uint256 private constant BPS = 10_000;

    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    address internal treasury = address(0xBEEFCAFE);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);

    address internal creator = address(0xC0FFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    address internal attackerReporter = address(0xDEAD);
    address internal attackerChallenger = address(0xBEEF);

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockUSDC();
        yearn = new MockERC4626Vault(usdc);

        address[] memory depositors = new address[](1);
        depositors[0] = address(this);
        wrapper = new YearnWrapper(usdc, IERC4626(address(yearn)), depositors);

        address[] memory oracles = new address[](2);
        oracles[0] = oracle0;
        oracles[1] = oracle1;
        pot = new yPot(address(usdc), address(wrapper), treasury, oracles);
        wrapper.setDepositor(address(pot), true);

        _mintApprove(creator, 1_000_000e6);
        _mintApprove(alice, 1_000_000e6);
        _mintApprove(bob, 1_000_000e6);
        _mintApprove(attackerReporter, 1_000_000e6);
        _mintApprove(attackerChallenger, 1_000_000e6);
    }

    function test_sybilReportAndChallenge_extractsTruthBounty_whenReporterWins() public {
        int256 profit = _runSybilFlow(1);
        assertEq(profit, -3e6, "self-dispute should be negative EV");
    }

    function test_sybilReportAndChallenge_extractsTruthBounty_whenChallengerWins() public {
        int256 profit = _runSybilFlow(2);
        assertEq(profit, -3e6, "self-dispute should be negative EV");
    }

    function _runSybilFlow(uint8 winner) internal returns (int256 profit) {
        uint64 deadline = uint64(block.timestamp + 14 days + 1);
        uint64 resTime = uint64(uint256(deadline) + 2 hours);

        vm.prank(creator);
        uint256 id = pot.create("sybil truth-bounty farm", "bafySybilTruthBounty", deadline, resTime, 2, "", address(0));

        vm.prank(alice);
        pot.bet(id, 1, 100e6, 0, block.timestamp + 1);

        vm.prank(bob);
        pot.bet(id, 2, 100e6, 0, block.timestamp + 1);

        vm.warp(uint256(deadline) + 1);
        pot.close(id);

        vm.warp(uint256(resTime));

        uint256 before = _attackerCluster();

        vm.prank(attackerReporter);
        pot.report(id, 1);

        vm.prank(attackerChallenger);
        pot.challenge(id, 2);

        vm.prank(oracle0);
        pot.resolveDispute(id, winner);
        vm.prank(oracle1);
        pot.resolveDispute(id, winner);

        (uint64 appealDeadline,,,) = pot.getAppealInfo(id);
        vm.warp(uint256(appealDeadline) + 24 hours + 1);

        pot.finalize(id);

        // Pull-based: withdraw pending bonds/bounties before measuring
        if (pot.pendingWithdrawals(attackerReporter) > 0) {
            vm.prank(attackerReporter);
            pot.withdrawPending();
        }
        if (pot.pendingWithdrawals(attackerChallenger) > 0) {
            vm.prank(attackerChallenger);
            pot.withdrawPending();
        }

        uint256 after_ = _attackerCluster();

        uint256 bond = pot.calcReportBond(id);
        uint256 rake = (bond * pot.disputeRakeBps()) / BPS;
        uint256 bounty = (pot.fee() * 2000) / BPS;
        assertEq(rake, 5e6);
        assertEq(bounty, 2e6);

        if (after_ >= before) {
            profit = SafeCast.toInt256(after_ - before);
        } else {
            profit = -SafeCast.toInt256(before - after_);
        }
    }

    function _attackerCluster() internal view returns (uint256) {
        return usdc.balanceOf(attackerReporter) + usdc.balanceOf(attackerChallenger);
    }

    function _mintApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }
}
