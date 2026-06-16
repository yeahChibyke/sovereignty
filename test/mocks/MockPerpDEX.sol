// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMarketPerpDEX} from "../../src/MarketVault.sol";

/// @title MockPerpDEX
/// @notice Minimal mock implementing IMarketPerpDEX so MarketVault can be tested in isolation.
/// @dev Exposes setters for `unrealizedPnL` and `collateralHeld` per market, allowing
///      test scripts to simulate any PnL scenario without needing real oracle data or
///      commit-reveal trading flows. Used exclusively by `MarketVaultTest`.
contract MockPerpDEX is IMarketPerpDEX {
    mapping(bytes32 => int256) private _unrealizedPnL;
    mapping(bytes32 => uint256) private _collateralHeld;

    /// @notice When true, `getMarketUnrealizedPnL` reverts to simulate a stale oracle, while
    ///         `getMarketUnrealizedPnLSafe` keeps returning the cached value.
    bool public oracleStale;

    error MockOracleStale();

    /// @notice Toggle the simulated stale-oracle condition.
    function setOracleStale(bool stale) external {
        oracleStale = stale;
    }

    /// @notice Set the simulated aggregate unrealized PnL for a market.
    /// @param marketId The market identifier.
    /// @param pnl      Signed PnL in cNGN token units (6 decimals). Positive = trader profit.
    function setUnrealizedPnL(bytes32 marketId, int256 pnl) external {
        _unrealizedPnL[marketId] = pnl;
    }

    /// @notice Set the simulated total collateral held by traders in a market.
    /// @param marketId The market identifier.
    /// @param amount   Collateral amount in cNGN token units (6 decimals).
    function setCollateralHeld(bytes32 marketId, uint256 amount) external {
        _collateralHeld[marketId] = amount;
    }

    /// @inheritdoc IMarketPerpDEX
    function getMarketUnrealizedPnL(bytes32 marketId) external view override returns (int256) {
        if (oracleStale) revert MockOracleStale();
        return _unrealizedPnL[marketId];
    }

    /// @inheritdoc IMarketPerpDEX
    function getMarketUnrealizedPnLSafe(bytes32 marketId) external view override returns (int256) {
        return _unrealizedPnL[marketId];
    }

    /// @inheritdoc IMarketPerpDEX
    function marketCollateralHeld(bytes32 marketId) external view override returns (uint256) {
        return _collateralHeld[marketId];
    }
}
