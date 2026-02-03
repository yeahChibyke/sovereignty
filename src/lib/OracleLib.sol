// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library OracleChecker {
    error OracleChecker__StaleData();

    uint256 private constant s_TIMEOUT = 10 minutes;

    function staleDataCheck(AggregatorV3Interface priceFeed)
        internal
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;

        if (secondsSince > s_TIMEOUT) revert OracleChecker__StaleData();

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
