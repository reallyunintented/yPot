// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {yPot} from "../src/yPot.sol";
import {yPotGov} from "../src/yPotGov.sol";
import {yPotUma} from "../src/yPotUma.sol";
import {YearnWrapper} from "../src/YearnWrapper.sol";
import {UmaOptimisticOracleAdapter} from "../src/UmaOptimisticOracleAdapter.sol";

/**
 * @title DeployGovernance
 * @notice Wires governance (yPotGov) onto an already-deployed yPot.
 *         Run this AFTER DeployyPot.s.sol and optionally DeployYearnWrapper.s.sol.
 *
 * Required env vars:
 *   YPOT        — deployed yPot address (deployer must be current owner)
 *   GOV_OWNER   — multisig / intended governor; must call gov.acceptOwnership() to complete transfer
 *
 * Optional env vars:
 *   YEARN_WRAPPER  — set yPot as depositor on this wrapper (skip if 0x0 or unset)
 *   UMA_ADAPTER    — deploy yPotUma and wire module+requester; skip if 0x0 or unset
 *                    NOTE: UMA wiring happens before ownership transfer so deployer can call setUmaModule.
 *
 * Deploy order:
 *   1. (optional) YearnWrapper.setDepositor(yPot, true)
 *   2. (optional) deploy yPotUma, pot.setUmaModule(yPotUma), adapter.setRequester(yPotUma, true)
 *   3. deploy yPotGov(yPot)
 *   4. pot.transferOwnership(yPotGov) + gov.acceptPotOwnership()
 *   5. gov.transferOwnership(GOV_OWNER)  [GOV_OWNER must then call gov.acceptOwnership()]
 */
contract DeployGovernance is Script {
    function run() external returns (yPotGov gov) {
        address potAddr = vm.envAddress("YPOT");
        address govOwner = vm.envAddress("GOV_OWNER");
        address wrapperAddr = vm.envOr("YEARN_WRAPPER", address(0));
        address umaAdapterAddr = vm.envOr("UMA_ADAPTER", address(0));

        require(potAddr != address(0), "YPOT required");
        require(govOwner != address(0), "GOV_OWNER required");

        yPot pot = yPot(payable(potAddr));

        vm.startBroadcast();

        // Step 1: If YearnWrapper: set yPot as depositor (must be done before gov takes ownership)
        if (wrapperAddr != address(0)) {
            YearnWrapper(wrapperAddr).setDepositor(potAddr, true);
            console2.log("YearnWrapper: yPot set as depositor");
        }

        // Step 2: If UMA: deploy yPotUma and wire before ownership transfer
        //         Order: setUmaModule before setRequester
        if (umaAdapterAddr != address(0)) {
            yPotUma umaModule = new yPotUma(potAddr, umaAdapterAddr);
            console2.log("yPotUma deployed:", address(umaModule));

            pot.setUmaModule(address(umaModule));
            console2.log("yPot.setUmaModule: yPotUma wired");

            UmaOptimisticOracleAdapter(umaAdapterAddr).setRequester(address(umaModule), true);
            console2.log("UmaAdapter.setRequester: yPotUma allowlisted");
        }

        // Step 3: Deploy yPotGov
        gov = new yPotGov(potAddr);
        console2.log("yPotGov deployed:", address(gov));

        // Step 4: Transfer yPot ownership to yPotGov (Ownable2Step)
        pot.transferOwnership(address(gov));
        gov.acceptPotOwnership();
        console2.log("yPotGov now owns yPot");

        // Step 5: Transfer yPotGov ownership to GOV_OWNER (Ownable2Step — initiate only)
        //         GOV_OWNER must call gov.acceptOwnership() to complete.
        gov.transferOwnership(govOwner);
        console2.log("yPotGov.pendingOwner set to:", govOwner);
        console2.log("ACTION REQUIRED: GOV_OWNER must call gov.acceptOwnership() to claim ownership");

        vm.stopBroadcast();
    }
}
