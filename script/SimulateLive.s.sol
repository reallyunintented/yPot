// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {yPot} from "../src/yPot.sol";
import {yPotViews} from "../src/yPotViews.sol";
import {yPotUma} from "../src/yPotUma.sol";
import {YearnWrapper} from "../src/YearnWrapper.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "../test/mocks/MockERC4626Vault.sol";
import {MockUmaOptimisticOracle} from "../test/mocks/MockUmaOptimisticOracle.sol";

/**
 * @title SimulateLive
 * @notice Broadcast-mode weekly runner for live frontend time-lapse.
 *
 * Each invocation broadcasts real transactions to Anvil so the subgraph
 * indexes them and the frontend shows live market activity.
 *
 * Run via sim-live.sh which loops over weeks:
 *   SIM_SPEED=1 bash scripts/sim-live.sh
 *
 * Required env vars (written by deploy-anvil.sh via anvil.json):
 *   YPOT_ADDR, ASSET_ADDR, VAULT_ADDR, YEARNVAULT_ADDR, YPOTVIEWS_ADDR
 *   UMAMODULE_ADDR, UMAOPTIMISTICORACLE_ADDR  (zero-address if no UMA)
 *
 * Anvil default private keys (local dev only — never use on mainnet):
 *   Account 0: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
 *   Account 1: 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
 *   Account 2: 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
 *   Account 3: 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
 *
 * deploy-anvil.sh sets ORACLE_0=Account0addr and ORACLE_1=Account1addr by default.
 */
