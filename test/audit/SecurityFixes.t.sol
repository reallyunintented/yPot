// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {yPot} from "src/yPot.sol";
import {yPotUma} from "src/yPotUma.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";
import {UmaOptimisticOracleAdapter} from "src/UmaOptimisticOracleAdapter.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";
import {MockUmaOptimisticOracle} from "test/mocks/MockUmaOptimisticOracle.sol";

/// @title SecurityFixes — Pull-Based Distributions, UMA Revoke, Oracle Vote Revoke
/// @notice Tests for the 4 security fixes from external audit (todo.md #9).
contract SecurityFixesTest is Test {
    // Re-declare events for vm.expectEmit
    event PendingWithdrawn(address indexed recipient, uint256 amount);
    uint256 private constant BPS = 10_000;
    uint256 private constant CHALLENGE_WINDOW = 48 hours;
    uint256 private constant DISPUTE_PERIOD = 24 hours;
    uint256 private constant SWEEP_DELAY = 30 days;
    bytes32 private constant IDENTIFIER = keccak256("YPOT_LOCAL");

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

        // UMA stack
        mockUma = new MockUmaOptimisticOracle();
        address[] memory requesters = new address[](1);
        requesters[0] = address(this);
        adapter = new UmaOptimisticOracleAdapter(address(mockUma), usdc, IDENTIFIER, 0, 0, 0, requesters);
        module = new yPotUma(address(pot), address(adapter));
        pot.setUmaModule(address(module));
        adapter.setRequester(address(module), true);

        _mintApprove(creator, 10_000_000e6);
        _mintApprove(alice, 10_000_000e6);
        _mintApprove(bob, 10_000_000e6);
        _mintApprove(reporter, 10_000_000e6);
        _mintApprove(challenger, 10_000_000e6);
        _mintApproveModule(appellant, 10_000_000e6);
    }

    // =====================================================================
    // FIX 1: Pull-Based Fee/Bond Distribution
    // =====================================================================

    /// @notice Fees are credited to pendingWithdrawals, not transferred directly.
    function test_pullClaim_feesCredited_notTransferred() public {
        (uint256 id,, uint64 rt) = _resolvedMarket();

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 reporterBefore = usdc.balanceOf(reporter);

        // Claim triggers _distributeFees → _creditPending for treasury + truth-teller
        vm.prank(alice);
        pot.claim(id, 0, 0);

        // Direct balances should NOT have changed (fees are pending)
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "treasury wallet balance changed immediately");
        assertEq(usdc.balanceOf(reporter), reporterBefore, "reporter wallet balance changed immediately");

        // But pendingWithdrawals should have been credited
        assertGt(pot.pendingWithdrawals(treasury), 0, "treasury not credited");
        assertGt(pot.pendingWithdrawals(reporter), 0, "reporter not credited");
    }

    /// @notice State transition succeeds even if treasury is USDC-blacklisted.
    function test_pullClaim_succeeds_when_treasury_blacklisted() public {
        (uint256 id,, uint64 rt) = _resolvedMarket();

        // Mock treasury as blacklisted: any safeTransfer to treasury will revert
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(usdc.transfer.selector, treasury),
            "blacklisted"
        );

        // Claim should still succeed (fees go to pendingWithdrawals, not direct transfer)
        vm.prank(alice);
        pot.claim(id, 0, 0);

        // Treasury fees are pending
        assertGt(pot.pendingWithdrawals(treasury), 0, "treasury fees not credited");
    }

    /// @notice sweepDust still succeeds even if treasury token transfers would revert.
    function test_sweepDust_succeeds_when_treasury_blacklisted() public {
        (uint256 id,,) = _resolvedMarket();

        (uint256[] memory aliceShares,,,) = pot.getUsr(id, alice);
        uint256 partialClaim = aliceShares[1] / 2;
        assertGt(partialClaim, 0, "need remaining shares to sweep");

        vm.prank(alice);
        pot.claim(id, partialClaim, 0);

        (,,,,, uint64 resolved,,,,,) = pot.getMkt(id);
        vm.warp(uint256(resolved) + DISPUTE_PERIOD + SWEEP_DELAY + 1);

        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(usdc.transfer.selector, treasury),
            "blacklisted"
        );

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 pendingBefore = pot.pendingWithdrawals(treasury);

        pot.sweepDust(id, 0);

        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, 6, "market not swept");
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "treasury wallet balance changed immediately");
        assertGt(pot.pendingWithdrawals(treasury), pendingBefore, "sweep not credited");
    }

    /// @notice sweepExcessVaultShares still succeeds even if treasury token transfers would revert.
    function test_sweepExcessVaultShares_succeeds_when_treasury_blacklisted() public {
        uint256 assetsIn = 50_000e6;
        usdc.mint(address(this), assetsIn);
        usdc.approve(address(wrapper), assetsIn);
        uint256 excessShares = wrapper.deposit(assetsIn, address(this));
        wrapper.transfer(address(pot), excessShares);

        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(usdc.transfer.selector, treasury),
            "blacklisted"
        );

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 pendingBefore = pot.pendingWithdrawals(treasury);

        pot.sweepExcessVaultShares(0, 0);

        assertEq(usdc.balanceOf(treasury), treasuryBefore, "treasury wallet balance changed immediately");
        assertEq(wrapper.balanceOf(address(pot)), pot.accountedShares(), "excess shares not swept");
        assertGt(pot.pendingWithdrawals(treasury), pendingBefore, "excess sweep not credited");
    }

    /// @notice Bond distribution after finalize credits bonds to pendingWithdrawals.
    function test_pullBonds_finalize_creditsBonds() public {
        (uint256 id, uint64 dl, uint64 rt) = _challengedMarket();

        // Oracles resolve to reporter's outcome (1)
        vm.prank(oracle0);
        pot.resolveDispute(id, 1);
        vm.prank(oracle1);
        pot.resolveDispute(id, 1);

        // Skip appeal window + dispute period
        (uint64 appealDeadline,,,) = pot.getAppealInfo(id);
        vm.warp(uint256(appealDeadline) + DISPUTE_PERIOD + 1);
        pot.finalize(id);

        // Reporter should have pending bond credit (winner gets loser's bond minus rake)
        uint256 reporterPending = pot.pendingWithdrawals(reporter);
        assertGt(reporterPending, 0, "reporter not credited after dispute finalize");
    }

    /// @notice Reporter bond returned via pendingWithdrawals after acceptReport.
    function test_pullBonds_acceptReport_creditsReporterBond() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100_000e6);
        _bet(bob, id, 2, 50_000e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(alice);
        pot.confirmReport(id, 50_000e6, 0, block.timestamp + 1);

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);

        uint256 reporterBefore = usdc.balanceOf(reporter);
        pot.acceptReport(id);
        uint256 reporterAfter = usdc.balanceOf(reporter);

        // Reporter bond should NOT have been directly transferred
        assertEq(reporterAfter, reporterBefore, "reporter wallet balance changed immediately in acceptReport");
        // But should be pending
        assertGt(pot.pendingWithdrawals(reporter), 0, "reporter bond not credited");
    }

    /// @notice Both bonds credited via pendingWithdrawals when challenge expires unresolved.
    function test_pullBonds_expireChallenge_creditsBothBonds() public {
        (uint256 id, uint64 dl, uint64 rt) = _challengedMarket();

        // Don't resolve dispute — let it expire
        (, , , uint64 reportedAt,,,,) = pot.getReport(id);
        vm.warp(uint256(reportedAt) + CHALLENGE_WINDOW + 7 days + 1);
        pot.expireChallenge(id);

        // Both reporter and challenger should have pending credits
        assertGt(pot.pendingWithdrawals(reporter), 0, "reporter bond not credited on expire");
        assertGt(pot.pendingWithdrawals(challenger), 0, "challenger bond not credited on expire");
    }

    /// @notice UMA settlement still resolves if a recipient would revert on token transfer.
    function test_umaSettle_succeeds_when_reporter_transferFrom_reverts() public {
        (uint256 id,,) = _appealableMarket();

        uint256 prin;
        (,,,,,,,,,, prin) = pot.getMkt(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        vm.prank(appellant);
        module.startUmaAppeal(id);

        (string memory desc,,,, uint64 resTime,,,,,,) = pot.getMkt(id);
        bytes memory ancillary = _appealAncillary(id, desc, resTime, 2, 1, 2, 2);

        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(1));

        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(usdc.transferFrom.selector, address(pot), reporter),
            "blacklisted"
        );

        uint256 reporterPendingBefore = pot.pendingWithdrawals(reporter);
        uint256 treasuryPendingBefore = pot.pendingWithdrawals(treasury);
        uint256 appellantPendingBefore = pot.pendingWithdrawals(appellant);

        module.settleUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, 1, "UMA winner not applied");
        assertEq(status, 2, "market not resolved");
        assertGt(pot.pendingWithdrawals(reporter), reporterPendingBefore, "reporter not credited");
        assertGt(pot.pendingWithdrawals(appellant), appellantPendingBefore, "appellant pending credit did not increase");
        assertGt(pot.pendingWithdrawals(treasury), treasuryPendingBefore, "treasury rake not credited");
        assertEq(usdc.balanceOf(appellant), 10_000_000e6 - appealBond, "appellant wallet balance changed unexpectedly");
    }

    /// @notice withdrawPending emits PendingWithdrawn event.
    function test_withdrawPending_emitsEvent() public {
        (uint256 id,,) = _resolvedMarket();

        // Trigger claim so treasury gets credited
        vm.prank(alice);
        pot.claim(id, 0, 0);

        uint256 pending = pot.pendingWithdrawals(treasury);
        assertGt(pending, 0);

        vm.prank(treasury);
        vm.expectEmit(true, false, false, true, address(pot));
        emit PendingWithdrawn(treasury, pending);
        pot.withdrawPending();

        assertEq(pot.pendingWithdrawals(treasury), 0, "pending not cleared");
        assertGe(usdc.balanceOf(treasury), pending, "balance less than pending after withdraw");
    }

    /// @notice withdrawPending reverts with E1 when nothing is pending.
    function test_withdrawPending_revertsOnZero() public {
        assertEq(pot.pendingWithdrawals(alice), 0);
        vm.prank(alice);
        vm.expectRevert(yPot.E1.selector);
        pot.withdrawPending();
    }

    /// @notice Multiple credits accumulate and can be withdrawn at once.
    function test_withdrawPending_multipleAccumulations() public {
        // Create two resolved markets so treasury gets credited twice
        (uint256 id1,,) = _resolvedMarket();

        // Reset timestamp and create second market
        (uint256 id2,,) = _resolvedMarket2();

        // Both claims credit treasury
        vm.prank(alice);
        pot.claim(id1, 0, 0);
        uint256 pendingAfterFirst = pot.pendingWithdrawals(treasury);
        assertGt(pendingAfterFirst, 0);

        vm.prank(alice);
        pot.claim(id2, 0, 0);
        uint256 pendingAfterSecond = pot.pendingWithdrawals(treasury);
        assertGt(pendingAfterSecond, pendingAfterFirst, "second claim didn't accumulate");

        // Single withdrawal gets everything
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(treasury);
        pot.withdrawPending();
        assertEq(pot.pendingWithdrawals(treasury), 0, "not fully cleared");
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, pendingAfterSecond, "didn't get full accumulated amount");
    }

    // =====================================================================
    // FIX 2: UMA Module Revocation
    // =====================================================================

    /// @notice revokeUmaModule clears approval and address.
    function test_revokeUmaModule_clearsApproval() public {
        address moduleBefore = address(module);
        assertEq(pot.umaModule(), moduleBefore);

        // Revoke
        pot.revokeUmaModule();

        assertEq(pot.umaModule(), address(0), "module not cleared");
        assertEq(usdc.allowance(address(pot), moduleBefore), 0, "approval not revoked");
    }

    /// @notice revokeUmaModule blocked while a market is in UMA_PENDING.
    function test_revokeUmaModule_blockedDuringPending() public {
        (uint256 id,,) = _appealableMarket();

        // Start UMA appeal → moves market to ST_UMA_PENDING
        _mintApprove(alice, 10_000_000e6);
        vm.prank(alice);
        usdc.approve(address(module), type(uint256).max);
        vm.prank(alice);
        module.startUmaAppeal(id);

        // umaActiveCount should be 1
        assertEq(pot.umaActiveCount(), 1, "umaActiveCount not incremented");

        // Revoke should fail
        vm.expectRevert(yPot.E2.selector);
        pot.revokeUmaModule();
    }

    /// @notice revokeUmaModule blocked while a market is in ST_APPEALABLE (appeal window open, no UMA triggered yet).
    function test_revokeUmaModule_blockedDuringAppealable() public {
        (uint256 id,,) = _appealableMarket();

        // Market is in ST_APPEALABLE, umaAppealableCount should be 1
        assertEq(pot.umaAppealableCount(), 1, "umaAppealableCount not incremented");

        // Revoke should fail during APPEALABLE
        vm.expectRevert(yPot.E2.selector);
        pot.revokeUmaModule();
    }

    /// @notice revokeUmaModule succeeds after ST_APPEALABLE market ages out without UMA appeal.
    function test_revokeUmaModule_succeeds_after_appealable_times_out() public {
        (uint256 id,,) = _appealableMarket();

        // Warp past appeal deadline + DISPUTE_PERIOD so finalize() can complete both phases
        (uint64 appealDeadline,,,) = pot.getAppealInfo(id);
        vm.warp(uint256(appealDeadline) + DISPUTE_PERIOD + 1);
        pot.finalize(id);

        // umaAppealableCount should be back to 0
        assertEq(pot.umaAppealableCount(), 0, "umaAppealableCount should be 0 after finalize");

        // Revoke should now succeed
        pot.revokeUmaModule();
        assertEq(pot.umaModule(), address(0), "module not cleared");
    }

    /// @notice setUmaModule works again after revoke.
    function test_setUmaModule_replacesAfterRevoke() public {
        pot.revokeUmaModule();
        assertEq(pot.umaModule(), address(0));

        // Deploy new module
        yPotUma newModule = new yPotUma(address(pot), address(adapter));
        pot.setUmaModule(address(newModule));
        assertEq(pot.umaModule(), address(newModule), "new module not set");
    }

    // =====================================================================
    // FIX 3: Oracle Vote Revocation
    // =====================================================================

    /// @notice Revoking a removed oracle's vote decrements the vote count.
    function test_revokeOracleVote_decrementsCount() public {
        (uint256 id,,) = _disputedMarket_oneVote();

        // oracle0 voted outcome 1. Market is still REPORTED (1 of 2 votes, no quorum).
        (,,,,,,,, uint8 statusBefore,,) = pot.getMkt(id);
        assertEq(statusBefore, 5, "should be REPORTED");

        // Add oracle2 so we can remove oracle0 without going below confirms threshold
        address oracle2 = address(0x5555);
        pot.setOracle(oracle2, true);

        // Remove oracle0 and revoke vote
        pot.setOracle(oracle0, false);
        pot.revokeOracleVote(id, oracle0);

        // Re-add oracle0 and have it vote again — should NOT reach quorum alone
        // (proves the original vote was actually decremented)
        pot.setOracle(oracle0, true);
        vm.prank(oracle0);
        pot.resolveDispute(id, 1);

        // Market should still be REPORTED (1 vote, quorum=2)
        (,,,,,,,, uint8 statusAfter,,) = pot.getMkt(id);
        assertEq(statusAfter, 5, "should still be REPORTED after re-vote");
    }

    /// @notice revokeOracleVote blocked if oracle is still active.
    function test_revokeOracleVote_blockedIfOracleStillActive() public {
        (uint256 id,,) = _disputedMarket_oneVote();

        // oracle0 is still active — revoke should fail with E3
        vm.expectRevert(yPot.E3.selector);
        pot.revokeOracleVote(id, oracle0);
    }

    /// @notice revokeOracleVote blocked if oracle hasn't voted.
    function test_revokeOracleVote_blockedIfNotVoted() public {
        (uint256 id,,) = _disputedMarket_oneVote();

        // Add oracle2 so we can remove oracle1 without going below confirms threshold
        address oracle2 = address(0x5555);
        pot.setOracle(oracle2, true);

        // oracle1 hasn't voted — remove oracle1 first
        pot.setOracle(oracle1, false);

        vm.expectRevert(yPot.E1.selector);
        pot.revokeOracleVote(id, oracle1);
    }

    /// @notice revokeOracleVote blocked if market is not in REPORTED state.
    function test_revokeOracleVote_blockedIfNotReported() public {
        (uint256 id,,) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100_000e6);

        // Add oracle2 so we can remove oracle0 without going below confirms threshold
        address oracle2 = address(0x5555);
        pot.setOracle(oracle2, true);

        // Market is still OPEN — try revoking (should fail)
        pot.setOracle(oracle0, false);
        vm.expectRevert(yPot.E2.selector);
        pot.revokeOracleVote(id, oracle0);
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _mintApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }

    function _mintApproveModule(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(module), type(uint256).max);
    }

    function _bet(address who, uint256 id, uint8 outcome, uint256 amount) internal {
        vm.prank(who);
        pot.bet(id, outcome, amount, 0, block.timestamp + 1);
    }

    function _create2OutcomeMarket() internal returns (uint256 id, uint64 dl, uint64 rt) {
        dl = uint64(block.timestamp + 14 days + 1);
        rt = uint64(uint256(dl) + 2 hours);
        vm.prank(creator);
        id = pot.create("sec fix test", "bafySec", dl, rt, 2, "", address(0));
    }

    function _simulateYield(uint256 yieldBps) internal {
        uint256 currentRate = yearn.exchangeRate();
        uint256 newRate = Math.mulDiv(currentRate, BPS + yieldBps, BPS);
        yearn.setExchangeRate(newRate);
        uint256 vaultBal = usdc.balanceOf(address(yearn));
        uint256 newBal = Math.mulDiv(vaultBal, BPS + yieldBps, BPS);
        if (newBal > vaultBal) {
            usdc.mint(address(yearn), newBal - vaultBal);
        }
    }

    /// @dev Creates a fully resolved (CLAIMABLE) market. Alice bet on outcome 1, Bob on outcome 2.
    /// Reporter reported outcome 1. Alice confirmed. Outcome 1 wins.
    function _resolvedMarket() internal returns (uint256 id, uint64 dl, uint64 rt) {
        (id, dl, rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100_000e6);
        _bet(bob, id, 2, 50_000e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(alice);
        pot.confirmReport(id, 50_000e6, 0, block.timestamp + 1);

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        vm.warp(block.timestamp + DISPUTE_PERIOD + 1);
        pot.finalize(id);

        _simulateYield(500); // 5% yield
    }

    /// @dev Second resolved market for accumulation test (different deadline offset).
    function _resolvedMarket2() internal returns (uint256 id, uint64 dl, uint64 rt) {
        dl = uint64(block.timestamp + 14 days + 1);
        rt = uint64(uint256(dl) + 2 hours);
        vm.prank(creator);
        id = pot.create("sec fix test 2", "bafySec2", dl, rt, 2, "", address(0));

        _bet(alice, id, 1, 80_000e6);
        _bet(bob, id, 2, 40_000e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(alice);
        pot.confirmReport(id, 40_000e6, 0, block.timestamp + 1);

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        vm.warp(block.timestamp + DISPUTE_PERIOD + 1);
        pot.finalize(id);

        _simulateYield(300); // 3% yield
    }

    /// @dev Market with a challenge filed. Reporter: outcome 1, challenger: outcome 2.
    function _challengedMarket() internal returns (uint256 id, uint64 dl, uint64 rt) {
        (id, dl, rt) = _create2OutcomeMarket();

        _bet(alice, id, 1, 100_000e6);
        _bet(bob, id, 2, 50_000e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(challenger);
        pot.challenge(id, 2);
    }

    /// @dev Market in APPEALABLE state (committee resolved, appeal window open).
    function _appealableMarket() internal returns (uint256 id, uint64 dl, uint64 rt) {
        (id, dl, rt) = _challengedMarket();

        vm.prank(oracle0);
        pot.resolveDispute(id, 2);
        vm.prank(oracle1);
        pot.resolveDispute(id, 2);

        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, 7, "not APPEALABLE");
    }

    /// @dev Market in REPORTED state with one oracle vote (oracle0 voted outcome 1).
    function _disputedMarket_oneVote() internal returns (uint256 id, uint64 dl, uint64 rt) {
        (id, dl, rt) = _challengedMarket();

        // Only oracle0 votes (1 of 2 needed for quorum)
        vm.prank(oracle0);
        pot.resolveDispute(id, 1);
    }

    function _appealAncillary(
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
