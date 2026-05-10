## Title

Base Chainlink oracle usage does not check sequencer uptime

## Severity

Medium

## Likelihood

Low

## Very detailed description

The protocol is deployed on Base and uses Chainlink's NGN/USD feed as part of the mark price calculation.

On optimistic rollups and similar L2 networks, protocols that rely on Chainlink price feeds should check the L2 sequencer uptime feed. This protects the protocol from accepting prices during or immediately after sequencer downtime, when users may not have had a fair opportunity to transact and oracle data may not represent a normal market state.

The current `_getUsdNgnRate()` function checks:

- Chainlink answer is positive,
- Chainlink answer is not older than `usdNgnMaxStaleness`.

It does not check whether the Base sequencer is up, nor does it enforce a grace period after the sequencer comes back online.

Relevant code:

- `src/PerpDEX.sol:579` - `_getUsdNgnRate()`
- `src/PerpDEX.sol:580` - reads Chainlink latest round data
- `src/PerpDEX.sol:581` - checks positive answer
- `src/PerpDEX.sol:582` - checks staleness

## Very detailed and well-explained scenario

1. The Base sequencer goes down or has a major outage.

2. During the outage, normal users cannot reliably submit transactions.

3. Chainlink feed data may still appear recent enough according to the normal `updatedAt` check, or it may become usable immediately after the sequencer returns.

4. The sequencer comes back online.

5. A sophisticated actor submits a transaction immediately.

6. The protocol reads the Chainlink NGN/USD feed.

7. `_getUsdNgnRate()` accepts the feed because:

   - `answer > 0`,
   - `block.timestamp - updatedAt <= usdNgnMaxStaleness`.

8. The protocol allows trading, collateral removal, closing, or liquidation.

9. Other users may not yet have had enough time to react after the outage.

10. The actor can benefit from stale or unfair post-outage conditions.

## Impact

- Trades or liquidations can occur during unsafe L2 oracle conditions.
- Users may be liquidated before they have a fair chance to add collateral or close.
- The protocol can accept prices immediately after sequencer recovery, before markets normalize.
- The oracle safety model is incomplete for a Base deployment.

## Recommended Mitigation

Integrate the Chainlink L2 sequencer uptime feed for Base.

The price-read path should:

1. Read the sequencer uptime feed.
2. Revert if the sequencer is down.
3. Revert if the sequencer recently came back online and the grace period has not elapsed.
4. Only then read and accept the NGN/USD price feed.

Typical logic:

```solidity
(, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
if (answer != 0) revert SequencerDown();
if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) revert SequencerGracePeriodNotOver();
```

The same protection should be applied to any Chainlink feed used for trading, liquidation, or share pricing.
