// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20, IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

/// @notice Minimal interface to query PerpDEX for unrealized PnL and collateral.
interface IPerpDEX {
    function getGlobalUnrealizedPnL() external view returns (int256);
    function totalCollateralHeld() external view returns (uint256);
}

/// @title cNGNVault
/// @notice ERC4626 vault where LPs deposit cNGN to underwrite trader PnL.
///         Share price reflects both realized PnL (settled via token transfers)
///         and unrealized PnL (queried from PerpDEX via live oracle prices),
///         meaning LP exposure increases/decreases with trader profits/losses.
contract cNGNVault is ERC4626, AccessManaged {
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

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PerpDexSet(address indexed perpDex);
    event PnLSettled(int256 pnl, int256 newGlobalTraderPnL);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _cNGN Address of the cNGN ERC20 token.
    /// @param _accessManager Address of the SovereigntyAccessManager proxy.
    constructor(IERC20 _cNGN, address _accessManager)
        ERC4626(_cNGN)
        ERC20("cNGN Vault Share", "vcNGN")
        AccessManaged(_accessManager)
    {}

    /*//////////////////////////////////////////////////////////////
                           ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    modifier onlyPerpDex() {
        if (msg.sender != perpDex) revert OnlyPerpDex();
        _;
    }

    /// @notice Set (or update) the PerpDEX address. Restricted via SovereigntyAccessManager.
    function setPerpDex(address _perpDex) external restricted {
        if (_perpDex == address(0)) revert ZeroAddress();
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

    /// @notice Transfer cNGN to a specified address (profit payouts, collateral withdrawals, or liquidator bounties).
    function payTrader(address _to, uint256 _amount) external onlyPerpDex {
        IERC20(asset()).safeTransfer(_to, _amount);
    }

    /// @notice Pull cNGN from a specified address into the vault.
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

        // Fallback: PerpDEX not yet linked or not a deployed contract, use realized PnL tracking
        if (globalTraderPnL >= 0) {
            uint256 absTraderPnL = uint256(globalTraderPnL);
            return balance > absTraderPnL ? balance - absTraderPnL : 0;
        } else {
            return balance + uint256(-globalTraderPnL);
        }
    }
}
