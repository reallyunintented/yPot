// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {YPotLib} from "./yPotLib.sol";

interface IyPotCoreViews {
    function counter() external view returns (uint256);

    function vault() external view returns (IERC4626);
    function confirmBps() external view returns (uint256);
    function minReportBond() external view returns (uint256);
    function reserveAssets() external view returns (uint256);
    function MAX_ROUNDING_TOPUP_ASSETS() external view returns (uint256);

    function getMkt(uint256 id)
        external
        view
        returns (
            string memory desc,
            string memory cid,
            uint64 created,
            uint64 deadline,
            uint64 resTime,
            uint64 resolved,
            uint8 outcomes,
            uint8 winner,
            uint8 status,
            address creator,
            uint256 prin
        );

    function getMktTotals(uint256 id) external view returns (uint256 tot, uint256 claimed, uint256 confirmTot);

    function getAppealInfo(uint256 id)
        external
        view
        returns (uint64 appealDeadline, uint64 umaStartedAt, address umaAppellant, uint256 umaAppealBond);

    function getDisputeMode(uint256 id) external view returns (uint8);

    function getReport(uint256 id)
        external
        view
        returns (
            address reporter,
            uint8 outcome,
            uint256 bond,
            uint64 reportedAt,
            uint16 confirmBpsSnapshot,
            address challenger,
            uint8 challengeOutcome,
            uint256 challengeBond
        );

    function getConfirm(uint256 id, address u)
        external
        view
        returns (uint256 userConfirmShares, uint256 totalConfirmShares, uint256 requiredConfirmShares);

    function getShares(uint256 id)
        external
        view
        returns (
            uint256[] memory shares,
            uint256[] memory weightedShares,
            uint256 totalShares,
            uint256 claimedShares,
            uint256 remainingShares
        );

    function getUsr(uint256 id, address u)
        external
        view
        returns (uint256[] memory s, uint256[] memory w, uint256 c, bool d);

    function calcReportBond(uint256 id) external view returns (uint256);
}

/**
 * @title yPotViews
 * @notice Off-chain lens for yPot, aggregating views for convenience.
 */
