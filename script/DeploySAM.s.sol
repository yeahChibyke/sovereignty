// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SovereigntyAccessManager} from "../src/SovereigntyAccessManager.sol";

/// @title DeploySAM
/// @notice Deployment script for the SovereigntyAccessManager (UUPS proxy pattern).
/// @dev Deploys a transparent UUPS proxy pointing at a fresh SAM implementation,
///      then labels all six custom roles so they appear in etherscan / block explorers.
///
///      Deployment flow:
///        1. Deploy bare SovereigntyAccessManager (implementation).
///        2. Deploy ERC1967Proxy whose constructor delegates to `initialize(initialAdmin)`.
///        3. Label each role via `labelRole()` for on-chain discoverability.
///
///      Required environment variables:
///        INITIAL_ADMIN        — address that receives the ADMIN_ROLE (role 0).
///        DEPLOYER_PRIVATE_KEY — wallet that broadcasts the transactions.
///
///      Usage:
///        forge script script/DeploySAM.s.sol --rpc-url $BASE_RPC --broadcast --verify
contract DeploySAM is Script {
    /// @notice Entry point. Deploys the SAM proxy and labels all roles.
    /// @return proxy The address of the deployed ERC1967 proxy (interact via this address).
    function run() external returns (address proxy) {
        address initialAdmin = vm.envAddress("INITIAL_ADMIN");

        vm.startBroadcast();

        // 1. Deploy the implementation contract (no state — just bytecode)
        SovereigntyAccessManager implementation = new SovereigntyAccessManager();
        console.log("SAM implementation deployed at:", address(implementation));

        // 2. Deploy the ERC1967 proxy, calling initialize(initialAdmin) via delegatecall.
        //    This sets initialAdmin as ADMIN_ROLE holder in the proxy's storage.
        bytes memory initData = abi.encodeCall(SovereigntyAccessManager.initialize, (initialAdmin));
        ERC1967Proxy samProxy = new ERC1967Proxy(address(implementation), initData);
        proxy = address(samProxy);
        console.log("SAM proxy deployed at:", proxy);

        // 3. Label each custom role for block-explorer discoverability.
        //    Role IDs: OPERATOR=1, PAUSER=2, UPGRADER=3, VAULT_MANAGER=4, LIQUIDATOR=5, MARKET_MANAGER=6.
        SovereigntyAccessManager sam = SovereigntyAccessManager(proxy);
        sam.labelRole(sam.OPERATOR_ROLE(), "OPERATOR");
        sam.labelRole(sam.PAUSER_ROLE(), "PAUSER");
        sam.labelRole(sam.UPGRADER_ROLE(), "UPGRADER");
        sam.labelRole(sam.VAULT_MANAGER_ROLE(), "VAULT_MANAGER");
        sam.labelRole(sam.LIQUIDATOR_ROLE(), "LIQUIDATOR");
        sam.labelRole(sam.MARKET_MANAGER_ROLE(), "MARKET_MANAGER");
        console.log("Roles labelled");

        vm.stopBroadcast();
    }
}
