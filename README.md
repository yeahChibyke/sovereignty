# Sovereignty — cNGN Perpetual DEX

A high-performance, fully on-chain Perpetual Futures Decentralized Exchange (DEX) on **Base**. The platform allows users to trade **11 markets** across 5 asset classes — Crypto, Commodities, Metals, Equities, and Forex — with up to 5× leverage, using **cNGN (a Nigerian Naira-pegged stablecoin)** as the base margin and settlement currency.

The architecture is split into three core smart contracts:
1. **SovereigntyAccessManager**: A UUPS-upgradeable, role-based access manager (built on OZ `AccessManager`) that governs all permissioned operations across the protocol with granular function-level role bindings.
2. **MarketVault**: An ERC4626-compliant, per-market isolated liquidity vault that underwrites trades for a specific market. Each market (ETH-PERP, BTC-PERP, etc.) has its own vault with independent share tokens (`vcNGN-ETH`, `vcNGN-BTC`, etc.).
3. **PerpDEX**: The trading engine handling commit-reveal order flow, isolated positions, oracle price triangulation (Pyth × Chainlink), funding rates, collateral management, and liquidations with Chainlink Automation 2.1 integration.

---

## Supported Markets

| Category   | Markets                  | Max Leverage | Max Staleness |
|------------|--------------------------|:------------:|:-------------:|
| Crypto     | BTC, ETH, SOL            | 5×           | 120s          |
| Commodity  | BRENT                    | 3×           | 300s          |
| Metal      | XAG, XAU                 | 3×           | 300s          |
| Equity     | NVDA, TSLA, AAPL         | 3×           | 300s          |
| Forex      | EUR, GBP                 | 3×           | 600s          |

All markets share a **2% maintenance margin** and **5× vault-TVL OI cap**.

---

## 👥 For Users

### 1. Traders
As a trader, you can open **Long** or **Short** positions on any of the 11 supported markets.
* **Margin & Risk:** All margin is posted in `cNGN`. You have full control to dynamically **Add Collateral** (to defend against wicks and lower leverage) or **Remove Collateral** (to extract profits early) on live positions.
* **Leverage:** Up to 5× for crypto markets, 3× for non-crypto. Maximize your exposure to price movements safely.
* **Funding Rates:** Fair and low funding rates based on the Long/Short Open Interest balance, carefully scaled (~0.09% daily at maximum imbalance) to prevent aggressive continuous decay.
* **Fair Pricing:** Prices are derived via **dual-oracle triangulation** — Pyth Network provides the Asset/USD price, and a Chainlink feed provides the NGN/USD rate (inverted to USD/NGN). This eliminates single-oracle dependency and protects execution from local manipulation.

### 2. Liquidity Providers (LPs)
LPs deposit `cNGN` into per-market `MarketVault`s to earn from trader losses and protocol-captured liquidation bounties. Each vault is isolated — risk in the ETH market does not affect BTC vault LPs.
* **Yield Capture from Protocol Liquidations:** Unlike traditional systems that leak value to external bots, this protocol uses Chainlink Automation to execute liquidations internally. The 1% liquidation bounty is captured directly by the Vault, instantly increasing the `cNGN` backing your shares.
* **Counterparty to Traders:** Your deposit underwrites the market. If traders win, the vault pays out. If traders lose, their losses are added directly to the vault, growing your share value.
* **Auto-compounding & MEV-Resistant:** Yield is auto-compounding. The share price of each vault (`vcNGN-ETH`, `vcNGN-BTC`, etc.) dynamically reflects both **realized PnL** (settled via token transfers) and **unrealized PnL** (queried live from the PerpDEX via oracle prices), protecting the Vault from LP front-running and ensuring accurate share pricing at all times.

### 3. Liquidators & Automation
Keep the protocol safe! While anyone can monitor positions and liquidate underwater trades via the public `liquidate()` function, the protocol natively implements **Protocol-Owned Liquidations** via Chainlink Automation 2.1 to secure the system and capture value for LPs.

---

## ⚙️ How It Works

### Phase 1: Opening a Position (Commit-Reveal)
To prevent oracle front-running and MEV, the protocol uses a **Commit-Reveal** strategy:
1. **Commit (`requestTrade`)**: The trader submits a hashed version of their desired trade — `keccak256(abi.encode(trader, marketId, side, collateral, leverage, salt))` — binding the order to their address.
2. **Delay**: The system forces a brief delay (2–20 blocks).
3. **Reveal (`executeTrade`)**: The trader reveals the cleartext parameters. The DEX verifies the hash, pulls the `cNGN` collateral into the MarketVault, and records the `Position` using the latest triangulated mark price.

