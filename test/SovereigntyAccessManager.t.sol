// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {SovereigntyAccessManager} from "../src/SovereigntyAccessManager.sol";
import {cNGNVault} from "../src/cNGNVault.sol";
import {PerpDEX} from "../src/PerpDEX.sol";
import {MockcNGN} from "./mocks/MockcNGN.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract SovereigntyAccessManagerTest is Test {
    SovereigntyAccessManager public sam;
    SovereigntyAccessManager public samImpl;

    MockcNGN public token;
    cNGNVault public vault;
    PerpDEX public perp;
    MockAggregator public ngnUsdFeed;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address pauser = makeAddr("pauser");
    address vaultManager = makeAddr("vaultManager");
    address nobody = makeAddr("nobody");

    uint256 constant ONE_TOKEN = 1e6;

    function setUp() public {
        // Deploy SAM via UUPS proxy
        samImpl = new SovereigntyAccessManager();
        ERC1967Proxy samProxy =
            new ERC1967Proxy(address(samImpl), abi.encodeCall(SovereigntyAccessManager.initialize, (admin)));
        sam = SovereigntyAccessManager(address(samProxy));

        // Deploy consuming contracts
        token = new MockcNGN();
        vault = new cNGNVault(IERC20(address(token)), address(sam));
        ngnUsdFeed = new MockAggregator(625e3, 8);
        perp = new PerpDEX(address(token), address(vault), address(ngnUsdFeed), 3600, address(sam));
    }

    /*//////////////////////////////////////////////////////////////
                     SECTION 1: INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_adminHasAdminRole() public view {
        (bool isMember,) = sam.hasRole(sam.ADMIN_ROLE(), admin);
        assertTrue(isMember);
    }

    function test_initialize_nobodyHasNoRole() public view {
        (bool isMember,) = sam.hasRole(sam.ADMIN_ROLE(), nobody);
        assertFalse(isMember);
        (isMember,) = sam.hasRole(sam.OPERATOR_ROLE(), nobody);
        assertFalse(isMember);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        sam.initialize(nobody);
    }

    function test_implementation_cannotInitialize() public {
        vm.expectRevert();
        samImpl.initialize(nobody);
    }

    /*//////////////////////////////////////////////////////////////
                     SECTION 2: ROLE CONSTANTS
    //////////////////////////////////////////////////////////////*/

    function test_roleConstants() public view {
        assertEq(sam.ADMIN_ROLE(), 0);
        assertEq(sam.OPERATOR_ROLE(), 1);
        assertEq(sam.PAUSER_ROLE(), 2);
        assertEq(sam.UPGRADER_ROLE(), 3);
        assertEq(sam.VAULT_MANAGER_ROLE(), 4);
        assertEq(sam.LIQUIDATOR_ROLE(), 5);
        assertEq(sam.PUBLIC_ROLE(), type(uint64).max);
    }

    /*//////////////////////////////////////////////////////////////
                  SECTION 3: GRANT & REVOKE ROLES
    //////////////////////////////////////////////////////////////*/

    function test_grantRole_success() public {
        vm.startPrank(admin);
        sam.grantRole(sam.OPERATOR_ROLE(), operator, 0);
        vm.stopPrank();

        (bool isMember,) = sam.hasRole(sam.OPERATOR_ROLE(), operator);
        assertTrue(isMember);
    }

    function test_grantRole_onlyAdmin() public {
        uint64 operatorRole = sam.OPERATOR_ROLE();
        uint64 adminRole = sam.ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, nobody, adminRole)
        );
        vm.prank(nobody);
        sam.grantRole(operatorRole, operator, 0);
    }

    function test_revokeRole_success() public {
        vm.startPrank(admin);
        sam.grantRole(sam.OPERATOR_ROLE(), operator, 0);
        sam.revokeRole(sam.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        (bool isMember,) = sam.hasRole(sam.OPERATOR_ROLE(), operator);
        assertFalse(isMember);
    }

    function test_grantMultipleRoles_sameAccount() public {
        vm.startPrank(admin);
        sam.grantRole(sam.OPERATOR_ROLE(), operator, 0);
        sam.grantRole(sam.PAUSER_ROLE(), operator, 0);
        vm.stopPrank();

        (bool isOp,) = sam.hasRole(sam.OPERATOR_ROLE(), operator);
        (bool isPauser,) = sam.hasRole(sam.PAUSER_ROLE(), operator);
        assertTrue(isOp);
        assertTrue(isPauser);
    }

    function test_grantRole_multipleAccounts() public {
        address ops2 = makeAddr("ops2");
        vm.startPrank(admin);
        sam.grantRole(sam.OPERATOR_ROLE(), operator, 0);
        sam.grantRole(sam.OPERATOR_ROLE(), ops2, 0);
        vm.stopPrank();

        (bool isOp1,) = sam.hasRole(sam.OPERATOR_ROLE(), operator);
        (bool isOp2,) = sam.hasRole(sam.OPERATOR_ROLE(), ops2);
        assertTrue(isOp1);
        assertTrue(isOp2);
    }

    /*//////////////////////////////////////////////////////////////
         SECTION 4: FUNCTION-TO-ROLE MAPPING & ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_setTargetFunctionRole_success() public {
        vm.startPrank(admin);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = cNGNVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), selectors, sam.VAULT_MANAGER_ROLE());
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), vaultManager, 0);

        vm.stopPrank();

        // vaultManager can call setPerpDex
        vm.prank(vaultManager);
        vault.setPerpDex(address(perp));
        assertEq(vault.perpDex(), address(perp));
    }

    function test_unmappedFunction_blockedByDefault() public {
        // setPerpDex is not yet mapped to any role → defaults to ADMIN_ROLE
        // nobody is not admin → blocked
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, nobody));
        vm.prank(nobody);
        vault.setPerpDex(address(perp));
    }

    function test_unmappedFunction_adminCanCall() public {
        // Default role for unmapped functions is ADMIN_ROLE
        vm.prank(admin);
        vault.setPerpDex(address(perp));
        assertEq(vault.perpDex(), address(perp));
    }

    function test_wrongRole_blocked() public {
        vm.startPrank(admin);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = cNGNVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), selectors, sam.VAULT_MANAGER_ROLE());
        sam.grantRole(sam.OPERATOR_ROLE(), operator, 0);
        // Note: operator has OPERATOR_ROLE, but setPerpDex requires VAULT_MANAGER_ROLE

        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        vm.prank(operator);
        vault.setPerpDex(address(perp));
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 5: DYNAMIC ROLE CHANGES (NO REDEPLOY)
    //////////////////////////////////////////////////////////////*/

    function test_grantAfterDeploy_immediateAccess() public {
        // Map and initially no one has the role
        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = cNGNVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), selectors, sam.VAULT_MANAGER_ROLE());
        vm.stopPrank();

        // vaultManager blocked
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, vaultManager));
        vm.prank(vaultManager);
        vault.setPerpDex(address(perp));

        // Grant role → immediate access
        vm.startPrank(admin);
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), vaultManager, 0);
        vm.stopPrank();

        vm.prank(vaultManager);
        vault.setPerpDex(address(perp));
        assertEq(vault.perpDex(), address(perp));
    }

    function test_revokeAfterGrant_immediateBlock() public {
        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = cNGNVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), selectors, sam.VAULT_MANAGER_ROLE());
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), vaultManager, 0);
        vm.stopPrank();

        // Works
        vm.prank(vaultManager);
        vault.setPerpDex(address(perp));

        // Revoke
        vm.startPrank(admin);
        sam.revokeRole(sam.VAULT_MANAGER_ROLE(), vaultManager);
        vm.stopPrank();

        // Now blocked
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, vaultManager));
        vm.prank(vaultManager);
        vault.setPerpDex(makeAddr("other"));
    }

    function test_remapFunction_changesRequiredRole() public {
        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = cNGNVault.setPerpDex.selector;

        // Initially map to VAULT_MANAGER_ROLE
        sam.setTargetFunctionRole(address(vault), selectors, sam.VAULT_MANAGER_ROLE());
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), vaultManager, 0);
        sam.grantRole(sam.OPERATOR_ROLE(), operator, 0);
        vm.stopPrank();

        // vaultManager can call, operator cannot
        vm.prank(vaultManager);
        vault.setPerpDex(address(perp));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        vm.prank(operator);
        vault.setPerpDex(makeAddr("x"));

        // Remap to OPERATOR_ROLE
        vm.startPrank(admin);
        sam.setTargetFunctionRole(address(vault), selectors, sam.OPERATOR_ROLE());
        vm.stopPrank();

        // Now operator can call, vaultManager cannot
        vm.prank(operator);
        vault.setPerpDex(makeAddr("new"));
        assertEq(vault.perpDex(), makeAddr("new"));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, vaultManager));
        vm.prank(vaultManager);
        vault.setPerpDex(makeAddr("y"));
    }

    /*//////////////////////////////////////////////////////////////
        SECTION 6: CROSS-CONTRACT ROLE ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_roleIsolation_perContract() public {
        vm.startPrank(admin);

        // Map vault.setPerpDex → VAULT_MANAGER_ROLE
        bytes4[] memory vaultSelectors = new bytes4[](1);
        vaultSelectors[0] = cNGNVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), vaultSelectors, sam.VAULT_MANAGER_ROLE());
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), vaultManager, 0);

        // Map perp.configureAsset → OPERATOR_ROLE
        bytes4[] memory perpSelectors = new bytes4[](1);
        perpSelectors[0] = PerpDEX.configureAsset.selector;
        sam.setTargetFunctionRole(address(perp), perpSelectors, sam.OPERATOR_ROLE());
        sam.grantRole(sam.OPERATOR_ROLE(), operator, 0);

        vm.stopPrank();

        // vaultManager can call vault but not perp
        vm.prank(vaultManager);
        vault.setPerpDex(address(perp));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, vaultManager));
        vm.prank(vaultManager);
        perp.configureAsset(makeAddr("x"), address(ngnUsdFeed), 3600);

        // operator can call perp but not vault
        MockAggregator feed = new MockAggregator(60_000e8, 8);
        vm.prank(operator);
        perp.configureAsset(makeAddr("x"), address(feed), 3600);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        vm.prank(operator);
        vault.setPerpDex(makeAddr("y"));
    }

    /*//////////////////////////////////////////////////////////////
                     SECTION 7: UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    function test_upgrade_onlyAdmin() public {
        SovereigntyAccessManager newImpl = new SovereigntyAccessManager();

        uint64 adminRole = sam.ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, nobody, adminRole)
        );
        vm.prank(nobody);
        sam.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_adminSucceeds() public {
        SovereigntyAccessManager newImpl = new SovereigntyAccessManager();

        vm.prank(admin);
        sam.upgradeToAndCall(address(newImpl), "");

        // SAM still works after upgrade — admin still has role
        (bool isMember,) = sam.hasRole(sam.ADMIN_ROLE(), admin);
        assertTrue(isMember);
    }

    function test_upgrade_preservesState() public {
        // Grant some roles before upgrade
        vm.startPrank(admin);
        sam.grantRole(sam.OPERATOR_ROLE(), operator, 0);
        sam.grantRole(sam.PAUSER_ROLE(), pauser, 0);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = cNGNVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), selectors, sam.VAULT_MANAGER_ROLE());
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), vaultManager, 0);
        vm.stopPrank();

        // Upgrade
        SovereigntyAccessManager newImpl = new SovereigntyAccessManager();
        vm.prank(admin);
        sam.upgradeToAndCall(address(newImpl), "");

        // All state preserved
        (bool isOp,) = sam.hasRole(sam.OPERATOR_ROLE(), operator);
        assertTrue(isOp);
        (bool isPauser,) = sam.hasRole(sam.PAUSER_ROLE(), pauser);
        assertTrue(isPauser);
        (bool isVm,) = sam.hasRole(sam.VAULT_MANAGER_ROLE(), vaultManager);
        assertTrue(isVm);

        // Function mapping still works
        vm.prank(vaultManager);
        vault.setPerpDex(address(perp));
        assertEq(vault.perpDex(), address(perp));
    }

    /*//////////////////////////////////////////////////////////////
              SECTION 8: CONSUMING CONTRACTS AUTHORITY
    //////////////////////////////////////////////////////////////*/

    function test_vault_authority() public view {
        assertEq(vault.authority(), address(sam));
    }

    function test_perp_authority() public view {
        assertEq(perp.authority(), address(sam));
    }

    /*//////////////////////////////////////////////////////////////
          SECTION 9: END-TO-END MULTI-ROLE SCENARIO
    //////////////////////////////////////////////////////////////*/

    function test_endToEnd_fullProtocolSetup() public {
        // Admin sets up all role mappings
        vm.startPrank(admin);

        bytes4[] memory vaultSelectors = new bytes4[](1);
        vaultSelectors[0] = cNGNVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), vaultSelectors, sam.VAULT_MANAGER_ROLE());

        bytes4[] memory operatorSelectors = new bytes4[](3);
        operatorSelectors[0] = PerpDEX.configureAsset.selector;
        operatorSelectors[1] = PerpDEX.setNgnUsdFeed.selector;
        operatorSelectors[2] = PerpDEX.setForwarder.selector;
        sam.setTargetFunctionRole(address(perp), operatorSelectors, sam.OPERATOR_ROLE());

        bytes4[] memory pauserSelectors = new bytes4[](2);
        pauserSelectors[0] = PerpDEX.pause.selector;
        pauserSelectors[1] = PerpDEX.unpause.selector;
        sam.setTargetFunctionRole(address(perp), pauserSelectors, sam.PAUSER_ROLE());

        // Assign roles to different accounts
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), vaultManager, 0);
        sam.grantRole(sam.OPERATOR_ROLE(), operator, 0);
        sam.grantRole(sam.PAUSER_ROLE(), pauser, 0);

        vm.stopPrank();

        // vaultManager links vault
        vm.prank(vaultManager);
        vault.setPerpDex(address(perp));

        // operator configures assets
        MockAggregator btcFeed = new MockAggregator(60_000e8, 8);
        vm.prank(operator);
        perp.configureAsset(address(0xB7C), address(btcFeed), 3600);

        // pauser pauses
        vm.prank(pauser);
        perp.pause();
        assertTrue(perp.paused());

        // operator cannot unpause (wrong role)
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        vm.prank(operator);
        perp.unpause();

        // pauser unpauses
        vm.prank(pauser);
        perp.unpause();
        assertFalse(perp.paused());

        // nobody is blocked everywhere
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, nobody));
        vm.prank(nobody);
        vault.setPerpDex(makeAddr("x"));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, nobody));
        vm.prank(nobody);
        perp.configureAsset(makeAddr("x"), address(btcFeed), 3600);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, nobody));
        vm.prank(nobody);
        perp.pause();
    }
}
