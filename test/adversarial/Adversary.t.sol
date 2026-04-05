// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {yPot} from "../../src/yPot.sol";
import {YearnWrapper} from "../../src/YearnWrapper.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {Adversary} from "./Adversary.sol";

/// @title AdversaryTest
/// @notice Test harness for adversarial testing of yPot.
///
/// This deploys a full yPot stack with realistic market state, then gives the
/// Adversary contract funds and calls executeAttack(). After the attack, it
/// checks whether the adversary profited.
///
/// Usage:
///   forge test --match-path test/adversarial/Adversary.t.sol -vvv
///
/// The test PASSES if the adversary does NOT profit (contract is secure).
/// The test FAILS if the adversary extracts value (vulnerability found).
contract AdversaryTest is Test {
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    MockUSDC internal usdc;
    MockERC4626Vault internal yearnVault;
    YearnWrapper internal wrapper;
    yPot internal pot;
    Adversary internal adversary;

    address internal treasury = address(0xCAFE);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);
    address internal creator = address(0xA11CE);

    // Innocent bettors
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xC3);

    uint256 internal constant ATTACKER_FUNDING = 500_000e6; // 500k USDC
    uint256 internal constant BETTOR_FUNDING = 1_000_000e6;
    uint8 internal constant ST_REPORTED = 5;
    uint8 internal constant ST_APPEALABLE = 7;
    uint8 internal constant ST_CLAIMABLE = 3;

    // Market IDs created during seeding
    uint256 internal openMarketId;
    uint256 internal reportedMarketId;
    uint256 internal claimableMarketId;
    uint256 internal cancelledMarketId;

    // -------------------------------------------------------------------------
    // Setup: deploy stack + seed state
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.warp(1_700_000_000);

        // --- Deploy core ---
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

        // --- Deploy adversary ---
        adversary = new Adversary(address(pot), address(usdc), address(wrapper));

        // --- Fund participants ---
        _fund(creator, BETTOR_FUNDING);
        _fund(alice, BETTOR_FUNDING);
        _fund(bob, BETTOR_FUNDING);
        _fund(charlie, BETTOR_FUNDING);
        _fund(address(adversary), ATTACKER_FUNDING);

        // --- Approve pot for all participants ---
        _approve(creator);
        _approve(alice);
        _approve(bob);
        _approve(charlie);

        // --- Seed realistic market state ---
        _seedOpenMarket();
        _seedReportedMarket();
        _seedClaimableMarket();
        _seedCancelledMarket();
    }

    // -------------------------------------------------------------------------
    // THE TEST: adversary tries to profit
    // -------------------------------------------------------------------------

    function test_adversary_cannot_profit() public {
        // --- Simulate some vault yield (rate goes up 5%) ---
        _simulateYield(500); // 5% = 500 bps

        uint256 balanceBefore = _adversaryTotal();
        console2.log("Adversary total before attack:", balanceBefore);

        // Run the exploit
        adversary.executeAttack();

        // Pull-based: withdraw any pending bond/bounty credits the adversary accumulated
        if (pot.pendingWithdrawals(address(adversary)) > 0) {
            vm.prank(address(adversary));
            pot.withdrawPending();
        }

        uint256 balanceAfter = _adversaryTotal();
        console2.log("Adversary total after attack: ", balanceAfter);

        if (balanceAfter > balanceBefore) {
            uint256 profit = balanceAfter - balanceBefore;
            console2.log("!!! VULNERABILITY FOUND !!!");
            console2.log("Profit extracted:", profit);
            console2.log("Profit in USDC:", profit / 1e6);
            fail("Adversary extracted value - vulnerability found");
        } else {
            console2.log("No profit extracted - contract held");
        }
    }

    /// @notice Runs full lifecycle attacks across outcomes + rates with honest challenge response.
    function test_adversary_cannot_profit_reactive_challenge_matrix() public {
        uint256[] memory rates = new uint256[](4);
        rates[0] = 0; // no yield
        rates[1] = 500; // 5%
        rates[2] = 1000; // 10%
        rates[3] = 5000; // 50%

        for (uint256 r; r < rates.length; r++) {
            for (uint8 attackerOutcome = 1; attackerOutcome <= 3; attackerOutcome++) {
                setUp();
                _runReactiveChallengeScenario(attackerOutcome, 100_000e6, rates[r]);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Market Seeding
    // -------------------------------------------------------------------------

    /// @dev Market 1: OPEN with bets from alice, bob, charlie on different outcomes
    function _seedOpenMarket() internal {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 1 hours;

        vm.prank(creator);
        openMarketId = pot.create("Open Market", "bafyOpen", deadline, resTime, 3, "", address(0));

        // Alice bets 10k on outcome 1
        vm.warp(now_ + 1 hours);
        vm.prank(alice);
        pot.bet(openMarketId, 1, 10_000e6, 0, block.timestamp + 60);

        // Bob bets 20k on outcome 2
        vm.warp(now_ + 2 hours);
        vm.prank(bob);
        pot.bet(openMarketId, 2, 20_000e6, 0, block.timestamp + 60);

        // Charlie bets 5k on outcome 3
        vm.warp(now_ + 3 hours);
        vm.prank(charlie);
        pot.bet(openMarketId, 3, 5_000e6, 0, block.timestamp + 60);

        // Reset time
        vm.warp(now_ + 4 hours);
    }

    /// @dev Market 2: REPORTED (past deadline, reported outcome 1, waiting for confirmation)
    function _seedReportedMarket() internal {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 30 minutes;

        vm.prank(creator);
        reportedMarketId = pot.create("Reported Market", "bafyReported", deadline, resTime, 2, "", address(0));

        // Alice bets 50k on outcome 1
        vm.prank(alice);
        pot.bet(reportedMarketId, 1, 50_000e6, 0, block.timestamp + 60);

        // Bob bets 30k on outcome 2
        vm.prank(bob);
        pot.bet(reportedMarketId, 2, 30_000e6, 0, block.timestamp + 60);

        // Close + report
        vm.warp(deadline + 1);
        pot.close(reportedMarketId);

        vm.warp(resTime);
        vm.prank(alice);
        pot.report(reportedMarketId, 1);
    }

    /// @dev Market 3: CLAIMABLE (fully resolved, outcome 1 won, ready for claims)
    function _seedClaimableMarket() internal {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 30 minutes;

        vm.prank(creator);
        claimableMarketId = pot.create("Claimable Market", "bafyClaimable", deadline, resTime, 2, "", address(0));

        // Alice bets 100k on outcome 1
        vm.prank(alice);
        pot.bet(claimableMarketId, 1, 100_000e6, 0, block.timestamp + 60);

        // Bob bets 80k on outcome 2
        vm.prank(bob);
        pot.bet(claimableMarketId, 2, 80_000e6, 0, block.timestamp + 60);

        // Charlie bets 20k on outcome 1
        vm.prank(charlie);
        pot.bet(claimableMarketId, 1, 20_000e6, 0, block.timestamp + 60);

        // Close + report + confirm + accept + finalize
        vm.warp(deadline + 1);
        pot.close(claimableMarketId);

        vm.warp(resTime);
        vm.prank(alice);
        pot.report(claimableMarketId, 1);

        // Alice confirms with her winning position (need ≥20% of pool = 40k USDC)
        vm.prank(alice);
        pot.confirmReport(claimableMarketId, 50_000e6, 0, block.timestamp + 60);

        vm.warp(resTime + 48 hours + 1);
        pot.acceptReport(claimableMarketId);

        vm.warp(resTime + 48 hours + 24 hours + 2);
        pot.finalize(claimableMarketId);
    }

    /// @dev Market 4: CANCELLED (expired without report)
    function _seedCancelledMarket() internal {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 30 minutes;

        vm.prank(creator);
        cancelledMarketId = pot.create("Cancelled Market", "bafyCancelled", deadline, resTime, 2, "", address(0));

        // Alice bets 10k on outcome 1
        vm.prank(alice);
        pot.bet(cancelledMarketId, 1, 10_000e6, 0, block.timestamp + 60);

        // Close but nobody reports -> expires after 7 days
        vm.warp(deadline + 1);
        pot.close(cancelledMarketId);

        vm.warp(resTime + 7 days + 1);
        pot.expireMarket(cancelledMarketId);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
    }

    function _approve(address who) internal {
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }

    /// @notice Simulate vault yield by minting extra USDC into the vault
    function _simulateYield(uint256 bps) internal {
        if (bps == 0) return;
        uint256 vaultBalance = usdc.balanceOf(address(yearnVault));
        uint256 yieldAmount = Math.mulDiv(vaultBalance, bps, 10_000);
        usdc.mint(address(yearnVault), yieldAmount);

        // MockERC4626Vault uses a manual exchange rate; update it to reflect yield.
        uint256 oldRate = yearnVault.exchangeRate();
        uint256 newRate = Math.mulDiv(oldRate, 10_000 + bps, 10_000);
        yearnVault.setExchangeRate(newRate);
    }

    function _runReactiveChallengeScenario(uint8 attackerOutcome, uint256 attackerBet, uint256 yieldBps) internal {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 30 minutes;

        vm.prank(creator);
        uint256 id = pot.create("Reactive Adversarial Market", "bafyReactive", deadline, resTime, 3, "", address(0));

        vm.prank(alice);
        pot.bet(id, 1, 30_000e6, 0, block.timestamp + 60);
        vm.prank(bob);
        pot.bet(id, 2, 45_000e6, 0, block.timestamp + 60);
        vm.prank(charlie);
        pot.bet(id, 3, 25_000e6, 0, block.timestamp + 60);

        adversary.configureAttack(id, attackerOutcome, attackerBet);

        uint256 beforeTotal = _adversaryTotal();

        vm.warp(now_ + 1 minutes);
        adversary.executeAttack(); // step 0: bet

        vm.warp(resTime);
        adversary.executeAttack(); // step 1: close + report
        adversary.executeAttack(); // step 2: confirm

        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        if (status != ST_REPORTED) {
            fail("expected market to be reported by adversary");
        }

        uint8 honestOutcome = _honestOutcome(attackerOutcome);
        address honestActor = _actorForOutcome(honestOutcome);

        vm.prank(honestActor);
        pot.challenge(id, honestOutcome);

        vm.prank(oracle0);
        pot.resolveDispute(id, honestOutcome);
        vm.prank(oracle1);
        pot.resolveDispute(id, honestOutcome);

        (,,,,,,,, uint8 statusAfterVote,,) = pot.getMkt(id);
        if (statusAfterVote != ST_APPEALABLE) {
            fail("expected market to be appealable after committee resolution");
        }

        (uint64 appealDeadline,,,) = pot.getAppealInfo(id);
        vm.warp(uint256(appealDeadline) + 24 hours + 1);
        pot.finalize(id);

        (,,,,,,,, uint8 finalStatus,,) = pot.getMkt(id);
        if (finalStatus != ST_CLAIMABLE) {
            fail("expected market to be claimable after finalize");
        }

        _simulateYield(yieldBps);
        _forceAdversaryExits(id);

        uint256 afterTotal = _adversaryTotal();
        if (afterTotal > beforeTotal) {
            console2.log("Reactive scenario vulnerability found");
            console2.log("attackerOutcome:", attackerOutcome);
            console2.log("honestOutcome:", honestOutcome);
            console2.log("yieldBps:", yieldBps);
            console2.log("profit:", afterTotal - beforeTotal);
            fail("adversary profited despite reactive honest challenge");
        }
    }

    function _forceAdversaryExits(uint256 id) internal {
        vm.prank(address(adversary));
        try pot.claim(id, 0, 0) {} catch {}

        vm.prank(address(adversary));
        try pot.withdrawConfirmBond(id, 0, 0) {} catch {}

        vm.prank(address(adversary));
        try pot.emergencyWithdraw(id, 0) {} catch {}

        if (pot.pendingWithdrawals(address(adversary)) > 0) {
            vm.prank(address(adversary));
            pot.withdrawPending();
        }
    }

    function _adversaryTotal() internal view returns (uint256) {
        return usdc.balanceOf(address(adversary)) + pot.pendingWithdrawals(address(adversary));
    }

    function _honestOutcome(uint8 attackerOutcome) internal pure returns (uint8) {
        if (attackerOutcome == 1) return 2;
        return 1;
    }

    function _actorForOutcome(uint8 outcome) internal view returns (address) {
        if (outcome == 1) return alice;
        if (outcome == 2) return bob;
        return charlie;
    }
}
