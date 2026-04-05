// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";
import {yPotViews} from "src/yPotViews.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

contract YPotViewsTest is Test {
    MockUSDC internal usdc;
    MockERC4626Vault internal yearnVault;
    YearnWrapper internal wrapper;
    yPot internal pot;
    yPotViews internal viewsLens;

    address internal treasury = address(0xCAFE);
    address internal creator = address(0xA11CE);
    address internal bettor = address(0xB0B);
    address internal reporter = address(0xC0C0A);

    function setUp() public {
        usdc = new MockUSDC();
        yearnVault = new MockERC4626Vault(usdc);

        address[] memory initialDepositors = new address[](1);
        initialDepositors[0] = address(this);
        wrapper = new YearnWrapper(usdc, yearnVault, initialDepositors);

        address[] memory oracles = new address[](2);
        oracles[0] = address(0x1111);
        oracles[1] = address(0x2222);
        pot = new yPot(address(usdc), address(wrapper), treasury, oracles);
        viewsLens = new yPotViews(address(pot));

        wrapper.setDepositor(address(pot), true);

        usdc.mint(creator, 1_000_000e6);
        usdc.mint(bettor, 1_000_000e6);
        usdc.mint(reporter, 1_000_000e6);

        vm.prank(creator);
        usdc.approve(address(pot), type(uint256).max);
        vm.prank(bettor);
        usdc.approve(address(pot), type(uint256).max);
        vm.prank(reporter);
        usdc.approve(address(pot), type(uint256).max);

        vm.warp(1_700_000_000);
    }

    function test_getConfirmWithSnapshot_uses_report_snapshot_not_current_setting() public {
        pot.setConfirmBps(3_000);
        uint256 id = _createAndReportMarket();

        pot.setConfirmBps(5_000);
        (uint256 userSh, uint256 totalSh, uint256 required, uint16 snapshot) =
            viewsLens.getConfirmWithSnapshot(id, bettor);
        (uint256 userShPot, uint256 totalShPot, uint256 requiredPot) = pot.getConfirm(id, bettor);

        assertEq(snapshot, 3_000);
        assertEq(userSh, userShPot);
        assertEq(totalSh, totalShPot);
        assertEq(required, requiredPot);
    }

    function test_previewClaim_quotes_fee_when_pool_has_yield() public {
        uint256 id = _createToClaimable();
        yearnVault.setExchangeRate(2e18);

        (uint256 entitled, uint256 estAssets, uint256 estFee, uint256 estPayout) = viewsLens.previewClaim(id, bettor);
        assertGt(entitled, 0);
        assertGt(estAssets, 0);
        assertGt(estFee, 0);
        assertEq(estAssets - estFee, estPayout);

        (,,,,,,,,,, uint256 prin) = pot.getMkt(id);
        (,, uint256 tot,,) = pot.getShares(id);
        uint256 expectedAssets = wrapper.convertToAssets(entitled);
        uint256 cp = Math.mulDiv(prin, entitled, tot);
        uint256 expectedFee = Math.mulDiv(expectedAssets - cp, 500, 10_000);

        assertEq(estAssets, expectedAssets);
        assertEq(estFee, expectedFee);
    }

    function test_calcUmaAppealBond_enforces_minimum_on_low_principal() public {
        uint256 id = _createOnly();
        uint256 bond = viewsLens.calcUmaAppealBond(id);
        assertEq(bond, 50e6);
    }

    function test_totalSharesDerived_passthrough_matches_core() public {
        uint256 id = _createAndBetOnly();
        assertGt(viewsLens.totalSharesDerived(id), 0);
    }

    function test_getPoolHealth_flags_healthy_when_reserve_covers_one_unit_shortfall() public {
        // Creation fee auto-funds reserve. Even 1 unit shortfall is covered by reserve.
        yearnVault.setExchangeRate(12e17); // 1.2x
        uint256 id = _createOnly();

        uint64 txDeadline = uint64(block.timestamp + 3600);
        vm.prank(bettor);
        pot.bet(id, 1, 50e6, 0, txDeadline);

        (uint256 assets, uint256 principal, bool healthy) = viewsLens.getPoolHealth(id);
        assertEq(principal, 50e6);
        assertEq(principal - assets, 1);
        // Reserve is now auto-funded from creation fee, covering tiny shortfalls
        assertTrue(healthy);
    }

    function test_getPoolHealth_flags_healthy_when_reserve_covers_two_unit_shortfall() public {
        yearnVault.setExchangeRate(12e17); // 1.2x
        uint256 id = _createOnly();

        uint64 txDeadline = uint64(block.timestamp + 3600);
        vm.startPrank(bettor);
        pot.bet(id, 1, 50e6, 0, txDeadline);
        pot.bet(id, 1, 1e6, 0, txDeadline);
        vm.stopPrank();

        (uint256 assets, uint256 principal, bool healthy) = viewsLens.getPoolHealth(id);
        assertEq(principal, 51e6);
        assertEq(principal - assets, 2);
        // Reserve is now auto-funded from creation fee, covering tiny shortfalls
        assertTrue(healthy);
    }

    function test_getPoolHealth_healthy_when_principal_is_fully_covered() public {
        uint256 id = _createOnly();

        uint64 txDeadline = uint64(block.timestamp + 3600);
        vm.prank(bettor);
        pot.bet(id, 1, 50e6, 0, txDeadline);

        (uint256 assets, uint256 principal, bool healthy) = viewsLens.getPoolHealth(id);
        assertEq(assets, principal);
        assertTrue(healthy);
    }

    function test_getPoolHealth_flags_unhealthy_when_share_coverage_is_insufficient() public {
        uint256 id = _createOnly();

        uint64 txDeadline = uint64(block.timestamp + 3600);
        vm.prank(bettor);
        pot.bet(id, 1, 50e6, 0, txDeadline);

        // Simulate real loss: each share now redeems to fewer assets than principal requires.
        yearnVault.setExchangeRate(9e17); // 0.9x

        (uint256 assets, uint256 principal, bool healthy) = viewsLens.getPoolHealth(id);
        assertLt(assets, principal);
        assertFalse(healthy);
    }

    function test_getProtocolHealth_aggregates_market_assets_and_principal() public {
        uint256 first = _createOnly();
        uint256 second = _createOnly();

        uint64 txDeadline = uint64(block.timestamp + 3600);
        vm.startPrank(bettor);
        pot.bet(first, 1, 50e6, 0, txDeadline);
        pot.bet(second, 1, 80e6, 0, txDeadline);
        vm.stopPrank();

        (uint256 assets, uint256 principal, uint256 unrealizedYield, uint256 unhealthyMarkets, uint256 marketCount) =
            viewsLens.getProtocolHealth();

        assertEq(marketCount, 2);
        assertEq(assets, 130e6);
        assertEq(principal, 130e6);
        assertEq(unrealizedYield, 0);
        assertEq(unhealthyMarkets, 0);
    }

    function test_getProtocolHealth_reports_live_yield() public {
        uint256 healthyId = _createOnly();
        uint256 otherId = _createOnly();

        uint64 txDeadline = uint64(block.timestamp + 3600);
        vm.startPrank(bettor);
        pot.bet(healthyId, 1, 100e6, 0, txDeadline);
        pot.bet(otherId, 1, 50e6, 0, txDeadline);
        vm.stopPrank();

        yearnVault.setExchangeRate(12e17);

        (uint256 assets, uint256 principal, uint256 unrealizedYield, uint256 unhealthyMarkets, uint256 marketCount) =
            viewsLens.getProtocolHealth();

        assertEq(marketCount, 2);
        assertGt(assets, principal);
        assertEq(unrealizedYield, assets - principal);
        assertEq(unhealthyMarkets, 0);
    }

    function _createOnly() internal returns (uint256 id) {
        uint64 nowTs = uint64(block.timestamp);
        uint64 deadline = nowTs + 14 days + 1;
        uint64 resTime = deadline + 1 hours;

        vm.prank(creator);
        id = pot.create("Views Market", "bafyViewsOnly", deadline, resTime, 2, "", address(0));
    }

    function _createAndBetOnly() internal returns (uint256 id) {
        id = _createOnly();
        uint64 txDeadline = uint64(block.timestamp + 3600);
        vm.prank(bettor);
        pot.bet(id, 1, 100e6, 0, txDeadline);
    }

    function _createAndReportMarket() internal returns (uint256 id) {
        uint64 nowTs = uint64(block.timestamp);
        uint64 deadline = nowTs + 14 days + 1;
        uint64 resTime = deadline + 1 hours;

        vm.prank(creator);
        id = pot.create("Views Report Market", "bafyViewsReport", deadline, resTime, 2, "", address(0));

        vm.warp(nowTs + 30 minutes);
        vm.prank(bettor);
        pot.bet(id, 1, 100e6, 0, nowTs + 1 hours);

        vm.warp(deadline + 1);
        pot.close(id);

        vm.warp(resTime);
        vm.prank(reporter);
        pot.report(id, 1);

        vm.prank(bettor);
        pot.confirmReport(id, 25e6, 0, resTime + 60);
    }

    function _createToClaimable() internal returns (uint256 id) {
        id = _createAndReportMarket();

        vm.warp(block.timestamp + 48 hours + 1);
        pot.acceptReport(id);

        vm.warp(block.timestamp + 24 hours + 1);
        pot.finalize(id);
    }
}
