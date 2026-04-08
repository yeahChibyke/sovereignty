// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {cNGNVault} from "../src/cNGNVault.sol";
import {PerpDEX} from "../src/PerpDEX.sol";
import {SovereigntyAccessManager} from "../src/SovereigntyAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deployment script for the Perpetual DEX system.
///         Requires a previously deployed SAM proxy (see DeploySAM.s.sol).
///         Set environment variables before running:
///           SAM_PROXY       — SovereigntyAccessManager proxy address
///           CNGN_TOKEN      — cNGN ERC20 address
///           NGN_USD_FEED    — Chainlink NGN/USD aggregator
///           NGN_HEARTBEAT   — Max staleness for NGN/USD feed (seconds)
///           BTC_ADDRESS     — Asset address identifier for BTC market
///           BTC_USD_FEED    — Chainlink BTC/USD aggregator
///           BTC_HEARTBEAT   — Max staleness for BTC/USD
///           ETH_ADDRESS     — Asset address identifier for ETH market
///           ETH_USD_FEED    — Chainlink ETH/USD aggregator
///           ETH_HEARTBEAT   — Max staleness for ETH/USD
///           SOL_ADDRESS     — Asset address identifier for SOL market
///           SOL_USD_FEED    — Chainlink SOL/USD aggregator
///           SOL_HEARTBEAT   — Max staleness for SOL/USD
contract DeployPerpDEX is Script {
    function run() external {
        address samProxy = vm.envAddress("SAM_PROXY");
        address cNgnToken = vm.envAddress("CNGN_TOKEN");
        address ngnUsdFeed = vm.envAddress("NGN_USD_FEED");
        uint256 ngnHeartbeat = vm.envUint("NGN_HEARTBEAT");

        SovereigntyAccessManager sam = SovereigntyAccessManager(samProxy);

        vm.startBroadcast();

        // 1. Deploy Vault (pass SAM proxy as access manager)
        cNGNVault vault = new cNGNVault(IERC20(cNgnToken), samProxy);
        console.log("cNGNVault deployed at:", address(vault));

        // 2. Deploy PerpDEX (pass SAM proxy as access manager)
        PerpDEX perp = new PerpDEX(cNgnToken, address(vault), ngnUsdFeed, ngnHeartbeat, samProxy);
        console.log("PerpDEX deployed at:", address(perp));

        // 3. Configure SAM: map vault function to VAULT_MANAGER_ROLE
        bytes4[] memory vaultSelectors = new bytes4[](1);
        vaultSelectors[0] = cNGNVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), vaultSelectors, sam.VAULT_MANAGER_ROLE());

        // 4. Configure SAM: map PerpDEX admin functions to appropriate roles
        bytes4[] memory operatorSelectors = new bytes4[](3);
        operatorSelectors[0] = PerpDEX.configureAsset.selector;
        operatorSelectors[1] = PerpDEX.setNgnUsdFeed.selector;
        operatorSelectors[2] = PerpDEX.setForwarder.selector;
        sam.setTargetFunctionRole(address(perp), operatorSelectors, sam.OPERATOR_ROLE());

        bytes4[] memory pauserSelectors = new bytes4[](2);
        pauserSelectors[0] = PerpDEX.pause.selector;
        pauserSelectors[1] = PerpDEX.unpause.selector;
        sam.setTargetFunctionRole(address(perp), pauserSelectors, sam.PAUSER_ROLE());

        // 5. Grant VAULT_MANAGER_ROLE to broadcaster so they can link vault
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), msg.sender, 0);

        // 6. Link vault to PerpDEX
        vault.setPerpDex(address(perp));
        console.log("Vault linked to PerpDEX");

        // 7. Grant OPERATOR_ROLE to broadcaster for asset configuration
        sam.grantRole(sam.OPERATOR_ROLE(), msg.sender, 0);

        // 8. Configure BTC market
        address btcAddr = vm.envAddress("BTC_ADDRESS");
        address btcFeed = vm.envAddress("BTC_USD_FEED");
        uint256 btcHb = vm.envUint("BTC_HEARTBEAT");
        perp.configureAsset(btcAddr, btcFeed, btcHb);
        console.log("BTC market configured");

        // 9. Configure ETH market
        address ethAddr = vm.envAddress("ETH_ADDRESS");
        address ethFeed = vm.envAddress("ETH_USD_FEED");
        uint256 ethHb = vm.envUint("ETH_HEARTBEAT");
        perp.configureAsset(ethAddr, ethFeed, ethHb);
        console.log("ETH market configured");

        // 10. Configure SOL market
        address solAddr = vm.envAddress("SOL_ADDRESS");
        address solFeed = vm.envAddress("SOL_USD_FEED");
        uint256 solHb = vm.envUint("SOL_HEARTBEAT");
        perp.configureAsset(solAddr, solFeed, solHb);
        console.log("SOL market configured");

        vm.stopBroadcast();
    }
}
