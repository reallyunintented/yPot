// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

contract yPotRoundingStressTest is Test {
    uint256 private constant CHALLENGE_WINDOW = 48 hours;
    uint256 private constant DISPUTE_PERIOD = 24 hours;

    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    address internal treasury = address(0xBEEF);
    address internal oracle0 = address(0x1111);
    address internal oracle1 = address(0x2222);

    address internal creator = address(0xCAFE);
    address internal reporter = address(0xD00D);
    address internal loser = address(0xB0B);

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockUSDC();
        yearn = new MockERC4626Vault(usdc);

        address[] memory initialDepositors = new address[](1);
        initialDepositors[0] = address(this);
        wrapper = new YearnWrapper(usdc, IERC4626(address(yearn)), initialDepositors);

        address[] memory oracles = new address[](2);
        oracles[0] = oracle0;
        oracles[1] = oracle1;
        pot = new yPot(address(usdc), address(wrapper), treasury, oracles);
        wrapper.setDepositor(address(pot), true);

        // Keep claimability flow deterministic for this rounding stress.
        pot.setConfirmBps(0);

        _mintApprove(creator, 1_000_000e6);
        _mintApprove(reporter, 1_000_000e6);
        _mintApprove(loser, 1_000_000e6);
    }

    function test_claim_manyWinners_roundingDustBounded_and_claimConservation() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = uint64(uint256(dl) + 2 hours);

        vm.prank(creator);
        uint256 id = pot.create("rounding stress", "bafyRounding", dl, rt, 2, "", address(0));

        uint256 winnerCount = 12;
        address[] memory winners = new address[](winnerCount);

        for (uint256 i; i < winnerCount;) {
            address who = vm.addr(1000 + i);
            winners[i] = who;
            _mintApprove(who, 1_000_000e6);

            uint256 amount = (2 + i) * 1e6;
            vm.prank(who);
            pot.bet(id, 1, amount, 0, block.timestamp + 1);

            // Stagger bets to vary weighted shares and increase rounding pressure.
            vm.warp(block.timestamp + 10 minutes);

            unchecked {
                ++i;
            }
        }

        vm.prank(loser);
        pot.bet(id, 2, 25e6, 0, block.timestamp + 1);

        vm.warp(uint256(dl) + 1);
        pot.close(id);

        vm.warp(uint256(rt));
        vm.prank(reporter);
        pot.report(id, 1);

        vm.warp(uint256(rt) + CHALLENGE_WINDOW + 1);
        pot.acceptReport(id);

        vm.warp(block.timestamp + DISPUTE_PERIOD + 1);
        pot.finalize(id);

        (, uint256[] memory totalWsh, uint256 poolShares,,) = pot.getShares(id);
        uint256 totalWinnerWeighted = totalWsh[1];
        assertGt(totalWinnerWeighted, 0);
        assertGt(poolShares, 0);

        uint256 summedEntitlement;
        for (uint256 i; i < winnerCount;) {
            address who = winners[i];
            (, uint256[] memory userWsh,,) = pot.getUsr(id, who);

            uint256 entitled = Math.mulDiv(userWsh[1], poolShares, totalWinnerWeighted);
            summedEntitlement += entitled;

            vm.prank(who);
            pot.claim(id, 0, 0);

            (,, uint256 claimed,) = pot.getUsr(id, who);
            assertEq(claimed, entitled);

            unchecked {
                ++i;
            }
        }

        assertLe(summedEntitlement, poolShares, "winner entitlements exceed pool shares");
        uint256 dustBound = winnerCount;
        uint256 roundingDust = poolShares - summedEntitlement;
        assertLe(roundingDust, dustBound, "rounding dust exceeded per-user bound");

        (,, uint256 totalShares, uint256 claimedShares,) = pot.getShares(id);
        assertEq(totalShares, poolShares);
        assertEq(claimedShares, summedEntitlement);
        assertEq(totalShares - claimedShares, roundingDust);
    }

    function _mintApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }
}
