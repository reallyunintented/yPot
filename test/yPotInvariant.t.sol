// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";
import {yPotViews} from "src/yPotViews.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

contract yPotInvariantHandler is Test {
    uint256 private constant CHALLENGE_WINDOW = 48 hours;
    uint256 private constant CONFIRM_TIMEOUT = 48 hours;
    uint256 private constant DISPUTE_PERIOD = 24 hours;
    uint256 private constant EXPIRE_WINDOW = 7 days;
    uint256 private constant MAX_MARKETS = 16;

    uint8 private constant ST_OPEN = 0;
    uint8 private constant ST_CLOSED = 1;
    uint8 private constant ST_RESOLVED = 2;
    uint8 private constant ST_CLAIMABLE = 3;
    uint8 private constant ST_CANCELLED = 4;
    uint8 private constant ST_REPORTED = 5;
    uint8 private constant ST_APPEALABLE = 7;

    yPot internal immutable pot;
    YearnWrapper internal immutable wrapper;
    MockERC4626Vault internal immutable yearn;
    MockUSDC internal immutable usdc;

    address[] internal actors;
    address[] internal oracles;

    uint256 public successfulCreates;
    uint256 public successfulBets;
    uint256 public successfulReports;
    uint256 public successfulConfirms;
    uint256 public successfulChallenges;
    uint256 public successfulResolutions;
    uint256 public successfulClaims;
    uint256 public successfulBatchClaims;
    uint256 public successfulEmergencyWithdraws;

    constructor(
        yPot _pot,
        YearnWrapper _wrapper,
        MockERC4626Vault _yearn,
        MockUSDC _usdc,
        address[] memory _actors,
        address[] memory _oracles
    ) {
        pot = _pot;
        wrapper = _wrapper;
        yearn = _yearn;
        usdc = _usdc;
        actors = _actors;
        oracles = _oracles;
    }

    function createMarket(uint256 actorSeed, uint64 deadlineDeltaRaw, uint64 resolutionDeltaRaw, uint8 outcomesRaw)
        external
    {
        if (_marketCount() >= MAX_MARKETS) return;

        address actor = _actor(actorSeed);
        uint64 dl = uint64(block.timestamp + bound(uint256(deadlineDeltaRaw), 14 days + 1, 90 days));
        uint64 rt = uint64(uint256(dl) + bound(uint256(resolutionDeltaRaw), 1 hours + 1, 5 days));
        uint8 outcomes = uint8(bound(uint256(outcomesRaw), 2, 5));

        vm.prank(actor);
        try pot.create("invariant-market", "bafyinvariant", dl, rt, outcomes, "", address(0)) returns (uint256) {
            successfulCreates++;
        } catch {}
    }

    function placeBet(uint256 actorSeed, uint256 marketSeed, uint256 amountRaw, uint8 outcomeRaw) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,, uint64 deadline,,, uint8 outcomes,, uint8 status,,) = pot.getMkt(id);
        if (status != ST_OPEN || block.timestamp > uint256(deadline)) return;

        address actor = _actor(actorSeed);
        uint256 amount = bound(amountRaw, pot.minBet(), pot.maxBet());
        uint8 outcome = uint8(bound(uint256(outcomeRaw), 1, outcomes));

        vm.prank(actor);
        try pot.bet(id, outcome, amount, 0, block.timestamp + 1 days) {
            successfulBets++;
        } catch {}
    }

    function closeMarket(uint256 marketSeed) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,, uint64 deadline,,, uint8 outcomes,, uint8 status,,) = pot.getMkt(id);
        if (outcomes < 2 || status != ST_OPEN) return;

        if (block.timestamp <= uint256(deadline)) {
            vm.warp(uint256(deadline) + 1);
        }

        try pot.close(id) {} catch {}
    }

    function reportMarket(uint256 actorSeed, uint256 marketSeed, uint8 outcomeRaw) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,, uint64 deadline, uint64 resTime,, uint8 outcomes,, uint8 status, address creator,) = pot.getMkt(id);
        if (status != ST_CLOSED || outcomes < 2) return;

        if (block.timestamp <= uint256(deadline)) {
            vm.warp(uint256(deadline) + 1);
        }
        if (block.timestamp < uint256(resTime)) {
            vm.warp(uint256(resTime));
        }

        address actor = _actor(actorSeed);
        if (actor == creator) {
            actor = _nextActor(actor, actorSeed + 1);
        }

        uint8 outcome = uint8(bound(uint256(outcomeRaw), 1, outcomes));
        vm.prank(actor);
        try pot.report(id, outcome) {
            successfulReports++;
        } catch {}
    }

    function confirmReportedMarket(uint256 actorSeed, uint256 marketSeed, uint256 assetsRaw) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,,,,,, uint8 winner, uint8 status,,) = pot.getMkt(id);
        if (status != ST_REPORTED || winner != 0) return;

        (, uint8 reportedOutcome,,,, address challenger,,) = pot.getReport(id);
        if (challenger != address(0)) return;

        address actor = _actor(actorSeed);
        (uint256[] memory shares,,,) = pot.getUsr(id, actor);
        if (reportedOutcome == 0 || uint256(reportedOutcome) >= shares.length) return;
        if (shares[reportedOutcome] == 0) return;

        uint256 bal = usdc.balanceOf(actor);
        if (bal < 1e6) return;
        uint256 assetsIn = bound(assetsRaw, 1e6, bal);

        vm.prank(actor);
        try pot.confirmReport(id, assetsIn, 0, block.timestamp + 1 days) {
            successfulConfirms++;
        } catch {}
    }

    function challengeReportedMarket(uint256 actorSeed, uint256 marketSeed, uint8 outcomeRaw) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,,,,, uint8 outcomes,, uint8 status,,) = pot.getMkt(id);
        if (status != ST_REPORTED || outcomes < 2) return;

        (address reporter, uint8 reportOutcome,, uint64 reportedAt,, address challenger,,) = pot.getReport(id);
        if (challenger != address(0)) return;
        if (block.timestamp > uint256(reportedAt) + CHALLENGE_WINDOW) return;

        address actor = _actor(actorSeed);
        if (actor == reporter) {
            actor = _nextActor(actor, actorSeed + 1);
        }

        uint8 outcome = uint8(bound(uint256(outcomeRaw), 1, outcomes));
        if (outcome == reportOutcome) {
            outcome = outcome == outcomes ? 1 : outcome + 1;
        }

        vm.prank(actor);
        try pot.challenge(id, outcome) {
            successfulChallenges++;
        } catch {}
    }

    function resolveDisputedMarket(uint256 oracleSeed, uint256 marketSeed, uint8 outcomeRaw) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,,,,, uint8 outcomes,, uint8 status,,) = pot.getMkt(id);
        if (status != ST_REPORTED || outcomes < 2) return;

        (,,,,, address challenger,,) = pot.getReport(id);
        if (challenger == address(0)) return;

        address oracle = _oracle(oracleSeed);
        uint8 outcome = uint8(bound(uint256(outcomeRaw), 1, outcomes));

        vm.prank(oracle);
        try pot.resolveDispute(id, outcome) {
            successfulResolutions++;
        } catch {}
    }

    function acceptReportedMarket(uint256 marketSeed) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        if (status != ST_REPORTED) return;

        (,,, uint64 reportedAt,, address challenger,,) = pot.getReport(id);
        if (challenger != address(0)) return;

        uint256 openUntil = uint256(reportedAt) + CHALLENGE_WINDOW;
        if (block.timestamp <= openUntil) {
            vm.warp(openUntil + 1);
        }

        try pot.acceptReport(id) {} catch {}
    }

    function finalizeMarket(uint256 marketSeed) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,,,, uint64 resolved,,, uint8 status,,) = pot.getMkt(id);
        if (status == ST_APPEALABLE) {
            (uint64 appealDeadline,,,) = pot.getAppealInfo(id);
            uint256 readyAt = uint256(appealDeadline) + DISPUTE_PERIOD + 1;
            if (block.timestamp < readyAt) {
                vm.warp(readyAt);
            }
        } else if (status == ST_RESOLVED) {
            uint256 readyAt = uint256(resolved) + DISPUTE_PERIOD + 1;
            if (block.timestamp < readyAt) {
                vm.warp(readyAt);
            }
        } else {
            return;
        }

        try pot.finalize(id) {} catch {}
    }

    function expireStaleMarket(uint256 marketSeed) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,,, uint64 resTime,,, uint8 status,,,) = pot.getMkt(id);
        if (status != ST_CLOSED) return;

        uint256 readyAt = uint256(resTime) + EXPIRE_WINDOW + 1;
        if (block.timestamp < readyAt) {
            vm.warp(readyAt);
        }

        try pot.expireMarket(id) {} catch {}
    }

    function expireStaleChallenge(uint256 marketSeed) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        if (status != ST_REPORTED) return;

        (,,, uint64 reportedAt,, address challenger,,) = pot.getReport(id);
        if (challenger == address(0)) return;

        uint256 readyAt = uint256(reportedAt) + CHALLENGE_WINDOW + EXPIRE_WINDOW + 1;
        if (block.timestamp < readyAt) {
            vm.warp(readyAt);
        }

        try pot.expireChallenge(id) {} catch {}
    }

    function expireUnconfirmedReport(uint256 marketSeed) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        if (status != ST_REPORTED) return;

        (,,, uint64 reportedAt,, address challenger,,) = pot.getReport(id);
        if (challenger != address(0)) return;

        uint256 readyAt = uint256(reportedAt) + CHALLENGE_WINDOW + CONFIRM_TIMEOUT + 1;
        if (block.timestamp < readyAt) {
            vm.warp(readyAt);
        }

        try pot.expireUnconfirmedReport(id) {} catch {}
    }

    function claimMarket(uint256 actorSeed, uint256 marketSeed) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        if (status != ST_CLAIMABLE) return;

        vm.prank(_actor(actorSeed));
        try pot.claim(id, 0, 0) {
            successfulClaims++;
        } catch {}
    }

    function batchClaimMarkets(uint256 actorSeed, uint256 marketSeedA, uint256 marketSeedB) external {
        uint256 count = _marketCount();
        if (count < 2) return;

        uint256 idA = _marketId(marketSeedA);
        uint256 idB = _marketId(marketSeedB);
        if (idA == idB) {
            idB = idA == count ? 1 : idA + 1;
        }

        uint256[] memory ids = new uint256[](2);
        ids[0] = idA;
        ids[1] = idB;

        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = 0;
        minOuts[1] = 0;

        vm.prank(_actor(actorSeed));
        try pot.batchClaim(ids, minOuts) {
            successfulBatchClaims++;
        } catch {}
    }

    function emergencyWithdrawCancelledMarket(uint256 actorSeed, uint256 marketSeed) external {
        uint256 count = _marketCount();
        if (count == 0) return;

        uint256 id = _marketId(marketSeed);
        (,,,,,,,, uint8 status,,) = pot.getMkt(id);
        if (status != ST_CANCELLED) return;

        vm.prank(_actor(actorSeed));
        try pot.emergencyWithdraw(id, 0) {
            successfulEmergencyWithdraws++;
        } catch {}
    }

    function advanceTime(uint256 deltaRaw) external {
        uint256 delta = bound(deltaRaw, 1, 2 days);
        vm.warp(block.timestamp + delta);
    }

    function mutateExchangeRate(uint256 rateRaw) external {
        uint256 nextRate = bound(rateRaw, 5e17, 2e18);
        yearn.setExchangeRate(nextRate);
    }

    function _marketCount() internal view returns (uint256) {
        uint256 c = pot.counter();
        return c > 1 ? c - 1 : 0;
    }

    function _marketId(uint256 seed) internal view returns (uint256) {
        uint256 count = _marketCount();
        return bound(seed, 1, count);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _nextActor(address current, uint256 seed) internal view returns (address) {
        uint256 idx = bound(seed, 0, actors.length - 1);
        if (actors[idx] != current) return actors[idx];
        return actors[(idx + 1) % actors.length];
    }

    function _oracle(uint256 seed) internal view returns (address) {
        return oracles[bound(seed, 0, oracles.length - 1)];
    }
}

