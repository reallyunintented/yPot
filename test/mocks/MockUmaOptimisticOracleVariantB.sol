// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice UMA OO V3-style mock that rejects Variant A signatures and only accepts Variant B.
 * @dev Forces the adapter's fallback logic to execute:
 *   - proposePrice(bytes32,uint256,bytes,int256)         → reverts
 *   - proposePriceFor(address,bytes32,uint256,bytes,int256) → accepted
 *   - disputePrice(bytes32,uint256,bytes)                → reverts
 *   - disputePriceFor(address,bytes32,uint256,bytes)     → accepted
 *   - settle(bytes32,uint256,bytes)                      → reverts
 *   - settle(address,bytes32,uint256,bytes)              → accepted (Variant B)
 */
contract MockUmaOptimisticOracleVariantB {
    using SafeERC20 for IERC20;

    struct Request {
        bool requested;
        bool proposed;
        bool disputed;
        bool settled;
        int256 price;
        IERC20 currency;
        uint256 bond;
        uint256 payout;
    }

    mapping(bytes32 => Request) public requests;

    bool public revertOnSettle;

    function setRevertOnSettle(bool v) external {
        revertOnSettle = v;
    }

    function _id(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(identifier, timestamp, ancillaryData));
    }

    // -------------------------------------------------------------------------
    // Common signatures (accepted by both V2 and V3)
    // -------------------------------------------------------------------------

    function requestPrice(
        bytes32 identifier,
        uint256 timestamp,
        bytes calldata ancillaryData,
        address currency,
        uint256
    ) external {
        bytes32 id = _id(identifier, timestamp, ancillaryData);
        Request storage r = requests[id];
        r.requested = true;
        r.currency = IERC20(currency);
    }

    function setCustomLiveness(bytes32, uint256, bytes calldata, uint256) external {}

    function setBond(bytes32 identifier, uint256 timestamp, bytes calldata ancillaryData, uint256 bond_) external {
        bytes32 id = _id(identifier, timestamp, ancillaryData);
        requests[id].bond = bond_;
    }

    // -------------------------------------------------------------------------
    // Variant A — rejected (forces adapter fallback to Variant B)
    // -------------------------------------------------------------------------

    function proposePrice(bytes32, uint256, bytes calldata, int256) external pure returns (uint256) {
        revert("VariantA: proposePrice not supported");
    }

    function disputePrice(bytes32, uint256, bytes calldata) external pure {
        revert("VariantA: disputePrice not supported");
    }

    // -------------------------------------------------------------------------
    // Variant B — accepted
    // -------------------------------------------------------------------------

    /// @notice Proposer address is ignored for state tracking; bond is pulled from msg.sender (adapter).
    function proposePriceFor(
        address,
        bytes32 identifier,
        uint256 timestamp,
        bytes calldata ancillaryData,
        int256 proposedPrice
    ) external {
        bytes32 id = _id(identifier, timestamp, ancillaryData);
        Request storage r = requests[id];
        require(r.requested, "not requested");
        if (!r.proposed && r.bond != 0) {
            r.currency.safeTransferFrom(msg.sender, address(this), r.bond);
        }
        r.proposed = true;
        r.price = proposedPrice;
    }

    /// @notice Disputer address is ignored; bond is pulled from msg.sender (adapter).
    function disputePriceFor(address, bytes32 identifier, uint256 timestamp, bytes calldata ancillaryData) external {
        bytes32 id = _id(identifier, timestamp, ancillaryData);
        Request storage r = requests[id];
        require(r.proposed, "not proposed");
        if (!r.disputed && r.bond != 0) {
            r.currency.safeTransferFrom(msg.sender, address(this), r.bond);
        }
        r.disputed = true;
    }

    // -------------------------------------------------------------------------
    // settle — overloaded: Variant A reverts, Variant B accepted
    // -------------------------------------------------------------------------

    function settle(bytes32, uint256, bytes calldata) external pure returns (int256) {
        revert("VariantA: settle not supported");
    }

    /// @dev Requester address is ignored; payout is sent to msg.sender (adapter).
    function settle(address, bytes32 identifier, uint256 timestamp, bytes calldata ancillaryData)
        external
        returns (int256)
    {
        require(!revertOnSettle, "settle reverted");
        bytes32 id = _id(identifier, timestamp, ancillaryData);
        Request storage r = requests[id];
        require(!r.settled, "already settled");
        r.settled = true;
        uint256 amount = r.payout;
        if (amount == 0 && r.bond != 0) {
            amount = r.bond * 2;
        }
        if (amount > 0) {
            r.currency.safeTransfer(msg.sender, amount);
        }
        return r.price;
    }

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function setPayout(bytes32 identifier, uint256 timestamp, bytes calldata ancillaryData, uint256 payout) external {
        bytes32 id = _id(identifier, timestamp, ancillaryData);
        requests[id].payout = payout;
    }
}
