// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {yPot} from "../../src/yPot.sol";
import {YearnWrapper} from "../../src/YearnWrapper.sol";

/// @title Adversary
/// @notice Attacker contract for adversarial testing of yPot.
/// @dev Implement your exploit in `executeAttack()`. The test harness will:
///   1. Deploy the full yPot stack (USDC, vault, wrapper, pot, oracles)
///   2. Seed realistic market state (open markets, bets, reported markets, etc.)
///   3. Fund this contract with USDC
///   4. Call `executeAttack()`
///   5. Measure whether the attacker profited beyond what they were given
///
/// Rules:
///   - You may call ANY public/external function on any deployed contract.
///   - You may create helper contracts from within this one.
///   - You may manipulate time via the test harness (see Adversary.t.sol).
///   - You may NOT use vm cheatcodes from within this contract.
///   - Goal: end up with more USDC than you started with.
contract Adversary {
    yPot public immutable pot;
    IERC20 public immutable usdc;
    YearnWrapper public immutable wrapper;

    address public immutable owner;

    error NotOwner();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // Configurable attack parameters (set by the test harness).
    uint256 public attackMarketId;
    uint8 public attackOutcome;
    uint256 public betAssets;
    uint8 public step;

    constructor(address _pot, address _usdc, address _wrapper) {
        pot = yPot(payable(_pot));
        usdc = IERC20(_usdc);
        wrapper = YearnWrapper(_wrapper);
        owner = msg.sender;

        // max-approve pot so we can bet/report/confirm/etc
        usdc.approve(_pot, type(uint256).max);
    }

    function configureAttack(uint256 marketId, uint8 outcome, uint256 assetsToBet) external onlyOwner {
        attackMarketId = marketId;
        attackOutcome = outcome;
        betAssets = assetsToBet;
        step = 0;
    }

    /// @notice Implement your exploit here.
    /// @dev This is called by the test harness after seeding market state.
    /// The contract already holds USDC. Try to end up with more than you started with.
    function executeAttack() external {
        if (attackMarketId == 0 || attackOutcome == 0) return;

        uint256 id = attackMarketId;
        uint8 o = attackOutcome;

        // Step 0: enter the market (bet) while it's still open.
        if (step == 0) {
            (,, uint64 created, uint64 deadline,,,,, uint8 status,,) = pot.getMkt(id);
            if (created == 0 || status != 0) return; // ST_OPEN
            if (block.timestamp > deadline) return;
            if (betAssets == 0 || usdc.balanceOf(address(this)) < betAssets) return;

            try pot.bet(id, o, betAssets, 0, block.timestamp + 60) {
                step = 1;
            } catch {}
            return;
        }

        // Step 1: close + report once resolution time is reached.
        if (step == 1) {
            (,, uint64 created, uint64 deadline,,,,, uint8 status,,) = pot.getMkt(id);
            if (created == 0) return;

            if (status == 0) {
                if (block.timestamp <= deadline) return;
                try pot.close(id) {}
                catch {
                    return;
                }
            }

            (,,,, uint64 rt,,,, uint8 st,,) = pot.getMkt(id);
            if (st != 1) return; // ST_CLOSED
            if (block.timestamp < rt) return;

            try pot.report(id, o) {
                step = 2;
            } catch {}
            return;
        }

        // Step 2: deposit confirmation bond until required confirmation is met.
        if (step == 2) {
            (,,,,,,,, uint8 st,,) = pot.getMkt(id);
            if (st != 5) return; // ST_REPORTED

            (,,,,, address challenger,,) = pot.getReport(id);
            if (challenger != address(0)) return;

            (, uint256 confirmTot, uint256 required) = pot.getConfirm(id, address(this));
            if (confirmTot >= required) {
                step = 3;
                return;
            }

            uint256 sharesNeeded = required - confirmTot;
            uint256 assetsIn = wrapper.previewMint(sharesNeeded) + 1; // tiny buffer for rounding
            if (usdc.balanceOf(address(this)) < assetsIn) return;

            try pot.confirmReport(id, assetsIn, 0, block.timestamp + 60) {
                step = 3;
            } catch {}
            return;
        }

        // Step 3: accept report after the challenge window.
        if (step == 3) {
            (,,,,,,,, uint8 st,,) = pot.getMkt(id);
            if (st != 5) return; // ST_REPORTED

            (,,, uint64 reportedAt,, address challenger,,) = pot.getReport(id);
            if (challenger != address(0)) return;
            if (block.timestamp <= uint256(reportedAt) + 48 hours) return;

            (, uint256 confirmTot, uint256 required) = pot.getConfirm(id, address(this));
            if (confirmTot < required) return;

            try pot.acceptReport(id) {
                step = 4;
            } catch {}
            return;
        }

        // Step 4: finalize after the dispute period.
        if (step == 4) {
            (,,,,, uint64 resolved,,, uint8 st,,) = pot.getMkt(id);
            if (st != 2) return; // ST_RESOLVED
            if (block.timestamp < uint256(resolved) + 24 hours) return;

            try pot.finalize(id) {
                step = 5;
            } catch {}
            return;
        }

        // Step 5: claim winnings + withdraw confirmation bond.
        if (step == 5) {
            (,,,,,,,, uint8 st,,) = pot.getMkt(id);
            if (st != 3) return; // ST_CLAIMABLE

            // Don't revert the whole call if we can't claim yet (e.g. no winning shares).
            try pot.claim(id, 0, 0) {} catch {}
            try pot.withdrawConfirmBond(id, 0, 0) {} catch {}

            step = 6;
            return;
        }

        // =====================================================================
        // YOUR EXPLOIT GOES HERE
        // =====================================================================
        //
        // Attack surface ideas (non-exhaustive):
        //
        // 1. SHARE ROUNDING: Can you exploit mulDiv rounding in claim() to
        //    extract more shares than entitled? Especially with many small
        //    partial claims vs one full claim.
        //
        // 2. TIME-WEIGHT GAMING: Can you bet at a timestamp that produces
        //    disproportionate weight? Edge cases around deadline boundaries.
        //
        // 3. CONFIRMATION MANIPULATION: Can you confirm your own report with
        //    minimal capital and extract the confirmation bond + report bond?
        //
        // 4. VAULT RATE MANIPULATION: If you can move the vault exchange rate
        //    (deposit/withdraw large amounts), can you cause claim() to
        //    over-pay or under-pay specific users?
        //
        // 5. GRIEF ATTACKS: Can you permanently lock funds? DOS finalize/claim?
        //    Force a market into an unrecoverable state?
        //
        // 6. FEE EXTRACTION: Can you manipulate yield fee calculations to
        //    route fees to yourself? Creator fee? Truth bounty?
        //
        // 7. REENTRANCY: Even with ReentrancyGuard, are there cross-function
        //    reentrancy paths? Callbacks from vault operations?
        //
        // 8. EMERGENCY WITHDRAW: Can you get shares back from a cancelled
        //    market AND claim from a resolved market for the same position?
        //
        // 9. ORACLE MANIPULATION: If you control an oracle address, can you
        //    vote + claim in ways that extract value?
        //
        // 10. DUST SWEEP: Can you manipulate sweepDust or sweepExcessVaultShares
        //     to extract value that belongs to other users?
        //
        // =====================================================================
    }

    /// @notice Convenience: withdraw all USDC back to owner (for measuring profit)
    function withdraw() external {
        bool ok = usdc.transfer(owner, usdc.balanceOf(address(this)));
        if (!ok) revert TransferFailed();
    }

    /// @notice Allow receiving ETH (in case needed for some attack path)
    receive() external payable {}
}
