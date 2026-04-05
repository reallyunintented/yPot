// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockUmaBestEffortAdapter {
    using SafeERC20 for IERC20;

    error SettleReverted();
    error WithdrawReverted();

    struct Behavior {
        int256 price;
        uint256 recovered;
        bool revertOnSettle;
        bool revertOnWithdraw;
    }

    IERC20 public immutable currency;

    mapping(bytes32 => Behavior) internal behaviors;

    constructor(IERC20 currency_) {
        currency = currency_;
    }

    function setBehavior(
        uint256 ts,
        bytes calldata ancillary,
        int256 price,
        uint256 recovered,
        bool onSettle,
        bool onWithdraw
    ) external {
        behaviors[_key(ts, ancillary)] = Behavior({
            price: price, recovered: recovered, revertOnSettle: onSettle, revertOnWithdraw: onWithdraw
        });
    }

    function requestAndProposeWithBond(uint256, bytes memory, int256, uint256) external {}

    function dispute(uint256, bytes memory) external {}

    function settle(uint256 ts, bytes memory ancillary) external view returns (int256) {
        Behavior memory b = behaviors[_key(ts, ancillary)];
        if (b.revertOnSettle) revert SettleReverted();
        return b.price;
    }

    function withdrawAllTo(uint256 ts, bytes memory ancillary, address to) external returns (uint256 recovered) {
        Behavior memory b = behaviors[_key(ts, ancillary)];
        if (b.revertOnWithdraw) revert WithdrawReverted();
        recovered = b.recovered;
        if (recovered == 0) return 0;
        currency.safeTransfer(to, recovered);
        return recovered;
    }

    function _key(uint256 ts, bytes memory ancillary) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(ts, ancillary));
    }
}
