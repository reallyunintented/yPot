// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Stateless helper functions for yPot modules.
library YPotLib {
    uint256 private constant BPS = 10_000;

    /// @notice Time-weight multiplier in BPS units.
    /// @dev Early bets get higher weight (up to 2x at market creation).
    function wt(uint64 created, uint64 deadline, uint256 nowTs) internal pure returns (uint256) {
        if (deadline <= created) return BPS;
        uint256 d = uint256(deadline) - uint256(created);
        uint256 e = nowTs - uint256(created);
        if (e >= d) return BPS;
        return BPS + Math.mulDiv(BPS, d - e, d);
    }

    /// @notice Returns max(minBond, principal * bondBps / BPS).
    function calcBond(uint256 principal, uint256 bondBps, uint256 minBond) internal pure returns (uint256) {
        uint256 prinBond = Math.mulDiv(principal, bondBps, BPS);
        return prinBond > minBond ? prinBond : minBond;
    }

    /// @notice Required confirmation shares for a given pool size and confirm bps.
    function requiredConfirm(uint256 totalShares, uint256 confirmBps) internal pure returns (uint256) {
        return Math.mulDiv(totalShares, confirmBps, BPS);
    }
}
