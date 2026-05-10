// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Test.sol";
import {BaseForkSetup} from "./BaseForkSetup.sol";
import {PerpDEX} from "../../src/PerpDEX.sol";
import {MarketVault} from "../../src/MarketVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TradingFlowForkTest
/// @notice End-to-end trading tests on a Base mainnet fork using real Pyth prices
///         and real cNGN token. Covers the full commit-reveal lifecycle, PnL settlement,
///         collateral management, funding rates, multi-market isolation, and all edge cases.
/// @dev All tests use live Pyth data (fetched via Hermes FFI) and live Chainlink NGN/USD.
///      cNGN is the real Base mainnet ERC20 proxy — balances are injected via `deal()`.
///
///      Test sections:
///        1.  Basic open long (token transfers, OI, position state)
///        2.  Basic open short
///        3.  Max leverage boundary (exactly max, exceeds max, zero)
///        4.  Commit-reveal timing (too early, exact min delay, expired, at max delay, wrong hash, no commit)
///        5.  Duplicate position prevention
///        6.  Close position & PnL settlement (immediate close, no-position revert)
///        7.  Collateral management (add, add zero, add no-position, remove, remove exceeds leverage, remove zero)
///        8.  Zero collateral trade revert
///        9.  Disabled market (can't open, can close existing)
///       10. Pause/unpause (blocks request/execute/close/addCollateral, resumes)
///       11. OI cap enforcement
///       12. Multi-trader same market (opposing sides, OI tracking)
///       13. Funding rate accumulation (imbalanced vs balanced OI)
///       14. Position isolation across markets
///       15. Real token transfer verification (full open→close cycle)
contract TradingFlowForkTest is BaseForkSetup {
    /*//////////////////////////////////////////////////////////////
              1. BASIC OPEN POSITION — LONG
    //////////////////////////////////////////////////////////////*/

    /// @notice Open a long ETH position with real prices and verify state.
    function test_openLong_eth_realPrices() public {
        _refreshEthPrices();

        uint256 collateral = 100_000e6; // 100k cNGN
        uint256 leverage = 3;

        uint256 traderBalBefore = cNGN.balanceOf(trader1);
        uint256 vaultBalBefore = cNGN.balanceOf(address(ethVault));

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, leverage);

        // Verify position
        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.collateral, collateral, "Collateral mismatch");
        assertEq(pos.size, uint256(collateral) * 1e12 * leverage, "Size mismatch");
        assertTrue(pos.averagePrice > 0, "Entry price should be > 0");
        assertEq(uint256(pos.side), uint256(PerpDEX.Side.Long));

        // Verify token transfers
        assertEq(cNGN.balanceOf(trader1), traderBalBefore - collateral, "Trader should pay collateral");
        assertEq(cNGN.balanceOf(address(ethVault)), vaultBalBefore + collateral, "Vault should receive collateral");

        // Verify OI
        PerpDEX.MarketOI memory oi = perp.getMarketOI(ETH_MARKET);
        assertEq(oi.longOI, pos.size, "Long OI should match size");
        assertEq(oi.shortOI, 0, "Short OI should be 0");

        console.log("Entry price:", pos.averagePrice);
        console.log("Position size:", pos.size);
    }

    /*//////////////////////////////////////////////////////////////
              2. BASIC OPEN POSITION — SHORT
    //////////////////////////////////////////////////////////////*/

    /// @notice Open a short BTC position with real prices.
    function test_openShort_btc_realPrices() public {
        _refreshBtcPrices();

        uint256 collateral = 200_000e6;
        uint256 leverage = 2;

        _commitAndExecute(trader1, BTC_MARKET, PerpDEX.Side.Short, collateral, leverage);

        PerpDEX.Position memory pos = perp.getPosition(BTC_MARKET, trader1);
        assertEq(pos.collateral, collateral);
        assertEq(uint256(pos.side), uint256(PerpDEX.Side.Short));
        assertGt(pos.averagePrice, 0);

        PerpDEX.MarketOI memory oi = perp.getMarketOI(BTC_MARKET);
        assertEq(oi.shortOI, pos.size);
        assertEq(oi.longOI, 0);
    }

    /*//////////////////////////////////////////////////////////////
        3. MAX LEVERAGE — BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Opening at exactly max leverage (5x for crypto) should succeed.
    function test_maxLeverage_boundary_succeeds() public {
        _refreshEthPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, CRYPTO_MAX_LEVERAGE);

        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.size, uint256(50_000e6) * 1e12 * CRYPTO_MAX_LEVERAGE);
    }

    /// @notice Opening above max leverage should revert.
    function test_exceedsMaxLeverage_reverts() public {
        _refreshEthPrices();

        bytes32 salt = keccak256(abi.encode(trader1, block.number, block.timestamp));
        uint256 badLeverage = CRYPTO_MAX_LEVERAGE + 1;
        bytes32 orderHash = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, badLeverage, salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.ExceedsMaxLeverage.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 50_000e6, badLeverage, salt);
    }

    /// @notice Leverage of 0 should revert.
    function test_zeroLeverage_reverts() public {
        _refreshEthPrices();

        bytes32 salt = keccak256(abi.encode(trader1, block.number, block.timestamp));
        bytes32 orderHash = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, uint256(0), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.ExceedsMaxLeverage.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 0, salt);
    }

    /*//////////////////////////////////////////////////////////////
           4. COMMIT-REVEAL TIMING EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Executing before MIN_BLOCK_DELAY should revert.
    function test_commitReveal_tooEarly_reverts() public {
        _refreshEthPrices();

        bytes32 salt = keccak256(abi.encode(trader1, block.number, block.timestamp));
        bytes32 orderHash = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, uint256(3), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        // Don't advance blocks — execute in same block
        vm.prank(trader1);
        vm.expectRevert(PerpDEX.TooEarlyToExecute.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3, salt);
    }

    /// @notice Executing exactly at MIN_BLOCK_DELAY should revert (needs > delay, not >=).
    function test_commitReveal_exactMinDelay_reverts() public {
        _refreshEthPrices();

        bytes32 salt = keccak256(abi.encode(trader1, block.number, block.timestamp));
        bytes32 orderHash = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, uint256(3), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 1); // commitBlock + MIN_BLOCK_DELAY = commitBlock + 1

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.TooEarlyToExecute.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3, salt);
    }

    /// @notice Executing after MAX_BLOCK_DELAY should revert (order expired).
    function test_commitReveal_expired_reverts() public {
        _refreshEthPrices();

        bytes32 salt = keccak256(abi.encode(trader1, block.number, block.timestamp));
        bytes32 orderHash = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, uint256(3), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 21); // > MAX_BLOCK_DELAY (20)

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.OrderExpired.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3, salt);
    }

    /// @notice Execute at the last valid block (commitBlock + MAX_BLOCK_DELAY).
    function test_commitReveal_atMaxDelay_succeeds() public {
        _refreshEthPrices();

        bytes32 salt = keccak256(abi.encode(trader1, block.number, block.timestamp));
        bytes32 orderHash = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, uint256(3), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);

        vm.roll(block.number + 20); // exactly MAX_BLOCK_DELAY

        vm.prank(trader1);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3, salt);

        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertGt(pos.size, 0);
    }

    /// @notice Wrong hash should revert.
    function test_commitReveal_wrongHash_reverts() public {
        _refreshEthPrices();

        bytes32 salt = keccak256(abi.encode(trader1, block.number, block.timestamp));
        bytes32 wrongHash = keccak256("wrong");

        vm.prank(trader1);
        perp.requestTrade(wrongHash);

        vm.roll(block.number + 2);

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.OrderHashMismatch.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3, salt);
    }

    /// @notice No committed order should revert.
    function test_commitReveal_noCommit_reverts() public {
        _refreshEthPrices();

        bytes32 salt = keccak256("anysalt");

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.NoCommittedOrder.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3, salt);
    }

    /*//////////////////////////////////////////////////////////////
          5. DUPLICATE POSITION PREVENTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Cannot open a second position in the same market.
    function test_duplicatePosition_reverts() public {
        _refreshEthPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3);

        // Try opening again
        bytes32 salt2 = keccak256(abi.encode(trader1, block.number + 100, block.timestamp));
        bytes32 orderHash2 = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, uint256(3), salt2));

        vm.prank(trader1);
        perp.requestTrade(orderHash2);
        vm.roll(block.number + 2);

        // Need fresh prices since blocks rolled
        _refreshEthPrices();

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.PositionAlreadyOpen.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3, salt2);
    }

    /// @notice Can open positions in different markets simultaneously.
    function test_multipleMarkets_differentPositions() public {
        _refreshCryptoPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3);

        // Need fresh prices for BTC since commit-reveal rolls blocks
        _refreshBtcPrices();
        _commitAndExecute(trader1, BTC_MARKET, PerpDEX.Side.Short, 50_000e6, 2);

        PerpDEX.Position memory ethPos = perp.getPosition(ETH_MARKET, trader1);
        PerpDEX.Position memory btcPos = perp.getPosition(BTC_MARKET, trader1);

        assertGt(ethPos.size, 0);
        assertGt(btcPos.size, 0);
        assertEq(uint256(ethPos.side), uint256(PerpDEX.Side.Long));
        assertEq(uint256(btcPos.side), uint256(PerpDEX.Side.Short));
    }

    /*//////////////////////////////////////////////////////////////
             6. CLOSE POSITION & PNL SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Open and immediately close — PnL should be near zero.
    function test_closePosition_immediateClose_nearZeroPnL() public {
        _refreshEthPrices();

        uint256 collateral = 100_000e6;
        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, 3);

        // Refresh prices again (same block timestamp, same prices)
        _refreshEthPrices();

        uint256 traderBalBefore = cNGN.balanceOf(trader1);

        vm.prank(trader1);
        perp.closePosition(ETH_MARKET);

        uint256 traderBalAfter = cNGN.balanceOf(trader1);

        // Trader should get back roughly their collateral (slight precision loss possible)
        uint256 received = traderBalAfter - traderBalBefore;
        assertApproxEqRel(received, collateral, 1e16, "Should receive ~collateral back on immediate close");

        // Position should be deleted
        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.size, 0, "Position should be cleared");
    }

    /// @notice Close with no open position should revert.
    function test_closePosition_noPosition_reverts() public {
        _refreshEthPrices();

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.NoOpenPosition.selector);
        perp.closePosition(ETH_MARKET);
    }

    /*//////////////////////////////////////////////////////////////
          7. COLLATERAL MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Add collateral to an open position.
    function test_addCollateral_success() public {
        _refreshEthPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 5);

        PerpDEX.Position memory posBefore = perp.getPosition(ETH_MARKET, trader1);

        uint256 addAmount = 50_000e6;
        _refreshEthPrices();

        vm.prank(trader1);
        perp.addCollateral(ETH_MARKET, addAmount);

        PerpDEX.Position memory posAfter = perp.getPosition(ETH_MARKET, trader1);
        assertEq(posAfter.collateral, posBefore.collateral + addAmount);
        assertEq(posAfter.size, posBefore.size, "Size should not change");
    }

    /// @notice Add zero collateral should revert.
    function test_addCollateral_zero_reverts() public {
        _refreshEthPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.ZeroAmount.selector);
        perp.addCollateral(ETH_MARKET, 0);
    }

    /// @notice Add collateral with no position should revert.
    function test_addCollateral_noPosition_reverts() public {
        vm.prank(trader1);
        vm.expectRevert(PerpDEX.NoOpenPosition.selector);
        perp.addCollateral(ETH_MARKET, 10_000e6);
    }

    /// @notice Remove collateral safely.
    function test_removeCollateral_success() public {
        _refreshEthPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 2);

        uint256 removeAmount = 20_000e6;
        _refreshEthPrices();

        uint256 traderBalBefore = cNGN.balanceOf(trader1);

        vm.prank(trader1);
        perp.removeCollateral(ETH_MARKET, removeAmount);

        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.collateral, 100_000e6 - removeAmount);

        uint256 traderBalAfter = cNGN.balanceOf(trader1);
        assertEq(traderBalAfter - traderBalBefore, removeAmount, "Trader should receive removed collateral");
    }

    /// @notice Remove too much collateral (would exceed leverage) should revert.
    function test_removeCollateral_exceedsLeverage_reverts() public {
        _refreshEthPrices();

        // Open at 5x leverage — removing most collateral should exceed leverage
        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 5);

        _refreshEthPrices();

        vm.prank(trader1);
        vm.expectRevert(); // ExceedsLeverageAfterRemoval or InsufficientEquity
        perp.removeCollateral(ETH_MARKET, 90_000e6); // removing 90% guarantees leverage breach
    }

    /// @notice Remove zero collateral should revert.
    function test_removeCollateral_zero_reverts() public {
        _refreshEthPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.ZeroAmount.selector);
        perp.removeCollateral(ETH_MARKET, 0);
    }

    /*//////////////////////////////////////////////////////////////
          8. ZERO COLLATERAL TRADE ATTEMPT
    //////////////////////////////////////////////////////////////*/

    /// @notice Zero collateral trade should revert.
    function test_zeroCollateral_reverts() public {
        _refreshEthPrices();

        bytes32 salt = keccak256(abi.encode(trader1, block.number, block.timestamp));
        bytes32 orderHash = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, uint256(0), uint256(3), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.ZeroAmount.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 0, 3, salt);
    }

    /*//////////////////////////////////////////////////////////////
        9. DISABLED MARKET — CAN'T OPEN, CAN CLOSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Trading on a disabled market should revert.
    function test_disabledMarket_cannotOpen() public {
        _refreshEthPrices();

        vm.prank(operator);
        perp.disableMarket(ETH_MARKET);

        bytes32 salt = keccak256(abi.encode(trader1, block.number, block.timestamp));
        bytes32 orderHash = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, uint256(3), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);

        vm.prank(trader1);
        vm.expectRevert(PerpDEX.MarketNotEnabled.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3, salt);
    }

    /// @notice Existing position can be closed after market is disabled.
    function test_disabledMarket_canClose() public {
        _refreshEthPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3);

        vm.prank(operator);
        perp.disableMarket(ETH_MARKET);

        _refreshEthPrices();

        vm.prank(trader1);
        perp.closePosition(ETH_MARKET); // should succeed

        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertEq(pos.size, 0);
    }

    /*//////////////////////////////////////////////////////////////
        10. PAUSE / UNPAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Paused protocol blocks requestTrade.
    function test_pause_blocksRequestTrade() public {
        vm.prank(operator);
        perp.pause();

        bytes32 orderHash = keccak256("test");

        vm.prank(trader1);
        vm.expectRevert(); // EnforcedPause
        perp.requestTrade(orderHash);
    }

    /// @notice Paused protocol blocks executeTrade.
    function test_pause_blocksExecuteTrade() public {
        _refreshEthPrices();

        bytes32 salt = keccak256(abi.encode(trader1, block.number, block.timestamp));
        bytes32 orderHash = keccak256(abi.encode(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, uint256(3), salt));

        vm.prank(trader1);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);

        vm.prank(operator);
        perp.pause();

        vm.prank(trader1);
        vm.expectRevert(); // EnforcedPause
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3, salt);
    }

    /// @notice Unpaused protocol resumes trading.
    function test_unpause_resumesTrading() public {
        _refreshEthPrices();

        vm.prank(operator);
        perp.pause();

        vm.prank(operator);
        perp.unpause();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3);

        PerpDEX.Position memory pos = perp.getPosition(ETH_MARKET, trader1);
        assertGt(pos.size, 0);
    }

    /// @notice Paused protocol blocks closePosition.
    function test_pause_blocksClosePosition() public {
        _refreshEthPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3);

        vm.prank(operator);
        perp.pause();

        vm.prank(trader1);
        vm.expectRevert(); // EnforcedPause
        perp.closePosition(ETH_MARKET);
    }

    /// @notice Paused protocol blocks addCollateral.
    function test_pause_blocksAddCollateral() public {
        _refreshEthPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3);

        vm.prank(operator);
        perp.pause();

        vm.prank(trader1);
        vm.expectRevert(); // EnforcedPause
        perp.addCollateral(ETH_MARKET, 10_000e6);
    }

    /*//////////////////////////////////////////////////////////////
          11. OI CAP ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice OI cap is enforced based on vault TVL × OI_MULTIPLIER.
    function test_oiCap_exceeded_reverts() public {
        _refreshEthPrices();

        // Vault has 10M cNGN, OI multiplier = 5x, max OI = 50M cNGN (in 18 dec = 50M * 1e12)
        // Opening at 5x leverage with 2M collateral = 10M size
        // Multiple traders to exceed cap
        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 2_000_000e6, 5);

        _refreshEthPrices();
        _commitAndExecute(trader2, ETH_MARKET, PerpDEX.Side.Long, 2_000_000e6, 5);

        // trader3 tries to open another huge position that would exceed cap
        // Vault TVL is decreasing as collateral goes in, so cap tightens
        _dealcNGN(trader3, 50_000_000e6);
        vm.prank(trader3);
        cNGN.approve(address(perp), type(uint256).max);

        _refreshEthPrices();

        bytes32 salt = keccak256(abi.encode(trader3, block.number, block.timestamp));
        uint256 hugeCollateral = 40_000_000e6;
        bytes32 orderHash =
            keccak256(abi.encode(trader3, ETH_MARKET, PerpDEX.Side.Long, hugeCollateral, uint256(5), salt));

        vm.prank(trader3);
        perp.requestTrade(orderHash);
        vm.roll(block.number + 2);

        // Refresh after block roll
        _refreshEthPrices();

        vm.prank(trader3);
        vm.expectRevert(PerpDEX.ExceedsMaxOI.selector);
        perp.executeTrade(ETH_MARKET, PerpDEX.Side.Long, hugeCollateral, 5, salt);
    }

    /*//////////////////////////////////////////////////////////////
         12. MULTI-TRADER SAME MARKET
    //////////////////////////////////////////////////////////////*/

    /// @notice Multiple traders can have positions in the same market.
    function test_multiTrader_sameMarket() public {
        _refreshEthPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);

        _refreshEthPrices();
        _commitAndExecute(trader2, ETH_MARKET, PerpDEX.Side.Short, 80_000e6, 2);

        PerpDEX.Position memory pos1 = perp.getPosition(ETH_MARKET, trader1);
        PerpDEX.Position memory pos2 = perp.getPosition(ETH_MARKET, trader2);

        assertGt(pos1.size, 0);
        assertGt(pos2.size, 0);
        assertEq(uint256(pos1.side), uint256(PerpDEX.Side.Long));
        assertEq(uint256(pos2.side), uint256(PerpDEX.Side.Short));

        // OI should reflect both
        PerpDEX.MarketOI memory oi = perp.getMarketOI(ETH_MARKET);
        assertEq(oi.longOI, pos1.size);
        assertEq(oi.shortOI, pos2.size);
    }

    /*//////////////////////////////////////////////////////////////
         13. FUNDING RATE ACCUMULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Funding rate should accumulate over time when OI is imbalanced.
    function test_fundingRate_accumulatesOnImbalance() public {
        _refreshEthPrices();

        // Only long — fully imbalanced
        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);

        PerpDEX.MarketOI memory oiBefore = perp.getMarketOI(ETH_MARKET);
        int256 fundingBefore = oiBefore.fundingIndex;

        // Advance time (stay within crypto staleness so prices remain valid)
        vm.warp(block.timestamp + 60); // 60s < 120s staleness

        // Trigger funding update by opening another position
        _refreshEthPrices();
        _commitAndExecute(trader2, ETH_MARKET, PerpDEX.Side.Short, 50_000e6, 2);

        PerpDEX.MarketOI memory oiAfter = perp.getMarketOI(ETH_MARKET);
        int256 fundingAfter = oiAfter.fundingIndex;

        // Funding should have moved (long-heavy → positive index → long pays short)
        assertGt(fundingAfter, fundingBefore, "Funding index should increase with long-heavy OI");

        console.log("Funding before:", uint256(fundingBefore));
        console.log("Funding after:", uint256(fundingAfter));
    }

    /// @notice Balanced OI should result in minimal/zero funding.
    function test_fundingRate_balanced_nearZero() public {
        _refreshEthPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 100_000e6, 3);
        _refreshEthPrices();
        _commitAndExecute(trader2, ETH_MARKET, PerpDEX.Side.Short, 100_000e6, 3);

        PerpDEX.MarketOI memory oi = perp.getMarketOI(ETH_MARKET);
        assertEq(oi.longOI, oi.shortOI, "OI should be balanced");

        // The funding updated during executeTrade already. Further time won't move it much
        // because the imbalance is zero.
        int256 fundingNow = oi.fundingIndex;

        vm.warp(block.timestamp + 7200); // 2 hours

        // Trigger update via addCollateral
        _refreshEthPrices();
        vm.prank(trader1);
        perp.addCollateral(ETH_MARKET, 1e6);

        PerpDEX.MarketOI memory oiAfter = perp.getMarketOI(ETH_MARKET);
        // With perfectly balanced OI, fundingIndex should not change
        assertEq(oiAfter.fundingIndex, fundingNow, "Funding should not change when OI is balanced");
    }

    /*//////////////////////////////////////////////////////////////
       14. POSITION ISOLATION ACROSS MARKETS
    //////////////////////////////////////////////////////////////*/

    /// @notice Positions in different markets are completely isolated.
    function test_positionIsolation_acrossMarkets() public {
        _refreshCryptoPrices();

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, 50_000e6, 3);
        _refreshBtcPrices();
        _commitAndExecute(trader1, BTC_MARKET, PerpDEX.Side.Short, 80_000e6, 2);

        // Close ETH position
        _refreshEthPrices();
        vm.prank(trader1);
        perp.closePosition(ETH_MARKET);

        // BTC position should still be open
        PerpDEX.Position memory ethPos = perp.getPosition(ETH_MARKET, trader1);
        PerpDEX.Position memory btcPos = perp.getPosition(BTC_MARKET, trader1);

        assertEq(ethPos.size, 0, "ETH position should be closed");
        assertGt(btcPos.size, 0, "BTC position should still be open");
    }

    /*//////////////////////////////////////////////////////////////
        15. REAL TOKEN TRANSFER VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Full cycle: open → close, verify exact token flows with real cNGN.
    function test_realTokenFlows_fullCycle() public {
        _refreshEthPrices();

        uint256 collateral = 100_000e6;

        uint256 traderBefore = cNGN.balanceOf(trader1);
        uint256 vaultBefore = cNGN.balanceOf(address(ethVault));

        _commitAndExecute(trader1, ETH_MARKET, PerpDEX.Side.Long, collateral, 3);

        uint256 traderAfterOpen = cNGN.balanceOf(trader1);
        uint256 vaultAfterOpen = cNGN.balanceOf(address(ethVault));

        assertEq(traderBefore - traderAfterOpen, collateral, "Should deduct collateral");
        assertEq(vaultAfterOpen - vaultBefore, collateral, "Vault should receive collateral");

        // Close
        _refreshEthPrices();
        vm.prank(trader1);
        perp.closePosition(ETH_MARKET);

        uint256 traderAfterClose = cNGN.balanceOf(trader1);
        // Trader should receive something back (collateral ± PnL)
        assertGt(traderAfterClose, traderAfterOpen, "Trader should receive tokens back");
    }

    /*//////////////////////////////////////////////////////////////
                         RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
