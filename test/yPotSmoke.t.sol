// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {yPot} from "../src/yPot.sol";
import {YearnWrapper} from "../src/YearnWrapper.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockERC4626Vault} from "./mocks/MockERC4626Vault.sol";

contract yPotSmokeTest is Test {
    MockUSDC internal usdc;
    MockERC4626Vault internal yearnVault;
    YearnWrapper internal wrapper;
    yPot internal pot;

    address internal treasury = address(0xCAFE);
    address internal creator = address(0xA11CE);
    address internal bettor = address(0xB0B);
    address internal reporter = address(0xC0C0A);

    function setUp() public {
        usdc = new MockUSDC();
        yearnVault = new MockERC4626Vault(usdc);

        address[] memory initialDepositors = new address[](1);
        initialDepositors[0] = address(this);
        wrapper = new YearnWrapper(usdc, yearnVault, initialDepositors);

        address[] memory oracles = new address[](2);
        oracles[0] = address(0x1111);
        oracles[1] = address(0x2222);
        pot = new yPot(address(usdc), address(wrapper), treasury, oracles);

        wrapper.setDepositor(address(pot), true);

        usdc.mint(creator, 1_000_000e6);
        usdc.mint(bettor, 1_000_000e6);
        usdc.mint(reporter, 1_000_000e6);

        vm.prank(creator);
        usdc.approve(address(pot), type(uint256).max);
        vm.prank(bettor);
        usdc.approve(address(pot), type(uint256).max);
        vm.prank(reporter);
        usdc.approve(address(pot), type(uint256).max);

        vm.warp(1_700_000_000);
    }

    function test_endToEnd_happyPath_noChallenge() public {
        uint64 nowTs = uint64(block.timestamp);
        uint64 deadline = nowTs + 14 days + 1;
        uint64 resTime = deadline + 1 hours;

        vm.prank(creator);
        uint256 id = pot.create("Smoke Test Market", "bafySmokeTest", deadline, resTime, 2, "", address(0));
        assertEq(id, 1);

        uint64 betTs = nowTs + 30 minutes;
        vm.warp(betTs);
        vm.prank(bettor);
        pot.bet(id, 1, 100e6, 0, betTs + 60);

        vm.warp(deadline + 1);
        pot.close(id);

        vm.warp(resTime);
        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(bettor);
        pot.confirmReport(id, 25e6, 0, resTime + 60);

        uint64 acceptTs = resTime + 48 hours + 1;
        vm.warp(acceptTs);
        pot.acceptReport(id);

        vm.warp(acceptTs + 24 hours + 1);
        pot.finalize(id);

        uint256 bettorBalBefore = usdc.balanceOf(bettor);

        vm.prank(bettor);
        pot.withdrawConfirmBond(id, 0, 0);

        vm.prank(bettor);
        pot.claim(id, 0, 0);

        uint256 bettorBalAfter = usdc.balanceOf(bettor);
        assertGt(bettorBalAfter, bettorBalBefore);
    }
}
