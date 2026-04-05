// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {YearnWrapper} from "../src/YearnWrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract DeployYearnWrapper is Script {
    function run() external returns (YearnWrapper wrapper) {
        address asset = vm.envAddress("ASSET");
        address yearnVault = vm.envAddress("YEARN_VAULT");

        uint256 depositorCount = vm.envOr("DEPOSITOR_COUNT", uint256(0));
        address[] memory depositors = new address[](depositorCount);
        for (uint256 i; i < depositorCount; i++) {
            depositors[i] = vm.envAddress(string.concat("DEPOSITOR_", vm.toString(i)));
        }

        vm.startBroadcast();
        wrapper = new YearnWrapper(IERC20(asset), IERC4626(yearnVault), depositors);
        vm.stopBroadcast();

        console2.log("YearnWrapper deployed:", address(wrapper));
    }
}