### Phase 2: Active Position & Collateral Management
While a position is active, traders can manage their isolated risk in real-time. Because adjusting margin doesn't open new market exposure, these actions bypass the commit-reveal delay and are executed instantly:
1. **Add Collateral** (`addCollateral`): Traders can deposit more `cNGN` to lower their effective leverage. This pushes their liquidation price further away, acting as a crucial defensive tool during wicks and volatility.
2. **Remove Collateral** (`removeCollateral`): Traders can extract "paper profits" or initial capital when a trade is deeply in profit. The protocol strictly enforces a **Max Leverage Guardrail** — withdrawals that would cause the remaining effective leverage to exceed the market's limit, or leave non-positive equity, are safely reverted.
3. **Funding Rate**: As positions stay open, a continuous per-second funding rate is exchanged between Longs and Shorts based on the Open Interest (OI) imbalance. It is carefully scaled (targeting ~0.09% daily at maximum imbalance) to prevent aggressive decay.
4. **Virtual Precision Accounting**: Position sizes are seamlessly scaled to a unified 18-decimal precision (`1e18`) internally. All realized PnL and collateral moves are converted back to 6-decimal `cNGN` token units at the settlement boundary, minimizing precision loss from rounding.

### Phase 3: Closing & Settlement
1. **Close Position**: A trader can close their position entirely.
2. **PnL Calculation**: The DEX calculates unrealized PnL based on the entry vs. exit oracle price, accounting for any funding accrued.
3. **Vault Settlement**: The DEX commands the market's `MarketVault` to settle the accounting.
    * If profitable, the vault sends `cNGN` to the trader.
    * If at a loss, the vault absorbs the trader's collateral minus what is safely returned to them.

### Phase 4: Protocol-Owned Liquidations (Automation)
If a trader's `Equity` vs `Position Size` drops below the 2% Maintenance Margin ratio, they must be liquidated to prevent bad debt inside the Vault.
The system natively executes **Protocol-Owned Liquidations**:
1. Chainlink Automation Nodes query `checkUpkeep`, which iterates over the `tradersPerMarket` set across all active markets up to a defined gas ceiling.
2. If underwater traders are found, the node triggers `performUpkeep`.
3. The DEX forcefully closes those positions at the current triangulated mark price.
4. **Yield Capture:** Instead of routing the **1% collateral bounty** to external MEV bots, the protocol intercepts it (by validating the `liquidationForwarder` via a Forwarder pattern) and retains the bounty inside the `MarketVault`, rewarding LPs with pure organic yield. Any remaining equity (after the bounty) is returned to the trader, and the position is cleanly wiped.

---

## 💻 For Developers: Technical Architecture

### 1. Dual-Oracle Price Triangulation (Pyth × Chainlink)
The protocol uses two independent oracle systems to derive cNGN-denominated prices:

| Oracle    | Feed                | Role                                      |
|-----------|---------------------|-------------------------------------------|
| **Pyth**  | Asset/USD (11 feeds)| Real-time asset prices with confidence     |
| **Chainlink** | NGN/USD (1 feed) | Naira exchange rate (inverted to USD/NGN) |

The triangulated mark price is computed in `_getMarkPrice()`:

$$Price_{cNGN} = Price_{Asset/USD} \times \frac{1}{Price_{NGN/USD}}$$

Both feeds are secured by staleness checks (per-category for Pyth, 1-hour for Chainlink) and a 2.5% confidence-ratio guard on Pyth prices.

### 2. MarketVault: Isolated Pools & Front-Running Protection
Each market has its own ERC4626 vault, providing **risk isolation** — a catastrophic loss in one market cannot drain liquidity from another. The `totalAssets()` function is dynamically overridden to reflect live trading state:

```
totalAssets() = cNGN Balance − Collateral Held − Unrealized PnL
```

* **O(M) Complexity:** By maintaining volume-weighted average entry prices (`avgLongPrice` & `avgShortPrice`) natively per market in the DEX state, the Vault fetches accurate real-time unrealized PnL independent of arbitrary trader counts.
* This strictly guarantees LP shares cannot be diluted or exploited by depositors entering immediately prior to massive trader liquidations or exiting immediately prior to a successful trader exit payout.

