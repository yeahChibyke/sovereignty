// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ------------------------------------------------------------------
//                             IMPORTS
// ------------------------------------------------------------------
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILPManagerEpoch} from "./interfaces/ILPManagerEpoch.sol";

contract SovereigntyLPManagerEpoch is ReentrancyGuard, Ownable, ILPManagerEpoch {
    // ------------------------------------------------------------------
    //                              TYPES
    // ------------------------------------------------------------------
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    //                             STORAGE
    // ------------------------------------------------------------------
    uint256 public constant PRECISION = 1e6; // share scaling factor
    uint256 public constant MIN_DEPOSIT = 100_000e6; // 100_000e6 cngn

    IERC20 public immutable liquidityToken; // cngn

    // ============= Epoch data structures =============

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

    // ------------------------------------------------------------------
    //                           CONSTRUCTOR
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    //                            MODIFIERS
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    //                        DEPOSIT / WITHDRAW
    // ------------------------------------------------------------------

    function deposit(uint256 _amount) external validDeposit(_amount) nonReentrant {
        Epoch storage _e = epochs[currentEpochId];

        liquidityToken.safeTransferFrom(msg.sender, address(this), _amount);

        // mint scaled shares
        uint256 _shares = _amount * PRECISION;

        // update epoch accounting
        _e.freeAssets += _amount;
        _e.totalShares += _shares;

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
        Epoch storage _e = epochs[_epochId];
        require(_e.id == _epochId, "SovereigntyLPManagerEpoch__InvalidEpoch!");

        LiquidityProvider storage lp = liquidityProviders[msg.sender];
        require(lp.exists, "SovereigntyLPManagerEpoch__InexistentLP!");

        // check LP overall availability across epochs
        uint256 _totalBalance = lp.totalShares / PRECISION; // tokens
        uint256 _available = 0;
        if (_totalBalance > lp.accumulatedUtilization) _available = _totalBalance - lp.accumulatedUtilization;
        require(_amount <= _available, "SovereigntyLPManagerEpoch__InsufficientAvailabilityAcrossEpochs!");

        // check epoch-level availability
        require(_e.freeAssets >= _amount, "SovereigntyLPManagerEpoch__EpochInsufficientFreeAssets!");

        uint256 _sharesToBurn = _amount * PRECISION;
        require(
            epochSharesOf[msg.sender][_epochId] >= _sharesToBurn, "SovereigntyLPManagerEpoch__NotEnoughSharesInEpoch!"
        );

        // update epoch and LP bookkeeping
        epochSharesOf[msg.sender][_epochId] -= _sharesToBurn;
        lp.totalShares -= _sharesToBurn;
        if (_e.totalShares >= _sharesToBurn) {
            _e.totalShares -= _sharesToBurn;
        } else {
            _e.totalShares = 0;
        }
        _e.freeAssets -= _amount;

        // update global free assets
        if (globalFreeAssets >= _amount) globalFreeAssets -= _amount;
        else globalFreeAssets = 0;

        // transfer tokens
        liquidityToken.safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _epochId, _amount, _sharesToBurn);
    }

    // ------------------------------------------------------------------
    //                         EPOCH FUNCTIONS
    // ------------------------------------------------------------------

    /**
     * @dev Split an epoch that has been frozen (i.e., some lockedAssets exist)
     * The locked portion remains in the original epoch (its totalShares becomes lockedShareCount).
     * The leftover freeAssets are moved to a new rollover epoch whose totalShares = rolloverShareCount.
     * This function updates epoch-level totals but does NOT touch per-LP balances.
     */
    function _splitEpoch(uint256 _epochId) internal returns (uint256 _newEpochId) {
        Epoch storage _e = epochs[_epochId];
        require(_e.frozen, "SovereigntyLPManagerEpoch_EpochNotFrozen!");
        require(!_e.split, "SovereigntyLPManagerEpoch__AlreadySplit!");

        uint256 _epochTotalAssets = _e.freeAssets + _e.lockedAssets;
        require(_epochTotalAssets > 0, "SovereigntyLPManagerEpoch__EmptyEpoch!");
        require(_e.totalShares > 0, "SovereigntyLPManagerEpoch__NoSharesInEpoch!");

        uint256 _originalTotalShares = _e.totalShares; // scaled

        // compute locked shares representing the lockedAssets
        uint256 _lockedShareCount = (_originalTotalShares * _e.lockedAssets) / _epochTotalAssets;
        uint256 _rolloverShareCount = _originalTotalShares - _lockedShareCount;

        // create new rollover epoch
        _newEpochId = ++currentEpochId;
        epochs[_newEpochId] = Epoch({
            id: _newEpochId,
            totalShares: _rolloverShareCount,
            freeAssets: _e.freeAssets,
            lockedAssets: 0,
            frozen: false,
            split: false,
            preSplitTotalShares: 0,
            rolloverEpochId: 0
        });

        emit EpochCreated(_newEpochId);

        // update original epoch to represent locked portion only
        _e.preSplitTotalShares = _originalTotalShares;
        _e.totalShares = _lockedShareCount;
        _e.freeAssets = 0; // leftover moved to rollover
        _e.split = true;
        _e.rolloverEpochId = _newEpochId;

        emit EpochSplit(_epochId, _lockedShareCount, _newEpochId);

        return _newEpochId;
    }

    /**
     * @dev Materialize a sequence of splits for msg.sender starting from `epochId` to +10 epochs.
     * This moves the caller's rollover shares down the split chain into concrete epochs.
     * Gas cost is paid by the caller. The function is idempotent.
     */
    function materializeShares(uint256 _epochId) external nonReentrant {
        uint256 _eid = _epochId;
        if (_eid != lastMaterializedEpoch[msg.sender]) {
            revert LPManager__MustMaterializeSequentially();
        }

        uint256 _noOfTimesMaterialized;

        while (_noOfTimesMaterialized < 10) {
            Epoch storage _e = epochs[_eid];
            if (!_e.split) break; // nothing to do for this epoch

            uint256 _originalTotal = _e.preSplitTotalShares;
            uint256 _lockedTotal = _e.totalShares; // locked share count after split
            uint256 _rolloverEid = _e.rolloverEpochId;
            if (!(_originalTotal > 0)) revert LPManager__BadSplitState();

            uint256 _sOld = epochSharesOf[msg.sender][_eid];
            if (_sOld > 0) {
                // compute locked and rollover shares for this LP
                uint256 _sLocked = (_sOld * _lockedTotal) / _originalTotal;
                uint256 _sRollover = _sOld - _sLocked;

                // set LP's shares in original epoch to _sLocked
                epochSharesOf[msg.sender][_eid] = _sLocked;

                // credit LP with shares in rollover epoch
                if (_sRollover > 0) {
                    epochSharesOf[msg.sender][_rolloverEid] += _sRollover;
                }

                _noOfTimesMaterialized++;
                emit Materialized(msg.sender, _eid, _sLocked, _sRollover);
            }

            // continue down the chain (in case rollover epoch itself is split later)
            _eid = _rolloverEid;
            if (_eid == 0) break;
        }

        lastMaterializedEpoch[msg.sender] = _eid;
    }

    // ------------------------------------------------------------------
    //                        TRADE LAYER FLOWS
    // ------------------------------------------------------------------

    /**
     * @dev Internal: lock funds from the current epoch, freeze it, and split to roll leftover forward.
     * Returns the epochId that was used to fund (the locked epoch, which after split will contain only locked shares/assets).
     */
    function _lockFromCurrentEpoch(uint256 _amount) internal returns (uint256 _fundingEpochId) {
        Epoch storage _e = epochs[currentEpochId];
        require(!_e.frozen, "SovereigntyLPManagerEpoch__CurrentEpochAlreadyFrozen!");
        require(_e.freeAssets >= _amount, "SovereigntyLPManagerEpoch__NotEnoughFreeAssetsInCurrentEpoch!");

        // move assets to locked
        _e.freeAssets -= _amount;
        _e.lockedAssets += _amount;

        globalFreeAssets -= _amount;

        // freeze epoch
        _e.frozen = true;

        uint256 _originalEpochId = currentEpochId;

        // split epoch to move leftover freeAssets into a new epoch (rollover)
        _splitEpoch(currentEpochId);

        // after split, the original epoch now represents the locked portion
        _fundingEpochId = _originalEpochId;

        // set currentEpochId to the newly created rollover epoch (already set inside _splitEpoch)
        // (currentEpochId was incremented by _splitEpoch)
        return _fundingEpochId;
    }

    /**
     * @dev Create a trade layer that is backed by the current epoch. This will lock `requiredBacking` tokens
     * from the current epoch, freeze it, and roll leftover forward.
     */
    function createTradeLayer(uint256 _requiredBacking) external onlyOwner returns (uint256 _layerId) {}
}
