// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ------------------------------------------------------------------
//                             IMPORTS
// ------------------------------------------------------------------
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import 
// import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract SovereigntyLiquidityProvider is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    error SLP__ZeroAddress();
    error SLP__NotValidAmount();
    error SLP__NotAdmin();

    event DepositBoundsSet(uint256 indexed min, uint256 indexed max);

    IERC20 immutable cngn; // liquidity token

    address private s_positionManager;
    address private s_admin;

    uint256 private s_totalShares;
    uint256 private s_MIN_DEPOSIT;
    uint256 private s_MAX_DEPOSIT;

    mapping(address => LiquidityProvider) private s_liquidityProvider;

    struct LiquidityProvider {
        uint256 shares;
        uint256 ownershipPercent;
    }

    modifier onlyAdmin() {
        if (msg.sender != s_admin) {
            revert SLP__NotAdmin();
        }
        _;
    }

    modifier validAmount(uint256 _amount) {
        if (_amount < s_MIN_DEPOSIT || _amount > s_MAX_DEPOSIT) {
            revert SLP__NotValidAmount();
        }
        _;
    }

    constructor(address _liquidityToken, address _admin) Ownable(_admin) {
        if (_liquidityToken == address(0) || _admin == address(0)) {
            revert SLP__ZeroAddress();
        }

        cngn = IERC20(_liquidityToken);
        s_admin = _admin;
    }

    function setDepositBounds(uint256 _min, uint256 _max) public onlyAdmin {
        if (_min == 0 || _max == 0 || _min == _max || _min > _max) {
            revert SLP__NotValidAmount();
        }
        s_MIN_DEPOSIT = _min;
        s_MAX_DEPOSIT = _max;

        emit DepositBoundsSet(s_MIN_DEPOSIT, s_MAX_DEPOSIT);
    }
}
