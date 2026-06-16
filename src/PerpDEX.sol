// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    AutomationCompatibleInterface
} from "chainlink-evm/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {AggregatorV3Interface} from "chainlink-evm/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {PythUtils} from "@pythnetwork/pyth-sdk-solidity/PythUtils.sol";
import {MarketVault} from "./MarketVault.sol";

/// @title PerpDEX
/// @author Sovereignty Protocol
/// @notice Multi-market perpetual futures trading engine for Asset/cNGN markets on Base.
///
/// @dev Core architecture & feature summary:
///
///      ─── Market model ───
///      Each tradeable asset (ETH, BTC, SOL, etc.) is a separate "market" identified by a
///      `bytes32 marketId` (e.g. `keccak256("ETH-PERP")`). Markets are added/removed by
///      the admin via `SovereigntyAccessManager`. Each market has:
///        - its own `MarketVault` (isolated ERC4626 liquidity pool),
///        - its own Pyth Asset/USD price feed,
///        - independent leverage/margin/OI parameters.
///      Risk is fully isolated: LP deposits in the ETH vault cannot be drained by losses
///      in the BTC market. This follows the GMX V2 / Synthetix V3 isolated-pool pattern.
///
///      ─── Oracle triangulation ───
///      All positions and collateral are denominated in cNGN (a Naira stablecoin). To price
///      an asset in cNGN, the contract performs a two-hop conversion:
///        1. Asset/USD  — fetched from a per-market Pyth price feed.
///        2. USD/NGN    — derived by inverting a Chainlink NGN/USD feed on Base.
///        → Asset/cNGN = Asset/USD × USD/NGN
///      Both legs include staleness and sanity checks (confidence ratio for Pyth,
///      updatedAt + answer > 0 for Chainlink).
///
///      ─── Order flow (commit-reveal) ───
///      Trade execution uses a two-step commit-reveal pattern to prevent front-running:
///        1. `requestTrade()` — trader commits a hash of their order parameters.
///        2. `executeTrade()` — trader reveals parameters after a block delay; the hash is
///           verified, and the position is opened at the current mark price, subject to the
///           committed `acceptablePrice` slippage bound and `deadline`.
///      The delay window is [MIN_BLOCK_DELAY, MAX_BLOCK_DELAY] blocks.
///
///      ─── Funding rate ───
///      A continuous funding rate incentivizes OI balance. Funding is strictly zero-sum
///      between traders: the dominant side pays exactly what the minority side receives,
///      scaled by the imbalance ratio `imbalance = (longOI − shortOI) / totalOI`. Each side
///      has its own cumulative index (`longFundingIndex` / `shortFundingIndex`), updated on
///      every trade/close/liquidation and applied as a PnL adjustment at settlement. A
///      one-sided market accrues no funding (there is no counterparty). Pending funding is
///      also netted into `MarketVault.totalAssets()` so LP share pricing stays accurate.
///
///      ─── Liquidations ───
///      A position is liquidatable when its equity (collateral + unrealized PnL − funding)
///      falls below `maintenanceMarginRatio × positionSize`. The bounty is 1% of the position's
///      COLLATERAL (not remaining equity), so even underwater/bankrupt positions remain
///      profitable to clear. Two paths exist:
///        a) Public liquidation — anyone calls `liquidate()` and earns the bounty.
///        b) Automated liquidation — Chainlink Automation nodes call `checkUpkeep()` /
///           `performUpkeep()` via a registered forwarder (bounty retained in the vault as LP
///           yield). Batch-processes up to 10 liquidations per call.
///      Liquidation paths are intentionally NOT pausable (they are the LP-solvency backstop),
///      though they still require a fresh oracle and so cannot run on stale prices.
///
///      ─── Access control ───
///      Admin functions (`addMarket`, `disableMarket`, `pause`, etc.) use the `restricted`
///      modifier from OpenZeppelin's `AccessManaged`, delegating authorization to
///      `SovereigntyAccessManager` where role-to-function mappings are configured.
contract PerpDEX is ReentrancyGuard, AccessManaged, Pausable, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice 1e18 — universal fixed-point precision used throughout the contract.
    /// @dev All position sizes, mark prices, funding indices, and internal calculations
    ///      operate at 18-decimal precision. Token amounts (cNGN, 6 dec) are scaled up
    ///      to PRECISION for math and scaled back down for settlement.
    uint256 public constant PRECISION = 1e18;

    /// @notice Fraction of a position's COLLATERAL paid to the liquidator as a bounty (1%).
    /// @dev Expressed in PRECISION: 1e16 / 1e18 = 0.01 = 1%.
    ///      Based on collateral (not remaining equity) so liquidating an underwater/bankrupt
    ///      position is still profitable. A solvent trader funds the bounty from their payout;
    ///      otherwise it is covered by the retained collateral. For automated (forwarder)
    ///      liquidations the bounty stays in the vault as protocol yield instead of being paid out.
    uint256 public constant LIQUIDATION_BOUNTY_RATIO = 1e16; // 1%

    /// @notice Minimum number of blocks a trader must wait after committing before executing.
    /// @dev On Base (~2s block time), 1 block ≈ 2 seconds. Prevents same-block oracle
    ///      manipulation: the trader cannot know the execution price at commit time.
    uint256 public constant MIN_BLOCK_DELAY = 1;

    /// @notice Maximum number of blocks after commit during which the order is still valid.
    /// @dev After `commitBlock + MAX_BLOCK_DELAY`, the order expires and must be re-committed.
    ///      On Base, 20 blocks ≈ 40 seconds — long enough for normal execution, short enough
    ///      to prevent stale-order abuse.
    uint256 public constant MAX_BLOCK_DELAY = 20;

    /// @notice Per-second funding rate scaling factor.
    /// @dev At maximum imbalance (100% long or 100% short), the funding rate accrues at
    ///      `FUNDING_RATE_PER_SECOND / PRECISION` per second ≈ 0.000001% / sec ≈ 0.0036% / hr.
    ///      The actual rate is proportional to the OI imbalance ratio.
    uint256 public constant FUNDING_RATE_PER_SECOND = 1e10;

    /// @notice Maximum number of liquidations processed in a single `performUpkeep` call.
    /// @dev Caps gas usage per Automation callback. If more positions are liquidatable, they
    ///      will be picked up in subsequent Automation rounds.
    uint256 public constant MAX_LIQUIDATION_BATCH = 10;

    /// @notice Target decimal precision for Pyth price normalization.
    /// @dev Pyth prices arrive with a variable `expo` (e.g. -8 for 8 decimals). PythUtils
    ///      normalizes them to `PYTH_TARGET_DECIMALS` (18) so they align with PRECISION.
    uint8 public constant PYTH_TARGET_DECIMALS = 18;

    /// @notice Maximum acceptable confidence-to-price ratio (2.5%).
    /// @dev Pyth prices include a 95% confidence interval. If `conf / price > 2.5%`,
    ///      the price is deemed too uncertain and the transaction reverts with
    ///      `PriceConfidenceTooWide`. This guards against trading on noisy or illiquid feeds.
    ///      Expressed in PRECISION: 25e15 / 1e18 = 0.025 = 2.5%.
    uint256 public constant MAX_CONFIDENCE_RATIO = 25e15; // 2.5%

    /// @notice Grace period (seconds) that must elapse after the L2 sequencer recovers before
    ///         Chainlink prices are accepted again.
    /// @dev Guards against acting on prices in the window right after the sequencer comes back,
    ///      when users have not yet had a fair chance to react. 1 hour.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600;

    /*//////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Direction of a perpetual futures position.
    enum Side {
        Long, //  Profits when asset price rises
        Short // Profits when asset price falls
    }

    /// @notice Category of a listed market. Used for frontend classification and
    ///         potential future per-category parameter defaults.
    enum MarketType {
        Crypto, //   e.g. ETH, BTC, SOL
        Commodity, // e.g. OIL, WHEAT
        Equity, //    e.g. AAPL, TSLA
        FX, //        e.g. EUR/USD
        Metal //      e.g. XAU (gold)
    }

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Represents a single trader's open position in a specific market.
    /// @dev Stored in `positions[marketId][trader]`. A zero `size` means no position.
    struct Position {
        uint256 size; //              Notional position size in cNGN (PRECISION scaled, 18 dec)
        uint256 collateral; //        Margin collateral in cNGN (raw token units, 6 dec)
        uint256 averagePrice; //      Weighted average entry price in cNGN (PRECISION scaled)
        int256 entryFundingIndex; //  Snapshot of this side's funding index (long/short) at position open
        Side side; //                 Long or Short
    }

    /// @notice Configuration parameters for a single market.
    /// @dev Stored in `marketConfigs[marketId]`. Set at `addMarket()` and mutable via
    ///      `updateMarketParams()` (except `pythFeedId`, `marketType`, and `vault`).
    struct MarketConfig {
        bytes32 pythFeedId; //             Pyth price feed ID for Asset/USD (immutable per market)
        uint256 maxStaleness; //           Max acceptable Pyth price age in seconds
        uint256 maxLeverage; //            Max leverage multiplier (e.g. 10 = 10× leverage)
        uint256 maintenanceMarginRatio; // Liquidation threshold (PRECISION: 2e16 = 2%)
        uint256 maxOIMultiplier; //        Max total OI as multiple of vault TVL (PRECISION: 5e18 = 5×)
        uint256 maxOpenInterest; //        Absolute OI ceiling (PRECISION cNGN); hard cap independent of TVL
        MarketType marketType; //          Asset class for this market
        MarketVault vault; //              Isolated ERC4626 vault for this market's liquidity
        bool enabled; //                   False = no new positions; existing ones can still close
    }

    /// @notice A pending commit-reveal order. One per trader at a time.
    /// @dev The trader commits a hash, then reveals parameters after a delay.
    struct CommittedOrder {
        bytes32 orderHash; //  keccak256(abi.encode(trader, marketId, side, collateral, leverage, salt))
        uint256 commitBlock; // Block number at which the order was committed
    }

    /// @notice Aggregate open interest (OI) state for a single market.
    /// @dev Stored in `marketOI[marketId]`. Updated on every open/close/liquidation.
    ///      Weighted average prices enable efficient aggregate unrealized PnL calculation
    ///      without iterating over individual positions.
    struct MarketOI {
        uint256 longOI; //              Total long notional (PRECISION scaled cNGN value)
        uint256 shortOI; //             Total short notional (PRECISION scaled cNGN value)
        uint256 sumLongInvEntry; //     Σ over open longs of (size × PRECISION / entryPrice) — for exact aggregate PnL
        uint256 sumShortInvEntry; //    Σ over open shorts of (size × PRECISION / entryPrice) — for exact aggregate PnL
        int256 longFundingIndex; //     Cumulative per-unit funding cost for LONGS (+ = longs pay, − = longs receive)
        int256 shortFundingIndex; //    Cumulative per-unit funding cost for SHORTS (+ = shorts pay, − = shorts receive)
        int256 sumLongEntryFunding; //  Σ over open longs of size × entryFundingIndex (for aggregate funding)
        int256 sumShortEntryFunding; // Σ over open shorts of size × entryFundingIndex (for aggregate funding)
        uint256 lastFundingUpdate; //   Timestamp of the last funding rate update
    }

    /// @notice Comprehensive read-only market snapshot returned by `getMarketInfo()`.
    /// @dev Designed for front-ends and LPs to get all relevant market data in a single
    ///      RPC call instead of requiring 6+ separate getter invocations.
    struct MarketInfo {
        // ── Configuration ──
        bytes32 marketId; //              The unique market identifier
        MarketType marketType; //         Asset class (Crypto, Commodity, etc.)
        bool enabled; //                  Whether new positions can be opened
        uint256 maxLeverage; //           Maximum leverage multiplier
        uint256 maintenanceMarginRatio; // Liquidation threshold (PRECISION)
        uint256 maxOIMultiplier; //       OI cap relative to vault TVL (PRECISION)
        address vault; //                 Address of the market's isolated ERC4626 vault
        // ── Live pricing (all 18 decimals) ──
        uint256 markPriceCngn; //         Asset price in cNGN (Asset/USD × USD/NGN)
        uint256 assetUsdPrice; //         Raw Asset/USD from Pyth
        uint256 usdNgnRate; //            How many NGN per 1 USD (from Chainlink, inverted)
        // ── Open interest (PRECISION scaled) ──
        uint256 longOI; //                Total long notional value
        uint256 shortOI; //               Total short notional value
        int256 longFundingIndex; //       Cumulative per-unit funding index for longs (+ = longs pay)
        int256 shortFundingIndex; //      Cumulative per-unit funding index for shorts (+ = shorts pay)
        // ── Vault & liquidity (token precision, 6 dec) ──
        uint256 vaultTVL; //              LP-available assets in the vault
        uint256 collateralHeld; //        Trader collateral held in the vault
        int256 unrealizedPnL; //          Net unrealized trader PnL (+ = traders winning)
        // ── Active traders ──
        uint256 openTraderCount; //       Number of addresses with open positions
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The cNGN stablecoin used as collateral and quote currency for all markets.
    /// @dev 6-decimal ERC20. On Base: `0x46C85152bFe9f96829aA94755D9f915F9B10EF5F`.
    IERC20 public immutable cNGN;

    /// @notice Pyth Network oracle contract used for all Asset/USD price feeds.
    /// @dev Callers must push fresh price updates via `updatePythPrices()` before trading.
    IPyth public immutable pyth;

    /// @notice Chainlink price feed that reports NGN/USD (e.g. 0.000735 = 1 NGN in USD).
    /// @dev Inverted in `_getUsdNgnRate()` to produce USD/NGN (e.g. ~1,360 NGN per USD).
    ///      Mutable via `setUsdNgnFeed()` in case the feed address changes.
    AggregatorV3Interface public ngnUsdChainlinkFeed;

    /// @notice Maximum acceptable age (in seconds) for the Chainlink NGN/USD price.
    /// @dev If `block.timestamp − updatedAt > usdNgnMaxStaleness`, `_getUsdNgnRate()` reverts.
    uint256 public usdNgnMaxStaleness;

    /// @notice Chainlink L2 Sequencer Uptime feed for the host rollup (Base).
    /// @dev Checked in `_getUsdNgnRate()` before consuming the Chainlink price so the protocol
    ///      rejects prices observed while the sequencer is down or within the grace window after
    ///      it recovers. May be `address(0)` to disable the check (e.g. non-L2 or test contexts);
    ///      production Base deployments must set the real feed
    ///      (`0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`).
    AggregatorV3Interface public immutable sequencerUptimeFeed;

    /// @notice Cached last good mark price per market (PRECISION, 18 dec), written on every
    ///         state-changing price fetch. Used as an oracle-independent fallback for read-only
    ///         vault accounting (`getMarketUnrealizedPnLSafe` → `MarketVault.totalAssets()` previews
    ///         /getters) so views don't revert on a stale feed. NOTE: value-moving LP actions
    ///         (deposit/mint/withdraw/redeem) are separately gated on a FRESH price and therefore
    ///         DO revert during oracle downtime while open interest exists — the cached value is
    ///         intentionally not used to price live entries or exits.
    mapping(bytes32 => uint256) public lastMarkPrice;

    /// @notice Per-market configuration. Key: `marketId` (e.g. `keccak256("ETH-PERP")`).
    mapping(bytes32 => MarketConfig) public marketConfigs;

    /// @notice Ordered list of all market IDs ever added. Used for iteration (e.g. Automation).
    /// @dev Markets are appended at `addMarket()` and never removed, even if disabled.
    bytes32[] public marketIds;

    /// @notice Individual trader positions per market. Key: `marketId → trader address`.
    mapping(bytes32 => mapping(address => Position)) public positions;

    /// @notice Aggregate open interest state per market.
    mapping(bytes32 => MarketOI) public marketOI;

    /// @notice Pending commit-reveal orders per trader. Only one order at a time per address.
    mapping(address => CommittedOrder) public committedOrders;

    /// @notice Total cNGN collateral deposited by traders for a given market.
    /// @dev Token precision (6 dec). Tracked separately so `MarketVault.totalAssets()` can
    ///      exclude it from LP-available assets — collateral belongs to traders, not LPs.
    mapping(bytes32 => uint256) public marketCollateralHeld;

    /// @notice Address of the registered Chainlink Automation forwarder.
    /// @dev Only this address may call `performUpkeep()`. Set after Automation upkeep
    ///      registration via `setForwarder()`. Zero address means Automation is not active.
    address public liquidationForwarder;

    /// @notice List of traders with open positions in each market.
    /// @dev Used by `checkUpkeep()` to iterate and discover liquidatable positions.
    ///      Maintained by `_addTrader()` and `_removeTrader()` (swap-and-pop pattern).
    mapping(bytes32 => address[]) public tradersPerMarket;

    /// @notice Reverse index for `tradersPerMarket`: maps `(marketId, trader) → arrayIndex + 1`.
    /// @dev A value of 0 means the trader has no open position in that market.
    ///      Offset by +1 so zero distinguishes "absent" from "index 0".
    mapping(bytes32 => mapping(address => uint256)) internal _traderIndex;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new market is listed on the protocol.
    event MarketAdded(
        bytes32 indexed marketId,
        bytes32 pythFeedId,
        uint256 maxLeverage,
        uint256 maintenanceMarginRatio,
        address vault,
        MarketType marketType
    );

    /// @notice Emitted when a market is disabled (no new positions can be opened).
    event MarketDisabled(bytes32 indexed marketId);

    /// @notice Emitted when a market's leverage/margin parameters are updated.
    event MarketUpdated(bytes32 indexed marketId, uint256 maxLeverage, uint256 maintenanceMarginRatio);

    /// @notice Emitted when the NGN/USD Chainlink feed is set or changed.
    event UsdNgnFeedConfigured(address feed, uint256 maxStaleness);

    /// @notice Emitted when a trader commits an order hash (step 1 of commit-reveal).
    event TradeCommitted(address indexed trader, bytes32 orderHash, uint256 commitBlock);

    /// @notice Emitted when a position is successfully opened (step 2 of commit-reveal).
    event PositionOpened(
        address indexed trader, bytes32 indexed marketId, Side side, uint256 size, uint256 collateral, uint256 price
    );

    /// @notice Emitted when a trader voluntarily closes their position.
    event PositionClosed(address indexed trader, bytes32 indexed marketId, int256 realisedPnL, uint256 price);

    /// @notice Emitted when a position is liquidated (public or automated).
    event PositionLiquidated(
        address indexed trader, bytes32 indexed marketId, address indexed liquidator, uint256 bounty, uint256 price
    );

    /// @notice Emitted after the funding indices are updated for a market.
    event FundingUpdated(bytes32 indexed marketId, int256 longFundingIndex, int256 shortFundingIndex);

    /// @notice Emitted when a trader adds collateral to their position.
    event CollateralAdded(address indexed trader, bytes32 indexed marketId, uint256 amount);

    /// @notice Emitted when a trader withdraws collateral from their position.
    event CollateralRemoved(address indexed trader, bytes32 indexed marketId, uint256 amount);

    /// @notice Emitted when the Chainlink Automation forwarder address is set.
    event ForwarderSet(address indexed forwarder);

    /// @notice Emitted during an automated liquidation executed by the forwarder.
    /// @param yieldCaptured The bounty amount retained by the protocol (stays in vault).
    event AutomatedLiquidation(address indexed trader, bytes32 indexed marketId, uint256 yieldCaptured);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error MarketNotEnabled(); //            Market is disabled or does not exist
    error MarketAlreadyExists(); //         Duplicate marketId on addMarket
    error InvalidPrice(); //                Oracle returned price ≤ 0
    error PriceConfidenceTooWide(); //      Pyth confidence / price > MAX_CONFIDENCE_RATIO
    error ExceedsMaxLeverage(); //          Requested leverage > market's maxLeverage
    error PositionAlreadyOpen(); //         Trader already has a position in this market
    error NoOpenPosition(); //              No position to close/liquidate/modify
    error NotLiquidatable(); //             Position equity is above maintenance margin
    error ZeroAmount(); //                  Collateral or size is zero
    error NoCommittedOrder(); //            executeTrade called without prior requestTrade
    error TooEarlyToExecute(); //           Block delay not yet satisfied
    error OrderExpired(); //                Beyond MAX_BLOCK_DELAY since commit
    error OrderHashMismatch(); //           Revealed params don't match committed hash
    error InsufficientEquity(); //          Remaining equity ≤ 0 after collateral removal
    error ExceedsLeverageAfterRemoval(); // Post-removal leverage exceeds maxLeverage
    error OnlyForwarder(); //               performUpkeep caller is not the registered forwarder
    error ExceedsMaxOI(); //                New position would breach the OI cap
    error ZeroAddress(); //                 Address parameter is address(0)
    error InvalidParameters(); //           One or more config values are zero
    error StaleChainlinkPrice(); //         Chainlink price is older than usdNgnMaxStaleness
    error SequencerDown(); //               L2 sequencer uptime feed reports the sequencer is down
    error SequencerGracePeriodNotElapsed(); // Sequencer recovered too recently (within grace period)
    error SlippageExceeded(); //            Mark price at execution is outside the committed bound
    error DeadlineExceeded(); //            executeTrade revealed after the committed deadline
    error InsufficientFee(); //             msg.value below the Pyth update fee in updatePythPrices

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys the PerpDEX trading engine.
    /// @dev After deployment, the admin must:
    ///      1. Call `addMarket()` (via SAM) to list at least one market.
    ///      2. Call `setForwarder()` after registering a Chainlink Automation upkeep.
    ///      3. Configure role→function mappings on the `SovereigntyAccessManager`.
    /// @param _cNGN                  Address of the cNGN ERC20 token (6 decimals).
    /// @param _pyth                  Address of the Pyth oracle contract on Base.
    /// @param _ngnUsdChainlinkFeed   Address of the Chainlink NGN/USD price feed on Base.
    /// @param _usdNgnMaxStaleness    Maximum acceptable age (seconds) for the Chainlink price.
    /// @param _accessManager         Address of the SovereigntyAccessManager (UUPS proxy).
    /// @param _sequencerUptimeFeed   Chainlink L2 Sequencer Uptime feed on Base. May be
    ///                               `address(0)` to disable the sequencer check (non-L2/tests).
    constructor(
        address _cNGN,
        address _pyth,
        address _ngnUsdChainlinkFeed,
        uint256 _usdNgnMaxStaleness,
        address _accessManager,
        address _sequencerUptimeFeed
    ) AccessManaged(_accessManager) {
        if (_cNGN == address(0) || _pyth == address(0) || _ngnUsdChainlinkFeed == address(0)) revert ZeroAddress();
        if (_usdNgnMaxStaleness == 0) revert InvalidParameters();
        cNGN = IERC20(_cNGN);
        pyth = IPyth(_pyth);
        ngnUsdChainlinkFeed = AggregatorV3Interface(_ngnUsdChainlinkFeed);
        usdNgnMaxStaleness = _usdNgnMaxStaleness;
        sequencerUptimeFeed = AggregatorV3Interface(_sequencerUptimeFeed);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN — MARKET MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a new perpetual futures market with its own isolated vault.
    /// @dev The vault must already be deployed and its `setPerpDex()` called to link it
    ///      back to this PerpDEX instance. The market is immediately enabled for trading.
    ///      Reverts if a market with the same `_marketId` is already enabled, if the vault
    ///      address is zero, or if any numeric parameter is zero.
    ///      Access: restricted via SovereigntyAccessManager (MARKET_MANAGER_ROLE).
    /// @param _marketId               Unique market identifier (e.g. `keccak256("ETH-PERP")`).
    /// @param _pythFeedId             Pyth price feed ID for Asset/USD.
    /// @param _maxStaleness           Maximum acceptable Pyth price age (seconds).
    /// @param _maxLeverage            Maximum leverage traders can use (e.g. 10 = 10×).
    /// @param _maintenanceMarginRatio Liquidation threshold (PRECISION, e.g. 2e16 = 2%).
    /// @param _maxOIMultiplier        Max total OI as a multiple of vault TVL (PRECISION).
    /// @param _maxOpenInterest        Absolute OI ceiling (PRECISION cNGN), independent of TVL.
    /// @param _marketType             Asset classification for this market.
    /// @param _vault                  Address of the pre-deployed MarketVault for this market.
    function addMarket(
        bytes32 _marketId,
        bytes32 _pythFeedId,
        uint256 _maxStaleness,
        uint256 _maxLeverage,
        uint256 _maintenanceMarginRatio,
        uint256 _maxOIMultiplier,
        uint256 _maxOpenInterest,
        MarketType _marketType,
        address _vault
    ) external restricted {
        // Market IDs are immutable once used: a market ID that has ever been initialized
        // (pythFeedId set) can never be re-added, even after `disableMarket()`. This prevents
        // overwriting a market's config (notably its vault) while stale positions, OI, and
        // collateral accounting still live under the same ID. `pythFeedId == 0` is the
        // contract-wide "market does not exist" sentinel, so it is the canonical existence key.
        if (marketConfigs[_marketId].pythFeedId != bytes32(0)) revert MarketAlreadyExists();
        if (_pythFeedId == bytes32(0)) revert InvalidParameters();
        if (_vault == address(0)) revert ZeroAddress();
        if (_maxLeverage == 0 || _maintenanceMarginRatio == 0 || _maxOIMultiplier == 0 || _maxOpenInterest == 0) {
            revert InvalidParameters();
        }

        marketConfigs[_marketId] = MarketConfig({
            pythFeedId: _pythFeedId,
            maxStaleness: _maxStaleness,
            maxLeverage: _maxLeverage,
            maintenanceMarginRatio: _maintenanceMarginRatio,
            maxOIMultiplier: _maxOIMultiplier,
            maxOpenInterest: _maxOpenInterest,
            marketType: _marketType,
            vault: MarketVault(_vault),
            enabled: true
        });

        marketIds.push(_marketId);

        emit MarketAdded(_marketId, _pythFeedId, _maxLeverage, _maintenanceMarginRatio, _vault, _marketType);
    }

    /// @notice Disable a market so no new positions can be opened.
    /// @dev Existing positions remain open and can be closed or liquidated normally.
    ///      The market stays in the `marketIds` array (for Automation iteration) but
    ///      `executeTrade()` will revert for this market.
    ///      Access: restricted via SovereigntyAccessManager.
    /// @param _marketId The market to disable.
    function disableMarket(bytes32 _marketId) external restricted {
        if (!marketConfigs[_marketId].enabled) revert MarketNotEnabled();
        marketConfigs[_marketId].enabled = false;
        emit MarketDisabled(_marketId);
    }

    /// @notice Update tunable parameters for an existing market.
    /// @dev Does not modify immutable fields (`pythFeedId`, `marketType`, `vault`).
    ///      Works on both enabled and disabled markets (disabled markets may still have
    ///      open positions that need correct margin parameters).
    ///      Access: restricted via SovereigntyAccessManager.
    /// @param _marketId               The market to update.
    /// @param _maxLeverage            New maximum leverage multiplier.
    /// @param _maintenanceMarginRatio New liquidation threshold (PRECISION).
    /// @param _maxOIMultiplier        New OI cap relative to vault TVL (PRECISION).
    /// @param _maxOpenInterest        New absolute OI ceiling (PRECISION cNGN), independent of TVL.
    /// @param _maxStaleness           New maximum Pyth price age (seconds).
    function updateMarketParams(
        bytes32 _marketId,
        uint256 _maxLeverage,
        uint256 _maintenanceMarginRatio,
        uint256 _maxOIMultiplier,
        uint256 _maxOpenInterest,
        uint256 _maxStaleness
    ) external restricted {
        MarketConfig storage cfg = marketConfigs[_marketId];
        if (!cfg.enabled && cfg.pythFeedId == bytes32(0)) revert MarketNotEnabled();
        if (_maxLeverage == 0 || _maintenanceMarginRatio == 0 || _maxOIMultiplier == 0 || _maxOpenInterest == 0) {
            revert InvalidParameters();
        }

        cfg.maxLeverage = _maxLeverage;
        cfg.maintenanceMarginRatio = _maintenanceMarginRatio;
        cfg.maxOIMultiplier = _maxOIMultiplier;
        cfg.maxOpenInterest = _maxOpenInterest;
        cfg.maxStaleness = _maxStaleness;

        emit MarketUpdated(_marketId, _maxLeverage, _maintenanceMarginRatio);
    }

    /// @notice Replace the Chainlink NGN/USD price feed and/or its staleness threshold.
    /// @dev Used if Chainlink deploys a new feed contract or if the staleness window needs
    ///      adjustment. Takes effect immediately for all subsequent price queries.
    ///      Access: restricted via SovereigntyAccessManager.
    /// @param _feed          Address of the new Chainlink AggregatorV3 feed.
    /// @param _maxStaleness  Maximum acceptable price age (seconds) for the new feed.
    function setUsdNgnFeed(address _feed, uint256 _maxStaleness) external restricted {
        if (_feed == address(0)) revert ZeroAddress();
        if (_maxStaleness == 0) revert InvalidParameters();
        ngnUsdChainlinkFeed = AggregatorV3Interface(_feed);
        usdNgnMaxStaleness = _maxStaleness;
        emit UsdNgnFeedConfigured(_feed, _maxStaleness);
    }

    /// @notice Emergency-pause the protocol. All trading, closing, and liquidation functions
    ///         guarded by `whenNotPaused` will revert until `unpause()` is called.
    ///         Access: restricted via SovereigntyAccessManager (PAUSER_ROLE).
    function pause() external restricted {
        _pause();
    }

    /// @notice Resume normal protocol operations after a pause.
    ///         Access: restricted via SovereigntyAccessManager (PAUSER_ROLE).
    function unpause() external restricted {
        _unpause();
    }

    /// @notice Set the Chainlink Automation forwarder address for automated liquidations.
    /// @dev After registering an upkeep on Chainlink Automation 2.1, the returned forwarder
    ///      address must be set here. Only this address can call `performUpkeep()`.
    ///      Access: restricted via SovereigntyAccessManager.
    /// @param _forwarder The Automation forwarder contract address.
    function setForwarder(address _forwarder) external restricted {
        if (_forwarder == address(0)) revert ZeroAddress();
        liquidationForwarder = _forwarder;
        emit ForwarderSet(_forwarder);
    }

    /// @notice Explicitly disable automated (forwarder) liquidations.
    /// @dev Clears `liquidationForwarder` so `performUpkeep()` is no longer callable by anyone.
    ///      Public, permissionless `liquidate()` continues to work. Provided as a distinct,
    ///      auditable action so that disabling automation is intentional rather than an
    ///      accidental zero-address passed to `setForwarder()`.
    ///      Access: restricted via SovereigntyAccessManager.
    function disableForwarder() external restricted {
        liquidationForwarder = address(0);
        emit ForwarderSet(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                      ORACLE — PRICE TRIANGULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the mark price of a market denominated in cNGN.
    /// @dev Performs two-hop triangulation: Asset/USD (Pyth) × USD/NGN (Chainlink inverted).
    ///      Requires that Pyth on-chain prices have been updated recently (via
    ///      `updatePythPrices()`). Reverts if either feed is stale or returns an invalid price.
    /// @param _marketId The market to price.
    /// @return Mark price in cNGN, normalized to PRECISION (18 decimals).
    function getMarkPrice(bytes32 _marketId) external view returns (uint256) {
        return _getMarkPrice(_marketId);
    }

    /// @dev Internal mark price calculation.
    ///      Formula: `Price_cNGN = (Asset/USD × USD/NGN) / 1e18`
    ///      Both `assetUsd` and `usdNgn` are 18-decimal, so dividing by PRECISION keeps
    ///      the result at 18 decimals.
    function _getMarkPrice(bytes32 _marketId) internal view returns (uint256) {
        MarketConfig storage cfg = marketConfigs[_marketId];
        if (cfg.pythFeedId == bytes32(0)) revert MarketNotEnabled();

        uint256 assetUsd = _getPythPrice(cfg.pythFeedId, cfg.maxStaleness); // Asset/USD (18 dec)
        uint256 usdNgn = _getUsdNgnRate(); //                                 USD/NGN  (18 dec)

        return (assetUsd * usdNgn) / PRECISION; // Asset/cNGN (18 dec)
    }

    /// @dev Fetch the live mark price and cache it as the market's last-good price.
    ///      Used by every state-changing operation so that, if the oracle later goes stale,
    ///      read-only LP accounting (`getMarketUnrealizedPnLSafe`, used by `totalAssets()` previews
    ///      and getters) has a recent fallback and does not revert. State-changing callers require a
    ///      fresh price, so the cache only ever advances to a freshly-validated value. (Value-moving
    ///      LP entries/exits are gated on a fresh price and are NOT served from this cache.)
    function _refreshMarkPrice(bytes32 _marketId) internal returns (uint256 markPrice) {
        markPrice = _getMarkPrice(_marketId);
        lastMarkPrice[_marketId] = markPrice;
    }

    /// @dev Fetch a Pyth price, validate it, and normalize to 18 decimals.
    ///
    ///      Validation steps:
    ///        1. Staleness — `getPriceNoOlderThan` reverts if the price is older than `_maxStaleness`.
    ///        2. Non-negative — `price <= 0` → revert.
    ///        3. Confidence — the Pyth 95% confidence interval must satisfy:
    ///           `conf / price < MAX_CONFIDENCE_RATIO` (2.5%).
    ///           Rewritten to avoid division: `conf × PRECISION < MAX_CONFIDENCE_RATIO × price`.
    ///
    ///      Normalization:
    ///        Pyth prices have a variable `expo` (e.g. -8). `PythUtils.convertToUint` scales
    ///        the raw price to `PYTH_TARGET_DECIMALS` (18), so all downstream math uses
    ///        a uniform precision.
    ///
    /// @param _feedId       Pyth price feed identifier for the asset.
    /// @param _maxStaleness Maximum acceptable price age (seconds).
    /// @return Price normalized to 18 decimals (PRECISION).
    function _getPythPrice(bytes32 _feedId, uint256 _maxStaleness) internal view returns (uint256) {
        PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(_feedId, _maxStaleness);

        if (priceData.price <= 0) revert InvalidPrice();

        // Confidence-to-price ratio check (avoids division-by-zero and rounding issues)
        uint256 absPrice = uint256(uint64(priceData.price));
        if (uint256(priceData.conf) * PRECISION > MAX_CONFIDENCE_RATIO * absPrice) {
            revert PriceConfidenceTooWide();
        }

        return PythUtils.convertToUint(priceData.price, priceData.expo, PYTH_TARGET_DECIMALS);
    }

    /// @dev Fetch the USD/NGN exchange rate from the Chainlink NGN/USD feed and invert it.
    ///
    ///      The Chainlink feed reports NGN/USD (e.g. 0.00073480 with 8 decimals = 73480).
    ///      We need USD/NGN (e.g. ~1,360 NGN per 1 USD). Inversion formula:
    ///
    ///        USD/NGN = (PRECISION × 10^feedDecimals) / answer
    ///                = (1e18 × 1e8) / 73480
    ///                ≈ 1,360.9e18   (18-decimal result)
    ///
    ///      Validation:
    ///        - `answer > 0` (non-zero, positive price).
    ///        - `block.timestamp − updatedAt ≤ usdNgnMaxStaleness` (freshness).
    ///
    /// @return USD/NGN rate normalized to 18 decimals (PRECISION).
    function _getUsdNgnRate() internal view returns (uint256) {
        _checkSequencer();

        (, int256 answer,, uint256 updatedAt,) = ngnUsdChainlinkFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > usdNgnMaxStaleness) revert StaleChainlinkPrice();

        uint8 feedDecimals = ngnUsdChainlinkFeed.decimals();
        return (PRECISION * 10 ** feedDecimals) / uint256(answer);
    }

    /// @dev Revert if the L2 sequencer is down or only recently recovered.
    ///      No-op when no sequencer feed is configured (`address(0)`), e.g. non-L2 deployments
    ///      or unit tests. The uptime feed reports `answer == 0` while the sequencer is up and
    ///      `answer == 1` while it is down; `startedAt` marks the last status change.
    function _checkSequencer() internal view {
        AggregatorV3Interface feed = sequencerUptimeFeed;
        if (address(feed) == address(0)) return;

        (, int256 answer, uint256 startedAt,,) = feed.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) revert SequencerGracePeriodNotElapsed();
    }

    /// @notice Push fresh Pyth price data on-chain. Must be called before any price-dependent
    ///         operation (trading, liquidation, collateral management).
    /// @dev The caller must send at least the Pyth update fee; any excess is refunded. The fee is
    ///      funded strictly from `msg.value` (the `require` below), so the contract's own ETH
    ///      balance can never be spent on a caller's update — preventing third parties from
    ///      draining stray/donated ETH held by the contract.
    /// @param _priceUpdate Pyth price update payload(s) obtained from the Hermes API.
    function updatePythPrices(bytes[] calldata _priceUpdate) external payable {
        uint256 fee = pyth.getUpdateFee(_priceUpdate);
        if (msg.value < fee) revert InsufficientFee();
        pyth.updatePriceFeeds{value: fee}(_priceUpdate);

        // Refund excess ETH
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            require(ok);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       FUNDING RATE ENGINE
    //////////////////////////////////////////////////////////////*/

    /// @dev Accrue funding for a market since the last update.
    ///
    ///      Funding is a **zero-sum transfer between longs and shorts**: every cNGN paid by
    ///      the dominant side is received by the minority side. Each side has its own cumulative
    ///      per-unit index (`+` = that side pays). The paying side accrues the standard
    ///      imbalance-scaled rate; the receiving side accrues a credit scaled by the OI ratio
    ///      so that `total paid == total received`:
    ///
    ///        imbalance = (longOI − shortOI) / totalOI                 ∈ [-1, 1]  (PRECISION)
    ///        D         = imbalance × FUNDING_RATE_PER_SECOND × elapsed / PRECISION
    ///
    ///        longs dominant (D > 0):  longΔ = +D,  shortΔ = −D × longOI / shortOI
    ///        shorts dominant (D < 0): shortΔ = −D, longΔ  = +D × shortOI / longOI
    ///
    ///        total longs pay  = longOI  × longΔ  / PRECISION
    ///        total shorts get = shortOI × |shortΔ| / PRECISION   (equal, opposite sign)
    ///
    ///      A counterparty is required on BOTH sides for any exchange: when either side has
    ///      zero OI, no funding accrues (there is no one to pay or receive). This also means a
    ///      fully one-sided market accrues nothing — unlike a funding-to-LP design.
    ///
    ///      Called at the start of every state-changing operation (open, close, liquidate,
    ///      add/remove collateral) so the indices are current before PnL calculations.
    /// @param _marketId The market to update funding for.
    function _updateFunding(bytes32 _marketId) internal {
        MarketOI storage moi = marketOI[_marketId];

        // First call for this market — initialize timestamp, no accrual needed
        if (moi.lastFundingUpdate == 0) {
            moi.lastFundingUpdate = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - moi.lastFundingUpdate;
        if (elapsed == 0) return; // Same block — no time has passed

        (int256 longDelta, int256 shortDelta) = _fundingDeltas(moi, elapsed);
        if (longDelta != 0 || shortDelta != 0) {
            moi.longFundingIndex += longDelta;
            moi.shortFundingIndex += shortDelta;
            emit FundingUpdated(_marketId, moi.longFundingIndex, moi.shortFundingIndex);
        }
        moi.lastFundingUpdate = block.timestamp;
    }

    /// @dev Compute the per-side funding index deltas for an elapsed interval, given current OI.
    ///      Pure function of `moi` + `elapsed`; used both to mutate state (`_updateFunding`) and
    ///      to project indices forward in view paths (`_currentFundingIndices`).
    /// @return longDelta  Change to apply to `longFundingIndex`  (+ = longs pay).
    /// @return shortDelta Change to apply to `shortFundingIndex` (+ = shorts pay).
    function _fundingDeltas(MarketOI storage moi, uint256 elapsed)
        internal
        view
        returns (int256 longDelta, int256 shortDelta)
    {
        uint256 longOI = moi.longOI;
        uint256 shortOI = moi.shortOI;

        // Zero-sum funding requires a counterparty on both sides.
        if (longOI == 0 || shortOI == 0) return (0, 0);

        uint256 totalOI = longOI + shortOI;
        int256 imbalance = (int256(longOI) - int256(shortOI)) * int256(PRECISION) / int256(totalOI);
        int256 D = imbalance * int256(FUNDING_RATE_PER_SECOND) * int256(elapsed) / int256(PRECISION);

        if (D > 0) {
            // Longs dominant → longs pay D per unit; shorts receive the matching total.
            longDelta = D;
            shortDelta = -(D * int256(longOI) / int256(shortOI));
        } else if (D < 0) {
            // Shorts dominant → shorts pay (−D) per unit; longs receive the matching total.
            shortDelta = -D;
            longDelta = D * int256(shortOI) / int256(longOI); // D < 0 → negative (credit to longs)
        }
    }

    /// @dev Return the funding indices projected forward to `block.timestamp`, so view callers
    ///      see funding accrued since the last on-chain `_updateFunding`. In state-changing
    ///      paths `_updateFunding` runs first, so the projection adds zero there.
    function _currentFundingIndices(MarketOI storage moi) internal view returns (int256 longIndex, int256 shortIndex) {
        longIndex = moi.longFundingIndex;
        shortIndex = moi.shortFundingIndex;

        if (moi.lastFundingUpdate == 0) return (longIndex, shortIndex);
        uint256 elapsed = block.timestamp - moi.lastFundingUpdate;
        if (elapsed == 0) return (longIndex, shortIndex);

        (int256 longDelta, int256 shortDelta) = _fundingDeltas(moi, elapsed);
        longIndex += longDelta;
        shortIndex += shortDelta;
    }

    /// @dev Calculate the funding payment owed by (or owed to) a specific position.
    ///
    ///      The sign is baked into each side's index, so the same formula applies to both:
    ///        `funding = size × (sideIndexNow − entryFundingIndex) / PRECISION`
    ///      Positive = the position pays funding (subtracted from equity); negative = receives.
    ///
    ///      The returned value is subtracted from raw PnL at settlement:
    ///        `netPnL = rawPnL − pendingFunding`
    ///
    /// @param _marketId The market the position belongs to.
    /// @param pos       Storage reference to the trader's position.
    /// @return Funding cost (positive = trader pays, negative = trader receives). PRECISION scaled.
    function _pendingFunding(bytes32 _marketId, Position storage pos) internal view returns (int256) {
        MarketOI storage moi = marketOI[_marketId];
        (int256 longIndex, int256 shortIndex) = _currentFundingIndices(moi);
        int256 sideIndex = pos.side == Side.Long ? longIndex : shortIndex;
        return int256(pos.size) * (sideIndex - pos.entryFundingIndex) / int256(PRECISION);
    }

    /*//////////////////////////////////////////////////////////////
                       COMMIT-REVEAL TRADING
    //////////////////////////////////////////////////////////////*/

    /// @notice Step 1 of the commit-reveal order flow: commit a hashed order.
    /// @dev The trader computes `keccak256(abi.encode(trader, marketId, side, collateral,
    ///      leverage, acceptablePrice, deadline, salt))` off-chain and submits only the hash.
    ///      This prevents miners and searchers from front-running the trade because the
    ///      parameters are hidden, while the committed `acceptablePrice`/`deadline` bound the
    ///      execution so the reveal is not a free option against LPs.
    ///      Only one pending order per address is allowed; a new commit overwrites the old one.
    /// @param _orderHash The keccak256 hash of the order parameters.
    function requestTrade(bytes32 _orderHash) external whenNotPaused {
        committedOrders[msg.sender] = CommittedOrder({orderHash: _orderHash, commitBlock: block.number});
        emit TradeCommitted(msg.sender, _orderHash, block.number);
    }

    /// @notice Step 2 of the commit-reveal order flow: reveal parameters and open a position.
    /// @dev The trader reveals the same parameters used to generate the committed hash.
    ///      Execution is only valid within the block window [commitBlock + MIN_BLOCK_DELAY,
    ///      commitBlock + MAX_BLOCK_DELAY]. The price used is the current mark price, not
    ///      the price at commit time, ensuring the trader cannot lock in a favorable price.
    ///
    ///      Flow:
    ///        1. Verify commit-reveal timing and hash match.
    ///        2. Validate inputs (collateral > 0, market enabled, leverage within bounds).
    ///        3. Update the market's funding index.
    ///        4. Fetch the current mark price (Asset/cNGN via oracle triangulation).
    ///        5. Scale collateral to internal precision and compute notional size.
    ///        6. Check that the position does not breach the market's OI cap.
    ///        7. Transfer cNGN from trader to the market's vault.
    ///        8. Record the position and update aggregate OI / weighted average prices.
    ///        9. Track the trader in the per-market trader set (for Automation iteration).
    ///
    ///      Only one position per (market, trader) is allowed. Call `closePosition()` first
    ///      to open a new one.
    ///
    /// @param _marketId       The market to trade in.
    /// @param _side           Long or Short.
    /// @param _collateral     Margin deposit in cNGN (token precision, 6 decimals).
    /// @param _leverage       Leverage multiplier (e.g. 5 = 5×). Must be ≤ `maxLeverage`.
    /// @param _acceptablePrice Slippage bound (mark price, PRECISION). For a Long, execution
    ///                         requires `markPrice ≤ acceptablePrice`; for a Short,
    ///                         `markPrice ≥ acceptablePrice`. Use `type(uint256).max` (Long) or
    ///                         `0` (Short) to opt out of the bound.
    /// @param _deadline       Latest `block.timestamp` at which the reveal may execute.
    /// @param _salt           Random nonce used in the commit hash to prevent hash collisions.
    function executeTrade(
        bytes32 _marketId,
        Side _side,
        uint256 _collateral,
        uint256 _leverage,
        uint256 _acceptablePrice,
        uint256 _deadline,
        bytes32 _salt
    ) external nonReentrant whenNotPaused {
        // --- Verify commit-reveal ---
        CommittedOrder storage order = committedOrders[msg.sender];
        if (order.commitBlock == 0) revert NoCommittedOrder();
        if (block.number <= order.commitBlock + MIN_BLOCK_DELAY) revert TooEarlyToExecute();
        if (block.number > order.commitBlock + MAX_BLOCK_DELAY) revert OrderExpired();
        if (block.timestamp > _deadline) revert DeadlineExceeded();

        bytes32 expectedHash = keccak256(
            abi.encode(msg.sender, _marketId, _side, _collateral, _leverage, _acceptablePrice, _deadline, _salt)
        );
        if (order.orderHash != expectedHash) revert OrderHashMismatch();

        delete committedOrders[msg.sender];

        // --- Validate inputs ---
        if (_collateral == 0) revert ZeroAmount();

        MarketConfig storage cfg = marketConfigs[_marketId];
        if (!cfg.enabled) revert MarketNotEnabled();
        if (_leverage == 0 || _leverage > cfg.maxLeverage) revert ExceedsMaxLeverage();

        Position storage pos = positions[_marketId][msg.sender];
        if (pos.size > 0) revert PositionAlreadyOpen();

        // --- Update funding ---
        _updateFunding(_marketId);

        // --- Fetch mark price (and cache as last-good for LP fallback accounting) ---
        uint256 markPrice = _refreshMarkPrice(_marketId);

        // --- Enforce committed slippage bound ---
        if (_side == Side.Long) {
            if (markPrice > _acceptablePrice) revert SlippageExceeded();
        } else {
            if (markPrice < _acceptablePrice) revert SlippageExceeded();
        }

        // --- Calculate position size ---
        uint256 collateralScaled = _toInternalPrecision(_collateral);
        uint256 size = collateralScaled * _leverage;

        // --- Check OI cap (against LP liquidity net of trader collateral & unrealized profit) ---
        _checkOICap(_marketId, cfg, size, markPrice);

        // --- Pull collateral from trader to market vault ---
        MarketVault vault = cfg.vault;
        cNGN.safeTransferFrom(msg.sender, address(vault), _collateral);
        marketCollateralHeld[_marketId] += _collateral;

        // --- Store position ---
        // Snapshot this side's funding index as the position's entry. `_updateFunding` ran
        // above, so the side indices are current.
        MarketOI storage moi = marketOI[_marketId];
        int256 entryFundingIndex = _side == Side.Long ? moi.longFundingIndex : moi.shortFundingIndex;
        pos.size = size;
        pos.collateral = _collateral;
        pos.averagePrice = markPrice;
        pos.entryFundingIndex = entryFundingIndex;
        pos.side = _side;

        // --- Update OI, inverse-entry accumulators & aggregate entry funding ---
        // `sum*InvEntry` accumulates `size × PRECISION / entryPrice` so `_marketUnrealizedPnL`
        // can compute the EXACT aggregate PnL `Σ size_i·(mark−entry_i)/entry_i` in closed form
        // (`mark × Σ(size/entry) − OI`) without iterating positions. A volume-weighted ARITHMETIC
        // mean of entry prices is NOT valid here because PnL is non-linear (reciprocal) in entry.
        // `sum*EntryFunding` likewise lets `_aggregatePendingFunding` avoid per-position iteration.
        if (_side == Side.Long) {
            moi.sumLongInvEntry += size * PRECISION / markPrice; // markPrice == entry at open
            moi.longOI += size;
            moi.sumLongEntryFunding += int256(size) * entryFundingIndex;
        } else {
            moi.sumShortInvEntry += size * PRECISION / markPrice;
            moi.shortOI += size;
            moi.sumShortEntryFunding += int256(size) * entryFundingIndex;
        }

        // Register trader in the per-market set for Automation liquidation scans
        _addTrader(_marketId, msg.sender);

        emit PositionOpened(msg.sender, _marketId, _side, size, _collateral, markPrice);
    }

    /*//////////////////////////////////////////////////////////////
                     COLLATERAL MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit additional cNGN collateral into an existing position.
    /// @dev Increases the position's margin, thereby lowering effective leverage and
    ///      reducing liquidation risk. The collateral is transferred to the market's vault.
    ///      Funding is updated before recording the new collateral amount.
    /// @param _marketId The market the position belongs to.
    /// @param _amount   Amount of cNGN to add (token precision, 6 decimals).
    function addCollateral(bytes32 _marketId, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        Position storage pos = positions[_marketId][msg.sender];
        if (pos.size == 0) revert NoOpenPosition();

        _updateFunding(_marketId);

        MarketVault vault = marketConfigs[_marketId].vault;
        cNGN.safeTransferFrom(msg.sender, address(vault), _amount);

        pos.collateral += _amount;
        marketCollateralHeld[_marketId] += _amount;

        emit CollateralAdded(msg.sender, _marketId, _amount);
    }

    /// @notice Withdraw collateral from an existing position, raising effective leverage.
    /// @dev Validates two safety invariants after the hypothetical removal:
    ///      1. Remaining equity (collateral + unrealized PnL − funding) must be > 0.
    ///      2. Resulting leverage (size / equity) must not exceed `maxLeverage`.
    ///      If either check fails, the withdrawal is rejected. Collateral is paid out from
    ///      the market's vault directly to the trader.
    /// @param _marketId The market the position belongs to.
    /// @param _amount   Amount of cNGN to withdraw (token precision, 6 decimals).
    function removeCollateral(bytes32 _marketId, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        Position storage pos = positions[_marketId][msg.sender];
        if (pos.size == 0) revert NoOpenPosition();

        MarketConfig storage cfg = marketConfigs[_marketId];
        _updateFunding(_marketId);

        uint256 markPrice = _refreshMarkPrice(_marketId);
        int256 pnl = _calculatePnL(pos, markPrice);
        int256 funding = _pendingFunding(_marketId, pos);
        int256 netPnL = pnl - funding;

        uint256 remainingCollateralScaled = _toInternalPrecision(pos.collateral - _amount);
        int256 remainingEquity = int256(remainingCollateralScaled) + netPnL;

        if (remainingEquity <= 0) revert InsufficientEquity();
        if (pos.size > uint256(remainingEquity) * cfg.maxLeverage) revert ExceedsLeverageAfterRemoval();

        pos.collateral -= _amount;
        marketCollateralHeld[_marketId] -= _amount;

        cfg.vault.payTrader(msg.sender, _amount);

        emit CollateralRemoved(msg.sender, _marketId, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                          CLOSE POSITION
    //////////////////////////////////////////////////////////////*/

    /// @notice Voluntarily close the caller's position in a market, settling all PnL.
    /// @dev Delegates to `_closePosition()` with `_isLiquidation = false`. The trader
    ///      receives their remaining equity (collateral ± PnL − funding) from the vault.
    /// @param _marketId The market to close the position in.
    function closePosition(bytes32 _marketId) external nonReentrant whenNotPaused {
        _closePosition(_marketId, msg.sender, false, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                           LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless liquidation: anyone can liquidate an underwater position.
    /// @dev The caller earns a liquidation bounty (1% of the position's collateral). The position
    ///      is force-closed and PnL is settled. Reverts with `NotLiquidatable` if above maintenance.
    ///      Intentionally NOT `whenNotPaused`: liquidation is the LP-solvency backstop and must
    ///      stay available during a pause (it still requires a fresh oracle via `_refreshMarkPrice`,
    ///      so it cannot run on stale prices regardless).
    /// @param _marketId The market the position is in.
    /// @param _trader   The address of the trader to liquidate.
    function liquidate(bytes32 _marketId, address _trader) external nonReentrant {
        Position storage pos = positions[_marketId][_trader];
        if (pos.size == 0) revert NoOpenPosition();

        _updateFunding(_marketId);

        uint256 markPrice = _refreshMarkPrice(_marketId);
        _validateAndLiquidate(_marketId, _trader, markPrice, msg.sender);
    }

    /// @dev Validate that a position is liquidatable, then force-close it.
    ///
    ///      Liquidation condition (either triggers liquidation):
    ///        - `equity < 0` (position is bankrupt, trader owes more than collateral), OR
    ///        - `equity × PRECISION < maintenanceMarginRatio × size`
    ///          (equity has fallen below the maintenance margin threshold).
    ///
    ///      If neither condition is met, reverts with `NotLiquidatable`.
    function _validateAndLiquidate(bytes32 _marketId, address _trader, uint256 _markPrice, address _liquidator)
        internal
    {
        Position storage pos = positions[_marketId][_trader];
        MarketConfig storage cfg = marketConfigs[_marketId];
        int256 pnl = _calculatePnL(pos, _markPrice);
        int256 funding = _pendingFunding(_marketId, pos);
        int256 netPnL = pnl - funding;

        uint256 collateralScaled = _toInternalPrecision(pos.collateral);
        int256 equity = int256(collateralScaled) + netPnL;

        if (equity >= 0 && uint256(equity) * PRECISION >= cfg.maintenanceMarginRatio * pos.size) {
            revert NotLiquidatable();
        }

        _closePosition(_marketId, _trader, true, _liquidator);
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL CLOSE + SETTLE
    //////////////////////////////////////////////////////////////*/

    /// @dev Core position closure logic — used by both voluntary close and liquidation.
    ///
    ///      Settlement flow:
    ///        1. Update funding for the market (ensures funding index is current).
    ///        2. Fetch the current mark price and compute net PnL (raw PnL − funding).
    ///        3. Update aggregate OI and recalculate weighted average prices.
    ///        4. Compute trader equity = collateral (scaled to 18 dec) + netPnL.
    ///        5. Convert equity to token precision (6 dec) → `traderReceives`.
    ///        6. If liquidation and equity > 0, deduct the liquidation bounty (1%).
    ///        7. Record realized PnL in the vault via `settlePnL()`.
    ///        8. Pay the trader and (if applicable) the liquidator from the vault.
    ///        9. Delete the position and remove the trader from the per-market set.
    ///
    ///      Automated vs. public liquidation:
    ///        - Public liquidator (any EOA): receives the bounty directly.
    ///        - Automated (forwarder): bounty stays in the vault as protocol yield.
    ///          An `AutomatedLiquidation` event is emitted to track the captured yield.
    ///
    /// @param _marketId      The market the position belongs to.
    /// @param _trader        The trader whose position is being closed.
    /// @param _isLiquidation True if this is a liquidation (bounty logic applies).
    /// @param _liquidator    Address of the liquidator (or forwarder). Ignored if `!_isLiquidation`.
    function _closePosition(bytes32 _marketId, address _trader, bool _isLiquidation, address _liquidator) internal {
        Position storage pos = positions[_marketId][_trader];
        if (pos.size == 0) revert NoOpenPosition();

        MarketConfig storage cfg = marketConfigs[_marketId];
        _updateFunding(_marketId);

        uint256 markPrice = _refreshMarkPrice(_marketId);
        int256 pnl = _calculatePnL(pos, markPrice);
        int256 funding = _pendingFunding(_marketId, pos);
        int256 netPnL = pnl - funding;

        // --- Remove this position's contribution from aggregate OI & accumulators ---
        // Subtract exactly what was added at open: `size × PRECISION / entryPrice` (entryPrice ==
        // pos.averagePrice) and `size × entryFundingIndex`. Because open and close use the same
        // operands, each removal exactly reverses its open with no residual drift.
        MarketOI storage moi = marketOI[_marketId];
        if (pos.side == Side.Long) {
            moi.sumLongInvEntry -= pos.size * PRECISION / pos.averagePrice;
            moi.longOI -= pos.size;
            moi.sumLongEntryFunding -= int256(pos.size) * pos.entryFundingIndex;
        } else {
            moi.sumShortInvEntry -= pos.size * PRECISION / pos.averagePrice;
            moi.shortOI -= pos.size;
            moi.sumShortEntryFunding -= int256(pos.size) * pos.entryFundingIndex;
        }

        // --- Settle PnL and distribute funds ---
        uint256 collateral = pos.collateral;
        marketCollateralHeld[_marketId] -= collateral;

        // Scale collateral to 18 dec and compute equity = collateral + netPnL
        uint256 collateralScaled = _toInternalPrecision(collateral);
        int256 equity = int256(collateralScaled) + netPnL;

        // If equity > 0, trader receives the equivalent in token precision (6 dec).
        // If equity ≤ 0, the position is bankrupt — trader receives nothing.
        uint256 traderReceives;
        if (equity > 0) {
            traderReceives = _fromInternalPrecision(uint256(equity));
        }

        // Liquidation bounty: a fixed fraction (1%) of the position's COLLATERAL, not of
        // remaining equity. Basing it on collateral keeps liquidating an underwater/bankrupt
        // position (equity ≤ 0) profitable, so the permissionless backstop has an incentive to
        // clear bad debt rather than leaving it to bleed LPs. When the trader has positive
        // equity they fund the bounty from their payout; otherwise it is paid from the
        // collateral the vault retains on a bankrupt close (a small, bounded LP cost).
        uint256 bounty;
        bool isProtocolLiquidation = _isLiquidation && _liquidator == liquidationForwarder;
        if (_isLiquidation) {
            bounty = (collateral * LIQUIDATION_BOUNTY_RATIO) / PRECISION;
            if (traderReceives >= bounty) {
                traderReceives -= bounty; // solvent-enough: trader funds their own bounty
            }
            // else: bounty is covered by the retained collateral (vault/LP), traderReceives kept
        }

        MarketVault vault = cfg.vault;

        // Record realized PnL in the vault's accounting (affects share price)
        int256 realisedPnLTokens = _toTokenPnL(netPnL);
        vault.settlePnL(realisedPnLTokens);

        // Pay trader their remaining equity (after bounty deduction)
        if (traderReceives > 0) {
            vault.payTrader(_trader, traderReceives);
        }

        // Public liquidator gets the bounty paid out; forwarder bounty stays in vault
        if (bounty > 0 && !isProtocolLiquidation) {
            vault.payTrader(_liquidator, bounty);
        }

        // Clean up storage
        delete positions[_marketId][_trader];
        _removeTrader(_marketId, _trader);

        // Emit appropriate event(s)
        if (_isLiquidation) {
            if (isProtocolLiquidation) {
                // Forwarder liquidation: the bounty is not paid out, it stays in the vault as
                // protocol yield → emit the retained amount (the collateral-based bounty).
                emit AutomatedLiquidation(_trader, _marketId, bounty);
            }
            emit PositionLiquidated(_trader, _marketId, _liquidator, bounty, markPrice);
        } else {
            emit PositionClosed(_trader, _marketId, realisedPnLTokens, markPrice);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          PNL CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Calculate the raw (pre-funding) PnL of a position at a given mark price.
    ///
    ///      Formula:
    ///        pnl = size × (markPrice − entryPrice) / entryPrice
    ///
    ///      For shorts, the sign is flipped: shorts profit when the price falls.
    ///      Result is in PRECISION (18 decimals), same unit as `size`.
    ///
    /// @param pos        Storage reference to the trader's position.
    /// @param _markPrice Current mark price of the asset in cNGN (PRECISION).
    /// @return Raw PnL in PRECISION. Positive = profit, negative = loss.
    function _calculatePnL(Position storage pos, uint256 _markPrice) internal view returns (int256) {
        int256 priceDelta = int256(_markPrice) - int256(pos.averagePrice);
        int256 pnl = int256(pos.size) * priceDelta / int256(pos.averagePrice);

        if (pos.side == Side.Short) {
            pnl = -pnl; // Shorts profit from price decreases
        }
        return pnl;
    }

    /*//////////////////////////////////////////////////////////////
                          OI CAP CHECK
    //////////////////////////////////////////////////////////////*/

    /// @dev Ensure that adding `_additionalSize` to the market's total OI does not exceed
    ///      the maximum allowed OI, which is defined as `vaultTVL × maxOIMultiplier`.
    ///
    ///      This protects LPs from excessive exposure: if the vault holds 100k cNGN and
    ///      `maxOIMultiplier` is 5×, total OI across both sides is capped at 500k cNGN.
    ///
    ///      The cap is measured against LP-provided liquidity only. From the vault's raw balance
    ///      we subtract (a) trader collateral (`marketCollateralHeld`, trader-owned) and (b) any
    ///      net unrealized trader PROFIT, which is already owed out to winning traders and is not
    ///      free LP capital — so the cap tightens precisely when the vault is least solvent.
    ///      Unrealized trader losses are NOT added back (they are unrealized and may reverse).
    ///      `markPrice` is the fresh price already fetched by `executeTrade`, so the check stays
    ///      oracle-call-free here and cannot revert on a stale feed.
    ///
    ///      NOTE (residual): the raw balance is still a spot read, so liquidity that is deposited
    ///      and then withdrawn in a later transaction (transient/flash LP) can momentarily lift
    ///      the cap, since OI is only validated at open. Fully closing that requires sticky-
    ///      liquidity accounting (e.g. a min-over-window or lock on LP withdrawal) — tracked
    ///      separately; this function bounds the cap to current solvency, not future withdrawals.
    ///
    /// @param _marketId       The market being traded.
    /// @param _cfg            Storage reference to the market's config.
    /// @param _additionalSize The notional size of the new position (PRECISION).
    /// @param _markPrice      Fresh mark price already fetched by the caller (PRECISION).
    function _checkOICap(bytes32 _marketId, MarketConfig storage _cfg, uint256 _additionalSize, uint256 _markPrice)
        internal
        view
    {
        MarketOI storage moi = marketOI[_marketId];
        uint256 totalOI = moi.longOI + moi.shortOI + _additionalSize;

        // LP-available liquidity = raw vault balance − trader collateral held for this market.
        uint256 rawBalance = _toInternalPrecision(IERC20(_cfg.vault.asset()).balanceOf(address(_cfg.vault)));
        uint256 collateralHeld = _toInternalPrecision(marketCollateralHeld[_marketId]);
        uint256 lpLiquidity = rawBalance > collateralHeld ? rawBalance - collateralHeld : 0;

        // Subtract unrealized trader PRICE profit only (already owed to traders). We deliberately
        // use the price-only PnL, NOT `_marketUnrealizedPnL` (which is net of funding): funding is
        // a zero-sum transfer between traders, not LP capital, so it must not move the solvency
        // denominator. `_marketPricePnL` returns PRECISION (18 dec), matching `lpLiquidity`. Only
        // positive (trader-owed) PnL reduces free LP capital; unrealized losses are not added back.
        int256 pricePnL = _marketPricePnL(moi, _markPrice);
        if (pricePnL > 0) {
            uint256 owedToTraders = uint256(pricePnL);
            lpLiquidity = lpLiquidity > owedToTraders ? lpLiquidity - owedToTraders : 0;
        }

        // Cap = min(absolute governance ceiling, TVL-multiple). The absolute ceiling is the hard
        // bound that flash/transient LP liquidity cannot lift (it is independent of vault balance);
        // the TVL-multiple is the secondary, liquidity-relative limit. The tighter of the two wins.
        uint256 maxOI = (lpLiquidity * _cfg.maxOIMultiplier) / PRECISION;
        if (_cfg.maxOpenInterest < maxOI) maxOI = _cfg.maxOpenInterest;
        if (totalOI > maxOI) revert ExceedsMaxOI();
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get a trader's position in a specific market.
    /// @param _marketId The market to query.
    /// @param _trader   The trader's address.
    /// @return The Position struct (zero `size` if no position exists).
    function getPosition(bytes32 _marketId, address _trader) external view returns (Position memory) {
        return positions[_marketId][_trader];
    }

    /// @notice Get aggregate open interest data for a market.
    /// @param _marketId The market to query.
    /// @return The MarketOI struct (longOI, shortOI, average prices, funding index).
    function getMarketOI(bytes32 _marketId) external view returns (MarketOI memory) {
        return marketOI[_marketId];
    }

    /// @notice Get the number of listed markets.
    /// @return Length of the `marketIds` array.
    function marketIdsLength() external view returns (uint256) {
        return marketIds.length;
    }

    /// @notice Check whether a trader's position is currently liquidatable.
    /// @dev Computes equity at the current mark price including pending funding.
    ///      Returns `false` if the trader has no open position.
    /// @param _marketId The market to check.
    /// @param _trader   The trader's address.
    /// @return True if the position can be liquidated, false otherwise.
    function isLiquidatable(bytes32 _marketId, address _trader) external view returns (bool) {
        Position storage pos = positions[_marketId][_trader];
        if (pos.size == 0) return false;

        MarketConfig storage cfg = marketConfigs[_marketId];
        uint256 markPrice = _getMarkPrice(_marketId);
        int256 pnl = _calculatePnL(pos, markPrice);
        int256 funding = _pendingFunding(_marketId, pos);
        int256 netPnL = pnl - funding;

        uint256 collateralScaled = _toInternalPrecision(pos.collateral);
        int256 equity = int256(collateralScaled) + netPnL;

        if (equity < 0) return true;
        return uint256(equity) * PRECISION < cfg.maintenanceMarginRatio * pos.size;
    }

    /// @notice Calculate the aggregate unrealized PnL (net of funding) for all open positions.
    /// @dev Uses inverse-entry accumulators (`sum*InvEntry`) for an exact closed-form aggregate —
    ///      no per-position iteration. Result is in cNGN token precision (6 decimals). Positive =
    ///      traders collectively winning (vault liability). Used by `MarketVault.totalAssets()`.
    /// @param _marketId The market to query.
    /// @return Net unrealized PnL (6 decimals). Positive = traders in profit.
    function getMarketUnrealizedPnL(bytes32 _marketId) external view returns (int256) {
        MarketOI storage moi = marketOI[_marketId];
        if (moi.longOI == 0 && moi.shortOI == 0) return 0;
        return _marketUnrealizedPnL(_marketId, _getMarkPrice(_marketId));
    }

    /// @notice Oracle-independent variant of {getMarketUnrealizedPnL} for read-only fallback.
    /// @dev Uses the cached `lastMarkPrice` instead of a live oracle read, so it never reverts on
    ///      a stale feed. `MarketVault.totalAssets()` falls back to this so previews/getters keep
    ///      working during oracle downtime. NOTE: this does NOT keep value-moving LP actions
    ///      available — `deposit`/`mint`/`withdraw`/`redeem` are all gated on a FRESH price and
    ///      revert during downtime while open interest exists, so no LP can enter OR exit at a
    ///      stale share price. This getter is for informational reads only.
    /// @param _marketId The market to query.
    /// @return Net unrealized PnL (6 decimals) computed from the last cached mark price.
    function getMarketUnrealizedPnLSafe(bytes32 _marketId) external view returns (int256) {
        MarketOI storage moi = marketOI[_marketId];
        if (moi.longOI == 0 && moi.shortOI == 0) return 0;
        uint256 cached = lastMarkPrice[_marketId];
        if (cached == 0) return 0; // No cached price yet — treat as no adjustment
        return _marketUnrealizedPnL(_marketId, cached);
    }

    /// @dev Internal aggregate unrealized PnL calculation, **net of pending funding**.
    ///
    ///      PnL is `Σ size_i·(mark − entry_i)/entry_i`, which is NON-linear (reciprocal) in the
    ///      entry price, so a volume-weighted ARITHMETIC mean entry price is invalid. Instead we
    ///      maintain `sum*InvEntry = Σ(size_i × PRECISION / entry_i)` per side and use the exact
    ///      closed form (no per-position iteration):
    ///
    ///        longPnL  = mark × Σ(size_i/entry_i) − longOI     = mark·sumLongInvEntry/P  − longOI
    ///        shortPnL = shortOI − mark × Σ(size_i/entry_i)    = shortOI − mark·sumShortInvEntry/P
    ///        totalPnL = longPnL + shortPnL − aggregatePendingFunding
    ///
    ///      Funding is netted in so that vault share pricing reflects funding accrued while
    ///      positions are open. Funding is zero-sum between traders, but settlement happens
    ///      per position, so between a payer's close and a receiver's close there is real
    ///      outstanding funding sitting in the vault; subtracting it here keeps `totalAssets()`
    ///      from over- or under-stating LP-available assets.
    ///
    ///      The result is the net amount owed to traders above their collateral, in token
    ///      precision (6 dec). Positive = traders winning (vault liability).
    ///
    /// @param _marketId  The market to compute PnL for.
    /// @param markPrice  Pre-fetched mark price (avoids double oracle call).
    /// @return Net unrealized PnL (price PnL − funding) in cNGN token precision (6 decimals).
    function _marketUnrealizedPnL(bytes32 _marketId, uint256 markPrice) internal view returns (int256) {
        MarketOI storage moi = marketOI[_marketId];
        if (moi.longOI == 0 && moi.shortOI == 0) return 0;

        // Net of pending funding (positive = traders owe traders less; negative = LPs are owed).
        int256 totalPnL = _marketPricePnL(moi, markPrice) - _aggregatePendingFunding(moi);

        // Cap the LP credit from trader LOSSES at recoverable collateral. When traders are losing
        // (totalPnL < 0), LPs gain — but only up to the collateral traders actually posted; the
        // excess is uncollectible bad debt that must NOT inflate `totalAssets()` / share price.
        int256 minPnL = -int256(_toInternalPrecision(marketCollateralHeld[_marketId]));
        if (totalPnL < minPnL) totalPnL = minPnL;

        return _toTokenPnL(totalPnL);
    }

    /// @dev Price-only aggregate unrealized PnL (EXCLUDES funding), in PRECISION (18 dec).
    ///      `Σ size_i·(mark − entry_i)/entry_i`, non-linear (reciprocal) in entry, computed in
    ///      closed form from the inverse-entry accumulators:
    ///        longPnL  = mark·sumLongInvEntry/P  − longOI
    ///        shortPnL = shortOI − mark·sumShortInvEntry/P
    ///      Used by `_marketUnrealizedPnL` (then netted with funding) and by `_checkOICap` (which
    ///      needs price-only profit, since funding is a trader-to-trader transfer, not LP capital).
    function _marketPricePnL(MarketOI storage moi, uint256 markPrice) internal view returns (int256 totalPnL) {
        if (moi.longOI > 0) {
            totalPnL += int256(markPrice) * int256(moi.sumLongInvEntry) / int256(PRECISION) - int256(moi.longOI);
        }
        if (moi.shortOI > 0) {
            totalPnL += int256(moi.shortOI) - int256(markPrice) * int256(moi.sumShortInvEntry) / int256(PRECISION);
        }
    }

    /// @dev Aggregate pending funding across all open positions in a market, in PRECISION (18 dec).
    ///      Positive = traders collectively owe funding; negative = traders are collectively owed.
    ///      Computed from side accumulators without per-position iteration:
    ///        longsPending  = (longOI  × longIndex  − sumLongEntryFunding)  / PRECISION
    ///        shortsPending = (shortOI × shortIndex − sumShortEntryFunding) / PRECISION
    ///      Uses funding indices projected to `block.timestamp` so views are current.
    function _aggregatePendingFunding(MarketOI storage moi) internal view returns (int256) {
        (int256 longIndex, int256 shortIndex) = _currentFundingIndices(moi);
        int256 longs = (int256(moi.longOI) * longIndex - moi.sumLongEntryFunding) / int256(PRECISION);
        int256 shorts = (int256(moi.shortOI) * shortIndex - moi.sumShortEntryFunding) / int256(PRECISION);
        return longs + shorts;
    }

    /// @notice Get the current USD/NGN exchange rate from the Chainlink feed.
    /// @dev Derived by inverting the on-chain NGN/USD Chainlink price.
    ///      Example: if NGN/USD = 0.00073480, then USD/NGN ≈ 1,360.9.
    /// @return USD/NGN rate, normalized to 18 decimals (PRECISION).
    function getUsdNgnRate() external view returns (uint256) {
        return _getUsdNgnRate();
    }

    /// @notice Get the raw Asset/USD price for a market from the Pyth oracle.
    /// @dev Useful for UIs that want to display the USD price independently of the FX rate.
    /// @param _marketId The market to query.
    /// @return Asset/USD price, normalized to 18 decimals (PRECISION).
    function getAssetUsdPrice(bytes32 _marketId) external view returns (uint256) {
        MarketConfig storage cfg = marketConfigs[_marketId];
        if (cfg.pythFeedId == bytes32(0)) revert MarketNotEnabled();
        return _getPythPrice(cfg.pythFeedId, cfg.maxStaleness);
    }

    /// @notice Get the complete list of market IDs ever added to the protocol.
    /// @dev Includes disabled markets. Use `marketConfigs[id].enabled` to filter.
    /// @return Array of all market ID bytes32 values.
    function getAllMarketIds() external view returns (bytes32[] memory) {
        return marketIds;
    }

    /// @notice Get the full configuration for a market.
    /// @dev Returns all fields of `MarketConfig` as a tuple (Solidity auto-generated
    ///      getters for mappings of structs only return individual fields).
    /// @param _marketId The market to query.
    /// @return pythFeedId             Pyth Asset/USD feed ID.
    /// @return maxStaleness           Max acceptable Pyth price age (seconds).
    /// @return maxLeverage            Maximum leverage multiplier.
    /// @return maintenanceMarginRatio Liquidation threshold (PRECISION).
    /// @return maxOIMultiplier        OI cap relative to vault TVL (PRECISION).
    /// @return marketType             Asset classification enum.
    /// @return vault                  Address of the market's MarketVault.
    /// @return enabled                Whether new positions can be opened.
    function getMarketConfig(bytes32 _marketId)
        external
        view
        returns (
            bytes32 pythFeedId,
            uint256 maxStaleness,
            uint256 maxLeverage,
            uint256 maintenanceMarginRatio,
            uint256 maxOIMultiplier,
            MarketType marketType,
            address vault,
            bool enabled
        )
    {
        MarketConfig storage cfg = marketConfigs[_marketId];
        return (
            cfg.pythFeedId,
            cfg.maxStaleness,
            cfg.maxLeverage,
            cfg.maintenanceMarginRatio,
            cfg.maxOIMultiplier,
            cfg.marketType,
            address(cfg.vault),
            cfg.enabled
        );
    }

    /// @notice Get a trader's current position equity in cNGN token precision.
    /// @dev Equity = collateral (scaled to 18 dec) + rawPnL − funding, then converted
    ///      back to 6 decimal token precision. Returns 0 if no position exists.
    /// @param _marketId The market the position is in.
    /// @param _trader   The trader's address.
    /// @return Position equity in cNGN (6 decimals). Can be negative if underwater.
    function getPositionEquity(bytes32 _marketId, address _trader) external view returns (int256) {
        Position storage pos = positions[_marketId][_trader];
        if (pos.size == 0) return int256(0);

        uint256 markPrice = _getMarkPrice(_marketId);
        int256 pnl = _calculatePnL(pos, markPrice);
        int256 funding = _pendingFunding(_marketId, pos);
        int256 netPnL = pnl - funding;

        uint256 collateralScaled = _toInternalPrecision(pos.collateral);
        int256 equity = int256(collateralScaled) + netPnL;
        return _toTokenPnL(equity);
    }

    /// @notice Get the LP-available TVL of a market's vault.
    /// @dev Returns `MarketVault.totalAssets()`, which accounts for trader collateral
    ///      and unrealized PnL. See MarketVault for the full calculation.
    /// @param _marketId The market to query.
    /// @return LP-available assets in cNGN (6 decimals).
    function getMarketVaultTVL(bytes32 _marketId) external view returns (uint256) {
        MarketConfig storage cfg = marketConfigs[_marketId];
        if (address(cfg.vault) == address(0)) revert MarketNotEnabled();
        return cfg.vault.totalAssets();
    }

    /// @notice Comprehensive market snapshot for LPs, traders, and front-ends.
    /// @dev Aggregates configuration, live oracle pricing, open interest, vault liquidity,
    ///      and trader count into a single struct. Eliminates the need for 6+ separate
    ///      RPC calls to piece together market state.
    ///
    ///      May revert if oracle feeds are stale — callers should handle this gracefully
    ///      (e.g. `try/catch` in front-ends or off-chain aggregators).
    ///
    ///      Gas cost: view function, free when called off-chain via `eth_call`.
    ///
    /// @param _marketId  The market to query (e.g. `keccak256("ETH-PERP")`).
    /// @return info  A `MarketInfo` struct containing all relevant market data.
    function getMarketInfo(bytes32 _marketId) external view returns (MarketInfo memory info) {
        MarketConfig storage cfg = marketConfigs[_marketId];
        if (cfg.pythFeedId == bytes32(0) && !cfg.enabled) revert MarketNotEnabled();

        // Config
        info.marketId = _marketId;
        info.marketType = cfg.marketType;
        info.maxLeverage = cfg.maxLeverage;
        info.maintenanceMarginRatio = cfg.maintenanceMarginRatio;
        info.maxOIMultiplier = cfg.maxOIMultiplier;
        info.enabled = cfg.enabled;
        info.vault = address(cfg.vault);

        // Live pricing (may revert if feeds are stale — caller should handle)
        info.markPriceCngn = _getMarkPrice(_marketId);
        info.assetUsdPrice = _getPythPrice(cfg.pythFeedId, cfg.maxStaleness);
        info.usdNgnRate = _getUsdNgnRate();

        // Open interest
        MarketOI storage moi = marketOI[_marketId];
        info.longOI = moi.longOI;
        info.shortOI = moi.shortOI;
        (info.longFundingIndex, info.shortFundingIndex) = _currentFundingIndices(moi);

        // Vault & liquidity
        info.vaultTVL = cfg.vault.totalAssets();
        info.collateralHeld = marketCollateralHeld[_marketId];

        // Unrealized PnL (token precision, 6 dec)
        info.unrealizedPnL = _marketUnrealizedPnL(_marketId, info.markPriceCngn);

        // Active traders
        info.openTraderCount = tradersPerMarket[_marketId].length;
    }

    /*//////////////////////////////////////////////////////////////
                       PRECISION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Scale a cNGN token amount (6 decimals) up to internal precision (18 decimals).
    ///      Used when entering amounts into fixed-point math (PnL, equity, size).
    function _toInternalPrecision(uint256 _amount) internal pure returns (uint256) {
        return _amount * 1e12; // 6 dec → 18 dec
    }

    /// @dev Scale an internal-precision amount (18 decimals) back to cNGN token precision (6 dec).
    ///      Used when converting calculated values back to token amounts for transfers.
    ///      Truncates (rounds down) — the protocol keeps any dust.
    function _fromInternalPrecision(uint256 _amount) internal pure returns (uint256) {
        return _amount / 1e12; // 18 dec → 6 dec
    }

    /// @dev Convert a signed PnL value from internal precision (18 dec) to token precision (6 dec).
    ///      Handles the sign correctly: splits into abs value, scales down, re-applies sign.
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

    // The trader set is an unordered array + reverse-index pattern that supports:
    //   - O(1) add (append + store index)
    //   - O(1) remove (swap last element into removed slot + pop)
    //   - O(n) iteration (for Automation's checkUpkeep scan)
    //
    // The `_traderIndex` mapping stores `arrayIndex + 1` so that 0 means "not present."

    /// @dev Add a trader to the per-market set. No-op if already present.
    function _addTrader(bytes32 _marketId, address _trader) internal {
        if (_traderIndex[_marketId][_trader] != 0) return; // already tracked
        tradersPerMarket[_marketId].push(_trader);
        _traderIndex[_marketId][_trader] = tradersPerMarket[_marketId].length;
    }

    /// @dev Remove a trader from the per-market set using swap-and-pop.
    ///      The last element is moved into the removed slot to keep the array compact.
    function _removeTrader(bytes32 _marketId, address _trader) internal {
        uint256 indexPlusOne = _traderIndex[_marketId][_trader];
        if (indexPlusOne == 0) return;

        uint256 lastIndex = tradersPerMarket[_marketId].length - 1;
        uint256 removeIndex = indexPlusOne - 1;

        if (removeIndex != lastIndex) {
            address lastTrader = tradersPerMarket[_marketId][lastIndex];
            tradersPerMarket[_marketId][removeIndex] = lastTrader;
            _traderIndex[_marketId][lastTrader] = indexPlusOne;
        }

        tradersPerMarket[_marketId].pop();
        delete _traderIndex[_marketId][_trader];
    }

    /// @notice Get the number of traders with open positions in a market.
    /// @param _marketId The market to query.
    /// @return Number of unique addresses with open positions.
    function tradersPerMarketLength(bytes32 _marketId) external view returns (uint256) {
        return tradersPerMarket[_marketId].length;
    }

    /*//////////////////////////////////////////////////////////////
                   CHAINLINK AUTOMATION 2.1
    //////////////////////////////////////////////////////////////*/

    /// @notice Off-chain check called by Chainlink Automation nodes to discover liquidatable
    ///         positions across all markets.
    /// @dev Implements `AutomationCompatibleInterface.checkUpkeep()`. Runs as a `view`
    ///      call (no gas cost). Iterates through all markets and their open positions to
    ///      find up to `MAX_LIQUIDATION_BATCH` (10) liquidatable positions.
    ///
    ///      Design choices:
    ///        - Uses `try/catch` on `getMarkPrice()` so that markets with stale Pyth prices
    ///          are silently skipped rather than reverting the entire check.
    ///        - Pre-allocates fixed-size arrays, then trims to actual count before encoding.
    ///        - `performData` is ABI-encoded `(bytes32[] markets, address[] traders)`.
    ///
    /// @param /* checkData */ Unused. Chainlink passes this from the upkeep registration config.
    /// @return upkeepNeeded  True if at least one position is liquidatable.
    /// @return performData   ABI-encoded arrays of (marketIds, traderAddresses) to liquidate.
    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        bytes32[] memory markets = new bytes32[](MAX_LIQUIDATION_BATCH);
        address[] memory traders = new address[](MAX_LIQUIDATION_BATCH);
        uint256 count;

        for (uint256 i = 0; i < marketIds.length && count < MAX_LIQUIDATION_BATCH; i++) {
            bytes32 mid = marketIds[i];
            MarketOI storage moi = marketOI[mid];
            if (moi.longOI == 0 && moi.shortOI == 0) continue;

            // Try to get price; skip market if stale
            uint256 markPrice;
            try this.getMarkPrice(mid) returns (uint256 p) {
                markPrice = p;
            } catch {
                continue;
            }

            MarketConfig storage cfg = marketConfigs[mid];
            uint256 traderCount = tradersPerMarket[mid].length;

            for (uint256 j = 0; j < traderCount && count < MAX_LIQUIDATION_BATCH; j++) {
                address trader = tradersPerMarket[mid][j];
                Position storage pos = positions[mid][trader];
                if (pos.size == 0) continue;

                int256 pnl = _calculatePnL(pos, markPrice);
                int256 funding = _pendingFunding(mid, pos);
                int256 netPnL = pnl - funding;

                uint256 collateralScaled = _toInternalPrecision(pos.collateral);
                int256 equity = int256(collateralScaled) + netPnL;

                bool liquidatable = equity < 0 || uint256(equity) * PRECISION < cfg.maintenanceMarginRatio * pos.size;

                if (liquidatable) {
                    markets[count] = mid;
                    traders[count] = trader;
                    count++;
                }
            }
        }

        if (count > 0) {
            bytes32[] memory trimmedMarkets = new bytes32[](count);
            address[] memory trimmedTraders = new address[](count);
            for (uint256 k = 0; k < count; k++) {
                trimmedMarkets[k] = markets[k];
                trimmedTraders[k] = traders[k];
            }
            upkeepNeeded = true;
            performData = abi.encode(trimmedMarkets, trimmedTraders);
        }
    }

    /// @notice Execute batched liquidations as identified by `checkUpkeep()`.
    /// @dev Implements `AutomationCompatibleInterface.performUpkeep()`. Only callable by
    ///      the registered Chainlink Automation forwarder (`liquidationForwarder`).
    ///
    ///      Optimizations:
    ///        - Caches the mark price per market so consecutive positions in the same
    ///          market don't trigger redundant oracle reads.
    ///        - Re-validates liquidation eligibility before executing (the position may
    ///          have been closed or the price may have moved since `checkUpkeep()`).
    ///        - Bounties from automated liquidations stay in the vault as protocol yield
    ///          (see `_closePosition` for the `isProtocolLiquidation` logic).
    ///
    /// @param performData ABI-encoded `(bytes32[] markets, address[] traders)` from `checkUpkeep`.
    // NOTE: intentionally NOT `whenNotPaused` — automated liquidation is the LP-solvency backstop
    // and must remain available during a pause (still gated on a fresh oracle via `_refreshMarkPrice`).
    function performUpkeep(bytes calldata performData) external override nonReentrant {
        if (msg.sender != liquidationForwarder) revert OnlyForwarder();

        (bytes32[] memory markets, address[] memory traders) = abi.decode(performData, (bytes32[], address[]));

        // Cache mark price per market — only re-fetch when the market changes
        bytes32 lastMarket;
        uint256 cachedMarkPrice;

        for (uint256 i = 0; i < markets.length; i++) {
            bytes32 mid = markets[i];
            address trader = traders[i];

            // Re-fetch price and update funding only when switching to a new market
            if (mid != lastMarket) {
                lastMarket = mid;
                _updateFunding(mid);
                cachedMarkPrice = _refreshMarkPrice(mid);
            }

            Position storage pos = positions[mid][trader];
            if (pos.size == 0) continue; // Position may have been closed since checkUpkeep

            // Re-validate liquidation: price may have moved favorably since check
            MarketConfig storage cfg = marketConfigs[mid];
            int256 pnl = _calculatePnL(pos, cachedMarkPrice);
            int256 funding = _pendingFunding(mid, pos);
            int256 netPnL = pnl - funding;

            uint256 collateralScaled = _toInternalPrecision(pos.collateral);
            int256 equity = int256(collateralScaled) + netPnL;

            bool stillLiquidatable = equity < 0 || uint256(equity) * PRECISION < cfg.maintenanceMarginRatio * pos.size;

            if (!stillLiquidatable) continue; // No longer liquidatable — skip

            _closePosition(mid, trader, true, liquidationForwarder);
        }
    }

    /// @notice Allows the contract to receive ETH, required for paying Pyth update fees
    ///         and receiving refunds from `updatePythPrices()`.
    receive() external payable {}
}
