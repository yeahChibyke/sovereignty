# cNGN Perpetual DEX

A high-performance, fully on-chain Perpetual Futures Decentralized Exchange (DEX). The platform allows users to trade crypto assets with up to 5x leverage, using **cNGN (a fiat-pegged stablecoin)** as the base margin and settlement currency.

The architecture is split into two core smart contracts:
1. **cNGNVault**: An ERC4626-compliant liquidity pool that underwrites all trades.
2. **PerpDEX**: The trading engine handling isolated positions, funding rates, oracles, and liquidations.

---

## 👥 For Users

### 1. Traders
As a trader, you can open **Long** or **Short** positions on markets like BTC/cNGN, ETH/cNGN, and SOL/cNGN.
* **Margin & Risk:** All margin is posted in `cNGN`. You have full control to dynamically **Add Collateral** (to defend against wicks and lower leverage) or **Remove Collateral** (to extract profits early) on live positions.
* **Leverage:** Up to 5x leverage. Maximize your exposure to price movements safely.
* **Funding Rates:** Real-time, continuous funding rates based on the Long/Short Open Interest balance.
* **Fair Pricing:** Prices are protected from local manipulation via Chainlink oracle triangulation.

### 2. Liquidity Providers (LPs)
LPs deposit `cNGN` into the `cNGNVault` to earn a share of the platform's volume and trader losses. 
* Your deposit underwrites the protocol. If traders win, the vault pays out. If traders lose, their losses are added directly to the vault, growing your share value.
* Yield is auto-compounding. The share price of `vcNGN` dynamically reflects the **Global Unrealized PnL** of all active traders, protecting the Vault from LP front-running and ensuring exact share pricing before trades are settled.

### 3. Liquidators
Keep the protocol safe! Anyone can monitor positions and liquidate underwater trades (positions where margin drops below the 2% Maintenance Margin). Liquidators earn a **1% bounty** on the remaining collateral as a reward.

---

## 🌊 Project Flow & Lifecycle

Here is the step-by-step flow of how actions are processed in the system.

### Phase 1: Opening a Position (Commit-Reveal)
To prevent Oracle front-running and MEV, the protocol uses a **Commit-Reveal** strategy:
1. **Commit (`requestTrade`)**: The trader submits a securely hashed version of their desired trade (Asset, Leverage, Collateral, Side, and a secret Salt).
2. **Delay**: The system forces a brief delay (1-20 blocks).
3. **Reveal (`executeTrade`)**: The trader reveals the cleartext parameters. The DEX verifies the hash, pulls the `cNGN` collateral into the Vault, and records the `Position` using the latest unmanipulated Chainlink mark price.

### Phase 2: Active Position & Collateral Management
While a position is active, traders can manage their isolated risk in real-time. Because adjusting margin doesn't open new market exposure, these actions bypass the commit-reveal delay and are executed instantly:
1. **Add Collateral** (`addCollateral`): Traders can deposit more `cNGN` to lower their effective leverage. This pushes their liquidation price further away, acting as a crucial defensive tool during wicks and volatility.
2. **Remove Collateral** (`removeCollateral`): Traders can extract "paper profits" or initial capital when a trade is deeply in profit. The protocol strictly enforces an **Infinite Leverage Guardrail**—withdrawals that cause the remaining effective leverage to exceed the 5x limit are safely reverted.
3. **Funding Rate**: As positions stay open, a continuous per-second funding rate is exchanged between Longs and Shorts based on the Open Interest (OI) imbalance. It is carefully scaled (targeting ~0.09% daily at maximum imbalance) to prevent aggressive decay.
4. **Virtual Precision Accounting**: Position sizes are seamlessly scaled to a unified 18-decimal precision (`1e18`) internally. All realized PnL and collateral moves are strictly converting back to 6-decimal `cNGN` token units right at the Vault boundary, completely removing precision rounding bugs.

### Phase 3: Closing & Settlement
1. **Close Position**: A trader can close their position entirely.
2. **PnL Calculation**: The DEX calculates Unrealised PnL based on the entry vs. exit oracle price, accounting for any Funding Rate accrued.
3. **Vault Settle**: The DEX commands the `cNGNVault` to settle the accounting. 
    * If profitable, the vault sends `cNGN` to the trader. 
    * If at a loss, the vault absorbs the trader's collateral minus what is safely returned to them.

### Phase 4: Liquidation (If needed)
If a trader's `Equity` vs `Position Size` drops below the 2% Maintenance Margin ratio:
1. A liquidator calls `liquidate(asset, trader)`.
2. The DEX forcefully closes the position at the current mark price.
3. The liquidator is instantly paid a **1% collateral bounty**, the Vault absorbs the remainder, and the position is wiped cleanly.

---

## 💻 For Developers: Technical Architecture

### 1. Chainlink Oracle Triangulation
Standard Chainlink feeds are natively `Asset/USD`. Since our native token is `cNGN`, we must derive the `Asset/cNGN` price directly on-chain using a *Triangulation* model:
```math
Price_{cNGN} = \frac{Price_{Asset/USD}}{Price_{NGN/USD}}
```
This is calculated locally in `_getMarkPrice()`. Both feeds are secured by extensive heartbeat/staleness checks.

### 2. cNGNVault: Global PnL Tracking & Front-Running Protection
The Vault conforms strictly to OpenZeppelin's `ERC4626`. However, standard vaults only account for static token balances. Because `vcNGN` shares must reflect *actively* open trades to prevent LP front-running, `totalAssets()` is dynamically overridden and queried from the `IPerpDEX`:
* `totalAssets() = cNGN Vault Balance - DEX Total Collateral Held - Global Unrealized PnL`
* **O(M) Complexity:** By maintaining volume-weighted average entry prices (`avgLongPrice` & `avgShortPrice`) natively per market in the DEX state, the Vault fetches accurate real-time unrealized PnL in an optimized, multi-asset loop independent of arbitrary trader counts (O(N)).
* This strictly guarantees LP shares cannot be diluted or exploited by depositors entering immediately prior to massive trader liquidations or exiting immediately prior to a successful trader exit payout.

### 3. OpenZeppelin Hardening
* **Pausable**: Trading, liquidations, and closing can be halted by the admin.
* **ReentrancyGuard**: Applied to all execution and settlement functions.
* **SafeERC20**: Revert-safe token transfers.
* **Ownable2Step**: Secure 2-step administration transfers for setting oracle config.

---

## 🛠 Setup & Testing

### Prerequisites
Make sure you have [Foundry / Forge](https://book.getfoundry.sh/) installed.

### Build
Compile the smart contracts:
```bash
forge build
```

### Test
Run the comprehensive test suite (100+ tests including fuzzing, isolated PnL, integration, and commit-reveal logic):
```bash
forge test -vv
```

### Local Deployment Script
The project includes a generic deployment script `script/DeployPerpDEX.s.sol`.
Configure your environment variables (`CNGN_TOKEN`, `NGN_USD_FEED`, and asset-specific feeds) and run:
```bash
forge script script/DeployPerpDEX.s.sol:DeployPerpDEX --rpc-url <YOUR_RPC_URL> --private-key <YOUR_PRIVATE_KEY> --broadcast
```

