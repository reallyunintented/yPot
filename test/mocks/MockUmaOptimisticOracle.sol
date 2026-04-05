// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Minimal UMA OO mock implementing the signature variants used by UmaOptimisticOracleAdapter (variant A).
 * @dev On settle, transfers `payout` currency to the caller to simulate recovered funds (bonds/reward).
 */
contract MockUmaOptimisticOracle {
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

    function setBond(bytes32 identifier, uint256 timestamp, bytes calldata ancillaryData, uint256 bond) external {
        bytes32 id = _id(identifier, timestamp, ancillaryData);
        Request storage r = requests[id];
        r.bond = bond;
    }

    function proposePrice(bytes32 identifier, uint256 timestamp, bytes calldata ancillaryData, int256 proposedPrice)
        external
    {
        bytes32 id = _id(identifier, timestamp, ancillaryData);
        Request storage r = requests[id];
        require(r.requested, "not requested");
        if (!r.proposed && r.bond != 0) {
            r.currency.safeTransferFrom(msg.sender, address(this), r.bond);
        }
        r.proposed = true;
        r.price = proposedPrice;
    }

    function disputePrice(bytes32 identifier, uint256 timestamp, bytes calldata ancillaryData) external {
        bytes32 id = _id(identifier, timestamp, ancillaryData);
        Request storage r = requests[id];
        require(r.proposed, "not proposed");
        if (!r.disputed && r.bond != 0) {
            r.currency.safeTransferFrom(msg.sender, address(this), r.bond);
        }
        r.disputed = true;
    }

    function setPayout(bytes32 identifier, uint256 timestamp, bytes calldata ancillaryData, uint256 payout) external {
        bytes32 id = _id(identifier, timestamp, ancillaryData);
        requests[id].payout = payout;
    }

    function settle(bytes32 identifier, uint256 timestamp, bytes calldata ancillaryData) external returns (int256) {
        require(!revertOnSettle, "settle reverted");
        bytes32 id = _id(identifier, timestamp, ancillaryData);
        Request storage r = requests[id];
        require(!r.settled, "settled");
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
}
