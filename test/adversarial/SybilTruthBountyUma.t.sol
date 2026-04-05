// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {yPot} from "../../src/yPot.sol";
import {YearnWrapper} from "../../src/YearnWrapper.sol";
import {yPotUma} from "../../src/yPotUma.sol";
import {UmaOptimisticOracleAdapter} from "../../src/UmaOptimisticOracleAdapter.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {MockUmaOptimisticOracle} from "../mocks/MockUmaOptimisticOracle.sol";

contract SybilTruthBountyUmaTest is Test {
    uint8 private constant ST_RESOLVED = 2;
    uint256 private constant DISPUTE_PERIOD = 24 hours;
    uint256 private constant BPS = 10_000;
    bytes32 private constant IDENTIFIER = keccak256("YPOT_LOCAL");

    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    MockUmaOptimisticOracle internal mockUma;
    UmaOptimisticOracleAdapter internal adapter;
    yPotUma internal module;

    address internal treasury = address(0xBEEFCAFE);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);

    address internal creator = address(0xC0FFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    address internal attackerReporter = address(0xDEAD);
    address internal attackerChallenger = address(0xBEEF);
    address internal attackerAppellant = address(0xFEED);

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
        _mintApprovePot(attackerReporter, 1_000_000e6);
        _mintApprovePot(attackerChallenger, 1_000_000e6);
        _mintApproveModule(attackerAppellant, 1_000_000e6);
    }

    function test_sybilSelfDispute_viaUma_overturn_isStillNegative() public {
        int256 profit = _runSybilUmaFlow(1);
        assertEq(profit, -3e6, "UMA overturn path should still be negative EV");
    }

    function test_sybilSelfDispute_viaUma_affirm_isEvenMoreNegative() public {
        int256 profit = _runSybilUmaFlow(2);
        assertEq(profit, -53e6, "UMA affirm path should include appeal-bond loss");
    }

    function _runSybilUmaFlow(uint8 umaWinner) internal returns (int256 profit) {
        uint256 before = _attackerCluster();
        (uint256 id, string memory desc, uint64 resTime, uint64 appealDeadline, uint256 rb) = _setupAppealableMarket();

        vm.prank(attackerAppellant);
        module.startUmaAppeal(id);

        bytes memory ancillary = _ancillary(id, desc, resTime, 2, 1, 2, 2);
        mockUma.proposePrice(IDENTIFIER, uint256(resTime), ancillary, int256(uint256(umaWinner)));

        module.settleUmaAppeal(id);

        (,,,,, uint64 resolved,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(winner, umaWinner);
        assertEq(status, ST_RESOLVED);

        vm.warp(uint256(resolved) + DISPUTE_PERIOD + 1);
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
        if (pot.pendingWithdrawals(attackerAppellant) > 0) {
            vm.prank(attackerAppellant);
            pot.withdrawPending();
        }

        uint256 after_ = _attackerCluster();

        uint256 bond = pot.calcReportBond(id);
        uint256 rake = (bond * pot.disputeRakeBps()) / BPS;
        uint256 bounty = (pot.fee() * 2000) / BPS;
        assertEq(rake, 5e6);
        assertEq(bounty, 2e6);
        assertEq(appealDeadline > 0, true);
        assertEq(rb, bond);

        if (after_ >= before) {
            profit = SafeCast.toInt256(after_ - before);
        } else {
            profit = -SafeCast.toInt256(before - after_);
        }
    }

    function _setupAppealableMarket()
        internal
        returns (uint256 id, string memory desc, uint64 resTime, uint64 appealDeadline, uint256 reportBond)
    {
        uint64 deadline = uint64(block.timestamp + 14 days + 1);
        uint64 resolutionTime = uint64(uint256(deadline) + 2 hours);

        vm.prank(creator);
        id = pot.create("sybil uma market", "bafySybilUma", deadline, resolutionTime, 2, "", address(0));

        vm.prank(alice);
        pot.bet(id, 1, 100e6, 0, block.timestamp + 1);

        vm.prank(bob);
        pot.bet(id, 2, 100e6, 0, block.timestamp + 1);

        vm.warp(uint256(deadline) + 1);
        pot.close(id);

        vm.warp(uint256(resolutionTime));
        vm.prank(attackerReporter);
        pot.report(id, 1);

        vm.prank(attackerChallenger);
        pot.challenge(id, 2);

        vm.prank(oracle0);
        pot.resolveDispute(id, 2);
        vm.prank(oracle1);
        pot.resolveDispute(id, 2);

        (desc,,,, resTime,,,,,,) = pot.getMkt(id);
        (appealDeadline,,,) = pot.getAppealInfo(id);
        uint256 cb;
        (,, reportBond,,,,, cb) = pot.getReport(id);
        assertEq(reportBond, cb);
    }

    function _attackerCluster() internal view returns (uint256) {
        return usdc.balanceOf(attackerReporter) + usdc.balanceOf(attackerChallenger) + usdc.balanceOf(attackerAppellant);
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
            vm.toString(id),
            " on chain ",
            vm.toString(block.chainid),
            " | Resolution timestamp: ",
            vm.toString(uint256(resTime)),
            ": ",
            desc,
            " | Committee winner: ",
            vm.toString(uint256(committeeWinner)),
            " | Reported outcome: ",
            vm.toString(uint256(reportedOutcome)),
            " | Challenged outcome: ",
            vm.toString(uint256(challengedOutcome)),
            " | Valid outcomes: 1-",
            vm.toString(uint256(outcomes)),
            " | Return the winning outcome number."
        );
    }
}
