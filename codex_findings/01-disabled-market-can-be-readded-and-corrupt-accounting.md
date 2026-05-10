## Title

Disabled markets can be re-added under the same market ID and corrupt vault accounting

## Severity

Critical

## Likelihood

Medium

## Very detailed description

`PerpDEX.addMarket()` only checks whether an existing market is currently enabled:

```solidity
if (marketConfigs[_marketId].enabled) revert MarketAlreadyExists();
```

This means a market that has been disabled with `disableMarket()` can later be added again using the same `_marketId`.

That is dangerous because disabling a market only flips `marketConfigs[_marketId].enabled` to `false`. It does not clear or migrate the rest of the market state. The following state remains active under the same `_marketId`:

- `positions[_marketId][trader]`
- `marketOI[_marketId]`
- `marketCollateralHeld[_marketId]`
- `tradersPerMarket[_marketId]`
- `_traderIndex[_marketId][trader]`

If `addMarket()` is called again with the same `_marketId`, the old `MarketConfig` is overwritten. In particular, the market's vault address can be replaced while existing positions and collateral accounting still point to the same market ID.

This breaks the protocol's core assumption that each market has one isolated vault that underwrites that market's positions. Existing trader collateral may be held in the old vault, while future close or liquidation logic reads the overwritten config and settles against the new vault.

Relevant code:

- `src/PerpDEX.sol:400` - `addMarket()`
- `src/PerpDEX.sol:410` - duplicate check only uses `enabled`
- `src/PerpDEX.sol:436` - `disableMarket()`
- `src/PerpDEX.sol:1003` - close/settlement uses the current `cfg.vault`

## Very detailed and well-explained scenario

1. The protocol lists `ETH-PERP` with `marketId = keccak256("ETH-PERP")`.

2. `ETH-PERP` is configured with `Vault A`.

3. Traders open positions in `ETH-PERP`.

4. Their collateral is transferred into `Vault A`.

5. The protocol disables `ETH-PERP` by calling `disableMarket(ETH_MARKET)`.

6. Disabling only sets:

   ```solidity
   marketConfigs[ETH_MARKET].enabled = false;
   ```

   Existing positions, open interest, trader lists, and collateral-held accounting remain in storage.

7. A market manager later calls `addMarket()` again with the same `ETH_MARKET` ID but passes `Vault B` as the vault.

8. The call succeeds because `marketConfigs[ETH_MARKET].enabled` is currently `false`.

9. The old config is overwritten. `marketConfigs[ETH_MARKET].vault` now points to `Vault B`.

10. A trader with an old position closes their position.

11. `_closePosition()` loads the current config and uses `Vault B` for settlement.

12. But the trader's original collateral is still physically held in `Vault A`.

13. Depending on vault balances and position PnL, the protocol can:

    - pay the trader from the wrong vault,
    - strand collateral in the old vault,
    - reduce or corrupt `marketCollateralHeld`,
    - distort LP share pricing in both vaults,
    - make closes or liquidations revert if the new vault has insufficient assets.

This is not just an administrative mistake. It is a state integrity failure because one storage namespace, `_marketId`, is reused for two different vault configurations.

## Impact

- Existing market positions can be settled against the wrong vault.
- Trader collateral can become stranded in the old vault.
- LP funds in the new vault can be used to pay liabilities created before that vault was attached.
- Market isolation can be broken.
- Liquidations and closes can revert or settle incorrectly.
- Vault share prices can become inaccurate because collateral and PnL accounting no longer match the vault that actually holds funds.

## Recommended Mitigation

Do not allow `addMarket()` to reuse any market ID that has ever been initialized.

For example:

```solidity
if (marketConfigs[_marketId].pythFeedId != bytes32(0)) revert MarketAlreadyExists();
if (address(marketConfigs[_marketId].vault) != address(0)) revert MarketAlreadyExists();
```

Alternatively, introduce an explicit market migration function. A safe migration should require, at minimum:

- no open positions,
- `marketOI.longOI == 0`,
- `marketOI.shortOI == 0`,
- `marketCollateralHeld[_marketId] == 0`,
- `tradersPerMarket[_marketId].length == 0`,
- an intentional event that identifies the old vault and new vault.

The safest immediate fix is to make market IDs immutable once used.
