## Title

Stale oracle data can freeze LP deposits and withdrawals while positions are open

## Severity

High

## Likelihood

Medium

## Very detailed description

`MarketVault` is an ERC4626 vault. ERC4626 functions such as `deposit`, `mint`, `withdraw`, `redeem`, `previewDeposit`, `previewWithdraw`, and related share conversion functions depend on `totalAssets()`.

This protocol overrides `totalAssets()` so that vault share pricing reflects live trader PnL:

```solidity
int256 lpAssets = int256(balance) - int256(collateralHeld) - unrealizedPnL;
```

When a PerpDEX is linked, `totalAssets()` calls:

```solidity
IMarketPerpDEX(_perpDex).getMarketUnrealizedPnL(marketId)
```

That function calls `_getMarkPrice()`, which depends on:

- Pyth Asset/USD price,
- Chainlink NGN/USD price,
- staleness checks,
- Pyth confidence checks.

If either oracle is stale or invalid, the oracle read reverts. Because that read happens inside `totalAssets()`, ERC4626 LP actions can also revert.

This is especially concerning because oracle failures often happen during volatile or stressed periods, which are exactly when LPs may want to withdraw or when the protocol may need clean settlement behavior.

Relevant code:

- `src/MarketVault.sol:201` - `totalAssets()`
- `src/MarketVault.sol:208` - calls `getMarketUnrealizedPnL()`
- `src/PerpDEX.sol:1141` - `getMarketUnrealizedPnL()`
- `src/PerpDEX.sol:1144` - calls `_getMarkPrice()`
- `src/PerpDEX.sol:551` - Pyth price staleness and confidence checks
- `src/PerpDEX.sol:579` - Chainlink NGN/USD staleness check

## Very detailed and well-explained scenario

1. LPs deposit into the ETH vault.

2. Traders open ETH positions.

3. Because there is open interest, the vault needs live unrealized PnL to calculate `totalAssets()`.

4. The Pyth ETH/USD price is not updated within the configured staleness window.

5. A legitimate LP tries to withdraw from the ETH vault.

6. ERC4626 withdrawal logic needs to calculate assets and shares.

7. It calls `totalAssets()`.

8. `totalAssets()` calls PerpDEX for unrealized PnL.

9. PerpDEX tries to read the Pyth price.

10. The Pyth read reverts because the price is stale.

11. The LP withdrawal reverts.

12. The LP cannot exit until fresh oracle data is pushed and accepted.

This can also affect deposits. A new LP cannot deposit if share conversion requires a `totalAssets()` calculation that reverts.

## Impact

- LPs can be unable to withdraw during oracle downtime.
- ERC4626 previews and integrations can fail.
- Vault liquidity can become operationally frozen even though the vault holds tokens.
- The protocol can become harder to recover during market stress.
- This conflicts with the expectation that ERC4626 vault actions remain reliably available.

## Recommended Mitigation

Avoid making core ERC4626 accounting fully dependent on a live oracle call that can revert.

Possible mitigations:

- Store a last-known-good market price and use it for vault accounting when fresh data is unavailable.
- Add a circuit-breaker mode that freezes new deposits but allows conservative withdrawals.
- Separate normal share pricing from emergency withdrawal accounting.
- Add a protocol shutdown or market settlement path that does not require fresh oracle data forever.
- Make `getMarketUnrealizedPnL()` return a safe fallback value for vault accounting, while separate trading functions continue to require fresh prices.

The mitigation should be chosen carefully because stale prices can also be abused. The key point is that LP funds should not become permanently inaccessible only because a live oracle read reverts.
