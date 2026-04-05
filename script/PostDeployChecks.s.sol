// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {yPot} from "../src/yPot.sol";
import {YearnWrapper} from "../src/YearnWrapper.sol";
import {UmaOptimisticOracleAdapter} from "../src/UmaOptimisticOracleAdapter.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract PostDeployChecks is Script {
    function run() external view {
        address ypot = vm.envOr("YPOT", address(0));
        address wrapper = vm.envOr("WRAPPER", address(0));
        address uma = vm.envOr("UMA_ADAPTER", address(0));

        if (ypot != address(0)) {
            yPot p = yPot(payable(ypot));
            address asset = address(p.asset());
            require(IERC20Metadata(asset).decimals() == 6, "asset decimals != 6");
            require(IERC4626(address(p.vault())).asset() == asset, "vault.asset mismatch");
            console2.log("yPot ok:", ypot);
        }

        if (wrapper != address(0)) {
            YearnWrapper w = YearnWrapper(wrapper);
            require(IERC4626(address(w.yearnVault())).asset() == w.asset(), "wrapper/yearn asset mismatch");
            console2.log("YearnWrapper ok:", wrapper);
        }

        if (uma != address(0)) {
            UmaOptimisticOracleAdapter a = UmaOptimisticOracleAdapter(uma);
            require(address(a.currency()) != address(0), "uma currency zero");
            require(a.identifier() != bytes32(0), "uma identifier zero");
            console2.log("UMA adapter ok:", uma);
        }
    }
}
