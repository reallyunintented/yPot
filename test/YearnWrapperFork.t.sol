// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {YearnWrapper} from "src/YearnWrapper.sol";

contract YearnWrapperForkTest is Test {
    error ForkRequirementFailed(string reason);

    bool internal forkReady;

    IERC20 internal usdc;
    IERC4626 internal yearnVault;
    YearnWrapper internal wrapper;

    address internal constant DEFAULT_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal depositor = address(0xD3D0);
    address internal outsider = address(0x0A75);
    uint256 internal fundedAmount;

    modifier onlyFork() {
        if (!forkReady) return;
        _;
    }

    function setUp() public {
        bool requireFork = vm.envOr("FORK_REQUIRED", false);
        string memory rpcUrl = vm.envOr("FORK_RPC_URL", string(""));
        address vaultAddr = vm.envOr("FORK_YEARN_VAULT", address(0));
        if (bytes(rpcUrl).length == 0 || vaultAddr == address(0)) {
            _requireForkInputs(requireFork, "Missing required fork env: FORK_RPC_URL, FORK_YEARN_VAULT");
            forkReady = false;
            return;
        }

        uint256 blockNumber = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        uint256 forkId = blockNumber == 0 ? vm.createFork(rpcUrl) : vm.createFork(rpcUrl, blockNumber);
        vm.selectFork(forkId);

        usdc = IERC20(vm.envOr("FORK_USDC", DEFAULT_USDC));
        yearnVault = IERC4626(vaultAddr);
        if (yearnVault.asset() != address(usdc)) {
            _requireForkInputs(requireFork, "FORK_YEARN_VAULT asset() does not match FORK_USDC");
            forkReady = false;
            return;
        }

        address[] memory initialDepositors = new address[](1);
        initialDepositors[0] = address(this);
        wrapper = new YearnWrapper(usdc, yearnVault, initialDepositors);
        wrapper.setDepositor(depositor, true);

        uint256 requestedFunding = vm.envOr("FORK_FUND_USDC", uint256(50_000e6));
        bool useDealFunding = vm.envOr("FORK_USE_DEAL", true);
        if (useDealFunding) {
            deal(address(usdc), depositor, requestedFunding, true);
            fundedAmount = requestedFunding;
        } else {
            address whale = vm.envOr("FORK_USDC_WHALE", address(0));
            if (whale == address(0)) {
                _requireForkInputs(requireFork, "FORK_USDC_WHALE is required when FORK_USE_DEAL=false");
                forkReady = false;
                return;
            }
            uint256 whaleBalance = usdc.balanceOf(whale);
            if (whaleBalance == 0) {
                _requireForkInputs(requireFork, "FORK_USDC_WHALE has zero USDC at selected block");
                forkReady = false;
                return;
            }

            fundedAmount = requestedFunding <= whaleBalance ? requestedFunding : whaleBalance;
            vm.prank(whale);
            bool transferred = usdc.transfer(depositor, fundedAmount);
            if (!transferred) {
                _requireForkInputs(requireFork, "Failed to fund depositor from FORK_USDC_WHALE");
                forkReady = false;
                return;
            }
        }

        if (usdc.balanceOf(depositor) == 0) {
            _requireForkInputs(requireFork, "Failed to fund depositor with USDC");
            forkReady = false;
            return;
        }

        vm.prank(depositor);
        usdc.approve(address(wrapper), type(uint256).max);

        forkReady = true;
    }

    function _requireForkInputs(bool requireFork, string memory reason) internal pure {
        if (requireFork) revert ForkRequirementFailed(reason);
    }

    function testFork_depositAndRedeem_roundTripIsNearQuotedAssets() public onlyFork {
        uint256 depositAssets = _boundedDepositAssets();
        uint256 quotedShares = wrapper.previewDeposit(depositAssets);
        assertGt(quotedShares, 0, "previewDeposit returned zero shares");

        vm.prank(depositor);
        uint256 mintedShares = wrapper.deposit(depositAssets, depositor);
        assertEq(mintedShares, quotedShares, "deposit minted unexpected shares");

        vm.prank(depositor);
        uint256 assetsOut = wrapper.redeem(mintedShares, depositor, depositor);

        assertApproxEqAbs(assetsOut, depositAssets, 5_000, "round-trip drift exceeded 0.005 USDC");
    }

    function testFork_maxRedeemTracksWithdrawLimit() public onlyFork {
        uint256 depositAssets = _boundedDepositAssets();
        vm.prank(depositor);
        wrapper.deposit(depositAssets, depositor);

        uint256 maxRedeemable = wrapper.maxRedeem(depositor);
        uint256 maxWithdrawable = wrapper.maxWithdraw(depositor);
        uint256 redeemableAssets = wrapper.previewRedeem(maxRedeemable);

        assertLe(maxRedeemable, wrapper.balanceOf(depositor), "maxRedeem exceeds holder balance");
        assertLe(redeemableAssets, maxWithdrawable + 1, "maxRedeem exceeds withdrawable assets");
    }

    function testFork_pauseBlocksDepositPath() public onlyFork {
        wrapper.pause();
        assertEq(wrapper.maxDeposit(depositor), 0, "maxDeposit should be zero while paused");
        assertEq(wrapper.maxMint(depositor), 0, "maxMint should be zero while paused");

        vm.prank(depositor);
        vm.expectRevert();
        wrapper.deposit(1e6, depositor);
    }

    function testFork_nonDepositorDepositRevertsUnauthorized() public onlyFork {
        uint256 transferAmount = fundedAmount >= 2e6 ? 2e6 : 1e6;
        vm.prank(depositor);
        bool transferred = usdc.transfer(outsider, transferAmount);
        require(transferred, "TRANSFER_FAILED");

        vm.prank(outsider);
        usdc.approve(address(wrapper), type(uint256).max);

        vm.prank(outsider);
        vm.expectRevert(YearnWrapper.Unauthorized.selector);
        wrapper.deposit(1e6, outsider);
    }

    function _boundedDepositAssets() internal view returns (uint256) {
        uint256 bal = usdc.balanceOf(depositor);
        if (bal <= 1e6) return bal;
        uint256 cap = fundedAmount / 4;
        if (cap < 1e6) cap = 1e6;
        if (cap > bal) cap = bal;
        return cap;
    }
}
