// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface ISovereigntyPosition {
    enum TradedAsset {
        BTC,
        ETH
    }

    enum PositionType {
        LONG,
        SHORT
    }

    struct Position {
        string asset;
        string positionType;
        uint256 caollateral;
        uint8 multiplier;
        uint256 leverage;
        uint256 size;
        uint256 priceAtOpen;
        address trader;
        uint256 openedAt;
        bool isPositionActive;
    }

    function openPosition(uint256 collateral, uint8 multiplier, TradedAsset asset, Position pos)
        external
        returns (uint256 positionId);

    function closePosition(uint256 positionId) external returns (bool closed);

    function liquidatePosition(uint256 positionId) external returns(bool liquidated);

    function getPositionPnL(uint256 positionId) external view returns(int256);

    function isLiquidationValid(uint256 positionId) external view returns(bool valid);

    function getTradeStatus() external view returns(bool status);
}
