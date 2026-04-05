// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {YearnWrapper} from "../src/YearnWrapper.sol";
import {PreviewFaucet} from "../src/PreviewFaucet.sol";
import {yPot} from "../src/yPot.sol";
import {yPotUma} from "../src/yPotUma.sol";
import {yPotGov} from "../src/yPotGov.sol";
import {yPotViews} from "../src/yPotViews.sol";
import {UmaOptimisticOracleAdapter} from "../src/UmaOptimisticOracleAdapter.sol";

import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockERC4626Vault} from "../test/mocks/MockERC4626Vault.sol";
import {MockUmaOptimisticOracle} from "../test/mocks/MockUmaOptimisticOracle.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract DeployLocalStack is Script {
    using stdJson for string;

    function run() external returns (address potAddr) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");

        address treasury = vm.envOr("TREASURY", vm.addr(deployerPk));
        address oracle0 = vm.envOr("ORACLE_0", vm.addr(deployerPk));
        address oracle1 = vm.envOr("ORACLE_1", address(0xBEEF));

        bool withUma = vm.envOr("WITH_UMA", false);
        string memory outPath = vm.envOr("OUT", string.concat(vm.projectRoot(), "/deployments/anvil.json"));
        uint256 faucetClaimAmount = vm.envOr("FAUCET_CLAIM_AMOUNT", uint256(10_000e6));
        uint256 faucetClaimCooldown = vm.envOr("FAUCET_CLAIM_COOLDOWN", uint256(1 hours));
        uint256 faucetSeedAmount = vm.envOr("FAUCET_SEED_AMOUNT", uint256(100_000_000e6));

        vm.startBroadcast(deployerPk);

        MockUSDC usdc = new MockUSDC();
        PreviewFaucet previewFaucet =
            new PreviewFaucet(address(usdc), vm.addr(deployerPk), faucetClaimAmount, faucetClaimCooldown);

        // "Yearn" vault mock + wrapper (so yPot interacts with ERC4626 wrapper like prod).
        MockERC4626Vault yearn = new MockERC4626Vault(usdc);

        address[] memory initialDepositors = new address[](1);
        initialDepositors[0] = vm.addr(deployerPk);
        YearnWrapper wrapper = new YearnWrapper(usdc, IERC4626(address(yearn)), initialDepositors);

        address optimisticOracle = address(0);
        address umaAdapter = address(0);
        address umaModule = address(0);
        if (withUma) {
            MockUmaOptimisticOracle mockUma = new MockUmaOptimisticOracle();
            optimisticOracle = address(mockUma);

            address[] memory requesters = new address[](1);
            requesters[0] = vm.addr(deployerPk); // will add UMA module as requester post-deploy
            UmaOptimisticOracleAdapter adapter =
                new UmaOptimisticOracleAdapter(address(mockUma), usdc, keccak256("YPOT_LOCAL"), 0, 0, 0, requesters);
            umaAdapter = address(adapter);
        }

        address[] memory oracles = new address[](2);
        oracles[0] = oracle0;
        oracles[1] = oracle1;

        yPot pot = new yPot(address(usdc), address(wrapper), treasury, oracles);

        // authorize yPot as depositor in wrapper
        wrapper.setDepositor(address(pot), true);

        // Seed the preview faucet so public testnet users can self-serve mUSDC.
        usdc.mint(address(previewFaucet), faucetSeedAmount);

        // Bootstrap 1 USDC into wrapper to prevent share inflation attack
        usdc.mint(vm.addr(deployerPk), 1e6);
        usdc.approve(address(wrapper), 1e6);
        wrapper.deposit(1e6, vm.addr(deployerPk)); // deployer holds 1 USDC worth of shares forever

        yPotViews views = new yPotViews(address(pot));
        address viewsAddr = address(views);
        console2.log("DEPLOY_VIEWS", viewsAddr);

        // set UMA module (if enabled)
        if (withUma) {
            yPotUma module = new yPotUma(address(pot), umaAdapter);
            umaModule = address(module);
            pot.setUmaModule(umaModule);
            UmaOptimisticOracleAdapter(umaAdapter).setRequester(umaModule, true);
        }

        // Deploy governance wrapper and transfer yPot ownership to it
        yPotGov gov = new yPotGov(address(pot));
        pot.transferOwnership(address(gov));
        gov.acceptPotOwnership();

        vm.stopBroadcast();

        potAddr = address(pot);

        console2.log("DEPLOY_ASSET", address(usdc));
        console2.log("DEPLOY_PREVIEW_FAUCET", address(previewFaucet));
        console2.log("DEPLOY_YEARN_MOCK", address(yearn));
        console2.log("DEPLOY_VAULT", address(wrapper));
        console2.log("DEPLOY_UMA_OO", optimisticOracle);
        console2.log("DEPLOY_UMA_ADAPTER", umaAdapter);
        console2.log("DEPLOY_UMA_MODULE", umaModule);
        console2.log("DEPLOY_POT", potAddr);
        console2.log("DEPLOY_GOV", address(gov));
        console2.log("DEPLOY_TREASURY", treasury);
        console2.log("DEPLOY_ORACLE_0", oracle0);
        console2.log("DEPLOY_ORACLE_1", oracle1);

        string memory jsonKey = "deploy";
        jsonKey.serialize("chainId", block.chainid);
        jsonKey.serialize("startBlock", block.number);
        jsonKey.serialize("asset", address(usdc));
        jsonKey.serialize("previewFaucet", address(previewFaucet));
        jsonKey.serialize("vault", address(wrapper));
        jsonKey.serialize("yPot", potAddr);
        jsonKey.serialize("yPotGov", address(gov));
        jsonKey.serialize("yearnVault", address(yearn));
        jsonKey.serialize("umaOptimisticOracle", optimisticOracle);
        jsonKey.serialize("umaAdapter", umaAdapter);
        jsonKey.serialize("yPotViews", viewsAddr);
        string memory json = jsonKey.serialize("umaModule", umaModule);
        json.write(outPath);
    }
}
