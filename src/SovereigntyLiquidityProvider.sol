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

    // ------------------------------------------------------------------
    //                              ERRORS
    // ------------------------------------------------------------------
    error SLP__ZeroAddress();
    error SLP__UnAuthorized();
    error SLP__InvalidAmount();
    error SLP__BadSplitState();
    error SLP__MustMaterializeSequentially();

    // ------------------------------------------------------------------
    //                              EVENTS
    // ------------------------------------------------------------------
    event SLP__EpochCreated(uint256 indexed epochId);
    event SLP__Deposit(address indexed lp, uint256 epochId, uint256 amount, uint256 sharesMinted);
    event SLP__Withdraw(address indexed lp, uint256 epochId, uint256 amount, uint256 sharesBurned);
    event SLP__EpochSplit(uint256 indexed epochId, uint256 lockedShareCount, uint256 rolloverEpochId);
    event SLP__Materialized(
        address indexed lp, uint256 indexed fromEpoch, uint256 lockedShares, uint256 rolloverShares
    );
    event SLP__TradeLayerCreated(uint256 indexed layerId, uint256 requiredBacking, uint256 fundingEpochId);
    event SLP__AllocationClaimed(uint256 indexed layerId, address indexed lp, uint256 allocation);
    event SLP__AllocationReleased(uint256 indexed layerId, address indexed lp, uint256 allocation);
    event SLP__TradeLayerActivated(uint256 indexed layerId);
    event SLP__TradeLayerClosed(uint256 indexed layerId, uint256 profitLoss, bool isProfit);

    // ------------------------------------------------------------------
    //                              TYPES
    // ------------------------------------------------------------------

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

    // ------------------------------------------------------------------
    //                     IMMUTABLES AND CONSTANTS
    // ------------------------------------------------------------------
    ICngn public immutable CNGN; // cNGN which is liquidity token
    address public immutable i_admin;
    uint256 constant MIN_DEPOSIT = 100_000e6; // 100 Thousand CNGN
    uint256 constant MAX_DEPOSIT = 1_000_000_000e6; // 1 Billion CNGN
    uint256 constant PRECISION = 1e6;

    // uint256 private s_totalShares;
    // uint256 private s_totalLPs;

    // ------------------------------------------------------------------
    //                          EPOCH STORAGE
    // ------------------------------------------------------------------

    // epoch id => Epoch
    mapping(uint256 => Epoch) public epochs;

    // LP -> epochId -> scaled shares
    mapping(address => mapping(uint256 => uint256)) public epochSharesOf;

    // current epoch that receives new deposits
    uint256 public currentEpochId;

    // aggregate free assets across all epochs (cached for efficiency)
    uint256 public globalFreeAssets;

    // ------------------------------------------------------------------
    //                            LP STORAGE
    // ------------------------------------------------------------------

    mapping(address => LiquidityProvider) public liquidityProviders;
    mapping(address => uint256) public lastMaterializedEpoch;

    // ------------------------------------------------------------------
    //                       TRADE LAYER STORAGE
    // ------------------------------------------------------------------

    mapping(uint256 => TradeLayer) internal tradeLayers;
    uint256 public temporalSequenceCounter;

    // ------------------------------------------------------------------
    //                            MODIFIERS
    // ------------------------------------------------------------------
    modifier onlyAdmin() {
        if (msg.sender != i_admin) {
            revert SLP__UnAuthorized();
        }
        _;
    }

    modifier validAmount(uint256 _amount) {
        if (_amount < MIN_DEPOSIT || _amount > MAX_DEPOSIT) {
            revert SLP__InvalidAmount();
        }
        _;
    }

    modifier validAddress(address _addr) {
        if (_addr == address(0)) {
            revert SLP__ZeroAddress();
        }
        _;
    }

    // ------------------------------------------------------------------
    //                           CONSTRUCTOR
    // ------------------------------------------------------------------
    constructor(address _liquidityToken, address _admin) Ownable(_admin) {
        if (_liquidityToken == address(0) || _admin == address(0)) {
            revert SLP__ZeroAddress();
        }

        CNGN = ICngn(_liquidityToken);
        i_admin = _admin;

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
        emit SLP__EpochCreated(currentEpochId);
    }

    // ------------------------------------------------------------------
    //                        EXTERNAL FUNCTIONS
    // ------------------------------------------------------------------

    function deposit(uint256 _amount, address _onBehalfOf)
        external
        validAmount(_amount)
        validAddress(_onBehalfOf)
        nonReentrant
    {
        Epoch storage e = epochs[currentEpochId];

        // make transfer from msg.sender
        CNGN.safeTransferFrom(msg.sender, address(this), _amount);

        // mint shares
        uint256 shares = _amount * PRECISION;

        // update epoch accounting
        e.freeAssets += _amount;
        e.totalShares += shares;

        // credit _onBehalfOf as LP
        epochSharesOf[_onBehalfOf][currentEpochId] += shares;

        // update LP summary
        LiquidityProvider storage lp = liquidityProviders[_onBehalfOf];
        if (!lp.exists) {
            lp.exists = true;
            lastMaterializedEpoch[_onBehalfOf] = currentEpochId;
        }
        lp.totalShares += shares;

        // update global free assets
        globalFreeAssets += _amount;

        emit SLP__Deposit(_onBehalfOf, currentEpochId, _amount, shares);
    }

    // ------------------------------------------------------------------
    //                        INTERNAL FUNCTIONS
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    //                       ONLY-ADMIN FUNCTIONS
    // ------------------------------------------------------------------
    // function pause() external onlyAdmin {
    //     _pause();
    // }

    // function unpause() external onlyAdmin {
    //     _unpause();
    // }
}
