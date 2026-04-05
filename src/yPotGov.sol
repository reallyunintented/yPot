// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IyPotGovTarget {
    function setTreasury(address t) external;
    function setLimits(uint256 mn, uint256 mx) external;
    function setFee(uint256 f) external;
    function setConfirms(uint256 c) external;
    function setOracle(address o, bool a) external;
    function setConfirmBps(uint256 bps) external;
    function setSlippage(uint256 bps) external;

    function pause() external;
    function unpause() external;
    function cancel(uint256 id) external;
    function rescueEth(address payable to) external;
    function withdrawReserveToTreasury(uint256 assets) external;

    function revokeUmaModule() external;
    function revokeOracleVote(uint256 id, address oracle) external;

    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

/**
 * @title yPotGov
 * @notice Timelock governance wrapper for yPot.
 * @dev All parameter changes go through a 2-day timelock.
 */
contract yPotGov is Ownable2Step {
    uint256 private constant TIMELOCK = 2 days;

    error E1(); // InvalidParams
    error E5(); // TimelockNotReady

    event PotOwnerProposed(address indexed newOwner, uint256 eta);
    event PotOwnerExecuted(address indexed newOwner);
    event PotOwnerCancelled();

    // action: 0=treasury, 1=limits, 2=fee, 3=confirms, 4=oracle, 5=confirmBps, 6=slippage, 7=reserveWithdraw
    // phase: 0=proposed, 1=executed, 2=cancelled
    event Proposal(uint8 indexed action, uint8 indexed phase, uint256 executeAt);

    struct PendingUint {
        uint256 v;
        uint256 t;
        bool s;
    }

    struct PendingLim {
        uint256 mn;
        uint256 mx;
        uint256 t;
        bool s;
    }

    struct PendingOracle {
        address o;
        bool a;
        uint256 t;
        bool s;
    }

    IyPotGovTarget public immutable pot;

    address public pendingPotOwner;
    uint256 public potOwnerEta;

    PendingUint public pT;
    PendingLim public pLim;
    PendingUint public pFee;
    PendingUint public pConf;
    PendingUint public pConfirmBps;
    PendingOracle public pOrc;
    PendingUint public pSlip;
    PendingUint public pResW;

    /// @notice Deploys yPotGov wrapping the given yPot instance.
    /// @param pot_ Address of the yPot contract to govern.
    constructor(address pot_) Ownable(msg.sender) {
        if (pot_ == address(0)) revert E1();
        pot = IyPotGovTarget(pot_);
    }

    // -------------------------------------------------------------------------
    // Ownership Transfer Helpers
    // -------------------------------------------------------------------------

    /// @notice Accepts pending ownership of the target yPot contract.
    function acceptPotOwnership() external onlyOwner {
        pot.acceptOwnership();
    }

    /// @notice Proposes a new owner for the target yPot contract (starts 2-day timelock).
    /// @param newOwner Address to transfer yPot ownership to. Use cancelPotOwner to rescind.
    function propPotOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert E1(); // use cancelPotOwner to rescind
        if (potOwnerEta != 0) revert E5(); // reject double-propose while one is pending
        pendingPotOwner = newOwner;
        potOwnerEta = block.timestamp + TIMELOCK;
        emit PotOwnerProposed(newOwner, potOwnerEta);
    }

    /// @notice Executes the pending pot-owner transfer after timelock expires.
    function execPotOwner() external onlyOwner {
        if (pendingPotOwner == address(0) || potOwnerEta == 0) revert E1();
        if (block.timestamp < potOwnerEta) revert E5();
        address target = pendingPotOwner;
        delete pendingPotOwner;
        delete potOwnerEta;
        pot.transferOwnership(target);
        emit PotOwnerExecuted(target);
    }

    /// @notice Cancels the pending pot-owner transfer proposal.
    function cancelPotOwner() external onlyOwner {
        delete pendingPotOwner;
        delete potOwnerEta;
        emit PotOwnerCancelled();
    }

    // -------------------------------------------------------------------------
    // Treasury (Timelocked)
    // -------------------------------------------------------------------------

    /// @notice Proposes a new treasury address (starts 2-day timelock).
    /// @param t New treasury address.
    function propT(address t) external onlyOwner {
        if (pT.s || t == address(0)) revert E1();
        pT = PendingUint(uint256(uint160(t)), block.timestamp + TIMELOCK, true);
        emit Proposal(0, 0, pT.t);
    }

    /// @notice Executes the pending treasury change after timelock expires.
    function execT() external onlyOwner {
        if (!pT.s || block.timestamp < pT.t) revert E5();
        pot.setTreasury(address(uint160(pT.v)));
        pT.s = false;
        emit Proposal(0, 1, 0);
    }

    /// @notice Cancels the pending treasury proposal.
    function cancelT() external onlyOwner {
        pT.s = false;
        emit Proposal(0, 2, 0);
    }

    // -------------------------------------------------------------------------
    // Bet Limits (Timelocked)
    // -------------------------------------------------------------------------

    /// @notice Proposes new bet limits (starts 2-day timelock).
    /// @param mn New minimum bet.
    /// @param mx New maximum bet.
    function propLim(uint256 mn, uint256 mx) external onlyOwner {
        if (pLim.s || mn == 0 || mx <= mn) revert E1();
        pLim = PendingLim(mn, mx, block.timestamp + TIMELOCK, true);
        emit Proposal(1, 0, pLim.t);
    }

    /// @notice Executes the pending bet limits change after timelock expires.
    function execLim() external onlyOwner {
        if (!pLim.s || block.timestamp < pLim.t) revert E5();
        pot.setLimits(pLim.mn, pLim.mx);
        pLim.s = false;
        emit Proposal(1, 1, 0);
    }

    /// @notice Cancels the pending bet limits proposal.
    function cancelLim() external onlyOwner {
        pLim.s = false;
        emit Proposal(1, 2, 0);
    }

    // -------------------------------------------------------------------------
    // Fee (Timelocked)
    // -------------------------------------------------------------------------

    /// @notice Proposes a new market creation fee (starts 2-day timelock).
    /// @param f New fee amount in asset units.
    function propFee(uint256 f) external onlyOwner {
        if (pFee.s) revert E1();
        pFee = PendingUint(f, block.timestamp + TIMELOCK, true);
        emit Proposal(2, 0, pFee.t);
    }

    /// @notice Executes the pending fee change after timelock expires.
    function execFee() external onlyOwner {
        if (!pFee.s || block.timestamp < pFee.t) revert E5();
        pot.setFee(pFee.v);
        pFee.s = false;
        emit Proposal(2, 1, 0);
    }

    /// @notice Cancels the pending fee proposal.
    function cancelFee() external onlyOwner {
        pFee.s = false;
        emit Proposal(2, 2, 0);
    }

    // -------------------------------------------------------------------------
    // Oracle Confirms (Timelocked)
    // -------------------------------------------------------------------------

    /// @notice Proposes a new oracle confirmation count (starts 2-day timelock).
    /// @param c Required confirmation count (must be >= 2).
    function propConf(uint256 c) external onlyOwner {
        if (pConf.s || c < 2) revert E1();
        pConf = PendingUint(c, block.timestamp + TIMELOCK, true);
        emit Proposal(3, 0, pConf.t);
    }

    /// @notice Executes the pending confirmation count change after timelock expires.
    function execConf() external onlyOwner {
        if (!pConf.s || block.timestamp < pConf.t) revert E5();
        pot.setConfirms(pConf.v);
        pConf.s = false;
        emit Proposal(3, 1, 0);
    }

    /// @notice Cancels the pending confirmation count proposal.
    function cancelConf() external onlyOwner {
        pConf.s = false;
        emit Proposal(3, 2, 0);
    }

    // -------------------------------------------------------------------------
    // Oracle Add/Remove (Timelocked)
    // -------------------------------------------------------------------------

    /// @notice Proposes adding or removing an oracle (starts 2-day timelock).
    /// @param o Oracle address.
    /// @param a True to add, false to remove.
    function propOracle(address o, bool a) external onlyOwner {
        if (pOrc.s || o == address(0)) revert E1();
        pOrc = PendingOracle(o, a, block.timestamp + TIMELOCK, true);
        emit Proposal(4, 0, pOrc.t);
    }

    /// @notice Executes the pending oracle change after timelock expires.
    function execOracle() external onlyOwner {
        if (!pOrc.s || block.timestamp < pOrc.t) revert E5();
        pot.setOracle(pOrc.o, pOrc.a);
        pOrc.s = false;
        emit Proposal(4, 1, 0);
    }

    /// @notice Cancels the pending oracle proposal.
    function cancelOracle() external onlyOwner {
        pOrc.s = false;
        emit Proposal(4, 2, 0);
    }

    // -------------------------------------------------------------------------
    // Confirm BPS (Timelocked)
    // -------------------------------------------------------------------------

    /// @notice Proposes a new report confirmation threshold (starts 2-day timelock).
    /// @param bps Confirmation threshold in basis points.
    function propConfirmBps(uint256 bps) external onlyOwner {
        if (pConfirmBps.s) revert E1();
        pConfirmBps = PendingUint(bps, block.timestamp + TIMELOCK, true);
        emit Proposal(5, 0, pConfirmBps.t);
    }

    /// @notice Executes the pending confirm BPS change after timelock expires.
    function execConfirmBps() external onlyOwner {
        if (!pConfirmBps.s || block.timestamp < pConfirmBps.t) revert E5();
        pot.setConfirmBps(pConfirmBps.v);
        pConfirmBps.s = false;
        emit Proposal(5, 1, 0);
    }

    /// @notice Cancels the pending confirm BPS proposal.
    function cancelConfirmBps() external onlyOwner {
        pConfirmBps.s = false;
        emit Proposal(5, 2, 0);
    }

    // -------------------------------------------------------------------------
    // Slippage (Timelocked)
    // -------------------------------------------------------------------------

    /// @notice Proposes a new vault deposit slippage tolerance (starts 2-day timelock).
    /// @param bps Slippage in basis points (9900 = 1% max slippage).
    function propSlip(uint256 bps) external onlyOwner {
        if (pSlip.s) revert E1();
        pSlip = PendingUint(bps, block.timestamp + TIMELOCK, true);
        emit Proposal(6, 0, pSlip.t);
    }

    /// @notice Executes the pending slippage change after timelock expires.
    function execSlip() external onlyOwner {
        if (!pSlip.s || block.timestamp < pSlip.t) revert E5();
        pot.setSlippage(pSlip.v);
        pSlip.s = false;
        emit Proposal(6, 1, 0);
    }

    /// @notice Cancels the pending slippage proposal.
    function cancelSlip() external onlyOwner {
        pSlip.s = false;
        emit Proposal(6, 2, 0);
    }

    // -------------------------------------------------------------------------
    // Reserve Withdraw (Timelocked)
    // -------------------------------------------------------------------------

    /// @notice Proposes a reserve withdrawal to treasury (starts 2-day timelock).
    /// @param assets Amount of reserve assets to withdraw.
    function propResW(uint256 assets) external onlyOwner {
        if (pResW.s || assets == 0) revert E1();
        pResW = PendingUint(assets, block.timestamp + TIMELOCK, true);
        emit Proposal(7, 0, pResW.t);
    }

    /// @notice Executes the pending reserve withdrawal after timelock expires.
    function execResW() external onlyOwner {
        if (!pResW.s || block.timestamp < pResW.t) revert E5();
        pot.withdrawReserveToTreasury(pResW.v);
        pResW.s = false;
        emit Proposal(7, 1, 0);
    }

    /// @notice Cancels the pending reserve withdrawal proposal.
    function cancelResW() external onlyOwner {
        pResW.s = false;
        emit Proposal(7, 2, 0);
    }

    // -------------------------------------------------------------------------
    // Immediate Actions (Forwarded)
    // -------------------------------------------------------------------------

    /// @notice Pauses the target yPot contract (immediate, no timelock).
    function pausePot() external onlyOwner {
        pot.pause();
    }

    /// @notice Unpauses the target yPot contract (immediate, no timelock).
    function unpausePot() external onlyOwner {
        pot.unpause();
    }

    /// @notice Cancels a market on the target yPot contract (immediate, no timelock).
    /// @param id Market identifier.
    function cancelMarket(uint256 id) external onlyOwner {
        pot.cancel(id);
    }

    /// @notice Rescues stuck ETH from the target yPot contract (immediate, no timelock).
    /// @param to Recipient address.
    function rescuePotEth(address payable to) external onlyOwner {
        pot.rescueEth(to);
    }

    /// @notice Revokes UMA module approval (immediate, defensive emergency action).
    function revokeUma() external onlyOwner {
        pot.revokeUmaModule();
    }

    /// @notice Revokes a removed oracle's vote on a disputed market (immediate, emergency response).
    /// @param id Market identifier.
    /// @param oracle Oracle address whose vote to revoke.
    function revokeOracleVotePot(uint256 id, address oracle) external onlyOwner {
        pot.revokeOracleVote(id, oracle);
    }
}
