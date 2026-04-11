// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title SovereigntyAccessManager
/// @author Sovereignty Protocol
/// @notice Centralized, upgradeable role-based access manager for the Sovereignty protocol.
///
/// @dev Architecture overview:
///
///      This contract is the single authority that governs *who* can call *which* functions
///      across every protocol contract (PerpDEX, MarketVault, future modules). It follows
///      the OpenZeppelin AccessManager pattern:
///
///        1. Consuming contracts inherit `AccessManaged` and guard sensitive functions with
///           the `restricted` modifier.
///        2. The admin calls `setTargetFunctionRole(target, selectors, roleId)` **on this
///           contract** to bind specific function selectors on a target to a role.
///        3. Accounts are granted roles via `grantRole(roleId, account, executionDelay)`.
///
///      Because all role↔function mappings live here, no consuming contract needs its own
///      setter or role-management logic — changes are made once, in one place.
///
///      Upgradeability (UUPS):
///        - Deployed behind an ERC1967 proxy so new roles can be added (as constants in a
///          new implementation) or upgrade authorization logic can be tightened, all without
///          redeploying consuming contracts.
///        - `_authorizeUpgrade` is restricted to `ADMIN_ROLE` holders.
///
///      Inherited roles (from AccessManagerUpgradeable):
///        - `ADMIN_ROLE` (0)                — full control; can grant roles, set function
///          mappings, and upgrade the implementation.
///        - `PUBLIC_ROLE` (type(uint64).max) — unrestricted; any address qualifies.
contract SovereigntyAccessManager is AccessManagerUpgradeable, UUPSUpgradeable {
    /*//////////////////////////////////////////////////////////////
                              ROLE IDs
    //////////////////////////////////////////////////////////////*/

    // ── Inherited (not re-declared) ──────────────────────────────
    // ADMIN_ROLE   = 0                  — protocol owner / multisig
    // PUBLIC_ROLE  = type(uint64).max   — open to all callers

    /// @notice Operator — day-to-day protocol configuration.
    /// @dev Intended for trusted EOAs or multisigs that perform routine maintenance:
    ///      configuring price feeds, market parameters, and automation forwarders on PerpDEX.
    uint64 public constant OPERATOR_ROLE = 1;

    /// @notice Pauser — emergency pause / unpause of protocol contracts.
    /// @dev Separate from OPERATOR so that a limited-scope guardian (e.g. monitoring bot
    ///      or security council) can halt the protocol without full operator privileges.
    uint64 public constant PAUSER_ROLE = 2;

    /// @notice Upgrader — authorises UUPS upgrades of this manager and managed proxies.
    /// @dev Currently unused by `_authorizeUpgrade` (which checks ADMIN_ROLE directly) but
    ///      reserved for future implementations that may delegate upgrade authority to a
    ///      timelock or governance contract distinct from the admin.
    uint64 public constant UPGRADER_ROLE = 3;

    /// @notice Vault Manager — vault-specific admin operations.
    /// @dev Controls functions like `MarketVault.setPerpDex()`, which links a vault to the
    ///      PerpDEX contract. Kept separate from OPERATOR to enforce least-privilege: an
    ///      operator can tune market parameters but cannot re-wire vault fund flows.
    uint64 public constant VAULT_MANAGER_ROLE = 4;

    /// @notice Liquidator — permissioned liquidation / automation operations.
    /// @dev Reserved for Chainlink Automation forwarders or trusted keeper bots that call
    ///      `PerpDEX.performUpkeep()`. Public liquidation is separate and permissionless.
    uint64 public constant LIQUIDATOR_ROLE = 5;

    /// @notice Market Manager — add/remove/configure markets and deploy market vaults.
    /// @dev Controls `PerpDEX.addMarket()`, `disableMarket()`, and `updateMarketParams()`.
    ///      Segregated so market listing operations require explicit authorization
    ///      distinct from general operator or vault management privileges.
    uint64 public constant MARKET_MANAGER_ROLE = 6;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Disables initializers on the implementation contract to prevent the
    ///      implementation from being initialized directly (only the proxy should
    ///      be initialized). Required safety measure for UUPS proxies.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the manager and grants `ADMIN_ROLE` to `_initialAdmin`.
    /// @dev Called exactly once, on the proxy, immediately after deployment. The initial
    ///      admin should then:
    ///        1. Grant operational roles to the appropriate addresses.
    ///        2. Call `setTargetFunctionRole()` to bind protected functions on PerpDEX
    ///           and MarketVault to their respective roles.
    /// @param _initialAdmin Address that receives `ADMIN_ROLE`. Typically a multisig or
    ///        deployer EOA that will later transfer admin to a more secure setup.
    function initialize(address _initialAdmin) public override initializer {
        __AccessManager_init(_initialAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                           UPGRADE AUTH
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts UUPS upgrades to accounts holding `ADMIN_ROLE`.
    /// @dev Called internally by `upgradeToAndCall()`. Reverts with
    ///      `AccessManagerUnauthorizedAccount` if the caller lacks `ADMIN_ROLE`.
    ///      The `newImplementation` address parameter is intentionally unused — any
    ///      valid implementation can be deployed; authorization is the only gate.
    function _authorizeUpgrade(address) internal view override {
        (bool isMember,) = hasRole(ADMIN_ROLE, msg.sender);
        if (!isMember) revert AccessManagerUnauthorizedAccount(msg.sender, ADMIN_ROLE);
    }
}
