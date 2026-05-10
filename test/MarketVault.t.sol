// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketVault} from "../src/MarketVault.sol";
import {SovereigntyAccessManager} from "../src/SovereigntyAccessManager.sol";
import {MockcNGN} from "./mocks/MockcNGN.sol";
import {MockPerpDEX} from "./mocks/MockPerpDEX.sol";

/// @title MarketVaultTest
/// @notice Unit tests for the MarketVault ERC4626 isolated-pool vault.
/// @dev Uses MockcNGN (6-decimal ERC20) and MockPerpDEX (controllable PnL/collateral)
///      to test vault accounting in isolation from the real PerpDEX oracle logic.
///
///      Coverage:
///        - Basic ERC4626: deposit, withdraw, redeem, multi-depositor
///        - totalAssets with PnL: trader profit (decreases LP assets), trader loss
///          (increases LP assets), floor-at-zero guard
///        - Access control: setPerpDex, settlePnL, payTrader, receiveFromTrader
///        - PnL settlement: positive and negative globalTraderPnL tracking
///        - Metadata: name, symbol, decimals, marketId, asset
///        - Fallback: totalAssets when no PerpDEX is linked
contract MarketVaultTest is Test {
    bytes32 constant MARKET_ID = keccak256("ETH-PERP");

    MockcNGN cNGN;
    SovereigntyAccessManager sam;
    MarketVault vault;
    MockPerpDEX mockPerp;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");

    /// @notice Deploys MockcNGN, SAM (proxied), MarketVault, and MockPerpDEX.
    /// @dev Configuration steps:
    ///      1. Deploy SAM via proxy, grant VAULT_MANAGER_ROLE to `operator`.
    ///      2. Deploy vault with cNGN as underlying asset and ETH-PERP market ID.
    ///      3. Deploy MockPerpDEX and bind setPerpDex selector to VAULT_MANAGER_ROLE.
    ///      4. Link vault → MockPerpDEX as operator.
    ///      5. Mint and approve 1M cNGN for each LP.
    function setUp() public {
        cNGN = new MockcNGN();

        // Deploy SAM
        vm.startPrank(admin);
        SovereigntyAccessManager samImpl = new SovereigntyAccessManager();
        bytes memory initData = abi.encodeCall(SovereigntyAccessManager.initialize, (admin));
        ERC1967Proxy samProxy = new ERC1967Proxy(address(samImpl), initData);
        sam = SovereigntyAccessManager(address(samProxy));
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), operator, 0);
        vm.stopPrank();

        // Deploy vault
        vault = new MarketVault(IERC20(address(cNGN)), address(sam), MARKET_ID, "cNGN Vault Share - ETH", "vcNGN-ETH");

        // Deploy mock PerpDEX
        mockPerp = new MockPerpDEX();

        // Configure SAM for vault
        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MarketVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), selectors, sam.VAULT_MANAGER_ROLE());
        vm.stopPrank();

        // Link PerpDEX
        vm.prank(operator);
        vault.setPerpDex(address(mockPerp));

        // Fund LPs
        cNGN.mint(lp1, 1_000_000e6);
        cNGN.mint(lp2, 1_000_000e6);
        vm.prank(lp1);
        cNGN.approve(address(vault), type(uint256).max);
        vm.prank(lp2);
        cNGN.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                          BASIC ERC4626 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice LP deposits 100k cNGN and receives vault shares.
    function test_deposit() public {
        vm.prank(lp1);
        uint256 shares = vault.deposit(100_000e6, lp1);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(lp1), shares);
        assertEq(cNGN.balanceOf(address(vault)), 100_000e6);
    }

    /// @notice LP withdraws 50k cNGN after depositing 100k — half remains in vault.
    function test_withdraw() public {
        vm.prank(lp1);
        vault.deposit(100_000e6, lp1);

        vm.prank(lp1);
        vault.withdraw(50_000e6, lp1, lp1);

        assertEq(cNGN.balanceOf(address(vault)), 50_000e6);
    }

    /// @notice LP redeems all shares and receives the full deposited amount back.
    function test_redeem() public {
        vm.prank(lp1);
        uint256 shares = vault.deposit(100_000e6, lp1);

        vm.prank(lp1);
        uint256 assets = vault.redeem(shares, lp1, lp1);

        assertEq(assets, 100_000e6);
        assertEq(vault.balanceOf(lp1), 0);
    }

    /// @notice Two LPs deposit sequentially; totalAssets equals summed deposits.
    function test_multiple_depositors() public {
        vm.prank(lp1);
        vault.deposit(100_000e6, lp1);

        vm.prank(lp2);
        vault.deposit(200_000e6, lp2);

        assertEq(vault.totalAssets(), 300_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                      TOTAL ASSETS WITH PNL
    //////////////////////////////////////////////////////////////*/

    /// @notice Trader unrealized profit reduces LP-visible totalAssets.
    /// @dev Formula: totalAssets = balance − collateralHeld − unrealizedPnL.
    ///      500k LP + 100k mock collateral − 100k held − 50k PnL = 450k.
    function test_totalAssets_decreases_with_trader_profit() public {
        vm.prank(lp1);
        vault.deposit(500_000e6, lp1);

        // Simulate trader unrealized profit of 50k
        mockPerp.setCollateralHeld(MARKET_ID, 100_000e6);
        mockPerp.setUnrealizedPnL(MARKET_ID, 50_000e6);

        // totalAssets = balance(600k) - collateral(100k) - unrealizedPnL(50k) = 350k
        // Wait — the vault balance is 500k (LP deposit) and no collateral is actually in the vault
        // from the mock. Let's add some collateral tokens to simulate.
        cNGN.mint(address(vault), 100_000e6); // Simulating collateral deposited by traders

        // balance = 600k, collateral = 100k, unrealized PnL = 50k
        // LP assets = 600k - 100k - 50k = 450k
        assertEq(vault.totalAssets(), 450_000e6);
    }

    /// @notice Trader unrealized loss increases LP-visible totalAssets (vault benefits).
    /// @dev balance=600k, held=100k, PnL=−30k → totalAssets = 600k − 100k − (−30k) = 530k.
    function test_totalAssets_increases_with_trader_loss() public {
        vm.prank(lp1);
        vault.deposit(500_000e6, lp1);

        cNGN.mint(address(vault), 100_000e6);

        // Trader is underwater: unrealized PnL = -30k (vault benefits)
        mockPerp.setCollateralHeld(MARKET_ID, 100_000e6);
        mockPerp.setUnrealizedPnL(MARKET_ID, -30_000e6);

        // LP assets = 600k - 100k - (-30k) = 530k
        assertEq(vault.totalAssets(), 530_000e6);
    }

    /// @notice totalAssets floors at zero when unrealized PnL exceeds vault balance.
    function test_totalAssets_floors_at_zero() public {
        vm.prank(lp1);
        vault.deposit(100_000e6, lp1);

        // Massive unrealized PnL > vault balance
        mockPerp.setCollateralHeld(MARKET_ID, 0);
        mockPerp.setUnrealizedPnL(MARKET_ID, 200_000e6);

        // LP assets would be negative, floor at 0
        assertEq(vault.totalAssets(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice setPerpDex reverts when called by an unauthorized account.
    function test_setPerpDex_unauthorized_reverts() public {
        vm.prank(lp1);
        vm.expectRevert();
        vault.setPerpDex(address(1));
    }

    /// @notice setPerpDex reverts when given address(0).
    function test_setPerpDex_zero_address_reverts() public {
        vm.prank(operator);
        vm.expectRevert(MarketVault.ZeroAddress.selector);
        vault.setPerpDex(address(0));
    }

    /// @notice settlePnL can only be called by the linked PerpDEX.
    function test_settlePnL_onlyPerpDex() public {
        vm.prank(lp1);
        vm.expectRevert(MarketVault.OnlyPerpDex.selector);
        vault.settlePnL(1000);
    }

    /// @notice payTrader can only be called by the linked PerpDEX.
    function test_payTrader_onlyPerpDex() public {
        vm.prank(lp1);
        vm.expectRevert(MarketVault.OnlyPerpDex.selector);
        vault.payTrader(lp1, 1000);
    }

    /// @notice receiveFromTrader can only be called by the linked PerpDEX.
    function test_receiveFromTrader_onlyPerpDex() public {
        vm.prank(lp1);
        vm.expectRevert(MarketVault.OnlyPerpDex.selector);
        vault.receiveFromTrader(lp1, 1000);
    }

    /*//////////////////////////////////////////////////////////////
                      PNL SETTLEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Positive PnL settlement increases globalTraderPnL.
    function test_settlePnL_positive() public {
        vm.prank(address(mockPerp));
        vault.settlePnL(50_000);

        assertEq(vault.globalTraderPnL(), 50_000);
    }

    /// @notice Negative PnL settlement decreases globalTraderPnL.
    function test_settlePnL_negative() public {
        vm.prank(address(mockPerp));
        vault.settlePnL(-30_000);

        assertEq(vault.globalTraderPnL(), -30_000);
    }

    /// @notice payTrader transfers cNGN from the vault to a trader address.
    function test_payTrader() public {
        vm.prank(lp1);
        vault.deposit(100_000e6, lp1);

        vm.prank(address(mockPerp));
        vault.payTrader(lp2, 10_000e6);

        assertEq(cNGN.balanceOf(lp2), 1_010_000e6); // original 1M + 10k
    }

    /*//////////////////////////////////////////////////////////////
                          METADATA TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Vault metadata (name, symbol, decimals, marketId) matches constructor args.
    function test_vault_metadata() public view {
        assertEq(vault.name(), "cNGN Vault Share - ETH");
        assertEq(vault.symbol(), "vcNGN-ETH");
        assertEq(vault.decimals(), 6); // same as underlying
        assertEq(vault.marketId(), MARKET_ID);
    }

    /// @notice Vault underlying asset is the cNGN mock token.
    function test_vault_asset() public view {
        assertEq(vault.asset(), address(cNGN));
    }

    /*//////////////////////////////////////////////////////////////
                     FALLBACK TOTAL ASSETS (NO PERPDEX)
    //////////////////////////////////////////////////////////////*/

    /// @notice Without a linked PerpDEX, totalAssets falls back to raw cNGN balance.
    function test_totalAssets_fallback_no_perpdex() public {
        // Deploy a fresh vault with no PerpDEX linked
        MarketVault freshVault = new MarketVault(IERC20(address(cNGN)), address(sam), MARKET_ID, "Fresh", "FRESH");

        cNGN.mint(address(freshVault), 100_000e6);
        assertEq(freshVault.totalAssets(), 100_000e6);
    }
}
