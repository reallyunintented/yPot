// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @notice Minimal ERC-4626-ish vault for Foundry tests.
 * @dev Uses a manual exchange rate (assets per share) in 1e18 precision.
 *      `previewDeposit` does NOT include slippage, while `deposit` can apply `depositSlippageBps`.
 */
contract MockERC4626Vault is ERC20, IERC4626 {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetToken;
    address public immutable admin;

    uint256 public exchangeRate = 1e18;
    uint256 public depositSlippageBps = 0;

    modifier onlyAdmin() {
        require(msg.sender == admin, "MockVault: only admin");
        _;
    }

    constructor(IERC20 _asset) ERC20("Mock Vault Share", "mSHARE") {
        assetToken = _asset;
        admin = msg.sender;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function totalAssets() public view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (assets == 0) return 0;
        return Math.mulDiv(assets, 1e18, exchangeRate, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (shares == 0) return 0;
        return Math.mulDiv(shares, exchangeRate, 1e18, Math.Rounding.Floor);
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        uint256 ownerAssets = convertToAssets(balanceOf(owner));
        uint256 bal = assetToken.balanceOf(address(this));
        return ownerAssets < bal ? ownerAssets : bal;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        uint256 ownerShares = balanceOf(owner);
        uint256 maxByAssets = convertToShares(assetToken.balanceOf(address(this)));
        return ownerShares < maxByAssets ? ownerShares : maxByAssets;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        if (shares == 0) return 0;
        return Math.mulDiv(shares, exchangeRate, 1e18, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        if (assets == 0) return 0;
        return Math.mulDiv(assets, 1e18, exchangeRate, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        uint256 slipped = Math.mulDiv(shares, 10_000 - depositSlippageBps, 10_000, Math.Rounding.Floor);
        shares = slipped;
        assetToken.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = Math.mulDiv(shares, exchangeRate, 1e18, Math.Rounding.Ceil);
        assetToken.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = Math.mulDiv(assets, 1e18, exchangeRate, Math.Rounding.Ceil);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        assetToken.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        assetToken.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function setExchangeRate(uint256 newRate) external onlyAdmin {
        require(newRate > 0, "rate=0");
        exchangeRate = newRate;
    }

    function setDepositSlippageBps(uint256 bps) external onlyAdmin {
        require(bps <= 10_000, "bps");
        depositSlippageBps = bps;
    }

    function drainAssets(address to, uint256 amount) external onlyAdmin {
        assetToken.safeTransfer(to, amount);
    }
}

