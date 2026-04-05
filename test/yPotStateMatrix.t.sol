// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

contract yPotStateMatrixTest is Test {
    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    address internal treasury = address(0xBEEF);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);

    address internal creator = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal reporter = address(0xD00D);
    address internal challenger = address(0xC0C0A);
    address internal outsider = address(0x0A75);

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

        // Keep acceptReport flow simple in this suite.
        pot.setConfirmBps(0);

        _mintApprove(creator, 1_000_000e6);
        _mintApprove(alice, 1_000_000e6);
        _mintApprove(reporter, 1_000_000e6);
        _mintApprove(challenger, 1_000_000e6);
        _mintApprove(outsider, 1_000_000e6);
    }

    function test_stateMatrix_close_reverts_before_deadline_and_on_second_call() public {
        (uint256 id, uint64 dl,) = _create2OutcomeMarket("close-matrix");

        vm.expectRevert(yPot.E2.selector);
        pot.close(id);

        vm.warp(uint256(dl) + 1);
        pot.close(id);

        vm.expectRevert(yPot.E2.selector);
        pot.close(id);
    }

    function test_stateMatrix_bet_reverts_once_market_is_closed_or_reported() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket("bet-matrix");

        _bet(alice, id, 1, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);

        vm.prank(alice);
        vm.expectRevert(yPot.E2.selector);
        pot.bet(id, 1, 100e6, 0, block.timestamp + 1);

        vm.warp(uint256(rt));
        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(alice);
        vm.expectRevert(yPot.E2.selector);
        pot.bet(id, 1, 100e6, 0, block.timestamp + 1);
    }

    function test_stateMatrix_report_reverts_when_not_closed_and_when_already_reported() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket("report-matrix");

        vm.prank(reporter);
        vm.expectRevert(yPot.E2.selector);
        pot.report(id, 1);

        vm.warp(uint256(dl) + 1);
        pot.close(id);

        vm.warp(uint256(rt));
        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(challenger);
        vm.expectRevert(yPot.E2.selector);
        pot.report(id, 2);
    }

    function test_stateMatrix_challenge_reverts_on_invalid_outcomes_and_after_resolution() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket("challenge-matrix");

        _bet(alice, id, 1, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);

        vm.warp(uint256(rt));
        vm.prank(reporter);
        pot.report(id, 1);

        vm.startPrank(challenger);
        vm.expectRevert(yPot.E1.selector);
        pot.challenge(id, 1);

        vm.expectRevert(yPot.E1.selector);
        pot.challenge(id, 0);

        vm.expectRevert(yPot.E1.selector);
        pot.challenge(id, 3);
        vm.stopPrank();

        vm.prank(challenger);
        pot.challenge(id, 2);

        vm.prank(oracle0);
        pot.resolveDispute(id, 2);
        vm.prank(oracle1);
        pot.resolveDispute(id, 2);

        vm.prank(challenger);
        vm.expectRevert(yPot.E2.selector);
        pot.challenge(id, 1);
    }

    function test_stateMatrix_resolveDispute_reverts_for_nonOracle_invalidOutcome_doubleVote_and_afterResolution()
        public
    {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket("resolve-matrix");

        _bet(alice, id, 1, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);

        vm.warp(uint256(rt));
        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(challenger);
        pot.challenge(id, 2);

        vm.prank(outsider);
        vm.expectRevert(yPot.E3.selector);
        pot.resolveDispute(id, 2);

        vm.prank(oracle0);
        vm.expectRevert(yPot.E1.selector);
        pot.resolveDispute(id, 0);

        vm.prank(oracle0);
        vm.expectRevert(yPot.E1.selector);
        pot.resolveDispute(id, 3);

        vm.prank(oracle0);
        pot.resolveDispute(id, 2);

        vm.prank(oracle0);
        vm.expectRevert(yPot.E2.selector);
        pot.resolveDispute(id, 2);

        vm.prank(oracle1);
        pot.resolveDispute(id, 2);

        vm.prank(oracle1);
        vm.expectRevert(yPot.E2.selector);
        pot.resolveDispute(id, 2);
    }

    function test_stateMatrix_acceptReport_reverts_when_market_is_challenged() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket("accept-matrix");

        _bet(alice, id, 1, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);

        vm.warp(uint256(rt));
        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(challenger);
        pot.challenge(id, 2);

        vm.warp(block.timestamp + 48 hours + 1);
        vm.expectRevert(yPot.E2.selector);
        pot.acceptReport(id);
    }

    function test_stateMatrix_finalize_reverts_before_dispute_period_after_acceptReport() public {
        (uint256 id, uint64 dl, uint64 rt) = _create2OutcomeMarket("finalize-matrix");

        _bet(alice, id, 1, 100e6);

        vm.warp(uint256(dl) + 1);
        pot.close(id);

        vm.warp(uint256(rt));
        vm.prank(reporter);
        pot.report(id, 1);

        vm.warp(block.timestamp + 48 hours + 1);
        pot.acceptReport(id);

        vm.expectRevert(yPot.E2.selector);
        pot.finalize(id);
    }

    function _create2OutcomeMarket(string memory desc) internal returns (uint256 id, uint64 dl, uint64 rt) {
        dl = uint64(block.timestamp + 14 days + 1);
        rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        id = pot.create(desc, "bafyStateMatrix", dl, rt, 2, "", address(0));
    }

    function _bet(address who, uint256 id, uint8 outcome, uint256 amount) internal {
        vm.prank(who);
        pot.bet(id, outcome, amount, 0, block.timestamp + 1);
    }

    function _mintApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }
}
