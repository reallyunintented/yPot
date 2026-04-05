// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {PreviewFaucet} from "../src/PreviewFaucet.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PreviewFaucetTest is Test {
    MockUSDC internal usdc;
    PreviewFaucet internal faucet;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant CLAIM_AMOUNT = 10_000e6;
    uint256 internal constant CLAIM_COOLDOWN = 1 hours;

    function setUp() public {
        usdc = new MockUSDC();
        faucet = new PreviewFaucet(address(usdc), address(this), CLAIM_AMOUNT, CLAIM_COOLDOWN);
        usdc.mint(address(faucet), 1_000_000e6);
    }

    function testClaimTransfersTokensAndStartsCooldown() public {
        vm.prank(ALICE);
        faucet.claim();

        assertEq(usdc.balanceOf(ALICE), CLAIM_AMOUNT);
        assertEq(faucet.nextClaimAt(ALICE), block.timestamp + CLAIM_COOLDOWN);
    }

    function testClaimRevertsDuringCooldown() public {
        vm.prank(ALICE);
        faucet.claim();

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PreviewFaucet.CooldownActive.selector, block.timestamp + CLAIM_COOLDOWN));
        faucet.claim();
    }

    function testClaimWorksAgainAfterCooldown() public {
        vm.prank(ALICE);
        faucet.claim();

        vm.warp(block.timestamp + CLAIM_COOLDOWN);

        vm.prank(ALICE);
        faucet.claim();

        assertEq(usdc.balanceOf(ALICE), CLAIM_AMOUNT * 2);
    }

    function testOwnerCanUpdateConfigAndDrain() public {
        faucet.setClaimAmount(25_000e6);
        faucet.setClaimCooldown(3 hours);
        faucet.drain(BOB, 50_000e6);

        assertEq(faucet.claimAmount(), 25_000e6);
        assertEq(faucet.claimCooldown(), 3 hours);
        assertEq(usdc.balanceOf(BOB), 50_000e6);
    }

    function testClaimRevertsWhenFaucetIsEmpty() public {
        faucet.drain(address(this), usdc.balanceOf(address(faucet)));

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PreviewFaucet.InsufficientLiquidity.selector, 0, CLAIM_AMOUNT));
        faucet.claim();
    }
}
