// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockPerpDEX
/// @notice Minimal mock implementing the vault's IPerpDEX interface for unit testing.
contract MockPerpDEX {
    int256 private _globalUnrealizedPnL;
    uint256 private _totalCollateralHeld;

    function setGlobalUnrealizedPnL(int256 pnl) external {
        _globalUnrealizedPnL = pnl;
    }

    function setTotalCollateralHeld(uint256 collateral) external {
        _totalCollateralHeld = collateral;
    }

    function getGlobalUnrealizedPnL() external view returns (int256) {
        return _globalUnrealizedPnL;
    }

    function totalCollateralHeld() external view returns (uint256) {
        return _totalCollateralHeld;
    }
}