contract yPotViews {
    uint256 private constant BPS = 10_000;
    uint256 private constant YIELD_FEE_BPS = 500;
    uint256 private constant UMA_APPEAL_BOND_BPS = 500;
    uint256 private constant MIN_UMA_APPEAL_BOND = 50e6;

    IyPotCoreViews public immutable pot;

    /// @param pot_ Address of the yPot contract to read from.
    constructor(address pot_) {
        pot = IyPotCoreViews(pot_);
    }

    // -------------------------------------------------------------------------
    // Pass-through views (just delegate to core)
    // -------------------------------------------------------------------------

    /// @notice Returns core market metadata and state.
    /// @param id Market identifier.
    function getMkt(uint256 id)
        external
        view
        returns (
            string memory desc,
            string memory cid,
            uint64 created,
            uint64 deadline,
            uint64 resTime,
            uint64 resolved,
            uint8 outcomes,
            uint8 winner,
            uint8 status,
            address creator,
            uint256 prin
        )
    {
        return pot.getMkt(id);
    }

    /// @notice Returns UMA appeal metadata for a market.
    /// @param id Market identifier.
    function getAppealInfo(uint256 id)
        external
        view
        returns (uint64 appealDeadline, uint64 umaStartedAt, address umaAppellant, uint256 umaAppealBond)
    {
        return pot.getAppealInfo(id);
    }

    /// @notice Returns reporter/challenger bond state for a market.
    /// @param id Market identifier.
    function getReport(uint256 id)
        external
        view
        returns (
            address reporter,
            uint8 outcome,
            uint256 bond,
            uint64 reportedAt,
            uint16 confirmBpsSnapshot,
            address challenger,
            uint8 challengeOutcome,
            uint256 challengeBond
        )
    {
        return pot.getReport(id);
    }

    /// @notice Returns dispute mode for a market.
    /// @param id Market identifier.
    function getDisputeMode(uint256 id) external view returns (uint8) {
        return pot.getDisputeMode(id);
    }

    /// @notice Returns per-outcome share vectors and totals for a market.
    /// @param id Market identifier.
    function getShares(uint256 id)
        external
        view
        returns (
            uint256[] memory shares,
            uint256[] memory weightedShares,
            uint256 totalShares,
            uint256 claimedShares,
            uint256 remainingShares
        )
    {
        return pot.getShares(id);
    }

    /// @notice Returns user share vectors and claim status for a market.
    /// @param id Market identifier.
    /// @param u User address.
    function getUsr(uint256 id, address u)
        external
        view
        returns (uint256[] memory s, uint256[] memory w, uint256 c, bool d)
    {
        return pot.getUsr(id, u);
    }

    /// @notice Returns estimated asset coverage versus remaining principal.
    /// @param id Market identifier.
    function getPoolHealth(uint256 id) external view returns (uint256 assets, uint256 principal, bool healthy) {
        return _poolHealth(id);
    }

    /// @notice Returns aggregate pool health across all created markets.
    /// @return assets Current estimated assets backing outstanding market liabilities.
    /// @return principal Current outstanding principal liabilities across markets.
    /// @return unrealizedYield Current surplus assets over principal liabilities.
    /// @return unhealthyMarkets Number of markets currently undercollateralized beyond reserve tolerance.
    /// @return marketCount Number of created markets included in the aggregation.
    function getProtocolHealth()
        external
        view
        returns (
            uint256 assets,
            uint256 principal,
            uint256 unrealizedYield,
            uint256 unhealthyMarkets,
            uint256 marketCount
        )
    {
        uint256 nextId = pot.counter();
        if (nextId <= 1) {
            return (0, 0, 0, 0, 0);
        }

        marketCount = nextId - 1;
        for (uint256 id = 1; id < nextId; ++id) {
            (uint256 marketAssets, uint256 marketPrincipal, bool healthy) = _poolHealth(id);
            assets += marketAssets;
            principal += marketPrincipal;
            if (!healthy) {
                unhealthyMarkets += 1;
            }
        }

        unrealizedYield = assets > principal ? assets - principal : 0;
    }

    function _poolHealth(uint256 id) internal view returns (uint256 assets, uint256 principal, bool healthy) {
        (uint256 tot, uint256 claimed,) = pot.getMktTotals(id);
        uint256 remaining = tot > claimed ? tot - claimed : 0;

        IERC4626 v = pot.vault();
        assets = remaining > 0 ? v.convertToAssets(remaining) : 0;
        (,,,,,,,,,, uint256 prin) = pot.getMkt(id);
        principal = tot > 0 ? Math.mulDiv(prin, remaining, tot) : 0;

        if (principal == 0) {
            healthy = true;
            return (assets, principal, healthy);
        }

        try v.previewWithdraw(principal) returns (uint256 requiredShares) {
            if (remaining >= requiredShares) {
                healthy = true;
            } else {
                healthy = _isReserveCoveringShortfall(principal, assets);
            }
        } catch {
            if (assets >= principal) {
                healthy = true;
            } else {
                healthy = _isReserveCoveringShortfall(principal, assets);
            }
        }
    }

    function _isReserveCoveringShortfall(uint256 principal, uint256 _assets) internal view returns (bool) {
        if (_assets >= principal) return true;
        uint256 shortfall = principal - _assets;
        return shortfall <= pot.MAX_ROUNDING_TOPUP_ASSETS() && pot.reserveAssets() >= shortfall;
    }

    // -------------------------------------------------------------------------
    // Confirmation Info
    // -------------------------------------------------------------------------

    /// @notice Returns confirmation bond position for a user.
    /// @param id Market identifier.
    /// @param u User address.
    function getConfirm(uint256 id, address u)
        external
        view
        returns (uint256 userConfirmShares, uint256 totalConfirmShares, uint256 requiredConfirmShares)
    {
        return pot.getConfirm(id, u);
    }

    /// @notice Returns confirmation position using the snapshotted threshold from report time.
    /// @param id Market identifier.
    /// @param u User address.
    function getConfirmWithSnapshot(uint256 id, address u)
        external
        view
        returns (
            uint256 userConfirmShares,
            uint256 totalConfirmShares,
            uint256 requiredConfirmShares,
            uint16 snapshotBps
        )
    {
        (userConfirmShares, totalConfirmShares,) = pot.getConfirm(id, u);
        (,,,, snapshotBps,,,) = pot.getReport(id);
        (uint256 tot,,) = pot.getMktTotals(id);
        requiredConfirmShares = YPotLib.requiredConfirm(tot, uint256(snapshotBps));
    }

    // -------------------------------------------------------------------------
    // Bond Calculations
    // -------------------------------------------------------------------------

    /// @notice Returns the report bond requirement for a market.
    /// @param id Market identifier.
    function calcReportBond(uint256 id) external view returns (uint256) {
        return pot.calcReportBond(id);
    }

    /// @notice Returns the estimated UMA appeal bond for a market.
    /// @param id Market identifier.
    function calcUmaAppealBond(uint256 id) external view returns (uint256) {
        (,,,,,,,,,, uint256 prin) = pot.getMkt(id);
        return YPotLib.calcBond(prin, UMA_APPEAL_BOND_BPS, MIN_UMA_APPEAL_BOND);
    }

    // -------------------------------------------------------------------------
    // Claim Preview
    // -------------------------------------------------------------------------

    /// @notice Previews claim payout for a user including yield fee breakdown.
    /// @param id Market identifier.
    /// @param user User address.
    function previewClaim(uint256 id, address user)
        external
        view
        returns (uint256 entitledShares, uint256 estimatedAssets, uint256 estimatedFee, uint256 estimatedPayout)
    {
        (uint8 outcomes, uint8 winner, uint256 prin) = _mktCore(id);
        if (winner == 0 || winner > outcomes) return (0, 0, 0, 0);

        uint256 tot;
        (entitledShares, tot) = _entitledShares(id, user, winner);
        if (entitledShares == 0 || tot == 0) return (0, 0, 0, 0);

        (estimatedAssets, estimatedFee, estimatedPayout) = _quoteAssetsAndFee(entitledShares, prin, tot);
    }

    function _mktCore(uint256 id) internal view returns (uint8 outcomes, uint8 winner, uint256 prin) {
        // getMkt: (desc, cid, created, deadline, resTime, resolved, outcomes, winner, status, creator, prin)
        (,,,,,, outcomes, winner,,, prin) = pot.getMkt(id);
    }

    function _entitledShares(uint256 id, address user, uint8 winner)
        internal
        view
        returns (uint256 entitled, uint256 tot)
    {
        // getUsr: (s, w, c, d)
        (, uint256[] memory w, uint256 claimed,) = pot.getUsr(id, user);
        uint256 uw = w[winner];
        if (uw == 0) return (0, 0);

        // getShares: (shares, weightedShares, totalShares, claimedShares, remainingShares)
        (, uint256[] memory weightedShares, uint256 total,,) = pot.getShares(id);
        tot = total;

        uint256 tw = weightedShares[winner];
        if (tw == 0 || total == 0) return (0, tot);

        uint256 gross = Math.mulDiv(uw, total, tw);
        if (gross <= claimed) return (0, tot);

        entitled = gross - claimed;
    }

    function _quoteAssetsAndFee(uint256 entitled, uint256 prin, uint256 tot)
        internal
        view
        returns (uint256 assets, uint256 fee, uint256 payout)
    {
        assets = pot.vault().convertToAssets(entitled);

        uint256 cp = Math.mulDiv(prin, entitled, tot);
        if (assets > cp) {
            fee = Math.mulDiv(assets - cp, YIELD_FEE_BPS, BPS);
        }
        payout = assets - fee;
    }

    // -------------------------------------------------------------------------
    // Derived / Utility
    // -------------------------------------------------------------------------

    /// @notice Recomputes total shares by summing per-outcome buckets (integrity check).
    /// @param id Market identifier.
    function totalSharesDerived(uint256 id) external view returns (uint256 t) {
        (uint256[] memory shares,,,,) = pot.getShares(id);
        for (uint256 i = 1; i < shares.length;) {
            t += shares[i];
            unchecked {
                ++i;
            }
        }
    }
}
