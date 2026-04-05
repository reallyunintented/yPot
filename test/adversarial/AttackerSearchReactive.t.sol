// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {yPot} from "../../src/yPot.sol";
import {YearnWrapper} from "../../src/YearnWrapper.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";

/// @notice Adversarial search with reactive honest challengers/oracles.
/// @dev This removes the "nobody challenges" assumption from the search space.
contract AttackerSearchReactiveTest is Test {
    uint8 private constant ST_REPORTED = 5;
    uint256 private constant MAX_KNOWN_BOUNTY_PROFIT = 0;

    MockUSDC internal usdc;
    MockERC4626Vault internal yearnVault;
    YearnWrapper internal wrapper;
    yPot internal pot;

    address internal treasury = address(0xCAFE);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);
    address internal creator = address(0xA11CE);

    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xC3);

    address internal attacker0 = address(0xDEAD);
    address internal attacker1 = address(0xBEEF);
    address internal attacker2 = address(0xFEED);

    uint256 internal constant ATTACKER_FUNDING = 500_000e6;
    uint256 internal constant BETTOR_FUNDING = 1_000_000e6;

    uint256 internal openMarketId;
    uint256 internal reportedMarketId;
    uint256 internal claimableMarketId;
    uint256 internal cancelledMarketId;

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

        _fundAndApprove(creator, BETTOR_FUNDING);
        _fundAndApprove(alice, BETTOR_FUNDING);
        _fundAndApprove(bob, BETTOR_FUNDING);
        _fundAndApprove(charlie, BETTOR_FUNDING);

        _fundAndApprove(attacker0, ATTACKER_FUNDING);
        _fundAndApprove(attacker1, 0);
        _fundAndApprove(attacker2, 0);

        _seedOpenMarket();
        _seedReportedMarket();
        _seedClaimableMarket();
        _seedCancelledMarket();

        _simulateYield(500);
    }

    function testFuzz_attackerCluster_cannotProfit_withReactiveChallenge(uint256 seed) public {
        uint256 finalTotal = _runSeed(seed, false);
        uint256 initial = ATTACKER_FUNDING;
        assertLe(
            finalTotal,
            initial + MAX_KNOWN_BOUNTY_PROFIT,
            "attacker cluster extracted more than bounded truth-bounty with reactive challengers"
        );
    }

    function test_replay_seed32() public {
        uint256 finalTotal = _runSeed(32, true);
        uint256 initial = ATTACKER_FUNDING;
        console2.log("seed 32 final attacker total:", finalTotal);
        console2.log("seed 32 initial attacker total:", initial);
        assertLe(finalTotal, initial, "attacker cluster extracted USDC with reactive challengers");
    }

    function test_replay_small_counterexample() public {
        uint256 seed = 10443197734650823812903508205054053828996693193942596722630947887776179046098;
        uint256 finalTotal = _runSeed(seed, true);
        uint256 initial = ATTACKER_FUNDING;
        console2.log("small-ct final attacker total:", finalTotal);
        console2.log("small-ct initial attacker total:", initial);
        assertLe(finalTotal, initial, "counterexample seed must not be profitable after dispute rake");
    }

    function _runSeed(uint256 seed, bool verbose) internal returns (uint256 finalTotal) {
        uint256 initial = _attackerTotal();
        if (verbose) {
            console2.log("initial attacker total:", initial);
        }

        for (uint256 i; i < 360; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));

            uint256 op = seed % 16;
            address actor = _attacker(seed >> 8);
            uint256 id = _marketId(seed >> 16);
            uint8 outcome = uint8((seed >> 24) % 5 + 1);

            uint256 before = _attackerTotal();

            if (op == 0) {
                _stepWarp(seed >> 32);
            } else if (op == 1) {
                _try(actor, abi.encodeWithSelector(yPot.close.selector, id));
            } else if (op == 2) {
                _try(actor, abi.encodeWithSelector(yPot.report.selector, id, outcome));
            } else if (op == 3) {
                _try(actor, abi.encodeWithSelector(yPot.challenge.selector, id, outcome));
            } else if (op == 4) {
                uint256 bal = usdc.balanceOf(actor);
                uint256 assetsIn = bal == 0 ? 0 : (seed % bal) + 1;
                _try(
                    actor,
                    abi.encodeWithSelector(yPot.confirmReport.selector, id, assetsIn, 0, block.timestamp + 1 days)
                );
            } else if (op == 5) {
                _try(actor, abi.encodeWithSelector(yPot.acceptReport.selector, id));
            } else if (op == 6) {
                _try(actor, abi.encodeWithSelector(yPot.finalize.selector, id));
            } else if (op == 7) {
                _try(actor, abi.encodeWithSelector(yPot.expireMarket.selector, id));
            } else if (op == 8) {
                _try(actor, abi.encodeWithSelector(yPot.expireChallenge.selector, id));
            } else if (op == 9) {
                _try(actor, abi.encodeWithSelector(yPot.expireUnconfirmedReport.selector, id));
            } else if (op == 10) {
                _try(actor, abi.encodeWithSelector(yPot.claim.selector, id, 0, 0));
            } else if (op == 11) {
                _try(actor, abi.encodeWithSelector(yPot.emergencyWithdraw.selector, id, 0));
            } else if (op == 12) {
                _try(actor, abi.encodeWithSelector(yPot.withdrawConfirmBond.selector, id, 0, 0));
            } else if (op == 13) {
                _try(actor, abi.encodeWithSelector(yPot.sweepDust.selector, id, 0));
            } else if (op == 14) {
                _try(actor, abi.encodeWithSelector(yPot.sweepExcessVaultShares.selector, 0, 0));
            } else {
                _attackerTransfer(actor, seed);
            }

            _honestMaintenance();

            uint256 after_ = _attackerTotal();
            if (verbose && after_ != before) {
                console2.log("balance-change step:", i);
                console2.log("op:", op);
                console2.log("actor:", actor);
                console2.log("market:", id);
                console2.log("outcome:", outcome);
                if (after_ > before) {
                    console2.log("delta (+):", after_ - before);
                } else {
                    console2.log("delta (-):", before - after_);
                }
            }
        }

        finalTotal = _attackerTotal();
    }

    function _honestMaintenance() internal {
        uint256[4] memory ids = [openMarketId, reportedMarketId, claimableMarketId, cancelledMarketId];

        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            (,,,,,, uint8 outcomes,, uint8 status,,) = pot.getMkt(id);
            if (status != ST_REPORTED) continue;

            (address reporter, uint8 reportOutcome,,,, address challenger, uint8 challengeOutcome,) = pot.getReport(id);
            if (reporter == address(0) || reportOutcome == 0 || outcomes < 2) continue;

            if (challenger == address(0) && _isAttacker(reporter)) {
                uint8 crowd = _crowdOutcome(id, outcomes, 0, reportOutcome);
                if (crowd == 0 || crowd == reportOutcome) {
                    continue;
                }

                (address honest, uint8 honestOutcome) = _pickHonestChallenger(id, crowd);
                if (honest != address(0) && honestOutcome != 0) {
                    vm.prank(honest);
                    try pot.challenge(id, honestOutcome) {} catch {}
                }
                continue;
            }

            if (challenger != address(0)) {
                uint8 resolvedOutcome = _crowdOutcome(id, outcomes, challengeOutcome, reportOutcome);
                if (resolvedOutcome == 0) {
                    resolvedOutcome = challengeOutcome == 0 ? reportOutcome : challengeOutcome;
                }
                if (resolvedOutcome > 0 && resolvedOutcome <= outcomes) {
                    vm.prank(oracle0);
                    try pot.resolveDispute(id, resolvedOutcome) {} catch {}
                    vm.prank(oracle1);
                    try pot.resolveDispute(id, resolvedOutcome) {} catch {}
                }
            }
        }
    }

    function _pickHonestChallenger(uint256 id, uint8 targetOutcome) internal view returns (address who, uint8 outcome) {
        address[3] memory honest = [alice, bob, charlie];

        uint256 bestShares;
        for (uint256 i; i < honest.length; i++) {
            (uint256[] memory s,,,) = pot.getUsr(id, honest[i]);
            if (targetOutcome >= s.length) continue;
            if (s[targetOutcome] > bestShares) {
                bestShares = s[targetOutcome];
                who = honest[i];
                outcome = targetOutcome;
            }
        }
    }

    function _crowdOutcome(uint256 id, uint8 outcomes, uint8 preferred, uint8 fallbackOutcome)
        internal
        view
        returns (uint8 best)
    {
        (uint256[] memory shares,,,,) = pot.getShares(id);
        uint256 bestS;

        for (uint8 o = 1; o <= outcomes; o++) {
            if (shares[o] > bestS) {
                bestS = shares[o];
                best = o;
            }
        }

        if (best == 0 || bestS == 0) {
            if (preferred != 0) return preferred;
            return fallbackOutcome;
        }
    }

    function _try(address actor, bytes memory data) internal returns (bool ok) {
        vm.prank(actor);
        (ok,) = address(pot).call(data);
    }

    function _attackerTransfer(address from, uint256 seed) internal {
        address to = _attacker(seed >> 40);
        if (to == from) {
            to = from == attacker0 ? attacker1 : attacker0;
        }

        uint256 bal = usdc.balanceOf(from);
        if (bal == 0) return;

        uint256 amount = (seed % bal) + 1;
        vm.prank(from);
        require(usdc.transfer(to, amount), "TRANSFER_FAILED");
    }

    function _stepWarp(uint256 seed) internal {
        uint256 delta = (seed % (3 days)) + 1;
        vm.warp(block.timestamp + delta);
    }

    function _marketId(uint256 seed) internal view returns (uint256) {
        uint256 idx = seed % 4;
        if (idx == 0) return openMarketId;
        if (idx == 1) return reportedMarketId;
        if (idx == 2) return claimableMarketId;
        return cancelledMarketId;
    }

    function _attacker(uint256 seed) internal view returns (address) {
        uint256 idx = seed % 3;
        if (idx == 0) return attacker0;
        if (idx == 1) return attacker1;
        return attacker2;
    }

    function _attackerTotal() internal view returns (uint256) {
        return usdc.balanceOf(attacker0) + usdc.balanceOf(attacker1) + usdc.balanceOf(attacker2)
            + pot.pendingWithdrawals(attacker0) + pot.pendingWithdrawals(attacker1) + pot.pendingWithdrawals(attacker2);
    }

    function _isAttacker(address a) internal view returns (bool) {
        return a == attacker0 || a == attacker1 || a == attacker2;
    }

    function _seedOpenMarket() internal {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 1 hours;

        vm.prank(creator);
        openMarketId = pot.create("Open Market", "bafyOpen", deadline, resTime, 3, "", address(0));

        vm.warp(now_ + 1 hours);
        vm.prank(alice);
        pot.bet(openMarketId, 1, 10_000e6, 0, block.timestamp + 60);

        vm.warp(now_ + 2 hours);
        vm.prank(bob);
        pot.bet(openMarketId, 2, 20_000e6, 0, block.timestamp + 60);

        vm.warp(now_ + 3 hours);
        vm.prank(charlie);
        pot.bet(openMarketId, 3, 5_000e6, 0, block.timestamp + 60);

        vm.warp(now_ + 4 hours);
    }

    function _seedReportedMarket() internal {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 30 minutes;

        vm.prank(creator);
        reportedMarketId = pot.create("Reported Market", "bafyReported", deadline, resTime, 2, "", address(0));

        vm.prank(alice);
        pot.bet(reportedMarketId, 1, 50_000e6, 0, block.timestamp + 60);

        vm.prank(bob);
        pot.bet(reportedMarketId, 2, 30_000e6, 0, block.timestamp + 60);

        vm.warp(deadline + 1);
        pot.close(reportedMarketId);

        vm.warp(resTime);
        vm.prank(alice);
        pot.report(reportedMarketId, 1);
    }

    function _seedClaimableMarket() internal {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 30 minutes;

        vm.prank(creator);
        claimableMarketId = pot.create("Claimable Market", "bafyClaimable", deadline, resTime, 2, "", address(0));

        vm.prank(alice);
        pot.bet(claimableMarketId, 1, 100_000e6, 0, block.timestamp + 60);

        vm.prank(bob);
        pot.bet(claimableMarketId, 2, 80_000e6, 0, block.timestamp + 60);

        vm.prank(charlie);
        pot.bet(claimableMarketId, 1, 20_000e6, 0, block.timestamp + 60);

        vm.warp(deadline + 1);
        pot.close(claimableMarketId);

        vm.warp(resTime);
        vm.prank(alice);
        pot.report(claimableMarketId, 1);

        vm.prank(alice);
        pot.confirmReport(claimableMarketId, 50_000e6, 0, block.timestamp + 60);

        vm.warp(resTime + 48 hours + 1);
        pot.acceptReport(claimableMarketId);

        vm.warp(resTime + 48 hours + 24 hours + 2);
        pot.finalize(claimableMarketId);
    }

    function _seedCancelledMarket() internal {
        uint64 now_ = uint64(block.timestamp);
        uint64 deadline = now_ + 14 days + 1;
        uint64 resTime = deadline + 30 minutes;

        vm.prank(creator);
        cancelledMarketId = pot.create("Cancelled Market", "bafyCancelled", deadline, resTime, 2, "", address(0));

        vm.prank(alice);
        pot.bet(cancelledMarketId, 1, 10_000e6, 0, block.timestamp + 60);

        vm.warp(deadline + 1);
        pot.close(cancelledMarketId);

        vm.warp(resTime + 7 days + 1);
        pot.expireMarket(cancelledMarketId);
    }

    function _simulateYield(uint256 bps) internal {
        if (bps == 0) return;
        uint256 vaultBalance = usdc.balanceOf(address(yearnVault));
        uint256 yieldAmount = Math.mulDiv(vaultBalance, bps, 10_000);
        usdc.mint(address(yearnVault), yieldAmount);

        uint256 oldRate = yearnVault.exchangeRate();
        uint256 newRate = Math.mulDiv(oldRate, 10_000 + bps, 10_000);
        yearnVault.setExchangeRate(newRate);
    }

    function _fundAndApprove(address who, uint256 amount) internal {
        if (amount > 0) {
            usdc.mint(who, amount);
        }
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }
}
