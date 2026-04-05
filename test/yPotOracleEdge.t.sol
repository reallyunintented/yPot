// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

contract yPotOracleEdgeTest is Test {
    uint8 private constant ST_REPORTED = 5;
    uint8 private constant ST_APPEALABLE = 7;

    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    address internal treasury = address(0xBEEF);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);
    address internal oracle2 = address(0x3333);

    address internal creator = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal reporter = address(0xD00D);
    address internal challenger = address(0xC0C0A);

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

        // Add a third oracle for removal/quorum edge cases.
        pot.setOracle(oracle2, true);

        _mintApprove(creator, 1_000_000e6);
        _mintApprove(alice, 1_000_000e6);
        _mintApprove(reporter, 1_000_000e6);
        _mintApprove(challenger, 1_000_000e6);
    }

    function test_oracleRemoval_betweenVotes_firstVoteStillCountsTowardQuorum() public {
        (uint256 id,,) = _createChallengedMarket("oracle-removal");

        vm.prank(oracle0);
        pot.resolveDispute(id, 2);

        pot.setOracle(oracle0, false);

        vm.prank(oracle1);
        pot.resolveDispute(id, 2);

        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        assertEq(status, ST_APPEALABLE);
        assertEq(winner, 2);

        vm.prank(oracle0);
        vm.expectRevert(yPot.E3.selector);
        pot.resolveDispute(id, 2);
    }

    function test_oracleVotes_are_scoped_per_market_and_do_not_bleed() public {
        (uint256 id1,,) = _createChallengedMarket("oracle-scope-1");
        (uint256 id2,,) = _createChallengedMarket("oracle-scope-2");

        vm.prank(oracle0);
        pot.resolveDispute(id1, 2);

        vm.prank(oracle0);
        pot.resolveDispute(id2, 2);

        (,,,,,,,, uint8 status1,,) = pot.getMkt(id1);
        (,,,,,,,, uint8 status2,,) = pot.getMkt(id2);
        assertEq(status1, ST_REPORTED);
        assertEq(status2, ST_REPORTED);

        vm.prank(oracle1);
        pot.resolveDispute(id2, 2);

        (,,,,,,,, status1,,) = pot.getMkt(id1);
        (,,,,,,,, status2,,) = pot.getMkt(id2);
        assertEq(status1, ST_REPORTED);
        assertEq(status2, ST_APPEALABLE);

        vm.prank(oracle1);
        pot.resolveDispute(id1, 2);

        (,,,,,,,, status1,,) = pot.getMkt(id1);
        assertEq(status1, ST_APPEALABLE);
    }

    function _createChallengedMarket(string memory desc) internal returns (uint256 id, uint64 dl, uint64 rt) {
        dl = uint64(block.timestamp + 14 days + 1);
        rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        id = pot.create(desc, "bafyOracleEdge", dl, rt, 2, "", address(0));

        vm.prank(alice);
        pot.bet(id, 1, 100e6, 0, block.timestamp + 1);

        vm.warp(uint256(dl) + 1);
        pot.close(id);

        vm.warp(uint256(rt));
        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(challenger);
        pot.challenge(id, 2);
    }

    function _mintApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }
}
