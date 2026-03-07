// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {cNGNVault} from "../src/cNGNVault.sol";
import {PerpDEX} from "../src/PerpDEX.sol";
import {MockcNGN} from "./mocks/MockcNGN.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {AggregatorV3Interface} from "chainlink-evm/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract PerpDEXTest is Test {
    MockcNGN public token;
    cNGNVault public vault;
    PerpDEX public perp;

    MockAggregator public btcUsdFeed;
    MockAggregator public ethUsdFeed;
    MockAggregator public solUsdFeed;
    MockAggregator public ngnUsdFeed;

    // Synthetic asset identifiers (arbitrary addresses for market keys)
    address public constant BTC = address(0xB7C);
    address public constant ETH = address(0xE74);
    address public constant SOL = address(0x501);

    address owner = makeAddr("owner");
    address trader1 = makeAddr("trader1");
    address trader2 = makeAddr("trader2");
    address lp = makeAddr("lp");
    address liquidator = makeAddr("liquidator");

    uint256 constant ONE_TOKEN = 1e6; // cNGN has 6 decimals
    uint256 constant PRECISION = 1e18;

    // Chainlink prices (8 decimals)
    int256 constant BTC_USD = 60_000e8; // $60,000
    int256 constant ETH_USD = 3_000e8; // $3,000
    int256 constant SOL_USD = 150e8; // $150
    int256 constant NGN_USD = 625e3; // $0.00625 (≈ 1600 NGN/USD)

    uint256 constant HEARTBEAT = 3600; // 1 hour

    function setUp() public {
        // Deploy token
        token = new MockcNGN();

        // Deploy vault
        vault = new cNGNVault(IERC20(address(token)));

        // Deploy price feeds
        btcUsdFeed = new MockAggregator(BTC_USD, 8);
        ethUsdFeed = new MockAggregator(ETH_USD, 8);
        solUsdFeed = new MockAggregator(SOL_USD, 8);
        ngnUsdFeed = new MockAggregator(NGN_USD, 8);

        // Deploy PerpDEX
        perp = new PerpDEX(address(token), address(vault), address(ngnUsdFeed), HEARTBEAT, owner);

        // Link vault to PerpDEX
        vault.setPerpDex(address(perp));

        // Configure assets
        vm.startPrank(owner);
        perp.configureAsset(BTC, address(btcUsdFeed), HEARTBEAT);
        perp.configureAsset(ETH, address(ethUsdFeed), HEARTBEAT);
        perp.configureAsset(SOL, address(solUsdFeed), HEARTBEAT);
        vm.stopPrank();

        // Seed LP into vault
        token.mint(lp, 10_000_000 * ONE_TOKEN);
        vm.prank(lp);
        token.approve(address(vault), type(uint256).max);
        vm.prank(lp);
        vault.deposit(5_000_000 * ONE_TOKEN, lp);

        // Fund traders
        token.mint(trader1, 1_000_000 * ONE_TOKEN);
        token.mint(trader2, 1_000_000 * ONE_TOKEN);
        vm.prank(trader1);
        token.approve(address(perp), type(uint256).max);
        vm.prank(trader2);
        token.approve(address(perp), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                         HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _commitAndExecute(
        address _trader,
        address _asset,
        PerpDEX.Side _side,
        uint256 _collateral,
        uint256 _leverage
    ) internal {
        bytes32 salt = keccak256("salt");
        bytes32 orderHash = keccak256(abi.encode(_trader, _asset, _side, _collateral, _leverage, salt));

        vm.prank(_trader);
        perp.requestTrade(orderHash);

        // Advance blocks past MIN_BLOCK_DELAY (1 block)
        vm.roll(block.number + 2);

        vm.prank(_trader);
        perp.executeTrade(_asset, _side, _collateral, _leverage, salt);
    }

    function _commitAndExecuteWithSalt(
        address _trader,
        address _asset,
        PerpDEX.Side _side,
        uint256 _collateral,
        uint256 _leverage,
        bytes32 _salt
    ) internal {
        bytes32 orderHash = keccak256(abi.encode(_trader, _asset, _side, _collateral, _leverage, _salt));

        vm.prank(_trader);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 2);

        vm.prank(_trader);
        perp.executeTrade(_asset, _side, _collateral, _leverage, _salt);
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 1: ADMIN & CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_configureAsset_success() public view {
        (,, bool enabled) = perp.assetConfigs(BTC);
        assertTrue(enabled);
        assertEq(perp.supportedAssetsLength(), 3);
    }

    function test_configureAsset_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader1));
        vm.prank(trader1);
        perp.configureAsset(makeAddr("new"), address(btcUsdFeed), HEARTBEAT);
    }

    function test_configureAsset_reconfigure() public {
        MockAggregator newFeed = new MockAggregator(BTC_USD, 8);
        vm.prank(owner);
        perp.configureAsset(BTC, address(newFeed), 7200);

        (AggregatorV3Interface feed, uint256 hb, bool enabled) = perp.assetConfigs(BTC);
        assertEq(address(feed), address(newFeed));
        assertEq(hb, 7200);
        assertTrue(enabled);
        // Should not duplicate in supportedAssets
        assertEq(perp.supportedAssetsLength(), 3);
    }

    function test_setNgnUsdFeed() public {
        MockAggregator newFeed = new MockAggregator(NGN_USD, 8);
        vm.prank(owner);
        perp.setNgnUsdFeed(address(newFeed), 7200);

        assertEq(address(perp.ngnUsdFeed()), address(newFeed));
        assertEq(perp.ngnUsdMaxHeartbeat(), 7200);
    }

    function test_pause_unpause() public {
        vm.prank(owner);
        perp.pause();

        // Should revert on paused
        bytes32 salt = keccak256("salt");
        bytes32 hash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, 100 * ONE_TOKEN, uint256(2), salt));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(trader1);
        perp.requestTrade(hash);

        vm.prank(owner);
        perp.unpause();

        // Should work after unpause
        vm.prank(trader1);
        perp.requestTrade(hash);
    }

    function test_pause_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader1));
        vm.prank(trader1);
        perp.pause();
    }

    function test_ownable2Step() public {
        vm.prank(owner);
        perp.transferOwnership(trader1);
        // Not yet transferred
        assertEq(perp.owner(), owner);

        vm.prank(trader1);
        perp.acceptOwnership();
        assertEq(perp.owner(), trader1);
    }

    /*//////////////////////////////////////////////////////////////
              SECTION 2: CHAINLINK TRIANGULATION ORACLE
    //////////////////////////////////////////////////////////////*/

    function test_getMarkPrice_btc() public view {
        uint256 price = perp.getMarkPrice(BTC);
        // BTC/USD = 60000e8, NGN/USD = 625e3 (0.00625)
        // Price_cNGN = 60000e8 * 1e18 / 625e3 = 60000e8 * 1e18 / 625000
        // = 6e12 * 1e18 / 625000 = 6e30 / 625000 = 9.6e24
        uint256 expected = (uint256(BTC_USD) * PRECISION) / uint256(NGN_USD);
        assertEq(price, expected);
    }

    function test_getMarkPrice_eth() public view {
        uint256 price = perp.getMarkPrice(ETH);
        uint256 expected = (uint256(ETH_USD) * PRECISION) / uint256(NGN_USD);
        assertEq(price, expected);
    }

    function test_getMarkPrice_sol() public view {
        uint256 price = perp.getMarkPrice(SOL);
        uint256 expected = (uint256(SOL_USD) * PRECISION) / uint256(NGN_USD);
        assertEq(price, expected);
    }

    function test_getMarkPrice_revertsForDisabledAsset() public {
        vm.expectRevert(PerpDEX.AssetNotEnabled.selector);
        perp.getMarkPrice(makeAddr("disabled"));
    }

    function test_getMarkPrice_revertsOnStaleAssetFeed() public {
        // Warp far into the future to make the feed stale
        vm.warp(block.timestamp + HEARTBEAT + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                PerpDEX.StalePrice.selector, address(btcUsdFeed), block.timestamp - HEARTBEAT - 1, HEARTBEAT
            )
        );
        perp.getMarkPrice(BTC);
    }

    function test_getMarkPrice_revertsOnStaleNgnFeed() public {
        // Update asset feed but not NGN feed
        btcUsdFeed.setAnswer(BTC_USD);
        vm.warp(block.timestamp + HEARTBEAT + 1);

        // BTC feed is stale now too, update it
        btcUsdFeed.setAnswer(BTC_USD);

        vm.expectRevert(
            abi.encodeWithSelector(
                PerpDEX.StalePrice.selector, address(ngnUsdFeed), block.timestamp - HEARTBEAT - 1, HEARTBEAT
            )
        );
        perp.getMarkPrice(BTC);
    }

    function test_getMarkPrice_revertsOnNegativePrice() public {
        btcUsdFeed.setAnswer(-1);
        vm.expectRevert(PerpDEX.InvalidPrice.selector);
        perp.getMarkPrice(BTC);
    }

    function test_getMarkPrice_revertsOnZeroPrice() public {
        btcUsdFeed.setAnswer(0);
        vm.expectRevert(PerpDEX.InvalidPrice.selector);
        perp.getMarkPrice(BTC);
    }

    function test_getMarkPrice_updatesWithNewPrices() public {
        uint256 priceBefore = perp.getMarkPrice(BTC);

        // BTC price doubles
        btcUsdFeed.setAnswer(120_000e8);

        uint256 priceAfter = perp.getMarkPrice(BTC);
        assertEq(priceAfter, priceBefore * 2);
    }

    /*//////////////////////////////////////////////////////////////
               SECTION 3: COMMIT-REVEAL ORDER FLOW
    //////////////////////////////////////////////////////////////*/

    function test_requestTrade_storesCommit() public {
        bytes32 orderHash = keccak256("order");

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        (bytes32 storedHash, uint256 commitBlock) = perp.committedOrders(trader1);
        assertEq(storedHash, orderHash);
        assertEq(commitBlock, block.number);
    }

    function test_requestTrade_emitsEvent() public {
        bytes32 orderHash = keccak256("order");

        vm.expectEmit(true, false, false, true);
        emit PerpDEX.TradeCommitted(trader1, orderHash, block.number);

        vm.prank(trader1);
        perp.requestTrade(orderHash);
    }

    function test_executeTrade_revertsNoCommit() public {
        vm.expectRevert(PerpDEX.NoCommittedOrder.selector);
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, 100 * ONE_TOKEN, 2, keccak256("salt"));
    }

    function test_executeTrade_revertsTooEarly() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000 * ONE_TOKEN;
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        // Don't advance blocks — try executing in same block
        vm.expectRevert(PerpDEX.TooEarlyToExecute.selector);
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, 2, salt);
    }

    function test_executeTrade_revertsAfterExpiry() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000 * ONE_TOKEN;
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        // Advance past MAX_BLOCK_DELAY
        vm.roll(block.number + 21);

        vm.expectRevert(PerpDEX.OrderExpired.selector);
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, 2, salt);
    }

    function test_executeTrade_revertsOnHashMismatch() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000 * ONE_TOKEN;
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 2);

        // Reveal with wrong leverage
        vm.expectRevert(PerpDEX.OrderHashMismatch.selector);
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, 3, salt);
    }

    function test_executeTrade_revertsOnHashMismatch_wrongAsset() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000 * ONE_TOKEN;
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 2);

        vm.expectRevert(PerpDEX.OrderHashMismatch.selector);
        vm.prank(trader1);
        perp.executeTrade(ETH, PerpDEX.Side.Long, collateral, 2, salt);
    }

    function test_executeTrade_revertsOnHashMismatch_wrongSide() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000 * ONE_TOKEN;
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 2);

        vm.expectRevert(PerpDEX.OrderHashMismatch.selector);
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Short, collateral, 2, salt);
    }

    function test_executeTrade_clearsCommit() public {
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, 100_000 * ONE_TOKEN, 2);

        (bytes32 hash, uint256 commitBlk) = perp.committedOrders(trader1);
        assertEq(hash, bytes32(0));
        assertEq(commitBlk, 0);
    }

    /*//////////////////////////////////////////////////////////////
             SECTION 4: POSITION OPENING & STATE
    //////////////////////////////////////////////////////////////*/

    function test_openLong_positionStored() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 3);

        PerpDEX.Position memory pos = perp.getPosition(BTC, trader1);
        assertEq(pos.collateral, collateral);
        assertEq(pos.size, uint256(collateral) * 1e12 * 3); // scaled + leverage
        assertEq(uint8(pos.side), uint8(PerpDEX.Side.Long));
        assertGt(pos.averagePrice, 0);
    }

    function test_openShort_positionStored() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, ETH, PerpDEX.Side.Short, collateral, 5);

        PerpDEX.Position memory pos = perp.getPosition(ETH, trader1);
        assertEq(pos.collateral, collateral);
        assertEq(uint8(pos.side), uint8(PerpDEX.Side.Short));
        assertEq(pos.size, uint256(collateral) * 1e12 * 5);
    }

    function test_openPosition_collateralTransferred() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        uint256 balBefore = token.balanceOf(trader1);
        uint256 vaultBefore = token.balanceOf(address(vault));

        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        assertEq(token.balanceOf(trader1), balBefore - collateral);
        assertEq(token.balanceOf(address(vault)), vaultBefore + collateral);
    }

    function test_openPosition_revertsExceedsMaxLeverage() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000 * ONE_TOKEN;
        uint256 leverage = 6; // > MAX_LEVERAGE
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, leverage, salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 2);

        vm.expectRevert(PerpDEX.ExceedsMaxLeverage.selector);
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, leverage, salt);
    }

    function test_openPosition_revertsZeroLeverage() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000 * ONE_TOKEN;
        uint256 leverage = 0;
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, leverage, salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 2);

        vm.expectRevert(PerpDEX.ExceedsMaxLeverage.selector);
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, leverage, salt);
    }

    function test_openPosition_revertsZeroCollateral() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 0;
        uint256 leverage = 2;
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, leverage, salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 2);

        vm.expectRevert(PerpDEX.ZeroAmount.selector);
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, leverage, salt);
    }

    function test_openPosition_revertsPositionAlreadyOpen() public {
        uint256 collateral = 50_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        // Try opening second position on same asset
        bytes32 salt = keccak256("salt2");
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);

        vm.expectRevert(PerpDEX.PositionAlreadyOpen.selector);
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, 2, salt);
    }

    function test_openPosition_multipleAssetsAllowed() public {
        uint256 collateral = 50_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);
        _commitAndExecuteWithSalt(trader1, ETH, PerpDEX.Side.Short, collateral, 3, keccak256("salt2"));

        PerpDEX.Position memory btcPos = perp.getPosition(BTC, trader1);
        PerpDEX.Position memory ethPos = perp.getPosition(ETH, trader1);
        assertGt(btcPos.size, 0);
        assertGt(ethPos.size, 0);
    }

    function test_openPosition_emitsEvent() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        bytes32 salt = keccak256("salt");
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);

        uint256 expectedSize = uint256(collateral) * 1e12 * 2;
        uint256 expectedPrice = (uint256(BTC_USD) * PRECISION) / uint256(NGN_USD);

        vm.expectEmit(true, true, false, true);
        emit PerpDEX.PositionOpened(trader1, BTC, PerpDEX.Side.Long, expectedSize, collateral, expectedPrice);

        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, 2, salt);
    }

    /*//////////////////////////////////////////////////////////////
            SECTION 5: OPEN INTEREST TRACKING
    //////////////////////////////////////////////////////////////*/

    function test_OI_increasesOnOpen() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        PerpDEX.MarketOI memory moi = perp.getMarketOI(BTC);
        uint256 expectedSize = uint256(collateral) * 1e12 * 2;
        assertEq(moi.longOI, expectedSize);
        assertEq(moi.shortOI, 0);
    }

    function test_OI_bothSides() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);
        _commitAndExecuteWithSalt(trader2, BTC, PerpDEX.Side.Short, collateral, 3, keccak256("salt2"));

        PerpDEX.MarketOI memory moi = perp.getMarketOI(BTC);
        assertEq(moi.longOI, uint256(collateral) * 1e12 * 2);
        assertEq(moi.shortOI, uint256(collateral) * 1e12 * 3);
    }

    function test_OI_decreasesOnClose() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        vm.prank(trader1);
        perp.closePosition(BTC);

        PerpDEX.MarketOI memory moi = perp.getMarketOI(BTC);
        assertEq(moi.longOI, 0);
    }

    /*//////////////////////////////////////////////////////////////
            SECTION 6: PNL — LONG POSITIONS
    //////////////////////////////////////////////////////////////*/

    function test_long_profitOnPriceUp() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        uint256 balBefore = token.balanceOf(trader1);

        // BTC goes up 10%
        btcUsdFeed.setAnswer(66_000e8);

        vm.prank(trader1);
        perp.closePosition(BTC);

        uint256 balAfter = token.balanceOf(trader1);
        // With 2x leverage, 10% up → ~20% profit on collateral
        assertGt(balAfter, balBefore + collateral);
    }

    function test_long_lossOnPriceDown() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        uint256 balBefore = token.balanceOf(trader1);

        // BTC goes down 5%
        btcUsdFeed.setAnswer(57_000e8);

        vm.prank(trader1);
        perp.closePosition(BTC);

        uint256 balAfter = token.balanceOf(trader1);
        uint256 received = balAfter - balBefore;
        // With 2x leverage, 5% down → 10% loss → receive ~90% of collateral
        assertLt(received, collateral);
        assertGt(received, 0);
    }

    function test_long_breakeven() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        uint256 balBefore = token.balanceOf(trader1);

        // Price unchanged
        vm.prank(trader1);
        perp.closePosition(BTC);

        uint256 balAfter = token.balanceOf(trader1);
        // Should get back approximately the collateral (minus any precision rounding)
        assertApproxEqAbs(balAfter - balBefore, collateral, 1);
    }

    /*//////////////////////////////////////////////////////////////
            SECTION 7: PNL — SHORT POSITIONS
    //////////////////////////////////////////////////////////////*/

    function test_short_profitOnPriceDown() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, ETH, PerpDEX.Side.Short, collateral, 3);

        uint256 balBefore = token.balanceOf(trader1);

        // ETH goes down 10%
        ethUsdFeed.setAnswer(2_700e8);

        vm.prank(trader1);
        perp.closePosition(ETH);

        uint256 balAfter = token.balanceOf(trader1);
        // 3x leverage, 10% down → ~30% profit
        assertGt(balAfter - balBefore, collateral);
    }

    function test_short_lossOnPriceUp() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, ETH, PerpDEX.Side.Short, collateral, 3);

        uint256 balBefore = token.balanceOf(trader1);

        // ETH goes up 5%
        ethUsdFeed.setAnswer(3_150e8);

        vm.prank(trader1);
        perp.closePosition(ETH);

        uint256 balAfter = token.balanceOf(trader1);
        uint256 received = balAfter - balBefore;
        // 3x leverage, 5% up → 15% loss
        assertLt(received, collateral);
        assertGt(received, 0);
    }

    /*//////////////////////////////////////////////////////////////
               SECTION 8: CLOSE POSITION
    //////////////////////////////////////////////////////////////*/

    function test_closePosition_clearsPosition() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        vm.prank(trader1);
        perp.closePosition(BTC);

        PerpDEX.Position memory pos = perp.getPosition(BTC, trader1);
        assertEq(pos.size, 0);
        assertEq(pos.collateral, 0);
    }

    function test_closePosition_revertsNoPosition() public {
        vm.expectRevert(PerpDEX.NoOpenPosition.selector);
        vm.prank(trader1);
        perp.closePosition(BTC);
    }

    function test_closePosition_emitsEvent() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        uint256 expectedPrice = (uint256(BTC_USD) * PRECISION) / uint256(NGN_USD);

        vm.expectEmit(true, true, false, false);
        emit PerpDEX.PositionClosed(trader1, BTC, 0, expectedPrice);

        vm.prank(trader1);
        perp.closePosition(BTC);
    }

    function test_closePosition_settlesPnLOnVault() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        int256 pnlBefore = vault.globalTraderPnL();

        // Breakeven close → PnL should still be settled (as 0)
        vm.prank(trader1);
        perp.closePosition(BTC);

        int256 pnlAfter = vault.globalTraderPnL();
        // PnL should be settled (could be 0 for breakeven)
        assertEq(pnlAfter - pnlBefore, 0);
    }

    function test_closePosition_vaultPnLPositiveOnTraderProfit() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        // Price goes up
        btcUsdFeed.setAnswer(66_000e8);

        vm.prank(trader1);
        perp.closePosition(BTC);

        // Vault's globalTraderPnL should be positive (traders profited)
        assertGt(vault.globalTraderPnL(), 0);
    }

    function test_closePosition_whenPaused_reverts() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        vm.prank(owner);
        perp.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(trader1);
        perp.closePosition(BTC);
    }

    /*//////////////////////////////////////////////////////////////
              SECTION 9: LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function test_liquidate_underwaterLong() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);

        // 5x leverage → 20% drop wipes out collateral (actually, maintenance margin is 2%)
        // At 5x, need price to drop enough that equity < 2% of size
        // equity = collateral + PnL = collateral + size * (price-entry)/entry
        // For equity = 0: price drops by collateral/size = 1/5 = 20%
        // For maintenance margin: equity/size < 2%
        // Need price drop of about 19.6% → let's do 19.5%
        btcUsdFeed.setAnswer(48_300e8); // ~19.5% drop

        assertTrue(perp.isLiquidatable(BTC, trader1));

        uint256 liqBalBefore = token.balanceOf(liquidator);

        vm.prank(liquidator);
        perp.liquidate(BTC, trader1);

        // Position should be cleared
        PerpDEX.Position memory pos = perp.getPosition(BTC, trader1);
        assertEq(pos.size, 0);

        // Liquidator should have received a bounty
        uint256 liqBalAfter = token.balanceOf(liquidator);
        assertGe(liqBalAfter, liqBalBefore);
    }

    function test_liquidate_underwaterShort() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, ETH, PerpDEX.Side.Short, collateral, 5);

        // 5x short: price up ~19.5% should make it liquidatable
        ethUsdFeed.setAnswer(3_585e8); // 19.5% up

        assertTrue(perp.isLiquidatable(ETH, trader1));

        vm.prank(liquidator);
        perp.liquidate(ETH, trader1);

        PerpDEX.Position memory pos = perp.getPosition(ETH, trader1);
        assertEq(pos.size, 0);
    }

    function test_liquidate_revertsNotLiquidatable() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        // Price unchanged → healthy position
        assertFalse(perp.isLiquidatable(BTC, trader1));

        vm.expectRevert(PerpDEX.NotLiquidatable.selector);
        vm.prank(liquidator);
        perp.liquidate(BTC, trader1);
    }

    function test_liquidate_revertsNoPosition() public {
        vm.expectRevert(PerpDEX.NoOpenPosition.selector);
        vm.prank(liquidator);
        perp.liquidate(BTC, trader1);
    }

    function test_liquidate_bountyPaid() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);

        // Drop price ~19.5% with 5x → PnL = -97.5% → equity = 2.5% of collateral
        // equity/size = 0.5% < maintenance margin 2% → liquidatable, but equity > 0
        btcUsdFeed.setAnswer(48_300e8);

        assertTrue(perp.isLiquidatable(BTC, trader1));

        uint256 liqBalBefore = token.balanceOf(liquidator);
        uint256 traderBalBefore = token.balanceOf(trader1);

        vm.prank(liquidator);
        perp.liquidate(BTC, trader1);

        uint256 liqBalAfter = token.balanceOf(liquidator);
        uint256 traderBalAfter = token.balanceOf(trader1);

        // Liquidator earned a bounty
        uint256 bounty = liqBalAfter - liqBalBefore;
        assertGt(bounty, 0);

        // Trader received remaining (minus bounty)
        uint256 traderReceived = traderBalAfter - traderBalBefore;
        // trader + liquidator combined should be roughly what's left of equity
        assertGt(traderReceived + bounty, 0);
    }

    function test_liquidate_emitsEvent() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);

        // ~19.5% drop → liquidatable
        btcUsdFeed.setAnswer(48_300e8);

        // Only check indexed params (trader, asset, liquidator), not data
        vm.expectEmit(true, true, true, false);
        emit PerpDEX.PositionLiquidated(trader1, BTC, liquidator, 0, 0);

        vm.prank(liquidator);
        perp.liquidate(BTC, trader1);
    }

    function test_liquidate_fullLoss_noRemainder() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);

        // 25% drop → 5x leverage → 125% loss of collateral → equity < 0
        btcUsdFeed.setAnswer(45_000e8);

        assertTrue(perp.isLiquidatable(BTC, trader1));

        uint256 traderBalBefore = token.balanceOf(trader1);
        uint256 liqBalBefore = token.balanceOf(liquidator);

        vm.prank(liquidator);
        perp.liquidate(BTC, trader1);

        // Equity is negative → trader receives 0, liquidator bounty = 0
        assertEq(token.balanceOf(trader1), traderBalBefore);
        assertEq(token.balanceOf(liquidator), liqBalBefore);
    }

    function test_isLiquidatable_noPosition_returnsFalse() public view {
        assertFalse(perp.isLiquidatable(BTC, trader1));
    }

    function test_liquidate_updatesOI() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);

        PerpDEX.MarketOI memory oiBefore = perp.getMarketOI(BTC);
        assertGt(oiBefore.longOI, 0);

        // ~19.5% drop → liquidatable
        btcUsdFeed.setAnswer(48_300e8);

        vm.prank(liquidator);
        perp.liquidate(BTC, trader1);

        PerpDEX.MarketOI memory oiAfter = perp.getMarketOI(BTC);
        assertEq(oiAfter.longOI, 0);
    }

    /*//////////////////////////////////////////////////////////////
              SECTION 10: FUNDING RATE
    //////////////////////////////////////////////////////////////*/

    function test_funding_noImbalance_noFunding() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        // Open equal long and short positions
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);
        _commitAndExecuteWithSalt(trader2, BTC, PerpDEX.Side.Short, collateral, 2, keccak256("salt2"));

        // Advance time
        vm.warp(block.timestamp + 3600);

        // Close trader1 → funding should be ~0 since balanced OI
        uint256 balBefore = token.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(BTC);
        uint256 received1 = token.balanceOf(trader1) - balBefore;

        // Breakeven price → should get back ~collateral
        assertApproxEqRel(received1, collateral, 1e15); // within 0.1%
    }

    function test_funding_longDominant_longsPay() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        // Trader1 opens a large long
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);
        // Trader2 opens a smaller short
        _commitAndExecuteWithSalt(trader2, BTC, PerpDEX.Side.Short, collateral, 1, keccak256("salt2"));

        // Advance time significantly for funding to accrue
        vm.warp(block.timestamp + 86400); // 1 day
        // Refresh feeds so they aren't stale
        btcUsdFeed.setAnswer(BTC_USD);
        ngnUsdFeed.setAnswer(NGN_USD);

        uint256 balBefore1 = token.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(BTC);
        uint256 received1 = token.balanceOf(trader1) - balBefore1;

        // Long pays funding → receives less than collateral
        assertLt(received1, collateral);
    }

    function test_funding_shortDominant_shortsPay() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        // Trader1 opens a small long
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 1);
        // Trader2 opens a large short
        _commitAndExecuteWithSalt(trader2, BTC, PerpDEX.Side.Short, collateral, 5, keccak256("salt2"));

        // Advance time
        vm.warp(block.timestamp + 86400);
        // Refresh feeds so they aren't stale
        btcUsdFeed.setAnswer(BTC_USD);
        ngnUsdFeed.setAnswer(NGN_USD);

        uint256 balBefore2 = token.balanceOf(trader2);
        vm.prank(trader2);
        perp.closePosition(BTC);
        uint256 received2 = token.balanceOf(trader2) - balBefore2;

        // Short pays funding → receives less than collateral
        assertLt(received2, collateral);
    }

    function test_funding_fundingIndexUpdates() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);

        PerpDEX.MarketOI memory oiBefore = perp.getMarketOI(BTC);

        // Advance time → next state update will accrue funding
        vm.warp(block.timestamp + 3600);

        // Trigger funding update by opening another position
        _commitAndExecuteWithSalt(trader2, BTC, PerpDEX.Side.Short, collateral, 1, keccak256("salt2"));

        PerpDEX.MarketOI memory oiAfter = perp.getMarketOI(BTC);

        // Funding index should have changed (longs > shorts → positive index)
        assertGt(oiAfter.fundingIndex, oiBefore.fundingIndex);
    }

    function test_funding_linearOverTime() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);

        // Close after 1 hour
        vm.warp(block.timestamp + 3600);
        btcUsdFeed.setAnswer(BTC_USD);
        ngnUsdFeed.setAnswer(NGN_USD);
        uint256 bal1 = token.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(BTC);
        uint256 fundingLoss1h = collateral - (token.balanceOf(trader1) - bal1);

        // Reopen same position
        token.mint(trader1, collateral); // replenish
        vm.prank(trader1);
        token.approve(address(perp), type(uint256).max);
        _commitAndExecuteWithSalt(trader1, BTC, PerpDEX.Side.Long, collateral, 5, keccak256("salt3"));

        // Close after 2 hours
        vm.warp(block.timestamp + 7200);
        btcUsdFeed.setAnswer(BTC_USD);
        ngnUsdFeed.setAnswer(NGN_USD);
        uint256 bal2 = token.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(BTC);
        uint256 fundingLoss2h = collateral - (token.balanceOf(trader1) - bal2);

        // Funding over 2h should be roughly 2x funding over 1h
        assertApproxEqRel(fundingLoss2h, fundingLoss1h * 2, 5e16); // within 5%
    }

    /*//////////////////////////////////////////////////////////////
            SECTION 11: MULTI-ASSET & MULTI-TRADER
    //////////////////////////////////////////////////////////////*/

    function test_multiAsset_independentPositions() public {
        uint256 collateral = 50_000 * ONE_TOKEN;

        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);
        _commitAndExecuteWithSalt(trader1, ETH, PerpDEX.Side.Short, collateral, 3, keccak256("salt2"));
        _commitAndExecuteWithSalt(trader1, SOL, PerpDEX.Side.Long, collateral, 1, keccak256("salt3"));

        PerpDEX.Position memory btcP = perp.getPosition(BTC, trader1);
        PerpDEX.Position memory ethP = perp.getPosition(ETH, trader1);
        PerpDEX.Position memory solP = perp.getPosition(SOL, trader1);

        assertGt(btcP.size, 0);
        assertGt(ethP.size, 0);
        assertGt(solP.size, 0);

        // Close only BTC — other positions unaffected
        vm.prank(trader1);
        perp.closePosition(BTC);

        btcP = perp.getPosition(BTC, trader1);
        ethP = perp.getPosition(ETH, trader1);
        assertEq(btcP.size, 0);
        assertGt(ethP.size, 0);
    }

    function test_multiTrader_sameSide() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);
        _commitAndExecuteWithSalt(trader2, BTC, PerpDEX.Side.Long, collateral, 3, keccak256("salt2"));

        PerpDEX.MarketOI memory moi = perp.getMarketOI(BTC);
        uint256 expected = uint256(collateral) * 1e12 * 2 + uint256(collateral) * 1e12 * 3;
        assertEq(moi.longOI, expected);
        assertEq(moi.shortOI, 0);
    }

    function test_multiTrader_opposingSides_settleIndependently() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);
        _commitAndExecuteWithSalt(trader2, BTC, PerpDEX.Side.Short, collateral, 2, keccak256("salt2"));

        // BTC goes up 10% → long profits, short loses
        btcUsdFeed.setAnswer(66_000e8);

        uint256 bal1Before = token.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(BTC);
        uint256 trader1Received = token.balanceOf(trader1) - bal1Before;

        uint256 bal2Before = token.balanceOf(trader2);
        vm.prank(trader2);
        perp.closePosition(BTC);
        uint256 trader2Received = token.balanceOf(trader2) - bal2Before;

        // Trader1 (long) should profit
        assertGt(trader1Received, collateral);
        // Trader2 (short) should lose
        assertLt(trader2Received, collateral);
    }

    /*//////////////////////////////////////////////////////////////
          SECTION 12: PRECISION & EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_precision_smallCollateral() public {
        // 1 cNGN = 1e6 (minimum meaningful amount)
        uint256 collateral = 1 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 1);

        PerpDEX.Position memory pos = perp.getPosition(BTC, trader1);
        assertGt(pos.size, 0);
        assertGt(pos.averagePrice, 0);

        vm.prank(trader1);
        perp.closePosition(BTC);

        // Should get back ~1 token (minus rounding)
        uint256 bal = token.balanceOf(trader1);
        assertApproxEqAbs(bal, 1_000_000 * ONE_TOKEN, 1);
    }

    function test_precision_highPriceAsset() public {
        // Set BTC to $100,000
        btcUsdFeed.setAnswer(100_000e8);
        uint256 collateral = 100_000 * ONE_TOKEN;

        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);

        PerpDEX.Position memory pos = perp.getPosition(BTC, trader1);
        assertGt(pos.size, 0);
        assertGt(pos.averagePrice, 0);
    }

    function test_precision_lowPriceAsset() public {
        // Set SOL to $0.50
        solUsdFeed.setAnswer(5e7); // 0.5e8
        uint256 collateral = 100_000 * ONE_TOKEN;

        _commitAndExecute(trader1, SOL, PerpDEX.Side.Short, collateral, 3);

        PerpDEX.Position memory pos = perp.getPosition(SOL, trader1);
        assertGt(pos.size, 0);
    }

    function test_canReopenAfterClose() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        vm.prank(trader1);
        perp.closePosition(BTC);

        // Reopen
        _commitAndExecuteWithSalt(trader1, BTC, PerpDEX.Side.Short, collateral / 2, 3, keccak256("salt2"));

        PerpDEX.Position memory pos = perp.getPosition(BTC, trader1);
        assertGt(pos.size, 0);
        assertEq(uint8(pos.side), uint8(PerpDEX.Side.Short));
    }

    /*//////////////////////////////////////////////////////////////
          SECTION 13: VAULT-DEX INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function test_vaultBalance_afterTraderProfit() public {
        uint256 vaultBalBefore = token.balanceOf(address(vault));
        uint256 collateral = 100_000 * ONE_TOKEN;

        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        // BTC up 10% → trader profits
        btcUsdFeed.setAnswer(66_000e8);

        vm.prank(trader1);
        perp.closePosition(BTC);

        uint256 vaultBalAfter = token.balanceOf(address(vault));
        // Vault should have paid out more than it received (net loss for LPs)
        assertLt(vaultBalAfter, vaultBalBefore + collateral);
    }

    function test_vaultBalance_afterTraderLoss() public {
        uint256 vaultBalBefore = token.balanceOf(address(vault));
        uint256 collateral = 100_000 * ONE_TOKEN;

        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        // BTC down 10% → trader loses
        btcUsdFeed.setAnswer(54_000e8);

        vm.prank(trader1);
        perp.closePosition(BTC);

        uint256 vaultBalAfter = token.balanceOf(address(vault));
        // Vault gained from the trader's loss
        assertGt(vaultBalAfter, vaultBalBefore);
    }

    function test_lpSharePrice_reflectsTraderPnL() public {
        uint256 collateral = 100_000 * ONE_TOKEN;

        uint256 sharesBefore = vault.balanceOf(lp);
        uint256 previewBefore = vault.previewRedeem(sharesBefore);

        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 3);

        // Trader profits big → LP share value goes down
        btcUsdFeed.setAnswer(72_000e8); // 20% up → 60% leveraged profit
        vm.prank(trader1);
        perp.closePosition(BTC);

        uint256 previewAfter = vault.previewRedeem(sharesBefore);
        assertLt(previewAfter, previewBefore);
    }

    /*//////////////////////////////////////////////////////////////
          SECTION 14: FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_openClose_noFundsLost(uint256 collateral, uint8 leverageRaw) public {
        // Bound collateral: 1 cNGN to 500k cNGN
        collateral = bound(collateral, 1 * ONE_TOKEN, 500_000 * ONE_TOKEN);
        uint256 leverage = bound(uint256(leverageRaw), 1, 5);

        uint256 systemBalBefore = token.balanceOf(address(vault)) + token.balanceOf(trader1);

        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, leverage);

        vm.prank(trader1);
        perp.closePosition(BTC);

        uint256 systemBalAfter = token.balanceOf(address(vault)) + token.balanceOf(trader1);

        // Conservation: no tokens created or destroyed (within rounding)
        assertApproxEqAbs(systemBalAfter, systemBalBefore, 1);
    }

    function testFuzz_priceChange_longPnL(uint256 newPriceBps) public {
        // newPriceBps: 5000 (50%) to 15000 (150%) of original → ±50% move
        newPriceBps = bound(newPriceBps, 5000, 15000);

        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        // Adjust BTC price
        int256 newPrice = BTC_USD * int256(newPriceBps) / 10000;
        btcUsdFeed.setAnswer(newPrice);

        uint256 balBefore = token.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(BTC);
        uint256 received = token.balanceOf(trader1) - balBefore;

        if (newPriceBps > 10000) {
            // Price went up → long profits
            assertGe(received, collateral);
        } else if (newPriceBps < 10000) {
            // Price went down → long loses
            assertLe(received, collateral);
        }
    }

    function testFuzz_priceChange_shortPnL(uint256 newPriceBps) public {
        newPriceBps = bound(newPriceBps, 5000, 15000);

        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, ETH, PerpDEX.Side.Short, collateral, 2);

        int256 newPrice = ETH_USD * int256(newPriceBps) / 10000;
        ethUsdFeed.setAnswer(newPrice);

        uint256 balBefore = token.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(ETH);
        uint256 received = token.balanceOf(trader1) - balBefore;

        if (newPriceBps < 10000) {
            // Price went down → short profits
            assertGe(received, collateral);
        } else if (newPriceBps > 10000) {
            // Price went up → short loses
            assertLe(received, collateral);
        }
    }

    /*//////////////////////////////////////////////////////////////
          SECTION 15: REENTRANCY / SECURITY
    //////////////////////////////////////////////////////////////*/

    function test_executeTrade_whenPaused_reverts() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000 * ONE_TOKEN;
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);

        vm.prank(owner);
        perp.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, 2, salt);
    }

    function test_liquidate_whenPaused_reverts() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);

        btcUsdFeed.setAnswer(49_200e8);

        vm.prank(owner);
        perp.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(liquidator);
        perp.liquidate(BTC, trader1);
    }

    function test_commitReplace_overwritesPreviousCommit() public {
        bytes32 hash1 = keccak256("order1");
        bytes32 hash2 = keccak256("order2");

        vm.prank(trader1);
        perp.requestTrade(hash1);

        vm.prank(trader1);
        perp.requestTrade(hash2);

        (bytes32 storedHash,) = perp.committedOrders(trader1);
        assertEq(storedHash, hash2);
    }

    function test_executeAtExactMinDelay() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000 * ONE_TOKEN;
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        uint256 commitBlock = block.number;
        vm.prank(trader1);
        perp.requestTrade(orderHash);

        // Advance exactly MIN_BLOCK_DELAY + 1 blocks (need block.number > commitBlock + 1)
        vm.roll(commitBlock + 2);

        // Should succeed
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, 2, salt);

        PerpDEX.Position memory pos = perp.getPosition(BTC, trader1);
        assertGt(pos.size, 0);
    }

    function test_executeAtExactMaxDelay() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000 * ONE_TOKEN;
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        uint256 commitBlock = block.number;
        vm.prank(trader1);
        perp.requestTrade(orderHash);

        // Advance to exactly MAX_BLOCK_DELAY
        vm.roll(commitBlock + 20);

        // Should succeed (block.number == commitBlock + 20, which is <= commitBlock + MAX_BLOCK_DELAY)
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, 2, salt);

        PerpDEX.Position memory pos = perp.getPosition(BTC, trader1);
        assertGt(pos.size, 0);
    }

    function test_executeOneBlockPastMaxDelay_reverts() public {
        bytes32 salt = keccak256("salt");
        uint256 collateral = 100_000 * ONE_TOKEN;
        bytes32 orderHash = keccak256(abi.encode(trader1, BTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        uint256 commitBlock = block.number;
        vm.prank(trader1);
        perp.requestTrade(orderHash);

        vm.roll(commitBlock + 21);

        vm.expectRevert(PerpDEX.OrderExpired.selector);
        vm.prank(trader1);
        perp.executeTrade(BTC, PerpDEX.Side.Long, collateral, 2, salt);
    }

    /*//////////////////////////////////////////////////////////////
          SECTION 16: NGN PRICE SENSITIVITY
    //////////////////////////////////////////////////////////////*/

    function test_ngnPriceChange_affectsMarkPrice() public {
        uint256 priceBefore = perp.getMarkPrice(BTC);

        // NGN strengthens (NGN/USD goes up → fewer NGN per dollar)
        ngnUsdFeed.setAnswer(1250e3); // doubled to 0.0125

        uint256 priceAfter = perp.getMarkPrice(BTC);

        // If NGN is stronger, asset price in cNGN should be lower (fewer cNGN per BTC)
        assertLt(priceAfter, priceBefore);
        assertEq(priceAfter, priceBefore / 2);
    }

    function test_ngnPriceChange_impactsPnL() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        // NGN weakens → cNGN mark price goes up → long profits
        ngnUsdFeed.setAnswer(500e3); // weaker NGN (0.005 vs 0.00625)

        uint256 balBefore = token.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(BTC);
        uint256 received = token.balanceOf(trader1) - balBefore;

        assertGt(received, collateral);
    }

    /*//////////////////////////////////////////////////////////////
         SECTION 17: GLOBAL AVG PRICES & UNREALIZED PNL
    //////////////////////////////////////////////////////////////*/

    function test_avgPrice_setOnFirstOpen() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        uint256 expectedPrice = perp.getMarkPrice(BTC);

        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        PerpDEX.MarketOI memory moi = perp.getMarketOI(BTC);
        assertEq(moi.avgLongPrice, expectedPrice);
        assertEq(moi.avgShortPrice, 0); // no shorts
    }

    function test_avgPrice_weightedOnSecondOpen() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);
        uint256 price1 = perp.getMarkPrice(BTC);

        // Change price for second trader
        btcUsdFeed.setAnswer(66_000e8);
        uint256 price2 = perp.getMarkPrice(BTC);

        _commitAndExecuteWithSalt(trader2, BTC, PerpDEX.Side.Long, collateral, 2, keccak256("salt2"));

        uint256 size1 = uint256(collateral) * 1e12 * 2;
        uint256 size2 = uint256(collateral) * 1e12 * 2; // same size
        uint256 expectedAvg = (price1 * size1 + price2 * size2) / (size1 + size2);

        PerpDEX.MarketOI memory moi = perp.getMarketOI(BTC);
        assertEq(moi.avgLongPrice, expectedAvg);
    }

    function test_avgPrice_clearedWhenAllClosed() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        vm.prank(trader1);
        perp.closePosition(BTC);

        PerpDEX.MarketOI memory moi = perp.getMarketOI(BTC);
        assertEq(moi.avgLongPrice, 0);
    }

    function test_avgPrice_shortTrackedSeparately() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);
        _commitAndExecuteWithSalt(trader2, BTC, PerpDEX.Side.Short, collateral, 3, keccak256("s2"));

        PerpDEX.MarketOI memory moi = perp.getMarketOI(BTC);
        uint256 markPrice = perp.getMarkPrice(BTC);
        assertEq(moi.avgLongPrice, markPrice);
        assertEq(moi.avgShortPrice, markPrice);
    }

    function test_totalCollateralHeld_trackedOnOpen() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        assertEq(perp.totalCollateralHeld(), 0);

        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);
        assertEq(perp.totalCollateralHeld(), collateral);

        _commitAndExecuteWithSalt(trader2, ETH, PerpDEX.Side.Short, collateral, 3, keccak256("s2"));
        assertEq(perp.totalCollateralHeld(), collateral * 2);
    }

    function test_totalCollateralHeld_clearedOnClose() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);
        assertEq(perp.totalCollateralHeld(), collateral);

        vm.prank(trader1);
        perp.closePosition(BTC);
        assertEq(perp.totalCollateralHeld(), 0);
    }

    function test_totalCollateralHeld_clearedOnLiquidation() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);
        assertEq(perp.totalCollateralHeld(), collateral);

        btcUsdFeed.setAnswer(48_300e8); // ~19.5% drop → liquidatable

        vm.prank(liquidator);
        perp.liquidate(BTC, trader1);
        assertEq(perp.totalCollateralHeld(), 0);
    }

    function test_getGlobalUnrealizedPnL_zeroWhenNoPositions() public view {
        assertEq(perp.getGlobalUnrealizedPnL(), 0);
    }

    function test_getGlobalUnrealizedPnL_zeroAtSamePrice() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        // Same price → unrealized PnL = 0
        assertEq(perp.getGlobalUnrealizedPnL(), 0);
    }

    function test_getGlobalUnrealizedPnL_positiveOnLongProfit() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        // BTC goes up 10% → longs have unrealized profit
        btcUsdFeed.setAnswer(66_000e8);

        int256 unrealized = perp.getGlobalUnrealizedPnL();
        assertGt(unrealized, 0);

        // Size = 200k scaled. PnL = 200k * 10% = 20k (in 18 dec) → 20k (in 6 dec)
        // Expected: 20_000 * ONE_TOKEN
        assertEq(unrealized, int256(20_000 * ONE_TOKEN));
    }

    function test_getGlobalUnrealizedPnL_negativeOnLongLoss() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        // BTC goes down 10% → longs have unrealized loss
        btcUsdFeed.setAnswer(54_000e8);

        int256 unrealized = perp.getGlobalUnrealizedPnL();
        assertLt(unrealized, 0);
    }

    function test_getGlobalUnrealizedPnL_balancedOI_netZero() public {
        uint256 collateral = 100_000 * ONE_TOKEN;
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);
        _commitAndExecuteWithSalt(trader2, BTC, PerpDEX.Side.Short, collateral, 2, keccak256("s2"));

        // Price moves → longs profit, shorts lose by same amount
        btcUsdFeed.setAnswer(66_000e8);

        // With equal OI and same entry price, net unrealized PnL should be ~0
        int256 unrealized = perp.getGlobalUnrealizedPnL();
        assertApproxEqAbs(unrealized, 0, 1); // within rounding
    }

    function test_vaultTotalAssets_reflectsUnrealizedPnL() public {
        uint256 lpDeposit = 5_000_000 * ONE_TOKEN;
        uint256 collateral = 100_000 * ONE_TOKEN;

        // LP deposited in setUp. totalAssets = 5M initially.
        uint256 totalAssetsBefore = vault.totalAssets();

        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 2);

        // Same price → unrealized PnL = 0. totalAssets = balance - collateral - 0 = 5M + 100k - 100k = 5M
        assertEq(vault.totalAssets(), totalAssetsBefore);

        // Price up 10% → unrealized trader profit = 20k
        btcUsdFeed.setAnswer(66_000e8);

        // totalAssets should decrease (traders are profiting at LP expense)
        uint256 totalAssetsWithProfit = vault.totalAssets();
        assertLt(totalAssetsWithProfit, totalAssetsBefore);

        // Expected: 5M + 100k (balance) - 100k (collateral) - 20k (unrealized) = 4.98M
        assertEq(totalAssetsWithProfit, lpDeposit - 20_000 * ONE_TOKEN);
    }

    function test_vaultTotalAssets_preventsFrontRunning() public {
        uint256 collateral = 100_000 * ONE_TOKEN;

        // LP has shares worth 5M initially
        uint256 sharesBefore = vault.balanceOf(lp);
        uint256 previewBefore = vault.previewRedeem(sharesBefore);

        // Trader opens a long
        _commitAndExecute(trader1, BTC, PerpDEX.Side.Long, collateral, 5);

        // BTC pumps 15% → trader has huge unrealized profit (75% of 500k notional = 375k)
        btcUsdFeed.setAnswer(69_000e8);

        // LP tries to front-run by withdrawing now — share price should already reflect the loss
        uint256 previewDuringPump = vault.previewRedeem(sharesBefore);
        assertLt(previewDuringPump, previewBefore, "LP cannot exit at stale price");
    }
}
