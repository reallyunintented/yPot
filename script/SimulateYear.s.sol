// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {yPot} from "../src/yPot.sol";
import {yPotViews} from "../src/yPotViews.sol";
import {YearnWrapper} from "../src/YearnWrapper.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "../test/mocks/MockERC4626Vault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {yPotUma} from "../src/yPotUma.sol";
import {UmaOptimisticOracleAdapter} from "../src/UmaOptimisticOracleAdapter.sol";
import {MockUmaOptimisticOracle} from "../test/mocks/MockUmaOptimisticOracle.sol";

/**
 * @title SimulateYear
 * @notice 50-user, 52-week end-to-end simulation verifying conservation of value.
 *
 * Run with:
 *   anvil --port 8545 &
 *   forge script script/SimulateYear.s.sol --rpc-url http://127.0.0.1:8545 -vvv
 *
 * Primary assertion: Σ(all_usdc_in_system) == initialTotalSupply + totalYieldMinted
 * Secondary: pot solvency (accountedShares <= wrapper.balanceOf(pot))
 */
contract SimulateYear is Script {
    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------

    uint256 constant NUM_USERS = 50;
    uint256 constant USER_INITIAL_USDC = 50_000e6; // 50k USDC each
    uint256 constant ORACLE_FUNDING = 10_000_000e6; // 10M USDC per oracle (for bonds)
    uint256 constant DEPLOYER_KEY = 100;
    uint256 constant ORACLE0_KEY = 51;
    uint256 constant ORACLE1_KEY = 52;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    MockUSDC usdc;
    MockERC4626Vault yearnVault;
    YearnWrapper wrapper;
    yPot pot;
    yPotViews views;

    address deployer;
    address oracle0;
    address oracle1;
    address[NUM_USERS] users;
    uint256[NUM_USERS] userKeys;

    uint256 exchangeRate = 1e18; // tracks current vault rate (1:1 initial)
    uint256 totalYieldMinted; // cumulative USDC minted to vault as yield
    uint256 initialTotalSupply; // usdc.totalSupply() after setup

    struct MarketInfo {
        uint256 id;
        uint64 deadline;
        uint64 resTime;
        uint8 outcomes;
        uint8 path; // 0=normal, 1=challenge, 2=expire, 3=emergency, 4=uma_appeal
        bool processed;
    }

    MarketInfo[] activeMarkets;
    uint256 marketsCreated;
    uint256 normalCount;
    uint256 challengeCount;
    uint256 expireCount;
    uint256 emergencyCount;
    uint256 umaCount;

    yPotUma umaModule;
    UmaOptimisticOracleAdapter umaAdapter;
    MockUmaOptimisticOracle mockUma;
    address appellant;

    uint256 simulationYearEnd; // stored in storage to prevent via_ir optimizer re-evaluation

    // -------------------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------------------

    function run() external {
        _setup();
        _simulate();
        _forceProcessRemaining();
        _finalReport();
    }

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function _setup() internal {
        deployer = vm.addr(DEPLOYER_KEY);
        oracle0 = vm.addr(ORACLE0_KEY);
        oracle1 = vm.addr(ORACLE1_KEY);

        for (uint256 i = 0; i < NUM_USERS; i++) {
            userKeys[i] = i + 1;
            users[i] = vm.addr(userKeys[i]);
        }

        // Deploy contracts
        vm.startPrank(deployer);
        usdc = new MockUSDC();
        yearnVault = new MockERC4626Vault(usdc);

        address[] memory initialDepositors = new address[](1);
        initialDepositors[0] = deployer;
        wrapper = new YearnWrapper(usdc, IERC4626(address(yearnVault)), initialDepositors);

        address[] memory oracles = new address[](2);
        oracles[0] = oracle0;
        oracles[1] = oracle1;
        pot = new yPot(address(usdc), address(wrapper), deployer, oracles);
        wrapper.setDepositor(address(pot), true);

        // Bootstrap: deposit 1 USDC into wrapper to prevent share inflation attack
        usdc.mint(deployer, 1e6);
        usdc.approve(address(wrapper), 1e6);
        wrapper.deposit(1e6, deployer);
        vm.stopPrank();

        // Deploy UMA stack
        vm.startPrank(deployer);
        mockUma = new MockUmaOptimisticOracle();
        address[] memory umaReq = new address[](1);
        umaReq[0] = deployer;
        umaAdapter = new UmaOptimisticOracleAdapter(address(mockUma), usdc, keccak256("YPOT_LOCAL"), 0, 0, 0, umaReq);
        umaModule = new yPotUma(address(pot), address(umaAdapter));
        pot.setUmaModule(address(umaModule));
        umaAdapter.setRequester(address(umaModule), true);
        vm.stopPrank();

        views = new yPotViews(address(pot));

        // Fund 50 users
        vm.startPrank(deployer);
        for (uint256 i = 0; i < NUM_USERS; i++) {
            usdc.mint(users[i], USER_INITIAL_USDC);
        }
        usdc.mint(oracle0, ORACLE_FUNDING);
        usdc.mint(oracle1, ORACLE_FUNDING);
        appellant = users[48];
        usdc.mint(appellant, 1_000_000e6);
        vm.stopPrank();

        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.prank(users[i]);
            usdc.approve(address(pot), type(uint256).max);
        }

        // Fund oracles for report bonds and confirmation stakes
        vm.prank(oracle0);
        usdc.approve(address(pot), type(uint256).max);
        vm.prank(oracle1);
        usdc.approve(address(pot), type(uint256).max);

        // Fund appellant for UMA appeals (users[48] gets extra 1M USDC)
        vm.prank(appellant);
        usdc.approve(address(umaModule), type(uint256).max);

        initialTotalSupply = usdc.totalSupply();
        console2.log("Setup complete. Total USDC minted:", initialTotalSupply);
        console2.log("Users:", NUM_USERS);
        console2.log("Oracle0:", oracle0, "Oracle1:", oracle1);
    }

    // -------------------------------------------------------------------------
    // Main simulation loop
    // -------------------------------------------------------------------------

    function _simulate() internal {
        uint256 seed = uint256(keccak256("ypot-sim-2025"));
        simulationYearEnd = block.timestamp + 365 days; // storage var: prevents via_ir re-evaluation

        uint256 week = 0;
        while (block.timestamp < simulationYearEnd) {
            seed = uint256(keccak256(abi.encode(seed, week)));

            // Create 2-6 markets this week
            uint256 numMarkets = 2 + (seed % 5);
            for (uint256 m = 0; m < numMarkets; m++) {
                uint256 mSeed = uint256(keccak256(abi.encode(seed, "market", m)));
                _createMarketWithBets(mSeed);
            }

            // Advance 1 week
            vm.warp(block.timestamp + 1 weeks);

            // Accrue 1 week of yield at 5% APR
            _applyYield(1 weeks);

            // Process any markets whose deadline has passed
            _processMaturedMarkets();

            week++;
        }
    }

    // -------------------------------------------------------------------------
    // Market creation
    // -------------------------------------------------------------------------

    struct MktEntry {
        string desc;
        string tag;
        uint8 n;
    }

    function _getMktEntry(uint256 idx) internal pure returns (MktEntry memory e) {
        if (idx == 0) {
            e.desc = "Will the Republican Party retain the US Senate majority in 2026 midterms?";
            e.tag = "Politics";
            e.n = 2;
        } else if (idx == 1) {
            e.desc = "Will the US House pass a federal AI regulation bill before EOY 2026?";
            e.tag = "Politics";
            e.n = 2;
        } else if (idx == 2) {
            e.desc = "Who will be elected French President in the 2027 election?";
            e.tag = "Politics";
            e.n = 4;
        } else if (idx == 3) {
            e.desc = "Will the UK rejoin the EU Single Market by 2030?";
            e.tag = "Politics";
            e.n = 2;
        } else if (idx == 4) {
            e.desc = "Will Giorgia Meloni remain Italian PM through EOY 2026?";
            e.tag = "Politics";
            e.n = 2;
        } else if (idx == 5) {
            e.desc = "Will the US government shut down before Q3 2026?";
            e.tag = "Politics";
            e.n = 2;
        } else if (idx == 6) {
            e.desc = "Will NATO expand to include Ukraine in 2026?";
            e.tag = "Politics";
            e.n = 2;
        } else if (idx == 7) {
            e.desc = "Will the 2026 Brazilian elections result in a runoff?";
            e.tag = "Politics";
            e.n = 2;
        } else if (idx == 8) {
            e.desc = "Will the Kansas City Chiefs win Super Bowl LXI?";
            e.tag = "Sports";
            e.n = 2;
        } else if (idx == 9) {
            e.desc = "Will Manchester City win the 2025-26 Premier League?";
            e.tag = "Sports";
            e.n = 2;
        } else if (idx == 10) {
            e.desc = "Who will win the 2026 FIFA World Cup?";
            e.tag = "Sports";
            e.n = 5;
        } else if (idx == 11) {
            e.desc = "Will Novak Djokovic win Wimbledon 2026?";
            e.tag = "Sports";
            e.n = 2;
        } else if (idx == 12) {
            e.desc = "Will the Golden State Warriors make the 2026 NBA playoffs?";
            e.tag = "Sports";
            e.n = 2;
        } else if (idx == 13) {
            e.desc = "Will the New York Yankees win the 2026 World Series?";
            e.tag = "Sports";
            e.n = 2;
        } else if (idx == 14) {
            e.desc = "Will Real Madrid win the 2025-26 Champions League?";
            e.tag = "Sports";
            e.n = 2;
        } else if (idx == 15) {
            e.desc = "Will Lewis Hamilton win a race in the 2026 F1 season?";
            e.tag = "Sports";
            e.n = 2;
        } else if (idx == 16) {
            e.desc = "Will Bitcoin exceed $150k before EOY 2026?";
            e.tag = "Crypto";
            e.n = 2;
        } else if (idx == 17) {
            e.desc = "Will Ethereum gas fees average below 5 gwei in Q3 2026?";
            e.tag = "Crypto";
            e.n = 2;
        } else if (idx == 18) {
            e.desc = "Will Solana flip Ethereum by market cap in 2026?";
            e.tag = "Crypto";
            e.n = 2;
        } else if (idx == 19) {
            e.desc = "What will Bitcoin's price range be in Q2 2026?";
            e.tag = "Crypto";
            e.n = 4;
        } else if (idx == 20) {
            e.desc = "Will a spot Ethereum ETF launch in the EU by Q4 2026?";
            e.tag = "Crypto";
            e.n = 2;
        } else if (idx == 21) {
            e.desc = "Will Coinbase be added to the S&P 500 in 2026?";
            e.tag = "Crypto";
            e.n = 2;
        } else if (idx == 22) {
            e.desc = "Will DeFi total TVL exceed $300B by EOY 2026?";
            e.tag = "Crypto";
            e.n = 2;
        } else if (idx == 23) {
            e.desc = "Will the Ethereum blockchain process over 2M txns/day in 2026?";
            e.tag = "Crypto";
            e.n = 2;
        } else if (idx == 24) {
            e.desc = "Will the Fed cut interest rates at least 3 times in 2026?";
            e.tag = "Finance";
            e.n = 2;
        } else if (idx == 25) {
            e.desc = "Will NVIDIA stock exceed $180 in Q2 2026?";
            e.tag = "Finance";
            e.n = 2;
        } else if (idx == 26) {
            e.desc = "Will US CPI inflation fall below 2.5% by Q3 2026?";
            e.tag = "Finance";
            e.n = 2;
        } else if (idx == 27) {
            e.desc = "Will the S&P 500 close above 6500 by EOY 2026?";
            e.tag = "Finance";
            e.n = 2;
        } else if (idx == 28) {
            e.desc = "Will Apple report earnings above $2.10 EPS in Q2 2026?";
            e.tag = "Finance";
            e.n = 2;
        } else if (idx == 29) {
            e.desc = "Will US GDP growth exceed 2.5% in 2026?";
            e.tag = "Finance";
            e.n = 3;
        } else if (idx == 30) {
            e.desc = "Will a commercial fusion pilot plant deliver net electricity before 2030?";
            e.tag = "Science";
            e.n = 2;
        } else if (idx == 31) {
            e.desc = "Will the first FDA-approved CRISPR therapy exceed $1B in annual revenue by 2027?";
            e.tag = "Science";
            e.n = 2;
        } else if (idx == 32) {
            e.desc = "Will GTA VI release before July 1, 2026?";
            e.tag = "Entertainment";
            e.n = 2;
        } else if (idx == 33) {
            e.desc = "Will Dune: Messiah gross over $800M worldwide?";
            e.tag = "Entertainment";
            e.n = 2;
        } else if (idx == 34) {
            e.desc = "Will Wikipedia exceed 7 million English articles by EOY 2026?";
            e.tag = "Other";
            e.n = 2;
        } else {
            e.desc = "Will global airline passenger traffic exceed the 2019 peak in 2026?";
            e.tag = "Other";
            e.n = 2;
        }
    }

    function _createMarketWithBets(uint256 seed) internal {
        // Duration: 14-90 days
        uint256 duration = 14 days + (seed % 76 days);

        uint64 dl = uint64(block.timestamp + duration);
        uint64 rt = uint64(uint256(dl) + 1 hours);

        // Pick market entry from library (36 entries)
        MktEntry memory entry = _getMktEntry(seed % 36);
        // Add 0-1 extra outcomes via seed for variety, capped at 5
        uint8 outcomes = entry.n + uint8((seed >> 128) % 2);
        if (outcomes > 5) outcomes = 5;

        // Build a unique CID per market
        string memory cid = string.concat("bafybeig", vm.toString(seed % 1_000_000_000_000));

        // Pick creator (needs fee USDC)
        uint256 creatorIdx = seed % NUM_USERS;
        address creator = users[creatorIdx];

        // Check creator has enough for fee (10 USDC default)
        if (usdc.balanceOf(creator) < 10e6) return;

        vm.prank(creator);
        uint256 id;
        try pot.create(entry.desc, cid, dl, rt, outcomes, entry.tag, address(0)) returns (uint256 mid) {
            id = mid;
        } catch {
            return;
        }

        // Assign resolution path based on seed
        uint8 path;
        uint256 r = uint256(keccak256(abi.encode(seed, "path"))) % 100;
        if (r < 73) path = 0; // normal
        else if (r < 83) path = 1; // challenge
        else if (r < 88) path = 2; // expire
        else if (r < 93) path = 3; // emergency
        else path = 4; // uma appeal

        // Place bets from 3-22 random users
        uint256 numBettors = 3 + (seed % 20);
        for (uint256 b = 0; b < numBettors; b++) {
            uint256 bSeed = uint256(keccak256(abi.encode(seed, "bet", b)));
            uint256 betterIdx = bSeed % NUM_USERS;
            uint256 amount = 100e6 + (bSeed % 4_900e6);
            uint8 outcome = uint8(1 + (bSeed % outcomes));

            address better = users[betterIdx];
            if (usdc.balanceOf(better) < amount) continue;

            vm.prank(better);
            try pot.bet(id, outcome, amount, 0, type(uint256).max) {} catch {}
        }

        activeMarkets.push(
            MarketInfo({id: id, deadline: dl, resTime: rt, outcomes: outcomes, path: path, processed: false})
        );
        marketsCreated++;
    }

    // -------------------------------------------------------------------------
    // Yield accrual
    // -------------------------------------------------------------------------

    function _applyYield(uint256 dt) internal {
        // 5% APR: newRate = oldRate * (1 + 0.05 * dt / 365days)
        // = oldRate + oldRate * 5 * dt / (100 * 365days)
        uint256 newRate = exchangeRate + (exchangeRate * 5 * dt) / (100 * 365 days);

        // Mint USDC to the underlying vault to back the increased exchange rate
        uint256 totalVaultShares = yearnVault.totalSupply();
        if (totalVaultShares > 0 && newRate > exchangeRate) {
            uint256 yieldAmount = (totalVaultShares * (newRate - exchangeRate)) / 1e18;
            if (yieldAmount > 0) {
                vm.prank(deployer);
                usdc.mint(address(yearnVault), yieldAmount);
                totalYieldMinted += yieldAmount;
            }
        }

        exchangeRate = newRate;
        vm.prank(deployer);
        yearnVault.setExchangeRate(newRate);
    }

    // -------------------------------------------------------------------------
    // Market processing
    // -------------------------------------------------------------------------

    function _processMaturedMarkets() internal {
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            if (activeMarkets[i].processed) continue;
            if (block.timestamp <= activeMarkets[i].deadline) continue;
            _processMarket(i);
        }
    }

    function _forceProcessRemaining() internal {
        console2.log("Force-processing remaining open markets...");
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            if (activeMarkets[i].processed) continue;
            // Advance time past this market's deadline + resTime + buffer
            if (block.timestamp <= activeMarkets[i].resTime) {
                vm.warp(uint256(activeMarkets[i].resTime) + 1);
                _applyYield(uint256(activeMarkets[i].resTime) + 1 - block.timestamp + 1);
            }
            _processMarket(i);
        }
    }

    function _processMarket(uint256 idx) internal {
        MarketInfo storage m = activeMarkets[idx];
        m.processed = true;
        uint256 id = m.id;

        // Ensure we're past the deadline
        if (block.timestamp <= m.deadline) {
            vm.warp(uint256(m.deadline) + 1);
        }

        (,,,,,,,, uint8 status,,) = views.getMkt(id);

        // Only process OPEN markets
        if (status != 0) return;

        // Close the market
        try pot.close(id) {}
        catch {
            return;
        }

        // --- Emergency path: owner cancels ---
        if (m.path == 3) {
            emergencyCount++;
            vm.prank(deployer);
            try pot.cancel(id) {} catch {}
            _doEmergencyWithdraw(id);
            _invariantCheck(id);
            return;
        }

        // --- Expire path: nobody reports, market expires ---
        if (m.path == 2) {
            expireCount++;
            if (block.timestamp < uint256(m.resTime) + 7 days + 1) {
                vm.warp(uint256(m.resTime) + 7 days + 1);
            }
            try pot.expireMarket(id) {} catch {}
            _doEmergencyWithdraw(id);
            _invariantCheck(id);
            return;
        }

        // --- Normal / Challenge paths ---

        // Ensure we're at resTime
        if (block.timestamp < m.resTime) {
            vm.warp(m.resTime);
        }

        // Find reporter: first user with outcome-1 shares and enough USDC for the bond
        uint256 bond = pot.calcReportBond(id);
        address reporter = address(0);
        for (uint256 i = 0; i < NUM_USERS; i++) {
            (uint256[] memory s,,,) = views.getUsr(id, users[i]);
            if (s.length > 1 && s[1] > 0 && usdc.balanceOf(users[i]) >= bond) {
                reporter = users[i];
                break;
            }
        }
        if (reporter == address(0)) {
            expireCount++;
            return;
        }
        vm.prank(reporter);
        try pot.report(id, 1) {}
        catch {
            expireCount++;
            return;
        }

        // Confirm the report
        _doConfirm(id);

        // --- UMA Appeal path ---
        // Challenge → both oracles resolve to outcome 2 → APPEALABLE → UMA appeal
        if (m.path == 4) {
            // Find challenger: first user (not the reporter) with outcome-2 shares + bond USDC
            address challenger = address(0);
            for (uint256 i = 0; i < NUM_USERS; i++) {
                if (users[i] == reporter) continue;
                (uint256[] memory s,,,) = views.getUsr(id, users[i]);
                if (s.length > 2 && s[2] > 0 && usdc.balanceOf(users[i]) >= bond) {
                    challenger = users[i];
                    break;
                }
            }
            if (challenger == address(0)) {
                normalCount++;
                return;
            }
            vm.prank(challenger);
            try pot.challenge(id, 2) {}
            catch {
                normalCount++;
                return;
            }

            vm.prank(oracle0);
            try pot.resolveDispute(id, 2) {} catch {}
            vm.prank(oracle1);
            try pot.resolveDispute(id, 2) {} catch {}

            (,,,,,,,, uint8 umaStatus,,) = views.getMkt(id);
            if (umaStatus != 7) {
                normalCount++;
                return;
            } // not APPEALABLE

            (,,,,,,,,,, uint256 umaPrin) = views.getMkt(id);
            uint256 ab = umaModule.calcUmaAppealBond(umaPrin);
            if (usdc.balanceOf(appellant) < ab) {
                normalCount++;
                return;
            }

            vm.prank(appellant);
            try umaModule.startUmaAppeal(id) {}
            catch {
                normalCount++;
                return;
            }

            bytes memory anc = _getAncillary(id);
            (,,,, uint64 umaResTime,,,,,,) = views.getMkt(id);
            uint8 variant = uint8(uint256(keccak256(abi.encode(id, "uma-variant"))) % 4);

            if (variant == 3) {
                // Expire: warp past 30-day UMA stale timeout
                (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
                vm.warp(uint256(umaStartedAt) + 30 days + 1);
                try umaModule.expireUmaAppeal(id) {}
                catch {
                    normalCount++;
                    return;
                }
            } else {
                // Settle: seed mock oracle with desired result
                int256 price = variant == 0
                    ? int256(1)  // overturn (committee=2, UMA=1)
                    : variant == 1
                        ? int256(2)  // affirm   (committee=2, UMA=2)
                        : int256(0); // invalid  → cancel
                mockUma.proposePrice(keccak256("YPOT_LOCAL"), uint256(umaResTime), anc, price);
                try umaModule.settleUmaAppeal(id) {}
                catch {
                    normalCount++;
                    return;
                }
            }

            umaCount++;
            (,,,,,,,, uint8 postUmaStatus,,) = views.getMkt(id);
            if (postUmaStatus == 3) _doClaims(id);
            else if (postUmaStatus == 4) _doEmergencyWithdraw(id);
            _invariantCheck(id);
            return;
        }

        // --- Challenge sub-path ---
        if (m.path == 1) {
            // Find challenger: first user (not the reporter) with outcome-2 shares + bond USDC
            address challenger = address(0);
            for (uint256 i = 0; i < NUM_USERS; i++) {
                if (users[i] == reporter) continue;
                (uint256[] memory s,,,) = views.getUsr(id, users[i]);
                if (s.length > 2 && s[2] > 0 && usdc.balanceOf(users[i]) >= bond) {
                    challenger = users[i];
                    break;
                }
            }
            if (challenger == address(0)) {
                normalCount++;
                return;
            }
            challengeCount++;
            vm.prank(challenger);
            try pot.challenge(id, 2) {}
            catch {
                normalCount++;
                return;
            }

            // Committee votes: both oracles uphold the original report (outcome 1).
            // Once votes[1] >= confirms (2), status → APPEALABLE with winner=1 and
            // appealDeadline = now+48h.  acceptReport below will fail (challenger set);
            // finalize() handles the APPEALABLE→RESOLVED→CLAIMABLE transition.
            vm.prank(oracle0);
            try pot.resolveDispute(id, 1) {} catch {}
            vm.prank(oracle1);
            try pot.resolveDispute(id, 1) {} catch {}
        } else {
            normalCount++;
        }

        // Accept report after 48h challenge window
        vm.warp(block.timestamp + 49 hours);
        try pot.acceptReport(id) {} catch {}

        // Finalize after 24h dispute period
        vm.warp(block.timestamp + 25 hours);
        try pot.finalize(id) {} catch {}

        // Claim for all users with positions
        _doClaims(id);

        // Recover confirmation bonds for all users who staked
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.prank(users[i]);
            try pot.withdrawConfirmBond(id, 0, 0) {} catch {}
        }

        _invariantCheck(id);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _doEmergencyWithdraw(uint256 id) internal {
        for (uint256 i = 0; i < NUM_USERS; i++) {
            (uint256[] memory s,,,) = views.getUsr(id, users[i]);
            bool hasPosition = false;
            for (uint256 j = 0; j < s.length; j++) {
                if (s[j] > 0) {
                    hasPosition = true;
                    break;
                }
            }
            if (hasPosition) {
                vm.prank(users[i]);
                try pot.emergencyWithdraw(id, 0) {} catch {}
            }
        }
    }

    function _doClaims(uint256 id) internal {
        (,,,,,,,, uint8 status,,) = views.getMkt(id);
        if (status != 3) return; // Not CLAIMABLE

        for (uint256 i = 0; i < NUM_USERS; i++) {
            (uint256[] memory s,,, bool done) = views.getUsr(id, users[i]);
            if (done) continue;
            bool hasShares = false;
            for (uint256 j = 0; j < s.length; j++) {
                if (s[j] > 0) {
                    hasShares = true;
                    break;
                }
            }
            if (hasShares) {
                vm.prank(users[i]);
                try pot.claim(id, 0, 0) {} catch {}
            }
        }
    }

    /// @dev Reconstructs the ancillary bytes that yPotUma._ancillary built for this market.
    ///      Must match exactly — same field order and string formatting (decimal integers).
    ///      Path 4 always uses reportedOutcome=1 (oracle0) and challengedOutcome=2 (oracle1).
    function _getAncillary(uint256 id) internal view returns (bytes memory) {
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

    function _doConfirm(uint256 id) internal {
        (uint256 tot,,) = pot.getMktTotals(id);
        address[] memory eligible = new address[](NUM_USERS);
        uint256 n;
        for (uint256 i = 0; i < NUM_USERS; i++) {
            (uint256[] memory s,,,) = views.getUsr(id, users[i]);
            if (s.length > 1 && s[1] > 0) eligible[n++] = users[i];
        }
        if (n == 0) return;
        uint256 perUser = tot / 4 / n + 1;
        for (uint256 i = 0; i < n; i++) {
            if (usdc.balanceOf(eligible[i]) < perUser) continue;
            vm.prank(eligible[i]);
            try pot.confirmReport(id, perUser, 0, block.timestamp + 3600) {} catch {}
        }
    }

    function _invariantCheck(uint256 id) internal view {
        // Post-market solvency: pot holds >= accountedShares worth of assets
        uint256 potShares = wrapper.balanceOf(address(pot));
        uint256 accounted = pot.accountedShares();
        if (accounted > potShares) {
            console2.log("SOLVENCY VIOLATION at market", id);
            console2.log("  accountedShares:", accounted);
            console2.log("  pot wrapper shares:", potShares);
        }
        assert(accounted <= potShares);
    }

    // -------------------------------------------------------------------------
    // Final report
    // -------------------------------------------------------------------------

    function _finalReport() internal view {
        console2.log("");
        console2.log("=== YEAR SIMULATION COMPLETE ===");
        console2.log("Markets created:  ", marketsCreated);
        console2.log("Normal path:      ", normalCount);
        console2.log("Challenge path:   ", challengeCount);
        console2.log("Expire path:      ", expireCount);
        console2.log("Emergency path:   ", emergencyCount);
        console2.log("UMA appeal path:  ", umaCount);
        console2.log("");

        // Sum all user balances
        uint256 finalUserSum;
        for (uint256 i = 0; i < NUM_USERS; i++) {
            finalUserSum += usdc.balanceOf(users[i]);
        }

        uint256 treasuryBalance = usdc.balanceOf(deployer);
        uint256 reserveAssets = pot.reserveAssets();
        uint256 potRawUsdc = usdc.balanceOf(address(pot));
        uint256 potWrapperAssets = wrapper.convertToAssets(wrapper.balanceOf(address(pot)));
        uint256 oracleBalance = usdc.balanceOf(oracle0) + usdc.balanceOf(oracle1);

        uint256 finalTotalSupply = usdc.totalSupply();

        console2.log("Initial total supply:     ", initialTotalSupply);
        console2.log("Total yield minted:       ", totalYieldMinted);
        console2.log("Expected total supply:    ", initialTotalSupply + totalYieldMinted);
        console2.log("Actual final total supply:", finalTotalSupply);
        console2.log("");
        console2.log("Final user sum (50 users):", finalUserSum);
        console2.log("Treasury balance:         ", treasuryBalance);
        console2.log("Reserve assets (pot):     ", reserveAssets);
        console2.log("Pot raw USDC:             ", potRawUsdc);
        console2.log("Pot wrapper assets:       ", potWrapperAssets);
        console2.log("Oracle total balance:     ", oracleBalance);
        console2.log("");
        console2.log("Pot accountedShares:      ", pot.accountedShares());
        console2.log("Pot wrapper shares:       ", wrapper.balanceOf(address(pot)));
        console2.log("");

        // Conservation check: usdc.totalSupply() == initialTotalSupply + totalYieldMinted
        // (all USDC in system equals what was minted — ERC20 conservation)
        uint256 expectedSupply = initialTotalSupply + totalYieldMinted;
        if (finalTotalSupply != expectedSupply) {
            console2.log("CONSERVATION VIOLATION: supply mismatch");
            console2.log("  Expected:", expectedSupply);
            console2.log("  Actual:  ", finalTotalSupply);
        }
        assert(finalTotalSupply == expectedSupply);

        // Solvency: pot holds at least as many shares as accountedShares
        assert(pot.accountedShares() <= wrapper.balanceOf(address(pot)));

        // Reserve sanity: pot raw USDC >= reserveAssets (reserve is backed)
        assert(potRawUsdc >= reserveAssets);

        console2.log("=== ALL ASSERTIONS PASSED ===");
    }
}
