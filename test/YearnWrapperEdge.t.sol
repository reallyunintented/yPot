// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {YearnWrapper} from "src/YearnWrapper.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

contract YearnWrapperEdgeTest is Test {
    MockUSDC internal usdc;
    MockERC4626Vault internal yearnVault;
    YearnWrapper internal wrapper;
    MockUSDC internal otherToken;

    address internal depositor = address(0xD3D0);
    address internal outsider = address(0x0A75);
    address internal receiver = address(0xBEEF);

    function setUp() public {
        usdc = new MockUSDC();
        yearnVault = new MockERC4626Vault(usdc);
        otherToken = new MockUSDC();

        address[] memory initialDepositors = new address[](1);
        initialDepositors[0] = address(this);
        wrapper = new YearnWrapper(usdc, yearnVault, initialDepositors);

        wrapper.setDepositor(depositor, true);

        usdc.mint(depositor, 1_000_000e6);
        vm.prank(depositor);
        usdc.approve(address(wrapper), type(uint256).max);
    }

    function test_renounceOwnership_reverts() public {
        vm.expectRevert(YearnWrapper.RenounceDisabled.selector);
        wrapper.renounceOwnership();
    }

    function test_setSlippage_enforces_bounds() public {
        vm.expectRevert(YearnWrapper.InvalidSlippage.selector);
        wrapper.setSlippage(9_499);

        vm.expectRevert(YearnWrapper.InvalidSlippage.selector);
        wrapper.setSlippage(9_991);

        wrapper.setSlippage(9_950);
        assertEq(wrapper.slippageBps(), 9_950);
    }

    function test_maxDeposit_and_maxMint_respect_auth_and_pause() public {
        wrapper.setDepositor(address(this), false);

        assertEq(wrapper.maxDeposit(outsider), 0);
        assertEq(wrapper.maxMint(outsider), 0);

        assertEq(wrapper.maxDeposit(address(this)), 0);
        assertEq(wrapper.maxMint(address(this)), 0);
        assertGt(wrapper.maxDeposit(depositor), 0);
        assertGt(wrapper.maxMint(depositor), 0);

        wrapper.pause();
        assertEq(wrapper.maxDeposit(depositor), 0);
        assertEq(wrapper.maxMint(depositor), 0);
    }

    function test_deposit_reverts_for_non_depositor() public {
        usdc.mint(outsider, 100e6);
        vm.prank(outsider);
        usdc.approve(address(wrapper), type(uint256).max);

        vm.prank(outsider);
        vm.expectRevert(YearnWrapper.Unauthorized.selector);
        wrapper.deposit(10e6, outsider);
    }

    function test_deposit_reverts_when_yearn_slippage_exceeds_guard() public {
        yearnVault.setDepositSlippageBps(150);

        vm.prank(depositor);
        vm.expectRevert(YearnWrapper.SlippageExceeded.selector);
        wrapper.deposit(100e6, depositor);
    }

    function test_mint_mints_requested_shares_for_authorized_depositor() public {
        uint256 targetAssets = 100e6;
        uint256 shares = wrapper.previewDeposit(targetAssets);
        uint256 quotedAssets = wrapper.previewMint(shares);

        uint256 depositorBefore = usdc.balanceOf(depositor);
        vm.prank(depositor);
        uint256 spentAssets = wrapper.mint(shares, depositor);

        assertEq(spentAssets, quotedAssets);
        assertEq(usdc.balanceOf(depositor), depositorBefore - spentAssets);
        assertEq(wrapper.balanceOf(depositor), shares);
        assertGt(wrapper.yearnShareBalance(), 0);
    }

    function test_setDepositor_reverts_on_zero_address() public {
        vm.expectRevert(YearnWrapper.ZeroAddress.selector);
        wrapper.setDepositor(address(0), true);
    }

    function test_rescue_rejects_asset_and_yearn_share_and_allows_other_token() public {
        vm.expectRevert(YearnWrapper.Unauthorized.selector);
        wrapper.rescue(IERC20(address(usdc)), receiver, 1);

        vm.expectRevert(YearnWrapper.Unauthorized.selector);
        wrapper.rescue(IERC20(address(yearnVault)), receiver, 1);

        otherToken.mint(address(wrapper), 55e6);
        wrapper.rescue(IERC20(address(otherToken)), receiver, 55e6);
        assertEq(otherToken.balanceOf(receiver), 55e6);
    }

    function test_emergencyExitYearn_redeems_to_local_balance() public {
        vm.prank(depositor);
        wrapper.deposit(100e6, depositor);

        uint256 yearnBefore = wrapper.yearnShareBalance();
        assertGt(yearnBefore, 0);

        wrapper.emergencyExitYearn();

        assertEq(wrapper.yearnShareBalance(), 0);
        assertGt(usdc.balanceOf(address(wrapper)), 0);
    }
}
