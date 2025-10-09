// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ------------------------------------------------------------------
//                             IMPORTS
// ------------------------------------------------------------------
import {ICngn} from "./interfaces/ICngn.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract SovereigntyLiquidityProvider is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for ICngn;

    // ------------------------------------------------------------------
    //                              ERRORS
    // ------------------------------------------------------------------
    error SLP__ZeroAddress();
    error SLP__UnAuthorized();
    error SLP__InvalidAmount();

    // ------------------------------------------------------------------
    //                              TYPES
    // ------------------------------------------------------------------
    struct LiquidityProvider {
        uint256 assets;
        uint256 shares;
    }

    // ------------------------------------------------------------------
    //                     IMMUTABLES AND CONSTANTS
    // ------------------------------------------------------------------
    ICngn public immutable CNGN; // cNGN
    address public immutable i_admin;
    uint256 constant MIN_DEPOSIT = 100_000e6; // 100 Thousand CNGN
    uint256 constant MAX_DEPOSIT = 1_000_000_000e6; // 1 Billion CNGN

    // ------------------------------------------------------------------
    //                             STORAGE
    // ------------------------------------------------------------------
    uint256 private s_totalShares;
    uint256 private s_totalLPs;

    // ------------------------------------------------------------------
    //                             MAPPINGS
    // ------------------------------------------------------------------
    mapping(address lp => LiquidityProvider) private s_LP;

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

    // ------------------------------------------------------------------
    //                           CONSTRUCTOR
    // ------------------------------------------------------------------
    constructor(address _liquidityToken, address _admin) Ownable(_admin) {
        if (_liquidityToken == address(0) || _admin == address(0)) {
            revert SLP__ZeroAddress();
        }

        CNGN = ICngn(_liquidityToken);
        i_admin = _admin;
    }

    // ------------------------------------------------------------------
    //                        EXTERNAL FUNCTIONS
    // ------------------------------------------------------------------
    function deposit(uint256 _amount, address _receiver) external whenNotPaused validAmount(_amount) nonReentrant {
        if (_receiver == address(0)) {
            revert SLP__ZeroAddress();
        }
        CNGN.safeTransferFrom(msg.sender, address(this), _amount);
    }

    // ------------------------------------------------------------------
    //                        INTERNAL FUNCTIONS
    // ------------------------------------------------------------------
    function _calculateShares() internal returns (uint256) {}

    // ------------------------------------------------------------------
    //                       ONLY-ADMIN FUNCTIONS
    // ------------------------------------------------------------------
    function pause() external onlyAdmin {
        _pause();
    }

    function unpause() external onlyAdmin {
        _unpause();
    }
}
