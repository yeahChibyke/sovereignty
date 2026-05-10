## Title

Funding is documented as a long/short exchange but is implemented as a net payment by traders

## Severity

High

## Likelihood

High

## Very detailed description

The README describes funding as being exchanged between longs and shorts. In that model, funding should be approximately zero-sum between traders:

- if longs are dominant, longs pay shorts;
- if shorts are dominant, shorts pay longs;
- the total amount paid by one side should match the total amount received by the other side, ignoring rounding.

The current implementation does not produce that result.

Funding is updated globally per market in `_updateFunding()`:

```solidity
int256 imbalance =
    (int256(moi.longOI) - int256(moi.shortOI)) * int256(PRECISION) / int256(totalOI);

int256 fundingDelta =
    imbalance * int256(FUNDING_RATE_PER_SECOND) * int256(elapsed) / int256(PRECISION);

moi.fundingIndex += fundingDelta;
```

Each position then applies the funding index like this:

```solidity
if (pos.side == Side.Long) {
    return int256(pos.size) * indexDelta / int256(PRECISION);
} else {
    return -(int256(pos.size) * indexDelta / int256(PRECISION));
}
```

When long open interest is larger than short open interest, `fundingIndex` increases. Longs pay funding, and shorts receive funding. However, because longs have more total size than shorts, the total amount paid by longs is greater than the total amount received by shorts.

The excess does not go to the opposite trader side. It is effectively retained by the vault during settlement because trader payouts are reduced by funding.

That may be acceptable if the protocol intentionally wants funding to be a payment from the dominant side to LPs. But that is not the documented design. The README explicitly says funding is exchanged between longs and shorts.

Relevant code:

- `src/PerpDEX.sol:624` - `_updateFunding()`
- `src/PerpDEX.sol:670` - `_pendingFunding()`
- `src/PerpDEX.sol:949` - close calculates raw PnL
- `src/PerpDEX.sol:950` - close calculates funding
- `src/PerpDEX.sol:951` - close subtracts funding from trader PnL

## Very detailed and well-explained scenario

Assume a market has:

- 900 cNGN of long open interest,
- 100 cNGN of short open interest,
- total open interest of 1,000 cNGN.

The imbalance is:

```text
(900 - 100) / 1000 = 80%
```

After some time, suppose the funding index increases by 1%.

The long side pays:

```text
900 * 1% = 9 cNGN
```

The short side receives:

```text
100 * 1% = 1 cNGN
```

The system has now charged traders a net 8 cNGN.

That 8 cNGN was not exchanged from longs to shorts. It was removed from trader equity and remains in the vault when positions settle.

If this is intended, then the documentation and naming should be changed to say dominant-side funding is paid partly to LPs. If it is not intended, then the funding formula is economically incorrect.

## Impact

- Traders can pay more funding than the opposite side receives.
- Funding is not zero-sum between longs and shorts.
- Protocol economics differ from the documented behavior.
- LP share value can increase from unadvertised funding capture.
- Traders may be charged more than expected during imbalanced markets.
- Risk models, frontends, and external integrations may display incorrect funding expectations.

## Recommended Mitigation

First decide the intended funding model.

If funding should be a true long/short exchange, compute funding so the total paid by one side equals the total received by the other side. One common approach is to calculate the funding transfer based on the smaller side or explicitly account for side-level funding pools.

If funding is intentionally paid partly to LPs, then:

- update the README and user-facing documentation,
- expose the LP funding capture clearly in view functions,
- include accrued funding in vault share pricing,
- add tests showing that funding is intentionally not zero-sum between traders.

In either case, add invariant tests that compare:

- total funding paid by longs,
- total funding received by shorts,
- any intended funding retained by the vault.