contract SimulateLive is Script {
    string internal constant DEFAULT_ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    // Anvil default private keys — local dev only
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant ORACLE1_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint32 constant BETTOR_START_INDEX = 2;
    uint256 constant BETTOR_COUNT = 6;
    uint32 constant REPORTER_A_INDEX = 8;
    uint32 constant REPORTER_B_INDEX = 9;

    yPot pot;
    yPotViews views;
    yPotUma umaModule;
    MockUSDC usdc;
    MockERC4626Vault yearnVault;
    YearnWrapper wrapper;
    MockUmaOptimisticOracle mockUma;

    bool hasUma;

    // -------------------------------------------------------------------------
    // Entry points (called by sim-live.sh with Anvil time advanced between phases)
    // -------------------------------------------------------------------------

    /// @notice Phase 1: fund (week 1 only) + apply yield + create markets + close/report mature ones.
    ///         Call after advancing Anvil time by SIM_DAYS (e.g. 15 days).
    function weekPhase1(uint256 weekNum) external {
        _setup();
        if (weekNum == 1) _fundActors();
        _applyYield();

        uint256 createUntilWeek = vm.envOr("SIM_CREATE_UNTIL_WEEK", type(uint256).max);
        if (weekNum <= createUntilWeek) {
            uint256 seed = uint256(keccak256(abi.encode("sim-live", weekNum)));
            uint256 numMarkets = 2 + (seed % 3);
            for (uint256 m = 0; m < numMarkets; m++) {
                _createMarket(uint256(keccak256(abi.encode(seed, m))));
            }
        }

        _closeAndReport();
    }

    /// @notice Phase 2: accept unchallenged reports + resolve disputed ones.
    ///         Call after advancing Anvil time by 49h (past CHALLENGE_WINDOW).
    function weekPhase2(uint256 weekNum) external {
        _setup();
        _acceptAndResolve();
    }

    /// @notice Phase 3: finalize resolved/appealable markets + claim + expire stale closed.
    ///         Call after advancing Anvil time by 25h (past DISPUTE_PERIOD).
    function weekPhase3(uint256 weekNum) external {
        _setup();
        _finalizeAndClaim();
    }

    function _setup() internal {
        pot = yPot(payable(vm.envAddress("YPOT_ADDR")));
        usdc = MockUSDC(vm.envAddress("ASSET_ADDR"));
        wrapper = YearnWrapper(vm.envAddress("VAULT_ADDR"));
        yearnVault = MockERC4626Vault(vm.envAddress("YEARNVAULT_ADDR"));
        views = yPotViews(vm.envAddress("YPOTVIEWS_ADDR"));

        address umaMod = vm.envOr("UMAMODULE_ADDR", address(0));
        address umaOO = vm.envOr("UMAOPTIMISTICORACLE_ADDR", address(0));
        hasUma = (umaMod != address(0) && umaOO != address(0));
        if (hasUma) {
            umaModule = yPotUma(umaMod);
            mockUma = MockUmaOptimisticOracle(umaOO);
        }
    }

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function _fundActors() internal {
        vm.startBroadcast(DEPLOYER_KEY);
        for (uint256 i = 0; i < BETTOR_COUNT; i++) {
            usdc.mint(_bettor(i), 2_500_000e6);
        }
        usdc.mint(_reporterA(), 5_000_000e6);
        usdc.mint(_reporterB(), 5_000_000e6);
        usdc.mint(vm.addr(DEPLOYER_KEY), 10_000_000e6); // oracle0 bonds
        usdc.mint(vm.addr(ORACLE1_KEY), 10_000_000e6); // oracle1 bonds
        vm.stopBroadcast();

        for (uint256 i = 0; i < BETTOR_COUNT; i++) {
            vm.startBroadcast(_bettorKey(i));
            usdc.approve(address(pot), type(uint256).max);
            vm.stopBroadcast();
        }

        vm.startBroadcast(DEPLOYER_KEY);
        usdc.approve(address(pot), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(ORACLE1_KEY);
        usdc.approve(address(pot), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(_reporterAKey());
        usdc.approve(address(pot), type(uint256).max);
        if (hasUma) usdc.approve(address(umaModule), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(_reporterBKey());
        usdc.approve(address(pot), type(uint256).max);
        if (hasUma) usdc.approve(address(umaModule), type(uint256).max);
        vm.stopBroadcast();
    }

    // -------------------------------------------------------------------------
    // Yield
    // -------------------------------------------------------------------------

    function _applyYield() internal {
        uint256 currentRate = yearnVault.convertToAssets(1e18);
        uint256 newRate = currentRate + (currentRate * 5 * 7 days) / (100 * 365 days);
        uint256 totalShares = yearnVault.totalSupply();

        vm.startBroadcast(DEPLOYER_KEY);
        if (totalShares > 0 && newRate > currentRate) {
            uint256 yieldAmt = (totalShares * (newRate - currentRate)) / 1e18;
            if (yieldAmt > 0) usdc.mint(address(yearnVault), yieldAmt);
        }
        yearnVault.setExchangeRate(newRate);
        vm.stopBroadcast();
    }

    // -------------------------------------------------------------------------
    // Market creation
    // -------------------------------------------------------------------------

    function _getMktEntry(uint256 idx) internal pure returns (string memory desc, string memory tag, uint8 n) {
        if (idx == 0) {
            desc = "Will the Republican Party retain the US Senate majority in 2026 midterms?";
            tag = "Politics";
            n = 2;
        } else if (idx == 1) {
            desc = "Will the US House pass a federal AI regulation bill before EOY 2026?";
            tag = "Politics";
            n = 2;
        } else if (idx == 2) {
            desc = "Who will be elected French President in the 2027 election?";
            tag = "Politics";
            n = 4;
        } else if (idx == 3) {
            desc = "Will the UK rejoin the EU Single Market by 2030?";
            tag = "Politics";
            n = 2;
        } else if (idx == 4) {
            desc = "Will Giorgia Meloni remain Italian PM through EOY 2026?";
            tag = "Politics";
            n = 2;
        } else if (idx == 5) {
            desc = "Will the US government shut down before Q3 2026?";
            tag = "Politics";
            n = 2;
        } else if (idx == 6) {
            desc = "Will NATO expand to include Ukraine in 2026?";
            tag = "Politics";
            n = 2;
        } else if (idx == 7) {
            desc = "Will the 2026 Brazilian elections result in a runoff?";
            tag = "Politics";
            n = 2;
        } else if (idx == 8) {
            desc = "Will the Kansas City Chiefs win Super Bowl LXI?";
            tag = "Sports";
            n = 2;
        } else if (idx == 9) {
            desc = "Will Manchester City win the 2025-26 Premier League?";
            tag = "Sports";
            n = 2;
        } else if (idx == 10) {
            desc = "Who will win the 2026 FIFA World Cup?";
            tag = "Sports";
            n = 5;
        } else if (idx == 11) {
            desc = "Will Novak Djokovic win Wimbledon 2026?";
            tag = "Sports";
            n = 2;
        } else if (idx == 12) {
            desc = "Will the Golden State Warriors make the 2026 NBA playoffs?";
            tag = "Sports";
            n = 2;
        } else if (idx == 13) {
            desc = "Will the New York Yankees win the 2026 World Series?";
            tag = "Sports";
            n = 2;
        } else if (idx == 14) {
            desc = "Will Real Madrid win the 2025-26 Champions League?";
            tag = "Sports";
            n = 2;
        } else if (idx == 15) {
            desc = "Will Lewis Hamilton win a race in the 2026 F1 season?";
            tag = "Sports";
            n = 2;
        } else if (idx == 16) {
            desc = "Will Bitcoin exceed $150k before EOY 2026?";
            tag = "Crypto";
            n = 2;
        } else if (idx == 17) {
            desc = "Will Ethereum gas fees average below 5 gwei in Q3 2026?";
            tag = "Crypto";
            n = 2;
        } else if (idx == 18) {
            desc = "Will Solana flip Ethereum by market cap in 2026?";
            tag = "Crypto";
            n = 2;
        } else if (idx == 19) {
            desc = "What will Bitcoin's price range be in Q2 2026?";
            tag = "Crypto";
            n = 4;
        } else if (idx == 20) {
            desc = "Will a spot Ethereum ETF launch in the EU by Q4 2026?";
            tag = "Crypto";
            n = 2;
        } else if (idx == 21) {
            desc = "Will Coinbase be added to the S&P 500 in 2026?";
            tag = "Crypto";
            n = 2;
        } else if (idx == 22) {
            desc = "Will DeFi total TVL exceed $300B by EOY 2026?";
            tag = "Crypto";
            n = 2;
        } else if (idx == 23) {
            desc = "Will the Ethereum blockchain process over 2M txns/day in 2026?";
            tag = "Crypto";
            n = 2;
        } else if (idx == 24) {
            desc = "Will the Fed cut interest rates at least 3 times in 2026?";
            tag = "Finance";
            n = 2;
        } else if (idx == 25) {
            desc = "Will NVIDIA stock exceed $180 in Q2 2026?";
            tag = "Finance";
            n = 2;
        } else if (idx == 26) {
            desc = "Will US CPI inflation fall below 2.5% by Q3 2026?";
            tag = "Finance";
            n = 2;
        } else if (idx == 27) {
            desc = "Will the S&P 500 close above 6500 by EOY 2026?";
            tag = "Finance";
            n = 2;
        } else if (idx == 28) {
            desc = "Will Apple report earnings above $2.10 EPS in Q2 2026?";
            tag = "Finance";
            n = 2;
        } else if (idx == 29) {
            desc = "Will US GDP growth exceed 2.5% in 2026?";
            tag = "Finance";
            n = 3;
        } else if (idx == 30) {
            desc = "Will a commercial fusion pilot plant deliver net electricity before 2030?";
            tag = "Science";
            n = 2;
        } else if (idx == 31) {
            desc = "Will the first FDA-approved CRISPR therapy exceed $1B in annual revenue by 2027?";
            tag = "Science";
            n = 2;
        } else if (idx == 32) {
            desc = "Will GTA VI release before July 1, 2026?";
            tag = "Entertainment";
            n = 2;
        } else if (idx == 33) {
            desc = "Will Dune: Messiah gross over $800M worldwide?";
            tag = "Entertainment";
            n = 2;
        } else if (idx == 34) {
            desc = "Will Wikipedia exceed 7 million English articles by EOY 2026?";
            tag = "Other";
            n = 2;
        } else {
            desc = "Will global airline passenger traffic exceed the 2019 peak in 2026?";
            tag = "Other";
            n = 2;
        }
    }

    function _createMarket(uint256 seed) internal {
        uint256 creatorIdx = seed % BETTOR_COUNT;
        uint256 creatorKey = _bettorKey(creatorIdx);
        address creator = vm.addr(creatorKey);
        if (usdc.balanceOf(creator) < 50e6) return;

        (string memory desc, string memory tag, uint8 baseN) = _getMktEntry(seed % 36);
        uint8 outcomes = baseN + uint8((seed >> 128) % 2);
        if (outcomes > 5) outcomes = 5;
        uint64 dl = uint64(block.timestamp + 14 days + ((seed >> 8) % 21 days));
        uint64 rt = uint64(dl + 6 hours + ((seed >> 40) % 3 days));
        string memory cid = string.concat("bafybeig", vm.toString(seed % 1_000_000_000_000));

        uint256 id;
        vm.broadcast(creatorKey);
        try pot.create(desc, cid, dl, rt, outcomes, tag, address(0)) returns (uint256 mid) {
            id = mid;
        } catch {
            return;
        }

        _placeBet(creatorKey, id, 1, 300e6 + (seed % 900e6));

        uint256 bettorAIdx = (creatorIdx + 1 + ((seed >> 64) % (BETTOR_COUNT - 1))) % BETTOR_COUNT;
        if (bettorAIdx == creatorIdx) bettorAIdx = (creatorIdx + 1) % BETTOR_COUNT;
        _placeBet(_bettorKey(bettorAIdx), id, outcomes > 1 ? 2 : 1, 180e6 + ((seed >> 16) % 700e6));

        uint256 bettorBIdx = (creatorIdx + 2 + ((seed >> 96) % (BETTOR_COUNT - 1))) % BETTOR_COUNT;
        if (bettorBIdx == creatorIdx) bettorBIdx = (creatorIdx + 2) % BETTOR_COUNT;
        uint8 bettorBOutcome =
            outcomes > 2 ? uint8(3 + ((seed >> 24) % (outcomes - 2))) : uint8(1 + ((seed >> 24) % outcomes));
        _placeBet(_bettorKey(bettorBIdx), id, bettorBOutcome, 100e6 + ((seed >> 32) % 450e6));

        uint256 extraBets = 2 + ((seed >> 144) % 4);
        for (uint256 i = 0; i < extraBets; i++) {
            uint256 actorIdx = (creatorIdx + 3 + i + ((seed >> (160 + i * 8)) % BETTOR_COUNT)) % BETTOR_COUNT;
            uint256 actorKey = _bettorKey(actorIdx);
            uint256 r = uint256(keccak256(abi.encode(seed, "bet", i))) % 100;
            uint8 outcome;
            if (r < 55) {
                outcome = 1;
            } else if (r < 85) {
                outcome = outcomes > 1 ? 2 : 1;
            } else {
                outcome = uint8(1 + (uint256(keccak256(abi.encode(seed, "outcome", i))) % outcomes));
            }
            uint256 amount = 75e6 + (uint256(keccak256(abi.encode(seed, "amount", i))) % 525e6);
            _placeBet(actorKey, id, outcome, amount);
        }
    }

    // -------------------------------------------------------------------------
    // Phase helpers
    // -------------------------------------------------------------------------

    /// @dev Returns the resolution path for a market (deterministic from id).
    ///      0=normal, 1=challenge+commit, 2=expire, 3=emergency-cancel, 4=UMA
    function _getPath(uint256 id) internal view returns (uint8 path) {
        uint256 r = uint256(keccak256(abi.encode("path", id))) % 100;
        if (r < 73) path = 0;
        else if (r < 83) path = 1;
        else if (r < 88) path = 2;
        else if (r < 93) path = 3;
        else path = 4;
        if (path == 4 && !hasUma) path = 0;
    }

    /// @dev Phase 1: close mature OPEN markets and report/challenge them.
    ///      Expire-path markets are left CLOSED for _finalizeAndClaim to expireMarket.
    function _closeAndReport() internal {
        uint256 nextId = pot.counter();
        for (uint256 id = 1; id < nextId; id++) {
            (,,, uint64 dl, uint64 rt,,,, uint8 status,,) = views.getMkt(id);
            if (status != 0) continue; // not OPEN
            if (block.timestamp <= dl) continue; // not yet matured

            uint8 path = _getPath(id);

            vm.broadcast(DEPLOYER_KEY);
            try pot.close(id) {}
                catch {
                continue;
            }

            if (path == 3) {
                vm.broadcast(DEPLOYER_KEY);
                try pot.cancel(id) {} catch {}
                continue;
            }

            if (path == 2) continue; // expire path: leave CLOSED, expireMarket in phase3

            if (block.timestamp < rt) continue; // not past resTime yet

            uint256 reporterKey = _reporterKey(id);
            vm.broadcast(reporterKey);
            try pot.report(id, 1) {}
                catch {
                continue;
            }

            if (_shouldConfirmReport(id)) {
                _fundReportConfirmations(id);
            }

            if (path == 1 || path == 4) {
                uint256 challengerKey = _challengeKey(id);
                if (challengerKey != 0) {
                    vm.broadcast(challengerKey);
                    try pot.challenge(id, 2) {} catch {}
                }
            }
        }
    }

    /// @dev Phase 2: accept unchallenged reports + resolve challenged ones.
    ///      Called after bash advances Anvil past CHALLENGE_WINDOW (48h+1h).
    function _acceptAndResolve() internal {
        uint256 nextId = pot.counter();
        for (uint256 id = 1; id < nextId; id++) {
            (,,, uint64 dl,,,,, uint8 status,,) = views.getMkt(id);
            if (status != 5) continue; // not REPORTED

            (,,, uint64 reportedAt, uint16 confirmBpsSnapshot, address challenger,,) = pot.getReport(id);

            if (challenger == address(0)) {
                // No challenge — accept if past challenge window AND confirmation met
                if (block.timestamp > uint256(reportedAt) + 48 hours) {
                    (uint256 tot,, uint256 confirmTot) = pot.getMktTotals(id);
                    uint256 required = (tot * uint256(confirmBpsSnapshot)) / 10_000;
                    if (confirmTot >= required) {
                        vm.broadcast(DEPLOYER_KEY);
                        pot.acceptReport(id);
                    }
                }
            } else {
                uint8 path = _getPath(id);
                if (path == 1) {
                    uint8 committeeOutcome = _committeeOutcome(id, false);
                    vm.broadcast(DEPLOYER_KEY);
                    try pot.resolveDispute(id, committeeOutcome) {} catch {}
                    vm.broadcast(ORACLE1_KEY);
                    try pot.resolveDispute(id, committeeOutcome) {} catch {}
                } else {
                    uint8 committeeOutcome = _committeeOutcome(id, true);
                    vm.broadcast(DEPLOYER_KEY);
                    try pot.resolveDispute(id, committeeOutcome) {} catch {}
                    vm.broadcast(ORACLE1_KEY);
                    try pot.resolveDispute(id, committeeOutcome) {} catch {}

                    if (hasUma) {
                        (,,,,,,,, uint8 s,,) = views.getMkt(id);
                        if (s == 7) {
                            (,,,,,,,,,, uint256 prin) = views.getMkt(id);
                            address appellant = vm.addr(_appellantKey(id));
                            uint256 ab = umaModule.calcUmaAppealBond(prin);
                            if (usdc.balanceOf(appellant) >= ab) {
                                vm.broadcast(_appellantKey(id));
                                try umaModule.startUmaAppeal(id) {} catch {}

                                (,,,,,,,, uint8 s2,,) = views.getMkt(id);
                                if (s2 == 8) {
                                    (,,,, uint64 resTime,,,,,,) = views.getMkt(id);
                                    bytes memory anc = _buildAncillary(id);
                                    int256 umaWinner = _umaOutcome(id);
                                    vm.broadcast(DEPLOYER_KEY);
                                    mockUma.proposePrice(keccak256("YPOT_LOCAL"), uint256(resTime), anc, umaWinner);
                                    vm.broadcast(DEPLOYER_KEY);
                                    try umaModule.settleUmaAppeal(id) {} catch {}
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// @dev Phase 3: finalize RESOLVED/APPEALABLE markets, claim for user, expire stale CLOSED.
    ///      Called after bash advances Anvil past DISPUTE_PERIOD (24h+1h).
    ///      Note: APPEALABLE markets need 48h appeal window + 24h dispute = 72h after resolveDispute.
    ///      Those that aren't ready yet will be finalized in the next week's phase3.
    function _finalizeAndClaim() internal {
        uint256 nextId = pot.counter();
        for (uint256 id = 1; id < nextId; id++) {
            (,,, uint64 dl, uint64 rt,,,, uint8 status,,) = views.getMkt(id);

            if (status == 2) {
                // RESOLVED: finalize if past DISPUTE_PERIOD
                (,,,,, uint64 resolved,,,,,) = views.getMkt(id);
                if (block.timestamp >= uint256(resolved) + 24 hours) {
                    vm.broadcast(DEPLOYER_KEY);
                    try pot.finalize(id) {} catch {}
                }
            } else if (status == 7) {
                // APPEALABLE: finalize if past appeal deadline
                (uint64 appealDeadline,,,) = pot.getAppealInfo(id);
                if (block.timestamp > uint256(appealDeadline)) {
                    vm.broadcast(DEPLOYER_KEY);
                    try pot.finalize(id) {} catch {}
                }
            }

            // Re-read status after potential finalize
            (,,,,,,,, uint8 newStatus,,) = views.getMkt(id);

            if (newStatus == 3) {
                // CLAIMABLE
                _claimForAllBettors(id);
            }

            if (status == 1) {
                // CLOSED expire-path: no report was filed
                if (_getPath(id) == 2 && block.timestamp > uint256(rt) + 7 days) {
                    vm.broadcast(DEPLOYER_KEY);
                    try pot.expireMarket(id) {} catch {}
                }
            }

            // Expire unconfirmed reports that are past CHALLENGE_WINDOW + CONFIRM_TIMEOUT (96h)
            if (status == 5) {
                // REPORTED
                (,,, uint64 reportedAt, uint16 cbps, address chlgr,,) = pot.getReport(id);
                if (chlgr == address(0)) {
                    (uint256 t,, uint256 ct) = pot.getMktTotals(id);
                    uint256 req = (t * uint256(cbps)) / 10_000;
                    if (ct < req && block.timestamp > uint256(reportedAt) + 96 hours) {
                        vm.broadcast(DEPLOYER_KEY);
                        try pot.expireUnconfirmedReport(id) {} catch {}
                    }
                }
            }

            _withdrawConfirmations(id);
            _withdrawCancelled(id);

            (
                string memory _desc,
                string memory _cid,
                uint64 _created,
                uint64 _deadline,
                uint64 _resTime,
                uint64 resolvedAfter,
                uint8 _outcomes,
                uint8 _winner,
                uint8 statusAfter,
                address _creator,
                uint256 _prin
            ) = views.getMkt(id);
            _desc;
            _cid;
            _created;
            _deadline;
            _resTime;
            _outcomes;
            _winner;
            _creator;
            _prin;
            if (statusAfter == 3 && block.timestamp >= uint256(resolvedAfter) + 31 days) {
                vm.broadcast(DEPLOYER_KEY);
                try pot.sweepDust(id, 0) {} catch {}
            }
        }

        vm.broadcast(DEPLOYER_KEY);
        try pot.sweepExcessVaultShares(0, 0) {} catch {}
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Reconstructs ancillary bytes matching yPotUma._ancillary exactly.
    ///      Path 4 always uses reportedOutcome=1 (oracle0) and challengedOutcome=2 (oracle1).
    function _buildAncillary(uint256 id) internal view returns (bytes memory) {
        (string memory desc,,,, uint64 resTime,, uint8 outcomes, uint8 committeeWinner,,,) = views.getMkt(id);
        string memory prefix = string.concat(
            "yPot market #",
            vm.toString(id),
            " on chain ",
            vm.toString(block.chainid),
            " | Resolution timestamp: ",
            vm.toString(uint256(resTime)),
            ": ",
            desc
        );
        string memory outcomesChunk = string.concat(
            " | Committee winner: ",
            vm.toString(uint256(committeeWinner)),
            " | Reported outcome: 1",
            " | Challenged outcome: 2"
        );
        return bytes(
            string.concat(
                prefix,
                outcomesChunk,
                " | Valid outcomes: 1-",
                vm.toString(uint256(outcomes)),
                " | Return the winning outcome number."
            )
        );
    }

    function _placeBet(uint256 actorKey, uint256 id, uint8 outcome, uint256 amount) internal {
        address actor = vm.addr(actorKey);
        uint256 bal = usdc.balanceOf(actor);
        if (bal < 10e6) return;
        if (amount > bal) amount = bal;
        if (amount < 10e6) return;

        vm.broadcast(actorKey);
        try pot.bet(id, outcome, amount, 0, type(uint256).max) {} catch {}
    }

    function _fundReportConfirmations(uint256 id) internal {
        (, uint256 totalConfirmShares, uint256 requiredConfirmShares) = views.getConfirm(id, _bettor(0));
        uint256 target = requiredConfirmShares + (requiredConfirmShares / 20) + 5e6;
        if (target < 25e6) target = 25e6;
        if (totalConfirmShares >= target) return;

        for (uint256 i = 0; i < BETTOR_COUNT && totalConfirmShares < target; i++) {
            address actor = _bettor(i);
            (uint256[] memory shares,,,) = views.getUsr(id, actor);
            if (shares.length <= 1 || shares[1] == 0) continue;

            (uint256 userConfirmShares,,) = views.getConfirm(id, actor);
            uint256 maxAssets = (shares[1] * 5) - userConfirmShares;
            if (maxAssets == 0) continue;

            uint256 needed = target - totalConfirmShares;
            uint256 tranche = 40e6 + ((uint256(keccak256(abi.encode(id, actor))) % 220e6));
            uint256 assetsIn = needed < tranche ? needed : tranche;
            if (assetsIn > maxAssets) assetsIn = maxAssets;
            if (assetsIn == 0 || usdc.balanceOf(actor) < assetsIn) continue;

            vm.broadcast(_bettorKey(i));
            try pot.confirmReport(id, assetsIn, 0, type(uint256).max) {} catch {}
            (, totalConfirmShares,) = views.getConfirm(id, actor);
        }
    }

    function _claimForAllBettors(uint256 id) internal {
        for (uint256 i = 0; i < BETTOR_COUNT; i++) {
            address actor = _bettor(i);
            (uint256[] memory shares,,, bool done) = views.getUsr(id, actor);
            if (done) continue;
            for (uint256 j = 1; j < shares.length; j++) {
                if (shares[j] == 0) continue;
                vm.broadcast(_bettorKey(i));
                try pot.claim(id, 0, 0) {} catch {}
                break;
            }
        }
    }

    function _withdrawConfirmations(uint256 id) internal {
        for (uint256 i = 0; i < BETTOR_COUNT; i++) {
            address actor = _bettor(i);
            (uint256 userConfirmShares,,) = views.getConfirm(id, actor);
            if (userConfirmShares == 0) continue;
            vm.broadcast(_bettorKey(i));
            try pot.withdrawConfirmBond(id, 0, 0) {} catch {}
        }
    }

    function _withdrawCancelled(uint256 id) internal {
        (,,,,,,,, uint8 status,,) = views.getMkt(id);
        if (status != 4) return;

        for (uint256 i = 0; i < BETTOR_COUNT; i++) {
            address actor = _bettor(i);
            (uint256[] memory shares,,, bool done) = views.getUsr(id, actor);
            if (done) continue;
            uint256 exposure;
            for (uint256 j = 1; j < shares.length; j++) {
                exposure += shares[j];
            }
            if (exposure == 0) continue;
            vm.broadcast(_bettorKey(i));
            try pot.emergencyWithdraw(id, 0) {} catch {}
        }
    }

    function _shouldConfirmReport(uint256 id) internal pure returns (bool) {
        return id % 9 != 0;
    }

    function _committeeOutcome(uint256 id, bool isUmaPath) internal pure returns (uint8) {
        if (isUmaPath) return 2;
        return id % 4 == 0 ? 2 : 1;
    }

    function _umaOutcome(uint256 id) internal pure returns (int256) {
        return id % 3 == 0 ? int256(2) : int256(1);
    }

    function _reporterKey(uint256 id) internal returns (uint256) {
        return id % 2 == 0 ? _reporterAKey() : _reporterBKey();
    }

    function _challengeKey(uint256 id) internal returns (uint256) {
        for (uint256 i = 0; i < BETTOR_COUNT; i++) {
            address actor = _bettor(i);
            (uint256[] memory shares,,,) = views.getUsr(id, actor);
            if (shares.length > 2 && shares[2] > 0) {
                return _bettorKey(i);
            }
        }
        return 0;
    }

    function _appellantKey(uint256 id) internal returns (uint256) {
        return id % 2 == 0 ? _reporterAKey() : _reporterBKey();
    }

    function _bettor(uint256 idx) internal returns (address) {
        return vm.addr(_bettorKey(idx));
    }

    function _bettorKey(uint256 idx) internal returns (uint256) {
        return vm.deriveKey(DEFAULT_ANVIL_MNEMONIC, uint32(BETTOR_START_INDEX + idx));
    }

    function _reporterA() internal returns (address) {
        return vm.addr(_reporterAKey());
    }

    function _reporterAKey() internal returns (uint256) {
        return vm.deriveKey(DEFAULT_ANVIL_MNEMONIC, REPORTER_A_INDEX);
    }

    function _reporterB() internal returns (address) {
        return vm.addr(_reporterBKey());
    }

    function _reporterBKey() internal returns (uint256) {
        return vm.deriveKey(DEFAULT_ANVIL_MNEMONIC, REPORTER_B_INDEX);
    }
}
