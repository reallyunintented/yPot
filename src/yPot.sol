// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {YPotLib} from "./yPotLib.sol";

/**
 * @title yPot
 * @notice Yield-bearing parimutuel prediction markets with bonded resolution and UMA appeal backstop.
 * @dev Shares are ERC4626 vault shares held by this contract (commingled across markets).
 *      UMA logic is in external yPotUma module accessed via hooks.
 */
contract yPot is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant BPS = 10_000;
    uint256 private constant ONE_USDC = 1e6;

    // Timing
    uint256 internal constant DISPUTE_PERIOD = 24 hours;
    uint256 internal constant CHALLENGE_WINDOW = 48 hours;
    uint256 internal constant UMA_APPEAL_WINDOW = 48 hours;
    uint256 private constant SWEEP_DELAY = 30 days;
    uint256 private constant MIN_MARKET_DURATION = 14 days;
    uint256 private constant MAX_MARKET_DURATION = 730 days; // 2 years absolute cap
    /// @dev Maximum allowed gap between betting deadline and resolution time.
    /// Product policy: 180 days. Prevents indefinite capital lock after market close.
    uint256 private constant MAX_RESOLUTION_DELAY = 180 days;
    uint256 private constant CONFIRM_TIMEOUT = 48 hours;

    // Fees & Bonds
    uint256 private constant MAX_CREATE_FEE = 1000e6;
    uint256 internal constant BOND_BPS = 1000;

    // Yield fee: fixed 5% of generated yield, split among reporter/reserve/treasury.
    uint256 private constant YIELD_FEE_BPS = 500;
    uint256 private constant YIELD_REPORTER_REWARD_BPS = 2000; // 20% of yield fee → reporter
    uint256 private constant YIELD_RESERVE_BPS = 2000; // 20% of yield fee → reserve

    // Creation fee split: reporter bounty (20%), reserve (10%), referral (10% of treasury), treasury (remainder).
    uint256 private constant CREATE_REPORTER_BOUNTY_BPS = 2000; // 20% of create fee
    uint256 private constant CREATE_RESERVE_BPS = 1000; // 10% of create fee
    uint256 private constant REFERRAL_BPS = 1000; // 10% of treasury portion
    // Loser-bond rake on challenged dispute settlement.
    // Guardrail: with current defaults (minReportBond=100 USDC, bounty=2 USDC),
    // DISPUTE_RAKE_BPS must stay above 200 bps to keep self-dispute bounty farming negative EV.
    uint256 private constant DISPUTE_RAKE_BPS = 500; // 5% of loser bond

    // Rounding reserve: only used to top up tiny shortfalls caused by ERC4626 rounding drift.
    uint256 public constant MAX_ROUNDING_TOPUP_ASSETS = 5; // 0.000005 USDC (6 decimals)
    uint256 public constant RESERVE_TARGET_ASSETS = 25e6; // 25 USDC

    // Slippage bounds (configurable within these limits)
    uint256 private constant MIN_SLIPPAGE_BPS = 9500; // 5% max slippage
    uint256 private constant MAX_SLIPPAGE_BPS = 9990; // 0.1% min slippage

    // Limits
    uint256 private constant MAX_DESC_BYTES = 1024;
    uint256 private constant MAX_ORACLES = 9;
    uint256 private constant MAX_BATCH_CLAIMS = 64;
    uint256 private constant MAX_BATCH_BETS = 16;

    // Market Status
    uint8 internal constant ST_OPEN = 0;
    uint8 internal constant ST_CLOSED = 1;
    uint8 internal constant ST_RESOLVED = 2;
    uint8 internal constant ST_CLAIMABLE = 3;
    uint8 internal constant ST_CANCELLED = 4;
    uint8 internal constant ST_REPORTED = 5;
    uint8 internal constant ST_SWEPT = 6;
    uint8 internal constant ST_APPEALABLE = 7;
    uint8 internal constant ST_UMA_PENDING = 8;

    // Dispute Mode
    uint8 internal constant DISPUTE_NONE = 0;
    uint8 internal constant DISPUTE_UMA = 1;

    // -------------------------------------------------------------------------
    // Errors (E5 is reserved for yPotGov: TimelockNotReady)
    // -------------------------------------------------------------------------

    error E1(); // InvalidParams
    error E2(); // InvalidState
    error E3(); // Unauthorized
    error E4(); // Expired
    error E6(); // Slippage
    error E7(); // MarketDurationTooShort
    error E8(); // ChallengerAlreadyExists
    error E9(); // ReportAlreadyExists

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IERC20 public immutable asset;
    IERC4626 public immutable vault;
    uint256 public immutable minReportBond;

    // -------------------------------------------------------------------------
    // Protocol State
    // -------------------------------------------------------------------------

    uint256 public minBet = ONE_USDC;
    uint256 public maxBet = 1_000_000e6;
    uint256 public fee = 10e6;
    address public treasury;
    address public umaModule;

    mapping(address => bool) public oracles;
    mapping(address => uint64) public oracleAddedAt;
    uint256 public oracleN;
    uint256 public confirms = 2;
    uint256 public counter = 1;

    /// @notice Number of markets currently in ST_UMA_PENDING state.
    uint256 public umaActiveCount;

    /// @notice Number of markets currently in ST_APPEALABLE state (appeal window open, UMA not yet triggered).
    uint256 public umaAppealableCount;

    uint256 public accountedShares;

    /// @notice Pull-based withdrawal balances for fee/bond recipients.
    /// @dev Replaces direct safeTransfer calls inside state transitions to prevent
    ///      USDC-blacklisted recipients from bricking market state changes.
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice Rounding reserve in underlying asset units (USDC).
    /// @dev This value is accounting-only. The corresponding tokens remain on this contract.
    uint256 public reserveAssets;

    /// @notice Configurable slippage tolerance for vault deposits (9900 = 1% max slippage).
    uint256 public slippageBps = 9900;

    // -------------------------------------------------------------------------
    // Confirmation Bonds
    // -------------------------------------------------------------------------

    uint256 public confirmBps = 2000; // 20%

    /// @dev 5x max - prevents "1 USDC bet -> huge confirmation bond"
    uint256 public constant CONFIRM_MAX_MULTIPLIER_BPS = 50_000;

    // -------------------------------------------------------------------------
    // Market Structs
    // -------------------------------------------------------------------------

    struct Report {
        address reporter;
        uint8 outcome;
        uint256 bond;
        uint64 reportedAt;
        uint16 confirmBpsSnapshot; // Snapshot of confirmBps at report time
        address challenger;
        uint8 challengeOutcome;
        uint256 challengeBond;
    }

    struct Usr {
        mapping(uint8 => uint256) sh;
        mapping(uint8 => uint256) wsh;
        mapping(uint8 => uint256) prin;
        uint256 claimed;
        bool done;
    }

    struct Mkt {
        string desc;
        string cid;
        uint64 created;
        uint64 deadline;
        uint64 resTime;
        uint64 resolved;
        uint8 outcomes;
        uint8 winner;
        uint8 status;
        address creator;
        uint256[] sh;
        uint256[] wsh;
        uint256 tot;
        uint256 claimed;
        uint256 prin;
        Report report;
        uint8 disputeMode;
        uint64 appealDeadline;
        uint64 umaStartedAt;
        address umaAppellant;
        uint256 umaAppealBond;
        uint256 confirmTot;
        uint256 reporterBountyEscrow;
        mapping(address => Usr) users;
        mapping(address => uint256) confirmSh;
        mapping(address => bool) voted;
        mapping(uint8 => uint32) votes;
        mapping(address => uint8) oracleVoteOutcome;
    }

    mapping(uint256 => Mkt) internal _m;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event MarketCreated(uint256 indexed id, address indexed creator, uint64 deadline, uint8 outcomes);
    event MarketMetadata(uint256 indexed id, string cid);
    event BetPlaced(uint256 indexed id, address indexed user, uint8 outcome, uint256 amount, uint256 shares);
    event Reported(uint256 indexed id, address indexed reporter, uint8 outcome, uint256 bond);
    event Challenged(uint256 indexed id, address indexed challenger, uint8 outcome, uint256 bond);
    event InternalResolved(uint256 indexed id, uint8 outcome, uint64 appealDeadline);
    event Resolved(uint256 indexed id, uint8 outcome);
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);
    event EmergencyWithdraw(uint256 indexed id, address indexed user, uint256 amount);
    event Cancelled(uint256 indexed id);
    event OracleSet(address indexed oracle, bool active);
    event ConfirmBpsSet(uint256 confirmBps);
    event SlippageBpsSet(uint256 slippageBps);
    event ReportConfirmed(uint256 indexed id, address indexed confirmer, uint256 assets, uint256 shares);
    event ConfirmBondWithdrawn(uint256 indexed id, address indexed confirmer, uint256 assets, uint256 shares);
    event Swept(uint256 indexed id, uint256 shares, uint256 assets);
    event ExcessSharesSwept(uint256 shares, uint256 assets);
    event EthReceived(address indexed sender, uint256 amount);
    event UmaModuleSet(address indexed module);

    event ReserveFunded(address indexed sender, uint256 reserveAdded, uint256 treasuryRouted);
    event ReserveAutoFunded(uint256 assets);
    event ReserveWithdrawn(address indexed to, uint256 assets);
    event ClaimToppedUp(uint256 indexed id, address indexed user, uint256 shortfall);
    event CreateFeeProcessed(uint256 indexed id, uint256 truthBounty, uint256 reserveFunding, uint256 treasuryFunding);
    event TruthBountyPaid(uint256 indexed id, address indexed recipient, uint256 assets);
    event TruthBountyRoutedToTreasury(uint256 indexed id, uint256 assets);
    event DisputeRaked(uint256 indexed id, address indexed loser, uint256 rake);
    event PendingCredited(address indexed recipient, uint256 amount);
    event PendingWithdrawn(address indexed recipient, uint256 amount);
    event UmaModuleRevoked(address indexed module);
    event OracleVoteRevoked(uint256 indexed id, address indexed oracle, uint8 outcome);
    event MarketTagged(uint256 indexed id, string tag);
    event ReferralCredited(uint256 indexed id, address indexed referrer, uint256 amount);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys yPot core with immutable asset/vault references.
    /// @param _asset Underlying asset token address (must be 6 decimals).
    /// @param _vault ERC4626 vault address used for yield-bearing deposits.
    /// @param _treasury Treasury address receiving protocol fees.
    /// @param _oracles Initial oracle committee addresses (2-9 unique non-zero).
    constructor(address _asset, address _vault, address _treasury, address[] memory _oracles) Ownable(msg.sender) {
        if (_asset == address(0) || _vault == address(0) || _treasury == address(0)) {
            revert E1();
        }
        if (IERC20Metadata(_asset).decimals() != 6) revert E1();
        if (_oracles.length < 2) revert E1();
        if (_oracles.length > MAX_ORACLES) revert E1();

        asset = IERC20(_asset);
        vault = IERC4626(_vault);
        if (vault.asset() != _asset) revert E1();

        treasury = _treasury;
        minReportBond = 100e6;

        for (uint256 i; i < _oracles.length;) {
            address o = _oracles[i];
            if (o == address(0) || oracles[o]) revert E1();
            oracles[o] = true;
            oracleAddedAt[o] = uint64(block.timestamp);
            unchecked {
                ++oracleN;
                ++i;
            }
        }
        if (oracleN < confirms) revert E1();
    }

    /// @notice Accepts ETH transfers and emits an accounting event.
    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }

    // -------------------------------------------------------------------------
    // Views (smaller focused functions to avoid stack-too-deep)
    // -------------------------------------------------------------------------

    /// @notice Returns dispute mode for a market.
    /// @param id Market identifier.
    /// @return Dispute mode enum value.
    function getDisputeMode(uint256 id) external view returns (uint8) {
        return _m[id].disputeMode;
    }

    /// @notice Returns loser-bond rake in basis points (required by yPotUma).
    function disputeRakeBps() external pure returns (uint256) {
        return DISPUTE_RAKE_BPS;
    }

    /// @notice Returns core market metadata and state.
    /// @param id Market identifier.
    /// @return desc Human-readable market description.
    /// @return cid Off-chain metadata CID.
    /// @return created Market creation timestamp.
    /// @return deadline Betting deadline timestamp.
    /// @return resTime Earliest reporting timestamp.
    /// @return resolved Resolution timestamp.
    /// @return outcomes Number of valid outcomes.
    /// @return winner Winning outcome index.
    /// @return status Current market status code.
    /// @return creator Market creator address.
    /// @return prin Total principal deposited into the market.
    function getMkt(uint256 id)
        external
        view
        returns (
            string memory desc,
            string memory cid,
            uint64 created,
            uint64 deadline,
            uint64 resTime,
            uint64 resolved,
            uint8 outcomes,
            uint8 winner,
            uint8 status,
            address creator,
            uint256 prin
        )
    {
        Mkt storage m = _m[id];
        return (
            m.desc,
            m.cid,
            m.created,
            m.deadline,
            m.resTime,
            m.resolved,
            m.outcomes,
            m.winner,
            m.status,
            m.creator,
            m.prin
        );
    }

    /// @notice Returns aggregate share totals for a market.
    /// @param id Market identifier.
    /// @return tot Total shares in the market.
    /// @return claimed Shares already claimed.
    /// @return confirmTot Total confirmation shares posted.
    function getMktTotals(uint256 id) external view returns (uint256 tot, uint256 claimed, uint256 confirmTot) {
        Mkt storage m = _m[id];
        return (m.tot, m.claimed, m.confirmTot);
    }

    /// @notice Returns UMA appeal metadata for a market.
    /// @param id Market identifier.
    /// @return appealDeadline Last timestamp to start UMA appeal.
    /// @return umaStartedAt Timestamp when UMA appeal was started.
    /// @return umaAppellant Address that posted UMA appeal bond.
    /// @return umaAppealBond UMA appeal bond amount.
    function getAppealInfo(uint256 id)
        external
        view
        returns (uint64 appealDeadline, uint64 umaStartedAt, address umaAppellant, uint256 umaAppealBond)
    {
        Mkt storage m = _m[id];
        return (m.appealDeadline, m.umaStartedAt, m.umaAppellant, m.umaAppealBond);
    }

    /// @notice Returns reporter/challenger bond state for a market.
    /// @param id Market identifier.
    /// @return reporter Reporter address.
    /// @return outcome Reported outcome.
    /// @return bond Reporter bond amount.
    /// @return reportedAt Report timestamp.
    /// @return confirmBpsSnapshot Confirm threshold snapshot captured at report time.
    /// @return challenger Challenger address.
    /// @return challengeOutcome Challenged outcome.
    /// @return challengeBond Challenger bond amount.
    function getReport(uint256 id)
        external
        view
        returns (
            address reporter,
            uint8 outcome,
            uint256 bond,
            uint64 reportedAt,
            uint16 confirmBpsSnapshot,
            address challenger,
            uint8 challengeOutcome,
            uint256 challengeBond
        )
    {
        Report storage r = _m[id].report;
        return (
            r.reporter,
            r.outcome,
            r.bond,
            r.reportedAt,
            r.confirmBpsSnapshot,
            r.challenger,
            r.challengeOutcome,
            r.challengeBond
        );
    }

    /// @notice Returns confirmation bond position for a user.
    /// @param id Market identifier.
    /// @param u User address.
    /// @return userConfirmShares User confirmation shares.
    /// @return totalConfirmShares Total market confirmation shares.
    /// @return requiredConfirmShares Threshold shares required for acceptance.
    function getConfirm(uint256 id, address u)
        external
        view
        returns (uint256 userConfirmShares, uint256 totalConfirmShares, uint256 requiredConfirmShares)
    {
        Mkt storage m = _m[id];
        userConfirmShares = m.confirmSh[u];
        totalConfirmShares = m.confirmTot;

        // Use snapshotted confirmBps when report exists, otherwise current
        uint256 bps = m.report.reporter != address(0) ? uint256(m.report.confirmBpsSnapshot) : confirmBps;
        requiredConfirmShares = YPotLib.requiredConfirm(m.tot, bps);
    }

    /// @notice Returns per-outcome share vectors and totals for a market.
    /// @param id Market identifier.
    /// @return shares Raw shares by outcome index.
    /// @return weightedShares Weighted shares by outcome index.
    /// @return totalShares Total market shares.
    /// @return claimedShares Claimed market shares.
    /// @return remainingShares Unclaimed market shares.
    function getShares(uint256 id)
        external
        view
        returns (
            uint256[] memory shares,
            uint256[] memory weightedShares,
            uint256 totalShares,
            uint256 claimedShares,
            uint256 remainingShares
        )
    {
        Mkt storage m = _m[id];
        shares = m.sh;
        weightedShares = m.wsh;
        totalShares = m.tot;
        claimedShares = m.claimed;
        remainingShares = totalShares > claimedShares ? totalShares - claimedShares : 0;
    }

    /// @notice Returns user share vectors and claim status for a market.
    /// @param id Market identifier.
    /// @param u User address.
    /// @return s Raw user shares by outcome index.
    /// @return w Weighted user shares by outcome index.
    /// @return c Shares already claimed by user.
    /// @return d True when user has fully exited claims for this market.
    function getUsr(uint256 id, address u)
        external
        view
        returns (uint256[] memory s, uint256[] memory w, uint256 c, bool d)
    {
        Mkt storage m = _m[id];
        uint8 n = m.outcomes;
        s = new uint256[](n + 1);
        w = new uint256[](n + 1);
        for (uint8 i = 1; i <= n;) {
            s[i] = m.users[u].sh[i];
            w[i] = m.users[u].wsh[i];
            unchecked {
                ++i;
            }
        }
        c = m.users[u].claimed;
        d = m.users[u].done;
    }

    // -------------------------------------------------------------------------
    // Reserve & Truth Bounty Funding
    // -------------------------------------------------------------------------

    /// @notice Donate assets to the rounding reserve (excess routes to treasury once target is reached).
    /// @param assetsIn Amount of assets to transfer in.
    function fundReserve(uint256 assetsIn) external nonReentrant whenNotPaused {
        if (assetsIn == 0) revert E1();

        asset.safeTransferFrom(msg.sender, address(this), assetsIn);

        uint256 capacity = reserveAssets < RESERVE_TARGET_ASSETS ? RESERVE_TARGET_ASSETS - reserveAssets : 0;
        uint256 reserveAdded = assetsIn <= capacity ? assetsIn : capacity;
        uint256 treasuryRouted = assetsIn - reserveAdded;

        if (reserveAdded > 0) {
            reserveAssets += reserveAdded;
        }
        if (treasuryRouted > 0) {
            _creditPending(treasury, treasuryRouted);
        }

        emit ReserveFunded(msg.sender, reserveAdded, treasuryRouted);
    }

    /// @notice Withdraw from the rounding reserve to the treasury (owner only).
    /// @dev Keep this treasury-only to avoid "reserve rug" optics. The reserve is small and refills automatically.
    /// @param assets Amount of reserve assets to withdraw.
    function withdrawReserveToTreasury(uint256 assets) external onlyOwner nonReentrant {
        if (assets == 0) revert E1();
        if (assets > reserveAssets) revert E2();
        reserveAssets -= assets;
        _creditPending(treasury, assets);
        emit ReserveWithdrawn(treasury, assets);
    }

    /// @notice Legacy reserve withdraw API kept for compatibility.
    /// @param to Destination address, restricted to treasury.
    /// @param assets Amount of reserve assets to withdraw.
    function withdrawReserve(address to, uint256 assets) external onlyOwner nonReentrant {
        if (to != treasury) revert E1();
        if (assets == 0) revert E1();
        if (assets > reserveAssets) revert E2();
        reserveAssets -= assets;
        _creditPending(treasury, assets);
        emit ReserveWithdrawn(treasury, assets);
    }

    /// @notice Computes reporter bond requirement for a market.
    /// @param id Market identifier.
    /// @return bond Required report bond.
    function calcReportBond(uint256 id) public view returns (uint256 bond) {
        return YPotLib.calcBond(_m[id].prin, BOND_BPS, minReportBond);
    }

    // -------------------------------------------------------------------------
    // Core Betting
    // -------------------------------------------------------------------------

    /// @notice Creates a new prediction market.
    /// @param d Human-readable market description.
    /// @param cid Off-chain metadata CID.
    /// @param dl Betting deadline timestamp.
    /// @param rt Earliest report timestamp.
    /// @param n Number of outcomes (2-5).
    /// @return id Newly created market identifier.
    function create(
        string calldata d,
        string calldata cid,
        uint64 dl,
        uint64 rt,
        uint8 n,
        string calldata tag,
        address referrer
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        if (n < 2 || n > 5) revert E1();

        bytes memory db = bytes(d);
        uint256 dLen = db.length;
        if (dLen == 0 || dLen > MAX_DESC_BYTES) revert E1();
        if (bytes(cid).length > 128) revert E1();

        // Sanitize pipe character (UMA ancillary data delimiter)
        for (uint256 i; i < dLen;) {
            if (db[i] == 0x7C) revert E1(); // '|' = 0x7C
            unchecked {
                ++i;
            }
        }

        if (dl <= block.timestamp || rt <= dl) revert E1();

        uint256 dur = dl - block.timestamp;
        if (dur < MIN_MARKET_DURATION || dur > MAX_MARKET_DURATION) {
            revert E7();
        }
        if (uint256(rt) - uint256(dl) > MAX_RESOLUTION_DELAY) revert E7();

        id = counter++;
        Mkt storage m = _m[id];
        m.desc = d;
        m.cid = cid;
        m.created = uint64(block.timestamp);
        m.deadline = dl;
        m.resTime = rt;
        m.outcomes = n;
        m.creator = msg.sender;
        m.status = ST_OPEN;
        m.sh = new uint256[](n + 1);
        m.wsh = new uint256[](n + 1);

        if (fee > 0) {
            asset.safeTransferFrom(msg.sender, address(this), fee);

            (uint256 reporterBounty, uint256 reserveFunding, uint256 treasuryFunding) = _allocateCreateFee(fee);
            m.reporterBountyEscrow = reporterBounty;

            if (reserveFunding > 0) {
                reserveAssets += reserveFunding;
                emit ReserveAutoFunded(reserveFunding);
            }

            uint256 referralAmount;
            if (referrer != address(0) && referrer != msg.sender && treasuryFunding > 0) {
                referralAmount = Math.mulDiv(treasuryFunding, REFERRAL_BPS, BPS);
                _creditPending(referrer, referralAmount);
                emit ReferralCredited(id, referrer, referralAmount);
            }

            uint256 netTreasury = treasuryFunding - referralAmount;
            if (netTreasury > 0) {
                _creditPending(treasury, netTreasury);
            }

            emit CreateFeeProcessed(id, reporterBounty, reserveFunding, netTreasury);
        }

        emit MarketCreated(id, msg.sender, dl, n);
        if (bytes(cid).length != 0) emit MarketMetadata(id, cid);
        if (bytes(tag).length != 0) emit MarketTagged(id, tag);
    }

    /// @notice Places a bet on a specific market outcome.
    /// @param id Market identifier.
    /// @param o Outcome index to back.
    /// @param a Asset amount to stake.
    /// @param minShares Minimum acceptable shares to protect against slippage.
    /// @param txDeadline Transaction deadline timestamp.
    function bet(uint256 id, uint8 o, uint256 a, uint256 minShares, uint256 txDeadline)
        external
        nonReentrant
        whenNotPaused
    {
        if (block.timestamp > txDeadline) revert E4();
        _betInternal(id, o, a, minShares);
    }

    /// @notice Places bets across multiple markets in a single transaction.
    /// @param ids Market identifiers.
    /// @param outcomes Outcome indices to back.
    /// @param amounts Asset amounts to stake.
    /// @param minShares Minimum acceptable shares per bet.
    /// @param txDeadline Transaction deadline timestamp.
    function batchBet(
        uint256[] calldata ids,
        uint8[] calldata outcomes,
        uint256[] calldata amounts,
        uint256[] calldata minShares,
        uint256 txDeadline
    ) external nonReentrant whenNotPaused {
        if (block.timestamp > txDeadline) revert E4();
        uint256 len = ids.length;
        if (len == 0) revert E1();
        if (len > MAX_BATCH_BETS) revert E1();
        if (len != outcomes.length || len != amounts.length || len != minShares.length) revert E1();

        for (uint256 i; i < len;) {
            _betInternal(ids[i], outcomes[i], amounts[i], minShares[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _betInternal(uint256 id, uint8 o, uint256 a, uint256 minSh) internal {
        Mkt storage m = _m[id];
        if (m.created == 0) revert E1();
        if (m.status != ST_OPEN) revert E2();
        if (block.timestamp > m.deadline) revert E2();
        if (o < 1 || o > m.outcomes) revert E1();
        if (a < minBet || a > maxBet) revert E1();

        asset.safeTransferFrom(msg.sender, address(this), a);
        _approveVaultIfNeeded(a);

        uint256 exp = vault.previewDeposit(a);
        uint256 s = vault.deposit(a, address(this));

        if (s < Math.mulDiv(exp, slippageBps, BPS) || s < minSh) {
            revert E6();
        }

        accountedShares += s;

        uint256 ws = Math.mulDiv(s, YPotLib.wt(m.created, m.deadline, block.timestamp), BPS);

        m.users[msg.sender].sh[o] += s;
        m.users[msg.sender].wsh[o] += ws;
        m.users[msg.sender].prin[o] += a;
        m.sh[o] += s;
        m.wsh[o] += ws;
        m.tot += s;
        m.prin += a;

        emit BetPlaced(id, msg.sender, o, a, s);
    }

    /// @notice Closes betting once market deadline has passed.
    /// @param id Market identifier.
    function close(uint256 id) external {
        Mkt storage m = _m[id];
        if (m.created == 0 || m.status != ST_OPEN) revert E2();
        if (block.timestamp <= m.deadline) revert E2();
        m.status = ST_CLOSED;
    }

    // -------------------------------------------------------------------------
    // Reporter System (Tier 1)
    // -------------------------------------------------------------------------

    /// @notice Submits an initial report for a closed market.
    /// @param id Market identifier.
    /// @param o Reported winning outcome.
    function report(uint256 id, uint8 o) external nonReentrant {
        Mkt storage m = _m[id];
        if (m.status != ST_CLOSED) revert E2();
        if (block.timestamp < m.resTime) revert E2();
        if (o < 1 || o > m.outcomes) revert E1();
        if (m.report.reporter != address(0)) revert E9();
        if (msg.sender == m.creator) revert E3();

        uint256 bond = calcReportBond(id);
        asset.safeTransferFrom(msg.sender, address(this), bond);

        m.report = Report({
            reporter: msg.sender,
            outcome: o,
            bond: bond,
            reportedAt: uint64(block.timestamp),
            confirmBpsSnapshot: SafeCast.toUint16(confirmBps),
            challenger: address(0),
            challengeOutcome: 0,
            challengeBond: 0
        });
        m.status = ST_REPORTED;

        emit Reported(id, msg.sender, o, bond);
    }

    /// @notice Challenges an existing market report by posting matching bond.
    /// @param id Market identifier.
    /// @param o Challenged outcome to propose.
    function challenge(uint256 id, uint8 o) external nonReentrant {
        Mkt storage m = _m[id];
        if (m.status != ST_REPORTED) revert E2();
        if (msg.sender == m.report.reporter) revert E3();
        if (m.report.challenger != address(0)) revert E8();
        if (block.timestamp > uint256(m.report.reportedAt) + CHALLENGE_WINDOW) revert E2();
        if (o < 1 || o > m.outcomes || o == m.report.outcome) revert E1();

        uint256 bond = m.report.bond;
        asset.safeTransferFrom(msg.sender, address(this), bond);

        m.report.challenger = msg.sender;
        m.report.challengeOutcome = o;
        m.report.challengeBond = bond;

        emit Challenged(id, msg.sender, o, bond);
    }

    /// @notice Posts confirmation stake supporting the current report.
    /// @param id Market identifier.
    /// @param assetsIn Assets to convert into confirmation shares.
    /// @param minShares Minimum acceptable confirmation shares.
    /// @param txDeadline Transaction deadline timestamp.
    function confirmReport(uint256 id, uint256 assetsIn, uint256 minShares, uint256 txDeadline)
        external
        nonReentrant
        whenNotPaused
    {
        if (block.timestamp > txDeadline) revert E4();
        Mkt storage m = _m[id];
        if (m.status != ST_REPORTED) revert E2();
        if (m.report.challenger != address(0)) revert E2();

        uint8 o = m.report.outcome;
        if (o < 1 || o > m.outcomes) revert E1();
        uint256 pos = m.users[msg.sender].sh[o];
        if (pos == 0) revert E1();
        if (assetsIn == 0) revert E1();

        uint256 maxConfirm = Math.mulDiv(pos, CONFIRM_MAX_MULTIPLIER_BPS, BPS);
        uint256 current = m.confirmSh[msg.sender];
        if (current >= maxConfirm) revert E2();

        asset.safeTransferFrom(msg.sender, address(this), assetsIn);
        _approveVaultIfNeeded(assetsIn);

        uint256 exp = vault.previewDeposit(assetsIn);
        uint256 s = vault.deposit(assetsIn, address(this));

        // Use configurable slippageBps
        if (s < Math.mulDiv(exp, slippageBps, BPS) || s < minShares) {
            revert E6();
        }

        uint256 next = current + s;
        if (next > maxConfirm) revert E1();

        m.confirmSh[msg.sender] = next;
        m.confirmTot += s;
        accountedShares += s;

        emit ReportConfirmed(id, msg.sender, assetsIn, s);
    }

    /// @notice Withdraws posted confirmation shares as assets.
    /// @param id Market identifier.
    /// @param shareRequest Requested confirmation shares to redeem (0 for all).
    /// @param minOut Minimum acceptable asset output.
    function withdrawConfirmBond(uint256 id, uint256 shareRequest, uint256 minOut) external nonReentrant {
        Mkt storage m = _m[id];
        if (m.created == 0) revert E1();

        uint8 st = m.status;
        // Confirmation bonds secure only the unchallenged optimistic path.
        // Once a challenge exists, they no longer gate resolution and can exit immediately.
        bool unlocked = (
            st == ST_RESOLVED || st == ST_CLAIMABLE || st == ST_CANCELLED || st == ST_SWEPT
                || st == ST_APPEALABLE || st == ST_UMA_PENDING
                || (st == ST_REPORTED && m.report.challenger != address(0))
        );
        if (!unlocked) {
            revert E2();
        }

        uint256 available = m.confirmSh[msg.sender];
        if (available == 0) revert E1();

        uint256 sharesToRedeem = (shareRequest == 0 || shareRequest >= available) ? available : shareRequest;
        if (sharesToRedeem == 0) revert E1();

        m.confirmSh[msg.sender] = available - sharesToRedeem;
        m.confirmTot -= sharesToRedeem;

        uint256 assetsOut = vault.redeem(sharesToRedeem, msg.sender, address(this));
        if (assetsOut < minOut) revert E6();
        accountedShares -= sharesToRedeem;

        emit ConfirmBondWithdrawn(id, msg.sender, assetsOut, sharesToRedeem);
    }

    /// @notice Accepts unchallenged report after challenge window and confirmation threshold.
    /// @param id Market identifier.
    function acceptReport(uint256 id) external nonReentrant {
        Mkt storage m = _m[id];
        if (m.status != ST_REPORTED) revert E2();
        if (m.report.challenger != address(0)) revert E2();
        if (block.timestamp <= uint256(m.report.reportedAt) + CHALLENGE_WINDOW) revert E2();

        uint8 o = m.report.outcome;
        if (o < 1 || o > m.outcomes) revert E1();

        // Use snapshotted confirmBps from report time
        uint256 required = YPotLib.requiredConfirm(m.tot, uint256(m.report.confirmBpsSnapshot));
        if (m.confirmTot < required) revert E2();

        m.winner = o;
        m.resolved = uint64(block.timestamp);
        m.status = ST_RESOLVED;

        uint256 b = m.report.bond;
        address r = m.report.reporter;
        m.report.bond = 0;
        _creditPending(r, b);

        emit Resolved(id, o);
    }

    /// @notice Cancels reported market if confirmation threshold was not met in time.
    /// @param id Market identifier.
    function expireUnconfirmedReport(uint256 id) external nonReentrant {
        Mkt storage m = _m[id];
        if (m.status != ST_REPORTED) revert E2();
        if (m.report.challenger != address(0)) revert E2();
        if (m.report.reporter == address(0)) revert E2();

        uint256 reportedAt = uint256(m.report.reportedAt);
        if (reportedAt == 0) revert E2();
        uint256 required = YPotLib.requiredConfirm(m.tot, uint256(m.report.confirmBpsSnapshot));
        if (m.confirmTot >= required) revert E2();
        if (block.timestamp <= reportedAt + CHALLENGE_WINDOW + CONFIRM_TIMEOUT) revert E2();

        uint256 b = m.report.bond;
        address r = m.report.reporter;
        m.report.bond = 0;

        m.status = ST_CANCELLED;
        _settleReporterBounty(id, m, false);

        if (b > 0) {
            _creditPending(r, b);
        }

        emit Cancelled(id);
    }

    // -------------------------------------------------------------------------
    // Internal Committee Voting (Tier 2)
    // -------------------------------------------------------------------------

    /// @notice Casts oracle committee vote to resolve a challenged report.
    /// @param id Market identifier.
    /// @param o Outcome selected by oracle.
    function resolveDispute(uint256 id, uint8 o) external nonReentrant {
        if (!oracles[msg.sender]) revert E3();

        Mkt storage m = _m[id];
        if (m.status != ST_REPORTED) revert E2();
        if (m.report.challenger == address(0)) revert E2();
        if (m.disputeMode == DISPUTE_UMA) revert E2();
        if (o < 1 || o > m.outcomes) revert E1();
        if (m.voted[msg.sender]) revert E2();
        // Oracle must have been in the set before the report was filed
        if (oracleAddedAt[msg.sender] > m.report.reportedAt) revert E3();

        m.voted[msg.sender] = true;
        m.oracleVoteOutcome[msg.sender] = o;
        m.votes[o]++;

        if (m.votes[o] >= confirms) {
            m.winner = o;
            m.appealDeadline = SafeCast.toUint64(block.timestamp + UMA_APPEAL_WINDOW);
            m.status = ST_APPEALABLE;
            ++umaAppealableCount;

            emit InternalResolved(id, o, m.appealDeadline);
        }
    }

    // -------------------------------------------------------------------------
    // UMA Module Hooks (Tier 3)
    // -------------------------------------------------------------------------

    function _checkUmaModule() internal view {
        if (msg.sender != umaModule) revert E3();
    }

    modifier onlyUmaModule() {
        _checkUmaModule();
        _;
    }

    /// @notice Sets UMA module address and grants it unlimited asset allowance.
    /// @dev Revoke existing module first if replacing. Cannot set while markets are UMA-pending.
    /// @param m UMA module contract address.
    function setUmaModule(address m) external onlyOwner {
        if (m == address(0)) revert E1();
        if (umaModule != address(0)) revert E2(); // Revoke first
        umaModule = m;
        asset.forceApprove(m, type(uint256).max);
        emit UmaModuleSet(m);
    }

    /// @notice Revokes UMA module approval and clears the module address.
    /// @dev Blocked while any market is in ST_UMA_PENDING to prevent orphaned appeals.
    function revokeUmaModule() external onlyOwner {
        address m = umaModule;
        if (m == address(0)) revert E1();
        if (umaActiveCount > 0 || umaAppealableCount > 0) revert E2();
        asset.forceApprove(m, 0);
        umaModule = address(0);
        emit UmaModuleRevoked(m);
    }

    /// @notice UMA hook: moves challenged market into UMA pending state.
    /// @param id Market identifier.
    /// @param appellant Address posting UMA appeal bond.
    /// @param appealBond UMA appeal bond amount.
    /// @return rb Reporter bond escrow amount.
    /// @return cb Challenger bond escrow amount.
    /// @return resTime Market resolution timestamp.
    /// @return committeeWinner Winner selected by committee before UMA.
    function umaBeginAppeal(uint256 id, address appellant, uint256 appealBond)
        external
        onlyUmaModule
        returns (uint256 rb, uint256 cb, uint64 resTime, uint8 committeeWinner)
    {
        Mkt storage m = _m[id];
        if (m.status != ST_APPEALABLE) revert E2();
        if (block.timestamp > uint256(m.appealDeadline)) revert E2();
        if (m.disputeMode == DISPUTE_UMA) revert E2();
        if (m.report.challenger == address(0)) revert E2();

        m.umaAppellant = appellant;
        m.umaAppealBond = appealBond;

        rb = m.report.bond;
        cb = m.report.challengeBond;
        if (rb == 0 || cb == 0 || rb != cb) revert E2();

        m.report.bond = 0;
        m.report.challengeBond = 0;

        m.disputeMode = DISPUTE_UMA;
        m.umaStartedAt = uint64(block.timestamp);
        m.status = ST_UMA_PENDING;
        --umaAppealableCount;
        ++umaActiveCount;

        resTime = m.resTime;
        committeeWinner = m.winner;
    }

    /// @notice UMA hook: consumes and clears stored UMA appeal bond.
    /// @param id Market identifier.
    /// @return appellant Address that posted UMA appeal bond.
    /// @return bond Bond amount consumed.
    function umaConsumeAppealBond(uint256 id) external onlyUmaModule returns (address appellant, uint256 bond) {
        Mkt storage m = _m[id];
        appellant = m.umaAppellant;
        bond = m.umaAppealBond;
        m.umaAppellant = address(0);
        m.umaAppealBond = 0;
    }

    /// @notice UMA hook: credits pending withdrawals instead of transferring directly.
    /// @param recipient Recipient to credit.
    /// @param amount Asset amount to credit.
    function umaCreditPending(address recipient, uint256 amount) external onlyUmaModule {
        _creditPending(recipient, amount);
    }

    /// @notice UMA hook: finalizes market with UMA winner.
    /// @param id Market identifier.
    /// @param winner Winning outcome returned by UMA.
    function umaResolve(uint256 id, uint8 winner) external onlyUmaModule {
        Mkt storage m = _m[id];
        if (m.status != ST_UMA_PENDING) revert E2();
        if (m.disputeMode != DISPUTE_UMA) revert E2();
        if (winner < 1 || winner > m.outcomes) revert E1();
        m.winner = winner;
        m.resolved = uint64(block.timestamp);
        m.status = ST_RESOLVED;
        --umaActiveCount;
        emit Resolved(id, winner);
    }

    /// @notice UMA hook: cancels market from UMA pending state.
    /// @param id Market identifier.
    function umaCancel(uint256 id) external onlyUmaModule {
        Mkt storage m = _m[id];
        if (m.status != ST_UMA_PENDING) revert E2();

        m.status = ST_CANCELLED;
        --umaActiveCount;
        _settleReporterBounty(id, m, false);

        emit Cancelled(id);
    }

    // -------------------------------------------------------------------------
    // Finalization / Expiry
    // -------------------------------------------------------------------------

    /// @notice Finalizes a resolved market into claimable/cancelled state.
    /// @dev If the market is in `ST_APPEALABLE`, this function can also resolve it once the UMA appeal window expires.
    /// @param id Market identifier.
    function finalize(uint256 id) external nonReentrant {
        Mkt storage m = _m[id];

        if (m.status == ST_APPEALABLE) {
            if (block.timestamp <= uint256(m.appealDeadline)) revert E2();
            if (m.disputeMode == DISPUTE_UMA) revert E2();

            m.resolved = m.appealDeadline;
            m.status = ST_RESOLVED;
            --umaAppealableCount;

            _distributeEscrowedBonds(id, m, m.winner);

            emit Resolved(id, m.winner);
        }

        if (m.status != ST_RESOLVED) revert E2();
        if (block.timestamp < uint256(m.resolved) + DISPUTE_PERIOD) revert E2();

        if (m.wsh[m.winner] == 0) {
            m.status = ST_CANCELLED;
            _settleReporterBounty(id, m, false);
            emit Cancelled(id);
            return;
        }

        m.status = ST_CLAIMABLE;
        _settleReporterBounty(id, m, true);
    }

    /// @notice Expires a stale closed market that never received a report.
    /// @param id Market identifier.
    function expireMarket(uint256 id) external {
        Mkt storage m = _m[id];
        if (m.status != ST_CLOSED) revert E2();
        if (block.timestamp <= uint256(m.resTime) + 7 days) revert E2();

        m.status = ST_CANCELLED;
        _settleReporterBounty(id, m, false);

        emit Cancelled(id);
    }

    /// @notice Expires unresolved challenge after grace period and refunds bonds.
    /// @param id Market identifier.
    function expireChallenge(uint256 id) external nonReentrant {
        Mkt storage m = _m[id];
        if (m.status != ST_REPORTED) revert E2();
        if (m.report.challenger == address(0)) revert E2();
        if (m.disputeMode == DISPUTE_UMA) revert E2();
        if (block.timestamp <= uint256(m.report.reportedAt) + CHALLENGE_WINDOW + 7 days) revert E2();

        uint256 rb = m.report.bond;
        uint256 cb = m.report.challengeBond;
        m.report.bond = 0;
        m.report.challengeBond = 0;

        m.status = ST_CANCELLED;
        _settleReporterBounty(id, m, false);

        _creditPending(m.report.reporter, rb);
        _creditPending(m.report.challenger, cb);

        emit Cancelled(id);
    }

    // -------------------------------------------------------------------------
    // Claims
    // -------------------------------------------------------------------------

    /// @notice Claims payout for a single market.
    /// @param id Market identifier.
    /// @param shareRequest Requested claim shares (0 for all available).
    /// @param minOut Minimum acceptable asset payout.
    function claim(uint256 id, uint256 shareRequest, uint256 minOut) external nonReentrant {
        _claimInternal(id, shareRequest, minOut);
    }

    /// @notice Claims payouts across multiple markets in one transaction.
    /// @param ids Market identifiers.
    /// @param minOuts Minimum acceptable payout per market, aligned by index.
    function batchClaim(uint256[] calldata ids, uint256[] calldata minOuts) external nonReentrant {
        uint256 len = ids.length;
        if (len != minOuts.length) revert E1();
        if (len == 0) revert E1();
        if (len > MAX_BATCH_CLAIMS) revert E1();

        for (uint256 i; i < len;) {
            _claimInternal(ids[i], 0, minOuts[i]); // 0 = claim all available
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Internal claim path shared by single and batch claims.
    /// @param id Market identifier.
    /// @param shareRequest Requested claim shares (0 for all available).
    /// @param minOut Minimum acceptable asset payout.
    function _claimInternal(uint256 id, uint256 shareRequest, uint256 minOut) internal {
        Mkt storage m = _m[id];
        if (m.status != ST_CLAIMABLE) revert E2();

        Usr storage u = m.users[msg.sender];

        // Declare before blocks so they survive into the second block and the emit.
        uint256 sharesToRedeem;
        uint256 pool;
        bool fullClaim;

        // Block 1: entitlement calculation — uw/tw/entitledShares/availableShares
        // are popped off the stack when this block exits, freeing slots for Block 2.
        {
            uint256 uw = u.wsh[m.winner];
            if (uw == 0) revert E1();
            uint256 tw = m.wsh[m.winner];
            if (tw == 0) revert E2();
            pool = m.tot;
            if (pool == 0) revert E2();
            uint256 entitledShares = Math.mulDiv(uw, pool, tw);
            if (u.claimed >= entitledShares) revert E1();
            uint256 availableShares = entitledShares - u.claimed;
            fullClaim = (shareRequest == 0 || shareRequest >= availableShares);
            sharesToRedeem = fullClaim ? availableShares : shareRequest;
            if (sharesToRedeem == 0) revert E1();
        }

        if (fullClaim) u.done = true;
        u.claimed += sharesToRedeem;
        m.claimed += sharesToRedeem;

        uint256 payout;

        // Block 2: redemption and fee calculation — assetsOut/cp/tf are popped
        // before the emit, leaving only the ~11 slots needed for Claimed.
        {
            uint256 assetsOut = vault.redeem(sharesToRedeem, address(this), address(this));
            accountedShares -= sharesToRedeem;
            uint256 cp = Math.mulDiv(m.prin, sharesToRedeem, pool);

            // If the vault redeem rounds down, a full claim can fall short of its principal by tiny dust.
            // We only ever top up tiny amounts from the rounding reserve (never to cover real losses).
            if (assetsOut < cp && fullClaim) {
                uint256 shortfall = cp - assetsOut;
                if (shortfall <= MAX_ROUNDING_TOPUP_ASSETS && reserveAssets >= shortfall) {
                    reserveAssets -= shortfall;
                    assetsOut += shortfall;
                    emit ClaimToppedUp(id, msg.sender, shortfall);
                }
            }

            if (assetsOut < minOut) revert E6();

            uint256 tf = 0;
            if (assetsOut > cp) {
                tf = Math.mulDiv(assetsOut - cp, YIELD_FEE_BPS, BPS);
            }

            payout = assetsOut - tf;
            asset.safeTransfer(msg.sender, payout);
            if (tf > 0) _distributeFees(m, tf);
        }

        emit Claimed(id, msg.sender, payout);
    }

    /// @notice Allows principal-only exit from cancelled market.
    /// @param id Market identifier.
    /// @param minOut Minimum acceptable redeemed assets.
    function emergencyWithdraw(uint256 id, uint256 minOut) external nonReentrant {
        Mkt storage m = _m[id];
        if (m.status != ST_CANCELLED) revert E2();

        Usr storage u = m.users[msg.sender];
        if (u.done) revert E2();

        uint256 t = 0;
        for (uint8 i = 1; i <= m.outcomes;) {
            t += u.sh[i];
            unchecked {
                ++i;
            }
        }
        if (t == 0) revert E1();

        m.claimed += t;
        u.done = true;

        uint256 out = vault.redeem(t, msg.sender, address(this));
        if (out < minOut) revert E6();
        accountedShares -= t;

        emit EmergencyWithdraw(id, msg.sender, out);
    }

    /// @notice Sweeps long-unclaimed market dust to treasury after delay.
    /// @param id Market identifier.
    /// @param minOut Minimum acceptable assets from sweep redemption.
    function sweepDust(uint256 id, uint256 minOut) external nonReentrant {
        Mkt storage m = _m[id];
        if (m.status != ST_CLAIMABLE) revert E2();
        if (block.timestamp < uint256(m.resolved) + DISPUTE_PERIOD + SWEEP_DELAY) revert E2();

        uint256 total = m.tot;
        uint256 remainingShares = total > m.claimed ? total - m.claimed : 0;

        m.claimed = total;
        m.status = ST_SWEPT;

        if (remainingShares == 0) {
            emit Swept(id, 0, 0);
            return;
        }

        uint256 assetsOut = vault.redeem(remainingShares, address(this), address(this));
        if (assetsOut < minOut) revert E6();
        accountedShares -= remainingShares;

        _creditPending(treasury, assetsOut);
        emit Swept(id, remainingShares, assetsOut);
    }

    // -------------------------------------------------------------------------
    // Admin (Owner)
    // -------------------------------------------------------------------------

    /// @notice Sets treasury address.
    /// @param t New treasury address.
    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert E1();
        treasury = t;
    }

    /// @notice Sets min and max bet limits.
    /// @param mn Minimum bet amount.
    /// @param mx Maximum bet amount.
    function setLimits(uint256 mn, uint256 mx) external onlyOwner {
        if (mn == 0 || mx <= mn) revert E1();
        minBet = mn;
        maxBet = mx;
    }

    /// @notice Sets market creation fee.
    /// @param f Creation fee amount.
    function setFee(uint256 f) external onlyOwner {
        if (f > MAX_CREATE_FEE) revert E1();
        fee = f;
    }

    /// @notice Sets required oracle confirmations for committee resolution.
    /// @param c Required confirmation count.
    function setConfirms(uint256 c) external onlyOwner {
        if (oracleN < 2) revert E2();
        if (c < 2 || c > oracleN) revert E1();
        // Require strict majority to prevent split-brain races
        if (c <= oracleN / 2) revert E1();
        confirms = c;
    }

    /// @notice Adds or removes an oracle address.
    /// @param o Oracle address.
    /// @param a True to enable/add, false to disable/remove.
    function setOracle(address o, bool a) external onlyOwner {
        if (o == address(0)) revert E1();

        if (a && !oracles[o]) {
            if (oracleN >= MAX_ORACLES) revert E1();
            oracleAddedAt[o] = uint64(block.timestamp);
            unchecked {
                ++oracleN;
            }
        } else if (!a && oracles[o]) {
            if (oracleN <= confirms) revert E1();
            if (oracleN <= 2) revert E1();
            unchecked {
                --oracleN;
            }
        }

        oracles[o] = a;
        emit OracleSet(o, a);
    }

    /// @notice Revokes a removed oracle's vote on a specific disputed market.
    /// @dev Only callable on ST_REPORTED markets with an active challenge, after oracle removal.
    /// @param id Market identifier.
    /// @param oracle Oracle address whose vote to revoke.
    function revokeOracleVote(uint256 id, address oracle) external onlyOwner {
        Mkt storage m = _m[id];
        if (m.status != ST_REPORTED) revert E2();
        if (m.report.challenger == address(0)) revert E2();
        if (!m.voted[oracle]) revert E1();
        if (oracles[oracle]) revert E3(); // must be removed first

        uint8 o = m.oracleVoteOutcome[oracle];
        m.votes[o]--;
        m.voted[oracle] = false;
        delete m.oracleVoteOutcome[oracle];

        emit OracleVoteRevoked(id, oracle, o);
    }

    /// @notice Sets report confirmation threshold in basis points.
    /// @param bps Confirmation threshold in basis points.
    function setConfirmBps(uint256 bps) external onlyOwner {
        if (bps > BPS) revert E1();
        confirmBps = bps;
        emit ConfirmBpsSet(bps);
    }

    /// @notice Set slippage tolerance for vault deposits
    /// @param bps Slippage in basis points (9900 = 1% max slippage)
    function setSlippage(uint256 bps) external onlyOwner {
        if (bps < MIN_SLIPPAGE_BPS || bps > MAX_SLIPPAGE_BPS) revert E1();
        slippageBps = bps;
        emit SlippageBpsSet(bps);
    }

    // -------------------------------------------------------------------------
    // Admin (Immediate)
    // -------------------------------------------------------------------------

    /// @notice Cancels a market before resolution window.
    /// @param id Market identifier.
    function cancel(uint256 id) external onlyOwner {
        Mkt storage m = _m[id];
        if (m.created == 0) revert E1();

        if (block.timestamp >= m.resTime) revert E2();

        if (
            m.status == ST_REPORTED || m.status == ST_RESOLVED || m.status == ST_APPEALABLE
                || m.status == ST_UMA_PENDING
        ) {
            revert E2();
        }
        if (m.status > ST_RESOLVED) revert E2();

        m.status = ST_CANCELLED;
        _settleReporterBounty(id, m, false);
        emit Cancelled(id);
    }

    /// @notice Pauses protocol actions guarded by `whenNotPaused`.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses protocol actions guarded by `whenNotPaused`.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Sends all native ETH balance to recipient.
    /// @param to Recipient address.
    function rescueEth(address payable to) external onlyOwner {
        if (to == address(0)) revert E1();
        uint256 bal = address(this).balance;
        if (bal > 0) {
            Address.sendValue(to, bal);
        }
    }

    /// @notice Redeems and sweeps vault shares not tracked as user liabilities.
    /// @dev Intentionally permissionless — excess shares are sent to treasury, so there is no
    ///      griefing vector. Anyone can call this to reclaim unaccounted vault shares.
    /// @param shareAmount Requested excess shares to redeem (0 for all excess).
    /// @param minOut Minimum acceptable assets from redemption.
    function sweepExcessVaultShares(uint256 shareAmount, uint256 minOut) external nonReentrant {
        uint256 bal = vault.balanceOf(address(this));
        uint256 excess = bal > accountedShares ? bal - accountedShares : 0;
        if (excess == 0) return;

        uint256 toRedeem = (shareAmount == 0 || shareAmount > excess) ? excess : shareAmount;
        uint256 out = vault.redeem(toRedeem, address(this), address(this));
        if (out < minOut) revert E6();
        _creditPending(treasury, out);
        emit ExcessSharesSwept(toRedeem, out);
    }

    // -------------------------------------------------------------------------
    // Pull-Based Withdrawals
    // -------------------------------------------------------------------------

    /// @notice Withdraw accumulated fee/bond credits.
    function withdrawPending() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert E1();
        pendingWithdrawals[msg.sender] = 0;
        asset.safeTransfer(msg.sender, amount);
        emit PendingWithdrawn(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @notice Credits assets for pull-based withdrawal instead of direct transfer.
    /// @param recipient Address to credit.
    /// @param amount Asset amount to credit.
    function _creditPending(address recipient, uint256 amount) internal {
        pendingWithdrawals[recipient] += amount;
        emit PendingCredited(recipient, amount);
    }

    function _approveVaultIfNeeded(uint256 amount) internal {
        uint256 allowance = asset.allowance(address(this), address(vault));
        if (allowance < amount) {
            asset.forceApprove(address(vault), type(uint256).max);
        }
    }

    /// @notice Distributes yield fee across truth-teller, reserve, and treasury.
    /// @param m Market storage pointer.
    /// @param tf Total fee amount to distribute.
    function _distributeFees(Mkt storage m, uint256 tf) internal {
        address tt = _truthTeller(m);
        uint256 truthFee = tt != address(0) ? Math.mulDiv(tf, YIELD_REPORTER_REWARD_BPS, BPS) : 0;
        uint256 reserveFee = Math.mulDiv(tf, YIELD_RESERVE_BPS, BPS);

        // Cap reserve to target; route excess to treasury.
        uint256 capacity = reserveAssets < RESERVE_TARGET_ASSETS ? RESERVE_TARGET_ASSETS - reserveAssets : 0;
        uint256 reserveAdded = reserveFee <= capacity ? reserveFee : capacity;

        if (reserveAdded > 0) {
            reserveAssets += reserveAdded;
            emit ReserveAutoFunded(reserveAdded);
        }

        uint256 treasuryFee = tf - truthFee - reserveAdded;

        if (treasuryFee > 0) {
            _creditPending(treasury, treasuryFee);
        }

        if (truthFee > 0) {
            _creditPending(tt, truthFee);
        }
    }

    /// @notice Distributes escrowed report/challenge bonds after dispute resolution.
    /// @dev For challenged markets, the loser bond is partially raked to treasury (see `DISPUTE_RAKE_BPS`).
    /// @param id Market identifier.
    /// @param m Market storage pointer.
    /// @param winner Final winner outcome index.
    function _distributeEscrowedBonds(uint256 id, Mkt storage m, uint8 winner) internal {
        uint256 tb = m.report.bond + m.report.challengeBond;
        if (tb == 0) return;

        uint256 rb = m.report.bond;
        uint256 cb = m.report.challengeBond;
        m.report.bond = 0;
        m.report.challengeBond = 0;

        if (cb == 0 && rb > 0) {
            _creditPending(m.report.reporter, rb);
            return;
        }
        if (rb == 0 && cb > 0) {
            _creditPending(m.report.challenger, cb);
            return;
        }

        address winAddr;
        address loserAddr;
        uint256 loserBond;
        if (winner == m.report.outcome) {
            winAddr = m.report.reporter;
            loserAddr = m.report.challenger;
            loserBond = cb;
        } else if (winner == m.report.challengeOutcome) {
            winAddr = m.report.challenger;
            loserAddr = m.report.reporter;
            loserBond = rb;
        } else {
            _creditPending(treasury, tb);
            return;
        }

        uint256 rake = Math.mulDiv(loserBond, DISPUTE_RAKE_BPS, BPS);
        if (rake > 0) {
            _creditPending(treasury, rake);
            emit DisputeRaked(id, loserAddr, rake);
        }
        _creditPending(winAddr, tb - rake);
    }

    /// @notice Settles truth bounty escrow to truth-teller or treasury.
    /// @param id Market identifier.
    /// @param m Market storage pointer.
    /// @param reportWasValid True when final outcome validates a reported side.
    function _settleReporterBounty(uint256 id, Mkt storage m, bool reportWasValid) internal {
        uint256 bounty = m.reporterBountyEscrow;
        if (bounty == 0) return;

        m.reporterBountyEscrow = 0;

        address tt = reportWasValid ? _truthTeller(m) : address(0);
        if (tt != address(0)) {
            _creditPending(tt, bounty);
            emit TruthBountyPaid(id, tt, bounty);
        } else {
            _creditPending(treasury, bounty);
            emit TruthBountyRoutedToTreasury(id, bounty);
        }
    }

    /// @dev Returns the party whose proposed outcome matches the final winner.
    function _truthTeller(Mkt storage m) internal view returns (address) {
        Report storage r = m.report;
        if (r.reporter == address(0)) return address(0);

        // No challenge → reporter is the truth-teller.
        if (r.challenger == address(0)) return r.reporter;

        // Challenged → whoever proposed the winning outcome.
        if (m.winner == r.outcome) return r.reporter;
        if (m.winner == r.challengeOutcome) return r.challenger;

        // Fallback: neither matched (e.g. oracle override to a third outcome).
        return address(0);
    }

    function _allocateCreateFee(uint256 amount)
        internal
        view
        returns (uint256 reporterBounty, uint256 reserveFunding, uint256 treasuryFunding)
    {
        reporterBounty = Math.mulDiv(amount, CREATE_REPORTER_BOUNTY_BPS, BPS);
        reserveFunding = Math.mulDiv(amount, CREATE_RESERVE_BPS, BPS);

        uint256 capacity = reserveAssets < RESERVE_TARGET_ASSETS ? RESERVE_TARGET_ASSETS - reserveAssets : 0;
        if (reserveFunding > capacity) {
            reserveFunding = capacity;
        }

        treasuryFunding = amount - reporterBounty - reserveFunding;
    }
}
