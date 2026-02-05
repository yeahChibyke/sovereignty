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
    uint256 public constant MIN_DEPOSIT = 100_000e6; // 100_000e6 cngn

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
        if (cngn == address(0)) revert LPManager__ZeroAddress();
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

    modifier validDeposit(uint256 _amount) {
        if (_amount < MIN_DEPOSIT) {
            revert LPManager__InvalidDeposit();
        }
        _;
    }

    modifier validAmount(uint256 _amount) {
        if (_amount <= 0) {
            revert LPManager__ZeroAmount();
        }
        _;
    }

    function deposit(uint256 _amount) external validDeposit(_amount) nonReentrant {
        Epoch storage e = epochs[currentEpochId];

        liquidityToken.safeTransferFrom(msg.sender, address(this), _amount);

        // mint scaled shares
        uint256 _shares = _amount * PRECISION;

        // update epoch accounting
        e.freeAssets += _amount;
        e.totalShares += _shares;

        // credit LP
        epochSharesOf[msg.sender][currentEpochId] += _shares;

        // update LP summary
        LiquidityProvider storage lp = liquidityProviders[msg.sender];
        if (!lp.exists) {
            lp.exists = true;
            lastMaterializedEpoch[msg.sender] = currentEpochId;
        }
        lp.totalShares += _shares;

        // update global free assets
        globalFreeAssets += _amount;

        emit Deposit(msg.sender, currentEpochId, _amount, _shares);
    }

    function withdrawFromEpoch(uint256 _epochId, uint256 _amount) external validAmount(_amount) nonReentrant {
        Epoch storage e = epochs[_epochId];
        require(e.id == _epochId, "SovereigntyLPManagerEpoch__InvalidEpoch");

        LiquidityProvider storage lp = liquidityProviders[msg.sender];
        require(lp.exists, "SovereigntyLPManagerEpoch__InexistentLP");

        // check LP overall availability across epochs
        uint256 _totalBalance = lp.totalShares / PRECISION; // tokens
        uint256 _available = 0;
        if (_totalBalance > lp.accumulatedUtilization) _available = _totalBalance - lp.accumulatedUtilization;
        require(_amount <= _available, "SovereigntyLPManagerEpoch__InsufficientAvailabilityAcrossEpochs");

        // check epoch-level availability
        require(e.freeAssets >= _amount, "SovereigntyLPManagerEpoch__EpochInsufficientFreeAssets");

        uint256 _sharesToBurn = _amount * PRECISION;
        require(epochSharesOf[msg.sender][_epochId] >= _sharesToBurn, "SovereigntyLPManagerEpoch__NotEnoughSharesInEpoch");

         // update epoch and LP bookkeeping
        epochSharesOf[msg.sender][_epochId] -= _sharesToBurn;
        lp.totalShares -= _sharesToBurn;
        if (e.totalShares >= _sharesToBurn) {
            e.totalShares -= _sharesToBurn;
        } else {
            e.totalShares = 0;
        }
        e.freeAssets -= _amount;

        // update global free assets
        if (globalFreeAssets >= _amount) globalFreeAssets -= _amount;
        else globalFreeAssets = 0;

        // transfer tokens
        liquidityToken.safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _epochId, _amount, _sharesToBurn);
    }
}
