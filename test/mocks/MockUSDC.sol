// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    address public immutable admin;

    constructor() ERC20("Mock USDC", "mUSDC") {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "MockUSDC: only admin");
        _;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyAdmin {
        _mint(to, amount);
    }
}

