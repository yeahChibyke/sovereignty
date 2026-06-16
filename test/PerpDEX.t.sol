// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {AggregatorV3Interface} from "chainlink-evm/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PerpDEX} from "../src/PerpDEX.sol";
import {MarketVault} from "../src/MarketVault.sol";
import {SovereigntyAccessManager} from "../src/SovereigntyAccessManager.sol";
import {MockcNGN} from "./mocks/MockcNGN.sol";

/// @title PerpDEXTest
/// @notice Unit tests for the PerpDEX perpetual trading engine using mock oracles.
/// @dev Uses MockPyth for deterministic Asset/USD prices and vm.mockCall for the
///      Chainlink NGN/USD feed, allowing exact control over triangulated mark prices.
///
///      Coverage areas:
///        - Market management: add, duplicate, unauthorized, disable, updateParams, getAllMarketIds
///        - Oracle / pricing: triangulation math, per-asset prices, staleness, excess refunds, feed swap
///        - Commit-reveal trading: open long/short, leverage limits, duplicate position,
///          timing (too-early, expired, wrong hash), disabled market
///        - Close position: profitable long, losing long, no-position revert
///        - Collateral management: add, remove, leverage-breach on removal
///        - Liquidation: public liquidation, not-liquidatable revert, no-position edge case
///        - Chainlink Automation: checkUpkeep detection, none-liquidatable, performUpkeep by
///          forwarder, unauthorized performUpkeep
///        - OI tracking: updates on trade, decreases on close, OI cap exceeded
///        - Getter functions: equity, vault TVL, tradersPerMarketLength, getMarketInfo
///        - Pause/unpause: blocks trading, resumes trading
///        - Multi-market isolation: independent positions and OI per market
///        - MarketInfo getter: empty/active/nonexistent markets, per-asset prices, unrealized PnL
contract PerpDEXTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deterministic market IDs matching production keccak256("ETH-PERP"), etc.
    bytes32 constant ETH_MARKET = keccak256("ETH-PERP");
    bytes32 constant BTC_MARKET = keccak256("BTC-PERP");

    /// @dev Arbitrary Pyth feed IDs for the mock oracle (not real Pyth IDs).
    bytes32 constant ETH_USD_FEED = bytes32(uint256(1));
    bytes32 constant BTC_USD_FEED = bytes32(uint256(2));

    /// @dev Pyth price exponent for crypto feeds: -8 means price * 10^-8 = USD.
    int32 constant CRYPTO_EXPO = -8;

    /// @dev 18-decimal precision constant used for price scaling.
    uint256 constant PRECISION = 1e18;

    /// @dev Maximum price age in seconds for the mock Pyth oracle.
    uint256 constant MAX_STALENESS = 120;

    /// @dev Absolute OI ceiling for tests — set effectively unbounded so the TVL-multiplier
    ///      remains the binding cap in existing tests; the absolute-cap path is exercised
    ///      separately via updateMarketParams in its own test.
    uint256 constant MAX_OI = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                            STATE
    //////////////////////////////////////////////////////////////*/

    MockcNGN cNGN;
    MockPyth mockPyth;
    SovereigntyAccessManager sam;
    PerpDEX perp;
    MarketVault ethVault;
    MarketVault btcVault;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address trader1 = makeAddr("trader1");
    address trader2 = makeAddr("trader2");
    address liquidator = makeAddr("liquidator");
    address lpProvider = makeAddr("lpProvider");
    address mockNgnUsdFeed = makeAddr("chainlinkNgnUsd");

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Full test-environment setup: token, oracles, SAM, PerpDEX, vaults, liquidity.
    /// @dev Steps:
    ///      1. Deploy MockcNGN (6-dec ERC20).
    ///      2. Deploy MockPyth (120s validity, 1 wei fee).
    ///      3. Deploy SAM via proxy; grant OPERATOR, MARKET_MANAGER, VAULT_MANAGER, PAUSER to `operator`.
    ///      4. Deploy PerpDEX with cNGN, mockPyth, mock Chainlink feed, SAM.
    ///      5. Mock Chainlink decimals() → 8.
    ///      6. Deploy ETH + BTC MarketVaults; configure SAM function roles.
    ///      7. Link vaults → PerpDEX; add ETH + BTC markets (5x lev, 2% MMR, 5x OI cap).
    ///      8. Seed 5M cNGN LP liquidity into each vault.
    ///      9. Fund traders with 1M cNGN each + ETH for Pyth fees.
    function setUp() public {
        // 1. Deploy token
        cNGN = new MockcNGN();

        // 2. Deploy MockPyth (validTimePeriod=120s, fee=1 wei)
        mockPyth = new MockPyth(MAX_STALENESS, 1);

        // 3. Deploy SAM via proxy
        vm.startPrank(admin);
        SovereigntyAccessManager samImpl = new SovereigntyAccessManager();
        bytes memory initData = abi.encodeCall(SovereigntyAccessManager.initialize, (admin));
        ERC1967Proxy samProxy = new ERC1967Proxy(address(samImpl), initData);
        sam = SovereigntyAccessManager(address(samProxy));

        // Grant roles
        sam.grantRole(sam.OPERATOR_ROLE(), operator, 0);
        sam.grantRole(sam.MARKET_MANAGER_ROLE(), operator, 0);
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), operator, 0);
        sam.grantRole(sam.PAUSER_ROLE(), operator, 0);
        vm.stopPrank();

        // 4. Deploy PerpDEX (sequencer feed disabled with address(0) for unit tests)
        perp = new PerpDEX(address(cNGN), address(mockPyth), mockNgnUsdFeed, MAX_STALENESS, address(sam), address(0));

        // Mock Chainlink NGN/USD feed decimals (constant for all tests)
        vm.mockCall(
            mockNgnUsdFeed, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(8))
        );

        // 5. Deploy MarketVaults
        ethVault =
            new MarketVault(IERC20(address(cNGN)), address(sam), ETH_MARKET, "cNGN Vault Share - ETH", "vcNGN-ETH", 0);
        btcVault =
            new MarketVault(IERC20(address(cNGN)), address(sam), BTC_MARKET, "cNGN Vault Share - BTC", "vcNGN-BTC", 0);

        // 6. Configure SAM function roles for PerpDEX
        vm.startPrank(admin);

        // PerpDEX functions → roles
        bytes4[] memory marketMgrSelectors = new bytes4[](3);
        marketMgrSelectors[0] = PerpDEX.addMarket.selector;
        marketMgrSelectors[1] = PerpDEX.disableMarket.selector;
        marketMgrSelectors[2] = PerpDEX.updateMarketParams.selector;
        sam.setTargetFunctionRole(address(perp), marketMgrSelectors, sam.MARKET_MANAGER_ROLE());

        bytes4[] memory operatorSelectors = new bytes4[](4);
        operatorSelectors[0] = PerpDEX.setUsdNgnFeed.selector;
        operatorSelectors[1] = PerpDEX.setForwarder.selector;
        operatorSelectors[2] = PerpDEX.disableForwarder.selector;
        operatorSelectors[3] = PerpDEX.unpause.selector;
        sam.setTargetFunctionRole(address(perp), operatorSelectors, sam.OPERATOR_ROLE());

        bytes4[] memory pauserSelectors = new bytes4[](1);
        pauserSelectors[0] = PerpDEX.pause.selector;
        sam.setTargetFunctionRole(address(perp), pauserSelectors, sam.PAUSER_ROLE());

        // MarketVault functions → roles
        bytes4[] memory vaultMgrSelectors = new bytes4[](1);
        vaultMgrSelectors[0] = MarketVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(ethVault), vaultMgrSelectors, sam.VAULT_MANAGER_ROLE());
        sam.setTargetFunctionRole(address(btcVault), vaultMgrSelectors, sam.VAULT_MANAGER_ROLE());

        vm.stopPrank();

        // 7. Link vaults to PerpDEX
        vm.startPrank(operator);
        ethVault.setPerpDex(address(perp));
        btcVault.setPerpDex(address(perp));

        // 8. Add markets
        perp.addMarket(
            ETH_MARKET,
            ETH_USD_FEED,
            MAX_STALENESS,
            5, // 5x leverage
            2e16, // 2% maintenance margin
            5e18, // 5x OI cap
            MAX_OI, // absolute OI ceiling (unbounded in tests)
            PerpDEX.MarketType.Crypto,
            address(ethVault)
        );
        perp.addMarket(
            BTC_MARKET, BTC_USD_FEED, MAX_STALENESS, 5, 2e16, 5e18, MAX_OI, PerpDEX.MarketType.Crypto, address(btcVault)
        );
        vm.stopPrank();

        // 9. Seed LP liquidity into ETH vault
        cNGN.mint(lpProvider, 10_000_000e6); // 10M cNGN
        vm.startPrank(lpProvider);
        cNGN.approve(address(ethVault), type(uint256).max);
        ethVault.deposit(5_000_000e6, lpProvider);
        cNGN.approve(address(btcVault), type(uint256).max);
        btcVault.deposit(5_000_000e6, lpProvider);
        vm.stopPrank();

        // 10. Fund trader accounts
        cNGN.mint(trader1, 1_000_000e6);
        cNGN.mint(trader2, 1_000_000e6);
        vm.prank(trader1);
        cNGN.approve(address(perp), type(uint256).max);
        vm.prank(trader2);
        cNGN.approve(address(perp), type(uint256).max);

        // 11. Fund this contract for Pyth fees
        vm.deal(address(this), 100 ether);
        vm.deal(trader1, 10 ether);
        vm.deal(trader2, 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        PYTH PRICE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Push a single price feed update into MockPyth.
    /// @param feedId Pyth feed identifier.
    /// @param price  Price in `10^(-expo)` units (e.g. 3000e8 for $3000 with expo=-8).
    /// @param expo   Pyth price exponent (negative = fractional decimals).
    /// @param conf   Confidence interval (same scale as price).
    function _setPythPrice(bytes32 feedId, int64 price, int32 expo, uint64 conf) internal {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = mockPyth.createPriceFeedUpdateData(
            feedId, price, conf, expo, price, conf, uint64(block.timestamp), uint64(block.timestamp - 1)
        );
        mockPyth.updatePriceFeeds{value: 1}(updateData);
    }

    /// @dev Mock the Chainlink NGN/USD latestRoundData. answer is in 8-decimal format.
    ///      E.g., 62500 = 0.000625 USD per NGN -> inverted = 1600 NGN per USD.
    function _mockChainlinkNgnUsd(int256 answer) internal {
        vm.mockCall(
            mockNgnUsdFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// @dev Sets default oracle state: ETH/USD=$3000, BTC/USD=$100k, NGN/USD=0.000625
    ///      → USD/NGN=1600 → ETH/NGN=4.8M, BTC/NGN=160M.
    function _setDefaultPrices() internal {
        _setPythPrice(ETH_USD_FEED, 3000e8, CRYPTO_EXPO, 10e8); // $3000 +/- $10
        _setPythPrice(BTC_USD_FEED, 100_000e8, CRYPTO_EXPO, 50e8); // $100k +/- $50
        _mockChainlinkNgnUsd(62500); // NGN/USD = 0.000625 -> USD/NGN = 1600
    }

    /// @notice Commit-reveal helper: requestTrade → roll 2 blocks → refresh prices → executeTrade.
    /// @dev Constructs the order hash from (trader, marketId, side, collateral, leverage, salt),
    ///      commits via requestTrade, advances past MIN_BLOCK_DELAY, then executes.
    function _commitAndExecuteTrade(
        address trader,
        bytes32 marketId,
        PerpDEX.Side side,
        uint256 collateral,
        uint256 leverage
    ) internal {
        bytes32 salt = keccak256(abi.encode(trader, block.number));
        // Opt out of the slippage bound (max for long, 0 for short) and use a far deadline.
        uint256 acceptablePrice = side == PerpDEX.Side.Long ? type(uint256).max : 0;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash =
            keccak256(abi.encode(trader, marketId, side, collateral, leverage, acceptablePrice, deadline, salt));

        vm.prank(trader);
        perp.requestTrade(orderHash);

        // Advance blocks to satisfy commit-reveal delay
        vm.roll(block.number + 2);

        // Refresh prices (time must advance too for staleness check)
        vm.warp(block.timestamp + 2);
        _setDefaultPrices();

        vm.prank(trader);
        perp.executeTrade(marketId, side, collateral, leverage, acceptablePrice, deadline, salt);
    }

    /*//////////////////////////////////////////////////////////////
                      MARKET MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice addMarket succeeds and stores correct config.
    function test_addMarket_success() public view {
        (bytes32 pythFeedId,, uint256 maxLev,,,,, bool enabled) = perp.getMarketConfig(ETH_MARKET);
        assertEq(pythFeedId, ETH_USD_FEED);
        assertEq(maxLev, 5);
        assertTrue(enabled);
    }

    /// @notice Adding a duplicate market ID reverts with MarketAlreadyExists.
    function test_addMarket_duplicate_reverts() public {
        vm.prank(operator);
        vm.expectRevert(PerpDEX.MarketAlreadyExists.selector);
        perp.addMarket(
            ETH_MARKET, ETH_USD_FEED, MAX_STALENESS, 5, 2e16, 5e18, MAX_OI, PerpDEX.MarketType.Crypto, address(ethVault)
        );
    }

    /// @notice A disabled market ID can never be re-added (market IDs are immutable once used).
    function test_addMarket_readd_after_disable_reverts() public {
        vm.startPrank(operator);
        perp.disableMarket(ETH_MARKET);

        // Even with the market disabled, re-adding the same ID must revert — re-adding would
        // overwrite the config (incl. vault) while stale positions/OI/collateral persist.
        vm.expectRevert(PerpDEX.MarketAlreadyExists.selector);
        perp.addMarket(
            ETH_MARKET, ETH_USD_FEED, MAX_STALENESS, 5, 2e16, 5e18, MAX_OI, PerpDEX.MarketType.Crypto, address(ethVault)
        );
        vm.stopPrank();
    }

    /// @notice addMarket rejects a zero Pyth feed ID (the contract-wide existence sentinel).
    function test_addMarket_zeroFeedId_reverts() public {
        vm.prank(operator);
        vm.expectRevert(PerpDEX.InvalidParameters.selector);
        perp.addMarket(
            keccak256("NEW-PERP"),
            bytes32(0),
            MAX_STALENESS,
            5,
            2e16,
            5e18,
            MAX_OI,
            PerpDEX.MarketType.Crypto,
            address(ethVault)
        );
    }

    /// @notice Only MARKET_MANAGER_ROLE can call addMarket.
    function test_addMarket_unauthorized_reverts() public {
        vm.prank(trader1);
        vm.expectRevert();
        perp.addMarket(
            keccak256("NEW-PERP"),
            bytes32(uint256(10)),
            MAX_STALENESS,
            3,
            2e16,
            5e18,
            MAX_OI,
            PerpDEX.MarketType.Commodity,
            address(ethVault)
        );
    }

    /// @notice disableMarket sets the enabled flag to false.
    function test_disableMarket() public {
        vm.prank(operator);
        perp.disableMarket(ETH_MARKET);

        (,,,,,,, bool enabled) = perp.getMarketConfig(ETH_MARKET);
        assertFalse(enabled);
    }

    /// @notice updateMarketParams updates leverage, MMR, OI multiplier, and staleness.
    function test_updateMarketParams() public {
        vm.prank(operator);
        perp.updateMarketParams(ETH_MARKET, 10, 3e16, 3e18, MAX_OI, 60);

        (, uint256 staleness, uint256 maxLev, uint256 mmr, uint256 oiMult,,,) = perp.getMarketConfig(ETH_MARKET);
        assertEq(maxLev, 10);
        assertEq(mmr, 3e16);
        assertEq(oiMult, 3e18);
        assertEq(staleness, 60);
    }

    /// @notice getAllMarketIds returns all registered market IDs in order.
    function test_getAllMarketIds() public view {
        bytes32[] memory ids = perp.getAllMarketIds();
        assertEq(ids.length, 2);
        assertEq(ids[0], ETH_MARKET);
        assertEq(ids[1], BTC_MARKET);
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE / PRICING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mark price triangulates correctly: ETH/USD × USD/NGN = 4,800,000e18.
    function test_getMarkPrice_triangulation() public {
        _setDefaultPrices();

        // ETH/USD = 3000, USD/NGN = 1600
        // ETH/NGN = 3000 * 1600 = 4,800,000
        uint256 ethNgn = perp.getMarkPrice(ETH_MARKET);
        assertEq(ethNgn, 4_800_000e18);
    }

    /// @notice BTC mark price triangulates: $100k × 1600 = 160,000,000e18 cNGN.
    function test_getMarkPrice_btc() public {
        _setDefaultPrices();

        // BTC/USD = 100,000, USD/NGN = 1600
        // BTC/NGN = 100,000 * 1600 = 160,000,000
        uint256 btcNgn = perp.getMarkPrice(BTC_MARKET);
        assertEq(btcNgn, 160_000_000e18);
    }

    /// @notice USD/NGN rate inverts Chainlink NGN/USD correctly → 1600e18.
    function test_getUsdNgnRate() public {
        _setDefaultPrices();
        uint256 rate = perp.getUsdNgnRate();
        assertEq(rate, 1600e18);
    }

    /// @notice Asset/USD price getter returns ETH at $3000e18.
    function test_getAssetUsdPrice() public {
        _setDefaultPrices();
        uint256 ethUsd = perp.getAssetUsdPrice(ETH_MARKET);
        assertEq(ethUsd, 3000e18);
    }

    /// @notice Stale Pyth prices revert when queried past the staleness window.
    function test_getMarkPrice_stale_reverts() public {
        _setDefaultPrices();
        // Fast forward beyond staleness window
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        vm.expectRevert(); // StalePrice from Pyth
        perp.getMarkPrice(ETH_MARKET);
    }

    /// @notice Querying a non-existent market reverts with MarketNotEnabled.
    function test_getMarkPrice_invalid_market_reverts() public {
        vm.expectRevert(PerpDEX.MarketNotEnabled.selector);
        perp.getMarkPrice(keccak256("NONEXISTENT"));
    }

    /// @notice updatePythPrices refunds excess ETH after deducting the Pyth fee.
    function test_updatePythPrices_refundsExcess() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, 3000e8, 10e8, CRYPTO_EXPO, 3000e8, 10e8, uint64(block.timestamp), uint64(block.timestamp - 1)
        );

        uint256 balBefore = address(this).balance;
        perp.updatePythPrices{value: 1 ether}(updateData);
        uint256 balAfter = address(this).balance;

        // Should have refunded all but 1 wei (the Pyth fee)
        assertEq(balBefore - balAfter, 1);
    }

    /// @notice updatePythPrices reverts when msg.value is below the Pyth fee (fee must come from
    ///         the caller, never the contract's own ETH balance). (Fix #4.)
    function test_updatePythPrices_insufficientFee_reverts() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, 3000e8, 10e8, CRYPTO_EXPO, 3000e8, 10e8, uint64(block.timestamp), uint64(block.timestamp - 1)
        );
        // MockPyth fee = 1 wei per update; sending 0 must revert rather than spend contract ETH.
        vm.expectRevert(PerpDEX.InsufficientFee.selector);
        perp.updatePythPrices{value: 0}(updateData);
    }

    /// @notice OPERATOR can change the Chainlink NGN/USD feed address and staleness.
    function test_setUsdNgnFeed() public {
        address newFeed = makeAddr("newFeed");
        vm.prank(operator);
        perp.setUsdNgnFeed(newFeed, 60);
        assertEq(address(perp.ngnUsdChainlinkFeed()), newFeed);
        assertEq(perp.usdNgnMaxStaleness(), 60);
    }

    /// @notice setUsdNgnFeed rejects the zero address.
    function test_setUsdNgnFeed_zeroAddress_reverts() public {
        vm.prank(operator);
        vm.expectRevert(PerpDEX.ZeroAddress.selector);
        perp.setUsdNgnFeed(address(0), 60);
    }

    /// @notice setUsdNgnFeed rejects a zero staleness window.
    function test_setUsdNgnFeed_zeroStaleness_reverts() public {
        vm.prank(operator);
        vm.expectRevert(PerpDEX.InvalidParameters.selector);
        perp.setUsdNgnFeed(makeAddr("newFeed"), 0);
    }

    /// @notice setForwarder rejects the zero address (use disableForwarder() to turn off automation).
    function test_setForwarder_zeroAddress_reverts() public {
        vm.prank(operator);
        vm.expectRevert(PerpDEX.ZeroAddress.selector);
        perp.setForwarder(address(0));
    }

    /// @notice disableForwarder explicitly clears the forwarder.
    function test_disableForwarder_clearsForwarder() public {
        address forwarder = makeAddr("forwarder");
        vm.startPrank(operator);
        perp.setForwarder(forwarder);
        assertEq(perp.liquidationForwarder(), forwarder);

        perp.disableForwarder();
        assertEq(perp.liquidationForwarder(), address(0));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       COMMIT-REVEAL TRADING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Opening a 3× long creates the correct position state (collateral, size, entry price).
    function test_openPosition_long() public {
        _setDefaultPrices();
        uint256 collateral = 100_000e6; // 100k cNGN

        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, 3);

        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.collateral, collateral);
        assertEq(pos.size, uint256(collateral) * 1e12 * 3); // 300k * 1e18
        assertTrue(pos.averagePrice > 0);
    }

    /// @notice Opening a 2× short stores Side.Short and correct size.
    function test_openPosition_short() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Short, 50_000e6, 2);

        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.collateral, 50_000e6);
        assertEq(pos.size, uint256(50_000e6) * 1e12 * 2);
    }

    /// @notice Leverage exceeding market max (6x > 5x) reverts with ExceedsMaxLeverage.
    function test_openPosition_exceeds_leverage_reverts() public {
        _setDefaultPrices();
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000e6;
        uint256 leverage = 6; // exceeds 5x max
        uint256 acceptablePrice = type(uint256).max;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash = keccak256(
            abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, leverage, acceptablePrice, deadline, salt)
        );

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 2);
        _setDefaultPrices();

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.ExceedsMaxLeverage.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, collateral, leverage, acceptablePrice, deadline, salt);
    }

    /// @notice Opening a second position in the same market reverts with PositionAlreadyOpen.
    function test_openPosition_duplicate_reverts() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 2);

        // Try to open another position in same market
        bytes32 salt = keccak256("salt2");
        uint256 collateral = 50_000e6;
        uint256 acceptablePrice = type(uint256).max;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash = keccak256(
            abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, uint256(2), acceptablePrice, deadline, salt)
        );

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 2);
        _setDefaultPrices();

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.PositionAlreadyOpen.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, collateral, 2, acceptablePrice, deadline, salt);
    }

    /// @notice Executing in the same block as commit reverts with TooEarlyToExecute.
    function test_commitReveal_tooEarly_reverts() public {
        _setDefaultPrices();
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000e6;
        uint256 acceptablePrice = type(uint256).max;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash = keccak256(
            abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, uint256(2), acceptablePrice, deadline, salt)
        );

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        // Don't advance blocks — try to execute immediately
        vm.prank(trader1);
        vm.expectRevert(PerpDEX.TooEarlyToExecute.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, collateral, 2, acceptablePrice, deadline, salt);
    }

    /// @notice Executing after MAX_BLOCK_DELAY blocks reverts with OrderExpired.
    function test_commitReveal_expired_reverts() public {
        _setDefaultPrices();
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000e6;
        uint256 acceptablePrice = type(uint256).max;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash = keccak256(
            abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, uint256(2), acceptablePrice, deadline, salt)
        );

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        // Advance too many blocks
        vm.roll(block.number + 25);
        vm.warp(block.timestamp + 25);
        _setDefaultPrices();

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.OrderExpired.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, collateral, 2, acceptablePrice, deadline, salt);
    }

    /// @notice Revealing with a wrong salt produces a hash mismatch → OrderHashMismatch.
    function test_commitReveal_wrongHash_reverts() public {
        _setDefaultPrices();
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000e6;
        uint256 acceptablePrice = type(uint256).max;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash = keccak256(
            abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, uint256(2), acceptablePrice, deadline, salt)
        );

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 2);
        _setDefaultPrices();

        // Reveal with different salt
        vm.prank(trader1);
        vm.expectRevert(PerpDEX.OrderHashMismatch.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, collateral, 2, acceptablePrice, deadline, keccak256("wrong"));
    }

    /// @notice Trading on a disabled market reverts with MarketNotEnabled.
    function test_disabled_market_reverts_on_trade() public {
        _setDefaultPrices();
        vm.prank(operator);
        perp.disableMarket(ETH_MARKET);

        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000e6;
        uint256 acceptablePrice = type(uint256).max;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash = keccak256(
            abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, uint256(2), acceptablePrice, deadline, salt)
        );

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 2);
        _setDefaultPrices();

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.MarketNotEnabled.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, collateral, 2, acceptablePrice, deadline, salt);
    }

    /// @notice A Long reveal with an acceptablePrice below the mark price reverts (slippage bound).
    function test_executeTrade_slippageExceeded_long_reverts() public {
        _setDefaultPrices();
        bytes32 salt = keccak256("slip");
        uint256 collateral = 100_000e6;
        uint256 acceptablePrice = 1; // far below the ~4.8M cNGN mark → Long must revert
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash = keccak256(
            abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, uint256(2), acceptablePrice, deadline, salt)
        );

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 2);
        _setDefaultPrices();

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.SlippageExceeded.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, collateral, 2, acceptablePrice, deadline, salt);
    }

    /// @notice Revealing after the committed deadline reverts with DeadlineExceeded.
    function test_executeTrade_deadlineExceeded_reverts() public {
        _setDefaultPrices();
        bytes32 salt = keccak256("dl");
        uint256 collateral = 100_000e6;
        uint256 acceptablePrice = type(uint256).max;
        uint256 deadline = block.timestamp + 1; // expires almost immediately
        bytes32 orderHash = keccak256(
            abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, uint256(2), acceptablePrice, deadline, salt)
        );

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2); // satisfy block window
        vm.warp(block.timestamp + 100); // past the deadline
        _setDefaultPrices();

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.DeadlineExceeded.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, collateral, 2, acceptablePrice, deadline, salt);
    }

    /// @notice When the L2 sequencer reports down, price reads revert with SequencerDown.
    function test_sequencer_down_reverts() public {
        vm.warp(1_000_000);
        address seqFeed = makeAddr("seqDown");
        vm.mockCall(
            seqFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), block.timestamp - 7200, block.timestamp, uint80(1)) // answer 1 = down
        );
        PerpDEX p2 = new PerpDEX(address(cNGN), address(mockPyth), mockNgnUsdFeed, MAX_STALENESS, address(sam), seqFeed);

        vm.expectRevert(PerpDEX.SequencerDown.selector);
        p2.getUsdNgnRate();
    }

    /// @notice Within the grace period after sequencer recovery, price reads still revert.
    function test_sequencer_gracePeriod_reverts() public {
        vm.warp(1_000_000);
        address seqFeed = makeAddr("seqGrace");
        vm.mockCall(
            seqFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), block.timestamp - 100, block.timestamp, uint80(1)) // up, but recovered 100s ago
        );
        PerpDEX p2 = new PerpDEX(address(cNGN), address(mockPyth), mockNgnUsdFeed, MAX_STALENESS, address(sam), seqFeed);

        vm.expectRevert(PerpDEX.SequencerGracePeriodNotElapsed.selector);
        p2.getUsdNgnRate();
    }

    /*//////////////////////////////////////////////////////////////
                       CLOSE POSITION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Closing a profitable long (ETH +10%) returns more than collateral.
    function test_closePosition_profitable_long() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);

        // Price goes up 10%: ETH 3000 → 3300
        vm.warp(block.timestamp + 5);
        _setPythPrice(ETH_USD_FEED, 3300e8, CRYPTO_EXPO, 10e8);
        _mockChainlinkNgnUsd(62500);

        uint256 balBefore = cNGN.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(ETH_MARKET);
        uint256 balAfter = cNGN.balanceOf(trader1);

        // Trader should get back more than their collateral
        assertTrue(balAfter > balBefore);
        uint256 profit = balAfter - balBefore - 0; // got back collateral + profit
        assertTrue(profit > 100_000e6); // Got back more than collateral

        // Position should be deleted
        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.size, 0);
    }

    /// @notice Closing a losing long (ETH −10%) returns less than collateral.
    function test_closePosition_losing_long() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 2);

        // Price goes down 10%: ETH 3000 → 2700
        vm.warp(block.timestamp + 5);
        _setPythPrice(ETH_USD_FEED, 2700e8, CRYPTO_EXPO, 10e8);
        _mockChainlinkNgnUsd(62500);

        uint256 balBefore = cNGN.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(ETH_MARKET);
        uint256 balAfter = cNGN.balanceOf(trader1);

        // Trader should get back less than their collateral
        uint256 received = balAfter - balBefore;
        assertTrue(received < 100_000e6);
    }

    /// @notice Closing with no open position reverts with NoOpenPosition.
    function test_closePosition_no_position_reverts() public {
        vm.prank(trader1);
        vm.expectRevert(PerpDEX.NoOpenPosition.selector);
        perp.closePosition(ETH_MARKET);
    }

    /*//////////////////////////////////////////////////////////////
                       COLLATERAL MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adding 50k collateral to an existing position increases pos.collateral.
    function test_addCollateral() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);

        uint256 addAmount = 50_000e6;
        vm.prank(trader1);
        perp.addCollateral(ETH_MARKET, addAmount);

        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.collateral, 150_000e6);
    }

    /// @notice Removing 20k collateral from a 2× position succeeds (stays within leverage).
    function test_removeCollateral() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 2);

        // Remove some collateral (staying within leverage)
        vm.warp(block.timestamp + 5);
        _setDefaultPrices();

        uint256 removeAmount = 20_000e6;
        vm.prank(trader1);
        perp.removeCollateral(ETH_MARKET, removeAmount);

        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.collateral, 80_000e6);
    }

    /// @notice Removing collateral from a 5× position reverts (would exceed max leverage).
    function test_removeCollateral_exceeds_leverage_reverts() public {
        _setDefaultPrices();
        // Open at 5x — can't remove any collateral without exceeding leverage
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 5);

        vm.warp(block.timestamp + 5);
        _setDefaultPrices();

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.ExceedsLeverageAfterRemoval.selector);
        perp.removeCollateral(ETH_MARKET, 10_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Public liquidation succeeds when margin ratio < 2%; liquidator receives bounty.
    /// @dev ETH drops ~18.3% (3000→2450), equity ≈ 8.3k on 500k size → 1.67% < 2% MMR.
    function test_liquidation_public() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 5);

        // Drop ETH ~18.3% (3000 → 2450) so equity is positive but below maintenance margin.
        // Size = 500k, PnL ≈ -91.7k, equity ≈ 8.3k → margin ratio 1.67% < 2% → liquidatable with bounty.
        vm.warp(block.timestamp + 5);
        _setPythPrice(ETH_USD_FEED, 2450e8, CRYPTO_EXPO, 10e8);
        _mockChainlinkNgnUsd(62500);

        assertTrue(perp.isLiquidatable(ETH_MARKET, trader1));

        uint256 liqBalBefore = cNGN.balanceOf(liquidator);
        vm.prank(liquidator);
        perp.liquidate(ETH_MARKET, trader1);
        uint256 liqBalAfter = cNGN.balanceOf(liquidator);

        // Liquidator should receive bounty
        assertTrue(liqBalAfter > liqBalBefore);

        // Position should be deleted
        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.size, 0);
    }

    /// @notice A bankrupt (equity ≤ 0) position still pays the liquidator a collateral-based
    ///         bounty, so the permissionless backstop is incentivized to clear bad debt. (Fix #1.)
    function test_liquidation_bankrupt_still_pays_bounty() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 5);

        // Crash ETH 3000 → 2300 so the 5× long is underwater past its collateral (equity < 0).
        vm.warp(block.timestamp + 5);
        _setPythPrice(ETH_USD_FEED, 2300e8, CRYPTO_EXPO, 10e8);
        _mockChainlinkNgnUsd(62500);

        assertTrue(perp.isLiquidatable(ETH_MARKET, trader1));
        assertLt(perp.getPositionEquity(ETH_MARKET, trader1), int256(0), "position should be bankrupt");

        uint256 before = cNGN.balanceOf(liquidator);
        vm.prank(liquidator);
        perp.liquidate(ETH_MARKET, trader1);
        uint256 received = cNGN.balanceOf(liquidator) - before;

        // bounty = 1% of collateral = 100_000e6 / 100 = 1_000e6, paid even though equity ≤ 0.
        // (The old equity-based bounty would have paid 0 here.)
        assertEq(received, 1_000e6, "liquidator must earn collateral-based bounty on bankrupt close");
    }

    /// @notice Liquidating a healthy position reverts with NotLiquidatable.
    function test_liquidation_not_liquidatable_reverts() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 2);

        assertFalse(perp.isLiquidatable(ETH_MARKET, trader1));

        vm.prank(liquidator);
        vm.expectRevert(PerpDEX.NotLiquidatable.selector);
        perp.liquidate(ETH_MARKET, trader1);
    }

    /// @notice isLiquidatable returns false for an address with no position.
    function test_isLiquidatable_no_position() public view {
        assertFalse(perp.isLiquidatable(ETH_MARKET, trader1));
    }

    /*//////////////////////////////////////////////////////////////
                    CHAINLINK AUTOMATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice checkUpkeep detects a liquidatable 5× position after a price crash.
    function test_checkUpkeep_finds_liquidatable() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 5);

        // Crash price
        vm.warp(block.timestamp + 5);
        _setPythPrice(ETH_USD_FEED, 2250e8, CRYPTO_EXPO, 10e8);
        _mockChainlinkNgnUsd(62500);

        (bool upkeepNeeded, bytes memory performData) = perp.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertTrue(performData.length > 0);
    }

    /// @notice checkUpkeep returns false when no positions are liquidatable.
    function test_checkUpkeep_none_liquidatable() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 2);

        (bool upkeepNeeded,) = perp.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    /// @notice performUpkeep called by the forwarder liquidates the flagged position.
    function test_performUpkeep_by_forwarder() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 5);

        address forwarder = makeAddr("forwarder");
        vm.prank(operator);
        perp.setForwarder(forwarder);

        // Crash price
        vm.warp(block.timestamp + 5);
        _setPythPrice(ETH_USD_FEED, 2250e8, CRYPTO_EXPO, 10e8);
        _mockChainlinkNgnUsd(62500);

        (, bytes memory performData) = perp.checkUpkeep("");

        vm.prank(forwarder);
        perp.performUpkeep(performData);

        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.size, 0);
    }

    /// @notice performUpkeep from a non-forwarder address reverts with OnlyForwarder.
    function test_performUpkeep_unauthorized_reverts() public {
        bytes32[] memory m = new bytes32[](1);
        address[] memory t = new address[](1);
        bytes memory performData = abi.encode(m, t);

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.OnlyForwarder.selector);
        perp.performUpkeep(performData);
    }

    /*//////////////////////////////////////////////////////////////
                        OI TRACKING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Opening a 3× long correctly increases longOI by size = collateral × 1e12 × leverage.
    function test_market_OI_updates_on_trade() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);

        PerpDEX.MarketOI memory oi = perp.getMarketOI(ETH_MARKET);
        assertEq(oi.longOI, uint256(100_000e6) * 1e12 * 3);
        assertEq(oi.shortOI, 0);
    }

    /// @notice Closing a position reduces OI back to zero.
    function test_market_OI_decreases_on_close() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 2);

        vm.warp(block.timestamp + 5);
        _setDefaultPrices();

        vm.prank(trader1);
        perp.closePosition(ETH_MARKET);

        PerpDEX.MarketOI memory oi = perp.getMarketOI(ETH_MARKET);
        assertEq(oi.longOI, 0);
    }

    /// @notice OI cap enforcement: 50M collateral × 5× = 250M >> 25M cap → ExceedsMaxOI.
    function test_OI_cap_exceeded_reverts() public {
        _setDefaultPrices();
        // Vault has 5M, OI cap = 5x TVL = 25M scaled.
        // Open position with size > 25M to exceed cap.
        // 5M collateral * 5x leverage = 25M, at the edge. But vault TVL calculation is
        // based on LP assets which changes when collateral enters. So let's try with a huge amount.
        cNGN.mint(trader1, 100_000_000e6);
        vm.prank(trader1);
        cNGN.approve(address(perp), type(uint256).max);

        bytes32 salt = keccak256("oi_cap_salt");
        uint256 collateral = 50_000_000e6; // 50M collateral * 5x = 250M >> 25M cap
        uint256 acceptablePrice = type(uint256).max;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash = keccak256(
            abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, uint256(5), acceptablePrice, deadline, salt)
        );

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 2);
        _setDefaultPrices();

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.ExceedsMaxOI.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, collateral, 5, acceptablePrice, deadline, salt);
    }

    /// @notice Absolute OI ceiling binds even when the TVL-multiplier would allow more — a hard
    ///         cap that transient/flash liquidity cannot lift. (Fix #2a.)
    function test_OI_absoluteCap_binds() public {
        _setDefaultPrices();

        // Tighten the absolute ceiling to 1,000,000 cNGN while the TVL-multiplier still allows
        // 25,000,000 (5M LP × 5×). A 1,500,000 position is within the multiplier but over the cap.
        vm.prank(operator);
        perp.updateMarketParams(ETH_MARKET, 5, 2e16, 5e18, 1_000_000e18, MAX_STALENESS);

        bytes32 salt = keccak256("abs_cap_salt");
        uint256 collateral = 300_000e6; // 300k × 5× = 1,500,000 internal OI > 1,000,000 absolute cap
        uint256 acceptablePrice = type(uint256).max;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash = keccak256(
            abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, uint256(5), acceptablePrice, deadline, salt)
        );

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 2);
        _setDefaultPrices();

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.ExceedsMaxOI.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, collateral, 5, acceptablePrice, deadline, salt);
    }

    /*//////////////////////////////////////////////////////////////
                         GETTER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice getPositionEquity returns 0 for empty positions.
    function test_getPositionEquity_no_position() public view {
        int256 equity = perp.getPositionEquity(ETH_MARKET, trader1);
        assertEq(equity, 0);
    }

    /// @notice getPositionEquity ≈ collateral at entry (no PnL, minimal funding).
    function test_getPositionEquity_with_position() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 2);

        int256 equity = perp.getPositionEquity(ETH_MARKET, trader1);
        // At entry, equity ≈ collateral (no PnL yet, minimal funding)
        assertApproxEqAbs(equity, int256(uint256(100_000e6)), 100); // within 100 units of token precision
    }

    /// @notice Funding is zero-sum between traders: what the dominant side pays, the minority
    ///         side receives. Mark price is held constant so price PnL is zero and equity
    ///         changes are pure funding. (Regression for the zero-sum funding redesign.)
    function test_funding_isZeroSum_betweenTraders() public {
        _setDefaultPrices();

        // Long-heavy, two-sided: longOI = 500k, shortOI = 250k (internal precision).
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 5);
        _commitAndExecuteTrade(trader2, ETH_MARKET, PerpDEX.Side.Short, 50_000e6, 5);

        // Accrue funding over time with the price unchanged (refresh oracle timestamps only).
        vm.warp(block.timestamp + 100); // < 120s staleness
        _setDefaultPrices();

        int256 eqLong = perp.getPositionEquity(ETH_MARKET, trader1);
        int256 eqShort = perp.getPositionEquity(ETH_MARKET, trader2);

        // Price PnL is zero, so funding = collateral − equity (token precision).
        int256 fundingLong = int256(uint256(100_000e6)) - eqLong; // > 0 : long pays
        int256 fundingShort = int256(uint256(50_000e6)) - eqShort; // < 0 : short receives

        assertGt(fundingLong, 0, "long should pay funding when long-heavy");
        assertLt(fundingShort, 0, "short should receive funding when long-heavy");

        // Zero-sum: longs pay exactly what shorts receive, within integer-rounding dust.
        assertApproxEqAbs(fundingLong, -fundingShort, 5, "funding must be zero-sum between traders");
    }

    /// @dev Open a Long on ETH at a specific ETH/USD price (commit-reveal, slippage opt-out).
    function _openLongEthAt(address trader, uint256 collateral, uint256 leverage, int64 ethUsd) internal {
        bytes32 salt = keccak256(abi.encode(trader, block.number, ethUsd));
        uint256 acceptablePrice = type(uint256).max;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash = keccak256(
            abi.encode(trader, ETH_MARKET, PerpDEX.Side.Long, collateral, leverage, acceptablePrice, deadline, salt)
        );
        vm.prank(trader);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 2);
        _setPythPrice(ETH_USD_FEED, ethUsd, CRYPTO_EXPO, uint64(uint64(ethUsd) / 100));
        _mockChainlinkNgnUsd(62500);
        vm.prank(trader);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, collateral, leverage, acceptablePrice, deadline, salt);
    }

    /// @notice Aggregate unrealized PnL uses the exact per-position sum (harmonic accumulator),
    ///         not a volume-weighted arithmetic mean of entry prices. (Finding 1 fix.)
    /// @dev Two equal longs at ETH=$3000 and $4000, marked at $3500:
    ///      true PnL = 200k·(3500−3000)/3000 + 200k·(3500−4000)/4000 ≈ +8,333 cNGN.
    ///      The buggy arithmetic-mean formula (avg entry $3500) would report 0.
    function test_marketUnrealizedPnL_harmonic_not_arithmetic() public {
        _openLongEthAt(trader1, 100_000e6, 2, 3000e8); // entry mark = 3000·1600 = 4.8M cNGN
        _openLongEthAt(trader2, 100_000e6, 2, 4000e8); // entry mark = 4000·1600 = 6.4M cNGN

        // Mark the market at ETH=$3500 (5.6M cNGN) with a fresh oracle.
        // Advance time so MockPyth accepts the new publishTime (it ignores same-timestamp updates).
        vm.warp(block.timestamp + 1);
        _setPythPrice(ETH_USD_FEED, 3500e8, CRYPTO_EXPO, 35e8);
        _mockChainlinkNgnUsd(62500);

        assertEq(perp.getMarkPrice(ETH_MARKET), 5_600_000e18, "mark should be 5.6M cNGN");
        int256 pnl = perp.getMarketUnrealizedPnL(ETH_MARKET);
        // ≈ +8,333.33 cNGN (6-dec). Buggy arithmetic-mean code returns ~0.
        assertApproxEqAbs(pnl, int256(8_333e6), 5e6, "aggregate PnL must equal true per-position sum");
        assertGt(pnl, int256(8_000e6), "must be materially positive, not the arithmetic-mean 0");
    }

    /// @notice getMarketVaultTVL returns the vault’s totalAssets (5M from setup).
    function test_getMarketVaultTVL() public view {
        uint256 tvl = perp.getMarketVaultTVL(ETH_MARKET);
        assertEq(tvl, 5_000_000e6);
    }

    /// @notice tradersPerMarketLength tracks the active trader set size.
    function test_tradersPerMarketLength() public {
        _setDefaultPrices();
        assertEq(perp.tradersPerMarketLength(ETH_MARKET), 0);

        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 2);
        assertEq(perp.tradersPerMarketLength(ETH_MARKET), 1);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pausing blocks requestTrade with EnforcedPause.
    function test_pause_blocks_trading() public {
        _setDefaultPrices();

        vm.prank(operator);
        perp.pause();

        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000e6;
        bytes32 orderHash = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, uint256(2), salt));

        vm.prank(trader1);
        vm.expectRevert(); // EnforcedPause
        perp.requestTrade(orderHash);
    }

    /// @notice Unpausing re-enables requestTrade.
    function test_unpause_resumes_trading() public {
        vm.prank(operator);
        perp.pause();
        vm.prank(operator);
        perp.unpause();

        // Should be able to commit again
        _setDefaultPrices();
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000e6;
        bytes32 orderHash = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, uint256(2), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash); // should not revert
    }

    /*//////////////////////////////////////////////////////////////
                      MULTI-MARKET ISOLATION TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Positions and OI are fully isolated between markets.
    function test_positions_isolated_across_markets() public {
        _setDefaultPrices();

        // Open in ETH market
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 2);

        // Open in BTC market (need a new commit since previous is consumed)
        vm.warp(block.timestamp + 5);
        _setDefaultPrices();
        _commitAndExecuteTrade(trader2, BTC_MARKET, PerpDEX.Side.Short, 50_000e6, 3);

        // Verify isolation
        PerpDEX.Position memory ethPos = perp.getPosition(ETH_MARKET, trader1);
        PerpDEX.Position memory btcPos = perp.getPosition(BTC_MARKET, trader2);

        assertEq(ethPos.collateral, 100_000e6);
        assertEq(btcPos.collateral, 50_000e6);

        // OI is per-market
        PerpDEX.MarketOI memory ethOI = perp.getMarketOI(ETH_MARKET);
        PerpDEX.MarketOI memory btcOI = perp.getMarketOI(BTC_MARKET);
        assertTrue(ethOI.longOI > 0);
        assertEq(ethOI.shortOI, 0);
        assertEq(btcOI.longOI, 0);
        assertTrue(btcOI.shortOI > 0);
    }

    /*//////////////////////////////////////////////////////////////
                           MARKET INFO GETTER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice getMarketInfo returns full config, pricing, and zero OI for an empty market.
    function test_getMarketInfo_emptyMarket() public {
        _setDefaultPrices();

        PerpDEX.MarketInfo memory info = perp.getMarketInfo(ETH_MARKET);

        // Config fields
        assertEq(info.marketId, ETH_MARKET);
        assertTrue(info.enabled);
        assertEq(info.maxLeverage, 5);
        assertEq(info.maintenanceMarginRatio, 2e16);
        assertEq(info.vault, address(ethVault));

        // Pricing
        assertEq(info.markPriceCngn, 4_800_000e18); // ETH $3000 * 1600 NGN
        assertEq(info.assetUsdPrice, 3000e18);
        assertEq(info.usdNgnRate, 1600e18);

        // No positions yet
        assertEq(info.longOI, 0);
        assertEq(info.shortOI, 0);
        assertEq(info.openTraderCount, 0);
        assertEq(info.unrealizedPnL, 0);

        // Vault has LP deposits
        assertEq(info.vaultTVL, 5_000_000e6);
        assertEq(info.collateralHeld, 0);
    }

    /// @notice getMarketInfo reflects open position state (OI, trader count, collateral).
    function test_getMarketInfo_withPositions() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);

        vm.warp(block.timestamp + 5);
        _setDefaultPrices();

        PerpDEX.MarketInfo memory info = perp.getMarketInfo(ETH_MARKET);

        // Should reflect open position
        assertGt(info.longOI, 0);
        assertEq(info.shortOI, 0);
        assertEq(info.openTraderCount, 1);
        assertEq(info.collateralHeld, 100_000e6);
        assertEq(info.markPriceCngn, 4_800_000e18);
    }

    /// @notice getMarketInfo reverts for a non-existent market ID.
    function test_getMarketInfo_nonExistentMarket_reverts() public {
        vm.expectRevert(PerpDEX.MarketNotEnabled.selector);
        perp.getMarketInfo(keccak256("NONEXISTENT"));
    }

    /// @notice ETH mark price: $3000 × 1600 = 4,800,000e18 cNGN.
    function test_getMarkPrice_perAsset_eth() public {
        _setDefaultPrices();
        uint256 ethNgn = perp.getMarkPrice(ETH_MARKET);
        assertEq(ethNgn, 4_800_000e18); // $3000 * 1600
    }

    /// @notice BTC mark price: $100k × 1600 = 160,000,000e18 cNGN.
    function test_getMarkPrice_perAsset_btc() public {
        _setDefaultPrices();
        uint256 btcNgn = perp.getMarkPrice(BTC_MARKET);
        assertEq(btcNgn, 160_000_000e18); // $100k * 1600
    }

    /// @notice Per-asset USD prices: ETH=$3000, BTC=$100k.
    function test_getAssetUsdPrice_perAsset() public {
        _setDefaultPrices();
        assertEq(perp.getAssetUsdPrice(ETH_MARKET), 3000e18);
        assertEq(perp.getAssetUsdPrice(BTC_MARKET), 100_000e18);
    }

    /// @notice Unrealized PnL is zero when no positions exist.
    function test_getMarketUnrealizedPnL_noPositions() public {
        _setDefaultPrices();
        int256 pnl = perp.getMarketUnrealizedPnL(ETH_MARKET);
        assertEq(pnl, 0);
    }

    /// @notice Unrealized PnL becomes positive when ETH rises 10% with a long open.
    function test_getMarketUnrealizedPnL_withPositions() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);

        // Price goes up 10%
        vm.warp(block.timestamp + 5);
        _setPythPrice(ETH_USD_FEED, 3300e8, CRYPTO_EXPO, 10e8);
        _mockChainlinkNgnUsd(62500);

        int256 pnl = perp.getMarketUnrealizedPnL(ETH_MARKET);
        assertGt(pnl, 0, "PnL should be positive after price increase");
    }

    /// @notice Aggregate trader loss credited to LPs is capped at recoverable collateral, so
    ///         uncollectible bad debt cannot inflate vault NAV. (Fix #1b.)
    function test_marketUnrealizedPnL_baddebt_clamped() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 5); // size 500k, collateral 100k

        // Crash ETH 3000 → 1500: raw long loss ≈ 250k cNGN, far exceeding the 100k collateral.
        vm.warp(block.timestamp + 1);
        _setPythPrice(ETH_USD_FEED, 1500e8, CRYPTO_EXPO, 15e8);
        _mockChainlinkNgnUsd(62500);

        int256 pnl = perp.getMarketUnrealizedPnL(ETH_MARKET);
        // Uncapped would be ≈ -250_000e6; clamped at -collateralHeld = -100_000e6.
        assertEq(pnl, -int256(uint256(100_000e6)), "LP credit from losses must cap at collateral");
    }

    /// @notice Liquidation remains available while the protocol is paused (LP-solvency backstop). (Fix #2.)
    function test_liquidate_works_while_paused() public {
        _setDefaultPrices();
        _commitAndExecuteTrade(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 5);

        // Drop ETH to make the position liquidatable (~1.67% margin < 2%).
        vm.warp(block.timestamp + 5);
        _setPythPrice(ETH_USD_FEED, 2450e8, CRYPTO_EXPO, 10e8);
        _mockChainlinkNgnUsd(62500);
        assertTrue(perp.isLiquidatable(ETH_MARKET, trader1));

        // Pause the protocol.
        vm.prank(operator);
        perp.pause();

        // Liquidation must still succeed despite the pause.
        vm.prank(liquidator);
        perp.liquidate(ETH_MARKET, trader1);
        assertEq(perp.getPosition(ETH_MARKET, trader1).size, 0, "position liquidated while paused");
    }

    /*//////////////////////////////////////////////////////////////
                           RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
