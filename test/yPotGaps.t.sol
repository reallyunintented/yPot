// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

contract yPotGapsTest is Test {
    uint256 private constant BPS = 10_000;
    uint256 private constant YIELD_FEE_BPS = 500;
    uint256 private constant CHALLENGE_WINDOW = 48 hours;
    uint256 private constant DISPUTE_PERIOD = 24 hours;

    uint8 private constant ST_CLAIMABLE = 3;
    uint8 private constant ST_CANCELLED = 4;
    uint8 private constant ST_REPORTED = 5;

    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    address internal treasury = address(0xBEEF);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);
    address internal oracle2 = address(0x1234);
    address internal oracle3 = address(0x2345);
    address internal oracle4 = address(0x3456);

    address internal creator = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xC0C0A);
    address internal reporter = address(0xD00D);

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
        _mintApprove(carol, 1_000_000e6);
        _mintApprove(reporter, 1_000_000e6);
    }

    function test_claim_timeWeighted_earlier_winner_gets_more_than_later_winner() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket("time weighted");

        uint256 t0 = block.timestamp;
        _bet(alice, id, 1, 100e6);

        vm.warp(t0 + 1 hours);
        _bet(bob, id, 1, 100e6);
        _bet(carol, id, 2, 100e6);

        _resolveToClaimableNoChallenge(id, dl, rt, 1, alice);

        (uint256 aliceEntitled, uint256 aliceAssetsOut, uint256 alicePayout, uint256 aliceW) = _claimQuote(id, alice);
        (uint256 bobEntitled, uint256 bobAssetsOut, uint256 bobPayout, uint256 bobW) = _claimQuote(id, bob);

        assertEq(_status(id), ST_CLAIMABLE);
        assertGt(aliceW, bobW);
        assertGt(aliceEntitled, bobEntitled);
        assertGt(alicePayout, bobPayout);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.claim(id, 0, aliceAssetsOut);
        uint256 aliceDelta = usdc.balanceOf(alice) - aliceBefore;
        assertEq(aliceDelta, alicePayout);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pot.claim(id, 0, bobAssetsOut);
        uint256 bobDelta = usdc.balanceOf(bob) - bobBefore;
        assertEq(bobDelta, bobPayout);
    }

    function testFuzz_claim_timeWeighted_payoutProportionalToWeightedShares(
        uint256 aliceAmtRaw,
        uint256 bobAmtRaw,
        uint256 timeDeltaRaw
    ) public {
        uint256 aliceAmt = bound(aliceAmtRaw, 1e6, 500_000e6);
        uint256 bobAmt = bound(bobAmtRaw, 1e6, 500_000e6);

        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        uint256 id = pot.create("time weighted fuzz", "bafyGapFuzz", dl, rt, 2, "", address(0));

        pot.setConfirmBps(0);

        uint256 t0 = block.timestamp;
        _bet(alice, id, 1, aliceAmt);

        uint256 delta = bound(timeDeltaRaw, 1, 5 hours);
        vm.warp(t0 + delta);
        _bet(bob, id, 1, bobAmt);
        _bet(carol, id, 2, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));
        vm.prank(reporter);
        pot.report(id, 1);
        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);
        vm.warp(block.timestamp + DISPUTE_PERIOD + 1);
        pot.finalize(id);

        assertEq(_status(id), ST_CLAIMABLE);

        (uint256 aliceEntitled, uint256 aliceAssetsOut, uint256 alicePayout, uint256 aliceW) = _claimQuote(id, alice);
        (uint256 bobEntitled, uint256 bobAssetsOut, uint256 bobPayout, uint256 bobW) = _claimQuote(id, bob);

        assertGt(aliceW, 0);
        assertGt(bobW, 0);
        assertGt(aliceEntitled, 0);
        assertGt(bobEntitled, 0);

        uint256 lhs = alicePayout * bobW;
        uint256 rhs = bobPayout * aliceW;
        assertApproxEqAbs(lhs, rhs, aliceW + bobW + 2);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.claim(id, 0, aliceAssetsOut);
        assertEq(usdc.balanceOf(alice) - aliceBefore, alicePayout);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pot.claim(id, 0, bobAssetsOut);
        assertEq(usdc.balanceOf(bob) - bobBefore, bobPayout);
    }

    function test_claim_multiWinner_splits_pool_by_weighted_share_ratio() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket("multi winner split");

        _bet(alice, id, 1, 150e6);
        _bet(bob, id, 1, 50e6);
        _bet(carol, id, 2, 100e6);

        _resolveToClaimableNoChallenge(id, dl, rt, 1, alice);

        (uint256 aliceEntitled, uint256 aliceAssetsOut, uint256 alicePayout, uint256 aliceW) = _claimQuote(id, alice);
        (uint256 bobEntitled, uint256 bobAssetsOut, uint256 bobPayout, uint256 bobW) = _claimQuote(id, bob);

        uint256 lhs = aliceEntitled * bobW;
        uint256 rhs = bobEntitled * aliceW;
        assertApproxEqAbs(lhs, rhs, aliceW + bobW);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.claim(id, 0, aliceAssetsOut);
        assertEq(usdc.balanceOf(alice) - aliceBefore, alicePayout);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pot.claim(id, 0, bobAssetsOut);
        assertEq(usdc.balanceOf(bob) - bobBefore, bobPayout);
    }

    function test_batchClaim_claims_multiple_markets() public {
        (uint256 id1, uint64 dl1, uint64 rt1) = _create2OutcomeMarket("batch-1");
        _bet(alice, id1, 1, 100e6);
        _bet(bob, id1, 2, 100e6);
        _resolveToClaimableNoChallenge(id1, dl1, rt1, 1, alice);

        (uint256 id2, uint64 dl2, uint64 rt2) = _create2OutcomeMarket("batch-2");
        _bet(alice, id2, 1, 80e6);
        _bet(bob, id2, 2, 120e6);
        _resolveToClaimableNoChallenge(id2, dl2, rt2, 1, alice);

        (uint256 ent1, uint256 assetsOut1, uint256 payout1,) = _claimQuote(id1, alice);
        (uint256 ent2, uint256 assetsOut2, uint256 payout2,) = _claimQuote(id2, alice);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = assetsOut1;
        minOuts[1] = assetsOut2;

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.batchClaim(ids, minOuts);
        assertEq(usdc.balanceOf(alice) - aliceBefore, payout1 + payout2);

        (,, uint256 claimed1, bool done1) = pot.getUsr(id1, alice);
        (,, uint256 claimed2, bool done2) = pot.getUsr(id2, alice);
        assertEq(claimed1, ent1);
        assertEq(claimed2, ent2);
        assertTrue(done1);
        assertTrue(done2);
    }

    function test_batchClaim_reverts_atomically_when_one_market_has_zero_entitlement() public {
        (uint256 id1, uint64 dl1, uint64 rt1) = _create2OutcomeMarket("batch-ok");
        _bet(alice, id1, 1, 100e6);
        _bet(bob, id1, 2, 100e6);
        _resolveToClaimableNoChallenge(id1, dl1, rt1, 1, alice);

        (uint256 id2, uint64 dl2, uint64 rt2) = _create2OutcomeMarket("batch-fail");
        _bet(alice, id2, 1, 100e6);
        _bet(bob, id2, 2, 100e6);
        _resolveToClaimableNoChallenge(id2, dl2, rt2, 2, bob);

        (uint256 ent1, uint256 assetsOut1,,) = _claimQuote(id1, alice);
        (uint256 ent2,,,) = _claimQuote(id2, alice);
        assertGt(ent1, 0);
        assertEq(ent2, 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = assetsOut1;
        minOuts[1] = 0;

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(yPot.E1.selector);
        pot.batchClaim(ids, minOuts);

        assertEq(usdc.balanceOf(alice), aliceBefore);
        (,, uint256 claimed1, bool done1) = pot.getUsr(id1, alice);
        assertEq(claimed1, 0);
        assertFalse(done1);
    }

    function test_create_reverts_when_description_contains_pipe() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        vm.expectRevert(yPot.E1.selector);
        pot.create("bad|market", "bafy", dl, rt, 2, "", address(0));
    }

    function test_create_reverts_for_invalid_outcomes_and_time_order() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = uint64(uint256(dl) + 2 hours);

        vm.startPrank(creator);

        vm.expectRevert(yPot.E1.selector);
        pot.create("invalid outcomes low", "bafy", dl, rt, 1, "", address(0));

        vm.expectRevert(yPot.E1.selector);
        pot.create("invalid outcomes high", "bafy", dl, rt, type(uint8).max, "", address(0));

        vm.expectRevert(yPot.E1.selector);
        pot.create("invalid rt eq dl", "bafy", dl, dl, 2, "", address(0));

        vm.expectRevert(yPot.E1.selector);
        pot.create("invalid rt lt dl", "bafy", dl, dl - 1, 2, "", address(0));

        vm.stopPrank();
    }

    function test_expireMarket_after_7_days_without_report_cancels() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket("expire market");

        _bet(alice, id, 1, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);

        vm.warp(uint256(rt) + 7 days);
        vm.expectRevert(yPot.E2.selector);
        pot.expireMarket(id);

        vm.warp(uint256(rt) + 7 days + 1);
        pot.expireMarket(id);
        assertEq(_status(id), ST_CANCELLED);

        (uint256[] memory s,,,) = pot.getUsr(id, alice);
        uint256 expectedOut = wrapper.previewRedeem(s[1]);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.emergencyWithdraw(id, expectedOut);
        assertEq(usdc.balanceOf(alice) - aliceBefore, expectedOut);
    }

    function test_emergencyWithdraw_reverts_when_minOut_stale_after_rate_drop() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket("expire slippage");

        _bet(alice, id, 1, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt) + 7 days + 1);
        pot.expireMarket(id);
        assertEq(_status(id), ST_CANCELLED);

        (uint256[] memory s,,,) = pot.getUsr(id, alice);
        uint256 shares = s[1];
        assertGt(shares, 0);

        yearn.setExchangeRate(12e17);
        uint256 staleHighMinOut = wrapper.previewRedeem(shares);
        yearn.setExchangeRate(1e18);

        vm.prank(alice);
        vm.expectRevert(yPot.E6.selector);
        pot.emergencyWithdraw(id, staleHighMinOut);

        uint256 minOutNow = wrapper.previewRedeem(shares);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.emergencyWithdraw(id, minOutNow);
        assertEq(usdc.balanceOf(alice) - aliceBefore, minOutNow);
    }

    function test_cancel_reverts_in_wrong_states_and_time_boundary() public {
        (uint256 idTime,, uint64 rtTime) = _create2OutcomeMarket("cancel-time");
        vm.warp(uint256(rtTime));
        vm.expectRevert(yPot.E2.selector);
        pot.cancel(idTime);

        (uint256 idReported, uint64 dlReported, uint64 rtReported) = _create2OutcomeMarket("cancel-reported");
        _bet(alice, idReported, 1, 100e6);
        _bet(bob, idReported, 2, 100e6);
        vm.warp(uint256(dlReported) + 1);
        pot.close(idReported);
        vm.warp(uint256(rtReported));
        vm.prank(reporter);
        pot.report(idReported, 1);
        assertEq(_status(idReported), ST_REPORTED);

        vm.expectRevert(yPot.E2.selector);
        pot.cancel(idReported);

        (uint256 idClaimable, uint64 dlClaimable, uint64 rtClaimable) = _create2OutcomeMarket("cancel-claimable");
        _bet(alice, idClaimable, 1, 100e6);
        _bet(bob, idClaimable, 2, 100e6);
        _resolveToClaimableNoChallenge(idClaimable, dlClaimable, rtClaimable, 1, alice);
        assertEq(_status(idClaimable), ST_CLAIMABLE);

        vm.expectRevert(yPot.E2.selector);
        pot.cancel(idClaimable);
    }

    function test_create_reverts_when_resolution_delay_exceeds_180_days() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rtTooFar = uint64(uint256(dl) + 181 days);

        vm.prank(creator);
        vm.expectRevert(yPot.E7.selector);
        pot.create("too long delay", "bafy", dl, rtTooFar, 2, "", address(0));
    }

    function test_create_succeeds_when_resolution_delay_is_exactly_180_days() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rtOk = uint64(uint256(dl) + 180 days);

        vm.prank(creator);
        uint256 id = pot.create("exact 180d delay", "bafy", dl, rtOk, 2, "", address(0));
        assertGt(id, 0);
    }

    function test_setConfirms_reverts_when_not_strict_majority_with_five_oracles() public {
        pot.setOracle(oracle2, true);
        pot.setOracle(oracle3, true);
        pot.setOracle(oracle4, true);
        assertEq(pot.oracleN(), 5);

        vm.expectRevert(yPot.E1.selector);
        pot.setConfirms(2);

        pot.setConfirms(3);
        assertEq(pot.confirms(), 3);
    }

    function _resolveToClaimableNoChallenge(uint256 id, uint64 dl, uint64 rt, uint8 winner, address confirmer)
        internal
    {
        vm.warp(uint256(dl) + 1);
        pot.close(id);

        vm.warp(uint256(rt));
        vm.prank(reporter);
        pot.report(id, winner);

        (,, uint256 requiredShares) = pot.getConfirm(id, confirmer);
        uint256 assetsIn = _assetsForAtLeastShares(requiredShares);
        vm.prank(confirmer);
        pot.confirmReport(id, assetsIn, 0, block.timestamp + 1);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        vm.warp(block.timestamp + DISPUTE_PERIOD + 1);
        pot.finalize(id);
    }

    function _claimQuote(uint256 id, address user)
        internal
        view
        returns (uint256 entitledShares, uint256 assetsOut, uint256 payout, uint256 userWeightedShares)
    {
        (,,,,,,, uint8 winner,,,) = pot.getMkt(id);
        (, uint256[] memory wsh,,) = pot.getUsr(id, user);
        userWeightedShares = wsh[winner];
        if (userWeightedShares == 0) return (0, 0, 0, 0);

        (, uint256[] memory totalWsh, uint256 poolShares,,) = pot.getShares(id);
        uint256 totalWinnerWeighted = totalWsh[winner];

        entitledShares = Math.mulDiv(userWeightedShares, poolShares, totalWinnerWeighted);
        assetsOut = wrapper.previewRedeem(entitledShares);

        (,,,,,,,,,, uint256 prin) = pot.getMkt(id);
        uint256 cp = Math.mulDiv(prin, entitledShares, poolShares);
        uint256 tf = assetsOut > cp ? Math.mulDiv(assetsOut - cp, YIELD_FEE_BPS, BPS) : 0;
        payout = assetsOut - tf;
    }

    function _status(uint256 id) internal view returns (uint8 status) {
        (,,,,,,,, status,,) = pot.getMkt(id);
    }

    function _create2OutcomeMarket(string memory desc) internal returns (uint256 id, uint64 dl, uint64 rt) {
        dl = uint64(block.timestamp + 14 days + 1);
        rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        id = pot.create(desc, "bafyGap", dl, rt, 2, "", address(0));
    }

    function _bet(address who, uint256 id, uint8 outcome, uint256 amount) internal {
        vm.prank(who);
        pot.bet(id, outcome, amount, 0, block.timestamp + 1);
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

    function _mintApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }
}
