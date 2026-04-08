# cNGN Perpetual DEX

A high-performance, fully on-chain Perpetual Futures Decentralized Exchange (DEX). The platform allows users to trade crypto assets with up to 5x leverage, using **cNGN (a fiat-pegged stablecoin)** as the base margin and settlement currency.

The architecture is split into three core smart contracts:
1. **SovereigntyAccessManager**: A UUPS-upgradeable, role-based access manager that governs all permissioned operations across the protocol.
2. **cNGNVault**: An ERC4626-compliant liquidity pool that underwrites all trades.
3. **PerpDEX**: The trading engine handling isolated positions, funding rates, oracles, and liquidations.

---

## 👥 For Users

### 1. Traders
As a trader, you can open **Long** or **Short** positions on markets like BTC/cNGN, ETH/cNGN, and SOL/cNGN.
* **Margin & Risk:** All margin is posted in `cNGN`. You have full control to dynamically **Add Collateral** (to defend against wicks and lower leverage) or **Remove Collateral** (to extract profits early) on live positions.
* **Leverage:** Up to 5x leverage. Maximize your exposure to price movements safely.
* **Funding Rates:** Enjoy fair and low funding rates based on the Long/Short Open Interest balance, carefully scaled to prevent aggressive continuous decay.
* **Fair Pricing:** Prices are protected from local manipulation and flash loans via secure Chainlink oracle triangulation, ensuring accurate and tamper-proof execution.

### 2. Liquidity Providers (LPs)
LPs deposit `cNGN` into the `cNGNVault` to earn from trader losses and protocol-captured liquidation bounties. The protocol is uniquely designed to maximize LP yield:
* **Yield Capture from Protocol Liquidations:** Unlike traditional systems that leak value to external bots, this protocol uses Chainlink Automation to execute liquidations internally. The typical 1% liquidation bounty is captured directly by the Vault, instantly increasing the `cNGN` backing your shares.
* **Counterparty to Traders:** Your deposit underwrites the protocol. If traders win, the vault pays out. If traders lose, their losses are added directly to the vault, growing your share value.
* **Auto-compounding & MEV-Resistant:** Yield is auto-compounding. The share price of `vcNGN` dynamically reflects both **realized PnL** (settled via token transfers) and **unrealized PnL** (queried live from the PerpDEX via oracle prices), protecting the Vault from LP front-running and ensuring accurate share pricing at all times.

### 3. Liquidators & Automation
Keep the protocol safe! While anyone can monitor positions and liquidate underwater trades, the protocol natively implements **Protocol-Owned Liquidations** via Chainlink Automation to secure the system and capture value for LPs.

Here is the step-by-step flow of how actions are processed in the system.

### Phase 1: Opening a Position (Commit-Reveal)
To prevent Oracle front-running and MEV, the protocol uses a **Commit-Reveal** strategy:
1. **Commit (`requestTrade`)**: The trader submits a hashed version of their desired trade — `keccak256(abi.encode(trader, asset, side, collateral, leverage, salt))` — binding the order to their address.
2. **Delay**: The system forces a brief delay (2–20 blocks).
3. **Reveal (`executeTrade`)**: The trader reveals the cleartext parameters. The DEX verifies the hash, pulls the `cNGN` collateral into the Vault, and records the `Position` using the latest unmanipulated Chainlink mark price.

### Phase 2: Active Position & Collateral Management
While a position is active, traders can manage their isolated risk in real-time. Because adjusting margin doesn't open new market exposure, these actions bypass the commit-reveal delay and are executed instantly:
1. **Add Collateral** (`addCollateral`): Traders can deposit more `cNGN` to lower their effective leverage. This pushes their liquidation price further away, acting as a crucial defensive tool during wicks and volatility.
2. **Remove Collateral** (`removeCollateral`): Traders can extract "paper profits" or initial capital when a trade is deeply in profit. The protocol strictly enforces a **Max Leverage Guardrail** — withdrawals that would cause the remaining effective leverage to exceed the 5x limit, or leave non-positive equity, are safely reverted.
3. **Funding Rate**: As positions stay open, a continuous per-second funding rate is exchanged between Longs and Shorts based on the Open Interest (OI) imbalance. It is carefully scaled (targeting ~0.09% daily at maximum imbalance) to prevent aggressive decay.
4. **Virtual Precision Accounting**: Position sizes are seamlessly scaled to a unified 18-decimal precision (`1e18`) internally. All realized PnL and collateral moves are converted back to 6-decimal `cNGN` token units at the settlement boundary, minimizing precision loss from rounding.

