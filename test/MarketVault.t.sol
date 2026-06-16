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
///        - Access control: setPerpDex, settlePnL, payTrader
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
        vault =
            new MarketVault(IERC20(address(cNGN)), address(sam), MARKET_ID, "cNGN Vault Share - ETH", "vcNGN-ETH", 0);

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
    /// @dev Uses the request→claim flow (cooldown 0 in this vault → claim immediately).
    function test_withdraw() public {
        vm.prank(lp1);
        vault.deposit(100_000e6, lp1);

        uint256 shares = vault.previewWithdraw(50_000e6);
        vm.prank(lp1);
        vault.requestRedeem(shares);
        vm.prank(lp1);
        vault.claimRedeem();

        assertEq(cNGN.balanceOf(address(vault)), 50_000e6);
    }

    /// @notice LP redeems all shares and receives the full deposited amount back.
    function test_redeem() public {
        vm.prank(lp1);
        uint256 shares = vault.deposit(100_000e6, lp1);

        vm.prank(lp1);
        vault.requestRedeem(shares);
        vm.prank(lp1);
        uint256 assets = vault.claimRedeem();

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

    /// @notice Deposit/mint revert while the vault is insolvent (NAV clamped to 0, shares
    ///         outstanding) — prevents value-free share minting. (Fix #1a.)
    function test_deposit_blocked_when_insolvent() public {
        vm.prank(lp1);
        vault.deposit(100_000e6, lp1);

        // Push LP NAV ≤ 0 → totalAssets clamps to 0 with totalSupply > 0.
        mockPerp.setCollateralHeld(MARKET_ID, 0);
        mockPerp.setUnrealizedPnL(MARKET_ID, 200_000e6);
        assertEq(vault.totalAssets(), 0);

        vm.prank(lp2);
        vm.expectRevert(MarketVault.VaultInsolvent.selector);
        vault.deposit(1, lp2);

        vm.prank(lp2);
        vm.expectRevert(MarketVault.VaultInsolvent.selector);
        vault.mint(1_000_000e6, lp2);

        // Once NAV recovers (traders no longer winning), deposits resume.
        mockPerp.setUnrealizedPnL(MARKET_ID, 0);
        vm.prank(lp2);
        uint256 shares = vault.deposit(50_000e6, lp2);
        assertGt(shares, 0);
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
        MarketVault freshVault = new MarketVault(IERC20(address(cNGN)), address(sam), MARKET_ID, "Fresh", "FRESH", 0);

        cNGN.mint(address(freshVault), 100_000e6);
        assertEq(freshVault.totalAssets(), 100_000e6);
    }

    /*//////////////////////////////////////////////////////////////
              STALE-ORACLE LP LIVENESS (FINDING 04)
    //////////////////////////////////////////////////////////////*/

    /// @notice When the live oracle reverts, totalAssets falls back to the cached-price variant.
    function test_totalAssets_usesFallback_when_oracle_stale() public {
        vm.prank(lp1);
        vault.deposit(500_000e6, lp1);
        cNGN.mint(address(vault), 100_000e6);
        mockPerp.setCollateralHeld(MARKET_ID, 100_000e6);
        mockPerp.setUnrealizedPnL(MARKET_ID, 50_000e6);

        uint256 fresh = vault.totalAssets(); // 600k − 100k − 50k = 450k
        assertEq(fresh, 450_000e6);

        // Live read now reverts; totalAssets must fall back (same mock value) instead of reverting.
        mockPerp.setOracleStale(true);
        assertEq(vault.totalAssets(), 450_000e6);
    }

    /// @notice Deposits are blocked while the oracle is stale (no entry at a stale share price).
    function test_deposit_blocked_when_oracle_stale() public {
        vm.prank(lp1);
        vault.deposit(100_000e6, lp1);

        mockPerp.setCollateralHeld(MARKET_ID, 50_000e6);
        mockPerp.setUnrealizedPnL(MARKET_ID, 10_000e6);
        mockPerp.setOracleStale(true);

        vm.prank(lp1);
        vm.expectRevert(MockPerpDEX.MockOracleStale.selector);
        vault.deposit(10_000e6, lp1);
    }

    /// @notice Withdrawals are blocked while the oracle is stale and the market has open interest,
    ///         so an LP cannot exit at a stale (favorable) share price. (Finding 2 fix.)
    function test_withdraw_blocked_when_oracle_stale() public {
        vm.prank(lp1);
        vault.deposit(100_000e6, lp1);

        uint256 shares = vault.previewWithdraw(50_000e6);
        vm.prank(lp1);
        vault.requestRedeem(shares);

        // Simulate open interest + stale live oracle at claim time.
        mockPerp.setUnrealizedPnL(MARKET_ID, 10_000e6);
        mockPerp.setOracleStale(true);

        vm.prank(lp1);
        vm.expectRevert(MockPerpDEX.MockOracleStale.selector);
        vault.claimRedeem();
    }

    /// @notice Claims succeed when the live oracle is fresh.
    function test_withdraw_allowed_when_oracle_fresh() public {
        vm.prank(lp1);
        vault.deposit(100_000e6, lp1);

        uint256 shares = vault.previewWithdraw(50_000e6);
        vm.prank(lp1);
        vault.requestRedeem(shares);

        // oracleStale defaults to false → _requireFreshPricing passes.
        vm.prank(lp1);
        vault.claimRedeem();
        assertEq(cNGN.balanceOf(address(vault)), 50_000e6);
    }

    /*//////////////////////////////////////////////////////////////
              WITHDRAWAL COOLDOWN (REQUEST → CLAIM)
    //////////////////////////////////////////////////////////////*/

    /// @dev A vault with a real cooldown, no PerpDEX linked (claim has no oracle dependency).
    function _cooldownVault(uint256 cooldown) internal returns (MarketVault v) {
        v = new MarketVault(IERC20(address(cNGN)), address(sam), MARKET_ID, "CD", "CD", cooldown);
        vm.prank(lp1);
        cNGN.approve(address(v), type(uint256).max);
    }

    /// @notice Instant ERC4626 withdraw/redeem are disabled — must use the request flow.
    function test_instantWithdrawRedeem_disabled() public {
        vm.prank(lp1);
        vault.deposit(100_000e6, lp1);

        vm.prank(lp1);
        vm.expectRevert(MarketVault.UseRequestRedeem.selector);
        vault.withdraw(1, lp1, lp1);

        vm.prank(lp1);
        vm.expectRevert(MarketVault.UseRequestRedeem.selector);
        vault.redeem(1, lp1, lp1);
    }

    /// @notice claimRedeem reverts before the cooldown elapses, succeeds after.
    function test_claimRedeem_respects_cooldown() public {
        MarketVault v = _cooldownVault(1 days);
        vm.prank(lp1);
        uint256 shares = v.deposit(100_000e6, lp1);

        vm.prank(lp1);
        v.requestRedeem(shares);

        // Too early.
        vm.prank(lp1);
        vm.expectRevert(MarketVault.CooldownNotElapsed.selector);
        v.claimRedeem();

        // After cooldown → succeeds.
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(lp1);
        uint256 assets = v.claimRedeem();
        assertEq(assets, 100_000e6);
        assertEq(v.balanceOf(lp1), 0);
        assertEq(v.totalPendingWithdrawalShares(), 0);
    }

    /// @notice cancelRedeem returns the escrowed shares and clears the request.
    function test_cancelRedeem_returns_shares() public {
        MarketVault v = _cooldownVault(1 days);
        vm.prank(lp1);
        uint256 shares = v.deposit(100_000e6, lp1);

        vm.prank(lp1);
        v.requestRedeem(shares);
        assertEq(v.balanceOf(lp1), 0, "shares escrowed");
        assertEq(v.totalPendingWithdrawalShares(), shares);

        vm.prank(lp1);
        v.cancelRedeem();
        assertEq(v.balanceOf(lp1), shares, "shares returned");
        assertEq(v.totalPendingWithdrawalShares(), 0);
    }

    /// @notice A second request while one is pending reverts.
    function test_requestRedeem_onePending() public {
        MarketVault v = _cooldownVault(1 days);
        vm.prank(lp1);
        uint256 shares = v.deposit(100_000e6, lp1);

        vm.prank(lp1);
        v.requestRedeem(shares / 2);
        vm.prank(lp1);
        vm.expectRevert(MarketVault.WithdrawalAlreadyPending.selector);
        v.requestRedeem(shares / 2);
    }
}
