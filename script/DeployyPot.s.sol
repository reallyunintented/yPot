// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {yPot} from "../src/yPot.sol";
import {yPotViews} from "../src/yPotViews.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract DeployyPot is Script {
    function run() external returns (yPot pot) {
        address asset = vm.envAddress("ASSET");
        address vault = vm.envAddress("VAULT");
        address treasury = vm.envAddress("TREASURY");

        uint256 oracleCount = vm.envOr("ORACLE_COUNT", uint256(0));
        require(oracleCount >= 2, "ORACLE_COUNT>=2");
        address[] memory oracles = new address[](oracleCount);
        for (uint256 i; i < oracleCount; i++) {
            oracles[i] = vm.envAddress(string.concat("ORACLE_", vm.toString(i)));
        }

        // NOTE: deployer must hold ≥ 1 USDC (1e6) before running this script.
        // Bootstrap 1 USDC into vault to prevent share inflation attack.
        vm.startBroadcast();
        pot = new yPot(asset, vault, treasury, oracles);
        yPotViews views = new yPotViews(address(pot));

        // Bootstrap wrapper with 1 USDC (deployer holds shares permanently)
        IERC20(asset).approve(vault, 1e6);
        IERC4626(vault).deposit(1e6, msg.sender);
        vm.stopBroadcast();

        console2.log("yPot deployed:", address(pot));
        console2.log("yPotViews deployed:", address(views));
    }
}
