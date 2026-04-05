// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title UmaOptimisticOracleAdapter
 * @notice Thin integration layer for UMA Optimistic Oracle V2/V3 compatibility.
 * @dev Uses signature fallbacks to support multiple oracle versions.
 *      Deployers MUST verify the target oracle address + ABI on their chain.
 *
 * Security model:
 * - Allowed requesters can initiate oracle requests
 * - Each request permanently records its initiating requester (requesterOf)
 * - Adapter owner is a backstop: can dispute/settle/withdraw for previously-created requests
 */
contract UmaOptimisticOracleAdapter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error ZeroAddress();
    error OracleCallFailed(bytes returndata);
    error InvalidOracleResponse();
    error RequestAlreadyExists();
    error RequestNotActive();
    error RequestStillActive();
    error InsufficientBalance();
    error InsufficientClaimable();
    error ActiveRequests();
    error InsufficientExcess();
    error RequestUnknown();
    error RequestSlotUsed();

    event RequesterSet(address indexed account, bool allowed);
    event PriceRequested(bytes32 indexed identifier, uint256 timestamp, bytes ancillaryData);
    event PriceProposed(bytes32 indexed identifier, uint256 timestamp, int256 proposedPrice);
    event PriceDisputed(bytes32 indexed identifier, uint256 timestamp);
    event PriceSettled(bytes32 indexed identifier, uint256 timestamp, int256 resolvedPrice);
    event CurrencyWithdrawn(address indexed to, uint256 amount);

    address public immutable optimisticOracle;
    IERC20 public immutable currency;
    bytes32 public immutable identifier;

    uint256 public immutable liveness;
    /// @dev Used by `requestAndPropose()` (fixed-bond mode). Not used by `requestAndProposeWithBond()`.
    uint256 public immutable bond;
    /// @dev Used by `requestAndPropose()` (fixed-reward mode). `requestAndProposeWithBond()` always uses reward=0.
    uint256 public immutable reward;

    mapping(address => bool) public requesters;

    /// @dev True while a request is active (pending settlement).
    mapping(bytes32 => bool) public activeRequests;

    /// @dev Permanent slot used flag: prevents requestId reuse across time.
    mapping(bytes32 => bool) public requestInitialized;

    /// @dev Who created the request (captured at creation).
    mapping(bytes32 => address) public requesterOf;

    /// @dev Bond per request side.
    mapping(bytes32 => uint256) public requestBonds;

    /// @dev Amount of currency attributable to a settled request and withdrawable.
    mapping(bytes32 => uint256) public claimable;

    uint256 public activeRequestCount;
    uint256 public totalClaimable;

    /// @dev Reserve required to keep active requests solvent for dispute (sum of requestBonds for active requests).
    uint256 public totalActiveBondReserve;

    function _checkAllowedRequester() internal view {
        if (!requesters[msg.sender]) revert Unauthorized();
    }

    modifier onlyAllowedRequester() {
        _checkAllowedRequester();
        _;
    }

    /// @notice Deploys the adapter with oracle config and initial requesters.
    /// @param _optimisticOracle Target UMA oracle address.
    /// @param _currency Currency token used for bonds and rewards.
    /// @param _identifier UMA price identifier.
    /// @param _liveness Custom liveness period (0 to use oracle default).
    /// @param _bond Default bond per side (used by `requestAndPropose`).
    /// @param _reward Default reward (used by `requestAndPropose`).
    /// @param _requesters Initial addresses allowed to create requests.
    constructor(
        address _optimisticOracle,
        IERC20 _currency,
        bytes32 _identifier,
        uint256 _liveness,
        uint256 _bond,
        uint256 _reward,
        address[] memory _requesters
    ) Ownable(msg.sender) {
        if (_optimisticOracle == address(0) || address(_currency) == address(0)) revert ZeroAddress();
        optimisticOracle = _optimisticOracle;
        currency = _currency;
        identifier = _identifier;
        liveness = _liveness;
        bond = _bond;
        reward = _reward;

        for (uint256 i; i < _requesters.length;) {
            address r = _requesters[i];
            if (r == address(0)) revert ZeroAddress();
            requesters[r] = true;
            unchecked {
                ++i;
            }
        }

        _currency.forceApprove(_optimisticOracle, type(uint256).max);
    }

    /// @notice Adds or removes a requester from the allowlist.
    /// @param account Address to update.
    /// @param allowed True to allow requests, false to revoke.
    function setRequester(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        requesters[account] = allowed;
        emit RequesterSet(account, allowed);
    }

    // -------------------------------------------------------------------------
    // Core flow
    // -------------------------------------------------------------------------

    /// @notice Requests and proposes a price (outcome). Uses adapter's configured liveness/bond/reward.
    function requestAndPropose(uint256 timestamp, bytes calldata ancillaryData, int256 proposedPrice)
        external
        nonReentrant
        onlyAllowedRequester
    {
        bytes32 requestId = _requestId(timestamp, ancillaryData);

        if (requestInitialized[requestId]) revert RequestSlotUsed();
        requestInitialized[requestId] = true;
        requesterOf[requestId] = msg.sender;

        if (activeRequests[requestId]) revert RequestAlreadyExists();
        activeRequests[requestId] = true;
        unchecked {
            ++activeRequestCount;
        }

        bytes memory ancillary = ancillaryData;

        // Prefund check: proposer bond + potential dispute bond + reward (reward is pulled at request time).
        if (bond != 0) {
            uint256 required = bond * 2 + reward;
            if (currency.balanceOf(address(this)) < required) revert InsufficientBalance();
            requestBonds[requestId] = bond;
            totalActiveBondReserve += bond;
        } else if (reward != 0) {
            if (currency.balanceOf(address(this)) < reward) revert InsufficientBalance();
        }

        _requestPrice(timestamp, ancillary);
        emit PriceRequested(identifier, timestamp, ancillary);

        if (liveness != 0) _setCustomLiveness(timestamp, ancillary, liveness);
        if (bond != 0) _setBond(timestamp, ancillary, bond);

        _proposePrice(timestamp, ancillary, proposedPrice);
        emit PriceProposed(identifier, timestamp, proposedPrice);
    }

    /// @notice Requests and proposes a price using a per-request bond and reward=0 (no reward pre-funding required).
    /// @dev Caller must pre-fund this adapter with `2 * bondPerSide` currency before calling.
    function requestAndProposeWithBond(
        uint256 timestamp,
        bytes calldata ancillaryData,
        int256 proposedPrice,
        uint256 bondPerSide
    ) external nonReentrant onlyAllowedRequester {
        bytes32 requestId = _requestId(timestamp, ancillaryData);

        if (requestInitialized[requestId]) revert RequestSlotUsed();
        requestInitialized[requestId] = true;
        requesterOf[requestId] = msg.sender;

        if (activeRequests[requestId]) revert RequestAlreadyExists();

        uint256 required = bondPerSide * 2;
        if (currency.balanceOf(address(this)) < required) revert InsufficientBalance();

        activeRequests[requestId] = true;
        requestBonds[requestId] = bondPerSide;
        totalActiveBondReserve += bondPerSide;
        unchecked {
            ++activeRequestCount;
        }

        bytes memory ancillary = ancillaryData;
        _requestPriceWithReward(timestamp, ancillary, 0);
        emit PriceRequested(identifier, timestamp, ancillary);

        if (liveness != 0) _setCustomLiveness(timestamp, ancillary, liveness);
        if (bondPerSide != 0) _setBond(timestamp, ancillary, bondPerSide);

        _proposePrice(timestamp, ancillary, proposedPrice);
        emit PriceProposed(identifier, timestamp, proposedPrice);
    }

    /// @notice Disputes the proposal to force oracle escalation (DVM) if supported by target oracle.
    /// @dev Callable by the recorded request owner, or by adapter owner as a backstop.
    function dispute(uint256 timestamp, bytes calldata ancillaryData) external nonReentrant {
        bytes32 requestId = _requestId(timestamp, ancillaryData);
        _requireOwnerOrRequestOwner(requestId);
        if (!requestInitialized[requestId]) revert RequestUnknown();
        if (!activeRequests[requestId]) revert RequestNotActive();

        uint256 reqBond = requestBonds[requestId];
        if (reqBond != 0 && currency.balanceOf(address(this)) < reqBond) revert InsufficientBalance();

        bytes memory ancillary = ancillaryData;
        _disputePrice(timestamp, ancillary);
        emit PriceDisputed(identifier, timestamp);
    }

    /// @notice Settles the request and returns the resolved price.
    /// @dev Callable by the recorded request owner, or by adapter owner as a backstop.
    function settle(uint256 timestamp, bytes calldata ancillaryData)
        external
        nonReentrant
        returns (int256 resolvedPrice)
    {
        bytes32 requestId = _requestId(timestamp, ancillaryData);
        _requireOwnerOrRequestOwner(requestId);
        if (!requestInitialized[requestId]) revert RequestUnknown();
        if (!activeRequests[requestId]) revert RequestNotActive();

        uint256 balanceBefore = currency.balanceOf(address(this));
        bytes memory ancillary = ancillaryData;

        bytes memory ret = _settle(timestamp, ancillary);
        if (ret.length < 32) revert InvalidOracleResponse();

        resolvedPrice = abi.decode(ret, (int256));

        uint256 balanceAfter = currency.balanceOf(address(this));
        if (balanceAfter > balanceBefore) {
            uint256 delta = balanceAfter - balanceBefore;
            claimable[requestId] += delta;
            totalClaimable += delta;
        }

        activeRequests[requestId] = false;

        uint256 reqBond = requestBonds[requestId];
        if (reqBond != 0) {
            delete requestBonds[requestId];
            totalActiveBondReserve -= reqBond;
        }

        activeRequestCount -= 1;
        emit PriceSettled(identifier, timestamp, resolvedPrice);
    }

    // -------------------------------------------------------------------------
    // Withdrawals
    // -------------------------------------------------------------------------

    /// @notice Allows owner to withdraw currency held by the adapter (e.g., to recover excess funds).
    /// @dev Excess is defined as balance - (totalClaimable + totalActiveBondReserve).
    ///      This avoids a global "activeRequestCount == 0" lock, while keeping active requests solvent.
    function withdrawCurrency(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        uint256 bal = currency.balanceOf(address(this));
        uint256 reserved = totalClaimable + totalActiveBondReserve;
        uint256 excess = bal > reserved ? bal - reserved : 0;

        if (amount > excess) revert InsufficientExcess();
        if (amount == 0) return;

        currency.safeTransfer(to, amount);
        emit CurrencyWithdrawn(to, amount);
    }

    /// @notice Withdraws currency attributable to a specific (settled) request.
    /// @dev Callable by request owner or adapter owner.
    function withdrawTo(uint256 timestamp, bytes calldata ancillaryData, address to, uint256 amount)
        external
        nonReentrant
        returns (uint256 withdrawn)
    {
        if (to == address(0)) revert ZeroAddress();
        bytes32 requestId = _requestId(timestamp, ancillaryData);
        _requireOwnerOrRequestOwner(requestId);
        if (!requestInitialized[requestId]) revert RequestUnknown();
        if (activeRequests[requestId]) revert RequestStillActive();

        uint256 available = claimable[requestId];
        if (amount > available) revert InsufficientClaimable();
        if (amount == 0) return 0;

        claimable[requestId] = available - amount;
        totalClaimable -= amount;
        currency.safeTransfer(to, amount);
        emit CurrencyWithdrawn(to, amount);
        return amount;
    }

    /// @notice Withdraws all currency attributable to a specific (settled) request.
    /// @dev Callable by request owner or adapter owner.
    function withdrawAllTo(uint256 timestamp, bytes calldata ancillaryData, address to)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (to == address(0)) revert ZeroAddress();
        bytes32 requestId = _requestId(timestamp, ancillaryData);
        _requireOwnerOrRequestOwner(requestId);
        if (!requestInitialized[requestId]) revert RequestUnknown();
        if (activeRequests[requestId]) revert RequestStillActive();

        amount = claimable[requestId];
        if (amount == 0) return 0;

        claimable[requestId] = 0;
        totalClaimable -= amount;
        currency.safeTransfer(to, amount);
        emit CurrencyWithdrawn(to, amount);
        return amount;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Returns whether a request is currently active (pending settlement).
    function isRequestActive(uint256 timestamp, bytes calldata ancillaryData) external view returns (bool) {
        return activeRequests[_requestId(timestamp, ancillaryData)];
    }

    /// @notice Returns the claimable currency amount for a settled request.
    function getClaimable(uint256 timestamp, bytes calldata ancillaryData) external view returns (uint256) {
        return claimable[_requestId(timestamp, ancillaryData)];
    }

    function _requestId(uint256 timestamp, bytes calldata ancillaryData) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(identifier, timestamp, ancillaryData));
    }

    function _requireOwnerOrRequestOwner(bytes32 requestId) internal view {
        address r = requesterOf[requestId];
        if (r == address(0) || (msg.sender != owner() && msg.sender != r)) revert Unauthorized();
    }

    // -------------------------------------------------------------------------
    // Oracle call helpers (signature fallbacks)
    // -------------------------------------------------------------------------

    function _requestPrice(uint256 timestamp, bytes memory ancillary) internal {
        _requestPriceWithReward(timestamp, ancillary, reward);
    }

    function _requestPriceWithReward(uint256 timestamp, bytes memory ancillary, uint256 rewardAmount) internal {
        // Common signature: requestPrice(bytes32,uint256,bytes,address,uint256)
        (bool ok, bytes memory ret) = optimisticOracle.call(
            abi.encodeWithSignature(
                "requestPrice(bytes32,uint256,bytes,address,uint256)",
                identifier,
                timestamp,
                ancillary,
                address(currency),
                rewardAmount
            )
        );
        if (!ok) revert OracleCallFailed(ret);
    }

    function _setCustomLiveness(uint256 timestamp, bytes memory ancillary, uint256 customLiveness) internal {
        // Common signature: setCustomLiveness(bytes32,uint256,bytes,uint256)
        (bool ok, bytes memory ret) = optimisticOracle.call(
            abi.encodeWithSignature(
                "setCustomLiveness(bytes32,uint256,bytes,uint256)", identifier, timestamp, ancillary, customLiveness
            )
        );
        if (!ok) revert OracleCallFailed(ret);
    }

    function _setBond(uint256 timestamp, bytes memory ancillary, uint256 customBond) internal {
        // Common signature: setBond(bytes32,uint256,bytes,uint256)
        (bool ok, bytes memory ret) = optimisticOracle.call(
            abi.encodeWithSignature(
                "setBond(bytes32,uint256,bytes,uint256)", identifier, timestamp, ancillary, customBond
            )
        );
        if (!ok) revert OracleCallFailed(ret);
    }

    function _proposePrice(uint256 timestamp, bytes memory ancillary, int256 proposedPrice) internal {
        // WARNING: Variant A does not validate return data — a misbehaving oracle could
        // return success with empty/garbage data. Variant B is preferred when available.
        // Variant A: proposePrice(bytes32,uint256,bytes,int256)
        (bool ok, bytes memory ret) = optimisticOracle.call(
            abi.encodeWithSignature(
                "proposePrice(bytes32,uint256,bytes,int256)", identifier, timestamp, ancillary, proposedPrice
            )
        );
        if (ok) return;

        // Variant B: proposePriceFor(address,bytes32,uint256,bytes,int256)
        (ok, ret) = optimisticOracle.call(
            abi.encodeWithSignature(
                "proposePriceFor(address,bytes32,uint256,bytes,int256)",
                address(this),
                identifier,
                timestamp,
                ancillary,
                proposedPrice
            )
        );
        if (!ok) revert OracleCallFailed(ret);
    }

    function _disputePrice(uint256 timestamp, bytes memory ancillary) internal {
        // Variant A: disputePrice(bytes32,uint256,bytes)
        (bool ok, bytes memory ret) = optimisticOracle.call(
            abi.encodeWithSignature("disputePrice(bytes32,uint256,bytes)", identifier, timestamp, ancillary)
        );
        if (ok) return;

        // Variant B: disputePriceFor(address,bytes32,uint256,bytes)
        (ok, ret) = optimisticOracle.call(
            abi.encodeWithSignature(
                "disputePriceFor(address,bytes32,uint256,bytes)", address(this), identifier, timestamp, ancillary
            )
        );
        if (!ok) revert OracleCallFailed(ret);
    }

    function _settle(uint256 timestamp, bytes memory ancillary) internal returns (bytes memory) {
        // Variant A: settle(bytes32,uint256,bytes)
        (bool ok, bytes memory ret) = optimisticOracle.call(
            abi.encodeWithSignature("settle(bytes32,uint256,bytes)", identifier, timestamp, ancillary)
        );
        if (ok && ret.length >= 32) return ret;

        // Variant B: settle(address,bytes32,uint256,bytes)
        (ok, ret) = optimisticOracle.call(
            abi.encodeWithSignature(
                "settle(address,bytes32,uint256,bytes)", address(this), identifier, timestamp, ancillary
            )
        );
        if (ok && ret.length >= 32) return ret;

        // Variant C: settleAndGetPrice(bytes32,uint256,bytes)
        (ok, ret) = optimisticOracle.call(
            abi.encodeWithSignature("settleAndGetPrice(bytes32,uint256,bytes)", identifier, timestamp, ancillary)
        );
        if (ok && ret.length >= 32) return ret;

        // Variant D: settleAndGetPrice(address,bytes32,uint256,bytes)
        (ok, ret) = optimisticOracle.call(
            abi.encodeWithSignature(
                "settleAndGetPrice(address,bytes32,uint256,bytes)", address(this), identifier, timestamp, ancillary
            )
        );
        if (!ok) revert OracleCallFailed(ret);
        return ret;
    }
}
