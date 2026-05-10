## Title

Privileged setters allow zero or invalid critical configuration values

## Severity

Low

## Likelihood

Medium

## Very detailed description

Several privileged configuration functions accept values that can accidentally disable important protocol functionality or cause future calls to revert.

`setUsdNgnFeed()` accepts any address and any staleness value:

```solidity
function setUsdNgnFeed(address _feed, uint256 _maxStaleness) external restricted {
    ngnUsdChainlinkFeed = AggregatorV3Interface(_feed);
    usdNgnMaxStaleness = _maxStaleness;
    emit UsdNgnFeedConfigured(_feed, _maxStaleness);
}
```

There is no check that:

- `_feed != address(0)`,
- `_feed` contains code,
- `_maxStaleness > 0`.

`setForwarder()` also accepts any address:

```solidity
function setForwarder(address _forwarder) external restricted {
    liquidationForwarder = _forwarder;
    emit ForwarderSet(_forwarder);
}
```

There is no check that:

- `_forwarder != address(0)`,
- `_forwarder` contains code.

These functions are restricted, so this is not an untrusted-user exploit. The risk is operational. A mistaken or compromised privileged account can break important protocol paths very easily.

Relevant code:

- `src/PerpDEX.sol:477` - `setUsdNgnFeed()`
- `src/PerpDEX.sol:501` - `setForwarder()`

## Very detailed and well-explained scenario

1. The operator intends to update the NGN/USD Chainlink feed.

2. The operator accidentally passes `address(0)` as `_feed`.

3. The transaction succeeds.

4. Later, a trader tries to open or close a position.

5. The protocol calls `_getUsdNgnRate()`.

6. `_getUsdNgnRate()` calls `latestRoundData()` on address zero.

7. The call fails.

8. Price-dependent protocol actions stop working.

A similar problem can happen with `_maxStaleness = 0`. Most real oracle updates will be considered stale unless they happen in the exact current timestamp context.

For the forwarder:

1. The operator accidentally sets `liquidationForwarder` to the wrong address or zero address.

2. Chainlink Automation can no longer call `performUpkeep()`.

3. Public liquidations still exist, but the protocol-owned liquidation path no longer works.

4. LPs lose the intended protocol-owned liquidation yield capture, and liquidations may become less reliable.

## Impact

- Price-dependent trading and settlement can be accidentally disabled.
- Automated liquidations can be accidentally disabled.
- Operational mistakes can cause avoidable downtime.
- The protocol relies more heavily on off-chain procedures being perfect.

## Recommended Mitigation

Add validation to privileged setters.

For `setUsdNgnFeed()`:

```solidity
if (_feed == address(0)) revert ZeroAddress();
if (_feed.code.length == 0) revert InvalidParameters();
if (_maxStaleness == 0) revert InvalidParameters();
```

For `setForwarder()`:

```solidity
if (_forwarder == address(0)) revert ZeroAddress();
if (_forwarder.code.length == 0) revert InvalidParameters();
```

If the protocol intentionally wants to allow disabling automation by setting the forwarder to zero, implement a separate explicit function such as `disableForwarder()` so the action is clear and auditable.
