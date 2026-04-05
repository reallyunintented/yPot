// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

contract yPotAdminAccessTest is Test {
    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    address internal treasury = address(0xBEEF);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);
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
    }

    function test_nonOwner_admin_functions_revert() public {
        vm.startPrank(outsider);

        vm.expectRevert();
        pot.setTreasury(address(0xCAFE));

        vm.expectRevert();
        pot.setLimits(1e6, 10e6);

        vm.expectRevert();
        pot.setFee(1e6);

        vm.expectRevert();
        pot.setConfirms(2);

        vm.expectRevert();
        pot.setOracle(address(0xD00D), true);

        vm.expectRevert();
        pot.setConfirmBps(5_000);

        vm.expectRevert();
        pot.setSlippage(9_950);

        vm.expectRevert();
        pot.pause();

        vm.expectRevert();
        pot.unpause();

        vm.expectRevert();
        pot.cancel(1);

        vm.expectRevert();
        pot.rescueEth(payable(address(0x1234)));

        vm.expectRevert();
        pot.setUmaModule(address(0xABCD));

        vm.stopPrank();
    }

    function test_setUmaModule_rejects_zero_and_is_one_shot() public {
        vm.expectRevert(yPot.E1.selector);
        pot.setUmaModule(address(0));

        address moduleA = address(0xABCD);
        address moduleB = address(0xBEEFCAFE);

        pot.setUmaModule(moduleA);
        assertEq(pot.umaModule(), moduleA);

        vm.expectRevert(yPot.E2.selector);
        pot.setUmaModule(moduleB);
    }
}