### Phase 3: Closing & Settlement
1. **Close Position**: A trader can close their position entirely.
2. **PnL Calculation**: The DEX calculates unrealized PnL based on the entry vs. exit oracle price, accounting for any funding accrued.
3. **Vault Settle**: The DEX commands the `cNGNVault` to settle the accounting. 
    * If profitable, the vault sends `cNGN` to the trader. 
    * If at a loss, the vault absorbs the trader's collateral minus what is safely returned to them.

### Phase 4: Protocol-Owned Liquidations (Automation)
If a trader's `Equity` vs `Position Size` drops below the 2% Maintenance Margin ratio, they must be liquidated to prevent bad debt inside the Vault.
The system natively executes **Protocol-Owned Liquidations**:
1. Chainlink Automation Nodes query `checkUpkeep`, which iterates actively over the recorded `tradersPerAsset` set up to a defined gas ceiling.
2. If underwater traders are found, the node triggers `performUpkeep`.
3. The DEX forcefully closes those positions at the current mark price by triangulating the freshest feeds.
4. **Yield Capture:** Instead of routing the **1% collateral bounty** to external MEV bots, the protocol intercepts it (by validating the `liquidationForwarder` via a Forwarder pattern) and retains the bounty inside the `cNGNVault`, rewarding LPs with pure organic yield. Any remaining equity (after the bounty) is returned to the trader, and the position is cleanly wiped.

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
* **Pausable**: Trading, liquidations, and closing can be halted via the PAUSER role.
* **ReentrancyGuard**: Applied to all execution and settlement functions.
* **SafeERC20**: Revert-safe token transfers.
* **AccessManaged + SovereigntyAccessManager**: All privileged functions use the `restricted` modifier, delegating authorization to a centralized, UUPS-upgradeable role-based access manager with granular role-to-function mappings (OPERATOR, PAUSER, UPGRADER, VAULT_MANAGER, LIQUIDATOR).

### 4. Protocol-Owned Liquidations & Yield Capture
Instead of external snipers extracting the risk-averse liquidator bounties from the Vault's capacity, `PerpDEX` implements a highly optimized internal liquidation engine to protect LPs:
* **Active Trader Set Profiling:** As positions open (`executeTrade`), traders are dynamically pushed to the `tradersPerAsset[asset]` array. When positions close completely, they are efficiently swapped and popped out. This bounded set ensures that external computation (`checkUpkeep`) doesn't spin endlessly on stale data.
* **Forwarder Pattern Verification:** Utilizing Chainlink Automation 2.1 (`AutomationCompatibleInterface`), the PerpDEX stores a registered `liquidationForwarder`. During `_closePosition`, the contract performs an `isProtocolLiquidation` check: if the liquidator is the `liquidationForwarder`, the standard 1% `LIQUIDATION_BOUNTY_RATIO` is withheld and retained inside the Vault instead of paying external EOAs.
* **Gas-Optimized Upkeeps:** The `checkUpkeep` logic iterates active positions per asset up to a strict bound (`MAX_LIQUIDATION_BATCH = 10`), validating the condition: `equity * PRECISION < MAINTENANCE_MARGIN_RATIO * size` (i.e., equity below 2% of position size). Within `performUpkeep`, the current oracle price is queried exactly once per asset and reused across all traders in that batch, avoiding redundant gas-intensive feed calls.

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

### Local Deployment Scripts
Deployment is a two-step process:

**Step 1 — Deploy the SovereigntyAccessManager (UUPS proxy):**
Set `INITIAL_ADMIN` and run:
```bash
forge script script/DeploySAM.s.sol:DeploySAM --rpc-url <YOUR_RPC_URL> --private-key <YOUR_PRIVATE_KEY> --broadcast
```

**Step 2 — Deploy the Vault & PerpDEX:**
Set `SAM_PROXY`, `CNGN_TOKEN`, `NGN_USD_FEED`, `NGN_HEARTBEAT`, and the asset-specific feed variables, then run:
```bash
forge script script/DeployPerpDEX.s.sol:DeployPerpDEX --rpc-url <YOUR_RPC_URL> --private-key <YOUR_PRIVATE_KEY> --broadcast
```

