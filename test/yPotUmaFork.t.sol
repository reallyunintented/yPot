// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";
import {yPotUma} from "src/yPotUma.sol";
import {UmaOptimisticOracleAdapter} from "src/UmaOptimisticOracleAdapter.sol";

import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

/**
 * @notice Fork tests validating ABI compatibility against a real UMA Optimistic Oracle deployment.
 *
 * @dev Required env vars:
 *   FORK_RPC_URL    — RPC endpoint (Sepolia, Arbitrum, Polygon, or Ethereum mainnet)
 *   FORK_UMA_OO     — UMA Optimistic Oracle address on the target chain
 *
 * Optional env vars:
 *   FORK_USDC                     — ERC20 currency address (defaults to ETH mainnet USDC)
 *   FORK_BLOCK_NUMBER             — Pin fork to a specific block for reproducibility
 *   FORK_UMA_IDENTIFIER_WHITELIST — IdentifierWhitelist contract; if set, pranks its owner
 *                                    to register YPOT_LOCAL before tests run
 *   FORK_REQUIRED                 — If "true", setUp failure hard-reverts instead of skipping
 *
 * Tests are skipped gracefully when env vars are absent. Set FORK_REQUIRED=true to fail
 * loudly in CI.
 *
 * Chain notes:
 *   Ethereum mainnet — UMA OO V2 + V3 available; USDC already in CollateralWhitelist
 *   Arbitrum         — UMA OO V2 available
 *   Polygon          — UMA OO V2 available
 *   Sepolia testnet  — UMA OO available for testing
 *   Base / BSC       — No UMA deployment; umaModule = address(0) in production
 */