### 3. OpenZeppelin Hardening
* **Pausable**: Trading, liquidations, and closing can be halted via the PAUSER role.
* **ReentrancyGuard**: Applied to all execution and settlement functions.
* **SafeERC20**: Revert-safe token transfers.
* **AccessManaged + SovereigntyAccessManager**: All privileged functions use the `restricted` modifier, delegating authorization to a centralized, UUPS-upgradeable role-based access manager with granular role-to-function mappings (OPERATOR, PAUSER, UPGRADER, VAULT_MANAGER, LIQUIDATOR, MARKET_MANAGER).

### 4. Protocol-Owned Liquidations & Yield Capture
Instead of external snipers extracting liquidator bounties from the Vault's capacity, `PerpDEX` implements a highly optimized internal liquidation engine to protect LPs:
* **Active Trader Set Profiling:** As positions open (`executeTrade`), traders are dynamically pushed to the `tradersPerMarket[marketId]` array. When positions close, they are efficiently swapped and popped out (O(1)). This bounded set ensures that `checkUpkeep` doesn't iterate stale data.
* **Forwarder Pattern Verification:** Utilizing Chainlink Automation 2.1 (`AutomationCompatibleInterface`), the PerpDEX stores a registered `liquidationForwarder`. During `_closePosition`, the contract performs an `isProtocolLiquidation` check: if the liquidator is the `liquidationForwarder`, the 1% `LIQUIDATION_BOUNTY_RATIO` is withheld and retained inside the MarketVault instead of paying external EOAs.
* **Gas-Optimized Upkeeps:** The `checkUpkeep` logic iterates active positions per market up to a strict bound (`MAX_LIQUIDATION_BATCH = 10`). Within `performUpkeep`, the current oracle price is queried exactly once per market and reused across all traders in that batch, avoiding redundant gas-intensive feed calls.

---

## 📁 Project Structure

```
src/
├── PerpDEX.sol                    # Trading engine (commit-reveal, funding, liquidation)
├── MarketVault.sol                # ERC4626 isolated-pool vault per market
└── SovereigntyAccessManager.sol   # UUPS-proxied role-based access manager

script/
├── DeploySAM.s.sol                # Deploy SAM proxy + label roles
└── DeployPerpDEX.s.sol            # Deploy PerpDEX + 11 vaults + SAM bindings

test/
├── PerpDEX.t.sol                  # 53 unit tests (mock oracles)
├── MarketVault.t.sol              # 18 unit tests (mock PerpDEX)
├── SovereigntyAccessManager.t.sol # 9 unit tests
├── mocks/
│   ├── MockcNGN.sol               # 6-decimal ERC20 mock
│   └── MockPerpDEX.sol            # Controllable PnL/collateral mock
└── fork/
    ├── BaseForkSetup.sol          # Shared Base mainnet fork setup
    ├── PythOracleFork.t.sol       # 22 oracle integration tests
    ├── TradingFlowFork.t.sol      # 35 end-to-end trading tests
    ├── VaultFork.t.sol            # 25 vault tests with real cNGN
    ├── LiquidationFork.t.sol      # 27 liquidation & automation tests
    └── GettersFork.t.sol          # 14 getter function tests
```

---

## 🛠 Setup & Testing

### Prerequisites
- [Foundry / Forge](https://book.getfoundry.sh/) installed
- A Base RPC URL (for fork tests) set as `base` in `foundry.toml` `[rpc_endpoints]`

### Build
Compile the smart contracts:
```bash
forge build
```

### Test
Run the full test suite (203 tests across 8 suites — unit tests with mock oracles + mainnet fork tests with live Pyth/Chainlink data):
```bash
forge test -vv --ffi
```

Run only unit tests (no fork, no FFI):
```bash
forge test -vv --no-match-path "test/fork/*"
```

Run only fork tests:
```bash
forge test -vv --ffi --match-path "test/fork/*"
```

<!-- ### Deployment
Deployment is a two-step process:

**Step 1 — Deploy the SovereigntyAccessManager (UUPS proxy):**
```bash
INITIAL_ADMIN=<admin_address> \
forge script script/DeploySAM.s.sol:DeploySAM \
  --rpc-url $BASE_RPC --broadcast --verify
```

**Step 2 — Deploy PerpDEX + 11 MarketVaults + SAM role bindings:**
```bash
SAM_PROXY=<sam_proxy_address> \
forge script script/DeployPerpDEX.s.sol:DeployPerpDEX \
  --rpc-url $BASE_RPC --broadcast --verify
```

> **Note:** Base mainnet addresses (cNGN, Pyth, Chainlink NGN/USD) and all 11 Pyth feed IDs are hardcoded in the deployment script. The deployer must hold `MARKET_MANAGER_ROLE` and `VAULT_MANAGER_ROLE` on the SAM proxy. -->

