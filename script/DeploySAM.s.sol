// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SovereigntyAccessManager} from "../src/SovereigntyAccessManager.sol";

/// @notice Deployment script for the SovereigntyAccessManager (UUPS proxy).
///         Set environment variables before running:
///           INITIAL_ADMIN — address that receives ADMIN_ROLE
contract DeploySAM is Script {
    function run() external returns (address proxy) {
        address initialAdmin = vm.envAddress("INITIAL_ADMIN");

        vm.startBroadcast();

        // 1. Deploy the implementation contract
        SovereigntyAccessManager implementation = new SovereigntyAccessManager();
        console.log("SAM implementation deployed at:", address(implementation));

        // 2. Deploy the ERC1967 proxy, calling initialize() via delegatecall
        bytes memory initData = abi.encodeCall(SovereigntyAccessManager.initialize, (initialAdmin));
        ERC1967Proxy samProxy = new ERC1967Proxy(address(implementation), initData);
        proxy = address(samProxy);
        console.log("SAM proxy deployed at:", proxy);

        // 3. Label roles for discoverability
        SovereigntyAccessManager sam = SovereigntyAccessManager(proxy);
        sam.labelRole(sam.OPERATOR_ROLE(), "OPERATOR");
        sam.labelRole(sam.PAUSER_ROLE(), "PAUSER");
        sam.labelRole(sam.UPGRADER_ROLE(), "UPGRADER");
        sam.labelRole(sam.VAULT_MANAGER_ROLE(), "VAULT_MANAGER");
        sam.labelRole(sam.LIQUIDATOR_ROLE(), "LIQUIDATOR");
        console.log("Roles labelled");

        vm.stopBroadcast();
    }
}
