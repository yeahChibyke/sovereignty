// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title SovereigntyAccessManager
/// @notice Centralized, upgradeable role-based access manager for the Sovereignty protocol.
///
///         Defines protocol-wide role constants that consuming contracts reference.
///         Consuming contracts inherit AccessManagedUpgradeable and use the `restricted`
///         modifier; role-to-function mappings are configured here via `setTargetFunctionRole`.
///
///         Upgradeable via UUPS so roles can be added, removed, or reassigned without
///         redeploying or adding setter functions to consuming contracts.
contract SovereigntyAccessManager is AccessManagerUpgradeable, UUPSUpgradeable {
    /*//////////////////////////////////////////////////////////////
                              ROLE IDs
    //////////////////////////////////////////////////////////////*/

    // Note: ADMIN_ROLE = 0 and PUBLIC_ROLE = type(uint64).max are inherited
    // from AccessManagerUpgradeable.

    /// @notice Operator — day-to-day protocol configuration.
    ///         e.g. configuring assets, price feeds, forwarders on PerpDEX.
    uint64 public constant OPERATOR_ROLE = 1;

    /// @notice Pauser — emergency pause / unpause of protocol contracts.
    uint64 public constant PAUSER_ROLE = 2;

    /// @notice Upgrader — authorises UUPS upgrades of this manager and managed proxies.
    uint64 public constant UPGRADER_ROLE = 3;

    /// @notice Vault Manager — vault-specific admin operations.
    ///         e.g. linking the PerpDEX to the cNGNVault.
    uint64 public constant VAULT_MANAGER_ROLE = 4;

    /// @notice Liquidator — permissioned liquidation / automation operations.
    uint64 public constant LIQUIDATOR_ROLE = 5;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialises the manager and grants ADMIN_ROLE to `_initialAdmin`.
    /// @param _initialAdmin Address that receives ADMIN_ROLE (can then grant other roles).
    function initialize(address _initialAdmin) public override initializer {
        __AccessManager_init(_initialAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                           UPGRADE AUTH
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts UUPS upgrades to accounts holding ADMIN_ROLE.
    function _authorizeUpgrade(address) internal view override {
        (bool isMember,) = hasRole(ADMIN_ROLE, msg.sender);
        if (!isMember) revert AccessManagerUnauthorizedAccount(msg.sender, ADMIN_ROLE);
    }
}
