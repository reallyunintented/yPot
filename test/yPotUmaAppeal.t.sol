// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";
import {yPotUma} from "src/yPotUma.sol";
import {UmaOptimisticOracleAdapter} from "src/UmaOptimisticOracleAdapter.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";
import {MockUmaOptimisticOracle} from "test/mocks/MockUmaOptimisticOracle.sol";

contract yPotUmaAppealTest is Test {
    uint8 private constant ST_APPEALABLE = 7;
    uint8 private constant ST_UMA_PENDING = 8;
    uint8 private constant ST_RESOLVED = 2;
    uint8 private constant ST_CLAIMABLE = 3;
    uint8 private constant ST_CANCELLED = 4;

    uint256 private constant BPS = 10_000;
    bytes32 private constant IDENTIFIER = keccak256("YPOT_LOCAL");
    uint256 private constant DISPUTE_PERIOD = 24 hours;
    uint256 private constant UMA_STALE_TIMEOUT = 30 days;

    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    MockUmaOptimisticOracle internal mockUma;
    UmaOptimisticOracleAdapter internal adapter;
    yPotUma internal module;

    address internal treasury = address(0xBEEF);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);

    address internal creator = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal reporter = address(0x3333);
    address internal challenger = address(0x4444);
    address internal appellant = address(0x5555);

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

        mockUma = new MockUmaOptimisticOracle();
        address[] memory requesters = new address[](1);
        requesters[0] = address(this);
        adapter = new UmaOptimisticOracleAdapter(address(mockUma), usdc, IDENTIFIER, 0, 0, 0, requesters);

        module = new yPotUma(address(pot), address(adapter));
        pot.setUmaModule(address(module));
        adapter.setRequester(address(module), true);

        _mintApprovePot(creator, 1_000_000e6);
        _mintApprovePot(alice, 1_000_000e6);
        _mintApprovePot(bob, 1_000_000e6);
        _mintApprovePot(reporter, 1_000_000e6);
        _mintApprovePot(challenger, 1_000_000e6);
        _mintApproveModule(appellant, 1_000_000e6);
    }

    function test_umaAppeal_overturns_committee_and_refunds_appellant() public {
        (uint256 id, string memory desc, uint64 resTime, uint64 appealDeadline, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);
        assertEq(usdc.balanceOf(appellant), appellantBefore - appealBond);

        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_UMA_PENDING);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);

        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(1));

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        vm.prank(address(this));
        module.settleUmaAppeal(id);

        uint8 winnerAfter;
        uint8 statusAfter;
        (,,,,,,, winnerAfter, statusAfter,,) = pot.getMkt(id);
        assertEq(winnerAfter, 1);
        assertEq(statusAfter, ST_RESOLVED);

        assertEq(_receivable(appellant), appellantBefore);
        uint256 recovered = rb * 2;
        uint256 rake = _disputeRake(rb, recovered);
        assertEq(_receivable(treasury) - treasuryBefore, rake);
        assertEq(_receivable(reporter) - reporterBefore, recovered - rake);

        vm.warp(uint256(appealDeadline) + 24 hours + 1);
        pot.finalize(id);
        (,,,,,,,, statusAfter,,) = pot.getMkt(id);
        assertEq(statusAfter, ST_CLAIMABLE);
    }

    function test_umaAppeal_affirms_committee_and_sends_appealBond_to_treasury() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 treasuryBefore = _receivable(treasury);
        uint256 challengerBefore = _receivable(challenger);

        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, rb * 2);

        vm.prank(address(this));
        module.settleUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, 2);
        assertEq(status, ST_RESOLVED);

        uint256 recovered = rb * 2;
        uint256 rake = _disputeRake(rb, recovered);
        assertEq(_receivable(treasury) - treasuryBefore, appealBond + rake);
        assertEq(_receivable(challenger) - challengerBefore, recovered - rake);
    }

    function test_umaAppeal_rake_usesEscrowSnapshot_afterCoreBondsZeroed() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        vm.prank(appellant);
        module.startUmaAppeal(id);

        (,, uint256 reportBondAfter,,,,, uint256 challengeBondAfter) = pot.getReport(id);
        assertEq(reportBondAfter, 0);
        assertEq(challengeBondAfter, 0);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        uint256 recovered = rb * 2;
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, recovered);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(1));

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);

        module.settleUmaAppeal(id);

        uint256 rake = _disputeRake(rb, recovered);
        assertGt(rake, 0);
        assertEq(_receivable(treasury) - treasuryBefore, rake);
        assertEq(_receivable(reporter) - reporterBefore, recovered - rake);
    }

    function test_settleUmaAppeal_invalidPrice_cancels_and_refunds_appellant_and_bondsHalfHalf() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);
        assertEq(usdc.balanceOf(appellant), appellantBefore - appealBond);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(0));

        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);

        module.settleUmaAppeal(id);

        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_CANCELLED);

        assertEq(_receivable(appellant), appellantBefore);
        assertEq(_receivable(reporter) - reporterBefore, rb);
        assertEq(_receivable(challenger) - challengerBefore, rb);
    }

    function test_expireUmaAppeal_after_stale_resolves_committee_when_oracle_unreachable() public {
        (uint256 id, string memory desc, uint64 resTime,,) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);
        assertEq(usdc.balanceOf(appellant), appellantBefore - appealBond);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        adapter.settle(uint256(resTime), ancillary);

        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        assertEq(pot.getDisputeMode(id), 1);

        vm.expectRevert(yPotUma.E2.selector);
        module.expireUmaAppeal(id);

        vm.warp(uint256(umaStartedAt) + 30 days + 1);
        module.expireUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, 2);
        assertEq(status, ST_RESOLVED);
        assertEq(_receivable(appellant), appellantBefore);
    }

    function test_withdrawConfirmBond_succeeds_during_umaPending() public {
        (uint256 id,,,,) = _setupAppealableMarketWithConfirm(50e6);

        (uint256 userConfirmShares,,) = pot.getConfirm(id, alice);
        assertGt(userConfirmShares, 0);
        uint256 expectedOut = wrapper.previewRedeem(userConfirmShares);

        vm.prank(appellant);
        module.startUmaAppeal(id);

        (,,,,,,,, uint8 statusAfter,,) = pot.getMkt(id);
        assertEq(statusAfter, ST_UMA_PENDING);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.withdrawConfirmBond(id, 0, 0);
        uint256 aliceAfter = usdc.balanceOf(alice);

        (uint256 remainingConfirmShares,,) = pot.getConfirm(id, alice);
        assertEq(aliceAfter - aliceBefore, expectedOut);
        assertEq(remainingConfirmShares, 0);
    }

    function test_umaAppeal_finalize_sequence_settle() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        vm.prank(appellant);
        module.startUmaAppeal(id);

        (,,,,,,,, uint8 statusAfter,,) = pot.getMkt(id);
        assertEq(statusAfter, ST_UMA_PENDING);

        vm.expectRevert(yPot.E2.selector);
        pot.finalize(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, rb);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(1));

        module.settleUmaAppeal(id);

        (,,,,, uint64 resolved,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_RESOLVED);

        vm.expectRevert(yPot.E2.selector);
        pot.finalize(id);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,,,,,, status,,) = pot.getMkt(id);
        assertEq(status, ST_CLAIMABLE);
    }

    function test_umaAppeal_finalize_sequence_expire() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        vm.prank(appellant);
        module.startUmaAppeal(id);

        (,,,,,,,, uint8 statusAfter,,) = pot.getMkt(id);
        assertEq(statusAfter, ST_UMA_PENDING);

        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        vm.warp(uint256(umaStartedAt) + UMA_STALE_TIMEOUT + 1);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, rb);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(1));

        module.expireUmaAppeal(id);

        (,,,,, uint64 resolved,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_RESOLVED);

        vm.expectRevert(yPot.E2.selector);
        pot.finalize(id);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,,,,,, status,,) = pot.getMkt(id);
        assertEq(status, ST_CLAIMABLE);
    }

    function test_umaAppeal_invalidPrice_cancel_allows_emergencyWithdraw_bettors() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, rb);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(0));

        module.settleUmaAppeal(id);

        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_CANCELLED);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.emergencyWithdraw(id, 0);
        assertGt(usdc.balanceOf(alice) - aliceBefore, 0);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pot.emergencyWithdraw(id, 0);
        assertGt(usdc.balanceOf(bob) - bobBefore, 0);
    }

    function testFuzz_umaAppeal_finalize_gates_on_disputePeriod(bool viaExpire, uint256 dt) public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, rb);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(1));

        if (viaExpire) {
            (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
            vm.warp(uint256(umaStartedAt) + UMA_STALE_TIMEOUT + 1);
            module.expireUmaAppeal(id);
        } else {
            module.settleUmaAppeal(id);
        }

        (,,,,, uint64 resolved,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_RESOLVED);

        uint256 early = bound(dt, 0, DISPUTE_PERIOD - 1);
        vm.warp(uint256(resolved) + early);
        vm.expectRevert(yPot.E2.selector);
        pot.finalize(id);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,,,,,, status,,) = pot.getMkt(id);
        assertEq(status, ST_CLAIMABLE);
    }

    function testFuzz_finalize_reverts_while_umaPending(uint256 dtRaw) public {
        (uint256 id,,,,) = _setupAppealableMarket();

        vm.prank(appellant);
        module.startUmaAppeal(id);

        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        uint256 dt = bound(dtRaw, 0, UMA_STALE_TIMEOUT * 2);
        vm.warp(uint256(umaStartedAt) + dt);

        vm.expectRevert(yPot.E2.selector);
        pot.finalize(id);
    }

    function testFuzz_expireUmaAppeal_payoutTooHigh_fallsBack_and_finalize_gates(uint256 dtRaw) public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, rb * 2 + 1);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(1));

        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        uint256 dt = bound(dtRaw, 0, UMA_STALE_TIMEOUT * 2);
        vm.warp(uint256(umaStartedAt) + dt);

        if (dt <= UMA_STALE_TIMEOUT) {
            vm.expectRevert(yPotUma.E2.selector);
            module.expireUmaAppeal(id);
            return;
        }

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);

        module.expireUmaAppeal(id);

        (,,,,, uint64 resolved,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, 2);
        assertEq(status, ST_RESOLVED);

        assertEq(_receivable(appellant), appellantBefore);
        assertEq(_receivable(treasury), treasuryBefore);
        assertEq(_receivable(reporter), reporterBefore);
        assertEq(_receivable(challenger), challengerBefore);
        assertEq(appealBond, module.calcUmaAppealBond(prin));

        (uint256[] memory sBob, uint256[] memory wBob,,) = pot.getUsr(id, bob);
        assertGt(sBob[2], 0);
        assertGt(wBob[2], 0);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD - 1);
        vm.expectRevert(yPot.E2.selector);
        pot.finalize(id);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
        pot.finalize(id);
        (,,,,,,,, status,,) = pot.getMkt(id);
        assertEq(status, ST_CLAIMABLE);
    }

    function test_expireUmaAppeal_after_stale_settle_succeeds_and_applies_uma_result() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);
        assertEq(usdc.balanceOf(appellant), appellantBefore - appealBond);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        uint256 payout = rb;
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payout);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(1));

        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        vm.warp(uint256(umaStartedAt) + 30 days + 1);

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);
        module.expireUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, 1);
        assertEq(status, ST_RESOLVED);

        assertEq(_receivable(appellant), appellantBefore);
        uint256 rake = _disputeRake(rb, payout);
        assertEq(_receivable(reporter) - reporterBefore, payout - rake);
        assertEq(_receivable(treasury) - treasuryBefore, rake);
        assertEq(_receivable(challenger), challengerBefore);
    }

    function test_expireUmaAppeal_after_stale_settle_invalid_price_falls_back_to_committee_and_refunds_halfHalf()
        public
    {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);
        assertEq(usdc.balanceOf(appellant), appellantBefore - appealBond);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        uint256 payout = rb * 2 - 1;
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payout);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(0));

        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        vm.warp(uint256(umaStartedAt) + 30 days + 1);

        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);
        module.expireUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, 2);
        assertEq(status, ST_RESOLVED);

        assertEq(_receivable(appellant), appellantBefore);

        uint256 half = payout >> 1;
        assertEq(_receivable(reporter) - reporterBefore, half);
        assertEq(_receivable(challenger) - challengerBefore, payout - half);
    }

    function test_umaAppeal_affirms_with_partial_payout_distributes_only_recovered_to_challenger() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);

        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        uint256 payout = rb;
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payout);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(2));

        module.settleUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, 2);
        assertEq(status, ST_RESOLVED);

        uint256 rake = _disputeRake(rb, payout);
        assertEq(_receivable(treasury) - treasuryBefore, appealBond + rake);
        assertEq(_receivable(challenger) - challengerBefore, payout - rake);
        assertEq(_receivable(reporter), reporterBefore);
    }

    function test_umaAppeal_overturns_with_winner_not_reported_or_challenged_sends_recovered_to_treasury() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket3Outcome();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);
        uint256 appellantBefore = _receivable(appellant);

        vm.prank(appellant);
        module.startUmaAppeal(id);
        assertEq(_receivable(appellant), appellantBefore - appealBond);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 3);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(3));

        module.settleUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, 3);
        assertEq(status, ST_RESOLVED);

        assertEq(_receivable(appellant), appellantBefore);
        assertEq(_receivable(treasury) - treasuryBefore, rb * 2);
        assertEq(_receivable(reporter), reporterBefore);
        assertEq(_receivable(challenger), challengerBefore);
    }

    function test_finalize_after_umaResolution_does_not_wait_for_appealDeadline() public {
        (uint256 id, string memory desc, uint64 resTime, uint64 appealDeadline,) = _setupAppealableMarket();

        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(1));

        module.settleUmaAppeal(id);

        (,,,,, uint64 resolved,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_RESOLVED);
        assertLt(uint256(resolved) + 24 hours + 1, uint256(appealDeadline));

        vm.warp(uint256(resolved) + 24 hours - 1);
        vm.expectRevert(yPot.E2.selector);
        pot.finalize(id);

        vm.warp(uint256(resolved) + 24 hours + 1);
        pot.finalize(id);
        (,,,,,,,, status,,) = pot.getMkt(id);
        assertEq(status, ST_CLAIMABLE);
    }

    function testFuzz_umaAppeal_recoveredRouting_respectsWinner_and_payout(
        uint8 umaWinnerRaw,
        uint256 payoutRaw,
        bool viaExpire
    ) public {
        uint8 umaWinner = uint8(bound(uint256(umaWinnerRaw), 1, 3));

        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket3Outcome();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 3);

        uint256 maxPayout = rb * 2;
        uint256 payout = bound(payoutRaw, 0, maxPayout);
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payout);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(uint256(umaWinner)));

        uint256 recovered = payout == 0 ? maxPayout : payout;
        uint256 mockBal = usdc.balanceOf(address(mockUma));
        if (mockBal < recovered) {
            usdc.mint(address(mockUma), recovered - mockBal);
        }

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);

        if (viaExpire) {
            (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
            vm.warp(uint256(umaStartedAt) + 30 days + 1);
            module.expireUmaAppeal(id);
        } else {
            module.settleUmaAppeal(id);
        }

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, umaWinner);
        assertEq(status, ST_RESOLVED);

        if (umaWinner == 2) {
            assertEq(_receivable(appellant), appellantBefore - appealBond);
        } else {
            assertEq(_receivable(appellant), appellantBefore);
        }

        uint256 expectedTreasury = umaWinner == 2 ? appealBond : 0;
        if (umaWinner == 1 || umaWinner == 2) {
            expectedTreasury += _disputeRake(rb, recovered);
        }
        expectedTreasury += umaWinner == 3 ? recovered : 0;
        assertEq(_receivable(treasury) - treasuryBefore, expectedTreasury);

        uint256 expectedReporter = umaWinner == 1 ? recovered - _disputeRake(rb, recovered) : 0;
        assertEq(_receivable(reporter) - reporterBefore, expectedReporter);

        uint256 expectedChallenger = umaWinner == 2 ? recovered - _disputeRake(rb, recovered) : 0;
        assertEq(_receivable(challenger) - challengerBefore, expectedChallenger);
    }

    function testFuzz_umaAppeal_invalidPrice_refundsHalfHalf_and_statusDependsOnPath(
        uint256 payoutRaw,
        bool viaExpire,
        bool invalidZeroPrice
    ) public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);

        uint256 maxPayout = rb * 2;
        uint256 payout = bound(payoutRaw, 0, maxPayout);
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payout);

        int256 invalidPrice = invalidZeroPrice ? int256(0) : int256(3);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, invalidPrice);

        uint256 recovered = payout == 0 ? maxPayout : payout;
        uint256 mockBal = usdc.balanceOf(address(mockUma));
        if (mockBal < recovered) {
            usdc.mint(address(mockUma), recovered - mockBal);
        }

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);

        if (viaExpire) {
            (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
            vm.warp(uint256(umaStartedAt) + 30 days + 1);
            module.expireUmaAppeal(id);
        } else {
            module.settleUmaAppeal(id);
        }

        if (viaExpire) {
            (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
            assertEq(winner, 2);
            assertEq(status, ST_RESOLVED);
        } else {
            (,,,,,,,, uint8 status,,) = pot.getMkt(id);
            assertEq(status, ST_CANCELLED);
        }

        assertEq(_receivable(appellant), appellantBefore);
        assertEq(appealBond, module.calcUmaAppealBond(prin));

        uint256 half = recovered >> 1;
        assertEq(_receivable(reporter) - reporterBefore, half);
        assertEq(_receivable(challenger) - challengerBefore, recovered - half);
        // On settle path (cancel), reporter bounty escrow goes to treasury via _creditPending
        uint256 expectedBountyToTreasury = viaExpire ? 0 : (pot.fee() * 2000) / 10_000;
        assertEq(_receivable(treasury) - treasuryBefore, expectedBountyToTreasury);
    }

    function testFuzz_umaAppeal_invalidPriceVariants_refundsHalfHalf_and_statusDependsOnPath(
        uint256 payoutRaw,
        bool viaExpire,
        uint8 invalidKindRaw
    ) public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);

        uint256 maxPayout = rb * 2;
        uint256 payout = bound(payoutRaw, 0, maxPayout);
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payout);

        uint8 kind = uint8(bound(uint256(invalidKindRaw), 0, 2));
        int256 invalidPrice = kind == 0 ? int256(0) : (kind == 1 ? int256(-1) : int256(3));
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, invalidPrice);

        uint256 recovered = payout == 0 ? maxPayout : payout;
        uint256 mockBal = usdc.balanceOf(address(mockUma));
        if (mockBal < recovered) {
            usdc.mint(address(mockUma), recovered - mockBal);
        }

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);

        if (viaExpire) {
            (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
            vm.warp(uint256(umaStartedAt) + 30 days + 1);
            module.expireUmaAppeal(id);
        } else {
            module.settleUmaAppeal(id);
        }

        if (viaExpire) {
            (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
            assertEq(winner, 2);
            assertEq(status, ST_RESOLVED);
        } else {
            (,,,,,,,, uint8 status,,) = pot.getMkt(id);
            assertEq(status, ST_CANCELLED);
        }

        assertEq(_receivable(appellant), appellantBefore);
        assertEq(appealBond, module.calcUmaAppealBond(prin));

        uint256 half = recovered >> 1;
        assertEq(_receivable(reporter) - reporterBefore, half);
        assertEq(_receivable(challenger) - challengerBefore, recovered - half);
        // On settle path (cancel), reporter bounty escrow goes to treasury via _creditPending
        uint256 expectedBountyToTreasury2 = viaExpire ? 0 : (pot.fee() * 2000) / 10_000;
        assertEq(_receivable(treasury) - treasuryBefore, expectedBountyToTreasury2);
    }

    function test_umaAppeal_matrix_recoveredRouting_settle() public {
        uint8[3] memory umaWinners = [uint8(1), uint8(2), uint8(3)];

        for (uint256 i; i < umaWinners.length; i++) {
            (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket3Outcome();

            uint256 prin = _principal(id);
            uint256 appealBond = module.calcUmaAppealBond(prin);

            uint256 appellantBefore = _receivable(appellant);
            vm.prank(appellant);
            module.startUmaAppeal(id);

            bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 3);
            uint256 payout = rb * 2 - 1;
            mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payout);
            mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(uint256(umaWinners[i])));

            uint256 treasuryBefore = _receivable(treasury);
            uint256 reporterBefore = _receivable(reporter);
            uint256 challengerBefore = _receivable(challenger);

            module.settleUmaAppeal(id);

            (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
            assertEq(winner, umaWinners[i]);
            assertEq(status, ST_RESOLVED);

            if (umaWinners[i] == 2) {
                assertEq(_receivable(appellant), appellantBefore - appealBond);
            } else {
                assertEq(_receivable(appellant), appellantBefore);
            }

            if (umaWinners[i] == 1) {
                uint256 rake = _disputeRake(rb, payout);
                assertEq(_receivable(treasury) - treasuryBefore, rake);
                assertEq(_receivable(reporter) - reporterBefore, payout - rake);
                assertEq(_receivable(challenger), challengerBefore);
            } else if (umaWinners[i] == 2) {
                uint256 rake = _disputeRake(rb, payout);
                assertEq(_receivable(treasury) - treasuryBefore, appealBond + rake);
                assertEq(_receivable(challenger) - challengerBefore, payout - rake);
                assertEq(_receivable(reporter), reporterBefore);
            } else {
                assertEq(_receivable(treasury) - treasuryBefore, payout);
                assertEq(_receivable(reporter), reporterBefore);
                assertEq(_receivable(challenger), challengerBefore);
            }
        }
    }

    function test_expireUmaAppeal_matrix_recoveredRouting_when_settle_succeeds() public {
        uint8[3] memory umaWinners = [uint8(1), uint8(2), uint8(3)];

        for (uint256 i; i < umaWinners.length; i++) {
            (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket3Outcome();

            uint256 prin = _principal(id);
            uint256 appealBond = module.calcUmaAppealBond(prin);

            uint256 appellantBefore = _receivable(appellant);
            vm.prank(appellant);
            module.startUmaAppeal(id);

            bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 3);
            uint256 payout = rb * 2 - 1;
            mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payout);
            mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(uint256(umaWinners[i])));

            (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
            vm.warp(uint256(umaStartedAt) + 30 days + 1);

            uint256 treasuryBefore = _receivable(treasury);
            uint256 reporterBefore = _receivable(reporter);
            uint256 challengerBefore = _receivable(challenger);

            module.expireUmaAppeal(id);

            (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
            assertEq(winner, umaWinners[i]);
            assertEq(status, ST_RESOLVED);

            if (umaWinners[i] == 2) {
                assertEq(_receivable(appellant), appellantBefore - appealBond);
            } else {
                assertEq(_receivable(appellant), appellantBefore);
            }

            if (umaWinners[i] == 1) {
                uint256 rake = _disputeRake(rb, payout);
                assertEq(_receivable(treasury) - treasuryBefore, rake);
                assertEq(_receivable(reporter) - reporterBefore, payout - rake);
                assertEq(_receivable(challenger), challengerBefore);
            } else if (umaWinners[i] == 2) {
                uint256 rake = _disputeRake(rb, payout);
                assertEq(_receivable(treasury) - treasuryBefore, appealBond + rake);
                assertEq(_receivable(challenger) - challengerBefore, payout - rake);
                assertEq(_receivable(reporter), reporterBefore);
            } else {
                assertEq(_receivable(treasury) - treasuryBefore, payout);
                assertEq(_receivable(reporter), reporterBefore);
                assertEq(_receivable(challenger), challengerBefore);
            }
        }
    }

    function test_expireUmaAppeal_matrix_invalidPrice_refundHalfHalf_withRemainders() public {
        uint256[5] memory payouts = [uint256(0), uint256(1), uint256(2), uint256(3), uint256(199e6)];

        for (uint256 i; i < payouts.length; i++) {
            (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

            uint256 prin = _principal(id);
            uint256 appealBond = module.calcUmaAppealBond(prin);

            uint256 appellantBefore = _receivable(appellant);
            vm.prank(appellant);
            module.startUmaAppeal(id);

            bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
            mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payouts[i]);
            mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(0));

            (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
            vm.warp(uint256(umaStartedAt) + 30 days + 1);

            uint256 reporterBefore = _receivable(reporter);
            uint256 challengerBefore = _receivable(challenger);

            module.expireUmaAppeal(id);

            (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
            assertEq(winner, 2);
            assertEq(status, ST_RESOLVED);
            assertEq(_receivable(appellant), appellantBefore);

            uint256 recovered = payouts[i] == 0 ? rb * 2 : payouts[i];
            uint256 half = recovered >> 1;
            assertEq(_receivable(reporter) - reporterBefore, half);
            assertEq(_receivable(challenger) - challengerBefore, recovered - half);
            assertEq(appealBond, module.calcUmaAppealBond(prin));
        }
    }

    function test_settleUmaAppeal_matrix_invalidPriceValues_cancel_and_refundHalfHalf_withRemainder() public {
        int256[3] memory invalidPrices = [int256(-1), int256(0), int256(3)];

        for (uint256 i; i < invalidPrices.length; i++) {
            (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

            uint256 prin = _principal(id);
            uint256 appealBond = module.calcUmaAppealBond(prin);

            uint256 appellantBefore = _receivable(appellant);
            vm.prank(appellant);
            module.startUmaAppeal(id);

            bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
            uint256 payout = rb * 2 - 1;
            mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payout);
            mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, invalidPrices[i]);

            uint256 treasuryBefore = _receivable(treasury);
            uint256 reporterBefore = _receivable(reporter);
            uint256 challengerBefore = _receivable(challenger);

            module.settleUmaAppeal(id);

            (,,,,,,,, uint8 status,,) = pot.getMkt(id);
            assertEq(status, ST_CANCELLED);

            assertEq(_receivable(appellant), appellantBefore);
            assertEq(appealBond, module.calcUmaAppealBond(prin));

            uint256 half = payout >> 1;
            assertEq(_receivable(reporter) - reporterBefore, half);
            assertEq(_receivable(challenger) - challengerBefore, payout - half);
            // Reporter bounty escrow goes to treasury on cancellation via _creditPending
            uint256 bounty = (pot.fee() * 2000) / 10_000;
            if (bounty > 0) {
                vm.prank(treasury);
                pot.withdrawPending();
            }
            assertEq(_receivable(treasury) - treasuryBefore, bounty);
        }
    }

    function test_expireUmaAppeal_matrix_invalidPriceValues_resolve_committee_and_refundHalfHalf_withRemainder()
        public
    {
        int256[3] memory invalidPrices = [int256(-1), int256(0), int256(3)];

        for (uint256 i; i < invalidPrices.length; i++) {
            (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

            uint256 prin = _principal(id);
            uint256 appealBond = module.calcUmaAppealBond(prin);

            uint256 appellantBefore = _receivable(appellant);
            vm.prank(appellant);
            module.startUmaAppeal(id);

            bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
            uint256 payout = rb * 2 - 1;
            mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payout);
            mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, invalidPrices[i]);

            (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
            vm.warp(uint256(umaStartedAt) + UMA_STALE_TIMEOUT + 1);

            uint256 treasuryBefore = _receivable(treasury);
            uint256 reporterBefore = _receivable(reporter);
            uint256 challengerBefore = _receivable(challenger);

            module.expireUmaAppeal(id);

            (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
            assertEq(winner, 2);
            assertEq(status, ST_RESOLVED);

            assertEq(_receivable(appellant), appellantBefore);
            assertEq(appealBond, module.calcUmaAppealBond(prin));

            uint256 half = payout >> 1;
            assertEq(_receivable(reporter) - reporterBefore, half);
            assertEq(_receivable(challenger) - challengerBefore, payout - half);
            assertEq(_receivable(treasury), treasuryBefore);
        }
    }

    function test_settleUmaAppeal_matrix_payoutZero_recovers2xBond_routesRecoveredByWinner() public {
        uint8[3] memory umaWinners = [uint8(1), uint8(2), uint8(3)];

        for (uint256 i; i < umaWinners.length; i++) {
            (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket3Outcome();

            uint256 prin = _principal(id);
            uint256 appealBond = module.calcUmaAppealBond(prin);

            uint256 appellantBefore = _receivable(appellant);
            vm.prank(appellant);
            module.startUmaAppeal(id);

            bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 3);
            mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(uint256(umaWinners[i])));

            uint256 treasuryBefore = _receivable(treasury);
            uint256 reporterBefore = _receivable(reporter);
            uint256 challengerBefore = _receivable(challenger);

            module.settleUmaAppeal(id);

            (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
            assertEq(winner, umaWinners[i]);
            assertEq(status, ST_RESOLVED);

            uint256 recovered = rb * 2;

            if (winner == 2) {
                assertEq(_receivable(appellant), appellantBefore - appealBond);
            } else {
                assertEq(_receivable(appellant), appellantBefore);
            }

            uint256 expectedTreasury = winner == 2 ? appealBond : 0;
            if (winner == 1 || winner == 2) {
                expectedTreasury += _disputeRake(rb, recovered);
            }
            expectedTreasury += winner == 3 ? recovered : 0;
            assertEq(_receivable(treasury) - treasuryBefore, expectedTreasury);

            uint256 expectedReporter = winner == 1 ? recovered - _disputeRake(rb, recovered) : 0;
            assertEq(_receivable(reporter) - reporterBefore, expectedReporter);

            uint256 expectedChallenger = winner == 2 ? recovered - _disputeRake(rb, recovered) : 0;
            assertEq(_receivable(challenger) - challengerBefore, expectedChallenger);
        }
    }

    function testFuzz_expireUmaAppeal_withdrawOnlyPath_refundsRecoveredHalfHalf(uint256 payoutRaw) public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);

        uint256 maxPayout = rb * 2;
        uint256 payout = bound(payoutRaw, 0, maxPayout);
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, payout);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(0));

        vm.prank(address(this));
        adapter.settle(uint256(resTime), ancillary);

        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        vm.warp(uint256(umaStartedAt) + UMA_STALE_TIMEOUT + 1);

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);

        module.expireUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, 2);
        assertEq(status, ST_RESOLVED);

        assertEq(_receivable(appellant), appellantBefore);
        assertEq(appealBond, module.calcUmaAppealBond(prin));

        uint256 recovered = payout == 0 ? maxPayout : payout;
        uint256 half = recovered >> 1;
        assertEq(_receivable(reporter) - reporterBefore, half);
        assertEq(_receivable(challenger) - challengerBefore, recovered - half);
        assertEq(_receivable(treasury), treasuryBefore);
    }

    function testFuzz_expireUmaAppeal_staleTimeout_gates_and_fallsBack_when_oracleSettleReverts(uint256 dtRaw) public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUma.setPayout(IDENTIFIER, uint256(resTime), ancillary, rb);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(1));
        mockUma.setRevertOnSettle(true);

        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        uint256 dt = bound(dtRaw, 0, UMA_STALE_TIMEOUT * 2);
        vm.warp(uint256(umaStartedAt) + dt);

        if (dt <= UMA_STALE_TIMEOUT) {
            vm.expectRevert(yPotUma.E2.selector);
            module.expireUmaAppeal(id);
            return;
        }

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);

        module.expireUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, 2);
        assertEq(status, ST_RESOLVED);

        assertEq(_receivable(appellant), appellantBefore);
        assertEq(appealBond, module.calcUmaAppealBond(prin));

        assertEq(_receivable(treasury), treasuryBefore);
        assertEq(_receivable(reporter), reporterBefore);
        assertEq(_receivable(challenger), challengerBefore);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _disputeRake(uint256 loserBond, uint256 recovered) internal view returns (uint256 rake) {
        rake = (loserBond * pot.disputeRakeBps()) / BPS;
        if (rake > recovered) {
            rake = recovered;
        }
    }

    function _receivable(address who) internal view returns (uint256) {
        return usdc.balanceOf(who) + pot.pendingWithdrawals(who);
    }

    function _mintApprovePot(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }

    function _mintApproveModule(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(module), type(uint256).max);
    }

    function _setupAppealableMarket()
        internal
        returns (uint256 id, string memory desc, uint64 resTime, uint64 appealDeadline, uint256 reportBond)
    {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        id = pot.create("UMA appeal market", "bafyUmaAppeal", dl, rt, 2, "", address(0));

        vm.prank(alice);
        pot.bet(id, 1, 100e6, 0, block.timestamp + 1);
        vm.prank(bob);
        pot.bet(id, 2, 100e6, 0, block.timestamp + 1);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);
        vm.prank(challenger);
        pot.challenge(id, 2);

        vm.prank(oracle0);
        pot.resolveDispute(id, 2);
        vm.prank(oracle1);
        pot.resolveDispute(id, 2);

        uint8 status;
        (desc,,,, resTime,,,, status,,) = pot.getMkt(id);
        assertEq(status, ST_APPEALABLE);

        (appealDeadline,,,) = pot.getAppealInfo(id);

        uint256 cb;
        (,, reportBond,,,,, cb) = pot.getReport(id);
        assertEq(reportBond, cb);
    }

    function _setupAppealableMarketWithConfirm(uint256 confirmAssets)
        internal
        returns (uint256 id, string memory desc, uint64 resTime, uint64 appealDeadline, uint256 reportBond)
    {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        id = pot.create("UMA appeal market", "bafyUmaAppeal", dl, rt, 2, "", address(0));

        vm.prank(alice);
        pot.bet(id, 1, 100e6, 0, block.timestamp + 1);
        vm.prank(bob);
        pot.bet(id, 2, 100e6, 0, block.timestamp + 1);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);
        vm.prank(alice);
        pot.confirmReport(id, confirmAssets, 0, uint256(rt) + 1);

        vm.prank(challenger);
        pot.challenge(id, 2);

        vm.prank(oracle0);
        pot.resolveDispute(id, 2);
        vm.prank(oracle1);
        pot.resolveDispute(id, 2);

        uint8 status;
        (desc,,,, resTime,,,, status,,) = pot.getMkt(id);
        assertEq(status, ST_APPEALABLE);

        (appealDeadline,,,) = pot.getAppealInfo(id);

        uint256 cb;
        (,, reportBond,,,,, cb) = pot.getReport(id);
        assertEq(reportBond, cb);
    }

    function _setupAppealableMarket3Outcome()
        internal
        returns (uint256 id, string memory desc, uint64 resTime, uint64 appealDeadline, uint256 reportBond)
    {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        id = pot.create("UMA appeal market", "bafyUmaAppeal", dl, rt, 3, "", address(0));

        vm.prank(alice);
        pot.bet(id, 1, 100e6, 0, block.timestamp + 1);
        vm.prank(bob);
        pot.bet(id, 2, 100e6, 0, block.timestamp + 1);
        vm.prank(challenger);
        pot.bet(id, 3, 100e6, 0, block.timestamp + 1);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);
        vm.prank(challenger);
        pot.challenge(id, 2);

        vm.prank(oracle0);
        pot.resolveDispute(id, 2);
        vm.prank(oracle1);
        pot.resolveDispute(id, 2);

        uint8 status;
        (desc,,,, resTime,,,, status,,) = pot.getMkt(id);
        assertEq(status, ST_APPEALABLE);

        (appealDeadline,,,) = pot.getAppealInfo(id);

        uint256 cb;
        (,, reportBond,,,,, cb) = pot.getReport(id);
        assertEq(reportBond, cb);
    }

    function _principal(uint256 id) internal view returns (uint256 prin) {
        (,,,,,,,,,, prin) = pot.getMkt(id);
    }

    function _ancillary(
        uint256 id,
        string memory desc,
        uint64 resTime,
        uint8 committeeWinner,
        uint8 reportedOutcome,
        uint8 challengedOutcome,
        uint8 outcomes
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            "yPot market #",
            Strings.toString(id),
            " on chain ",
            Strings.toString(block.chainid),
            " | Resolution timestamp: ",
            Strings.toString(uint256(resTime)),
            ": ",
            desc,
            " | Committee winner: ",
            Strings.toString(uint256(committeeWinner)),
            " | Reported outcome: ",
            Strings.toString(uint256(reportedOutcome)),
            " | Challenged outcome: ",
            Strings.toString(uint256(challengedOutcome)),
            " | Valid outcomes: 1-",
            Strings.toString(uint256(outcomes)),
            " | Return the winning outcome number."
        );
    }
}
