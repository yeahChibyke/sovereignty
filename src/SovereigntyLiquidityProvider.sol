// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ------------------------------------------------------------------
//                             IMPORTS
// ------------------------------------------------------------------
import {ICngn} from "./interfaces/ICngn.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract SovereigntyLiquidityProvider is ReentrancyGuard, Ownable {
    using SafeERC20 for ICngn;

    
}
