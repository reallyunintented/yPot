// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IyPotGovTarget, yPotGov} from "src/yPotGov.sol";

contract MockGovTarget is IyPotGovTarget {
    address public owner;
    address public pendingOwner;

    address public treasury;
    uint256 public minBet;
    uint256 public maxBet;
    uint256 public fee;
    uint256 public confirms;
    uint256 public confirmBps;
    uint256 public slippage;
    uint256 public lastCanceledId;
    address public lastRescueTo;
    bool public paused;

    mapping(address => bool) public oracleActive;

    error OnlyOwner();
    error NotPendingOwner();

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    function setTreasury(address t) external onlyOwner {
        treasury = t;
    }

    function setLimits(uint256 mn, uint256 mx) external onlyOwner {
        minBet = mn;
        maxBet = mx;
    }

    function setFee(uint256 f) external onlyOwner {
        fee = f;
    }

    function setConfirms(uint256 c) external onlyOwner {
        confirms = c;
    }

    function setOracle(address o, bool a) external onlyOwner {
        oracleActive[o] = a;
    }

    function setConfirmBps(uint256 bps) external onlyOwner {
        confirmBps = bps;
    }

    function setSlippage(uint256 bps) external onlyOwner {
        slippage = bps;
    }

    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    function cancel(uint256 id) external onlyOwner {
        lastCanceledId = id;
    }

    function rescueEth(address payable to) external onlyOwner {
        lastRescueTo = to;
    }

    function withdrawReserveToTreasury(uint256) external onlyOwner {}

    function revokeUmaModule() external onlyOwner {}

    function revokeOracleVote(uint256, address) external onlyOwner {}

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}

contract YPotGovTest is Test {
    MockGovTarget internal target;
    yPotGov internal gov;

    address internal newTreasury = address(0xBEEF);
    address internal oracle = address(0xABCD);

    function setUp() public {
        target = new MockGovTarget();
        gov = new yPotGov(address(target));

        target.transferOwnership(address(gov));
        gov.acceptPotOwnership();
    }

    function test_constructor_reverts_on_zero_target() public {
        vm.expectRevert(yPotGov.E1.selector);
        new yPotGov(address(0));
    }

    function test_treasury_timelock_executes_after_2_days() public {
        gov.propT(newTreasury);

        (, uint256 executeAt, bool staged) = gov.pT();
        assertTrue(staged);

        vm.warp(executeAt - 1);
        vm.expectRevert(yPotGov.E5.selector);
        gov.execT();

        vm.warp(executeAt);
        gov.execT();
        assertEq(target.treasury(), newTreasury);

        (,, bool stagedAfter) = gov.pT();
        assertFalse(stagedAfter);
    }

    function test_cancel_treasury_proposal_allows_reproposal() public {
        gov.propT(newTreasury);
        gov.cancelT();

        (,, bool stagedAfterCancel) = gov.pT();
        assertFalse(stagedAfterCancel);

        gov.propT(address(0xCAFE));
        (,, bool stagedAfterNew) = gov.pT();
        assertTrue(stagedAfterNew);
    }

    function test_limits_fee_confirms_oracle_confirmBps_slippage_timelocks() public {
        gov.propLim(1e6, 10e6);
        (,, uint256 limTs, bool limStaged) = gov.pLim();
        assertTrue(limStaged);
        vm.warp(limTs);
        gov.execLim();
        assertEq(target.minBet(), 1e6);
        assertEq(target.maxBet(), 10e6);

        gov.propFee(42e6);
        (, uint256 feeTs, bool feeStaged) = gov.pFee();
        assertTrue(feeStaged);
        vm.warp(feeTs);
        gov.execFee();
        assertEq(target.fee(), 42e6);

        gov.propConf(3);
        (, uint256 confTs, bool confStaged) = gov.pConf();
        assertTrue(confStaged);
        vm.warp(confTs);
        gov.execConf();
        assertEq(target.confirms(), 3);

        gov.propOracle(oracle, true);
        (,, uint256 orcTs, bool orcStaged) = gov.pOrc();
        assertTrue(orcStaged);
        vm.warp(orcTs);
        gov.execOracle();
        assertTrue(target.oracleActive(oracle));

        gov.propConfirmBps(3_333);
        (, uint256 bpsTs, bool bpsStaged) = gov.pConfirmBps();
        assertTrue(bpsStaged);
        vm.warp(bpsTs);
        gov.execConfirmBps();
        assertEq(target.confirmBps(), 3_333);

        gov.propSlip(9_900);
        (, uint256 slipTs, bool slipStaged) = gov.pSlip();
        assertTrue(slipStaged);
        vm.warp(slipTs);
        gov.execSlip();
        assertEq(target.slippage(), 9_900);
    }

    function test_propConf_reverts_when_below_minimum() public {
        vm.expectRevert(yPotGov.E1.selector);
        gov.propConf(1);
    }

    function test_immediate_forwarded_actions() public {
        gov.pausePot();
        assertTrue(target.paused());

        gov.unpausePot();
        assertFalse(target.paused());

        gov.cancelMarket(77);
        assertEq(target.lastCanceledId(), 77);

        gov.rescuePotEth(payable(address(0xD00D)));
        assertEq(target.lastRescueTo(), address(0xD00D));
    }

    function test_propPotOwner_zero_address_reverts() public {
        vm.expectRevert(yPotGov.E1.selector);
        gov.propPotOwner(address(0));
    }

    function test_propPotOwner_double_propose_reverts() public {
        gov.propPotOwner(address(0xF00D));
        vm.expectRevert(yPotGov.E5.selector);
        gov.propPotOwner(address(0xBEEF));
    }

    function test_execPotOwner_before_eta_reverts() public {
        gov.propPotOwner(address(0xF00D));
        vm.warp(gov.potOwnerEta() - 1);
        vm.expectRevert(yPotGov.E5.selector);
        gov.execPotOwner();
    }

    function test_cancelPotOwner_clears_pending_proposal() public {
        gov.propPotOwner(address(0xF00D));
        assertEq(gov.pendingPotOwner(), address(0xF00D));
        gov.cancelPotOwner();
        assertEq(gov.pendingPotOwner(), address(0));
        assertEq(gov.potOwnerEta(), 0);
    }

    function test_execPotOwner_after_timelock_sets_pending_owner_on_target() public {
        address newOwner = address(0xF00D);
        gov.propPotOwner(newOwner);
        vm.warp(gov.potOwnerEta());
        gov.execPotOwner();
        // Initiates Ownable2Step: yPot.pendingOwner == newOwner
        assertEq(target.pendingOwner(), newOwner);
        // Proposal cleared
        assertEq(gov.pendingPotOwner(), address(0));
        assertEq(gov.potOwnerEta(), 0);
    }

    function test_nominated_owner_accepts_directly_on_target() public {
        address newOwner = address(0xF00D);
        gov.propPotOwner(newOwner);
        vm.warp(gov.potOwnerEta());
        gov.execPotOwner();
        assertEq(target.pendingOwner(), newOwner);
        // newOwner accepts directly on the target (NOT via yPotGov.acceptPotOwnership)
        vm.prank(newOwner);
        target.acceptOwnership();
        assertEq(target.owner(), newOwner);
    }
}
