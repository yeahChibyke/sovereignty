## Title

Open interest cap uses raw vault balance and counts trader collateral as LP liquidity

## Severity

High

## Likelihood

High

## Very detailed description

The README states that each market has a `5x vault-TVL OI cap`. This means open interest should be limited by the liquidity that LPs provide to underwrite trader PnL.

The code checks the OI cap in `_checkOICap()`:

```solidity
uint256 vaultTVL = _toInternalPrecision(IERC20(_cfg.vault.asset()).balanceOf(address(_cfg.vault)));
uint256 maxOI = (vaultTVL * _cfg.maxOIMultiplier) / PRECISION;
if (totalOI > maxOI) revert ExceedsMaxOI();
```

This uses the raw ERC20 balance of the vault.

That balance includes more than LP-owned liquidity. It includes:

- LP deposits,
- trader collateral,
- realized trader losses,
- funds that may be owed back to traders,
- protocol-retained liquidation bounty amounts.

Most importantly, trader collateral deposited when opening positions increases the raw vault balance. This means opening positions can increase the amount of additional open interest the market allows.

That weakens the cap. The cap is supposed to limit trader exposure relative to LP underwriting capacity, not relative to a balance that includes trader margin.

Relevant code:

- `src/PerpDEX.sol:1079` - `_checkOICap()`
- `src/PerpDEX.sol:1082` - uses raw vault token balance
- `src/PerpDEX.sol:762` - trader collateral is transferred into the vault
- `src/PerpDEX.sol:763` - trader collateral is tracked separately as `marketCollateralHeld`
- `src/MarketVault.sol:201` - `totalAssets()` excludes trader collateral from LP assets

## Very detailed and well-explained scenario

1. LPs deposit 1,000,000 cNGN into a market vault.

2. The market has a 5x OI cap.

3. The intended maximum open interest is:

   ```text
   1,000,000 * 5 = 5,000,000 cNGN
   ```

4. Traders open positions and deposit 500,000 cNGN of collateral into the vault.

5. The raw vault token balance is now:

   ```text
   1,500,000 cNGN
   ```

6. `_checkOICap()` uses this raw balance.

7. The new calculated OI cap becomes:

   ```text
   1,500,000 * 5 = 7,500,000 cNGN
   ```

8. The protocol now allows 2,500,000 cNGN more open interest than the LP-only TVL would allow.

9. If traders collectively win, the additional exposure is still underwritten by LPs.

10. Trader collateral helped increase the risk limit even though trader collateral is not LP capital and may need to be returned to traders.

This makes the market appear more liquid than it actually is from an LP risk perspective.

## Impact

- The market can accept more open interest than intended.
- LPs can be exposed to more risk than the documented OI cap suggests.
- Trader deposits can increase future market capacity.
- The cap does not match the README claim of a vault-TVL-based exposure limit.
- Risk management assumptions can be wrong during high activity.

## Recommended Mitigation

Calculate the OI cap from LP-available assets, not raw vault balance.

For example, use a value that excludes trader collateral:

```solidity
uint256 lpAssets = _cfg.vault.totalAssets();
```

However, `totalAssets()` currently depends on live oracle reads and can revert. If that is not acceptable inside `executeTrade()`, PerpDEX should maintain a conservative LP-liquidity accounting value that excludes:

- `marketCollateralHeld`,
- unrealized trader profits,
- any other trader-owned funds.

At minimum:

```solidity
uint256 rawBalance = IERC20(_cfg.vault.asset()).balanceOf(address(_cfg.vault));
uint256 collateralHeld = marketCollateralHeld[_marketId];
uint256 lpBalance = rawBalance > collateralHeld ? rawBalance - collateralHeld : 0;
```

Then apply additional adjustments for unrealized PnL if the protocol wants the cap to reflect current risk more accurately.
