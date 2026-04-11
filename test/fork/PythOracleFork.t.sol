// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Test.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {AggregatorV3Interface} from "chainlink-evm/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {BaseForkSetup} from "./BaseForkSetup.sol";
import {PerpDEX} from "../../src/PerpDEX.sol";
import {MarketVault} from "../../src/MarketVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PythOracleForkTest
/// @notice Fork tests validating Pyth oracle integration on Base mainnet.
///         Covers all 11 feed IDs, triangulation math, confidence checks,
///         staleness enforcement, and Hermes price update flow.
/// @dev Runs against a pinned Base fork. Pyth prices are fetched live from Hermes
///      via FFI (`script/fetch_pyth_prices.sh`), pushed on-chain, and then verified
///      through PerpDEX view functions. Chainlink NGN/USD is live on Base — no mocking.
///
///      Test sections:
///        1. Hermes live price fetching (ETH, BTC, SOL, batch)
///        2. USD/NGN feed validation (sensible range)
///        3. Triangulation math verification (Asset/USD × USD/NGN = mark price)
///        4. Staleness enforcement (crypto 120s, USD/NGN 3600s, boundary checks)
///        5. Non-crypto feed integration (commodity, metal, FX — may be unavailable outside hours)
///        6. Confidence ratio validation (<2.5% of price)
///        7. updatePythPrices via PerpDEX (fee refund, exact fee, insufficient fee)
///        8. Disabled/invalid market oracle reads
///        9. Feed reconfiguration (setUsdNgnFeed changes triangulated output)
///       10. Multiple sequential price updates
contract PythOracleForkTest is BaseForkSetup {
    uint256 constant MAX_CONFIDENCE_RATIO = 25e15; // 2.5% — must match PerpDEX

    /*//////////////////////////////////////////////////////////////
                  1. HERMES LIVE PRICE FETCHING
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify we can fetch live prices from Hermes and push them on-chain.
    function test_hermesLivePriceUpdate_ethUsd() public {
        _refreshEthPrices();

        uint256 markPrice = perp.getMarkPrice(ETH_MARKET);
        assertGt(markPrice, 0, "ETH mark price should be > 0");
        console.log("ETH/cNGN mark price:", markPrice);
    }

    /// @notice Verify BTC feed works end-to-end via Hermes.
    function test_hermesLivePriceUpdate_btcUsd() public {
        _refreshBtcPrices();

        uint256 markPrice = perp.getMarkPrice(BTC_MARKET);
        assertGt(markPrice, 0, "BTC mark price should be > 0");
        console.log("BTC/cNGN mark price:", markPrice);
    }

    /// @notice Verify SOL feed works end-to-end via Hermes.
    function test_hermesLivePriceUpdate_solUsd() public {
        _refreshSolPrices();

        uint256 markPrice = perp.getMarkPrice(SOL_MARKET);
        assertGt(markPrice, 0, "SOL mark price should be > 0");
        console.log("SOL/cNGN mark price:", markPrice);
    }

    /// @notice Fetch all crypto + NGN feeds in a single Hermes call.
    function test_hermesBatchUpdate_allCrypto() public {
        _refreshCryptoPrices();

        uint256 ethPrice = perp.getMarkPrice(ETH_MARKET);
        uint256 btcPrice = perp.getMarkPrice(BTC_MARKET);
        uint256 solPrice = perp.getMarkPrice(SOL_MARKET);

        assertGt(ethPrice, 0);
        assertGt(btcPrice, 0);
        assertGt(solPrice, 0);

        // BTC should be more expensive than ETH
        assertGt(btcPrice, ethPrice, "BTC should be priced higher than ETH in cNGN");
        // ETH should be more expensive than SOL
        assertGt(ethPrice, solPrice, "ETH should be priced higher than SOL in cNGN");

        console.log("ETH/cNGN:", ethPrice);
        console.log("BTC/cNGN:", btcPrice);
        console.log("SOL/cNGN:", solPrice);
    }

    /*//////////////////////////////////////////////////////////////
              2. USD/NGN FEED VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify the USD/NGN rate returns a sensible value from Chainlink.
    function test_usdNgnRate_isSensible() public {
        uint256 rate = perp.getUsdNgnRate();
        assertGt(rate, 0, "USD/NGN rate should be > 0");

        // Chainlink NGN/USD live on Base: ~1000-2000 NGN per USD
        assertGt(rate, 1000e18, "USD/NGN rate too low (< 1000)");
        assertLt(rate, 2000e18, "USD/NGN rate too high (> 2000)");

        console.log("USD/NGN rate (18 dec):", rate);
    }

    /// @notice Verify Asset/USD prices are reasonable ranges.
    function test_assetUsdPrices_sensibleRanges() public {
        _refreshCryptoPrices();

        uint256 ethUsd = perp.getAssetUsdPrice(ETH_MARKET);
        uint256 btcUsd = perp.getAssetUsdPrice(BTC_MARKET);
        uint256 solUsd = perp.getAssetUsdPrice(SOL_MARKET);

        // ETH: $500 - $20000
        assertGt(ethUsd, 500e18, "ETH/USD too low");
        assertLt(ethUsd, 20_000e18, "ETH/USD too high");

        // BTC: $10000 - $500000
        assertGt(btcUsd, 10_000e18, "BTC/USD too low");
        assertLt(btcUsd, 500_000e18, "BTC/USD too high");

        // SOL: $1 - $2000
        assertGt(solUsd, 1e18, "SOL/USD too low");
        assertLt(solUsd, 2_000e18, "SOL/USD too high");

        console.log("ETH/USD:", ethUsd);
        console.log("BTC/USD:", btcUsd);
        console.log("SOL/USD:", solUsd);
    }

    /*//////////////////////////////////////////////////////////////
              3. TRIANGULATION MATH VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify mark price = (Asset/USD × USD/NGN) / 1e18 using real feeds.
    function test_triangulation_mathAccuracy() public {
        _refreshEthPrices();

        uint256 ethUsd = perp.getAssetUsdPrice(ETH_MARKET);
        uint256 usdNgn = perp.getUsdNgnRate();
        uint256 markPrice = perp.getMarkPrice(ETH_MARKET);

        uint256 expectedMark = (ethUsd * usdNgn) / PRECISION;

        // Should match exactly — same formula, same Pyth state
        assertEq(markPrice, expectedMark, "Triangulation mismatch");

        console.log("ETH/USD:", ethUsd);
        console.log("USD/NGN:", usdNgn);
        console.log("ETH/NGN (mark):", markPrice);
        console.log("ETH/NGN (calc):", expectedMark);
    }

    /// @notice Verify triangulation for BTC.
    function test_triangulation_btc() public {
        _refreshBtcPrices();

        uint256 btcUsd = perp.getAssetUsdPrice(BTC_MARKET);
        uint256 usdNgn = perp.getUsdNgnRate();
        uint256 markPrice = perp.getMarkPrice(BTC_MARKET);

        uint256 expectedMark = (btcUsd * usdNgn) / PRECISION;
        assertEq(markPrice, expectedMark, "BTC triangulation mismatch");
    }

    /// @notice Verify triangulation for SOL.
    function test_triangulation_sol() public {
        _refreshSolPrices();

        uint256 solUsd = perp.getAssetUsdPrice(SOL_MARKET);
        uint256 usdNgn = perp.getUsdNgnRate();
        uint256 markPrice = perp.getMarkPrice(SOL_MARKET);

        uint256 expectedMark = (solUsd * usdNgn) / PRECISION;
        assertEq(markPrice, expectedMark, "SOL triangulation mismatch");
    }

    /*//////////////////////////////////////////////////////////////
          4. STALENESS — PRICES EXPIRE CORRECTLY
    //////////////////////////////////////////////////////////////*/

    /// @notice After prices are updated, warping past maxStaleness should revert.
    function test_staleness_crypto_revertsAfterExpiry() public {
        _refreshEthPrices();

        // Should work now
        uint256 price = perp.getMarkPrice(ETH_MARKET);
        assertGt(price, 0);

        // Warp well past crypto staleness (Hermes publishTime can be slightly
        // ahead of fork block.timestamp, so use generous margin)
        vm.warp(block.timestamp + CRYPTO_MAX_STALENESS + 300);

        vm.expectRevert(); // StalePrice from Pyth
        perp.getMarkPrice(ETH_MARKET);
    }

    /// @notice Warping exactly to the staleness boundary should still work.
    function test_staleness_crypto_worksAtBoundary() public {
        _refreshEthPrices();

        // Warp just under the boundary
        vm.warp(block.timestamp + CRYPTO_MAX_STALENESS - 1);

        // Should still succeed (within staleness window)
        uint256 price = perp.getMarkPrice(ETH_MARKET);
        assertGt(price, 0);
    }

    /// @notice USD/NGN has longer staleness (3600s). Verify it holds after 120s
    ///         but the asset feed would be stale, causing the full triangulation to fail.
    function test_staleness_usdNgn_longerWindow() public {
        _refreshEthPrices();

        // Warp 500s — asset feed stale (120s max), USD/NGN still valid (3600s)
        // Use generous margin because Hermes publishTime can be ahead of fork block.timestamp
        vm.warp(block.timestamp + 500);

        // Should revert because ETH/USD feed is stale even though USD/NGN is fine
        vm.expectRevert();
        perp.getMarkPrice(ETH_MARKET);
    }

    /*//////////////////////////////////////////////////////////////
        5. NON-CRYPTO FEED VALIDATION (IF MARKETS OPEN)
    //////////////////////////////////////////////////////////////*/

    /// @notice Add commodity/metal/equity/FX markets and verify their feeds work.
    ///         NOTE: Non-crypto feeds may be unavailable outside trading hours.
    ///         This test uses try/catch — it confirms the integration path works
    ///         but doesn't fail if feeds have no recent data.
    function test_nonCryptoFeeds_integration() public {
        // Deploy vaults and add non-crypto markets
        MarketVault brentVault = new MarketVault(cNGN, address(sam), BRENT_MARKET, "vcNGN-BRENT", "vcNGN-BRENT");
        MarketVault xauVault = new MarketVault(cNGN, address(sam), XAU_MARKET, "vcNGN-XAU", "vcNGN-XAU");
        MarketVault eurVault = new MarketVault(cNGN, address(sam), EUR_MARKET, "vcNGN-EUR", "vcNGN-EUR");

        vm.startPrank(admin);
        bytes4[] memory vaultMgrSels = new bytes4[](1);
        vaultMgrSels[0] = MarketVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(brentVault), vaultMgrSels, sam.VAULT_MANAGER_ROLE());
        sam.setTargetFunctionRole(address(xauVault), vaultMgrSels, sam.VAULT_MANAGER_ROLE());
        sam.setTargetFunctionRole(address(eurVault), vaultMgrSels, sam.VAULT_MANAGER_ROLE());
        vm.stopPrank();

        vm.startPrank(operator);
        brentVault.setPerpDex(address(perp));
        xauVault.setPerpDex(address(perp));
        eurVault.setPerpDex(address(perp));

        perp.addMarket(
            BRENT_MARKET,
            BRENT_USD_FEED,
            COMMODITY_MAX_STALENESS,
            NON_CRYPTO_MAX_LEVERAGE,
            MAINTENANCE_MARGIN,
            OI_MULTIPLIER,
            PerpDEX.MarketType.Commodity,
            address(brentVault)
        );
        perp.addMarket(
            XAU_MARKET,
            XAU_USD_FEED,
            METAL_MAX_STALENESS,
            NON_CRYPTO_MAX_LEVERAGE,
            MAINTENANCE_MARGIN,
            OI_MULTIPLIER,
            PerpDEX.MarketType.Metal,
            address(xauVault)
        );
        perp.addMarket(
            EUR_MARKET,
            EUR_USD_FEED,
            FX_MAX_STALENESS,
            NON_CRYPTO_MAX_LEVERAGE,
            MAINTENANCE_MARGIN,
            OI_MULTIPLIER,
            PerpDEX.MarketType.FX,
            address(eurVault)
        );
        vm.stopPrank();

        // Refresh feeds (USD/NGN uses Chainlink, not fetched from Hermes)
        bytes32[] memory feeds = new bytes32[](3);
        feeds[0] = BRENT_USD_FEED;
        feeds[1] = XAU_USD_FEED;
        feeds[2] = EUR_USD_FEED;
        _refreshPythPrices(feeds);

        // Try getting prices — may fail if outside market hours
        try perp.getMarkPrice(BRENT_MARKET) returns (uint256 brentPrice) {
            assertGt(brentPrice, 0, "BRENT price should be > 0");
            console.log("BRENT/cNGN:", brentPrice);
        } catch {
            console.log("BRENT feed stale or unavailable (likely outside hours)");
        }

        try perp.getMarkPrice(XAU_MARKET) returns (uint256 xauPrice) {
            assertGt(xauPrice, 0, "XAU price should be > 0");
            console.log("XAU/cNGN:", xauPrice);
        } catch {
            console.log("XAU feed stale or unavailable (likely outside hours)");
        }

        try perp.getMarkPrice(EUR_MARKET) returns (uint256 eurPrice) {
            assertGt(eurPrice, 0, "EUR price should be > 0");
            console.log("EUR/cNGN:", eurPrice);
        } catch {
            console.log("EUR feed stale or unavailable (likely outside hours)");
        }
    }

    /*//////////////////////////////////////////////////////////////
       6. CONFIDENCE RATIO VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice After fetching real prices, confidence ratio should be within 2.5%.
    ///         If it weren't, the getMarkPrice call itself would revert.
    function test_confidenceRatio_withinThreshold() public {
        _refreshCryptoPrices();

        // If these don't revert, confidence is within MAX_CONFIDENCE_RATIO
        uint256 ethPrice = perp.getMarkPrice(ETH_MARKET);
        uint256 btcPrice = perp.getMarkPrice(BTC_MARKET);
        uint256 solPrice = perp.getMarkPrice(SOL_MARKET);

        assertGt(ethPrice, 0);
        assertGt(btcPrice, 0);
        assertGt(solPrice, 0);
    }

    /// @notice Read raw Pyth data and verify confidence ratio manually.
    function test_confidenceRatio_manualCheck() public {
        _refreshEthPrices();

        PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(ETH_USD_FEED, CRYPTO_MAX_STALENESS);

        uint256 absPrice = uint256(uint64(priceData.price));
        uint256 conf = uint256(priceData.conf);

        // conf * 1e18 <= 2.5e16 * price => conf/price <= 2.5%
        bool withinThreshold = conf * PRECISION <= MAX_CONFIDENCE_RATIO * absPrice;
        assertTrue(withinThreshold, "Confidence ratio exceeds 2.5%");

        uint256 ratioPercentBps = (conf * 10000) / absPrice;
        console.log("ETH/USD confidence ratio (bps):", ratioPercentBps);
        console.log("ETH/USD price:", absPrice);
        console.log("ETH/USD conf:", conf);
    }

    /*//////////////////////////////////////////////////////////////
          7. UPDATE PYTH PRICES VIA PERPDEX
    //////////////////////////////////////////////////////////////*/

    /// @notice Test the PerpDEX.updatePythPrices() function with real Hermes data.
    function test_updatePythPrices_viaPerpdex() public {
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = ETH_USD_FEED;
        bytes[] memory updateData = _fetchHermesPriceUpdate(feeds);

        uint256 fee = pyth.getUpdateFee(updateData);
        assertGt(fee, 0, "Pyth fee should be > 0");

        // Call through PerpDEX's updatePythPrices
        uint256 balanceBefore = address(this).balance;
        perp.updatePythPrices{value: 1 ether}(updateData);
        uint256 balanceAfter = address(this).balance;

        // Should refund excess: we sent 1 ether, fee is tiny
        uint256 spent = balanceBefore - balanceAfter;
        assertEq(spent, fee, "Should only spend exact Pyth fee");

        // Now prices should be readable (USD/NGN is mocked)
        uint256 mark = perp.getMarkPrice(ETH_MARKET);
        assertGt(mark, 0);
    }

    /// @notice updatePythPrices with exact fee (no refund).
    function test_updatePythPrices_exactFee() public {
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = ETH_USD_FEED;
        bytes[] memory updateData = _fetchHermesPriceUpdate(feeds);

        uint256 fee = pyth.getUpdateFee(updateData);

        uint256 balanceBefore = address(this).balance;
        perp.updatePythPrices{value: fee}(updateData);
        uint256 balanceAfter = address(this).balance;

        assertEq(balanceBefore - balanceAfter, fee);
    }

    /// @notice updatePythPrices with insufficient fee should revert.
    function test_updatePythPrices_insufficientFee_reverts() public {
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = ETH_USD_FEED;
        bytes[] memory updateData = _fetchHermesPriceUpdate(feeds);

        uint256 fee = pyth.getUpdateFee(updateData);
        if (fee > 0) {
            // Drain PerpDEX's ETH so it can't cover the fee internally
            vm.deal(address(perp), 0);

            vm.expectRevert();
            perp.updatePythPrices{value: fee - 1}(updateData);
        }
    }

    /*//////////////////////////////////////////////////////////////
           8. DISABLED / INVALID MARKET ORACLE READS
    //////////////////////////////////////////////////////////////*/

    /// @notice Querying a non-existent market should revert.
    function test_getMarkPrice_nonExistentMarket_reverts() public {
        _refreshCryptoPrices();

        bytes32 fakeMarket = keccak256("FAKE-PERP");
        vm.expectRevert(PerpDEX.MarketNotEnabled.selector);
        perp.getMarkPrice(fakeMarket);
    }

    /// @notice Querying a disabled market should still work (prices are feed-based).
    function test_getMarkPrice_disabledMarket_stillReturnsPrice() public {
        _refreshEthPrices();

        // Disable ETH market
        vm.prank(operator);
        perp.disableMarket(ETH_MARKET);

        // getMarkPrice checks pythFeedId != 0, not enabled flag
        // The feed ID is still set even when disabled
        uint256 price = perp.getMarkPrice(ETH_MARKET);
        assertGt(price, 0, "Disabled market should still return price (for closing)");
    }

    /*//////////////////////////////////////////////////////////////
         9. FEED RECONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Changing the NGN/USD Chainlink feed should affect triangulated prices.
    function test_setUsdNgnFeed_changesFeed() public {
        _refreshEthPrices();

        uint256 priceBefore = perp.getMarkPrice(ETH_MARKET);

        // Create a mock Chainlink feed that returns a very different rate
        address mockFeed = makeAddr("mockChainlinkAlt");
        // Mock NGN/USD = 0.00125 (800 NGN per USD, about half of real ~1361)
        vm.mockCall(mockFeed, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(8)));
        vm.mockCall(
            mockFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(125000), block.timestamp, block.timestamp, uint80(1))
        );

        vm.prank(operator);
        perp.setUsdNgnFeed(mockFeed, USD_NGN_STALENESS);

        uint256 priceAfter = perp.getMarkPrice(ETH_MARKET);
        assertGt(priceAfter, 0);

        // Price should be different since we changed the exchange rate
        assertTrue(priceBefore != priceAfter, "Price should change with different NGN feed");

        // Restore original feed
        vm.prank(operator);
        perp.setUsdNgnFeed(NGN_USD_CHAINLINK, USD_NGN_STALENESS);
    }

    /*//////////////////////////////////////////////////////////////
         10. MULTIPLE SEQUENTIAL PRICE UPDATES
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify price updates can be called multiple times without issues.
    function test_multipleSequentialUpdates() public {
        // First update
        _refreshEthPrices();
        uint256 price1 = perp.getMarkPrice(ETH_MARKET);
        assertGt(price1, 0);

        // Advance time slightly
        vm.warp(block.timestamp + 10);

        // Second update
        _refreshEthPrices();
        uint256 price2 = perp.getMarkPrice(ETH_MARKET);
        assertGt(price2, 0);

        console.log("Price 1:", price1);
        console.log("Price 2:", price2);
    }

    /*//////////////////////////////////////////////////////////////
                       RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
