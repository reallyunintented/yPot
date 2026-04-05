// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {yPot} from "src/yPot.sol";
import {YearnWrapper} from "src/YearnWrapper.sol";

import {MockUSDC} from "test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";

contract yPotFeaturesTest is Test {
    uint256 private constant BPS = 10_000;
    uint256 private constant REFERRAL_BPS = 1000;

    event MarketTagged(uint256 indexed id, string tag);
    event ReferralCredited(uint256 indexed id, address indexed referrer, uint256 amount);

    MockUSDC internal usdc;
    MockERC4626Vault internal yearn;
    YearnWrapper internal wrapper;
    yPot internal pot;

    address internal treasury = address(0xBEEF);
    address internal creator = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal referrer = address(0xDEAD);

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockUSDC();
        yearn = new MockERC4626Vault(usdc);

        address[] memory initialDepositors = new address[](1);
        initialDepositors[0] = address(this);
        wrapper = new YearnWrapper(usdc, IERC4626(address(yearn)), initialDepositors);

        address[] memory oracles = new address[](2);
        oracles[0] = address(0x1111);
        oracles[1] = address(0x2222);
        pot = new yPot(address(usdc), address(wrapper), treasury, oracles);
        wrapper.setDepositor(address(pot), true);

        _mintApprove(creator, 1_000_000e6);
        _mintApprove(alice, 1_000_000e6);
        _mintApprove(bob, 1_000_000e6);
        _mintApprove(referrer, 1_000_000e6);
    }

    // =========================================================================
    // Market Tags
    // =========================================================================

    function test_create_emitsMarketTagged_whenTagProvided() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        vm.prank(creator);
        vm.expectEmit(true, false, false, true);
        emit MarketTagged(1, "sports");
        pot.create("tagged market", "bafyTag", dl, rt, 2, "sports", address(0));
    }

    function test_create_doesNotEmitMarketTagged_whenTagEmpty() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        vm.recordLogs();
        vm.prank(creator);
        pot.create("untagged market", "bafyNoTag", dl, rt, 2, "", address(0));

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 taggedSig = keccak256("MarketTagged(uint256,string)");
        for (uint256 i; i < entries.length; i++) {
            assertFalse(entries[i].topics[0] == taggedSig, "MarketTagged should not emit for empty tag");
        }
    }

    function test_create_tagDoesNotAffectMarketData() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        vm.prank(creator);
        uint256 id = pot.create("tag data test", "bafyTagData", dl, rt, 3, "crypto", address(0));

        (string memory desc,,,,,, uint8 outcomes,,, address mCreator,) = pot.getMkt(id);
        assertEq(keccak256(bytes(desc)), keccak256(bytes("tag data test")));
        assertEq(outcomes, 3);
        assertEq(mCreator, creator);
    }

    // =========================================================================
    // Referral Tracking
    // =========================================================================

    function test_create_creditsReferral_whenReferrerProvided() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        // Fee = 10e6. bounty = 2e6, reserve = 1e6, treasury = 7e6
        // referralAmount = 7e6 * 1000 / 10000 = 700_000

        vm.prank(creator);
        vm.expectEmit(true, true, false, true);
        emit ReferralCredited(1, referrer, Math.mulDiv(7e6, REFERRAL_BPS, BPS));
        pot.create("referral market", "bafyRef", dl, rt, 2, "", referrer);

        uint256 pending = pot.pendingWithdrawals(referrer);
        assertEq(pending, 700_000); // 10% of 7e6 treasury portion
    }

    function test_create_selfReferral_noCredit() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        vm.prank(creator);
        pot.create("self referral", "bafySelf", dl, rt, 2, "", creator);

        uint256 pending = pot.pendingWithdrawals(creator);
        assertEq(pending, 0);
    }

    function test_create_zeroAddressReferrer_noCredit() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        vm.prank(creator);
        pot.create("no referrer", "bafyNone", dl, rt, 2, "", address(0));

        // Treasury should get full portion (no referral split)
        // Check nothing credited to address(0)
        uint256 pending = pot.pendingWithdrawals(address(0));
        assertEq(pending, 0);
    }

    function test_create_referrerCanWithdraw() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        vm.prank(creator);
        pot.create("withdraw ref", "bafyWithdraw", dl, rt, 2, "", referrer);

        uint256 pending = pot.pendingWithdrawals(referrer);
        assertGt(pending, 0);

        uint256 balBefore = usdc.balanceOf(referrer);
        vm.prank(referrer);
        pot.withdrawPending();
        uint256 balAfter = usdc.balanceOf(referrer);

        assertEq(balAfter - balBefore, pending);
        assertEq(pot.pendingWithdrawals(referrer), 0);
    }

    function test_create_referralReducesTreasuryPortion() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        // Create without referrer first to fill reserve
        vm.prank(creator);
        pot.create("fill reserve", "bafyFill", dl, rt, 2, "", address(0));

        // Now create with referrer (reserve full, so treasury gets more)
        uint256 treasuryBefore = usdc.balanceOf(treasury) + pot.pendingWithdrawals(treasury);
        vm.prank(creator);
        pot.create("with ref", "bafyRef2", dl, rt, 2, "", referrer);
        uint256 treasuryAfter = usdc.balanceOf(treasury) + pot.pendingWithdrawals(treasury);

        // Reserve still not full (target 25e6, only 1e6 filled by first create)
        // So reserve gets another 1e6, bounty 2e6, treasury = 10e6 - 2e6 - 1e6 = 7e6
        // Referral = 7e6 * 1000 / 10000 = 700_000
        // Net treasury = 7e6 - 700_000 = 6_300_000
        uint256 treasuryReceived = treasuryAfter - treasuryBefore;
        assertEq(treasuryReceived, 6_300_000);
        assertEq(pot.pendingWithdrawals(referrer), 700_000);
    }

    // =========================================================================
    // Batch Bet
    // =========================================================================

    function test_batchBet_multiMarket() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        vm.startPrank(creator);
        uint256 id1 = pot.create("market A", "bafyA", dl, rt, 2, "", address(0));
        uint256 id2 = pot.create("market B", "bafyB", dl, rt, 3, "", address(0));
        vm.stopPrank();

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 1;
        outcomes[1] = 3;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 75e6;

        uint256[] memory minShares = new uint256[](2);
        minShares[0] = 0;
        minShares[1] = 0;

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pot.batchBet(ids, outcomes, amounts, minShares, block.timestamp + 1);
        uint256 balAfter = usdc.balanceOf(alice);

        assertEq(balBefore - balAfter, 125e6);

        // Verify bets landed
        (uint256[] memory sh1,,,,) = pot.getShares(id1);
        assertGt(sh1[1], 0);

        (uint256[] memory sh2,,,,) = pot.getShares(id2);
        assertGt(sh2[3], 0);
    }

    function test_batchBet_sameMarketDifferentOutcomes() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        vm.prank(creator);
        uint256 id = pot.create("multi outcome", "bafyMulti", dl, rt, 3, "", address(0));

        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 1;
        outcomes[1] = 2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 200e6;

        uint256[] memory minShares = new uint256[](2);

        vm.prank(alice);
        pot.batchBet(ids, outcomes, amounts, minShares, block.timestamp + 1);

        (uint256[] memory sh,,,,) = pot.getShares(id);
        assertGt(sh[1], 0);
        assertGt(sh[2], 0);
    }

    function test_batchBet_revertsOnLengthMismatch() public {
        uint256[] memory ids = new uint256[](2);
        uint8[] memory outcomes = new uint8[](1); // mismatch
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory minShares = new uint256[](2);

        vm.prank(alice);
        vm.expectRevert(yPot.E1.selector);
        pot.batchBet(ids, outcomes, amounts, minShares, block.timestamp + 1);
    }

    function test_batchBet_revertsOnEmptyBatch() public {
        uint256[] memory ids = new uint256[](0);
        uint8[] memory outcomes = new uint8[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256[] memory minShares = new uint256[](0);

        vm.prank(alice);
        vm.expectRevert(yPot.E1.selector);
        pot.batchBet(ids, outcomes, amounts, minShares, block.timestamp + 1);
    }

    function test_batchBet_revertsOnMaxExceeded() public {
        uint256[] memory ids = new uint256[](17); // MAX_BATCH_BETS = 16
        uint8[] memory outcomes = new uint8[](17);
        uint256[] memory amounts = new uint256[](17);
        uint256[] memory minShares = new uint256[](17);

        vm.prank(alice);
        vm.expectRevert(yPot.E1.selector);
        pot.batchBet(ids, outcomes, amounts, minShares, block.timestamp + 1);
    }

    function test_batchBet_revertsOnExpiredDeadline() public {
        uint256[] memory ids = new uint256[](1);
        uint8[] memory outcomes = new uint8[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory minShares = new uint256[](1);

        vm.prank(alice);
        vm.expectRevert(yPot.E4.selector);
        pot.batchBet(ids, outcomes, amounts, minShares, block.timestamp - 1);
    }

    function test_batchBet_atomicRevert_onInvalidBet() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        vm.prank(creator);
        uint256 id = pot.create("atomic test", "bafyAtomic", dl, rt, 2, "", address(0));

        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 1;
        outcomes[1] = 5; // invalid outcome for 2-outcome market

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;

        uint256[] memory minShares = new uint256[](2);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(yPot.E1.selector);
        pot.batchBet(ids, outcomes, amounts, minShares, block.timestamp + 1);

        // Balance unchanged — atomic revert
        assertEq(usdc.balanceOf(alice), balBefore);
    }

    function test_batchBet_at_maxBatchSize() public {
        uint64 dl = uint64(block.timestamp + 14 days + 1);
        uint64 rt = dl + 2 hours;

        vm.prank(creator);
        uint256 id = pot.create("max batch", "bafyMax", dl, rt, 2, "", address(0));

        uint256[] memory ids = new uint256[](16);
        uint8[] memory outcomes = new uint8[](16);
        uint256[] memory amounts = new uint256[](16);
        uint256[] memory minShares = new uint256[](16);

        for (uint256 i; i < 16; i++) {
            ids[i] = id;
            outcomes[i] = 1;
            amounts[i] = 1e6; // minBet
        }

        vm.prank(alice);
        pot.batchBet(ids, outcomes, amounts, minShares, block.timestamp + 1);

        (uint256[] memory sh,,,,) = pot.getShares(id);
        assertGt(sh[1], 0);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _mintApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pot), type(uint256).max);
    }
}
