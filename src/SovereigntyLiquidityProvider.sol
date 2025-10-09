// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICngn} from "./interfaces/ICngn.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract SovereigntyLiquidityProvider is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for ICngn;

    error SLP__ZeroAddress();
    error SLP__UnAuthorized();
    error SLP__InvalidAmount();

    ICngn public immutable CNGN; // cNGN
    address public immutable i_admin;

    uint256 private s_totalShares;
    uint256 private s_totalLPs;
    uint256 constant MIN_DEPOSIT = 100_000;
    uint256 constant MAX_DEPOSIT = 1_000_000_000;

    struct LiquidityProvider {
        uint256 shares;
        uint256 ownershipPercent;
    }

    mapping(address lp => LiquidityProvider) private s_LP;

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

    constructor(address _liquidityToken, address _admin) Ownable(_admin) {
        if (_liquidityToken == address(0) || _admin == address(0)) {
            revert SLP__ZeroAddress();
        }

        CNGN = ICngn(_liquidityToken);
        i_admin = _admin;
    }

    function pause() external onlyAdmin {
        _pause();
    }

    function unpause() external onlyAdmin {
        _unpause();
    }

    function deposit(uint256 _amount, address _receiver) external whenNotPaused validAmount(_amount) nonReentrant {
        CNGN.safeTransferFrom(msg.sender, address(this), _amount);
    }
}
