// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";
import {yPotUma} from "src/yPotUma.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";
import {MockUmaBestEffortAdapter} from "test/mocks/MockUmaBestEffortAdapter.sol";

contract yPotUmaBestEffortTest is Test {
    uint8 private constant ST_APPEALABLE = 7;
    uint8 private constant ST_RESOLVED = 2;

    uint256 private constant BPS = 10_000;
    uint256 private constant UMA_STALE_TIMEOUT = 30 days;

    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    MockUmaBestEffortAdapter internal adapter;
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

        adapter = new MockUmaBestEffortAdapter(usdc);
        module = new yPotUma(address(pot), address(adapter));
        pot.setUmaModule(address(module));

        _mintApprovePot(creator, 1_000_000e6);
        _mintApprovePot(alice, 1_000_000e6);
        _mintApprovePot(bob, 1_000_000e6);
        _mintApprovePot(reporter, 1_000_000e6);
        _mintApprovePot(challenger, 1_000_000e6);
        _mintApproveModule(appellant, 1_000_000e6);
    }

    function test_expireUmaAppeal_bestEffort_settleValid_withdrawReverts_still_resolvesUmaWinner() public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        adapter.setBehavior(uint256(resTime), ancillary, int256(1), rb * 2, false, true);

        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        vm.warp(uint256(umaStartedAt) + UMA_STALE_TIMEOUT + 1);

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);

        module.expireUmaAppeal(id);

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, 1);
        assertEq(status, ST_RESOLVED);

        assertEq(_receivable(appellant), appellantBefore);
        assertEq(_receivable(treasury), treasuryBefore);
        assertEq(_receivable(reporter), reporterBefore);
        assertEq(_receivable(challenger), challengerBefore);
        assertEq(appealBond, module.calcUmaAppealBond(prin));
    }

    function test_expireUmaAppeal_bestEffort_settleReverts_withdrawSucceeds_refundsRecoveredHalfHalf_and_resolvesCommittee()
        public
    {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        uint256 recovered = rb * 2 - 1;
        adapter.setBehavior(uint256(resTime), ancillary, int256(1), recovered, true, false);

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
        assertEq(_receivable(treasury), treasuryBefore);

        uint256 half = recovered >> 1;
        assertEq(_receivable(reporter) - reporterBefore, half);
        assertEq(_receivable(challenger) - challengerBefore, recovered - half);
    }

    function test_expireUmaAppeal_bestEffort_settleInvalid_withdrawSucceeds_refundsRecoveredHalfHalf_and_resolvesCommittee()
        public
    {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        uint256 recovered = rb * 2 - 1;
        adapter.setBehavior(uint256(resTime), ancillary, int256(3), recovered, false, false);

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
        assertEq(_receivable(treasury), treasuryBefore);

        uint256 half = recovered >> 1;
        assertEq(_receivable(reporter) - reporterBefore, half);
        assertEq(_receivable(challenger) - challengerBefore, recovered - half);
    }

    function testFuzz_expireUmaAppeal_bestEffort_properties(
        uint256 recoveredRaw,
        uint8 umaWinnerRaw,
        bool settleReverts,
        bool withdrawReverts,
        bool validPrice
    ) public {
        (uint256 id, string memory desc, uint64 resTime,, uint256 rb) = _setupAppealableMarket();

        uint256 prin = _principal(id);
        uint256 appealBond = module.calcUmaAppealBond(prin);

        uint256 appellantBefore = _receivable(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);

        uint8 umaWinner = uint8(bound(uint256(umaWinnerRaw), 1, 2));
        int256 price = validPrice ? int256(uint256(umaWinner)) : (umaWinnerRaw % 2 == 0 ? int256(0) : int256(3));

        uint256 recovered = bound(recoveredRaw, 0, rb * 2);
        adapter.setBehavior(uint256(resTime), ancillary, price, recovered, settleReverts, withdrawReverts);

        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        vm.warp(uint256(umaStartedAt) + UMA_STALE_TIMEOUT + 1);

        uint256 treasuryBefore = _receivable(treasury);
        uint256 reporterBefore = _receivable(reporter);
        uint256 challengerBefore = _receivable(challenger);

        module.expireUmaAppeal(id);

        bool applyUma = (!settleReverts && validPrice);
        uint8 expectedWinner = applyUma ? umaWinner : 2;

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, expectedWinner);
        assertEq(status, ST_RESOLVED);

        uint256 recoveredApplied = withdrawReverts ? 0 : recovered;

        if (applyUma) {
            if (umaWinner == 2) {
                assertEq(_receivable(appellant), appellantBefore - appealBond);
                assertEq(_receivable(treasury) - treasuryBefore, appealBond + _disputeRake(rb, recoveredApplied));
            } else {
                assertEq(_receivable(appellant), appellantBefore);
                assertEq(_receivable(treasury) - treasuryBefore, _disputeRake(rb, recoveredApplied));
            }

            uint256 expectedReporter = umaWinner == 1 ? recoveredApplied - _disputeRake(rb, recoveredApplied) : 0;
            assertEq(_receivable(reporter) - reporterBefore, expectedReporter);

            uint256 expectedChallenger = umaWinner == 2 ? recoveredApplied - _disputeRake(rb, recoveredApplied) : 0;
            assertEq(_receivable(challenger) - challengerBefore, expectedChallenger);
        } else {
            assertEq(_receivable(appellant), appellantBefore);
            assertEq(_receivable(treasury), treasuryBefore);

            uint256 half = recoveredApplied >> 1;
            assertEq(_receivable(reporter) - reporterBefore, half);
            assertEq(_receivable(challenger) - challengerBefore, recoveredApplied - half);
        }

        assertEq(appealBond, module.calcUmaAppealBond(prin));
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

    function _receivable(address who) internal view returns (uint256) {
        return usdc.balanceOf(who) + pot.pendingWithdrawals(who);
    }

    function _setupAppealableMarket()
        internal
        returns (uint256 id, string memory desc, uint64 resTime, uint64 appealDeadline, uint256 reportBond)
    {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        id = pot.create("UMA appeal market", "bafyUmaBestEffort", dl, rt, 2, "", address(0));

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
