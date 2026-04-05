// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Simple preview-only faucet for seeded mock assets on public testnets.
contract PreviewFaucet is Ownable {
    using SafeERC20 for IERC20;

    error InvalidAsset();
    error InvalidClaimAmount();
    error CooldownActive(uint256 nextClaimAt);
    error InsufficientLiquidity(uint256 available, uint256 required);

    IERC20 public immutable asset;
    uint256 public claimAmount;
    uint256 public claimCooldown;

    mapping(address => uint256) public nextClaimAt;

    event Claimed(address indexed account, uint256 amount, uint256 nextClaimAt);
    event ClaimAmountUpdated(uint256 previousAmount, uint256 newAmount);
    event ClaimCooldownUpdated(uint256 previousCooldown, uint256 newCooldown);
    event Drained(address indexed to, uint256 amount);

    constructor(address asset_, address owner_, uint256 claimAmount_, uint256 claimCooldown_) Ownable(owner_) {
        if (asset_ == address(0)) revert InvalidAsset();
        if (claimAmount_ == 0) revert InvalidClaimAmount();
        asset = IERC20(asset_);
        claimAmount = claimAmount_;
        claimCooldown = claimCooldown_;
    }

    function claim() external {
        uint256 readyAt = nextClaimAt[msg.sender];
        if (readyAt > block.timestamp) revert CooldownActive(readyAt);

        uint256 amount = claimAmount;
        uint256 available = asset.balanceOf(address(this));
        if (available < amount) revert InsufficientLiquidity(available, amount);

        uint256 newReadyAt = block.timestamp + claimCooldown;
        nextClaimAt[msg.sender] = newReadyAt;

        asset.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount, newReadyAt);
    }

    function setClaimAmount(uint256 newAmount) external onlyOwner {
        if (newAmount == 0) revert InvalidClaimAmount();
        emit ClaimAmountUpdated(claimAmount, newAmount);
        claimAmount = newAmount;
    }

    function setClaimCooldown(uint256 newCooldown) external onlyOwner {
        emit ClaimCooldownUpdated(claimCooldown, newCooldown);
        claimCooldown = newCooldown;
    }

    function drain(address to, uint256 amount) external onlyOwner {
        asset.safeTransfer(to, amount);
        emit Drained(to, amount);
    }
}
