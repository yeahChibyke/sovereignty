 Minimal Perpetual Protocol Analysis

  1. Overall Architecture

  This protocol implements a decentralized perpetuals exchange where users can open leveraged long or short positions on crypto assets (e.g., ETH). The
  protocol's architecture is modular, separating concerns into distinct contracts:

   * Position Management (`PositionManager.sol`): The core logic for handling trades.
   * Collateral Management (`CollateralManager.sol`): Manages user funds deposited as collateral.
   * Liquidity Provision (`LPManagerEpoch.sol`): Manages the liquidity pool that acts as the counterparty to all trades.
   * Price Feeds (`PriceOracle.sol`): Provides reliable, external price data to value assets and positions.

  The system is designed so that Liquidity Providers (LPs) pool their assets, and this pool serves as the house or counterparty against which traders open
  positions. LPs profit when traders lose, and vice-versa.

  ---

  2. Contract Breakdown

  a. PositionManager.sol

  This is the main entry point for traders and the central orchestrator of the protocol.

   * Purpose: To manage the lifecycle of a trading position (open, close, liquidate).
   * Key State Variables:
       * positions: A mapping from a position ID to a Position struct containing details like size, entry price, leverage, and owner.
       * userPosition: A mapping from a user's address to their open position ID.
       * lpManager: An instance of the LPManagerEpoch contract.
       * collateralManager: An instance of the CollateralManager contract.
   * Key Entry Points (User-facing):
       * openPosition(leverage, positionType): Allows a user to open a new long or short position. It checks their collateral, calculates the position size, and
         requests the backing liquidity from the LPManagerEpoch.
       * closePosition(positionId): Allows a user to close their own position. It calculates the Profit and Loss (PnL) and settles the funds between the trader's
         collateral and the LP pool.
       * liquidate(positionId): A public function that allows anyone to liquidate an undercollateralized position. The caller (liquidator) receives a fee.
   * How it Functions: It uses the PriceOracle to get real-time asset prices for PnL calculations and liquidation checks. When a position is opened, it instructs
     the LPManagerEpoch to create a TradeLayer, effectively locking liquidity to back that specific trade. When the trade is closed, it directs the settlement of
     funds between the CollateralManager and the LPManagerEpoch.

  b. CollateralManager.sol

  This contract acts as a vault for user deposits.

   * Purpose: To securely hold and account for the collateral deposited by traders.
   * Key State Variables:
       * userDeposits: A mapping from a user's address to a Deposit struct, which tracks their collateral amount.
       * totalDeposits: The total amount of collateral held in the contract.
   * Key Entry Points (User-facing):
       * deposit(amount): Allows users to deposit collateral (e.g., DAI) into the protocol.
       * withdraw(amount): Allows users to withdraw their collateral, but only if they have no open positions.
   * How it Functions: It receives and holds ERC20 tokens. The PositionManager is the owner of this contract and is the only entity authorized to move funds
     internally for PnL settlements via the updateUserDeposit and withdrawLosses functions.

  c. LPManagerEpoch.sol

  This contract manages the liquidity pool using a sophisticated epoch-based system.

   * Purpose: To pool liquidity from LPs and manage its allocation to back trades. The epoch system isolates risk and liquidity across different periods.
   * Key Concepts:
       * Epoch: A time-based cohort of liquidity. New LP deposits go into the currentEpochId.
       * Trade Layer: When a trader opens a position, a corresponding TradeLayer is created. This layer "locks" a specific amount of liquidity from an epoch to
         serve as the counterparty for that trade.
       * Splitting & Rolling Over: When liquidity is locked for a trade, the current epoch is "frozen" and "split." The locked portion remains in the old epoch,
         while the remaining free liquidity is rolled over into a new, active epoch. This ensures that new deposits are not mixed with liquidity already backing
         active trades.
   * Key Entry Points (User-facing):
       * deposit(amount): Allows LPs to add liquidity to the current epoch. They receive "shares" in return.
       * withdrawFromEpoch(epochId, amount): Allows LPs to withdraw their free (unlocked) liquidity from a specific epoch.
   * How it Functions: It acts as the house. When PositionManager requests liquidity via createTradeLayer, it locks the funds. When a trade is closed,
     closeTradeLayer is called to settle the PnL. If the trader lost, the funds are added to the epoch's assets, increasing the value of LP shares. If the trader
     won, the funds are paid out from the epoch's assets.

  d. PriceOracle.sol

  A simple contract to provide external price data.

   * Purpose: To fetch the latest price of assets from a reliable on-chain source.
   * How it Functions: It integrates with Chainlink Data Feeds. The getChainlinkDataFeedLatestAnswer function returns the latest price for a given asset pair
     (e.g., ETH/USD). It includes a check to ensure the price data is not stale.

  ---

  3. User Interaction Workflows

  Trader Workflow

   1. Deposit: The trader calls deposit() on CollateralManager to add collateral (e.g., 1,000 DAI).
   2. Open Position: The trader calls openPosition(leverage: 5, positionType: LONG) on PositionManager.
       * PositionManager reads their 1,000 DAI collateral.
       * It calculates a position size of 5,000 DAI (1,000 * 5x).
       * It calls createTradeLayer(5000) on LPManagerEpoch to lock 5,000 DAI from the LP pool.
       * A new Position is created and stored.
   3. Close Position: The price of ETH increases, and the trader decides to close. They call closePosition() on PositionManager.
       * PositionManager uses PriceOracle to get the current ETH price and calculates a profit of 500 DAI.
       * It calls closeTradeLayer(layerId, profit: 500, lpGains: false) on LPManagerEpoch. The LP pool sends 500 DAI to the CollateralManager.
       * PositionManager calls updateUserDeposit(trader, 500, isIncreasing: true) on CollateralManager. The trader's collateral balance is now 1,500 DAI.
   4. Withdraw: The trader calls withdraw(1500) on CollateralManager to retrieve their initial collateral plus profit.

  Liquidity Provider (LP) Workflow

   1. Deposit: The LP calls deposit(10000) on LPManagerEpoch to provide 10,000 DAI of liquidity. They receive shares representing their portion of the pool.
   2. Wait: The LP's capital is now in the pool, being used as the counterparty for trades. If traders collectively lose money, the value of the LP's shares
      increases. If traders win, it decreases.
   3. Withdraw: The LP can call withdrawFromEpoch() to redeem their shares for the underlying DAI, provided that liquidity is not locked in an active trade layer.
      Due to the epoch-splitting mechanism, their funds might be spread across multiple epochs, some locked and some free.

  ---

 