// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AggregatorV3Interface} from "chainlink-evm/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {cNGNVault} from "../src/cNGNVault.sol";
import {PerpDEX} from "../src/PerpDEX.sol";
import {SovereigntyAccessManager} from "../src/SovereigntyAccessManager.sol";

/// @title PerpDEX Fork Test
/// @notice Full integration tests on a Base mainnet fork with real cNGN and Chainlink feeds.
contract PerpDEXForkTest is Test {
    /*//////////////////////////////////////////////////////////////
                       BASE MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    // Tokens
    address constant CNGN = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WSOL = 0x311935Cd80B76769bF2ecC9D8Ab7635b2139cf82;

    // Chainlink price feeds
    address constant BTC_USD_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant SOL_USD_FEED = 0x975043adBb80fc32276CbF9Bbcfd4A601a12462D;
    address constant NGN_USD_FEED = 0xdfbb5Cbc88E382de007bfe6CE99C388176ED80aD;

    // Heartbeats
    uint256 constant NGN_HEARTBEAT = 3600;
    uint256 constant BTC_HEARTBEAT = 1200;
    uint256 constant ETH_HEARTBEAT = 1200;
    uint256 constant SOL_HEARTBEAT = 86400;

    /*//////////////////////////////////////////////////////////////
                              STATE
    //////////////////////////////////////////////////////////////*/

    IERC20 public cNGN;
    cNGNVault public vault;
    PerpDEX public perp;
    SovereigntyAccessManager public sam;

    address owner = makeAddr("owner");
    address trader1 = makeAddr("trader1");
    address trader2 = makeAddr("trader2");
    address lp = makeAddr("lp");
    address liquidator = makeAddr("liquidator");

    uint256 constant ONE_CNGN = 1e6;
    uint256 constant PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork(vm.envString("RPC_URL"));

        cNGN = IERC20(CNGN);

        // Deploy SAM proxy
        SovereigntyAccessManager samImpl = new SovereigntyAccessManager();
        ERC1967Proxy samProxy =
            new ERC1967Proxy(address(samImpl), abi.encodeCall(SovereigntyAccessManager.initialize, (owner)));
        sam = SovereigntyAccessManager(address(samProxy));

        // Deploy vault & PerpDEX
        vault = new cNGNVault(cNGN, address(sam));
        perp = new PerpDEX(CNGN, address(vault), NGN_USD_FEED, NGN_HEARTBEAT, address(sam));

        // Configure SAM role mappings
        vm.startPrank(owner);

        // Vault: setPerpDex → VAULT_MANAGER_ROLE
        bytes4[] memory vaultSelectors = new bytes4[](1);
        vaultSelectors[0] = cNGNVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(vault), vaultSelectors, sam.VAULT_MANAGER_ROLE());
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), owner, 0);

        // PerpDEX: configureAsset, setNgnUsdFeed, setForwarder → OPERATOR_ROLE
        bytes4[] memory operatorSelectors = new bytes4[](3);
        operatorSelectors[0] = PerpDEX.configureAsset.selector;
        operatorSelectors[1] = PerpDEX.setNgnUsdFeed.selector;
        operatorSelectors[2] = PerpDEX.setForwarder.selector;
        sam.setTargetFunctionRole(address(perp), operatorSelectors, sam.OPERATOR_ROLE());
        sam.grantRole(sam.OPERATOR_ROLE(), owner, 0);

        // PerpDEX: pause, unpause → PAUSER_ROLE
        bytes4[] memory pauserSelectors = new bytes4[](2);
        pauserSelectors[0] = PerpDEX.pause.selector;
        pauserSelectors[1] = PerpDEX.unpause.selector;
        sam.setTargetFunctionRole(address(perp), pauserSelectors, sam.PAUSER_ROLE());
        sam.grantRole(sam.PAUSER_ROLE(), owner, 0);

        vm.stopPrank();

        // Link vault → PerpDEX
        vm.prank(owner);
        vault.setPerpDex(address(perp));

        // Configure all three markets using real Chainlink feeds
        vm.startPrank(owner);
        perp.configureAsset(WBTC, BTC_USD_FEED, BTC_HEARTBEAT);
        perp.configureAsset(WETH, ETH_USD_FEED, ETH_HEARTBEAT);
        perp.configureAsset(WSOL, SOL_USD_FEED, SOL_HEARTBEAT);
        vm.stopPrank();

        // Fund accounts with cNGN
        deal(CNGN, lp, 50_000_000 * ONE_CNGN);
        deal(CNGN, trader1, 5_000_000 * ONE_CNGN);
        deal(CNGN, trader2, 5_000_000 * ONE_CNGN);

        // LP deposits into vault
        vm.prank(lp);
        cNGN.approve(address(vault), type(uint256).max);
        vm.prank(lp);
        vault.deposit(30_000_000 * ONE_CNGN, lp);

        // Traders approve PerpDEX
        vm.prank(trader1);
        cNGN.approve(address(perp), type(uint256).max);
        vm.prank(trader2);
        cNGN.approve(address(perp), type(uint256).max);
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
        bytes32 salt = keccak256(abi.encodePacked("salt", _trader, _asset, block.number));
        bytes32 orderHash = keccak256(abi.encode(_trader, _asset, _side, _collateral, _leverage, salt));

        vm.prank(_trader);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 2);

        vm.prank(_trader);
        perp.executeTrade(_asset, _side, _collateral, _leverage, salt);
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 1: REAL CHAINLINK ORACLE TRIANGULATION
    //////////////////////////////////////////////////////////////*/

    function test_fork_oracle_btcMarkPrice() public view {
        uint256 price = perp.getMarkPrice(WBTC);
        assertGt(price, 0, "BTC/cNGN mark price should be > 0");
        console.log("BTC/cNGN mark price (1e18):", price);

        // Sanity: At ~$90k BTC and ~1600 NGN/USD, BTC = ~144M cNGN
        // price in PRECISION = ~144_000_000 * 1e18
        // That's 1.44e26. Let's just check it's in a sane range.
        assertGt(price, 1e24, "BTC should be worth at least 1M cNGN");
        assertLt(price, 1e30, "BTC price sanity upper bound");
    }

    function test_fork_oracle_ethMarkPrice() public view {
        uint256 price = perp.getMarkPrice(WETH);
        assertGt(price, 0, "ETH/cNGN mark price should be > 0");
        console.log("ETH/cNGN mark price (1e18):", price);

        // ETH ~$3k, NGN ~1600/USD → ETH ≈ 4.8M cNGN → ~4.8e24
        assertGt(price, 1e22, "ETH should be worth at least 10k cNGN");
        assertLt(price, 1e28, "ETH price sanity upper bound");
    }

    function test_fork_oracle_solMarkPrice() public view {
        uint256 price = perp.getMarkPrice(WSOL);
        assertGt(price, 0, "SOL/cNGN mark price should be > 0");
        console.log("SOL/cNGN mark price (1e18):", price);

        // SOL ~$150, NGN ~1600/USD → SOL ≈ 240k cNGN → ~2.4e23
        assertGt(price, 1e20, "SOL should be worth at least 100 cNGN");
        assertLt(price, 1e27, "SOL price sanity upper bound");
    }

    function test_fork_oracle_triangulationConsistency() public view {
        // BTC should be much more expensive than ETH, ETH more than SOL
        uint256 btcPrice = perp.getMarkPrice(WBTC);
        uint256 ethPrice = perp.getMarkPrice(WETH);
        uint256 solPrice = perp.getMarkPrice(WSOL);

        assertGt(btcPrice, ethPrice, "BTC should cost more than ETH");
        assertGt(ethPrice, solPrice, "ETH should cost more than SOL");
    }

    function test_fork_oracle_disabledAssetReverts() public {
        address fakeAsset = makeAddr("notConfigured");
        vm.expectRevert(PerpDEX.AssetNotEnabled.selector);
        perp.getMarkPrice(fakeAsset);
    }

    function test_fork_oracle_feedDecimals() public view {
        // All Chainlink feeds on Base should be 8 decimals
        assertEq(AggregatorV3Interface(BTC_USD_FEED).decimals(), 8);
        assertEq(AggregatorV3Interface(ETH_USD_FEED).decimals(), 8);
        assertEq(AggregatorV3Interface(SOL_USD_FEED).decimals(), 8);
        assertEq(AggregatorV3Interface(NGN_USD_FEED).decimals(), 8);
    }

    function test_fork_oracle_feedsNotStale() public view {
        // Confirm feeds are fresh on the forked block
        _assertFeedFresh(BTC_USD_FEED, BTC_HEARTBEAT);
        _assertFeedFresh(ETH_USD_FEED, ETH_HEARTBEAT);
        _assertFeedFresh(SOL_USD_FEED, SOL_HEARTBEAT);
        _assertFeedFresh(NGN_USD_FEED, NGN_HEARTBEAT);
    }

    function _assertFeedFresh(address _feed, uint256 _heartbeat) internal view {
        (,,, uint256 updatedAt,) = AggregatorV3Interface(_feed).latestRoundData();
        assertLe(block.timestamp - updatedAt, _heartbeat, string.concat("Feed stale: ", vm.toString(_feed)));
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 2: ADMIN CONFIGURATION ON FORK
    //////////////////////////////////////////////////////////////*/

    function test_fork_configuredAssets() public view {
        assertEq(perp.supportedAssetsLength(), 3);
        assertEq(perp.supportedAssets(0), WBTC);
        assertEq(perp.supportedAssets(1), WETH);
        assertEq(perp.supportedAssets(2), WSOL);
    }

    function test_fork_pause_blocksTrading() public {
        vm.prank(owner);
        perp.pause();

        bytes32 hash = keccak256("anything");
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(trader1);
        perp.requestTrade(hash);

        vm.prank(owner);
        perp.unpause();

        // Should work now
        vm.prank(trader1);
        perp.requestTrade(hash);
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 3: COMMIT-REVEAL WITH REAL PRICES
    //////////////////////////////////////////////////////////////*/

    function test_fork_commitReveal_btcLong() public {
        uint256 collateral = 500_000 * ONE_CNGN;
        bytes32 salt = keccak256("btcLongSalt");
        bytes32 orderHash = keccak256(abi.encode(trader1, WBTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        // Commit
        vm.prank(trader1);
        perp.requestTrade(orderHash);

        (bytes32 storedHash, uint256 commitBlock) = perp.committedOrders(trader1);
        assertEq(storedHash, orderHash);
        assertEq(commitBlock, block.number);

        // Advance
        vm.roll(block.number + 2);

        // Execute
        vm.prank(trader1);
        perp.executeTrade(WBTC, PerpDEX.Side.Long, collateral, 2, salt);

        // Position should exist
        PerpDEX.Position memory pos = perp.getPosition(WBTC, trader1);
        assertGt(pos.size, 0);
        assertEq(pos.collateral, collateral);
        assertEq(uint8(pos.side), uint8(PerpDEX.Side.Long));
    }

    function test_fork_commitReveal_tooEarly() public {
        uint256 collateral = 100_000 * ONE_CNGN;
        bytes32 salt = keccak256("s");
        bytes32 orderHash = keccak256(abi.encode(trader1, WBTC, PerpDEX.Side.Long, collateral, uint256(1), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        // Don't advance blocks → should revert
        vm.expectRevert(PerpDEX.TooEarlyToExecute.selector);
        vm.prank(trader1);
        perp.executeTrade(WBTC, PerpDEX.Side.Long, collateral, 1, salt);
    }

    function test_fork_commitReveal_expired() public {
        uint256 collateral = 100_000 * ONE_CNGN;
        bytes32 salt = keccak256("s");
        bytes32 orderHash = keccak256(abi.encode(trader1, WBTC, PerpDEX.Side.Long, collateral, uint256(1), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 21); // past MAX_BLOCK_DELAY

        vm.expectRevert(PerpDEX.OrderExpired.selector);
        vm.prank(trader1);
        perp.executeTrade(WBTC, PerpDEX.Side.Long, collateral, 1, salt);
    }

    function test_fork_commitReveal_hashMismatch() public {
        uint256 collateral = 100_000 * ONE_CNGN;
        bytes32 salt = keccak256("s");
        bytes32 orderHash = keccak256(abi.encode(trader1, WBTC, PerpDEX.Side.Long, collateral, uint256(2), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);

        // Reveal with wrong leverage
        vm.expectRevert(PerpDEX.OrderHashMismatch.selector);
        vm.prank(trader1);
        perp.executeTrade(WBTC, PerpDEX.Side.Long, collateral, 3, salt);
    }

    /*//////////////////////////////////////////////////////////////
      SECTION 4: OPEN POSITIONS ON ALL MARKETS (REAL PRICES)
    //////////////////////////////////////////////////////////////*/

    function test_fork_openLong_btc() public {
        uint256 collateral = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, collateral, 3);

        PerpDEX.Position memory pos = perp.getPosition(WBTC, trader1);
        assertEq(pos.collateral, collateral);
        uint256 expectedSize = uint256(collateral) * 1e12 * 3;
        assertEq(pos.size, expectedSize);
        assertEq(uint8(pos.side), uint8(PerpDEX.Side.Long));

        // averagePrice must match the current mark price
        uint256 markPrice = perp.getMarkPrice(WBTC);
        assertEq(pos.averagePrice, markPrice);
    }

    function test_fork_openShort_eth() public {
        uint256 collateral = 300_000 * ONE_CNGN;
        _commitAndExecute(trader1, WETH, PerpDEX.Side.Short, collateral, 5);

        PerpDEX.Position memory pos = perp.getPosition(WETH, trader1);
        assertEq(uint8(pos.side), uint8(PerpDEX.Side.Short));
        assertEq(pos.size, uint256(collateral) * 1e12 * 5);
    }

    function test_fork_openLong_sol() public {
        uint256 collateral = 200_000 * ONE_CNGN;
        _commitAndExecute(trader1, WSOL, PerpDEX.Side.Long, collateral, 2);

        PerpDEX.Position memory pos = perp.getPosition(WSOL, trader1);
        assertGt(pos.size, 0);
        assertEq(pos.collateral, collateral);
    }

    function test_fork_openPosition_collateralMovesToVault() public {
        uint256 collateral = 500_000 * ONE_CNGN;
        uint256 traderBalBefore = cNGN.balanceOf(trader1);
        uint256 vaultBalBefore = cNGN.balanceOf(address(vault));

        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, collateral, 2);

        assertEq(cNGN.balanceOf(trader1), traderBalBefore - collateral);
        assertEq(cNGN.balanceOf(address(vault)), vaultBalBefore + collateral);
    }

    function test_fork_exceedsMaxLeverage_reverts() public {
        uint256 collateral = 100_000 * ONE_CNGN;
        bytes32 salt = keccak256("s");
        bytes32 hash = keccak256(abi.encode(trader1, WBTC, PerpDEX.Side.Long, collateral, uint256(6), salt));

        vm.prank(trader1);
        perp.requestTrade(hash);
        vm.roll(block.number + 2);

        vm.expectRevert(PerpDEX.ExceedsMaxLeverage.selector);
        vm.prank(trader1);
        perp.executeTrade(WBTC, PerpDEX.Side.Long, collateral, 6, salt);
    }

    function test_fork_duplicatePosition_reverts() public {
        uint256 collateral = 100_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, collateral, 2);

        bytes32 salt = keccak256("dup");
        bytes32 hash = keccak256(abi.encode(trader1, WBTC, PerpDEX.Side.Long, collateral, uint256(2), salt));
        vm.prank(trader1);
        perp.requestTrade(hash);
        vm.roll(block.number + 2);

        vm.expectRevert(PerpDEX.PositionAlreadyOpen.selector);
        vm.prank(trader1);
        perp.executeTrade(WBTC, PerpDEX.Side.Long, collateral, 2, salt);
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 5: OPEN INTEREST TRACKING
    //////////////////////////////////////////////////////////////*/

    function test_fork_OI_tracked() public {
        uint256 collateral = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, collateral, 3);

        PerpDEX.MarketOI memory moi = perp.getMarketOI(WBTC);
        uint256 expectedSize = uint256(collateral) * 1e12 * 3;
        assertEq(moi.longOI, expectedSize);
        assertEq(moi.shortOI, 0);
    }

    function test_fork_OI_bothSides() public {
        uint256 collateral = 300_000 * ONE_CNGN;
        _commitAndExecute(trader1, WETH, PerpDEX.Side.Long, collateral, 2);
        _commitAndExecute(trader2, WETH, PerpDEX.Side.Short, collateral, 4);

        PerpDEX.MarketOI memory moi = perp.getMarketOI(WETH);
        assertEq(moi.longOI, uint256(collateral) * 1e12 * 2);
        assertEq(moi.shortOI, uint256(collateral) * 1e12 * 4);
    }

    function test_fork_OI_clearedOnClose() public {
        uint256 collateral = 200_000 * ONE_CNGN;
        _commitAndExecute(trader1, WSOL, PerpDEX.Side.Long, collateral, 2);

        vm.prank(trader1);
        perp.closePosition(WSOL);

        PerpDEX.MarketOI memory moi = perp.getMarketOI(WSOL);
        assertEq(moi.longOI, 0);
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 6: CLOSE POSITIONS AT REAL PRICES (BREAKEVEN)
    //////////////////////////////////////////////////////////////*/

    function test_fork_closeLong_breakeven() public {
        uint256 collateral = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, collateral, 2);

        uint256 balBefore = cNGN.balanceOf(trader1);

        // Close at the same block → same price → breakeven
        vm.prank(trader1);
        perp.closePosition(WBTC);

        uint256 received = cNGN.balanceOf(trader1) - balBefore;
        // Should get back collateral (within rounding of 1e-12)
        assertApproxEqAbs(received, collateral, 1);
    }

    function test_fork_closeShort_breakeven() public {
        uint256 collateral = 300_000 * ONE_CNGN;
        _commitAndExecute(trader1, WETH, PerpDEX.Side.Short, collateral, 3);

        uint256 balBefore = cNGN.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(WETH);

        uint256 received = cNGN.balanceOf(trader1) - balBefore;
        assertApproxEqAbs(received, collateral, 1);
    }

    function test_fork_close_positionDeleted() public {
        uint256 collateral = 200_000 * ONE_CNGN;
        _commitAndExecute(trader1, WSOL, PerpDEX.Side.Long, collateral, 1);

        vm.prank(trader1);
        perp.closePosition(WSOL);

        PerpDEX.Position memory pos = perp.getPosition(WSOL, trader1);
        assertEq(pos.size, 0);
        assertEq(pos.collateral, 0);
    }

    function test_fork_close_noPosition_reverts() public {
        vm.expectRevert(PerpDEX.NoOpenPosition.selector);
        vm.prank(trader1);
        perp.closePosition(WBTC);
    }

    function test_fork_close_settlesPnLOnVault() public {
        uint256 collateral = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, collateral, 2);

        // Collateral tracked
        assertEq(perp.totalCollateralHeld(), collateral);

        vm.prank(trader1);
        perp.closePosition(WBTC);

        // Breakeven → collateral released, PnL ~ 0
        assertEq(perp.totalCollateralHeld(), 0);
    }

    function test_fork_canReopenAfterClose() public {
        uint256 collateral = 100_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, collateral, 2);

        vm.prank(trader1);
        perp.closePosition(WBTC);

        // Reopen on the opposite side
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Short, collateral, 3);

        PerpDEX.Position memory pos = perp.getPosition(WBTC, trader1);
        assertGt(pos.size, 0);
        assertEq(uint8(pos.side), uint8(PerpDEX.Side.Short));
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 7: MULTI-ASSET CONCURRENT POSITIONS
    //////////////////////////////////////////////////////////////*/

    function test_fork_multiAsset_sameTrader() public {
        uint256 col = 200_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);
        _commitAndExecute(trader1, WETH, PerpDEX.Side.Short, col, 3);
        _commitAndExecute(trader1, WSOL, PerpDEX.Side.Long, col, 1);

        assertGt(perp.getPosition(WBTC, trader1).size, 0);
        assertGt(perp.getPosition(WETH, trader1).size, 0);
        assertGt(perp.getPosition(WSOL, trader1).size, 0);

        // Close one, others stay
        vm.prank(trader1);
        perp.closePosition(WETH);

        assertEq(perp.getPosition(WETH, trader1).size, 0);
        assertGt(perp.getPosition(WBTC, trader1).size, 0);
        assertGt(perp.getPosition(WSOL, trader1).size, 0);
    }

    function test_fork_multiTrader_sameAssetOpposingSides() public {
        uint256 col = 300_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);
        _commitAndExecute(trader2, WBTC, PerpDEX.Side.Short, col, 2);

        PerpDEX.MarketOI memory moi = perp.getMarketOI(WBTC);
        assertEq(moi.longOI, moi.shortOI, "Balanced OI");

        // Both close at same price → breakeven for both
        uint256 bal1Before = cNGN.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(WBTC);

        uint256 bal2Before = cNGN.balanceOf(trader2);
        vm.prank(trader2);
        perp.closePosition(WBTC);

        assertApproxEqAbs(cNGN.balanceOf(trader1) - bal1Before, col, 1);
        assertApproxEqAbs(cNGN.balanceOf(trader2) - bal2Before, col, 1);
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 8: TOKEN CONSERVATION (FORK)
    //////////////////////////////////////////////////////////////*/

    function test_fork_tokenConservation() public {
        uint256 col = 500_000 * ONE_CNGN;

        uint256 systemBefore = cNGN.balanceOf(address(vault)) + cNGN.balanceOf(trader1);

        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 3);

        // System balance should be conserved mid-trade (collateral moved to vault)
        uint256 systemMid = cNGN.balanceOf(address(vault)) + cNGN.balanceOf(trader1);
        assertEq(systemMid, systemBefore, "No tokens lost on open");

        vm.prank(trader1);
        perp.closePosition(WBTC);

        uint256 systemAfter = cNGN.balanceOf(address(vault)) + cNGN.balanceOf(trader1);
        assertApproxEqAbs(systemAfter, systemBefore, 1, "No tokens lost on close");
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 9: LIQUIDATION AT REAL PRICES
    //////////////////////////////////////////////////////////////*/

    function test_fork_isLiquidatable_healthyPosition() public view {
        // No position → not liquidatable
        assertFalse(perp.isLiquidatable(WBTC, trader1));
    }

    function test_fork_liquidate_noPosition_reverts() public {
        vm.expectRevert(PerpDEX.NoOpenPosition.selector);
        vm.prank(liquidator);
        perp.liquidate(WBTC, trader1);
    }

    function test_fork_liquidate_healthyPosition_reverts() public {
        uint256 col = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);

        // At same price → fully healthy
        assertFalse(perp.isLiquidatable(WBTC, trader1));

        vm.expectRevert(PerpDEX.NotLiquidatable.selector);
        vm.prank(liquidator);
        perp.liquidate(WBTC, trader1);
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 10: VAULT INTEGRATION ON FORK
    //////////////////////////////////////////////////////////////*/

    function test_fork_vaultLinkedCorrectly() public view {
        assertEq(vault.perpDex(), address(perp));
        assertEq(address(perp.vault()), address(vault));
        assertEq(address(perp.cNGN()), CNGN);
    }

    function test_fork_vaultTotalAssets_includesLPDeposit() public view {
        // LP deposited 30M in setUp
        assertEq(vault.totalAssets(), 30_000_000 * ONE_CNGN);
    }

    function test_fork_vaultSharePrice_afterTradeSettlement() public {
        uint256 lpShares = vault.balanceOf(lp);
        uint256 previewBefore = vault.previewRedeem(lpShares);

        uint256 col = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);

        // Close at same price → PnL = 0 → no impact on share price
        vm.prank(trader1);
        perp.closePosition(WBTC);

        uint256 previewAfter = vault.previewRedeem(lpShares);
        assertApproxEqAbs(previewAfter, previewBefore, 1, "Share price unchanged on breakeven");
    }

    function test_fork_vault_lpCanDepositAndWithdrawAfterTrades() public {
        // Open and close a position
        uint256 col = 200_000 * ONE_CNGN;
        _commitAndExecute(trader1, WETH, PerpDEX.Side.Short, col, 3);
        vm.prank(trader1);
        perp.closePosition(WETH);

        // LP deposits more
        uint256 additionalDeposit = 1_000_000 * ONE_CNGN;
        vm.prank(lp);
        uint256 newShares = vault.deposit(additionalDeposit, lp);
        assertGt(newShares, 0);

        // LP withdraws some
        vm.prank(lp);
        vault.withdraw(500_000 * ONE_CNGN, lp, lp);

        assertGt(vault.balanceOf(lp), 0);
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 11: FUNDING RATE WITH REAL OI
    //////////////////////////////////////////////////////////////*/

    function test_fork_funding_initialState() public view {
        PerpDEX.MarketOI memory moi = perp.getMarketOI(WBTC);
        assertEq(moi.longOI, 0);
        assertEq(moi.shortOI, 0);
        assertEq(moi.fundingIndex, 0);
    }

    function test_fork_funding_balancedOI_noPayment() public {
        uint256 col = 300_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);
        _commitAndExecute(trader2, WBTC, PerpDEX.Side.Short, col, 2);

        // Balanced OI → funding accrues nothing
        // Close both → both get back collateral
        uint256 bal1 = cNGN.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(WBTC);

        uint256 bal2 = cNGN.balanceOf(trader2);
        vm.prank(trader2);
        perp.closePosition(WBTC);

        assertApproxEqAbs(cNGN.balanceOf(trader1) - bal1, col, 1);
        assertApproxEqAbs(cNGN.balanceOf(trader2) - bal2, col, 1);
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 12: PRECISION TESTS WITH REAL FEEDS
    //////////////////////////////////////////////////////////////*/

    function test_fork_precision_smallPosition() public {
        // Smallest meaningful position: 10 cNGN
        uint256 col = 10 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 1);

        PerpDEX.Position memory pos = perp.getPosition(WBTC, trader1);
        assertGt(pos.size, 0);
        assertGt(pos.averagePrice, 0);

        uint256 balBefore = cNGN.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(WBTC);

        uint256 received = cNGN.balanceOf(trader1) - balBefore;
        assertApproxEqAbs(received, col, 1);
    }

    function test_fork_precision_largePosition() public {
        // 2M cNGN at 5x leverage = 10M notional
        uint256 col = 2_000_000 * ONE_CNGN;
        _commitAndExecute(trader1, WETH, PerpDEX.Side.Short, col, 5);

        PerpDEX.Position memory pos = perp.getPosition(WETH, trader1);
        assertEq(pos.size, uint256(col) * 1e12 * 5);

        uint256 balBefore = cNGN.balanceOf(trader1);
        vm.prank(trader1);
        perp.closePosition(WETH);

        uint256 received = cNGN.balanceOf(trader1) - balBefore;
        assertApproxEqAbs(received, col, 1);
    }

    function test_fork_precision_allMarketsConsistent() public {
        // Open and close on all 3 markets → each should break even
        uint256 col = 100_000 * ONE_CNGN;
        address[3] memory assets = [WBTC, WETH, WSOL];

        for (uint256 i = 0; i < 3; i++) {
            _commitAndExecute(trader1, assets[i], PerpDEX.Side.Long, col, 2);

            uint256 balBefore = cNGN.balanceOf(trader1);
            vm.prank(trader1);
            perp.closePosition(assets[i]);
            uint256 received = cNGN.balanceOf(trader1) - balBefore;

            assertApproxEqAbs(received, col, 1, "Breakeven should hold on all markets");
        }
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 13: PAUSED STATE ON FORK
    //////////////////////////////////////////////////////////////*/

    function test_fork_paused_closeReverts() public {
        uint256 col = 200_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);

        vm.prank(owner);
        perp.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(trader1);
        perp.closePosition(WBTC);

        vm.prank(owner);
        perp.unpause();

        // Now close works
        vm.prank(trader1);
        perp.closePosition(WBTC);
    }

    function test_fork_paused_liquidateReverts() public {
        uint256 col = 200_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);

        vm.prank(owner);
        perp.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(liquidator);
        perp.liquidate(WBTC, trader1);
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 14: UNREALIZED PNL & FRONT-RUN PROTECTION ON FORK
    //////////////////////////////////////////////////////////////*/

    function test_fork_getGlobalUnrealizedPnL_zeroAtEntry() public {
        uint256 col = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);

        // Same block, same price → unrealized PnL = 0
        assertEq(perp.getGlobalUnrealizedPnL(), 0);
    }

    function test_fork_totalCollateralHeld_tracked() public {
        uint256 col1 = 300_000 * ONE_CNGN;
        uint256 col2 = 200_000 * ONE_CNGN;

        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col1, 2);
        assertEq(perp.totalCollateralHeld(), col1);

        _commitAndExecute(trader2, WETH, PerpDEX.Side.Short, col2, 3);
        assertEq(perp.totalCollateralHeld(), col1 + col2);

        vm.prank(trader1);
        perp.closePosition(WBTC);
        assertEq(perp.totalCollateralHeld(), col2);

        vm.prank(trader2);
        perp.closePosition(WETH);
        assertEq(perp.totalCollateralHeld(), 0);
    }

    function test_fork_vaultTotalAssets_accountsForCollateral() public {
        uint256 lpDeposit = 30_000_000 * ONE_CNGN;
        uint256 col = 500_000 * ONE_CNGN;

        // Before trade: totalAssets = LP deposit
        assertEq(vault.totalAssets(), lpDeposit);

        // Open position: collateral goes to vault but is tracked separately
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);

        // totalAssets = balance(30.5M) - collateral(500k) - unrealizedPnL(0) = 30M
        assertEq(vault.totalAssets(), lpDeposit);
    }

    function test_fork_lpFrontRunProtection() public {
        uint256 col = 500_000 * ONE_CNGN;

        uint256 lpShares = vault.balanceOf(lp);
        uint256 previewBefore = vault.previewRedeem(lpShares);

        // Trader opens long
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 3);

        // At same price, LP share value unchanged
        uint256 previewAtOpen = vault.previewRedeem(lpShares);
        assertApproxEqAbs(previewAtOpen, previewBefore, 1, "Share price stable at breakeven");
    }

    function test_fork_avgPrices_trackedOnFork() public {
        uint256 col = 300_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);

        PerpDEX.MarketOI memory moi = perp.getMarketOI(WBTC);
        uint256 markPrice = perp.getMarkPrice(WBTC);
        assertEq(moi.avgLongPrice, markPrice, "Avg long price should match mark price");
        assertEq(moi.avgShortPrice, 0, "No shorts opened");
    }

    /*//////////////////////////////////////////////////////////////
        SECTION: COLLATERAL MANAGEMENT (ADD / REMOVE) — FORK
    //////////////////////////////////////////////////////////////*/

    function test_fork_addCollateral_success() public {
        uint256 col = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 3);

        uint256 addAmount = 200_000 * ONE_CNGN;
        uint256 totalColBefore = perp.totalCollateralHeld();

        vm.prank(trader1);
        cNGN.approve(address(perp), addAmount);
        vm.prank(trader1);
        perp.addCollateral(WBTC, addAmount);

        PerpDEX.Position memory pos = perp.getPosition(WBTC, trader1);
        assertEq(pos.collateral, col + addAmount);
        assertEq(perp.totalCollateralHeld(), totalColBefore + addAmount);
    }

    function test_fork_addCollateral_totalAssetsReflectsIncrease() public {
        uint256 col = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);

        uint256 totalAssetsBefore = vault.totalAssets();

        uint256 addAmount = 300_000 * ONE_CNGN;
        vm.prank(trader1);
        cNGN.approve(address(perp), addAmount);
        vm.prank(trader1);
        perp.addCollateral(WBTC, addAmount);

        // Balance up by addAmount, collateralHeld up by addAmount → totalAssets unchanged
        assertEq(vault.totalAssets(), totalAssetsBefore);
    }

    function test_fork_removeCollateral_success() public {
        uint256 col = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);

        // size = 1M CNGN notional at 2x. At 5x max: min equity = 1M/5 = 200k
        // Can safely remove up to ~300k from 500k collateral
        uint256 removeAmount = 200_000 * ONE_CNGN;
        uint256 balBefore = cNGN.balanceOf(trader1);

        vm.prank(trader1);
        perp.removeCollateral(WBTC, removeAmount);

        PerpDEX.Position memory pos = perp.getPosition(WBTC, trader1);
        assertEq(pos.collateral, col - removeAmount);
        assertEq(cNGN.balanceOf(trader1), balBefore + removeAmount);
    }

    function test_fork_removeCollateral_revertsExceedsLeverage() public {
        uint256 col = 300_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 5);

        // Already at 5x — cannot remove any meaningful amount
        vm.expectRevert(PerpDEX.ExceedsLeverageAfterRemoval.selector);
        vm.prank(trader1);
        perp.removeCollateral(WBTC, 1 * ONE_CNGN);
    }

    function test_fork_removeCollateral_totalAssetsUnchanged() public {
        uint256 col = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.prank(trader1);
        perp.removeCollateral(WBTC, 100_000 * ONE_CNGN);

        // balance down 100k, collateralHeld down 100k → totalAssets unchanged
        assertEq(vault.totalAssets(), totalAssetsBefore);
    }

    function test_fork_addRemoveCollateral_roundTrip() public {
        uint256 col = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WETH, PerpDEX.Side.Short, col, 2);

        uint256 addAmount = 200_000 * ONE_CNGN;
        vm.prank(trader1);
        cNGN.approve(address(perp), addAmount);
        vm.prank(trader1);
        perp.addCollateral(WETH, addAmount);

        PerpDEX.Position memory pos1 = perp.getPosition(WETH, trader1);
        assertEq(pos1.collateral, col + addAmount);

        // Remove the same amount back
        vm.prank(trader1);
        perp.removeCollateral(WETH, addAmount);

        PerpDEX.Position memory pos2 = perp.getPosition(WETH, trader1);
        assertEq(pos2.collateral, col);
    }

    /*//////////////////////////////////////////////////////////////
      SECTION: CHAINLINK AUTOMATION (PROTOCOL-OWNED LIQUIDATIONS) — FORK
    //////////////////////////////////////////////////////////////*/

    function test_fork_setForwarder() public {
        address fwd = makeAddr("forwarder");
        vm.prank(owner);
        perp.setForwarder(fwd);
        assertEq(perp.liquidationForwarder(), fwd);
    }

    function test_fork_traderSet_trackedOnFork() public {
        uint256 col = 300_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);
        _commitAndExecute(trader2, WBTC, PerpDEX.Side.Short, col, 2);

        assertEq(perp.tradersPerAssetLength(WBTC), 2);

        vm.prank(trader1);
        perp.closePosition(WBTC);
        assertEq(perp.tradersPerAssetLength(WBTC), 1);
    }

    function test_fork_checkUpkeep_noLiquidatable() public {
        uint256 col = 500_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);

        (bool needed,) = perp.checkUpkeep("");
        assertFalse(needed, "Healthy position should not trigger upkeep");
    }

    function test_fork_performUpkeep_onlyForwarder() public {
        address fwd = makeAddr("forwarder");
        vm.prank(owner);
        perp.setForwarder(fwd);

        vm.expectRevert(PerpDEX.OnlyForwarder.selector);
        vm.prank(trader1);
        perp.performUpkeep(abi.encode(new address[](0), new address[](0)));
    }

    function test_fork_automation_multiAssetTraderSet() public {
        uint256 col = 300_000 * ONE_CNGN;
        _commitAndExecute(trader1, WBTC, PerpDEX.Side.Long, col, 2);
        _commitAndExecute(trader1, WETH, PerpDEX.Side.Short, col, 3);
        _commitAndExecute(trader2, WSOL, PerpDEX.Side.Long, col, 2);

        assertEq(perp.tradersPerAssetLength(WBTC), 1);
        assertEq(perp.tradersPerAssetLength(WETH), 1);
        assertEq(perp.tradersPerAssetLength(WSOL), 1);

        vm.prank(trader1);
        perp.closePosition(WBTC);
        assertEq(perp.tradersPerAssetLength(WBTC), 0);
        assertEq(perp.tradersPerAssetLength(WETH), 1, "Other asset unaffected");
    }
}
