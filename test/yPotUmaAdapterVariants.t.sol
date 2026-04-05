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
import {MockUmaOptimisticOracleVariantB} from "test/mocks/MockUmaOptimisticOracleVariantB.sol";

/**
 * @notice Variant B fallback path tests for UmaOptimisticOracleAdapter.
 * @dev Uses MockUmaOptimisticOracleVariantB which rejects Variant A ABI calls and only
 *      accepts Variant B (proposePriceFor / disputePriceFor / settle(address,...)).
 *      Proves the adapter's silent A→B fallback chain works end-to-end for all
 *      appeal exit branches.
 */
contract yPotUmaAdapterVariantsTest is Test {
    uint8 private constant ST_UMA_PENDING = 8;
    uint8 private constant ST_RESOLVED = 2;
    uint8 private constant ST_CANCELLED = 4;
    uint8 private constant ST_APPEALABLE = 7;

    uint256 private constant BPS = 10_000;
    bytes32 private constant IDENTIFIER = keccak256("YPOT_LOCAL");
    uint256 private constant UMA_STALE_TIMEOUT = 30 days;

    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    MockUmaOptimisticOracleVariantB internal mockUmaB;
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

        mockUmaB = new MockUmaOptimisticOracleVariantB();
        address[] memory requesters = new address[](1);
        requesters[0] = address(this);
        adapter = new UmaOptimisticOracleAdapter(address(mockUmaB), usdc, IDENTIFIER, 0, 0, 0, requesters);

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

    // -------------------------------------------------------------------------
    // Variant B fallback tests
    // -------------------------------------------------------------------------

    /// @notice Variant B: UMA returns winner != committeeWinner → market overturned.
    function test_variantB_appeal_overturns_committee() public {
        (uint256 id, string memory desc, uint64 resTime,,) = _setupAppealableMarket();

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_UMA_PENDING, "should be UMA_PENDING after startUmaAppeal");

        // Committee winner = 2. Simulate UMA DVM resolving to 1 (overturns committee).
        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUmaB.proposePriceFor(address(0), IDENTIFIER, uint256(resTime), ancillary, int256(1));

        module.settleUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 statusAfter,,) = pot.getMkt(id);
        assertEq(winner, 1, "winner should be 1 (overturns committee winner 2)");
        assertEq(statusAfter, ST_RESOLVED);
        assertEq(_receivable(appellant), appellantBefore, "appellant receivable should be restored on overturn");
    }

    /// @notice Variant B: UMA returns winner == committeeWinner → committee affirmed.
    function test_variantB_appeal_affirms_committee() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        uint256 treasuryBefore = _receivable(treasury);

        vm.prank(appellant);
        module.startUmaAppeal(id);

        // Committee winner = 2. Simulate UMA confirming outcome 2.
        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUmaB.setPayout(IDENTIFIER, uint256(resTime), ancillary, rb * 2);
        mockUmaB.proposePriceFor(address(0), IDENTIFIER, uint256(resTime), ancillary, int256(2));

        module.settleUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 statusAfter,,) = pot.getMkt(id);
        assertEq(winner, 2, "winner should be 2 (affirms committee)");
        assertEq(statusAfter, ST_RESOLVED);
        assertEq(_receivable(appellant), appellantBefore - appealBond, "appellant receivable should lose the bond on affirm");

        uint256 rake = _disputeRake(rb, rb * 2);
        assertGe(_receivable(treasury) - treasuryBefore, appealBond, "treasury receivable should include at least the appeal bond");
        assertGe(_receivable(treasury) - treasuryBefore, appealBond + rake, "treasury receivable should include appeal bond plus rake");
    }

    /// @notice Variant B: oracle unreachable after 30d → expireUmaAppeal falls back to committee winner.
    function test_variantB_appeal_expiredOracle_fallsToCommittee() public {
        (uint256 id,,,,) = _setupAppealableMarket();

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        // Simulate the oracle becoming unreachable (settle always reverts).
        mockUmaB.setRevertOnSettle(true);

        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        vm.warp(uint256(umaStartedAt) + UMA_STALE_TIMEOUT + 1);

        module.expireUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 statusAfter,,) = pot.getMkt(id);
        assertEq(winner, 2, "committee winner should prevail when oracle is unreachable");
        assertEq(statusAfter, ST_RESOLVED);
        assertEq(_receivable(appellant), appellantBefore, "appellant receivable should be restored when oracle expiry falls back");
    }

    /// @notice Variant B: UMA returns price=0 (invalid) → market cancelled, bonds refunded half-half.
    function test_variantB_invalidPrice_cancelsMarket() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 appellantBefore = _receivable(appellant);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);

        vm.prank(appellant);
        module.startUmaAppeal(id);

        // Simulate UMA returning an invalid price (0 = not a valid outcome).
        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUmaB.proposePriceFor(address(0), IDENTIFIER, uint256(resTime), ancillary, int256(0));

        module.settleUmaAppeal(id);

        (,,,,,,,, uint8 statusAfter,,) = pot.getMkt(id);
        assertEq(statusAfter, ST_CANCELLED, "invalid UMA price should cancel market");

        assertEq(_receivable(appellant), appellantBefore, "appellant receivable should be restored on cancel");

        uint256 recovered = rb * 2;
        uint256 half = recovered >> 1;
        assertEq(_receivable(reporter) - reporterBefore, half, "reporter gets half of recovered bonds");
        assertEq(_receivable(challenger) - challengerBefore, recovered - half, "challenger gets other half");
    }

    // -------------------------------------------------------------------------
    // Helpers (mirrored from yPotUmaAppeal.t.sol)
    // -------------------------------------------------------------------------

    function _disputeRake(uint256 loserBond, uint256 recovered) internal view returns (uint256 rake) {
        rake = (loserBond * pot.disputeRakeBps()) / BPS;
        if (rake > recovered) rake = recovered;
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
        assertEq(status, ST_APPEALABLE, "market should be in APPEALABLE state");

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
