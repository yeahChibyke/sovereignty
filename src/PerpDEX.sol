// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AggregatorV3Interface} from "chainlink-evm/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {
    AutomationCompatibleInterface
} from "chainlink-evm/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {cNGNVault} from "./cNGNVault.sol";

/// @title PerpDEX
/// @notice Perpetual futures trading engine for BTC/cNGN, ETH/cNGN, SOL/cNGN.
///         Uses Chainlink triangulation (Asset/USD ÷ NGN/USD), continuous funding,
///         commit-reveal order flow, Chainlink Automation liquidations, and public liquidation with bounties.
contract PerpDEX is ReentrancyGuard, Ownable2Step, Pausable, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice 1e18 — internal precision for all fixed-point math.
    uint256 public constant PRECISION = 1e18;

    /// @notice 1e8 — Chainlink answer precision.
    uint256 public constant CHAINLINK_PRECISION = 1e8;

    /// @notice Maximum allowed leverage (5x).
    uint256 public constant MAX_LEVERAGE = 5;

    /// @notice Maintenance margin ratio (2%, in PRECISION). Below this → liquidatable.
    uint256 public constant MAINTENANCE_MARGIN_RATIO = 2e16; // 2%

    /// @notice Liquidation bounty paid to the caller (1% of remaining collateral, in PRECISION).
    uint256 public constant LIQUIDATION_BOUNTY_RATIO = 1e16; // 1%

    /// @notice Minimum blocks between commit and execute (commit-reveal delay).
    uint256 public constant MIN_BLOCK_DELAY = 1;

    /// @notice Maximum blocks a committed order stays valid.
    uint256 public constant MAX_BLOCK_DELAY = 20;

    /// @notice Funding rate scaling factor per second (~0.0001% per second at max imbalance).
    /// Targets ~0.09% per day at full imbalance, comparable to DeFi perpetual standards.
    uint256 public constant FUNDING_RATE_PER_SECOND = 1e10;

    /// @notice Maximum number of liquidations per performUpkeep batch.
    uint256 public constant MAX_LIQUIDATION_BATCH = 10;

    /*//////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/

    enum Side {
        Long,
        Short
    }

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Position {
        uint256 size; // Position size in cNGN value (PRECISION scaled)
        uint256 collateral; // Collateral in cNGN (raw token units, asset decimals)
        uint256 averagePrice; // Average entry price (PRECISION scaled, in cNGN)
        int256 entryFundingIndex; // Funding index snapshot at entry
        Side side;
    }

    struct AssetConfig {
        AggregatorV3Interface priceFeed; // Asset/USD Chainlink feed
        uint256 maxHeartbeat; // Max acceptable staleness (seconds)
        bool enabled;
    }

    struct CommittedOrder {
        bytes32 orderHash;
        uint256 commitBlock;
    }

    struct MarketOI {
        uint256 longOI; // Total long open interest (PRECISION scaled cNGN value)
        uint256 shortOI; // Total short open interest (PRECISION scaled cNGN value)
        uint256 avgLongPrice; // Weighted average entry price for all longs (PRECISION)
        uint256 avgShortPrice; // Weighted average entry price for all shorts (PRECISION)
        int256 fundingIndex; // Cumulative funding index (PRECISION scaled)
        uint256 lastFundingUpdate; // timestamp of last funding update
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable cNGN;
    cNGNVault public immutable vault;

    /// @notice NGN/USD Chainlink feed (shared across all markets).
    AggregatorV3Interface public ngnUsdFeed;
    uint256 public ngnUsdMaxHeartbeat;

    /// @notice asset address => config (feeds, heartbeats).
    mapping(address => AssetConfig) public assetConfigs;

    /// @notice List of supported asset addresses.
    address[] public supportedAssets;

    /// @notice asset => user => Position
    mapping(address => mapping(address => Position)) public positions;

    /// @notice asset => MarketOI
    mapping(address => MarketOI) public marketOI;

    /// @notice user => CommittedOrder (one pending order per user)
    mapping(address => CommittedOrder) public committedOrders;

    /// @notice Total trader collateral currently held by the vault (token precision, 6 dec).
    uint256 public totalCollateralHeld;

    /// @notice Chainlink Automation forwarder address (set after upkeep registration).
    address public liquidationForwarder;

    /// @notice asset => list of traders with open positions.
    mapping(address => address[]) public tradersPerAsset;

    /// @notice asset => trader => index+1 in tradersPerAsset (0 = not present).
    mapping(address => mapping(address => uint256)) internal _traderIndex;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AssetConfigured(address indexed asset, address priceFeed, uint256 maxHeartbeat);
    event NgnFeedConfigured(address priceFeed, uint256 maxHeartbeat);
    event TradeCommitted(address indexed trader, bytes32 orderHash, uint256 commitBlock);
    event PositionOpened(
        address indexed trader, address indexed asset, Side side, uint256 size, uint256 collateral, uint256 price
    );
    event PositionClosed(address indexed trader, address indexed asset, int256 realisedPnL, uint256 price);
    event PositionLiquidated(
        address indexed trader, address indexed asset, address indexed liquidator, uint256 bounty, uint256 price
    );
    event FundingUpdated(address indexed asset, int256 newFundingIndex);
    event CollateralAdded(address indexed trader, address indexed asset, uint256 amount);
    event CollateralRemoved(address indexed trader, address indexed asset, uint256 amount);
    event ForwarderSet(address indexed forwarder);
    event AutomatedLiquidation(address indexed trader, address indexed asset, uint256 yieldCaptured);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error AssetNotEnabled();
    error StalePrice(address feed, uint256 updatedAt, uint256 maxHeartbeat);
    error InvalidPrice();
    error ExceedsMaxLeverage();
    error PositionAlreadyOpen();
    error NoOpenPosition();
    error NotLiquidatable();
    error ZeroAmount();
    error NoCommittedOrder();
    error TooEarlyToExecute();
    error OrderExpired();
    error OrderHashMismatch();
    error InvalidSide();
    error InsufficientEquity();
    error ExceedsLeverageAfterRemoval();
    error OnlyForwarder();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _cNGN, address _vault, address _ngnUsdFeed, uint256 _ngnUsdMaxHeartbeat, address _owner)
        Ownable(_owner)
    {
        cNGN = IERC20(_cNGN);
        vault = cNGNVault(_vault);
        ngnUsdFeed = AggregatorV3Interface(_ngnUsdFeed);
        ngnUsdMaxHeartbeat = _ngnUsdMaxHeartbeat;
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure (or reconfigure) an asset's Chainlink feed.
    function configureAsset(address _asset, address _priceFeed, uint256 _maxHeartbeat) external onlyOwner {
        bool existed = assetConfigs[_asset].enabled;
        assetConfigs[_asset] =
            AssetConfig({priceFeed: AggregatorV3Interface(_priceFeed), maxHeartbeat: _maxHeartbeat, enabled: true});
        if (!existed) {
            supportedAssets.push(_asset);
        }
        emit AssetConfigured(_asset, _priceFeed, _maxHeartbeat);
    }

    /// @notice Update the NGN/USD feed.
    function setNgnUsdFeed(address _feed, uint256 _maxHeartbeat) external onlyOwner {
        ngnUsdFeed = AggregatorV3Interface(_feed);
        ngnUsdMaxHeartbeat = _maxHeartbeat;
        emit NgnFeedConfigured(_feed, _maxHeartbeat);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Set the Chainlink Automation forwarder address.
    ///         Called by the admin after registering the upkeep.
    function setForwarder(address _forwarder) external onlyOwner {
        liquidationForwarder = _forwarder;
        emit ForwarderSet(_forwarder);
    }

    /*//////////////////////////////////////////////////////////////
                     CHAINLINK TRIANGULATION ORACLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the mark price of an asset denominated in cNGN (PRECISION scaled).
    ///         Price_cNGN = Price_Asset/USD / Price_NGN/USD
    ///         Both prices are validated for staleness.
    function getMarkPrice(address _asset) external view returns (uint256) {
        return _getMarkPrice(_asset);
    }

    function _getMarkPrice(address _asset) internal view returns (uint256) {
        AssetConfig storage cfg = assetConfigs[_asset];
        if (!cfg.enabled) revert AssetNotEnabled();

        // Fetch Asset/USD
        uint256 assetUsd = _getChainlinkPrice(cfg.priceFeed, cfg.maxHeartbeat);

        // Fetch NGN/USD
        uint256 ngnUsd = _getChainlinkPrice(ngnUsdFeed, ngnUsdMaxHeartbeat);

        // Price_cNGN = (assetUsd * PRECISION) / ngnUsd
        // Both assetUsd and ngnUsd are already in CHAINLINK_PRECISION (1e8).
        return (assetUsd * PRECISION) / ngnUsd;
    }

    /// @notice Fetch a Chainlink price and validate staleness. Returns price in CHAINLINK_PRECISION.
    function _getChainlinkPrice(AggregatorV3Interface _feed, uint256 _maxHeartbeat) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = _feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > _maxHeartbeat) {
            revert StalePrice(address(_feed), updatedAt, _maxHeartbeat);
        }
        return uint256(answer);
    }

    /*//////////////////////////////////////////////////////////////
                       FUNDING RATE ENGINE
    //////////////////////////////////////////////////////////////*/

    /// @notice Update the global funding index for an asset based on OI imbalance.
    ///         Funding is linear per-second: longs pay shorts when longOI > shortOI, vice versa.
    function _updateFunding(address _asset) internal {
        MarketOI storage moi = marketOI[_asset];
        if (moi.lastFundingUpdate == 0) {
            moi.lastFundingUpdate = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - moi.lastFundingUpdate;
        if (elapsed == 0) return;

        uint256 totalOI = moi.longOI + moi.shortOI;
        if (totalOI == 0) {
            moi.lastFundingUpdate = block.timestamp;
            return;
        }

        // imbalance = (longOI - shortOI) / totalOI  — signed, in PRECISION
        int256 imbalance = (int256(moi.longOI) - int256(moi.shortOI)) * int256(PRECISION) / int256(totalOI);

        // fundingDelta = imbalance * rate * elapsed
        int256 fundingDelta = imbalance * int256(FUNDING_RATE_PER_SECOND) * int256(elapsed) / int256(PRECISION);

        moi.fundingIndex += fundingDelta;
        moi.lastFundingUpdate = block.timestamp;

        emit FundingUpdated(_asset, moi.fundingIndex);
    }

    /// @notice Calculate the pending funding payment for a position.
    ///         Positive = position owes funding, Negative = position receives funding.
    function _pendingFunding(address _asset, Position storage pos) internal view returns (int256) {
        MarketOI storage moi = marketOI[_asset];
        int256 indexDelta = moi.fundingIndex - pos.entryFundingIndex;

        // Longs pay positive funding, shorts receive positive funding.
        int256 funding;
        if (pos.side == Side.Long) {
            funding = int256(pos.size) * indexDelta / int256(PRECISION);
        } else {
            funding = -(int256(pos.size) * indexDelta / int256(PRECISION));
        }
        return funding;
    }

    /*//////////////////////////////////////////////////////////////
                       COMMIT-REVEAL TRADING
    //////////////////////////////////////////////////////////////*/

    /// @notice Step 1: Commit a trade order hash. The hash encodes the full order params.
    /// @param _orderHash keccak256(abi.encode(trader, asset, side, collateral, leverage, salt))
    function requestTrade(bytes32 _orderHash) external whenNotPaused {
        committedOrders[msg.sender] = CommittedOrder({orderHash: _orderHash, commitBlock: block.number});
        emit TradeCommitted(msg.sender, _orderHash, block.number);
    }

    /// @notice Step 2: Execute the committed trade by revealing the parameters.
    ///         Must wait MIN_BLOCK_DELAY blocks and execute before MAX_BLOCK_DELAY.
    function executeTrade(address _asset, Side _side, uint256 _collateral, uint256 _leverage, bytes32 _salt)
        external
        nonReentrant
        whenNotPaused
    {
        // --- Verify commit-reveal ---
        CommittedOrder storage order = committedOrders[msg.sender];
        if (order.commitBlock == 0) revert NoCommittedOrder();
        if (block.number <= order.commitBlock + MIN_BLOCK_DELAY) revert TooEarlyToExecute();
        if (block.number > order.commitBlock + MAX_BLOCK_DELAY) revert OrderExpired();

        bytes32 expectedHash = keccak256(abi.encode(msg.sender, _asset, _side, _collateral, _leverage, _salt));
        if (order.orderHash != expectedHash) revert OrderHashMismatch();

        // Clear committed order
        delete committedOrders[msg.sender];

        // --- Validate inputs ---
        if (_collateral == 0) revert ZeroAmount();
        if (_leverage == 0 || _leverage > MAX_LEVERAGE) revert ExceedsMaxLeverage();

        AssetConfig storage cfg = assetConfigs[_asset];
        if (!cfg.enabled) revert AssetNotEnabled();

        Position storage pos = positions[_asset][msg.sender];
        if (pos.size > 0) revert PositionAlreadyOpen();

        // --- Update funding before state changes ---
        _updateFunding(_asset);

        // --- Fetch mark price ---
        uint256 markPrice = _getMarkPrice(_asset);

        // --- Calculate position size (PRECISION scaled cNGN notional) ---
        // collateral is in raw cNGN decimals. Convert to PRECISION for internal math.
        uint256 collateralScaled = _toInternalPrecision(_collateral);
        uint256 size = collateralScaled * _leverage;

        // --- Pull collateral from trader to vault ---
        cNGN.safeTransferFrom(msg.sender, address(vault), _collateral);
        totalCollateralHeld += _collateral;

        // --- Store position ---
        MarketOI storage moi = marketOI[_asset];
        pos.size = size;
        pos.collateral = _collateral;
        pos.averagePrice = markPrice;
        pos.entryFundingIndex = moi.fundingIndex;
        pos.side = _side;

        // --- Update OI & weighted average prices ---
        if (_side == Side.Long) {
            moi.avgLongPrice =
                moi.longOI == 0 ? markPrice : (moi.avgLongPrice * moi.longOI + markPrice * size) / (moi.longOI + size);
            moi.longOI += size;
        } else {
            moi.avgShortPrice = moi.shortOI == 0
                ? markPrice
                : (moi.avgShortPrice * moi.shortOI + markPrice * size) / (moi.shortOI + size);
            moi.shortOI += size;
        }

        // --- Track trader in asset's trader set ---
        _addTrader(_asset, msg.sender);

        emit PositionOpened(msg.sender, _asset, _side, size, _collateral, markPrice);
    }

    /*//////////////////////////////////////////////////////////////
                     COLLATERAL MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Add collateral to an existing position, lowering effective leverage.
    /// @param _asset The market the position is in.
    /// @param _amount Raw cNGN amount (6 decimals) to add.
    function addCollateral(address _asset, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        Position storage pos = positions[_asset][msg.sender];
        if (pos.size == 0) revert NoOpenPosition();

        _updateFunding(_asset);

        // Pull cNGN from trader directly to the vault
        cNGN.safeTransferFrom(msg.sender, address(vault), _amount);

        pos.collateral += _amount;
        totalCollateralHeld += _amount;

        emit CollateralAdded(msg.sender, _asset, _amount);
    }

    /// @notice Remove collateral from an existing position, raising effective leverage.
    ///         Reverts if the removal would exceed MAX_LEVERAGE or leave non-positive equity.
    /// @param _asset The market the position is in.
    /// @param _amount Raw cNGN amount (6 decimals) to remove.
    function removeCollateral(address _asset, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        Position storage pos = positions[_asset][msg.sender];
        if (pos.size == 0) revert NoOpenPosition();

        _updateFunding(_asset);

        // Compute current unrealized PnL and pending funding
        uint256 markPrice = _getMarkPrice(_asset);
        int256 pnl = _calculatePnL(pos, markPrice);
        int256 funding = _pendingFunding(_asset, pos);
        int256 netPnL = pnl - funding;

        // Remaining equity after removal (all in PRECISION / 1e18)
        uint256 remainingCollateralScaled = _toInternalPrecision(pos.collateral - _amount);
        int256 remainingEquity = int256(remainingCollateralScaled) + netPnL;

        // Safety: equity must remain positive
        if (remainingEquity <= 0) revert InsufficientEquity();

        // Safety: effective leverage must not exceed MAX_LEVERAGE
        // size / equity <= MAX_LEVERAGE  →  size <= equity * MAX_LEVERAGE
        if (pos.size > uint256(remainingEquity) * MAX_LEVERAGE) revert ExceedsLeverageAfterRemoval();

        pos.collateral -= _amount;
        totalCollateralHeld -= _amount;

        vault.payTrader(msg.sender, _amount);

        emit CollateralRemoved(msg.sender, _asset, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                          CLOSE POSITION
    //////////////////////////////////////////////////////////////*/

    /// @notice Close the caller's position for a given asset, settling PnL.
    function closePosition(address _asset) external nonReentrant whenNotPaused {
        _closePosition(_asset, msg.sender, false, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                           LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone can liquidate an underwater position and earn a bounty.
    function liquidate(address _asset, address _trader) external nonReentrant whenNotPaused {
        Position storage pos = positions[_asset][_trader];
        if (pos.size == 0) revert NoOpenPosition();

        _updateFunding(_asset);

        uint256 markPrice = _getMarkPrice(_asset);
        _validateAndLiquidate(_asset, _trader, markPrice, msg.sender);
    }

    /// @notice Internal: verify maintenance margin breach and close.
    function _validateAndLiquidate(address _asset, address _trader, uint256 _markPrice, address _liquidator) internal {
        Position storage pos = positions[_asset][_trader];
        int256 pnl = _calculatePnL(pos, _markPrice);
        int256 funding = _pendingFunding(_asset, pos);
        int256 netPnL = pnl - funding;

        uint256 collateralScaled = _toInternalPrecision(pos.collateral);
        int256 equity = int256(collateralScaled) + netPnL;

        // Check maintenance margin: equity / size < MAINTENANCE_MARGIN_RATIO
        // Rewritten to: equity * PRECISION < MAINTENANCE_MARGIN_RATIO * size
        if (equity >= 0 && uint256(equity) * PRECISION >= MAINTENANCE_MARGIN_RATIO * pos.size) {
            revert NotLiquidatable();
        }

        _closePosition(_asset, _trader, true, _liquidator);
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL CLOSE + SETTLE
    //////////////////////////////////////////////////////////////*/

    function _closePosition(address _asset, address _trader, bool _isLiquidation, address _liquidator) internal {
        Position storage pos = positions[_asset][_trader];
        if (pos.size == 0) revert NoOpenPosition();

        _updateFunding(_asset);

        uint256 markPrice = _getMarkPrice(_asset);
        int256 pnl = _calculatePnL(pos, markPrice);
        int256 funding = _pendingFunding(_asset, pos);
        int256 netPnL = pnl - funding;

        // --- Update OI & weighted average prices ---
        MarketOI storage moi = marketOI[_asset];
        if (pos.side == Side.Long) {
            if (moi.longOI == pos.size) {
                moi.avgLongPrice = 0;
            } else {
                uint256 oldTotal = moi.avgLongPrice * moi.longOI;
                uint256 removal = pos.averagePrice * pos.size;
                uint256 newOI = moi.longOI - pos.size;
                moi.avgLongPrice = oldTotal > removal ? (oldTotal - removal) / newOI : 0;
            }
            moi.longOI -= pos.size;
        } else {
            if (moi.shortOI == pos.size) {
                moi.avgShortPrice = 0;
            } else {
                uint256 oldTotal = moi.avgShortPrice * moi.shortOI;
                uint256 removal = pos.averagePrice * pos.size;
                uint256 newOI = moi.shortOI - pos.size;
                moi.avgShortPrice = oldTotal > removal ? (oldTotal - removal) / newOI : 0;
            }
            moi.shortOI -= pos.size;
        }

        // --- Settle PnL ---
        uint256 collateral = pos.collateral;
        totalCollateralHeld -= collateral;
        uint256 collateralScaled = _toInternalPrecision(collateral);
        int256 equity = int256(collateralScaled) + netPnL;

        // Clamp equity to zero floor (trader can't owe more than collateral in this model)
        uint256 traderReceives;
        if (equity > 0) {
            traderReceives = _fromInternalPrecision(uint256(equity));
        }

        uint256 bounty;
        bool isProtocolLiquidation = _isLiquidation && _liquidator == liquidationForwarder;
        if (_isLiquidation && traderReceives > 0) {
            bounty = (traderReceives * LIQUIDATION_BOUNTY_RATIO) / PRECISION;
            traderReceives -= bounty;
        }

        // Record PnL on vault in token precision (positive = trader profit, vault loss)
        int256 realisedPnLTokens = _toTokenPnL(netPnL);
        vault.settlePnL(realisedPnLTokens);

        // Pay trader
        if (traderReceives > 0) {
            vault.payTrader(_trader, traderReceives);
        }

        // Pay liquidator bounty (external only; for protocol liquidations bounty stays in vault)
        if (bounty > 0 && !isProtocolLiquidation) {
            vault.payTrader(_liquidator, bounty);
        }

        // Clear position and remove from trader set
        delete positions[_asset][_trader];
        _removeTrader(_asset, _trader);

        if (_isLiquidation) {
            if (isProtocolLiquidation) {
                // Yield captured = what would have been the bounty
                uint256 yieldCaptured = traderReceives > 0
                    ? ((_fromInternalPrecision(uint256(equity)) * LIQUIDATION_BOUNTY_RATIO) / PRECISION)
                    : 0;
                emit AutomatedLiquidation(_trader, _asset, yieldCaptured);
            }
            emit PositionLiquidated(_trader, _asset, _liquidator, bounty, markPrice);
        } else {
            emit PositionClosed(_trader, _asset, realisedPnLTokens, markPrice);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          PNL CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate unrealised PnL for a position (PRECISION scaled, in cNGN terms).
    function _calculatePnL(Position storage pos, uint256 _markPrice) internal view returns (int256) {
        // priceDelta = markPrice - averagePrice (both in PRECISION)
        int256 priceDelta = int256(_markPrice) - int256(pos.averagePrice);

        // pnl = size * priceDelta / averagePrice
        int256 pnl = int256(pos.size) * priceDelta / int256(pos.averagePrice);

        // Shorts profit when price goes down
        if (pos.side == Side.Short) {
            pnl = -pnl;
        }
        return pnl;
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get full position info for a trader on an asset.
    function getPosition(address _asset, address _trader) external view returns (Position memory) {
        return positions[_asset][_trader];
    }

    /// @notice Get the current OI data for an asset.
    function getMarketOI(address _asset) external view returns (MarketOI memory) {
        return marketOI[_asset];
    }

    /// @notice Get the number of supported assets.
    function supportedAssetsLength() external view returns (uint256) {
        return supportedAssets.length;
    }

    /// @notice Check if a position is liquidatable.
    function isLiquidatable(address _asset, address _trader) external view returns (bool) {
        Position storage pos = positions[_asset][_trader];
        if (pos.size == 0) return false;

        uint256 markPrice = _getMarkPrice(_asset);
        int256 pnl = _calculatePnL(pos, markPrice);
        int256 funding = _pendingFunding(_asset, pos);
        int256 netPnL = pnl - funding;

        uint256 collateralScaled = _toInternalPrecision(pos.collateral);
        int256 equity = int256(collateralScaled) + netPnL;

        if (equity < 0) return true;
        return uint256(equity) * PRECISION < MAINTENANCE_MARGIN_RATIO * pos.size;
    }

    /*//////////////////////////////////////////////////////////////
                       PRECISION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert raw cNGN token amount (asset decimals) to PRECISION (1e18).
    ///         Assumes cNGN has 6 decimals; adjust if different.
    function _toInternalPrecision(uint256 _amount) internal pure returns (uint256) {
        return _amount * 1e12; // 6 decimals → 18 decimals
    }

    /// @notice Convert from PRECISION (1e18) back to raw cNGN token amount.
    function _fromInternalPrecision(uint256 _amount) internal pure returns (uint256) {
        return _amount / 1e12; // 18 decimals → 6 decimals
    }

    /// @notice Convert PnL from internal precision (18 dec) to token precision (6 dec).
    function _toTokenPnL(int256 _pnl) internal pure returns (int256) {
        if (_pnl >= 0) {
            return int256(_fromInternalPrecision(uint256(_pnl)));
        } else {
            return -int256(_fromInternalPrecision(uint256(-_pnl)));
        }
    }

    /*//////////////////////////////////////////////////////////////
                     TRADER SET MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Add a trader to an asset's trader set (idempotent).
    function _addTrader(address _asset, address _trader) internal {
        if (_traderIndex[_asset][_trader] != 0) return; // already tracked
        tradersPerAsset[_asset].push(_trader);
        _traderIndex[_asset][_trader] = tradersPerAsset[_asset].length; // store index+1
    }

    /// @notice Remove a trader from an asset's trader set (swap-and-pop).
    function _removeTrader(address _asset, address _trader) internal {
        uint256 indexPlusOne = _traderIndex[_asset][_trader];
        if (indexPlusOne == 0) return; // not tracked

        uint256 lastIndex = tradersPerAsset[_asset].length - 1;
        uint256 removeIndex = indexPlusOne - 1;

        if (removeIndex != lastIndex) {
            address lastTrader = tradersPerAsset[_asset][lastIndex];
            tradersPerAsset[_asset][removeIndex] = lastTrader;
            _traderIndex[_asset][lastTrader] = indexPlusOne;
        }

        tradersPerAsset[_asset].pop();
        delete _traderIndex[_asset][_trader];
    }

    /// @notice Get the count of traders with open positions on an asset.
    function tradersPerAssetLength(address _asset) external view returns (uint256) {
        return tradersPerAsset[_asset].length;
    }

    /*//////////////////////////////////////////////////////////////
                   CHAINLINK AUTOMATION 2.1
    //////////////////////////////////////////////////////////////*/

    /// @notice Called off-chain by Chainlink Automation nodes to detect liquidatable positions.
    ///         Returns up to MAX_LIQUIDATION_BATCH (asset, trader) pairs.
    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        address[] memory assets = new address[](MAX_LIQUIDATION_BATCH);
        address[] memory traders = new address[](MAX_LIQUIDATION_BATCH);
        uint256 count;

        for (uint256 i = 0; i < supportedAssets.length && count < MAX_LIQUIDATION_BATCH; i++) {
            address asset = supportedAssets[i];
            MarketOI storage moi = marketOI[asset];
            if (moi.longOI == 0 && moi.shortOI == 0) continue;

            uint256 markPrice = _getMarkPrice(asset);
            uint256 traderCount = tradersPerAsset[asset].length;

            for (uint256 j = 0; j < traderCount && count < MAX_LIQUIDATION_BATCH; j++) {
                address trader = tradersPerAsset[asset][j];
                Position storage pos = positions[asset][trader];
                if (pos.size == 0) continue;

                int256 pnl = _calculatePnL(pos, markPrice);
                int256 funding = _pendingFunding(asset, pos);
                int256 netPnL = pnl - funding;

                uint256 collateralScaled = _toInternalPrecision(pos.collateral);
                int256 equity = int256(collateralScaled) + netPnL;

                bool liquidatable = equity < 0 || uint256(equity) * PRECISION < MAINTENANCE_MARGIN_RATIO * pos.size;

                if (liquidatable) {
                    assets[count] = asset;
                    traders[count] = trader;
                    count++;
                }
            }
        }

        if (count > 0) {
            // Trim arrays to actual count
            address[] memory trimmedAssets = new address[](count);
            address[] memory trimmedTraders = new address[](count);
            for (uint256 k = 0; k < count; k++) {
                trimmedAssets[k] = assets[k];
                trimmedTraders[k] = traders[k];
            }
            upkeepNeeded = true;
            performData = abi.encode(trimmedAssets, trimmedTraders);
        }
    }

    /// @notice Called by Chainlink Automation forwarder to execute batched liquidations.
    ///         Each liquidation is wrapped in a conditional check for resilience.
    function performUpkeep(bytes calldata performData) external override nonReentrant whenNotPaused {
        if (msg.sender != liquidationForwarder) revert OnlyForwarder();

        (address[] memory assets, address[] memory traders) = abi.decode(performData, (address[], address[]));

        // Cache mark prices per unique asset for gas efficiency
        address lastAsset;
        uint256 cachedMarkPrice;
        bool fundingUpdated;

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            address trader = traders[i];

            // Refresh cache when asset changes
            if (asset != lastAsset) {
                lastAsset = asset;
                _updateFunding(asset);
                cachedMarkPrice = _getMarkPrice(asset);
                fundingUpdated = true;
            }

            // Resilient: skip if position was already closed or is now healthy
            Position storage pos = positions[asset][trader];
            if (pos.size == 0) continue;

            int256 pnl = _calculatePnL(pos, cachedMarkPrice);
            int256 funding = _pendingFunding(asset, pos);
            int256 netPnL = pnl - funding;

            uint256 collateralScaled = _toInternalPrecision(pos.collateral);
            int256 equity = int256(collateralScaled) + netPnL;

            bool stillLiquidatable = equity < 0 || uint256(equity) * PRECISION < MAINTENANCE_MARGIN_RATIO * pos.size;

            if (!stillLiquidatable) continue;

            // Execute liquidation — forwarder is the liquidator (yield capture)
            _closePosition(asset, trader, true, liquidationForwarder);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    GLOBAL UNREALIZED PNL
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate total unrealized PnL across all markets (in token precision, 6 dec).
    ///         Positive = traders are net profitable; negative = traders are net losing.
    ///         Used by the vault to compute LP share price in real-time.
    function getGlobalUnrealizedPnL() external view returns (int256) {
        int256 totalPnL;
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            MarketOI storage moi = marketOI[asset];

            if (moi.longOI == 0 && moi.shortOI == 0) continue;

            uint256 markPrice = _getMarkPrice(asset);

            // Long unrealized PnL: longOI * (markPrice - avgLongPrice) / avgLongPrice
            if (moi.longOI > 0 && moi.avgLongPrice > 0) {
                int256 priceDelta = int256(markPrice) - int256(moi.avgLongPrice);
                totalPnL += int256(moi.longOI) * priceDelta / int256(moi.avgLongPrice);
            }

            // Short unrealized PnL: shortOI * (avgShortPrice - markPrice) / avgShortPrice
            if (moi.shortOI > 0 && moi.avgShortPrice > 0) {
                int256 priceDelta = int256(moi.avgShortPrice) - int256(markPrice);
                totalPnL += int256(moi.shortOI) * priceDelta / int256(moi.avgShortPrice);
            }
        }
        // Convert from internal precision to token precision
        return _toTokenPnL(totalPnL);
    }
}
