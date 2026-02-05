// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface ILPManagerEpoch {
    struct Epoch {
        uint256 id;
        uint256 totalShares; // scaled shares (PRECISION)
        uint256 freeAssets; // token units
        uint256 lockedAssets; // token units
        bool frozen; // true if epoch has been frozen by a lock
        bool split; // true if epoch has been split into locked+rollover
        uint256 preSplitTotalShares; // original totalShares before split (scaled)
        uint256 rolloverEpochId; // id of the epoch holding rollover shares (if split)
    }

    struct LiquidityProvider {
        uint256 totalShares; // sum of epochSharesOf across epochs (scaled)
        uint256 accumulatedUtilization; // total tokens currently allocated to active layers (token units)
        bool exists;
    }

    enum LayerStatus {
        Open,
        Active,
        Closed
    }

    struct TradeLayer {
        uint256 id;
        uint256 requiredBacking; // locked amount in tokens
        uint256 fundingEpochId; // epoch which funded/was frozen for this layer (locked epoch)
        LayerStatus status;
        uint256 totalAllocated; // total tokens claimed by LPs for this layer
        uint256 remainingBacking; // remaining tokens that can be claimed
        mapping(address => uint256) allocations; // token allocations per LP
        mapping(address => bool) hasAllocated;
    }

    // ============= Events =============
    event EpochCreated(uint256 indexed epochId);
    event Deposit(address indexed lp, uint256 epochId, uint256 amount, uint256 sharesMinted);
    event Withdraw(address indexed lp, uint256 epochId, uint256 amount, uint256 sharesBurned);
    event EpochSplit(uint256 indexed epochId, uint256 lockedShareCount, uint256 rolloverEpochId);
    event Materialized(address indexed lp, uint256 indexed fromEpoch, uint256 lockedShares, uint256 rolloverShares);
    event TradeLayerCreated(uint256 indexed layerId, uint256 requiredBacking, uint256 fundingEpochId);
    event AllocationClaimed(uint256 indexed layerId, address indexed lp, uint256 allocation);
    event AllocationReleased(uint256 indexed layerId, address indexed lp, uint256 allocation);
    event TradeLayerActivated(uint256 indexed layerId);
    event TradeLayerClosed(uint256 indexed layerId, uint256 profitLoss, bool isProfit);

    // ============= Errors =============
    error LPManager__BadSplitState();
    error LPManager__MustMaterializeSequentially();
    error LPManager__ZeroAddress();
    error LPManager__InvalidDeposit();
    error LPManager__ZeroAmount();
}
