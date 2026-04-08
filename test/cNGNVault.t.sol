// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {cNGNVault} from "../src/cNGNVault.sol";
import {SovereigntyAccessManager} from "../src/SovereigntyAccessManager.sol";
import {MockcNGN} from "./mocks/MockcNGN.sol";
import {MockPerpDEX} from "./mocks/MockPerpDEX.sol";

contract cNGNVaultTest is Test {
    MockcNGN public token;
    cNGNVault public vault;
    MockPerpDEX public perpDexMock;
    SovereigntyAccessManager public sam;

    address owner = makeAddr("owner");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address perpDex;
    address trader = makeAddr("trader");

    uint256 constant ONE_TOKEN = 1e6; // 6 decimals

    function setUp() public {
        // Deploy SAM proxy
        SovereigntyAccessManager samImpl = new SovereigntyAccessManager();
        ERC1967Proxy samProxy =
            new ERC1967Proxy(address(samImpl), abi.encodeCall(SovereigntyAccessManager.initialize, (owner)));
        sam = SovereigntyAccessManager(address(samProxy));

        token = new MockcNGN();
        vault = new cNGNVault(IERC20(address(token)), address(sam));
        perpDexMock = new MockPerpDEX();
        perpDex = address(perpDexMock);

        // Configure SAM: map setPerpDex to VAULT_MANAGER_ROLE and grant to owner
        vm.startPrank(owner);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = cNGNVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), selectors, sam.VAULT_MANAGER_ROLE());
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), owner, 0);
        vm.stopPrank();

        // Fund LPs
        token.mint(lp1, 1_000_000 * ONE_TOKEN);
        token.mint(lp2, 1_000_000 * ONE_TOKEN);

        // Approve vault
        vm.prank(lp1);
        token.approve(address(vault), type(uint256).max);
        vm.prank(lp2);
        token.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_asset() public view {
        assertEq(vault.asset(), address(token));
    }

    function test_constructor_name() public view {
        assertEq(vault.name(), "cNGN Vault Share");
    }

    function test_constructor_symbol() public view {
        assertEq(vault.symbol(), "vcNGN");
    }

    function test_constructor_perpDexIsZero() public view {
        assertEq(vault.perpDex(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                       SET PERPDEX TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setPerpDex_success() public {
        vm.prank(owner);
        vault.setPerpDex(perpDex);
        assertEq(vault.perpDex(), perpDex);
    }

    function test_setPerpDex_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit cNGNVault.PerpDexSet(perpDex);
        vm.prank(owner);
        vault.setPerpDex(perpDex);
    }

    function test_setPerpDex_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(cNGNVault.ZeroAddress.selector);
        vault.setPerpDex(address(0));
    }

    function test_setPerpDex_revertsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, lp1));
        vm.prank(lp1);
        vault.setPerpDex(perpDex);
    }

    /*//////////////////////////////////////////////////////////////
                    ERC4626 DEPOSIT / WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_deposit_basic() public {
        uint256 depositAmount = 100_000 * ONE_TOKEN;

        vm.prank(lp1);
        uint256 shares = vault.deposit(depositAmount, lp1);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(lp1), shares);
        assertEq(token.balanceOf(address(vault)), depositAmount);
    }

    function test_deposit_multipleUsers() public {
        uint256 amount = 50_000 * ONE_TOKEN;

        vm.prank(lp1);
        vault.deposit(amount, lp1);

        vm.prank(lp2);
        vault.deposit(amount, lp2);

        assertEq(token.balanceOf(address(vault)), 2 * amount);
        assertEq(vault.totalAssets(), 2 * amount);
    }

    function test_withdraw_basic() public {
        uint256 amount = 100_000 * ONE_TOKEN;

        vm.prank(lp1);
        vault.deposit(amount, lp1);

        vm.prank(lp1);
        vault.withdraw(amount, lp1, lp1);

        assertEq(vault.balanceOf(lp1), 0);
        assertEq(token.balanceOf(lp1), 1_000_000 * ONE_TOKEN);
    }

    function test_redeem_basic() public {
        uint256 amount = 100_000 * ONE_TOKEN;

        vm.prank(lp1);
        uint256 shares = vault.deposit(amount, lp1);

        vm.prank(lp1);
        uint256 assets = vault.redeem(shares, lp1, lp1);

        assertEq(assets, amount);
        assertEq(vault.balanceOf(lp1), 0);
    }

    /*//////////////////////////////////////////////////////////////
                  TOTAL ASSETS WITH GLOBAL PNL
    //////////////////////////////////////////////////////////////*/

    function test_totalAssets_noTraderPnL() public {
        uint256 amount = 100_000 * ONE_TOKEN;
        vm.prank(lp1);
        vault.deposit(amount, lp1);

        assertEq(vault.totalAssets(), amount);
    }

    function test_totalAssets_traderProfit_reducesAssets() public {
        uint256 amount = 100_000 * ONE_TOKEN;
        vm.prank(lp1);
        vault.deposit(amount, lp1);

        vm.prank(owner);
        vault.setPerpDex(perpDex);
        perpDexMock.setGlobalUnrealizedPnL(int256(10_000 * ONE_TOKEN));

        // totalAssets = balance(100k) - collateral(0) - unrealizedPnL(10k) = 90k
        assertEq(vault.totalAssets(), 90_000 * ONE_TOKEN);
    }

    function test_totalAssets_traderLoss_increasesAssets() public {
        uint256 amount = 100_000 * ONE_TOKEN;
        vm.prank(lp1);
        vault.deposit(amount, lp1);

        vm.prank(owner);
        vault.setPerpDex(perpDex);

        // Simulate: traders have 5k unrealized loss
        perpDexMock.setGlobalUnrealizedPnL(-int256(5_000 * ONE_TOKEN));

        // totalAssets = balance(100k) - collateral(0) - (-5k) = 105k
        assertEq(vault.totalAssets(), amount + 5_000 * ONE_TOKEN);
    }

    function test_totalAssets_traderProfit_smallAmount() public {
        uint256 amount = 100_000 * ONE_TOKEN;
        vm.prank(lp1);
        vault.deposit(amount, lp1);

        vm.prank(owner);
        vault.setPerpDex(perpDex);

        // Simulate: traders have small 1k unrealized profit
        perpDexMock.setGlobalUnrealizedPnL(int256(1_000 * ONE_TOKEN));

        // totalAssets = 100k - 1k = 99k
        assertEq(vault.totalAssets(), 99_000 * ONE_TOKEN);
    }

    function test_totalAssets_clampedToZero() public {
        uint256 amount = 10 * ONE_TOKEN;
        vm.prank(lp1);
        vault.deposit(amount, lp1);

        vm.prank(owner);
        vault.setPerpDex(perpDex);

        // Unrealized profit exceeds vault balance
        perpDexMock.setGlobalUnrealizedPnL(int256(100 * ONE_TOKEN));

        assertEq(vault.totalAssets(), 0);
    }

    function test_totalAssets_withCollateralAndPnL() public {
        uint256 amount = 100_000 * ONE_TOKEN;
        vm.prank(lp1);
        vault.deposit(amount, lp1);

        vm.prank(owner);
        vault.setPerpDex(perpDex);

        // Simulate: 50k collateral in vault and 10k unrealized profit
        uint256 collateral = 50_000 * ONE_TOKEN;
        token.mint(address(vault), collateral); // simulate collateral transfer
        perpDexMock.setTotalCollateralHeld(collateral);
        perpDexMock.setGlobalUnrealizedPnL(int256(10_000 * ONE_TOKEN));

        // balance=150k, collateral=50k, unrealized=10k → LP assets = 90k
        assertEq(vault.totalAssets(), 90_000 * ONE_TOKEN);
    }

    /*//////////////////////////////////////////////////////////////
                       SETTLE PNL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_settlePnL_onlyPerpDex() public {
        vm.prank(owner);
        vault.setPerpDex(perpDex);

        vm.expectRevert(cNGNVault.OnlyPerpDex.selector);
        vm.prank(lp1);
        vault.settlePnL(int256(100));
    }

    function test_settlePnL_accumulates() public {
        vm.prank(owner);
        vault.setPerpDex(perpDex);

        vm.prank(perpDex);
        vault.settlePnL(int256(100));
        assertEq(vault.globalTraderPnL(), 100);

        vm.prank(perpDex);
        vault.settlePnL(-int256(50));
        assertEq(vault.globalTraderPnL(), 50);

        vm.prank(perpDex);
        vault.settlePnL(-int256(200));
        assertEq(vault.globalTraderPnL(), -150);
    }

    function test_settlePnL_emitsEvent() public {
        vm.prank(owner);
        vault.setPerpDex(perpDex);

        vm.expectEmit(false, false, false, true);
        emit cNGNVault.PnLSettled(int256(42), int256(42));

        vm.prank(perpDex);
        vault.settlePnL(int256(42));
    }

    /*//////////////////////////////////////////////////////////////
                     PAY TRADER / RECEIVE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_payTrader_onlyPerpDex() public {
        vm.prank(owner);
        vault.setPerpDex(perpDex);

        vm.expectRevert(cNGNVault.OnlyPerpDex.selector);
        vm.prank(lp1);
        vault.payTrader(trader, 100);
    }

    function test_payTrader_transfersTokens() public {
        uint256 amount = 100_000 * ONE_TOKEN;
        vm.prank(lp1);
        vault.deposit(amount, lp1);

        vm.prank(owner);
        vault.setPerpDex(perpDex);

        uint256 payout = 1_000 * ONE_TOKEN;
        vm.prank(perpDex);
        vault.payTrader(trader, payout);

        assertEq(token.balanceOf(trader), payout);
        assertEq(token.balanceOf(address(vault)), amount - payout);
    }

    function test_receiveFromTrader_onlyPerpDex() public {
        vm.prank(owner);
        vault.setPerpDex(perpDex);

        vm.expectRevert(cNGNVault.OnlyPerpDex.selector);
        vm.prank(lp1);
        vault.receiveFromTrader(trader, 100);
    }

    function test_receiveFromTrader_pullsTokens() public {
        token.mint(trader, 10_000 * ONE_TOKEN);
        vm.prank(trader);
        token.approve(address(vault), type(uint256).max);

        vm.prank(owner);
        vault.setPerpDex(perpDex);

        uint256 amount = 5_000 * ONE_TOKEN;
        vm.prank(perpDex);
        vault.receiveFromTrader(trader, amount);

        assertEq(token.balanceOf(address(vault)), amount);
        assertEq(token.balanceOf(trader), 5_000 * ONE_TOKEN);
    }

    /*//////////////////////////////////////////////////////////////
                   SHARE PRICE REFLECTS PNL
    //////////////////////////////////////////////////////////////*/

    function test_sharePrice_decreasesOnTraderProfit() public {
        vm.prank(owner);
        vault.setPerpDex(perpDex);

        uint256 amount = 100_000 * ONE_TOKEN;
        vm.prank(lp1);
        vault.deposit(amount, lp1);

        uint256 sharesBefore = vault.balanceOf(lp1);
        uint256 previewBefore = vault.previewRedeem(sharesBefore);

        // Simulate trader unrealized profit
        perpDexMock.setGlobalUnrealizedPnL(int256(10_000 * ONE_TOKEN));

        uint256 previewAfter = vault.previewRedeem(sharesBefore);
        assertLt(previewAfter, previewBefore);
    }

    function test_sharePrice_increasesOnTraderLoss() public {
        vm.prank(owner);
        vault.setPerpDex(perpDex);

        uint256 amount = 100_000 * ONE_TOKEN;
        vm.prank(lp1);
        vault.deposit(amount, lp1);

        uint256 sharesBefore = vault.balanceOf(lp1);
        uint256 previewBefore = vault.previewRedeem(sharesBefore);

        // Simulate trader unrealized loss
        perpDexMock.setGlobalUnrealizedPnL(-int256(10_000 * ONE_TOKEN));

        uint256 previewAfter = vault.previewRedeem(sharesBefore);
        assertGt(previewAfter, previewBefore);
    }

    /*//////////////////////////////////////////////////////////////
                   SAM INTEGRATION: DYNAMIC ROLE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_authority_isSAM() public view {
        assertEq(vault.authority(), address(sam));
    }

    function test_setPerpDex_newRoleHolder() public {
        // Grant VAULT_MANAGER_ROLE to lp1
        vm.startPrank(owner);
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), lp1, 0);
        vm.stopPrank();

        // lp1 can now call setPerpDex
        vm.prank(lp1);
        vault.setPerpDex(perpDex);
        assertEq(vault.perpDex(), perpDex);
    }

    function test_setPerpDex_revokedRoleHolder() public {
        // Revoke VAULT_MANAGER_ROLE from owner
        vm.startPrank(owner);
        sam.revokeRole(sam.VAULT_MANAGER_ROLE(), owner);
        vm.stopPrank();

        // Owner can no longer call setPerpDex
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        vm.prank(owner);
        vault.setPerpDex(perpDex);
    }

    function test_setPerpDex_roleReassignment() public {
        // Revoke from owner, grant to lp1
        vm.startPrank(owner);
        sam.revokeRole(sam.VAULT_MANAGER_ROLE(), owner);
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), lp1, 0);
        vm.stopPrank();

        // Owner blocked
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        vm.prank(owner);
        vault.setPerpDex(perpDex);

        // lp1 succeeds
        vm.prank(lp1);
        vault.setPerpDex(perpDex);
        assertEq(vault.perpDex(), perpDex);
    }

    function test_setPerpDex_roleRemapped() public {
        // Remap setPerpDex from VAULT_MANAGER_ROLE to OPERATOR_ROLE
        vm.startPrank(owner);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = cNGNVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), selectors, sam.OPERATOR_ROLE());
        sam.grantRole(sam.OPERATOR_ROLE(), lp2, 0);
        vm.stopPrank();

        // Owner (only has VAULT_MANAGER_ROLE) now blocked
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        vm.prank(owner);
        vault.setPerpDex(perpDex);

        // lp2 (has OPERATOR_ROLE) succeeds
        vm.prank(lp2);
        vault.setPerpDex(perpDex);
        assertEq(vault.perpDex(), perpDex);
    }
}
