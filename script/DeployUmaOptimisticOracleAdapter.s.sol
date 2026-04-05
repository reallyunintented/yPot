// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {UmaOptimisticOracleAdapter} from "../src/UmaOptimisticOracleAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployUmaOptimisticOracleAdapter is Script {
    function run() external returns (UmaOptimisticOracleAdapter adapter) {
        address optimisticOracle = vm.envAddress("UMA_OPTIMISTIC_ORACLE");
        address currency = vm.envAddress("CURRENCY");
        bytes32 identifier = vm.envBytes32("UMA_IDENTIFIER");

        uint256 liveness = vm.envOr("UMA_LIVENESS", uint256(0));
        uint256 bond = vm.envOr("UMA_BOND", uint256(0));
        uint256 reward = vm.envOr("UMA_REWARD", uint256(0));

        uint256 requesterCount = vm.envOr("REQUESTER_COUNT", uint256(0));
        address[] memory requesters = new address[](requesterCount);
        for (uint256 i; i < requesterCount; i++) {
            requesters[i] = vm.envAddress(string.concat("REQUESTER_", vm.toString(i)));
        }

        vm.startBroadcast();
        adapter = new UmaOptimisticOracleAdapter(
            optimisticOracle, IERC20(currency), identifier, liveness, bond, reward, requesters
        );
        vm.stopBroadcast();

        console2.log("UmaOptimisticOracleAdapter deployed:", address(adapter));
    }
}
