// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockVault is ERC4626 {
    constructor(address asset_) ERC4626(IERC20(asset_)) ERC20("Mock Vault", "mVault") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
