// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {cNGNVault} from "../src/cNGNVault.sol";
import {PerpDEX} from "../src/PerpDEX.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deployment script for the Perpetual DEX system.
///         Set environment variables before running:
///           CNGN_TOKEN      — cNGN ERC20 address
///           NGN_USD_FEED    — Chainlink NGN/USD aggregator
///           NGN_HEARTBEAT   — Max staleness for NGN/USD feed (seconds)
///           BTC_ADDRESS     — Synthetic asset identifier for BTC market
///           BTC_USD_FEED    — Chainlink BTC/USD aggregator
///           BTC_HEARTBEAT   — Max staleness for BTC/USD
///           ETH_ADDRESS     — Synthetic asset identifier for ETH market
///           ETH_USD_FEED    — Chainlink ETH/USD aggregator
///           ETH_HEARTBEAT   — Max staleness for ETH/USD
///           SOL_ADDRESS     — Synthetic asset identifier for SOL market
///           SOL_USD_FEED    — Chainlink SOL/USD aggregator
///           SOL_HEARTBEAT   — Max staleness for SOL/USD
contract DeployPerpDEX is Script {
    function run() external {
        address cNgnToken = vm.envAddress("CNGN_TOKEN");
        address ngnUsdFeed = vm.envAddress("NGN_USD_FEED");
        uint256 ngnHeartbeat = vm.envUint("NGN_HEARTBEAT");

        vm.startBroadcast();

        // 1. Deploy Vault
        cNGNVault vault = new cNGNVault(IERC20(cNgnToken));
        console.log("cNGNVault deployed at:", address(vault));

        // 2. Deploy PerpDEX
        PerpDEX perp = new PerpDEX(cNgnToken, address(vault), ngnUsdFeed, ngnHeartbeat, msg.sender);
        console.log("PerpDEX deployed at:", address(perp));

        // 3. Link vault to PerpDEX
        vault.setPerpDex(address(perp));
        console.log("Vault linked to PerpDEX");

        // 4. Configure BTC market
        address btcAddr = vm.envAddress("BTC_ADDRESS");
        address btcFeed = vm.envAddress("BTC_USD_FEED");
        uint256 btcHb = vm.envUint("BTC_HEARTBEAT");
        perp.configureAsset(btcAddr, btcFeed, btcHb);
        console.log("BTC market configured");

        // 5. Configure ETH market
        address ethAddr = vm.envAddress("ETH_ADDRESS");
        address ethFeed = vm.envAddress("ETH_USD_FEED");
        uint256 ethHb = vm.envUint("ETH_HEARTBEAT");
        perp.configureAsset(ethAddr, ethFeed, ethHb);
        console.log("ETH market configured");

        // 6. Configure SOL market
        address solAddr = vm.envAddress("SOL_ADDRESS");
        address solFeed = vm.envAddress("SOL_USD_FEED");
        uint256 solHb = vm.envUint("SOL_HEARTBEAT");
        perp.configureAsset(solAddr, solFeed, solHb);
        console.log("SOL market configured");

        vm.stopBroadcast();
    }
}
