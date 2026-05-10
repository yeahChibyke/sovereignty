## Title

Vault share pricing excludes accrued funding while positions are open

## Severity

High

## Likelihood

High

## Very detailed description

`MarketVault.totalAssets()` is designed to make ERC4626 vault shares reflect live market state. The README states that vault share price dynamically reflects both realized PnL and unrealized PnL, protecting LPs from front-running and keeping share pricing accurate.

The current implementation includes unrealized price PnL, but it does not include accrued funding while positions are open.

`MarketVault.totalAssets()` computes:

```solidity
LP assets = vault balance - trader collateral - unrealizedPnL
```

It gets `unrealizedPnL` from `PerpDEX.getMarketUnrealizedPnL()`.

`getMarketUnrealizedPnL()` only calculates price-based PnL from aggregate long and short average entry prices. It does not include pending funding for open positions.

Funding is only applied when a position is closed or liquidated:

```solidity
int256 pnl = _calculatePnL(pos, markPrice);
int256 funding = _pendingFunding(_marketId, pos);
int256 netPnL = pnl - funding;
```

This creates a gap. While positions are open, funding can accrue and materially affect trader equity, but vault shares do not reflect it until settlement.

Relevant code:

- `src/MarketVault.sol:201` - `totalAssets()`
- `src/MarketVault.sol:207` - reads collateral held
- `src/MarketVault.sol:208` - reads unrealized PnL
- `src/PerpDEX.sol:1141` - `getMarketUnrealizedPnL()`
- `src/PerpDEX.sol:1162` - `_marketUnrealizedPnL()`
- `src/PerpDEX.sol:950` - funding is applied only at close/liquidation

## Very detailed and well-explained scenario

1. LPs deposit cNGN into a market vault.

2. A trader opens a large long position.

3. The market becomes heavily long-skewed.

4. Time passes.

5. Funding accrues against the long trader.

6. The trader's true equity is now lower because they owe funding.

7. The vault should be worth more if that funding is ultimately retained by LPs, or the opposite side should be owed more if funding is meant to be long/short exchange.

8. However, `MarketVault.totalAssets()` does not include this accrued funding.

9. A new LP deposits before the trader closes.

10. The new LP receives shares based on a vault value that does not include the accrued funding.

11. The trader later closes the position.

12. Funding is finally applied during settlement.

13. The vault value changes, and the new LP receives a share of funding that accrued before they joined.

This means the vault share price was not accurate at the time of deposit.

The reverse case can also harm new LPs. If accrued funding is owed to traders but not included in `totalAssets()`, new LPs can deposit at an overstated share price and absorb obligations that existed before they joined.

## Impact

- ERC4626 share pricing can be wrong while positions are open.
- LPs can enter or exit around accrued funding.
- Existing LPs can be diluted by new LPs who join before funding is realized.
- New LPs can unknowingly absorb pre-existing funding liabilities.
- The protocol does not meet the README claim that vault share value accurately reflects live trading state.

## Recommended Mitigation

Include pending funding in live market accounting.

Possible approaches:

1. Track aggregate accrued funding per side and include it in `getMarketUnrealizedPnL()` or a new `getMarketNetLiability()` function.

2. Make `MarketVault.totalAssets()` consume one complete value from PerpDEX:

   ```text
   vault liability = trader collateral + price PnL - accrued funding owed by traders + accrued funding owed to traders
   ```

3. If exact per-position funding cannot be aggregated safely, change the design so funding is settled more frequently into side-level accounting.

4. Add tests where time passes with imbalanced OI and no price movement. The test should verify that vault `totalAssets()` changes consistently with accrued funding.
