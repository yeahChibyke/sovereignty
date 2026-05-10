## Title

Commit-reveal orders have no price protection and give traders a free execution option

## Severity

Medium

## Likelihood

High

## Very detailed description

The protocol uses a commit-reveal flow to reduce front-running:

1. The trader commits a hash of their order.
2. The trader waits for the required block delay.
3. The trader reveals the order parameters and opens the position at the current mark price.

The committed hash includes:

```solidity
keccak256(abi.encode(msg.sender, _marketId, _side, _collateral, _leverage, _salt))
```

It does not include any price protection, such as:

- maximum acceptable entry price for a long,
- minimum acceptable entry price for a short,
- maximum slippage,
- expected oracle publish time,
- deadline in seconds.

Because execution uses the current mark price at reveal time, the trader can choose whether to reveal after seeing how the price moved during the valid execution window.

This gives the trader a free option. If the price moves favorably, they reveal and open the trade. If the price moves unfavorably, they let the order expire and lose nothing except gas.

The commit-reveal design hides parameters from other market participants, but it does not protect LPs from adverse selection by the trader who submitted the commitment.

Relevant code:

- `src/PerpDEX.sol:691` - `requestTrade()`
- `src/PerpDEX.sol:721` - `executeTrade()`
- `src/PerpDEX.sol:729` - minimum block delay
- `src/PerpDEX.sol:730` - maximum block delay
- `src/PerpDEX.sol:732` - committed fields
- `src/PerpDEX.sol:751` - trade executes at current mark price

## Very detailed and well-explained scenario

1. ETH is trading around 3,000 USD.

2. A trader wants to open a 5x long.

3. The trader submits a commitment for:

   - ETH market,
   - long side,
   - 100,000 cNGN collateral,
   - 5x leverage.

4. The trader waits until the reveal window opens.

5. During the reveal window, ETH price moves down to 2,950 USD.

6. This is favorable for opening a long because the trader gets a lower entry price.

7. The trader reveals and opens the position.

8. If ETH had instead moved up to 3,050 USD, the trader could choose not to reveal.

9. The order expires.

10. The trader avoids the worse entry price.

11. LPs only receive the flow when the trader likes the resulting execution price.

This is economically similar to giving the trader a short-lived free option against the vault.

## Impact

- Traders can selectively execute only favorable commitments.
- LPs face adverse selection.
- The protocol's commit-reveal design reduces external front-running but does not guarantee fair execution against LPs.
- The issue becomes more important in volatile markets or with large positions.
- Sophisticated traders can automate reveal decisions based on price movement.

## Recommended Mitigation

Add price protection to the committed order.

The committed hash should include fields such as:

```solidity
marketId
side
collateral
leverage
acceptablePrice
deadline
salt
```

Then enforce:

- for longs: `markPrice <= acceptablePrice`,
- for shorts: `markPrice >= acceptablePrice`,
- `block.timestamp <= deadline`.

Also consider including the Pyth price publish time or a maximum oracle age chosen by the trader.

This does not remove all optionality, but it prevents execution at a price outside the trader's committed bounds and makes order behavior explicit.
