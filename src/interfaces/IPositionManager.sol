// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IPositionManager {
    event PositionLiquidated(uint256, address, address, uint256, uint256);

    enum PositionType {
        LONG,
        SHORT
    }

    struct Position {
        uint256 size;
        address owner;
        uint256 id;
        uint256 openedAt;
        uint256 indexTokenPrice;
        uint256 indexTokenSize;
        uint256 leverage;
        PositionType positionType;
        uint256 layerId;
    }

    function isLiquidatable(uint256 positionId) external view returns (bool, uint256 losses);
    function openPosition(uint256 leverage, PositionType positionType) external;
    function closePosition(uint256 positionId) external;
    function liquidate(uint256 positionId) external;
    function getPositionPnL(uint256 positionId) external view returns (int256 pnl, bool isProfitable);
    function getUserPosition(address _user)
        external
        view
        returns (
            uint256 size,
            address owner,
            uint256 id,
            uint256 openedAt,
            uint256 indexTokenPrice,
            uint256 indexTokenSize,
            uint256 leverage,
            PositionType positionType,
            uint256 layerId
        );

    function hasOpenPosition(address _user) external view returns (bool);
}