contract yPotInvariantTest is StdInvariant, Test {
    uint8 private constant ST_CANCELLED = 4;

    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;
    yPotViews internal viewsLens;
    yPotInvariantHandler internal handler;

    address[] internal actors;

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockUSDC();
        yearn = new MockERC4626Vault(usdc);

        address[] memory initialDepositors = new address[](1);
        initialDepositors[0] = address(this);
        wrapper = new YearnWrapper(usdc, IERC4626(address(yearn)), initialDepositors);

        address oracle0 = address(0x1111);
        address oracle1 = address(0x2222);

        address[] memory oracleSet = new address[](2);
        oracleSet[0] = oracle0;
        oracleSet[1] = oracle1;

        pot = new yPot(address(usdc), address(wrapper), address(0xBEEF), oracleSet);
        viewsLens = new yPotViews(address(pot));
        wrapper.setDepositor(address(pot), true);

        pot.setFee(0);
        pot.setConfirmBps(0);

        address[] memory actorSet = new address[](8);
        actorSet[0] = address(0xA11CE);
        actorSet[1] = address(0xB0B);
        actorSet[2] = address(0xCA11);
        actorSet[3] = address(0xD00D);
        actorSet[4] = address(0xE11E);
        actorSet[5] = address(0xF00D);
        actorSet[6] = oracle0;
        actorSet[7] = oracle1;
        actors = actorSet;

        for (uint256 i; i < actorSet.length;) {
            usdc.mint(actorSet[i], 10_000_000e6);
            vm.prank(actorSet[i]);
            usdc.approve(address(pot), type(uint256).max);
            unchecked {
                ++i;
            }
        }

        handler = new yPotInvariantHandler(pot, wrapper, yearn, usdc, actorSet, oracleSet);

        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = handler.createMarket.selector;
        selectors[1] = handler.placeBet.selector;
        selectors[2] = handler.closeMarket.selector;
        selectors[3] = handler.reportMarket.selector;
        selectors[4] = handler.confirmReportedMarket.selector;
        selectors[5] = handler.challengeReportedMarket.selector;
        selectors[6] = handler.resolveDisputedMarket.selector;
        selectors[7] = handler.acceptReportedMarket.selector;
        selectors[8] = handler.finalizeMarket.selector;
        selectors[9] = handler.expireStaleMarket.selector;
        selectors[10] = handler.expireStaleChallenge.selector;
        selectors[11] = handler.expireUnconfirmedReport.selector;
        selectors[12] = handler.claimMarket.selector;
        selectors[13] = handler.batchClaimMarkets.selector;
        selectors[14] = handler.emergencyWithdrawCancelledMarket.selector;
        selectors[15] = handler.advanceTime.selector;
        selectors[16] = handler.mutateExchangeRate.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_claimedSharesNeverExceedPoolShares() public view {
        uint256 count = pot.counter();
        for (uint256 id = 1; id < count;) {
            (,, uint256 totalShares, uint256 claimedShares,) = pot.getShares(id);
            assertLe(claimedShares, totalShares, "market claimed shares exceed total shares");
            unchecked {
                ++id;
            }
        }
    }

    function invariant_userClaimsNeverExceedEntitlement() public view {
        uint256 count = pot.counter();
        for (uint256 id = 1; id < count;) {
            (,,,,,, uint8 outcomes, uint8 winner, uint8 status,,) = pot.getMkt(id);
            (, uint256[] memory totalWeighted, uint256 poolShares,,) = pot.getShares(id);

            for (uint256 i; i < actors.length;) {
                (uint256[] memory userShares, uint256[] memory userWeighted, uint256 claimedShares,) =
                    pot.getUsr(id, actors[i]);

                uint256 entitlement;
                if (status == ST_CANCELLED) {
                    for (uint8 o = 1; o <= outcomes;) {
                        entitlement += userShares[o];
                        unchecked {
                            ++o;
                        }
                    }
                } else if (winner > 0 && winner <= outcomes && totalWeighted[winner] > 0) {
                    entitlement = Math.mulDiv(userWeighted[winner], poolShares, totalWeighted[winner]);
                }

                assertLe(claimedShares, entitlement, "user claimed shares exceed entitlement");

                unchecked {
                    ++i;
                }
            }

            unchecked {
                ++id;
            }
        }
    }

    function invariant_shareConservationAcrossWinnersWithinRoundingBound() public view {
        uint256 count = pot.counter();
        for (uint256 id = 1; id < count;) {
            (,,,,,, uint8 outcomes, uint8 winner,,,) = pot.getMkt(id);
            if (winner == 0 || winner > outcomes) {
                unchecked {
                    ++id;
                }
                continue;
            }

            (, uint256[] memory totalWeighted, uint256 poolShares,,) = pot.getShares(id);
            uint256 totalWinnerWeighted = totalWeighted[winner];
            if (totalWinnerWeighted == 0 || poolShares == 0) {
                unchecked {
                    ++id;
                }
                continue;
            }

            uint256 summedEntitlement;
            uint256 winnerUsers;

            for (uint256 i; i < actors.length;) {
                (, uint256[] memory userWeighted,,) = pot.getUsr(id, actors[i]);
                uint256 uw = userWeighted[winner];
                if (uw > 0) {
                    summedEntitlement += Math.mulDiv(uw, poolShares, totalWinnerWeighted);
                    winnerUsers++;
                }
                unchecked {
                    ++i;
                }
            }

            assertLe(summedEntitlement, poolShares, "summed winner entitlement exceeds pool shares");
            if (winnerUsers > 0) {
                uint256 roundingDust = poolShares - summedEntitlement;
                assertLe(roundingDust, winnerUsers, "rounding dust exceeded per-user bound");
            }

            unchecked {
                ++id;
            }
        }
    }

    function invariant_accountedSharesTrackMarketAndConfirmShares() public view {
        uint256 count = pot.counter();
        uint256 trackedShares;
        for (uint256 id = 1; id < count;) {
            (uint256 totalShares, uint256 claimedShares, uint256 confirmShares) = pot.getMktTotals(id);
            if (totalShares > claimedShares) {
                trackedShares += totalShares - claimedShares;
            }
            trackedShares += confirmShares;

            unchecked {
                ++id;
            }
        }

        assertEq(pot.accountedShares(), trackedShares, "accounted shares mismatch tracked market+confirm shares");
        assertGe(wrapper.balanceOf(address(pot)), pot.accountedShares(), "vault share balance below accounted shares");
    }

    function invariant_poolHealthMatchesShareCoverageModel() public view {
        uint256 count = pot.counter();
        for (uint256 id = 1; id < count;) {
            (,, uint256 totalShares, uint256 claimedShares,) = pot.getShares(id);
            uint256 remainingShares = totalShares > claimedShares ? totalShares - claimedShares : 0;

            (uint256 assets, uint256 principal, bool healthy) = viewsLens.getPoolHealth(id);
            assertEq(assets, wrapper.convertToAssets(remainingShares), "pool health assets mismatch share conversion");

            if (principal == 0) {
                assertTrue(healthy, "principal=0 market should always be healthy");
            } else {
                bool expectedHealthy;
                try wrapper.previewWithdraw(principal) returns (uint256 requiredShares) {
                    if (remainingShares >= requiredShares) {
                        expectedHealthy = true;
                    } else {
                        expectedHealthy = _isReserveCoveringShortfall(principal, assets);
                    }
                } catch {
                    if (assets >= principal) {
                        expectedHealthy = true;
                    } else {
                        expectedHealthy = _isReserveCoveringShortfall(principal, assets);
                    }
                }

                assertEq(healthy, expectedHealthy, "pool health bool mismatch reserve-aware model");
            }

            unchecked {
                ++id;
            }
        }
    }

    function _isReserveCoveringShortfall(uint256 principal, uint256 assets) internal view returns (bool) {
        if (assets >= principal) return true;
        uint256 shortfall = principal - assets;
        return shortfall <= pot.MAX_ROUNDING_TOPUP_ASSETS() && pot.reserveAssets() >= shortfall;
    }
}
