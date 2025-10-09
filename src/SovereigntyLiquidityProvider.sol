// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICngn} from "./interfaces/ICngn.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SovereigntyLiquidityProvider is ReentrancyGuard {
    using SafeERC20 for ICngn;

    error SLP__ZeroAddress();

    ICngn public immutable i_cNGN; // cNGN

    uint256 private s_totalShares;
    uint256 private s_totalLPs;

    struct LiquidityProvider {
        uint256 shares;
        uint256 ownershipPercent;
    }

    mapping(address lp => LiquidityProvider) private s_LP;

    constructor(address _liquidityToken) {
        if (_liquidityToken == address(0)) {
            revert SLP__ZeroAddress();
        }

        i_cNGN = ICngn(_liquidityToken);
    }
}
