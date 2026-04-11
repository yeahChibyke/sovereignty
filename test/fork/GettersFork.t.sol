// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Test.sol";
import {BaseForkSetup} from "./BaseForkSetup.sol";
import {PerpDEX} from "../../src/PerpDEX.sol";

/// @title GettersForkTest
/// @notice Fork tests validating all price-getter and market-info functions
///         on Base mainnet with live Pyth + Chainlink data.
///         Ensures traders and LPs can query per-asset prices in NGN and
///         comprehensive market details for liquidity decisions.
/// @dev All prices come from live Pyth feeds (fetched via Hermes FFI) and the live
///      Chainlink NGN/USD feed. Tests verify sensible price ranges, relative ordering,
///      triangulation consistency, and that `getMarketInfo()` returns coherent snapshots.
///
///      Test sections:
///        1. Per-asset mark price queries in cNGN (ETH, BTC, SOL, relative ordering)
///        2. Asset/USD price queries (per-asset, sensible ranges)
///        3. USD/NGN rate from Chainlink (sensible range)
///        4. getMarketInfo() comprehensive getter (empty market, with positions, compare markets,
///           non-existent revert, disabled market)
///        5. Per-asset unrealized PnL (isolated per market)
///        6. Mark price consistency across getters (getMarkPrice vs getMarketInfo, triangulation)
contract GettersForkTest is BaseForkSetup {
    /*//////////////////////////////////////////////////////////////
          1. PER-ASSET MARK PRICE QUERIES (cNGN DENOMINATED)
    //////////////////////////////////////////////////////////////*/

    /// @notice Any user can query the live ETH price in cNGN.
    function test_getMarkPrice_eth_livePrice() public {
        _refreshEthPrices();

        uint256 ethNgn = perp.getMarkPrice(ETH_MARKET);
        assertGt(ethNgn, 0, "ETH/cNGN should be > 0");

        // ETH is ~$2000-$10000, NGN is ~1000-2000 per USD => ~2M-20M range
        assertGt(ethNgn, 2_000_000e18, "ETH/cNGN too low");
        assertLt(ethNgn, 20_000_000e18, "ETH/cNGN too high");

        console.log("ETH/cNGN mark price:", ethNgn);
    }

    /// @notice Any user can query the live BTC price in cNGN.
    function test_getMarkPrice_btc_livePrice() public {
        _refreshBtcPrices();

        uint256 btcNgn = perp.getMarkPrice(BTC_MARKET);
        assertGt(btcNgn, 0, "BTC/cNGN should be > 0");

        // BTC ~$30k-$200k, NGN ~1000-2000 => ~30M-400M range
        assertGt(btcNgn, 30_000_000e18, "BTC/cNGN too low");
        assertLt(btcNgn, 400_000_000e18, "BTC/cNGN too high");

        console.log("BTC/cNGN mark price:", btcNgn);
    }

    /// @notice Any user can query the live SOL price in cNGN.
    function test_getMarkPrice_sol_livePrice() public {
        _refreshSolPrices();

        uint256 solNgn = perp.getMarkPrice(SOL_MARKET);
        assertGt(solNgn, 0, "SOL/cNGN should be > 0");

        // SOL ~$10-$500, NGN ~1000-2000 => ~10k-1M range
        assertGt(solNgn, 10_000e18, "SOL/cNGN too low");
        assertLt(solNgn, 1_000_000e18, "SOL/cNGN too high");

        console.log("SOL/cNGN mark price:", solNgn);
    }

    /// @notice Query all asset prices in cNGN in one test, verifying relative ordering.
    function test_getMarkPrice_allAssets_relativeOrdering() public {
        _refreshCryptoPrices();

        uint256 ethNgn = perp.getMarkPrice(ETH_MARKET);
        uint256 btcNgn = perp.getMarkPrice(BTC_MARKET);
        uint256 solNgn = perp.getMarkPrice(SOL_MARKET);

        // BTC > ETH > SOL in cNGN terms
        assertGt(btcNgn, ethNgn, "BTC should be priced higher than ETH in cNGN");
        assertGt(ethNgn, solNgn, "ETH should be priced higher than SOL in cNGN");

        console.log("ETH/cNGN:", ethNgn);
        console.log("BTC/cNGN:", btcNgn);
        console.log("SOL/cNGN:", solNgn);
    }

    /*//////////////////////////////////////////////////////////////
          2. ASSET/USD PRICE QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Query per-asset USD prices individually.
    function test_getAssetUsdPrice_perAsset() public {
        _refreshCryptoPrices();

        uint256 ethUsd = perp.getAssetUsdPrice(ETH_MARKET);
        uint256 btcUsd = perp.getAssetUsdPrice(BTC_MARKET);
        uint256 solUsd = perp.getAssetUsdPrice(SOL_MARKET);

        assertGt(ethUsd, 500e18, "ETH/USD too low");
        assertLt(ethUsd, 20_000e18, "ETH/USD too high");

        assertGt(btcUsd, 10_000e18, "BTC/USD too low");
        assertLt(btcUsd, 500_000e18, "BTC/USD too high");

        assertGt(solUsd, 1e18, "SOL/USD too low");
        assertLt(solUsd, 2_000e18, "SOL/USD too high");

        console.log("ETH/USD:", ethUsd);
        console.log("BTC/USD:", btcUsd);
        console.log("SOL/USD:", solUsd);
    }

    /*//////////////////////////////////////////////////////////////
          3. USD/NGN RATE (CHAINLINK)
    //////////////////////////////////////////////////////////////*/

    /// @notice USD/NGN rate from Chainlink is queryable and sensible.
    function test_getUsdNgnRate_liveChainlink() public view {
        uint256 rate = perp.getUsdNgnRate();
        assertGt(rate, 1000e18, "USD/NGN too low");
        assertLt(rate, 2000e18, "USD/NGN too high");
        console.log("USD/NGN (Chainlink):", rate);
    }

    /*//////////////////////////////////////////////////////////////
          4. getMarketInfo() — COMPREHENSIVE LP GETTER
    //////////////////////////////////////////////////////////////*/

    /// @notice LP queries full market info for ETH-PERP before any trading.
    function test_getMarketInfo_emptyMarket() public {
        _refreshEthPrices();

        PerpDEX.MarketInfo memory info = perp.getMarketInfo(ETH_MARKET);

        // Config
        assertEq(info.marketId, ETH_MARKET);
        assertTrue(info.enabled);
        assertEq(info.maxLeverage, CRYPTO_MAX_LEVERAGE);
        assertEq(info.maintenanceMarginRatio, MAINTENANCE_MARGIN);
        assertEq(info.vault, address(ethVault));

        // Pricing — live from oracles
        assertGt(info.markPriceCngn, 0, "Mark price should be > 0");
        assertGt(info.assetUsdPrice, 0, "Asset/USD should be > 0");
        assertGt(info.usdNgnRate, 0, "USD/NGN should be > 0");

        // No positions
        assertEq(info.longOI, 0);
        assertEq(info.shortOI, 0);
        assertEq(info.openTraderCount, 0);
        assertEq(info.unrealizedPnL, 0);
        assertEq(info.collateralHeld, 0);

        // Vault has LP liquidity
        assertGt(info.vaultTVL, 0, "Vault should have LP deposits");

        console.log("=== ETH-PERP Market Info (empty) ===");
        console.log("Mark price (cNGN):", info.markPriceCngn);
        console.log("Asset/USD:", info.assetUsdPrice);
        console.log("USD/NGN:", info.usdNgnRate);
        console.log("Vault TVL:", info.vaultTVL);
        console.log("Max leverage:", info.maxLeverage);
    }

    /// @notice LP queries market info after traders have opened positions.
    function test_getMarketInfo_withOpenPositions() public {
        _refreshEthPrices();

        // Trader opens a long
        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);

        PerpDEX.MarketInfo memory info = perp.getMarketInfo(ETH_MARKET);

        // Should reflect the open position
        assertGt(info.longOI, 0, "Long OI should be > 0");
        assertEq(info.shortOI, 0, "Short OI should be 0");
        assertEq(info.openTraderCount, 1, "Should have 1 open trader");
        assertEq(info.collateralHeld, 100_000e6, "Collateral held should match");

        // Mark price should still be live
        assertGt(info.markPriceCngn, 0);

        console.log("=== ETH-PERP Market Info (1 long) ===");
        console.log("Long OI:", info.longOI);
        console.log("Short OI:", info.shortOI);
        console.log("Traders:", info.openTraderCount);
        console.log("Collateral held:", info.collateralHeld);
        console.log("Unrealized PnL:", info.unrealizedPnL);
        console.log("Vault TVL:", info.vaultTVL);
    }

    /// @notice LP compares market info across ETH vs BTC to decide where to provide liquidity.
    function test_getMarketInfo_compareMarkets() public {
        _refreshCryptoPrices();

        // Open positions in ETH only
        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);
        _commitAndExecute(trader2, ETH_MARKET, PerpDEX.Side.Short, 50_000e6, 2);

        PerpDEX.MarketInfo memory ethInfo = perp.getMarketInfo(ETH_MARKET);
        PerpDEX.MarketInfo memory btcInfo = perp.getMarketInfo(BTC_MARKET);

        // ETH should have activity, BTC should not
        assertGt(ethInfo.openTraderCount, 0, "ETH should have traders");
        assertEq(btcInfo.openTraderCount, 0, "BTC should have no traders");

        assertGt(ethInfo.longOI, 0);
        assertGt(ethInfo.shortOI, 0);
        assertEq(btcInfo.longOI, 0);
        assertEq(btcInfo.shortOI, 0);

        // Both should have vault TVL (LP seeded in setUp)
        assertGt(ethInfo.vaultTVL, 0);
        assertGt(btcInfo.vaultTVL, 0);

        console.log("=== Market Comparison ===");
        console.log("ETH traders:", ethInfo.openTraderCount, "BTC traders:", btcInfo.openTraderCount);
        console.log("ETH long OI:", ethInfo.longOI);
        console.log("ETH short OI:", ethInfo.shortOI);
        console.log("ETH TVL:", ethInfo.vaultTVL, "BTC TVL:", btcInfo.vaultTVL);
    }

    /// @notice getMarketInfo reverts for non-existent market.
    function test_getMarketInfo_nonExistent_reverts() public {
        vm.expectRevert(PerpDEX.MarketNotEnabled.selector);
        perp.getMarketInfo(keccak256("FAKE-PERP"));
    }

    /// @notice getMarketInfo on disabled market still works (for closing/info purposes).
    function test_getMarketInfo_disabledMarket() public {
        _refreshEthPrices();

        // Open a position first, then disable
        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 2);

        vm.prank(operator);
        perp.disableMarket(ETH_MARKET);

        PerpDEX.MarketInfo memory info = perp.getMarketInfo(ETH_MARKET);
        assertFalse(info.enabled, "Should show market as disabled");
        assertGt(info.openTraderCount, 0, "Should still show open traders");
        assertGt(info.markPriceCngn, 0, "Price should still be readable");
    }

    /*//////////////////////////////////////////////////////////////
         5. PER-ASSET UNREALIZED PNL
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone can query the aggregate unrealized PnL for a specific market.
    function test_getMarketUnrealizedPnL_perAsset() public {
        _refreshCryptoPrices();

        // No positions — PnL should be 0
        int256 ethPnl = perp.getMarketUnrealizedPnL(ETH_MARKET);
        int256 btcPnl = perp.getMarketUnrealizedPnL(BTC_MARKET);
        assertEq(ethPnl, 0);
        assertEq(btcPnl, 0);

        // Open ETH long
        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);

        // Refresh to get new prices (price may have moved slightly)
        _refreshEthPrices();

        int256 ethPnlAfter = perp.getMarketUnrealizedPnL(ETH_MARKET);
        // PnL can be slightly positive or negative depending on price movement during test
        console.log("ETH unrealized PnL (6 dec):");
        if (ethPnlAfter >= 0) {
            console.log("  positive:", uint256(ethPnlAfter));
        } else {
            console.log("  negative:", uint256(-ethPnlAfter));
        }

        // BTC should still be 0 (no positions)
        int256 btcPnlAfter = perp.getMarketUnrealizedPnL(BTC_MARKET);
        assertEq(btcPnlAfter, 0, "BTC PnL should remain 0");
    }

    /*//////////////////////////////////////////////////////////////
         6. MARK PRICE CONSISTENCY ACROSS GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify getMarkPrice and getMarketInfo return the same price.
    function test_markPrice_consistentWithMarketInfo() public {
        _refreshEthPrices();

        uint256 markPrice = perp.getMarkPrice(ETH_MARKET);
        PerpDEX.MarketInfo memory info = perp.getMarketInfo(ETH_MARKET);

        assertEq(markPrice, info.markPriceCngn, "getMarkPrice and getMarketInfo should agree");
    }

    /// @notice Verify triangulation holds: markPriceCngn == assetUsd * usdNgn / 1e18.
    function test_marketInfo_triangulationConsistency() public {
        _refreshEthPrices();

        PerpDEX.MarketInfo memory info = perp.getMarketInfo(ETH_MARKET);

        uint256 expected = (info.assetUsdPrice * info.usdNgnRate) / PRECISION;
        assertEq(info.markPriceCngn, expected, "Triangulation mismatch in getMarketInfo");
    }
}
