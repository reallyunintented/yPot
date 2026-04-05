// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title YearnWrapper
 * @notice ERC-4626 wrapper routing deposits to Yearn V3 vault
 * @dev Pass-through design with 1:1 share backing
 *
 * CHANGELOG v1.2:
 * - Slippage tolerance now configurable (was hardcoded 1%)
 * - Added setSlippage() with bounded range [9500, 9990]
 * - Added SlippageSet event
 */
contract YearnWrapper is ERC4626, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 private constant BPS = 10_000;

    /// @dev Slippage bounds: 0.1% min slippage to 5% max slippage
    uint256 private constant MIN_SLIPPAGE_BPS = 9500; // 5% max slippage allowed
    uint256 private constant MAX_SLIPPAGE_BPS = 9990; // 0.1% min slippage allowed

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IERC4626 public immutable yearnVault;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    mapping(address => bool) public depositors;

    /// @notice Slippage tolerance in BPS (9900 = 1% max slippage)
    uint256 public slippageBps = 9900;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error SlippageExceeded();
    error InsufficientLiquidity();
    error RenounceDisabled();
    error InvalidSlippage();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event DepositorSet(address indexed account, bool allowed);
    event EmergencyWithdraw(uint256 yearnShares, uint256 assetsRecovered);
    event SlippageSet(uint256 slippageBps);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    function _checkDepositor() internal view {
        if (!depositors[msg.sender]) revert Unauthorized();
    }

    modifier onlyDepositor() {
        _checkDepositor();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys the wrapper with asset, Yearn vault, and initial depositors.
    /// @param _asset Underlying asset token (must match Yearn vault's asset).
    /// @param _yearnVault Yearn V3 vault to route deposits into.
    /// @param _depositors Initial addresses allowed to deposit.
    constructor(IERC20 _asset, IERC4626 _yearnVault, address[] memory _depositors)
        ERC20("yPot Yearn Wrapper", "ypYEARN")
        ERC4626(_asset)
        Ownable(msg.sender)
    {
        if (address(_yearnVault) == address(0)) revert ZeroAddress();
        if (_yearnVault.asset() != address(_asset)) revert Unauthorized();

        yearnVault = _yearnVault;

        for (uint256 i; i < _depositors.length;) {
            if (_depositors[i] == address(0)) revert ZeroAddress();
            depositors[_depositors[i]] = true;
            emit DepositorSet(_depositors[i], true);
            unchecked {
                ++i;
            }
        }

        _asset.forceApprove(address(_yearnVault), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // ERC-4626 Overrides
    // -------------------------------------------------------------------------

    /// @notice Permanently disabled — ownership cannot be renounced.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @notice Total assets under management (local balance + Yearn vault position).
    function totalAssets() public view override returns (uint256) {
        uint256 local = IERC20(asset()).balanceOf(address(this));
        uint256 yearnShares = yearnVault.balanceOf(address(this));
        if (yearnShares == 0) return local;
        return yearnVault.convertToAssets(yearnShares) + local;
    }

    /// @notice Max depositable assets (0 when paused or caller is not an allowed depositor).
    function maxDeposit(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        if (!depositors[owner_]) return 0;
        return yearnVault.maxDeposit(address(this));
    }

    /// @notice Max mintable shares (0 when paused or caller is not an allowed depositor).
    function maxMint(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        if (!depositors[owner_]) return 0;

        uint256 maxAssets = yearnVault.maxDeposit(address(this));
        if (maxAssets == 0) return 0;

        uint256 numerator = totalSupply() + 10 ** _decimalsOffset();
        uint256 denominator = totalAssets() + 1;

        uint256 maxAssetsBeforeOverflow = Math.mulDiv(type(uint256).max, denominator, numerator);
        if (maxAssets > maxAssetsBeforeOverflow) return type(uint256).max;

        return Math.mulDiv(maxAssets, numerator, denominator, Math.Rounding.Floor);
    }

    /// @notice Max withdrawable assets (capped by local + Yearn liquidity).
    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 ownerAssets = _convertToAssets(balanceOf(owner_), Math.Rounding.Floor);
        uint256 local = IERC20(asset()).balanceOf(address(this));
        uint256 yearnMax = yearnVault.maxWithdraw(address(this));
        uint256 totalAvailable = local + yearnMax;
        return ownerAssets < totalAvailable ? ownerAssets : totalAvailable;
    }

    /// @notice Max redeemable shares (capped by local + Yearn liquidity).
    function maxRedeem(address owner_) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(owner_);
        uint256 local = IERC20(asset()).balanceOf(address(this));
        uint256 yearnMaxAssets = yearnVault.maxWithdraw(address(this));
        uint256 maxRedeemableAssets = local + yearnMaxAssets;
        uint256 maxRedeemableShares = _convertToShares(maxRedeemableAssets, Math.Rounding.Floor);
        return ownerShares < maxRedeemableShares ? ownerShares : maxRedeemableShares;
    }

    // -------------------------------------------------------------------------
    // Deposit / Mint
    // -------------------------------------------------------------------------

    /// @notice Deposits assets into Yearn vault and mints wrapper shares to receiver.
    /// @dev Only allowed depositors can call. Checks slippage against Yearn preview.
    function deposit(uint256 assets, address receiver)
        public
        override
        onlyDepositor
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);

        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroAmount();

        uint256 expectedYearn = yearnVault.previewDeposit(assets);
        if (expectedYearn == 0) revert ZeroAmount();

        SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), assets);

        uint256 yearnShares = yearnVault.deposit(assets, address(this));
        if (yearnShares == 0) revert ZeroAmount();

        if (yearnShares < expectedYearn.mulDiv(slippageBps, BPS)) {
            revert SlippageExceeded();
        }

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Mints exact wrapper shares by depositing required assets into Yearn.
    /// @dev Only allowed depositors can call. Checks slippage against Yearn preview.
    function mint(uint256 shares, address receiver)
        public
        override
        onlyDepositor
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();

        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) revert ERC4626ExceededMaxMint(receiver, shares, maxShares);

        assets = previewMint(shares);
        if (assets == 0) revert ZeroAmount();

        uint256 expectedYearn = yearnVault.previewDeposit(assets);
        if (expectedYearn == 0) revert ZeroAmount();

        SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), assets);

        uint256 yearnShares = yearnVault.deposit(assets, address(this));
        if (yearnShares == 0) revert ZeroAmount();

        if (yearnShares < expectedYearn.mulDiv(slippageBps, BPS)) {
            revert SlippageExceeded();
        }

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // -------------------------------------------------------------------------
    // Withdraw / Redeem
    // -------------------------------------------------------------------------

    /// @notice Withdraws exact assets by redeeming from local balance and/or Yearn.
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        uint256 maxAssets = maxWithdraw(owner_);
        if (assets > maxAssets) revert ERC4626ExceededMaxWithdraw(owner_, assets, maxAssets);

        shares = previewWithdraw(assets);

        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }

        _burn(owner_, shares);
        _fulfillAssets(assets);

        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @notice Redeems exact shares for assets from local balance and/or Yearn.
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();

        uint256 maxShares = maxRedeem(owner_);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner_, shares, maxShares);

        assets = previewRedeem(shares);

        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }

        _burn(owner_, shares);
        _fulfillAssets(assets);

        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function _fulfillAssets(uint256 needed) internal {
        uint256 local = IERC20(asset()).balanceOf(address(this));
        if (local >= needed) return;

        uint256 shortfall = needed - local;
        yearnVault.withdraw(shortfall, address(this), address(this));

        uint256 balAfter = IERC20(asset()).balanceOf(address(this));
        if (balAfter < needed) revert InsufficientLiquidity();
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /// @notice Adds or removes a depositor from the allowlist.
    /// @param account Address to update.
    /// @param allowed True to allow deposits, false to revoke.
    function setDepositor(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        depositors[account] = allowed;
        emit DepositorSet(account, allowed);
    }

    /// @notice Set slippage tolerance for Yearn deposits
    /// @param bps Slippage in basis points (9900 = 1% max slippage)
    function setSlippage(uint256 bps) external onlyOwner {
        if (bps < MIN_SLIPPAGE_BPS || bps > MAX_SLIPPAGE_BPS) revert InvalidSlippage();
        slippageBps = bps;
        emit SlippageSet(bps);
    }

    /// @notice Pauses deposits (withdrawals remain enabled).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses deposits.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Redeems all Yearn vault shares back to the wrapper as local asset balance.
    function emergencyExitYearn() external onlyOwner nonReentrant {
        uint256 yearnShares = yearnVault.balanceOf(address(this));
        if (yearnShares == 0) return;
        uint256 assets = yearnVault.redeem(yearnShares, address(this), address(this));
        emit EmergencyWithdraw(yearnShares, assets);
    }

    /// @notice Rescues accidentally sent tokens (cannot rescue asset or Yearn vault shares).
    /// @param token Token to rescue.
    /// @param to Recipient address.
    /// @param amount Amount to transfer.
    function rescue(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (address(token) == asset()) revert Unauthorized();
        if (address(token) == address(yearnVault)) revert Unauthorized();
        token.safeTransfer(to, amount);
    }

    // -------------------------------------------------------------------------
    // View Helpers
    // -------------------------------------------------------------------------

    /// @notice Returns the wrapper's Yearn vault share balance.
    function yearnShareBalance() external view returns (uint256) {
        return yearnVault.balanceOf(address(this));
    }

    /// @notice Returns the wrapper's asset-per-share exchange rate (scaled to 1e18).
    function exchangeRate() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return totalAssets().mulDiv(1e18, supply);
    }
}
