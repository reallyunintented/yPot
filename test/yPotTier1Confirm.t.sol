// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

contract yPotTier1ConfirmTest is Test {
    uint256 private constant BPS = 10_000;
    uint256 private constant YIELD_FEE_BPS = 500;
    uint256 private constant YIELD_REPORTER_REWARD_BPS = 2000;
    uint256 private constant YIELD_RESERVE_BPS = 2000;

    uint8 private constant ST_OPEN = 0;
    uint8 private constant ST_CLOSED = 1;
    uint8 private constant ST_RESOLVED = 2;
    uint8 private constant ST_CLAIMABLE = 3;
    uint8 private constant ST_CANCELLED = 4;
    uint8 private constant ST_REPORTED = 5;
    uint8 private constant ST_SWEPT = 6;

    uint256 private constant CHALLENGE_WINDOW = 48 hours;
    uint256 private constant CONFIRM_TIMEOUT = 48 hours;
    uint256 private constant DISPUTE_PERIOD = 24 hours;
    uint256 private constant SWEEP_DELAY = 30 days;

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
    }

    function test_acceptReport_uses_confirmBpsSnapshot_threshold() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        pot.setConfirmBps(5000);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        uint256 tsRt = uint256(rt);
        vm.warp(tsRt);

        vm.prank(reporter);
        pot.report(id, 1);

        (,,,, uint16 snap,,,) = pot.getReport(id);
        assertEq(uint256(snap), 5000);

        pot.setConfirmBps(0);

        (,, uint256 requiredBefore) = pot.getConfirm(id, alice);
        assertGt(requiredBefore, 0);

        vm.prank(alice);
        pot.confirmReport(id, 1e6, 0, tsRt + 1);

        (, uint256 totalConfirm1, uint256 required1) = pot.getConfirm(id, alice);
        assertLt(totalConfirm1, required1);

        uint256 tsAfterChallenge = tsRt + CHALLENGE_WINDOW + 1;
        vm.warp(tsAfterChallenge);
        vm.expectRevert(yPot.E2.selector);
        pot.acceptReport(id);

        uint256 remaining = required1 - totalConfirm1;
        uint256 assets2 = wrapper.previewMint(remaining + 1);
        vm.prank(alice);
        pot.confirmReport(id, assets2, 0, tsAfterChallenge + 1);

        uint256 reporterBefore = usdc.balanceOf(reporter);
        uint256 reportBond;
        (,, reportBond,,,,,) = pot.getReport(id);

        pot.acceptReport(id);

        vm.prank(reporter);
        pot.withdrawPending();

        (,,,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);
        assertEq(usdc.balanceOf(reporter) - reporterBefore, reportBond);
    }

    function test_acceptReport_uses_confirmBpsSnapshot_zero_allows_noConfirms() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        pot.setConfirmBps(0);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        (,,,, uint16 snap,,,) = pot.getReport(id);
        assertEq(uint256(snap), 0);

        pot.setConfirmBps(10_000);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        (,,,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);
    }

    function test_acceptReport_matrix_confirmTot_threshold_boundary() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        pot.setConfirmBps(5000);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        (,, uint256 requiredShares) = pot.getConfirm(id, alice);
        assertGt(requiredShares, 0);

        uint256 assetsShort = _assetsForAtMostShares(requiredShares - 1);
        vm.prank(alice);
        pot.confirmReport(id, assetsShort, 0, block.timestamp + 1);

        (, uint256 confirmTot,) = pot.getConfirm(id, alice);
        assertLt(confirmTot, requiredShares);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        vm.expectRevert(yPot.E2.selector);
        pot.acceptReport(id);

        uint256 remaining = requiredShares - confirmTot;
        uint256 assetsRemaining = _assetsForAtLeastShares(remaining);
        vm.prank(alice);
        pot.confirmReport(id, assetsRemaining, 0, block.timestamp + 1);

        (, uint256 confirmTot2,) = pot.getConfirm(id, alice);
        assertGe(confirmTot2, requiredShares);

        pot.acceptReport(id);
        (,,,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);
    }

    function test_confirmReport_matrix_partialSequences_and_capBoundaries() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 1, 50e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        (uint256[] memory sAlice,,,) = pot.getUsr(id, alice);
        uint256 alicePos = sAlice[1];
        assertGt(alicePos, 0);

        uint256 maxAlice = (alicePos * pot.CONFIRM_MAX_MULTIPLIER_BPS()) / BPS;
        assertGt(maxAlice, 3);

        uint256 unitShares = wrapper.previewDeposit(1);
        assertGt(unitShares, 0);

        uint256 assetsTooMuchAlice = _assetsForExactShares(maxAlice + unitShares);
        vm.prank(alice);
        vm.expectRevert(yPot.E1.selector);
        pot.confirmReport(id, assetsTooMuchAlice, 0, block.timestamp + 1);

        uint256 oneThird = maxAlice / 3;
        uint256 s1 = oneThird - (oneThird % unitShares);
        uint256 s2 = oneThird - (oneThird % unitShares);
        uint256 s3 = maxAlice - s1 - s2;
        assertGt(s1, 0);
        assertGt(s2, 0);
        assertGt(s3, 0);

        uint256 assetsS1 = _assetsForExactShares(s1);
        vm.prank(alice);
        pot.confirmReport(id, assetsS1, 0, block.timestamp + 1);
        (uint256 aliceConfirm, uint256 confirmTot,) = pot.getConfirm(id, alice);
        assertEq(aliceConfirm, s1);
        assertEq(confirmTot, s1);

        uint256 assetsS2 = _assetsForExactShares(s2);
        vm.prank(alice);
        pot.confirmReport(id, assetsS2, 0, block.timestamp + 1);
        (aliceConfirm, confirmTot,) = pot.getConfirm(id, alice);
        assertEq(aliceConfirm, s1 + s2);
        assertEq(confirmTot, s1 + s2);

        uint256 remaining = maxAlice - (s1 + s2);
        uint256 assetsTooMuchRemaining = _assetsForExactShares(remaining + unitShares);
        vm.prank(alice);
        vm.expectRevert(yPot.E1.selector);
        pot.confirmReport(id, assetsTooMuchRemaining, 0, block.timestamp + 1);

        uint256 assetsS3 = _assetsForExactShares(s3);
        vm.prank(alice);
        pot.confirmReport(id, assetsS3, 0, block.timestamp + 1);
        (aliceConfirm, confirmTot,) = pot.getConfirm(id, alice);
        assertEq(aliceConfirm, maxAlice);
        assertEq(confirmTot, maxAlice);

        vm.prank(alice);
        vm.expectRevert(yPot.E2.selector);
        pot.confirmReport(id, 1e6, 0, block.timestamp + 1);

        (uint256[] memory sBob,,,) = pot.getUsr(id, bob);
        uint256 bobPos = sBob[1];
        assertGt(bobPos, 0);

        uint256 maxBob = (bobPos * pot.CONFIRM_MAX_MULTIPLIER_BPS()) / BPS;
        assertGe(maxBob, unitShares);

        uint256 assetsBobSmall = _assetsForExactShares(unitShares);
        vm.prank(bob);
        pot.confirmReport(id, assetsBobSmall, 0, block.timestamp + 1);
        (uint256 bobConfirm, uint256 confirmTot2,) = pot.getConfirm(id, bob);
        assertEq(bobConfirm, unitShares);
        assertEq(confirmTot2, maxAlice + unitShares);

        uint256 bobRemaining = maxBob - unitShares;
        uint256 assetsTooMuchBob = _assetsForExactShares(bobRemaining + unitShares);
        vm.prank(bob);
        vm.expectRevert(yPot.E1.selector);
        pot.confirmReport(id, assetsTooMuchBob, 0, block.timestamp + 1);
    }

    function test_bet_reverts_YearnWrapperZeroAmount_when_yearnPreviewDeposit_is_zero() public {
        (uint256 id,,) = _create2OutcomeMarket();

        uint256 assetsIn = 1e6;
        uint256 yearnRateThatZeros = 1e24 + 1;
        yearn.setExchangeRate(yearnRateThatZeros);
        assertEq(yearn.previewDeposit(assetsIn), 0);

        vm.prank(alice);
        vm.expectRevert(YearnWrapper.ZeroAmount.selector);
        pot.bet(id, 1, assetsIn, 0, block.timestamp + 1);
    }

    function test_confirmReport_reverts_YearnWrapperZeroAmount_when_yearnPreviewDeposit_is_zero() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 yearnRateThatZeros = 1e24 + 1;
        _applyYearnExchangeRate(yearnRateThatZeros);

        uint256 assetsIn = 1e6;
        assertEq(yearn.previewDeposit(assetsIn), 0);

        vm.prank(alice);
        vm.expectRevert(YearnWrapper.ZeroAmount.selector);
        pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);
    }

    function testFuzz_confirmReport_respectsCap_overSequence(uint256 a0, uint256 a1, uint256 a2) public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 1, 50e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        (uint256[] memory sAlice,,,) = pot.getUsr(id, alice);
        uint256 alicePos = sAlice[1];
        assertGt(alicePos, 0);

        uint256 maxConfirm = (alicePos * pot.CONFIRM_MAX_MULTIPLIER_BPS()) / BPS;
        assertGt(maxConfirm, 0);

        uint256 unitShares = wrapper.previewDeposit(1);
        assertGt(unitShares, 0);

        uint256[3] memory fuzzAssets = [a0, a1, a2];
        for (uint256 i; i < fuzzAssets.length; i++) {
            uint256 availableAssets = usdc.balanceOf(alice);
            if (availableAssets == 0) break;

            uint256 assetsIn = bound(fuzzAssets[i], 1, availableAssets);
            uint256 expShares = wrapper.previewDeposit(assetsIn);

            (uint256 userBefore, uint256 totalBefore,) = pot.getConfirm(id, alice);
            assertEq(userBefore, totalBefore);
            assertLe(userBefore, maxConfirm);

            if (userBefore >= maxConfirm) {
                vm.prank(alice);
                vm.expectRevert(yPot.E2.selector);
                pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);
                continue;
            }

            uint256 next = userBefore + expShares;
            if (next > maxConfirm) {
                vm.prank(alice);
                vm.expectRevert(yPot.E1.selector);
                pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);
                continue;
            }

            vm.prank(alice);
            pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);

            (uint256 userAfter, uint256 totalAfter,) = pot.getConfirm(id, alice);
            assertEq(userAfter, userBefore + expShares);
            assertEq(totalAfter, userAfter);
            assertLe(userAfter, maxConfirm);
        }

        (uint256 userFinal,,) = pot.getConfirm(id, alice);
        assertLe(userFinal, maxConfirm);

        if (userFinal < maxConfirm) {
            uint256 remaining = maxConfirm - userFinal;
            uint256 overShares = remaining + unitShares;
            uint256 assetsOver = _assetsForAtLeastShares(overShares);

            uint256 availableAssets = usdc.balanceOf(alice);
            assetsOver = bound(assetsOver, 1, availableAssets);

            uint256 expOverShares = wrapper.previewDeposit(assetsOver);
            if (userFinal + expOverShares > maxConfirm) {
                vm.prank(alice);
                vm.expectRevert(yPot.E1.selector);
                pot.confirmReport(id, assetsOver, 0, block.timestamp + 1);
            }
        } else {
            vm.prank(alice);
            vm.expectRevert(yPot.E2.selector);
            pot.confirmReport(id, 1, 0, block.timestamp + 1);
        }
    }

    function testFuzz_confirmReport_twoUsers_respectsCaps_and_totals(
        uint256 a0,
        uint256 a1,
        uint256 b0,
        uint256 b1,
        bool flipOrder
    ) public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 1, 50e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        (uint256[] memory sAlice,,,) = pot.getUsr(id, alice);
        (uint256[] memory sBob,,,) = pot.getUsr(id, bob);
        uint256 alicePos = sAlice[1];
        uint256 bobPos = sBob[1];
        assertGt(alicePos, 0);
        assertGt(bobPos, 0);

        uint256 maxAlice = (alicePos * pot.CONFIRM_MAX_MULTIPLIER_BPS()) / BPS;
        uint256 maxBob = (bobPos * pot.CONFIRM_MAX_MULTIPLIER_BPS()) / BPS;
        assertGt(maxAlice, 0);
        assertGt(maxBob, 0);

        uint256 minAssets = wrapper.previewMint(1);
        uint256[4] memory raw = [a0, b0, a1, b1];
        address[4] memory who = [alice, bob, alice, bob];
        if (flipOrder) {
            raw = [b0, a0, b1, a1];
            who = [bob, alice, bob, alice];
        }

        for (uint256 i; i < raw.length; i++) {
            address actor = who[i];
            uint256 availableAssets = usdc.balanceOf(actor);
            if (availableAssets < minAssets) continue;

            uint256 assetsIn = bound(raw[i], minAssets, availableAssets);
            uint256 expShares = wrapper.previewDeposit(assetsIn);
            assertGt(expShares, 0);

            uint256 maxConfirm = actor == alice ? maxAlice : maxBob;
            (uint256 userBefore, uint256 totalBefore,) = pot.getConfirm(id, actor);
            assertLe(userBefore, maxConfirm);

            if (userBefore >= maxConfirm) {
                vm.prank(actor);
                vm.expectRevert(yPot.E2.selector);
                pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);
                continue;
            }

            if (userBefore + expShares > maxConfirm) {
                vm.prank(actor);
                vm.expectRevert(yPot.E1.selector);
                pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);
                continue;
            }

            vm.prank(actor);
            pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);

            (uint256 userAfter, uint256 totalAfter,) = pot.getConfirm(id, actor);
            assertEq(userAfter, userBefore + expShares);
            assertEq(totalAfter, totalBefore + expShares);
        }

        (uint256 aliceConfirm, uint256 totalConfirm,) = pot.getConfirm(id, alice);
        (uint256 bobConfirm,,) = pot.getConfirm(id, bob);
        assertEq(totalConfirm, aliceConfirm + bobConfirm);
        assertLe(aliceConfirm, maxAlice);
        assertLe(bobConfirm, maxBob);
    }

    function testFuzz_acceptReport_gates_on_confirmTot_vs_required(uint16 confirmBpsRaw) public {
        uint256 confirmBps = bound(uint256(confirmBpsRaw), 1, BPS);

        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        pot.setConfirmBps(confirmBps);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        (,, uint256 requiredShares) = pot.getConfirm(id, alice);
        vm.assume(requiredShares > 0);

        uint256 assetsShort = _assetsForAtMostShares(requiredShares - 1);
        vm.prank(alice);
        pot.confirmReport(id, assetsShort, 0, block.timestamp + 1);

        (, uint256 confirmTot,) = pot.getConfirm(id, alice);
        assertLt(confirmTot, requiredShares);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        vm.expectRevert(yPot.E2.selector);
        pot.acceptReport(id);

        uint256 remaining = requiredShares - confirmTot;
        uint256 assetsRemaining = _assetsForAtLeastShares(remaining);
        vm.prank(alice);
        pot.confirmReport(id, assetsRemaining, 0, block.timestamp + 1);

        (, uint256 confirmTot2,) = pot.getConfirm(id, alice);
        assertGe(confirmTot2, requiredShares);

        pot.acceptReport(id);
        (,,,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);
    }

    function test_expireUnconfirmedReport_cancels_and_refunds_reportBond() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 reportedAt;
        uint256 reportBond;
        (,, reportBond, reportedAt,,,,) = pot.getReport(id);

        vm.warp(reportedAt + CHALLENGE_WINDOW + CONFIRM_TIMEOUT + 1);

        uint256 reporterBefore = usdc.balanceOf(reporter);
        pot.expireUnconfirmedReport(id);

        vm.prank(reporter);
        pot.withdrawPending();

        (,,,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_CANCELLED);
        assertEq(usdc.balanceOf(reporter) - reporterBefore, reportBond);
    }

    function test_expireUnconfirmedReport_allows_partial_confirms_and_withdrawConfirmBond_after_cancel() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        pot.setConfirmBps(8000);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        (,, uint256 requiredShares) = pot.getConfirm(id, alice);
        assertGt(requiredShares, 1);
        uint256 targetShares = requiredShares / 2;

        uint256 assetsIn = _assetsForAtMostShares(targetShares);
        vm.prank(alice);
        pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);

        (uint256 userConfirmShares, uint256 totalConfirmShares, uint256 requiredConfirmShares) =
            pot.getConfirm(id, alice);
        assertGt(userConfirmShares, 0);
        assertLt(totalConfirmShares, requiredConfirmShares);

        uint256 reportedAt;
        uint256 reportBond;
        (,, reportBond, reportedAt,,,,) = pot.getReport(id);

        vm.warp(reportedAt + CHALLENGE_WINDOW + CONFIRM_TIMEOUT + 1);
        uint256 reporterBefore = usdc.balanceOf(reporter);
        pot.expireUnconfirmedReport(id);

        vm.prank(reporter);
        pot.withdrawPending();
        assertEq(usdc.balanceOf(reporter) - reporterBefore, reportBond);

        uint256 expectedOut = wrapper.previewRedeem(userConfirmShares);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.withdrawConfirmBond(id, 0, 0);
        assertEq(usdc.balanceOf(alice) - aliceBefore, expectedOut);

        (uint256 remainingConfirmShares,,) = pot.getConfirm(id, alice);
        assertEq(remainingConfirmShares, 0);
    }

    function test_claim_sweepDust_matrix_yieldFeeInteractions() public {
        uint256[2] memory yearnRates = [uint256(1e18), uint256(12e17)];
        uint8[2] memory patterns = [uint8(0), uint8(1)]; // 0=claimAll, 1=claimHalfThenSweep

        for (uint256 i; i < yearnRates.length; i++) {
            for (uint256 j; j < patterns.length; j++) {
                (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

                _bet(alice, id, 1, 100e6);
                _bet(bob, id, 2, 100e6);

                vm.warp(uint256(dl) + 1);
                pot.close(id);
                vm.warp(uint256(rt));

                vm.prank(reporter);
                pot.report(id, 1);

                uint256 requiredShares;
                (,, requiredShares) = pot.getConfirm(id, alice);
                uint256 confirmAssets = _assetsForAtLeastShares(requiredShares);
                vm.prank(alice);
                pot.confirmReport(id, confirmAssets, 0, block.timestamp + 1);

                uint256 acceptTs = uint256(rt) + CHALLENGE_WINDOW + 1;
                vm.warp(acceptTs);
                pot.acceptReport(id);

                (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
                assertEq(status, ST_RESOLVED);

                vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
                pot.finalize(id);
                (,,,, status,,) = _mktCore(id);
                assertEq(status, ST_CLAIMABLE);

                _applyYearnExchangeRate(yearnRates[i]);

                (,,,,,,,,,, uint256 prin) = pot.getMkt(id);
                (,, uint256 poolShares,,) = pot.getShares(id);
                assertGt(poolShares, 0);

                uint256 claimShares = patterns[j] == 0 ? 0 : (poolShares / 2);

                uint256 sharesToRedeem = claimShares == 0 ? poolShares : claimShares;
                uint256 assetsOut = wrapper.previewRedeem(sharesToRedeem);
                uint256 cp = Math.mulDiv(prin, sharesToRedeem, poolShares);
                uint256 reserveBefore = pot.reserveAssets();
                bool fullClaim = claimShares == 0 || claimShares >= poolShares;
                (uint256 payout, uint256 truthFee, uint256 treasuryFee, uint256 reserveAdded, uint256 topup) =
                    _expectedClaimSettlement(assetsOut, cp, fullClaim, reserveBefore, true);

                _flushPending(treasury);
                _flushPending(reporter);
                uint256 aliceBefore = usdc.balanceOf(alice);
                uint256 treasuryBefore = usdc.balanceOf(treasury);
                uint256 reporterBefore = usdc.balanceOf(reporter);

                vm.prank(alice);
                pot.claim(id, claimShares, 0);

                if (treasuryFee > 0) {
                    vm.prank(treasury);
                    pot.withdrawPending();
                }
                if (truthFee > 0) {
                    vm.prank(reporter);
                    pot.withdrawPending();
                }

                assertEq(usdc.balanceOf(alice) - aliceBefore, payout);
                assertEq(usdc.balanceOf(treasury) - treasuryBefore, treasuryFee);
                assertEq(usdc.balanceOf(reporter) - reporterBefore, truthFee);
                assertEq(pot.reserveAssets() + topup, reserveBefore + reserveAdded);

                if (patterns[j] == 0) {
                    (,,,, uint256 remainingShares) = pot.getShares(id);
                    assertEq(remainingShares, 0);

                    vm.warp(uint256(resolved) + DISPUTE_PERIOD + SWEEP_DELAY + 1);
                    _flushPending(treasury);
                    treasuryBefore = usdc.balanceOf(treasury);
                    pot.sweepDust(id, 1);
                    assertEq(usdc.balanceOf(treasury), treasuryBefore);
                } else {
                    (,,, uint256 claimedShares, uint256 remainingShares) = pot.getShares(id);
                    assertEq(claimedShares, sharesToRedeem);
                    assertEq(remainingShares, poolShares - sharesToRedeem);
                    assertGt(remainingShares, 0);

                    uint256 sweepOut = wrapper.previewRedeem(remainingShares);

                    vm.warp(uint256(resolved) + DISPUTE_PERIOD + SWEEP_DELAY + 1);
                    _flushPending(treasury);
                    treasuryBefore = usdc.balanceOf(treasury);
                    pot.sweepDust(id, 0);

                    _flushPending(treasury);
                    assertEq(usdc.balanceOf(treasury) - treasuryBefore, sweepOut);

                    vm.prank(alice);
                    vm.expectRevert(yPot.E2.selector);
                    pot.claim(id, 0, 0);
                }
            }
        }
    }

    function testFuzz_claim_sweepDust_feeSplit_respectsPreviewRedeem_overRates(
        uint256 rateAtClaim,
        uint256 rateAtSweep,
        uint16 claimBps,
        bool doPartialThenSweep
    ) public {
        rateAtClaim = bound(rateAtClaim, 5e17, 2e18);
        rateAtSweep = bound(rateAtSweep, 5e17, 2e18);
        claimBps = uint16(bound(uint256(claimBps), 1, 9999));

        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 requiredShares;
        (,, requiredShares) = pot.getConfirm(id, alice);
        uint256 confirmAssets = _assetsForAtLeastShares(requiredShares);
        vm.prank(alice);
        pot.confirmReport(id, confirmAssets, 0, block.timestamp + 1);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,, status,,) = _mktCore(id);
        assertEq(status, ST_CLAIMABLE);

        _applyYearnExchangeRate(rateAtClaim);

        (,,,,,,,,,, uint256 prin) = pot.getMkt(id);
        (,, uint256 poolShares,,) = pot.getShares(id);
        assertGt(poolShares, 1);

        uint256 shareRequest = 0;
        if (doPartialThenSweep) {
            shareRequest = Math.mulDiv(poolShares, uint256(claimBps), BPS);
            shareRequest = bound(shareRequest, 1, poolShares - 1);
        }

        uint256 sharesToRedeem = shareRequest == 0 ? poolShares : shareRequest;
        uint256 assetsOut = wrapper.previewRedeem(sharesToRedeem);
        uint256 minOut = assetsOut;

        uint256 cp = Math.mulDiv(prin, sharesToRedeem, poolShares);
        uint256 reserveBefore = pot.reserveAssets();
        bool fullClaim = shareRequest == 0 || shareRequest >= poolShares;
        (uint256 payout, uint256 truthFee, uint256 treasuryFee, uint256 reserveAdded, uint256 topup) =
            _expectedClaimSettlement(assetsOut, cp, fullClaim, reserveBefore, true);

        _flushPending(treasury);
        _flushPending(reporter);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 reporterBefore = usdc.balanceOf(reporter);

        vm.prank(alice);
        pot.claim(id, shareRequest, minOut);

        if (treasuryFee > 0) {
            vm.prank(treasury);
            pot.withdrawPending();
        }
        if (truthFee > 0) {
            vm.prank(reporter);
            pot.withdrawPending();
        }

        assertEq(usdc.balanceOf(alice) - aliceBefore, payout);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, treasuryFee);
        assertEq(usdc.balanceOf(reporter) - reporterBefore, truthFee);
        assertEq(pot.reserveAssets() + topup, reserveBefore + reserveAdded);

        (,,, uint256 claimedShares, uint256 remainingShares) = pot.getShares(id);
        assertEq(claimedShares, sharesToRedeem);
        assertEq(remainingShares, poolShares - sharesToRedeem);

        _applyYearnExchangeRate(rateAtSweep);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + SWEEP_DELAY + 1);

        uint256 expectedSweep = remainingShares == 0 ? 0 : wrapper.previewRedeem(remainingShares);
        _flushPending(treasury);
        treasuryBefore = usdc.balanceOf(treasury);
        pot.sweepDust(id, expectedSweep);

        if (expectedSweep > 0) {
            _flushPending(treasury);
        }

        (,,,, status,,) = _mktCore(id);
        assertEq(status, ST_SWEPT);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expectedSweep);

        if (remainingShares > 0) {
            vm.prank(alice);
            vm.expectRevert(yPot.E2.selector);
            pot.claim(id, 0, 0);
        }
    }

    function test_claim_matrix_twoClaims_rateChanges_feeSplit() public {
        uint256[3] memory rateA = [uint256(1e18), uint256(12e17), uint256(8e17)];
        uint256[3] memory rateB = [uint256(1e18), uint256(8e17), uint256(12e17)];
        uint8[2] memory patterns = [uint8(0), uint8(1)]; // 0=oneThirdThenRest, 1=halfThenRest

        for (uint256 i; i < rateA.length; i++) {
            for (uint256 j; j < patterns.length; j++) {
                (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

                _bet(alice, id, 1, 100e6);
                _bet(bob, id, 2, 100e6);

                vm.warp(uint256(dl) + 1);
                pot.close(id);
                vm.warp(uint256(rt));

                vm.prank(reporter);
                pot.report(id, 1);

                uint256 requiredShares;
                (,, requiredShares) = pot.getConfirm(id, alice);
                uint256 confirmAssets = _assetsForAtLeastShares(requiredShares);
                vm.prank(alice);
                pot.confirmReport(id, confirmAssets, 0, block.timestamp + 1);

                vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
                pot.acceptReport(id);

                (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
                assertEq(status, ST_RESOLVED);

                vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
                pot.finalize(id);
                (,,,, status,,) = _mktCore(id);
                assertEq(status, ST_CLAIMABLE);

                (,,,,,,,,,, uint256 prin) = pot.getMkt(id);
                (,, uint256 poolShares,,) = pot.getShares(id);
                assertGt(poolShares, 2);

                uint256 claim1Shares = patterns[j] == 0 ? (poolShares / 3) : (poolShares / 2);
                claim1Shares = bound(claim1Shares, 1, poolShares - 1);
                uint256 claim2Shares = poolShares - claim1Shares;

                _applyYearnExchangeRate(rateA[i]);
                _assertClaimFeeSplitMatchesPreview(id, prin, poolShares, claim1Shares);

                _applyYearnExchangeRate(rateB[i]);
                _assertClaimFeeSplitMatchesPreview(id, prin, poolShares, 0);

                (,,,, uint256 remainingShares) = pot.getShares(id);
                assertEq(remainingShares, 0);
                assertEq(claim2Shares, poolShares - claim1Shares);
            }
        }
    }

    function test_claim_matrix_secondClaim_reverts_E6_when_rateDrops_after_minOut_quoted() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 requiredShares;
        (,, requiredShares) = pot.getConfirm(id, alice);
        uint256 confirmAssets = _assetsForAtLeastShares(requiredShares);
        vm.prank(alice);
        pot.confirmReport(id, confirmAssets, 0, block.timestamp + 1);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,, status,,) = _mktCore(id);
        assertEq(status, ST_CLAIMABLE);

        (,, uint256 poolShares,,) = pot.getShares(id);
        uint256 claim1Shares = poolShares / 2;
        claim1Shares = bound(claim1Shares, 1, poolShares - 1);

        vm.prank(alice);
        pot.claim(id, claim1Shares, 0);

        (,,, uint256 claimedSharesBefore, uint256 remainingSharesBefore) = pot.getShares(id);
        assertEq(claimedSharesBefore, claim1Shares);
        assertEq(remainingSharesBefore, poolShares - claim1Shares);

        uint256 rateHigh = 12e17;
        uint256 rateLow = 8e17;
        _applyYearnExchangeRate(rateHigh);
        uint256 quotedMinOut = wrapper.previewRedeem(remainingSharesBefore);
        assertGt(quotedMinOut, 0);

        _applyYearnExchangeRate(rateLow);
        vm.prank(alice);
        vm.expectRevert(yPot.E6.selector);
        pot.claim(id, 0, quotedMinOut);

        (,,, uint256 claimedSharesAfter, uint256 remainingSharesAfter) = pot.getShares(id);
        assertEq(claimedSharesAfter, claimedSharesBefore);
        assertEq(remainingSharesAfter, remainingSharesBefore);

        uint256 minOutNow = wrapper.previewRedeem(remainingSharesAfter);
        vm.prank(alice);
        pot.claim(id, 0, minOutNow);

        (,,,, uint256 remainingFinal) = pot.getShares(id);
        assertEq(remainingFinal, 0);
    }

    function test_claim_matrix_feeSplit_rounding_totalFeeOne_goes_to_treasury() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 1e6);
        _bet(bob, id, 2, 1e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 requiredShares;
        (,, requiredShares) = pot.getConfirm(id, alice);
        uint256 confirmAssets = _assetsForAtLeastShares(requiredShares);
        vm.prank(alice);
        pot.confirmReport(id, confirmAssets, 0, block.timestamp + 1);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,, status,,) = _mktCore(id);
        assertEq(status, ST_CLAIMABLE);

        (,,,,,,,,,, uint256 prin) = pot.getMkt(id);
        (,, uint256 poolShares,,) = pot.getShares(id);

        uint256 baseRate = 1e18;
        uint256[6] memory incs = [uint256(1e13), uint256(2e13), uint256(3e13), uint256(4e13), uint256(5e13), uint256(6e13)];

        uint256 assetsOut;
        uint256 tf;
        bool found;
        for (uint256 i; i < incs.length; i++) {
            _applyYearnExchangeRate(baseRate + incs[i]);
            assetsOut = wrapper.previewRedeem(poolShares);
            if (assetsOut <= prin) continue;
            tf = Math.mulDiv(assetsOut - prin, YIELD_FEE_BPS, BPS);
            if (tf == 1) {
                found = true;
                break;
            }
        }
        assertTrue(found);
        assertEq(tf, 1);

        _flushPending(treasury);
        _flushPending(reporter);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 creatorBefore = usdc.balanceOf(creator);
        uint256 reporterBefore = usdc.balanceOf(reporter);

        vm.prank(alice);
        pot.claim(id, 0, assetsOut);

        vm.prank(treasury);
        pot.withdrawPending();

        assertEq(usdc.balanceOf(alice) - aliceBefore, assetsOut - 1);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 1);
        assertEq(usdc.balanceOf(creator), creatorBefore);
        assertEq(usdc.balanceOf(reporter), reporterBefore);
    }

    function testFuzz_claim_twice_feeSplit_respectsPreviewRedeem_overRates(uint256 rate1, uint256 rate2, uint16 bps1)
        public
    {
        rate1 = bound(rate1, 5e17, 2e18);
        rate2 = bound(rate2, 5e17, 2e18);
        bps1 = uint16(bound(uint256(bps1), 1, 9999));

        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 requiredShares;
        (,, requiredShares) = pot.getConfirm(id, alice);
        uint256 confirmAssets = _assetsForAtLeastShares(requiredShares);
        vm.prank(alice);
        pot.confirmReport(id, confirmAssets, 0, block.timestamp + 1);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,, status,,) = _mktCore(id);
        assertEq(status, ST_CLAIMABLE);

        (,,,,,,,,,, uint256 prin) = pot.getMkt(id);
        (,, uint256 poolShares,,) = pot.getShares(id);
        assertGt(poolShares, 1);

        uint256 claim1Shares = Math.mulDiv(poolShares, uint256(bps1), BPS);
        claim1Shares = bound(claim1Shares, 1, poolShares - 1);

        _applyYearnExchangeRate(rate1);
        _assertClaimFeeSplitMatchesPreview(id, prin, poolShares, claim1Shares);

        _applyYearnExchangeRate(rate2);
        _assertClaimFeeSplitMatchesPreview(id, prin, poolShares, 0);

        (,,,, uint256 remainingShares) = pot.getShares(id);
        assertEq(remainingShares, 0);
    }

    function testFuzz_claim_secondClaim_reverts_E6_when_rateDrops_after_quote(uint256 rateHigh, uint256 rateLow, uint16 bps1)
        public
    {
        rateHigh = bound(rateHigh, 11e17, 2e18);
        rateLow = bound(rateLow, 5e17, 10e17);
        vm.assume(rateLow < rateHigh);
        bps1 = uint16(bound(uint256(bps1), 1, 9999));

        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 requiredShares;
        (,, requiredShares) = pot.getConfirm(id, alice);
        uint256 confirmAssets = _assetsForAtLeastShares(requiredShares);
        vm.prank(alice);
        pot.confirmReport(id, confirmAssets, 0, block.timestamp + 1);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,, status,,) = _mktCore(id);
        assertEq(status, ST_CLAIMABLE);

        (,, uint256 poolShares,,) = pot.getShares(id);
        assertGt(poolShares, 1);

        uint256 claim1Shares = Math.mulDiv(poolShares, uint256(bps1), BPS);
        claim1Shares = bound(claim1Shares, 1, poolShares - 1);

        vm.prank(alice);
        pot.claim(id, claim1Shares, 0);

        (,,, uint256 claimedSharesBefore, uint256 remainingSharesBefore) = pot.getShares(id);
        assertEq(claimedSharesBefore, claim1Shares);
        assertEq(remainingSharesBefore, poolShares - claim1Shares);

        _applyYearnExchangeRate(rateHigh);
        uint256 quotedMinOut = wrapper.previewRedeem(remainingSharesBefore);
        assertGt(quotedMinOut, 0);

        _applyYearnExchangeRate(rateLow);
        vm.prank(alice);
        vm.expectRevert(yPot.E6.selector);
        pot.claim(id, 0, quotedMinOut);

        (,,, uint256 claimedSharesAfter, uint256 remainingSharesAfter) = pot.getShares(id);
        assertEq(claimedSharesAfter, claimedSharesBefore);
        assertEq(remainingSharesAfter, remainingSharesBefore);

        uint256 minOutNow = wrapper.previewRedeem(remainingSharesAfter);
        vm.prank(alice);
        pot.claim(id, 0, minOutNow);

        (,,,, uint256 remainingFinal) = pot.getShares(id);
        assertEq(remainingFinal, 0);
    }

    function testFuzz_claim_reverts_E6_when_rateDrops_after_minOut_quoted(uint256 rateHigh, uint256 rateLow) public {
        rateHigh = bound(rateHigh, 11e17, 2e18);
        rateLow = bound(rateLow, 5e17, 10e17);
        vm.assume(rateLow < rateHigh);

        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 requiredShares;
        (,, requiredShares) = pot.getConfirm(id, alice);
        uint256 confirmAssets = _assetsForAtLeastShares(requiredShares);
        vm.prank(alice);
        pot.confirmReport(id, confirmAssets, 0, block.timestamp + 1);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,, status,,) = _mktCore(id);
        assertEq(status, ST_CLAIMABLE);

        _applyYearnExchangeRate(rateHigh);

        (,, uint256 poolShares,,) = pot.getShares(id);
        assertGt(poolShares, 0);

        uint256 outHigh = wrapper.previewRedeem(poolShares);

        _applyYearnExchangeRate(rateLow);
        uint256 outLow = wrapper.previewRedeem(poolShares);
        vm.assume(outLow < outHigh);

        vm.prank(alice);
        vm.expectRevert(yPot.E6.selector);
        pot.claim(id, 0, outHigh);
    }

    function test_confirmReport_enforces_confirm_cap_and_reverts_when_exceeded() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        (uint256[] memory s,,,) = pot.getUsr(id, alice);
        uint256 posShares = s[1];
        assertGt(posShares, 0);

        uint256 maxConfirmShares = (posShares * pot.CONFIRM_MAX_MULTIPLIER_BPS()) / BPS;

        uint256 assetsTooMuch = wrapper.previewMint(maxConfirmShares + 1) + 1;
        vm.prank(alice);
        vm.expectRevert(yPot.E1.selector);
        pot.confirmReport(id, assetsTooMuch, 0, block.timestamp + 1);

        uint256 assetsForMax = _assetsForExactShares(maxConfirmShares);
        vm.prank(alice);
        pot.confirmReport(id, assetsForMax, 0, block.timestamp + 1);

        vm.prank(alice);
        vm.expectRevert(yPot.E2.selector);
        pot.confirmReport(id, 1e6, 0, block.timestamp + 1);
    }

    function test_expireUnconfirmedReport_reverts_when_confirmed_enough_even_after_timeout() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        pot.setConfirmBps(5000);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        (,, uint256 requiredShares) = pot.getConfirm(id, alice);
        uint256 assetsForRequired = _assetsForExactShares(requiredShares);
        vm.prank(alice);
        pot.confirmReport(id, assetsForRequired, 0, block.timestamp + 1);

        uint256 reportedAt;
        (,,, reportedAt,,,,) = pot.getReport(id);

        vm.warp(reportedAt + CHALLENGE_WINDOW + CONFIRM_TIMEOUT + 1);
        vm.expectRevert(yPot.E2.selector);
        pot.expireUnconfirmedReport(id);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        (,,,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);
    }

    function test_confirmReport_reverts_E6_when_minShares_not_met() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 assetsIn = 50e6;
        uint256 expShares = wrapper.previewDeposit(assetsIn);

        vm.prank(alice);
        vm.expectRevert(yPot.E6.selector);
        pot.confirmReport(id, assetsIn, expShares + 1, block.timestamp + 1);
    }

    function test_sweepDust_reverts_until_delay_then_sweeps_to_treasury() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 requiredShares;
        (,, requiredShares) = pot.getConfirm(id, alice);
        uint256 assetsIn = wrapper.previewMint(requiredShares) + 1;
        vm.prank(alice);
        pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);

        uint256 acceptTs = uint256(rt) + CHALLENGE_WINDOW + 1;
        vm.warp(acceptTs);
        pot.acceptReport(id);

        (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,, uint8 status2,,) = _mktCore(id);
        assertEq(status2, ST_CLAIMABLE);

        (,, uint256 totalShares,,) = pot.getShares(id);
        uint256 halfShares = totalShares / 2;
        vm.prank(alice);
        pot.claim(id, halfShares, 0);

        (,,, uint256 claimedShares, uint256 remainingShares) = pot.getShares(id);
        assertEq(remainingShares, totalShares - claimedShares);
        assertGt(remainingShares, 0);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + SWEEP_DELAY - 1);
        vm.expectRevert(yPot.E2.selector);
        pot.sweepDust(id, 0);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + SWEEP_DELAY + 1);

        _flushPending(treasury);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 expected = wrapper.previewRedeem(remainingShares);
        pot.sweepDust(id, 0);

        _flushPending(treasury);

        (,,,, uint8 status3,,) = _mktCore(id);
        assertEq(status3, ST_SWEPT);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expected);
    }

    function test_sweepDust_reverts_when_called_twice() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 requiredShares;
        (,, requiredShares) = pot.getConfirm(id, alice);
        uint256 assetsIn = wrapper.previewMint(requiredShares) + 1;
        vm.prank(alice);
        pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,, uint8 status2,,) = _mktCore(id);
        assertEq(status2, ST_CLAIMABLE);

        vm.prank(alice);
        pot.claim(id, 1, 0);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + SWEEP_DELAY + 1);
        pot.sweepDust(id, 0);

        vm.expectRevert(yPot.E2.selector);
        pot.sweepDust(id, 0);
    }

    function test_sweepDust_handles_zero_remainingShares_noop_and_sets_swept() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 requiredShares;
        (,, requiredShares) = pot.getConfirm(id, alice);
        uint256 assetsIn = wrapper.previewMint(requiredShares) + 1;
        vm.prank(alice);
        pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,, uint8 status2,,) = _mktCore(id);
        assertEq(status2, ST_CLAIMABLE);

        vm.prank(alice);
        pot.claim(id, 0, 0);
        (,,,, uint256 remainingShares) = pot.getShares(id);
        assertEq(remainingShares, 0);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + SWEEP_DELAY + 1);
        _flushPending(treasury);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        pot.sweepDust(id, 1);

        (,,,, uint8 status3,,) = _mktCore(id);
        assertEq(status3, ST_SWEPT);
        assertEq(usdc.balanceOf(treasury), treasuryBefore);
    }

    function test_sweepDust_enforces_minOut_slippage_check() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100e6);
        _bet(bob, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        uint256 requiredShares;
        (,, requiredShares) = pot.getConfirm(id, alice);
        uint256 assetsIn = wrapper.previewMint(requiredShares) + 1;
        vm.prank(alice);
        pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);

        uint256 acceptTs = uint256(rt) + CHALLENGE_WINDOW + 1;
        vm.warp(acceptTs);
        pot.acceptReport(id);

        (,, uint64 resolved,, uint8 status,,) = _mktCore(id);
        assertEq(status, ST_RESOLVED);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,, uint8 status2,,) = _mktCore(id);
        assertEq(status2, ST_CLAIMABLE);

        (,, uint256 totalShares,,) = pot.getShares(id);
        uint256 halfShares = totalShares / 2;
        vm.prank(alice);
        pot.claim(id, halfShares, 0);

        (,,, uint256 claimedShares, uint256 remainingShares) = pot.getShares(id);
        assertEq(remainingShares, totalShares - claimedShares);
        assertGt(remainingShares, 0);

        _assertSweepDustMinOut(id, resolved, remainingShares);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _assertClaimFeeSplitMatchesPreview(uint256 id, uint256 prin, uint256 poolShares, uint256 shareRequest)
        internal
    {
        uint256 availableShares = _remainingShares(id);
        uint256 sharesToRedeem = shareRequest == 0 ? availableShares : shareRequest;
        assertGt(sharesToRedeem, 0);

        uint256 assetsOut = wrapper.previewRedeem(sharesToRedeem);

        uint256 cp = Math.mulDiv(prin, sharesToRedeem, poolShares);
        uint256 reserveBefore = pot.reserveAssets();
        bool fullClaim = shareRequest == 0 || shareRequest >= availableShares;
        (uint256 payout, uint256 truthFee, uint256 treasuryFee, uint256 reserveAdded, uint256 topup) =
            _expectedClaimSettlement(assetsOut, cp, fullClaim, reserveBefore, true);

        _flushPending(treasury);
        _flushPending(reporter);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 reporterBefore = usdc.balanceOf(reporter);

        vm.prank(alice);
        pot.claim(id, shareRequest, assetsOut);

        _flushPending(treasury);
        _flushPending(reporter);

        assertEq(usdc.balanceOf(alice) - aliceBefore, payout);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, treasuryFee);
        assertEq(usdc.balanceOf(reporter) - reporterBefore, truthFee);
        assertEq(pot.reserveAssets() + topup, reserveBefore + reserveAdded);
    }

    function _remainingShares(uint256 id) internal view returns (uint256 remainingShares) {
        (,,,, remainingShares) = pot.getShares(id);
    }

    function _assertSweepDustMinOut(uint256 id, uint64 resolved, uint256 remainingShares) internal {
        vm.warp(uint256(resolved) + DISPUTE_PERIOD + SWEEP_DELAY + 1);

        uint256 expected = wrapper.previewRedeem(remainingShares);
        vm.expectRevert(yPot.E6.selector);
        pot.sweepDust(id, expected + 1e6);

        _flushPending(treasury);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        pot.sweepDust(id, expected);

        _flushPending(treasury);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expected);
    }

    function _expectedFeeSplit(uint256 tf, uint256 reserveBefore, bool hasTruthTeller)
        internal
        view
        returns (uint256 truthFee, uint256 treasuryFee, uint256 reserveAdded)
    {
        truthFee = hasTruthTeller ? Math.mulDiv(tf, YIELD_REPORTER_REWARD_BPS, BPS) : 0;
        uint256 reserveFee = Math.mulDiv(tf, YIELD_RESERVE_BPS, BPS);

        uint256 target = pot.RESERVE_TARGET_ASSETS();
        uint256 capacity = reserveBefore < target ? target - reserveBefore : 0;
        reserveAdded = reserveFee <= capacity ? reserveFee : capacity;

        treasuryFee = tf - truthFee - reserveAdded;
    }

    function _expectedClaimSettlement(uint256 assetsOutPreview, uint256 cp, bool fullClaim, uint256 reserveBefore, bool hasTruthTeller)
        internal
        view
        returns (
            uint256 payout,
            uint256 truthFee,
            uint256 treasuryFee,
            uint256 reserveAdded,
            uint256 topup
        )
    {
        uint256 assetsOut = assetsOutPreview;
        if (fullClaim && assetsOut < cp) {
            uint256 shortfall = cp - assetsOut;
            if (shortfall <= pot.MAX_ROUNDING_TOPUP_ASSETS() && reserveBefore >= shortfall) {
                topup = shortfall;
                assetsOut += shortfall;
            }
        }

        uint256 reserveAfterTopup = reserveBefore - topup;
        uint256 tf = assetsOut > cp ? Math.mulDiv(assetsOut - cp, YIELD_FEE_BPS, BPS) : 0;
        (truthFee, treasuryFee, reserveAdded) = _expectedFeeSplit(tf, reserveAfterTopup, hasTruthTeller);
        payout = assetsOut - tf;
    }

    function _mintApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }

    function _create2OutcomeMarket() internal returns (uint256 id, uint64 dl, uint64 rt) {
        dl = uint64(block.timestamp + 14 days + 1);
        rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        id = pot.create("tier1 confirm market", "bafyTier1Confirm", dl, rt, 2, "", address(0));

        (,,, uint64 deadline, uint64 resTime,, uint8 outcomes,, uint8 status, address mCreator,) = pot.getMkt(id);
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

    function _assetsForAtMostShares(uint256 sharesTarget) internal view returns (uint256 assets) {
        assets = wrapper.previewMint(sharesTarget);
        uint256 shares = wrapper.previewDeposit(assets);
        for (uint256 i; shares > sharesTarget && i < 64;) {
            assets -= 1;
            shares = wrapper.previewDeposit(assets);
            unchecked {
                ++i;
            }
        }
        assertLe(wrapper.previewDeposit(assets), sharesTarget);
    }

    function _assetsForAtLeastShares(uint256 sharesTarget) internal view returns (uint256 assets) {
        assets = wrapper.previewMint(sharesTarget);
        uint256 shares = wrapper.previewDeposit(assets);
        for (uint256 i; shares < sharesTarget && i < 64;) {
            assets += 1;
            shares = wrapper.previewDeposit(assets);
            unchecked {
                ++i;
            }
        }
        assertGe(wrapper.previewDeposit(assets), sharesTarget);
    }

    function _assetsForExactShares(uint256 sharesTarget) internal view returns (uint256 assets) {
        assets = wrapper.previewMint(sharesTarget);
        uint256 shares = wrapper.previewDeposit(assets);

        for (uint256 i; shares > sharesTarget && i < 128;) {
            assets -= 1;
            shares = wrapper.previewDeposit(assets);
            unchecked {
                ++i;
            }
        }

        for (uint256 i; shares < sharesTarget && i < 128;) {
            assets += 1;
            shares = wrapper.previewDeposit(assets);
            unchecked {
                ++i;
            }
        }

        assertEq(wrapper.previewDeposit(assets), sharesTarget);
    }

    function _applyYearnExchangeRate(uint256 newRate) internal {
        if (newRate == yearn.exchangeRate()) return;
        yearn.setExchangeRate(newRate);

        uint256 requiredAssets = yearn.convertToAssets(yearn.totalSupply());
        uint256 bal = usdc.balanceOf(address(yearn));
        if (bal < requiredAssets) {
            usdc.mint(address(yearn), requiredAssets - bal);
        }
    }

    function _mktCore(uint256 id)
        internal
        view
        returns (
            uint8 winner,
            uint64 created,
            uint64 resolved,
            uint8 outcomes,
            uint8 status,
            uint64 deadline,
            uint64 resTime
        )
    {
        (,, created, deadline, resTime, resolved, outcomes, winner, status,,) = pot.getMkt(id);
    }

    function _flushPending(address who) internal {
        if (pot.pendingWithdrawals(who) > 0) {
            vm.prank(who);
            pot.withdrawPending();
        }
    }
}
