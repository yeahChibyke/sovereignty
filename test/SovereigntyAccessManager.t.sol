// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SovereigntyAccessManager} from "../src/SovereigntyAccessManager.sol";

/// @title SovereigntyAccessManagerTest
/// @notice Unit tests for the SovereigntyAccessManager UUPS-proxied access control contract.
/// @dev Validates:
///      - ADMIN_ROLE is correctly assigned during initialization
///      - All 6 custom role constants resolve to expected uint64 IDs
///      - Admin can grant and revoke roles
///      - Non-admin callers cannot grant roles
///      - UUPS upgrade authorization (admin-only)
///      - A single account can hold multiple roles simultaneously
///      - Double-initialization is blocked by the Initializable guard
contract SovereigntyAccessManagerTest is Test {
    SovereigntyAccessManager sam;

    address admin = makeAddr("admin");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    /// @notice Deploys a fresh SAM instance behind an ERC1967 proxy.
    /// @dev Mimics the production DeploySAM script: deploy implementation, then
    ///      proxy with `initialize(admin)` as the constructor calldata.
    function setUp() public {
        vm.startPrank(admin);
        SovereigntyAccessManager samImpl = new SovereigntyAccessManager();
        bytes memory initData = abi.encodeCall(SovereigntyAccessManager.initialize, (admin));
        ERC1967Proxy samProxy = new ERC1967Proxy(address(samImpl), initData);
        sam = SovereigntyAccessManager(address(samProxy));
        vm.stopPrank();
    }

    /// @notice The initial admin receives ADMIN_ROLE (role 0) at initialization.
    function test_admin_has_admin_role() public view {
        (bool isMember,) = sam.hasRole(sam.ADMIN_ROLE(), admin);
        assertTrue(isMember);
    }

    /// @notice Each custom role constant resolves to a sequential uint64 (1–6).
    function test_role_constants() public view {
        assertEq(sam.OPERATOR_ROLE(), 1);
        assertEq(sam.PAUSER_ROLE(), 2);
        assertEq(sam.UPGRADER_ROLE(), 3);
        assertEq(sam.VAULT_MANAGER_ROLE(), 4);
        assertEq(sam.LIQUIDATOR_ROLE(), 5);
        assertEq(sam.MARKET_MANAGER_ROLE(), 6);
    }

    /// @notice Admin can grant a role to any address.
    function test_grant_role() public {
        vm.startPrank(admin);
        sam.grantRole(sam.OPERATOR_ROLE(), user1, 0);
        vm.stopPrank();

        (bool isMember,) = sam.hasRole(sam.OPERATOR_ROLE(), user1);
        assertTrue(isMember);
    }

    /// @notice Admin can revoke a previously granted role.
    function test_revoke_role() public {
        vm.startPrank(admin);
        sam.grantRole(sam.OPERATOR_ROLE(), user1, 0);
        sam.revokeRole(sam.OPERATOR_ROLE(), user1);
        vm.stopPrank();

        (bool isMember,) = sam.hasRole(sam.OPERATOR_ROLE(), user1);
        assertFalse(isMember);
    }

    /// @notice Non-admin callers are rejected when attempting to grant roles.
    function test_non_admin_cannot_grant() public {
        uint64 role = sam.OPERATOR_ROLE();
        vm.prank(user1);
        vm.expectRevert();
        sam.grantRole(role, user2, 0);
    }

    /// @notice Admin can perform a UUPS upgrade to a new implementation.
    function test_upgrade_authorized_by_admin() public {
        SovereigntyAccessManager newImpl = new SovereigntyAccessManager();
        vm.prank(admin);
        sam.upgradeToAndCall(address(newImpl), "");
    }

    /// @notice Non-admin callers are rejected when attempting UUPS upgrades.
    function test_upgrade_unauthorized_reverts() public {
        SovereigntyAccessManager newImpl = new SovereigntyAccessManager();
        vm.prank(user1);
        vm.expectRevert();
        sam.upgradeToAndCall(address(newImpl), "");
    }

    /// @notice A single address can hold multiple distinct roles simultaneously.
    function test_multiple_roles_same_user() public {
        vm.startPrank(admin);
        sam.grantRole(sam.OPERATOR_ROLE(), user1, 0);
        sam.grantRole(sam.PAUSER_ROLE(), user1, 0);
        sam.grantRole(sam.MARKET_MANAGER_ROLE(), user1, 0);
        vm.stopPrank();

        (bool isOp,) = sam.hasRole(sam.OPERATOR_ROLE(), user1);
        (bool isPauser,) = sam.hasRole(sam.PAUSER_ROLE(), user1);
        (bool isMarketMgr,) = sam.hasRole(sam.MARKET_MANAGER_ROLE(), user1);

        assertTrue(isOp);
        assertTrue(isPauser);
        assertTrue(isMarketMgr);
    }

    /// @notice Calling initialize() a second time reverts (Initializable guard).
    function test_initialize_twice_reverts() public {
        vm.expectRevert();
        sam.initialize(user1);
    }
}
