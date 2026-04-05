// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {YPotLib} from "./yPotLib.sol";

interface IUmaOptimisticOracleAdapter {
    function requestAndProposeWithBond(uint256 ts, bytes memory ancillary, int256 proposedPrice, uint256 bond) external;
    function dispute(uint256 ts, bytes memory ancillary) external;
    function settle(uint256 ts, bytes memory ancillary) external returns (int256 price);
    function withdrawAllTo(uint256 ts, bytes memory ancillary, address to) external returns (uint256 recovered);
}

interface IyPotUmaTarget {
    function asset() external view returns (IERC20);
    function treasury() external view returns (address);
    function disputeRakeBps() external view returns (uint256);

    // Smaller focused views (avoid stack-too-deep)
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

    function umaBeginAppeal(uint256 id, address appellant, uint256 appealBond)
        external
        returns (uint256 rb, uint256 cb, uint64 resTime, uint8 committeeWinner);

    function umaConsumeAppealBond(uint256 id) external returns (address appellant, uint256 bond);
    function umaCreditPending(address recipient, uint256 amount) external;
    function umaResolve(uint256 id, uint8 winner) external;
    function umaCancel(uint256 id) external;
}

/**
 * @title yPotUma
 * @notice External UMA appeal module for yPot.
 * @dev Handles UMA dispute lifecycle without using delegatecall.
 */
