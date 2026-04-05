// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

contract yPotDisputeTest is Test {
    uint256 private constant BPS = 10_000;

    uint8 private constant ST_OPEN = 0;
    uint8 private constant ST_CLOSED = 1;
    uint8 private constant ST_RESOLVED = 2;
    uint8 private constant ST_CLAIMABLE = 3;
    uint8 private constant ST_CANCELLED = 4;
    uint8 private constant ST_REPORTED = 5;
    uint8 private constant ST_APPEALABLE = 7;

    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    address internal treasury = address(0xBEEF);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);

    address internal creator = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal reporter = address(0x3333);
    address internal challenger = address(0x4444);

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockUSDC();
        yearn = new MockERC4626Vault(usdc);

        address[] memory initialDepositors = new address[](1);
        initialDepositors[0] = address(this);
        wrapper = new YearnWrapper(usdc, IERC4626(address(yearn)), initialDepositors);

        address[] memory oracles = new address[](2);
        oracles[0] = oracle0;
        oracles[1] = oracle1;
        pot = new yPot(address(usdc), address(wrapper), treasury, oracles);
        wrapper.setDepositor(address(pot), true);

        _mintApprove(creator, 1_000_000e6);
        _mintApprove(alice, 1_000_000e6);
        _mintApprove(bob, 1_000_000e6);
        _mintApprove(reporter, 1_000_000e6);
        _mintApprove(challenger, 1_000_000e6);
    }

    function test_challenge_committeeFinalize_claimPartialThenRest() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        _closeAndReportAndChallenge(id, dl, rt, 1, 2);

        _committeeResolve(id, 2);

        (,,,,,, uint8 outcomes, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(outcomes, 2);
        assertEq(winner, 2);
        assertEq(status, ST_APPEALABLE);

        (uint64 appealDeadline,,,) = pot.getAppealInfo(id);

        vm.warp(uint256(appealDeadline) + 24 hours + 1);
        pot.finalize(id);

        (,,,,,,,, status,,) = pot.getMkt(id);
        assertEq(status, ST_CLAIMABLE);

        (,, uint256 totalShares,,) = pot.getShares(id);
        uint256 halfShares = totalShares / 2;

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pot.claim(id, halfShares, 0);
        uint256 bobAfter = usdc.balanceOf(bob);
        assertEq(bobAfter - bobBefore, wrapper.previewRedeem(halfShares));

        bobBefore = bobAfter;
        vm.prank(bob);
        pot.claim(id, 0, 0);
        bobAfter = usdc.balanceOf(bob);
        assertEq(bobAfter - bobBefore, wrapper.previewRedeem(totalShares - halfShares));

        vm.prank(alice);
        vm.expectRevert(yPot.E1.selector);
        pot.claim(id, 0, 0);
    }

    function test_finalize_reverts_before_appeal_deadline() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        _closeAndReportAndChallenge(id, dl, rt, 1, 2);
        _committeeResolve(id, 2);

        (uint64 appealDeadline,,,) = pot.getAppealInfo(id);
        vm.warp(uint256(appealDeadline));

        vm.expectRevert(yPot.E2.selector);
        pot.finalize(id);

        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_APPEALABLE);
    }

    function test_claim_reverts_when_not_claimable() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        _closeAndReportAndChallenge(id, dl, rt, 1, 2);
        _committeeResolve(id, 2);

        vm.prank(bob);
        vm.expectRevert(yPot.E2.selector);
        pot.claim(id, 0, 0);
    }

    function test_finalize_cancels_when_winner_has_no_bets_then_emergencyWithdraw() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(reporter, id, 1, 50e6);

        _closeAndReportAndChallenge(id, dl, rt, 1, 2);
        _committeeResolve(id, 2);

        (uint64 appealDeadline,,,) = pot.getAppealInfo(id);
        vm.warp(uint256(appealDeadline) + 24 hours + 1);
        pot.finalize(id);

        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_CANCELLED);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.emergencyWithdraw(id, 0);
        uint256 aliceAfter = usdc.balanceOf(alice);
        assertEq(aliceAfter - aliceBefore, 100e6);
    }

    function test_withdrawConfirmBond_reverts_while_report_is_still_unchallenged() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(alice);
        pot.confirmReport(id, 50e6, 0, block.timestamp + 1);

        vm.prank(alice);
        vm.expectRevert(yPot.E2.selector);
        pot.withdrawConfirmBond(id, 0, 0);

        (uint256 remainingConfirmShares,,) = pot.getConfirm(id, alice);
        assertGt(remainingConfirmShares, 0);
    }

    function test_withdrawConfirmBond_unlocks_immediately_after_challenge() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(alice);
        pot.confirmReport(id, 50e6, 0, block.timestamp + 1);

        (uint256 confirmSharesBefore,,) = pot.getConfirm(id, alice);
        uint256 expectedOut = wrapper.previewRedeem(confirmSharesBefore);

        vm.prank(challenger);
        pot.challenge(id, 2);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.withdrawConfirmBond(id, 0, 0);
        uint256 aliceAfter = usdc.balanceOf(alice);

        assertEq(aliceAfter - aliceBefore, expectedOut);
        (uint256 remainingConfirmShares,,) = pot.getConfirm(id, alice);
        assertEq(remainingConfirmShares, 0);
    }

    function test_withdrawConfirmBond_succeeds_during_appealable() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(alice);
        pot.confirmReport(id, 50e6, 0, block.timestamp + 1);

        vm.prank(challenger);
        pot.challenge(id, 2);
        _committeeResolve(id, 2);

        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_APPEALABLE);

        (uint256 confirmSharesBefore,,) = pot.getConfirm(id, alice);
        uint256 expectedOut = wrapper.previewRedeem(confirmSharesBefore);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.withdrawConfirmBond(id, 0, 0);
        uint256 aliceAfter = usdc.balanceOf(alice);

        assertEq(aliceAfter - aliceBefore, expectedOut);
        (uint256 remainingConfirmShares,,) = pot.getConfirm(id, alice);
        assertEq(remainingConfirmShares, 0);
    }

    function test_reporter_cannot_challenge_own_report() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(reporter);
        vm.expectRevert(yPot.E3.selector);
        pot.challenge(id, 2);
    }

    function test_defaultEconomics_minRake_coversTruthBounty() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 1e6);
        _bet(bob, id, 2, 1e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        uint256 bond = pot.calcReportBond(id);
        assertEq(bond, pot.minReportBond());

        uint256 minRake = (bond * pot.disputeRakeBps()) / BPS;
        uint256 truthBounty = (pot.fee() * 2000) / BPS;
        assertGe(minRake, truthBounty, "rake must dominate bounty at minimum bond");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _mintApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }

    function _create2OutcomeMarket() internal returns (uint256 id, uint64 dl, uint64 rt) {
        dl = uint64(block.timestamp + 14 days + 1);
        rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        id = pot.create("local test market", "bafyLocalTest", dl, rt, 2, "", address(0));

        (,, uint64 created, uint64 deadline, uint64 resTime,, uint8 outcomes,, uint8 status, address mCreator,) =
            pot.getMkt(id);
        assertEq(created, uint64(block.timestamp));
        assertEq(deadline, dl);
        assertEq(resTime, rt);
        assertEq(outcomes, 2);
        assertEq(status, ST_OPEN);
        assertEq(mCreator, creator);
    }

    function _bet(address who, uint256 id, uint8 outcome, uint256 amount) internal {
        vm.prank(who);
        pot.bet(id, outcome, amount, 0, block.timestamp + 1);
    }

    function _closeAndReportAndChallenge(
        uint256 id,
        uint64 dl,
        uint64 rt,
        uint8 reportedOutcome,
        uint8 challengedOutcome
    ) internal {
        vm.warp(uint256(dl) + 1);
        pot.close(id);

        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_CLOSED);

        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, reportedOutcome);

        (,,,,,,,, status,,) = pot.getMkt(id);
        assertEq(status, ST_REPORTED);

        vm.prank(challenger);
        pot.challenge(id, challengedOutcome);
    }

    function _committeeResolve(uint256 id, uint8 outcome) internal {
        vm.prank(oracle0);
        pot.resolveDispute(id, outcome);
        vm.prank(oracle1);
        pot.resolveDispute(id, outcome);
    }
}
