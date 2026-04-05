// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {yPot} from "../../src/yPot.sol";
import {YearnWrapper} from "../../src/YearnWrapper.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {Adversary} from "./Adversary.sol";

/// @notice Relaxed harness that allows time-gated sequences (warp + multiple calls).
/// This is useful for exploring report/confirm/finalize paths without using cheatcodes in Adversary.
contract AdversaryTimeGatedTest is Test {
    MockUSDC internal usdc;
    MockERC4626Vault internal yearnVault;
    YearnWrapper internal wrapper;
    yPot internal pot;
    Adversary internal adversary;

    address internal treasury = address(0xCAFE);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);
    address internal creator = address(0xA11CE);

    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    uint256 internal constant ATTACKER_FUNDING = 500_000e6; // 500k USDC
    uint256 internal constant BETTOR_FUNDING = 1_000_000e6;

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockUSDC();
        yearnVault = new MockERC4626Vault(usdc);

        address[] memory depositors = new address[](1);
        depositors[0] = address(this);
        wrapper = new YearnWrapper(usdc, yearnVault, depositors);

        address[] memory oracles = new address[](2);
        oracles[0] = oracle0;
        oracles[1] = oracle1;
        pot = new yPot(address(usdc), address(wrapper), treasury, oracles);
        wrapper.setDepositor(address(pot), true);

        adversary = new Adversary(address(pot), address(usdc), address(wrapper));

        _fund(creator, BETTOR_FUNDING);
        _fund(alice, BETTOR_FUNDING);
        _fund(bob, BETTOR_FUNDING);
        _fund(address(adversary), ATTACKER_FUNDING);

        _approve(creator);
        _approve(alice);
        _approve(bob);
    }

    function test_adversary_time_gated_can_profit() public {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 30 minutes;

        vm.prank(creator);
        uint256 id = pot.create("Time-Gated Market", "bafyTime", deadline, resTime, 2, "", address(0));

        // Seed bets from innocents.
        vm.prank(alice);
        pot.bet(id, 1, 10_000e6, 0, block.timestamp + 60);

        vm.prank(bob);
        pot.bet(id, 2, 20_000e6, 0, block.timestamp + 60);

        // Configure adversary: bet on outcome 2 and later report/confirm that outcome.
        adversary.configureAttack(id, 2, 100_000e6);

        uint256 balanceBefore = usdc.balanceOf(address(adversary));
        console2.log("Adversary USDC before:", balanceBefore);

        // Step 0: bet while open.
        vm.warp(now_ + 1 minutes);
        adversary.executeAttack();
        assertEq(adversary.step(), 1);

        // Step 1: close + report once resolution time is reached.
        vm.warp(resTime);
        adversary.executeAttack();
        assertEq(adversary.step(), 2);

        // Step 2: confirm until threshold met.
        adversary.executeAttack();
        assertEq(adversary.step(), 3);

        // Step 3: accept after challenge window.
        vm.warp(resTime + 48 hours + 1);
        adversary.executeAttack();
        assertEq(adversary.step(), 4);

        // Step 4: finalize after dispute period.
        vm.warp(resTime + 48 hours + 24 hours + 2);
        adversary.executeAttack();
        assertEq(adversary.step(), 5);

        // Simulate yield, then claim.
        _simulateYield(1000); // 10% yield
        adversary.executeAttack();
        assertEq(adversary.step(), 6);

        // Pull-based: withdraw pending bond/bounty credits
        if (pot.pendingWithdrawals(address(adversary)) > 0) {
            vm.prank(address(adversary));
            pot.withdrawPending();
        }

        uint256 balanceAfter = usdc.balanceOf(address(adversary));
        console2.log("Adversary USDC after: ", balanceAfter);

        assertGt(balanceAfter, balanceBefore, "expected adversary profit");
    }

    function test_false_report_is_challenged_and_attacker_cannot_profit() public {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 30 minutes;

        vm.prank(creator);
        uint256 id = pot.create("Challenged Market", "bafyChallenged", deadline, resTime, 2, "", address(0));

        // "Truth" in this test is outcome 1. Adversary will try to report outcome 2.
        vm.prank(alice);
        pot.bet(id, 1, 50_000e6, 0, block.timestamp + 60);

        vm.prank(bob);
        pot.bet(id, 1, 30_000e6, 0, block.timestamp + 60);

        adversary.configureAttack(id, 2, 100_000e6);

        uint256 balBefore = usdc.balanceOf(address(adversary));

        // Step 0: bet while open.
        vm.warp(now_ + 1 minutes);
        adversary.executeAttack();

        // Step 1: close + report (dishonest).
        vm.warp(resTime);
        adversary.executeAttack();

        // Honest challenger disputes immediately.
        vm.prank(alice);
        pot.challenge(id, 1);

        // Oracles resolve to the true outcome.
        vm.prank(oracle0);
        pot.resolveDispute(id, 1);
        vm.prank(oracle1);
        pot.resolveDispute(id, 1);

        (uint64 appealDeadline,,,) = pot.getAppealInfo(id);
        vm.warp(uint256(appealDeadline) + 24 hours + 1);
        pot.finalize(id);

        uint256 balAfter = usdc.balanceOf(address(adversary));
        assertLe(balAfter, balBefore, "attacker should not profit if challenged");
    }

    function test_challenged_market_can_expire_if_oracles_fail_to_resolve() public {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 30 minutes;

        vm.prank(creator);
        uint256 id = pot.create("Unresolved Dispute", "bafyUnresolved", deadline, resTime, 2, "", address(0));

        vm.prank(alice);
        pot.bet(id, 1, 10_000e6, 0, block.timestamp + 60);
        vm.prank(bob);
        pot.bet(id, 2, 20_000e6, 0, block.timestamp + 60);

        adversary.configureAttack(id, 2, 50_000e6);

        // Enter + report.
        vm.warp(now_ + 1 minutes);
        adversary.executeAttack();
        vm.warp(resTime);
        adversary.executeAttack();

        // Challenge, but do not call oracle resolution.
        vm.prank(alice);
        pot.challenge(id, 1);

        (,,, uint64 reportedAt,,,,) = pot.getReport(id);
        vm.warp(uint256(reportedAt) + 48 hours + 7 days + 1);
        pot.expireChallenge(id);

        // Everyone can exit; attacker should be able to emergency-withdraw their shares.
        vm.prank(address(adversary));
        pot.emergencyWithdraw(id, 0);
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
    }

    function _approve(address who) internal {
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }

    /// @notice Simulate vault yield by minting assets + increasing mock exchange rate.
    function _simulateYield(uint256 bps) internal {
        if (bps == 0) return;

        uint256 vaultBalance = usdc.balanceOf(address(yearnVault));
        uint256 yieldAmount = Math.mulDiv(vaultBalance, bps, 10_000);
        usdc.mint(address(yearnVault), yieldAmount);

        uint256 oldRate = yearnVault.exchangeRate();
        uint256 newRate = Math.mulDiv(oldRate, 10_000 + bps, 10_000);
        yearnVault.setExchangeRate(newRate);
    }
}