contract yPotUmaForkTest is Test {
    error ForkRequirementFailed(string reason);

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    bool internal forkReady;
    bool internal requireFork;

    address internal constant DEFAULT_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 internal constant DEFAULT_LIVENESS = 7200; // 2 hours
    bytes32 internal constant YPOT_IDENTIFIER = keccak256("YPOT_LOCAL");

    IERC20 internal usdc;
    address internal umaOO;

    address internal treasury = address(0xBEEF);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);
    address internal creator = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal reporter = address(0x3333);
    address internal challenger = address(0x4444);
    address internal appellant = address(0x5555);

    modifier onlyFork() {
        if (!forkReady) return;
        _;
    }

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        requireFork = vm.envOr("FORK_REQUIRED", false);

        string memory rpcUrl = vm.envOr("FORK_RPC_URL", string(""));
        umaOO = vm.envOr("FORK_UMA_OO", address(0));

        if (bytes(rpcUrl).length == 0 || umaOO == address(0)) {
            _requireForkInputs("Missing FORK_RPC_URL or FORK_UMA_OO");
            forkReady = false;
            return;
        }

        uint256 blockNumber = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        uint256 forkId = blockNumber == 0 ? vm.createFork(rpcUrl) : vm.createFork(rpcUrl, blockNumber);
        vm.selectFork(forkId);

        usdc = IERC20(vm.envOr("FORK_USDC", DEFAULT_USDC));

        // Register the YPOT_LOCAL identifier in UMA's IdentifierWhitelist if provided.
        address identifierWhitelist = vm.envOr("FORK_UMA_IDENTIFIER_WHITELIST", address(0));
        if (identifierWhitelist != address(0)) {
            _whitelistIdentifier(identifierWhitelist, YPOT_IDENTIFIER);
        }

        forkReady = true;
    }

    // -------------------------------------------------------------------------
    // Test 1: ABI compatibility — request → propose → settle
    // -------------------------------------------------------------------------

    /**
     * @notice Verifies ABI compatibility of the UMA OO on the target chain for the full
     *         request-propose-settle lifecycle (no dispute, proposer bond refunded).
     *
     * Proves: requestPrice, setBond, proposePrice/proposePriceFor, settle/settleAndGetPrice
     *         all work correctly against the live oracle ABI.
     */
    function testFork_adapter_abiCompatible_requestProposeSettle() public onlyFork {
        uint256 bondPerSide = 100e6; // 100 USDC per side

        address[] memory requesters = new address[](1);
        requesters[0] = address(this);
        UmaOptimisticOracleAdapter adapterFork =
            new UmaOptimisticOracleAdapter(umaOO, usdc, YPOT_IDENTIFIER, 0, 0, 0, requesters);

        // Fund adapter with 2x bond (propose + potential dispute).
        deal(address(usdc), address(adapterFork), bondPerSide * 2, true);

        // Use a timestamp in the past so UMA accepts it as a valid price request.
        uint256 ts = block.timestamp - 1;
        bytes memory ancillary = bytes("yPotUmaFork: abi compat test");
        int256 proposedPrice = int256(1);

        adapterFork.requestAndProposeWithBond(ts, ancillary, proposedPrice, bondPerSide);

        // Determine liveness: try oracle's defaultLiveness(), fall back to 2 hours.
        uint256 liveness = _readDefaultLiveness(umaOO);
        vm.warp(block.timestamp + liveness + 1);

        int256 settled = adapterFork.settle(ts, ancillary);

        assertEq(settled, proposedPrice, "settled price should equal proposed price");
        assertGt(adapterFork.getClaimable(ts, ancillary), 0, "adapter should have claimable bonds after settle");
    }

    // -------------------------------------------------------------------------
    // Test 2: Full appeal expire path → committee winner
    // -------------------------------------------------------------------------

    /**
     * @notice Deploys the full yPot stack against the real UMA OO and runs the appeal
     *         expire path. DVM voting is not triggered (can't be done via fork without
     *         pranking the entire voter set); the 30-day timeout causes the appeal to
     *         expire and the committee winner to prevail.
     *
     * Proves: startUmaAppeal sends valid requests to the live oracle (requestPrice,
     *         setBond, proposePrice/proposePriceFor, disputePrice/disputePriceFor),
     *         and expireUmaAppeal gracefully handles an unresolved oracle.
     */
    function testFork_fullAppealExpires_toCommitteeWinner() public onlyFork {
        // Deploy full stack using real USDC as the shared asset.
        MockERC4626Vault yearnMock = new MockERC4626Vault(usdc);

        address[] memory initialDepositors = new address[](1);
        initialDepositors[0] = address(this);
        YearnWrapper wrapper = new YearnWrapper(usdc, IERC4626(address(yearnMock)), initialDepositors);

        address[] memory oracles = new address[](2);
        oracles[0] = oracle0;
        oracles[1] = oracle1;
        yPot pot = new yPot(address(usdc), address(wrapper), treasury, oracles);
        wrapper.setDepositor(address(pot), true);

        address[] memory requesters = new address[](1);
        requesters[0] = address(this);
        UmaOptimisticOracleAdapter adapterFork =
            new UmaOptimisticOracleAdapter(umaOO, usdc, YPOT_IDENTIFIER, 0, 0, 0, requesters);

        yPotUma module = new yPotUma(address(pot), address(adapterFork));
        pot.setUmaModule(address(module));
        adapterFork.setRequester(address(module), true);

        // Fund all participants with real USDC via deal.
        _dealAndApprovePot(creator, pot, 1_000_000e6);
        _dealAndApprovePot(alice, pot, 1_000_000e6);
        _dealAndApprovePot(bob, pot, 1_000_000e6);
        _dealAndApprovePot(reporter, pot, 1_000_000e6);
        _dealAndApprovePot(challenger, pot, 1_000_000e6);
        _dealAndApproveModule(appellant, module, 1_000_000e6);

        // Create and advance to APPEALABLE state (same flow as unit test helper).
        (uint256 id,,) = _setupAppealableMarketFork(pot);

        // Verify APPEALABLE before starting appeal.
        uint8 status;
        (,,,,,,,, status,,) = pot.getMkt(id);
        assertEq(status, 7, "market should be APPEALABLE");

        // startUmaAppeal: calls requestPrice + setBond + proposePrice/proposePriceFor +
        // disputePrice/disputePriceFor on the real UMA OO. Validates live ABI.
        uint256 appellantBefore = usdc.balanceOf(appellant);
        vm.prank(appellant);
        module.startUmaAppeal(id);

        (,,,,,,,, status,,) = pot.getMkt(id);
        assertEq(status, 8, "market should be UMA_PENDING after startUmaAppeal");

        // Warp past 30-day stale timeout. DVM cannot resolve on fork, so settle will fail.
        (, uint64 umaStartedAt,,) = pot.getAppealInfo(id);
        vm.warp(uint256(umaStartedAt) + 30 days + 1);

        // expireUmaAppeal: tries settle (fails, DVM unresolved), falls back to committee winner.
        module.expireUmaAppeal(id);

        uint8 winner;
        (,,,,,,, winner, status,,) = pot.getMkt(id);
        assertEq(winner, 2, "committee winner (2) should prevail when oracle times out");
        assertEq(status, 2, "market should be ST_RESOLVED after expire");
        assertEq(usdc.balanceOf(appellant), appellantBefore, "appellant appeal bond refunded on expire");

        // Warp past dispute period and finalize.
        vm.warp(block.timestamp + 25 hours);
        pot.finalize(id);
        (,,,,,,,, status,,) = pot.getMkt(id);
        assertEq(status, 3, "market should be ST_CLAIMABLE after finalize");

        // Confirm claimants can withdraw.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.claim(id, 0, 0);
        assertGt(usdc.balanceOf(alice) - aliceBefore, 0, "alice (winner=2) should receive payout");
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _requireForkInputs(string memory reason) internal view {
        if (requireFork) revert ForkRequirementFailed(reason);
    }

    /// @dev Pranks the owner of the IdentifierWhitelist to add support for identifier.
    function _whitelistIdentifier(address whitelist, bytes32 id) internal {
        (bool ok, bytes memory ownerData) = whitelist.call(abi.encodeWithSignature("owner()"));
        if (!ok || ownerData.length < 32) return; // graceful skip if not Ownable
        address owner = abi.decode(ownerData, (address));
        vm.prank(owner);
        (bool addOk,) = whitelist.call(abi.encodeWithSignature("addSupportedIdentifier(bytes32)", id));
        if (!addOk) {
            // Some whitelist contracts use a different method name; best-effort only.
            vm.prank(owner);
            whitelist.call(abi.encodeWithSignature("addToWhitelist(bytes32)", id));
        }
    }

    /// @dev Reads the oracle's default liveness, falling back to 7200 (2 hours) on failure.
    function _readDefaultLiveness(address oracle) internal view returns (uint256) {
        (bool ok, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("defaultLiveness()"));
        if (ok && data.length >= 32) {
            uint256 l = abi.decode(data, (uint256));
            if (l > 0) return l;
        }
        return DEFAULT_LIVENESS;
    }

    function _dealAndApprovePot(address who, yPot pot, uint256 amount) internal {
        deal(address(usdc), who, amount, true);
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }

    function _dealAndApproveModule(address who, yPotUma module, uint256 amount) internal {
        deal(address(usdc), who, amount, true);
        vm.prank(who);
        usdc.approve(address(module), type(uint256).max);
    }

    /// @dev Replicates _setupAppealableMarket from unit tests but uses deal for funding.
    function _setupAppealableMarketFork(yPot pot) internal returns (uint256 id, uint64 resTime, uint64 appealDeadline) {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        id = pot.create("UMA fork appeal market", "bafyFork", dl, rt, 2, "", address(0));

        vm.prank(alice);
        pot.bet(id, 1, 100e6, 0, block.timestamp + 1);
        vm.prank(bob);
        pot.bet(id, 2, 100e6, 0, block.timestamp + 1);

        vm.warp(uint256(dl) + 1);
        pot.close(id);
        vm.warp(uint256(rt));

        vm.prank(reporter);
        pot.report(id, 1);
        vm.prank(challenger);
        pot.challenge(id, 2);

        vm.prank(oracle0);
        pot.resolveDispute(id, 2);
        vm.prank(oracle1);
        pot.resolveDispute(id, 2);

        resTime = rt;
        (appealDeadline,,,) = pot.getAppealInfo(id);
    }
}