contract yPotUma is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 private constant ST_APPEALABLE = 7;
    uint8 private constant ST_UMA_PENDING = 8;
    uint8 private constant DISPUTE_UMA = 1;

    uint256 private constant BPS = 10_000;
    uint256 private constant UMA_APPEAL_BOND_BPS = 500;
    uint256 private constant MIN_UMA_APPEAL_BOND = 50e6;
    uint256 private constant UMA_STALE_TIMEOUT = 30 days;

    error E2(); // InvalidState

    IyPotUmaTarget public immutable pot;
    IERC20 public immutable asset;
    IUmaOptimisticOracleAdapter public immutable umaOracle;

    event UmaAppealStarted(uint256 indexed id, address indexed appellant);
    event UmaDisputeSettled(uint256 indexed id, int256 resolvedPrice);
    event UmaDisputeExpired(uint256 indexed id);
    event DisputeRaked(uint256 indexed id, address indexed loser, uint256 rake);

    struct UmaSettlementContext {
        bytes ancillary;
        uint64 resTime;
        uint8 outcomes;
        uint8 committeeWinner;
        uint8 reportedOutcome;
        uint8 challengedOutcome;
        address reporter;
        address challenger;
        uint256 reportBond;
        uint256 challengeBond;
    }

    struct EscrowedBonds {
        uint256 reportBond;
        uint256 challengeBond;
    }

    struct UmaStartContext {
        string desc;
        uint64 resTime;
        uint8 outcomes;
        uint8 committeeWinner;
        uint8 reportedOutcome;
        uint8 challengedOutcome;
        uint256 principal;
        uint256 reportBond;
        uint256 challengeBond;
    }

    struct UmaReportContext {
        uint8 reportedOutcome;
        uint8 challengedOutcome;
        uint256 reportBond;
        uint256 challengeBond;
        address reporter;
        address challenger;
    }

    mapping(uint256 => EscrowedBonds) private _escrowedBonds;

    /// @notice Deploys the UMA appeal module for a given yPot and oracle adapter.
    /// @param pot_ Address of the yPot contract.
    /// @param umaOracle_ Address of the UMA optimistic oracle adapter.
    constructor(address pot_, address umaOracle_) {
        pot = IyPotUmaTarget(pot_);
        asset = pot.asset();
        umaOracle = IUmaOptimisticOracleAdapter(umaOracle_);
    }

    /// @notice Computes the UMA appeal bond for a given market principal.
    /// @param prin Total principal deposited in the market.
    /// @return Appeal bond amount in asset units.
    function calcUmaAppealBond(uint256 prin) public pure returns (uint256) {
        return YPotLib.calcBond(prin, UMA_APPEAL_BOND_BPS, MIN_UMA_APPEAL_BOND);
    }

    /// @notice Starts a UMA appeal for a market in the appealable state.
    /// @dev Caller must have approved `asset` for the appeal bond amount.
    ///      Transfers reporter and challenger bonds to the UMA oracle adapter.
    /// @param id Market identifier.
    function startUmaAppeal(uint256 id) external nonReentrant {
        UmaStartContext memory ctx = _loadStartContext(id);

        uint256 appealBond = calcUmaAppealBond(ctx.principal);
        asset.safeTransferFrom(msg.sender, address(pot), appealBond);

        (uint256 escrowRb, uint256 escrowCb, uint64 ts, uint8 proposed) = pot.umaBeginAppeal(id, msg.sender, appealBond);
        if (
            escrowRb != ctx.reportBond || escrowCb != ctx.challengeBond || ts != ctx.resTime
                || proposed != ctx.committeeWinner
        ) revert E2();
        _escrowedBonds[id] = EscrowedBonds({reportBond: escrowRb, challengeBond: escrowCb});

        bytes memory ancillary = _ancillary(
            id, ctx.desc, ctx.resTime, ctx.committeeWinner, ctx.reportedOutcome, ctx.challengedOutcome, ctx.outcomes
        );

        asset.safeTransferFrom(address(pot), address(umaOracle), ctx.reportBond + ctx.challengeBond);
        umaOracle.requestAndProposeWithBond(
            uint256(ctx.resTime), ancillary, int256(uint256(ctx.committeeWinner)), ctx.reportBond
        );
        umaOracle.dispute(uint256(ctx.resTime), ancillary);

        emit UmaAppealStarted(id, msg.sender);
    }

    /// @notice Settles a pending UMA appeal after the oracle has resolved.
    /// @dev Distributes bonds based on the UMA outcome. Invalid prices trigger cancellation.
    /// @param id Market identifier.
    function settleUmaAppeal(uint256 id) external nonReentrant {
        UmaSettlementContext memory ctx = _loadPendingUmaContext(id);

        int256 price = umaOracle.settle(uint256(ctx.resTime), ctx.ancillary);
        uint256 recovered = umaOracle.withdrawAllTo(uint256(ctx.resTime), ctx.ancillary, address(pot));
        emit UmaDisputeSettled(id, price);

        if (price <= 0 || price > int256(uint256(ctx.outcomes))) {
            _handleInvalidPrice(id, ctx.reporter, ctx.challenger, recovered);
            _clearEscrowedBonds(id);
            return;
        }

        uint8 umaWinner = SafeCast.toUint8(SafeCast.toUint256(price));
        pot.umaResolve(id, umaWinner);

        bool overturned = (umaWinner != ctx.committeeWinner);
        _handleAppealBond(id, overturned);
        _distributeRecoveredBonds(
            id,
            ctx.reporter,
            ctx.challenger,
            ctx.reportedOutcome,
            ctx.challengedOutcome,
            ctx.reportBond,
            ctx.challengeBond,
            umaWinner,
            recovered
        );
        _clearEscrowedBonds(id);
    }

    /// @notice Expires a stale UMA appeal that has been pending beyond the 30-day timeout.
    /// @dev Attempts best-effort settlement first; falls back to committee winner if that fails.
    /// @param id Market identifier.
    function expireUmaAppeal(uint256 id) external nonReentrant {
        UmaSettlementContext memory ctx = _loadPendingUmaContext(id);
        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        if (block.timestamp <= uint256(umaStartedAt) + UMA_STALE_TIMEOUT) revert E2();

        // Best-effort: attempt to settle first. If it succeeds, apply normal settlement path.
        int256 price = 0;
        bool settled = false;
        try umaOracle.settle(uint256(ctx.resTime), ctx.ancillary) returns (int256 p) {
            price = p;
            settled = true;
        } catch {}

        uint256 recovered = 0;
        try umaOracle.withdrawAllTo(uint256(ctx.resTime), ctx.ancillary, address(pot)) returns (uint256 r) {
            recovered = r;
        } catch {}

        if (settled && price > 0 && price <= int256(uint256(ctx.outcomes))) {
            uint8 umaWinner = SafeCast.toUint8(SafeCast.toUint256(price));
            pot.umaResolve(id, umaWinner);

            bool overturned = (umaWinner != ctx.committeeWinner);
            _handleAppealBond(id, overturned);
            _distributeRecoveredBonds(
                id,
                ctx.reporter,
                ctx.challenger,
                ctx.reportedOutcome,
                ctx.challengedOutcome,
                ctx.reportBond,
                ctx.challengeBond,
                umaWinner,
                recovered
            );
            _clearEscrowedBonds(id);

            emit UmaDisputeExpired(id);
            return;
        }

        (address appellant, uint256 bond) = pot.umaConsumeAppealBond(id);
        if (bond > 0) {
            pot.umaCreditPending(appellant, bond);
        }
        _refundRecoveredHalfHalf(ctx.reporter, ctx.challenger, recovered);

        pot.umaResolve(id, ctx.committeeWinner);
        _clearEscrowedBonds(id);

        emit UmaDisputeExpired(id);
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _handleInvalidPrice(uint256 id, address reporter, address challenger, uint256 recovered) internal {
        (address appellant, uint256 bond) = pot.umaConsumeAppealBond(id);
        if (bond > 0) {
            pot.umaCreditPending(appellant, bond);
        }
        _refundRecoveredHalfHalf(reporter, challenger, recovered);
        pot.umaCancel(id);
    }

    function _handleAppealBond(uint256 id, bool overturned) internal {
        (address appellant, uint256 bond) = pot.umaConsumeAppealBond(id);
        if (bond > 0) {
            address to = overturned ? appellant : pot.treasury();
            pot.umaCreditPending(to, bond);
        }
    }

    function _loadStartContext(uint256 id) internal view returns (UmaStartContext memory ctx) {
        (
            string memory desc,,,,
            uint64 resTime,,
            uint8 outcomes,
            uint8 committeeWinner,
            uint8 status,,
            uint256 principal
        ) = pot.getMkt(id);
        (uint64 appealDeadline,,,) = pot.getAppealInfo(id);
        if (status != ST_APPEALABLE) revert E2();
        if (block.timestamp > uint256(appealDeadline)) revert E2();
        if (pot.getDisputeMode(id) == DISPUTE_UMA) revert E2();
        if (outcomes < 2) revert E2();
        if (committeeWinner == 0 || committeeWinner > outcomes) revert E2();

        UmaReportContext memory reportCtx = _loadReportContext(id, outcomes);
        if (
            reportCtx.reportBond == 0 || reportCtx.challengeBond == 0 || reportCtx.reportBond != reportCtx.challengeBond
        ) revert E2();

        ctx.desc = desc;
        ctx.resTime = resTime;
        ctx.outcomes = outcomes;
        ctx.committeeWinner = committeeWinner;
        ctx.reportedOutcome = reportCtx.reportedOutcome;
        ctx.challengedOutcome = reportCtx.challengedOutcome;
        ctx.principal = principal;
        ctx.reportBond = reportCtx.reportBond;
        ctx.challengeBond = reportCtx.challengeBond;
    }

    function _loadPendingUmaContext(uint256 id) internal view returns (UmaSettlementContext memory ctx) {
        (string memory desc,,,, uint64 resTime,, uint8 outcomes, uint8 committeeWinner, uint8 status,,) = pot.getMkt(id);
        if (status != ST_UMA_PENDING) revert E2();
        if (pot.getDisputeMode(id) != DISPUTE_UMA) revert E2();
        if (outcomes < 2) revert E2();
        if (committeeWinner == 0 || committeeWinner > outcomes) revert E2();

        UmaReportContext memory reportCtx = _loadReportContext(id, outcomes);
        EscrowedBonds memory escrowed = _escrowedBonds[id];
        if (escrowed.reportBond == 0 || escrowed.challengeBond == 0 || escrowed.reportBond != escrowed.challengeBond) {
            revert E2();
        }

        ctx.resTime = resTime;
        ctx.outcomes = outcomes;
        ctx.committeeWinner = committeeWinner;
        ctx.reportedOutcome = reportCtx.reportedOutcome;
        ctx.challengedOutcome = reportCtx.challengedOutcome;
        ctx.reporter = reportCtx.reporter;
        ctx.challenger = reportCtx.challenger;
        ctx.reportBond = escrowed.reportBond;
        ctx.challengeBond = escrowed.challengeBond;
        ctx.ancillary = _ancillary(
            id, desc, resTime, committeeWinner, reportCtx.reportedOutcome, reportCtx.challengedOutcome, outcomes
        );
    }

    function _loadReportContext(uint256 id, uint8 outcomes) internal view returns (UmaReportContext memory reportCtx) {
        (
            address reporter,
            uint8 reportedOutcome,
            uint256 reportBond,,,
            address challenger,
            uint8 challengedOutcome,
            uint256 challengeBond
        ) = pot.getReport(id);

        if (reporter == address(0) || challenger == address(0)) revert E2();
        if (reportedOutcome == 0 || reportedOutcome > outcomes) revert E2();
        if (challengedOutcome == 0 || challengedOutcome > outcomes) revert E2();

        reportCtx.reportedOutcome = reportedOutcome;
        reportCtx.challengedOutcome = challengedOutcome;
        reportCtx.reportBond = reportBond;
        reportCtx.challengeBond = challengeBond;
        reportCtx.reporter = reporter;
        reportCtx.challenger = challenger;
    }

    function _ancillary(
        uint256 id,
        string memory desc,
        uint64 resTime,
        uint8 committeeWinner,
        uint8 reportedOutcome,
        uint8 challengedOutcome,
        uint8 outcomes
    ) internal view returns (bytes memory) {
        string memory prefix = string.concat(
            "yPot market #",
            Strings.toString(id),
            " on chain ",
            Strings.toString(block.chainid),
            " | Resolution timestamp: ",
            Strings.toString(uint256(resTime)),
            ": ",
            desc
        );
        string memory outcomesChunk = string.concat(
            " | Committee winner: ",
            Strings.toString(uint256(committeeWinner)),
            " | Reported outcome: ",
            Strings.toString(uint256(reportedOutcome)),
            " | Challenged outcome: ",
            Strings.toString(uint256(challengedOutcome))
        );
        return bytes(
            string.concat(
                prefix,
                outcomesChunk,
                " | Valid outcomes: 1-",
                Strings.toString(uint256(outcomes)),
                " | Return the winning outcome number."
            )
        );
    }

    function _distributeRecoveredBonds(
        uint256 id,
        address reporter,
        address challenger,
        uint8 reportedOutcome,
        uint8 challengedOutcome,
        uint256 reportBond,
        uint256 challengeBond,
        uint8 winner,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        address treasury = pot.treasury();
        address to = treasury;
        address loser = address(0);
        uint256 loserBond = 0;
        if (winner == reportedOutcome) {
            to = reporter;
            loser = challenger;
            loserBond = challengeBond;
        } else if (winner == challengedOutcome) {
            to = challenger;
            loser = reporter;
            loserBond = reportBond;
        }

        if (to == treasury) {
            pot.umaCreditPending(treasury, amount);
            return;
        }

        uint256 rake = Math.mulDiv(loserBond, pot.disputeRakeBps(), BPS);
        if (rake > amount) {
            rake = amount;
        }
        if (rake > 0) {
            pot.umaCreditPending(treasury, rake);
            emit DisputeRaked(id, loser, rake);
        }
        pot.umaCreditPending(to, amount - rake);
    }

    function _refundRecoveredHalfHalf(address reporter, address challenger, uint256 recovered) internal {
        if (recovered == 0) return;
        uint256 half = recovered >> 1;
        pot.umaCreditPending(reporter, half);
        pot.umaCreditPending(challenger, recovered - half);
    }

    function _clearEscrowedBonds(uint256 id) internal {
        delete _escrowedBonds[id];
    }
}
