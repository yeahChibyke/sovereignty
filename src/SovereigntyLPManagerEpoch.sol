// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILPManagerEpoch} from "./interfaces/ILPManagerEpoch.sol";

contract SovereigntyLPManagerEpoch is ReentrancyGuard, Ownable, ILPManagerEpoch {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e6; // share scaling factor
    uint256 public constant MIN_AMOUNT = 100_000e6;

    IERC20 public immutable liquidityToken; // cngn

    // epoch id => Epoch
    mapping(uint256 => Epoch) public epochs;

    // LP -> epochId -> scaled shares
    mapping(address => mapping(uint256 => uint256)) public epochSharesOf;

    // current epoch that receives new deposits
    uint256 public currentEpochId;

    // aggregate free assets across all epochs (cached for efficiency)
    uint256 public globalFreeAssets;

    // ============= LP summary state =============

    mapping(address => LiquidityProvider) public liquidityProviders;
    mapping(address => uint256) public lastMaterializedEpoch;

    // ============= Trade layer data =============

    mapping(uint256 => TradeLayer) internal tradeLayers;
    uint256 public temporalSequenceCounter;

    constructor(address cngn) Ownable(msg.sender) {
        if (cngn == address(0)) revert ZeroAddress();
        liquidityToken = IERC20(cngn);

        // create initial epoch
        currentEpochId = 1;
        epochs[currentEpochId] = Epoch({
            id: currentEpochId,
            totalShares: 0,
            freeAssets: 0,
            lockedAssets: 0,
            frozen: false,
            split: false,
            preSplitTotalShares: 0,
            rolloverEpochId: 0
        });
        emit EpochCreated(currentEpochId);
    }
}
