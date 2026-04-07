// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20, IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Minimal interface to query PerpDEX for unrealized PnL and collateral.
interface IPerpDEX {
    function getGlobalUnrealizedPnL() external view returns (int256);
    function totalCollateralHeld() external view returns (uint256);
}

/// @title cNGNVault
/// @notice ERC4626 vault where LPs deposit cNGN to underwrite trader PnL.
///         Share price reflects the Global PnL of all open trader positions,
///         meaning LP exposure increases/decreases with trader profits/losses.
contract cNGNVault is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the PerpDEX contract allowed to settle PnL.
    address public perpDex;

    /// @notice Accumulated net PnL of all traders settled through this vault.
    ///         Positive = traders profited (vault lost), Negative = traders lost (vault gained).
    int256 public globalTraderPnL;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyPerpDex();
    error ZeroAddress();
    error PerpDexAlreadySet();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PerpDexSet(address indexed perpDex);
    event PnLSettled(int256 pnl, int256 newGlobalTraderPnL);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _cNGN Address of the cNGN ERC20 token.
    constructor(IERC20 _cNGN) ERC4626(_cNGN) ERC20("cNGN Vault Share", "vcNGN") {}

    /*//////////////////////////////////////////////////////////////
                           ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    modifier onlyPerpDex() {
        if (msg.sender != perpDex) revert OnlyPerpDex();
        _;
    }

    /// @notice One-time setter for the PerpDEX address (called after deployment).
    function setPerpDex(address _perpDex) external {
        if (_perpDex == address(0)) revert ZeroAddress();
        if (perpDex != address(0)) revert PerpDexAlreadySet();
        perpDex = _perpDex;
        emit PerpDexSet(_perpDex);
    }

    /*//////////////////////////////////////////////////////////////
                          PNL SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by PerpDEX to settle a trader's realised PnL.
    ///         Positive _pnl = trader won (vault pays out).
    ///         Negative _pnl = trader lost (vault receives).
    function settlePnL(int256 _pnl) external onlyPerpDex {
        globalTraderPnL += _pnl;
        emit PnLSettled(_pnl, globalTraderPnL);
    }

    /// @notice Transfer cNGN out to a trader (profit payout).
    function payTrader(address _to, uint256 _amount) external onlyPerpDex {
        IERC20(asset()).safeTransfer(_to, _amount);
    }

    /// @notice Pull cNGN from the PerpDEX (losses flowing into vault).
    function receiveFromTrader(address _from, uint256 _amount) external onlyPerpDex {
        IERC20(asset()).safeTransferFrom(_from, address(this), _amount);
    }

    /*//////////////////////////////////////////////////////////////
                     TOTAL ASSETS (GLOBAL PNL AWARE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Total assets available to LPs = vault balance - trader collateral - unrealized PnL.
    ///         Includes real-time unrealized PnL from all open positions via live oracle prices,
    ///         preventing LP front-running on unrealized trader profits.
    function totalAssets() public view override returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));

        // When PerpDEX is linked and is a contract, account for open positions
        address _perpDex = perpDex;
        if (_perpDex != address(0) && _perpDex.code.length > 0) {
            uint256 collateralHeld = IPerpDEX(_perpDex).totalCollateralHeld();
            int256 unrealizedPnL = IPerpDEX(_perpDex).getGlobalUnrealizedPnL();

            // LP assets = balance - collateral held for traders - unrealized trader PnL
            int256 lpAssets = int256(balance) - int256(collateralHeld) - unrealizedPnL;
            return lpAssets > 0 ? uint256(lpAssets) : 0;
        }

        // Fallback: PerpDEX not yet linked, use realized PnL tracking
        if (globalTraderPnL >= 0) {
            uint256 absTraderPnL = uint256(globalTraderPnL);
            return balance > absTraderPnL ? balance - absTraderPnL : 0;
        } else {
            return balance + uint256(-globalTraderPnL);
        }
    }
}
