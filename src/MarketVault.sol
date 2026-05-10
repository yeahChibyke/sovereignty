// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20, IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

/// @notice Minimal interface used by MarketVault to query PerpDEX for live market data.
/// @dev Kept minimal to avoid circular dependencies — the vault only needs unrealized PnL
///      and collateral amounts; it does not import the full PerpDEX contract.
interface IMarketPerpDEX {
    /// @notice Net unrealized PnL of all open positions in a market (token precision, 6 dec).
    ///         Positive = traders are winning (vault liability), negative = traders are losing (vault asset).
    function getMarketUnrealizedPnL(bytes32 marketId) external view returns (int256);

    /// @notice Total collateral deposited by traders for a given market (token precision, 6 dec).
    ///         This collateral is held inside the vault's token balance but belongs to traders,
    ///         not to LPs, so it must be subtracted when computing LP-available assets.
    function marketCollateralHeld(bytes32 marketId) external view returns (uint256);
}

/// @title MarketVault
/// @author Sovereignty Protocol
/// @notice Per-market ERC4626 vault where Liquidity Providers (LPs) deposit cNGN to
///         underwrite trader PnL for a specific perpetual futures market.
///
/// @dev Architecture & isolation model:
///
///      Each market listed on PerpDEX gets its own MarketVault instance. This provides
///      risk isolation: if ETH-PERP traders collectively profit, only the ETH vault's
///      LPs bear the cost — BTC vault LPs are unaffected. This follows the isolated-pool
///      pattern used by GMX V2 and Synthetix V3.
///
///      Token accounting:
///        - The vault's underlying asset is cNGN (6 decimals).
///        - LPs deposit cNGN and receive ERC4626 share tokens (e.g. "vcNGN-ETH").
///        - The vault's cNGN balance includes: LP deposits + trader collateral + realized PnL.
///        - `totalAssets()` subtracts trader collateral and unrealized PnL so the share price
///          accurately reflects the LP-available portion.
///
///      PnL settlement flow:
///        - When a trader closes a position, PerpDEX calls `settlePnL()` to record the
///          realized PnL, then `payTrader()` or `receiveFromTrader()` to move tokens.
///        - `globalTraderPnL` is a running tally used as a fallback before PerpDEX is linked.
///
///      Access control:
///        - `setPerpDex()` is gated by `SovereigntyAccessManager` (VAULT_MANAGER_ROLE).
///        - Settlement functions (`settlePnL`, `payTrader`, `receiveFromTrader`) are gated
///          by the `onlyPerpDex` modifier — only the linked PerpDEX can call them.
///        - LP deposit/withdraw (inherited ERC4626) are permissionless.
contract MarketVault is ERC4626, AccessManaged {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The market this vault underwrites (e.g. `keccak256("ETH-PERP")`).
    /// @dev Set once at construction and never changed — each vault is permanently
    ///      bound to exactly one market.
    bytes32 public immutable marketId;

    /// @notice Address of the PerpDEX contract authorized to settle PnL and move funds.
    /// @dev Initially `address(0)` until the admin calls `setPerpDex()` after deployment.
    ///      Can be updated (e.g. during a PerpDEX migration) via `setPerpDex()`.
    address public perpDex;

    /// @notice Accumulated net realized PnL of all traders settled through this vault.
    /// @dev Positive = traders collectively profited (vault paid out more than it received).
    ///      Negative = traders collectively lost (vault received more than it paid out).
    ///      Used as a fallback in `totalAssets()` when PerpDEX is not yet linked.
    int256 public globalTraderPnL;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown when a settlement function is called by an address other than `perpDex`.
    error OnlyPerpDex();

    /// @dev Thrown when attempting to set `perpDex` to the zero address.
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the PerpDEX address is set or updated.
    /// @param perpDex The new PerpDEX address.
    event PerpDexSet(address indexed perpDex);

    /// @notice Emitted each time PerpDEX settles a trader's realized PnL.
    /// @param pnl               The PnL amount being settled (positive = trader profit).
    /// @param newGlobalTraderPnL Updated cumulative trader PnL after this settlement.
    event PnLSettled(int256 pnl, int256 newGlobalTraderPnL);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys a new MarketVault for a specific market.
    /// @dev The vault is not functional until `setPerpDex()` is called to link it to PerpDEX.
    ///      The share token's name and symbol are set here and cannot be changed later.
    /// @param _cNGN           Address of the cNGN ERC20 token (vault's underlying asset).
    /// @param _accessManager  Address of the SovereigntyAccessManager proxy for role checks.
    /// @param _marketId       Unique identifier for the market this vault underwrites.
    /// @param _shareName      ERC20 name for the vault's share token (e.g. "cNGN Vault Share - ETH").
    /// @param _shareSymbol    ERC20 symbol for the vault's share token (e.g. "vcNGN-ETH").
    constructor(
        IERC20 _cNGN,
        address _accessManager,
        bytes32 _marketId,
        string memory _shareName,
        string memory _shareSymbol
    ) ERC4626(_cNGN) ERC20(_shareName, _shareSymbol) AccessManaged(_accessManager) {
        marketId = _marketId;
    }

    /*//////////////////////////////////////////////////////////////
                           ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts function access to the linked PerpDEX contract.
    ///      Used by `settlePnL`, `payTrader`, and `receiveFromTrader`.
    modifier onlyPerpDex() {
        if (msg.sender != perpDex) revert OnlyPerpDex();
        _;
    }

    /// @notice Set (or update) the PerpDEX address authorized to settle PnL.
    /// @dev Restricted via SovereigntyAccessManager (typically VAULT_MANAGER_ROLE).
    ///      Emits {PerpDexSet}. Reverts with {ZeroAddress} if `_perpDex` is `address(0)`.
    /// @param _perpDex The address of the PerpDEX contract to authorize.
    function setPerpDex(address _perpDex) external restricted {
        if (_perpDex == address(0)) revert ZeroAddress();
        perpDex = _perpDex;
        emit PerpDexSet(_perpDex);
    }

    /*//////////////////////////////////////////////////////////////
                          PNL SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Records a trader's realized PnL in the vault's running tally.
    /// @dev Called by PerpDEX when a position is closed or liquidated. The actual token
    ///      movement happens separately via `payTrader()` / `receiveFromTrader()`.
    ///      This function only updates the accounting (`globalTraderPnL`).
    /// @param _pnl The realized PnL in cNGN token precision (6 decimals).
    ///             Positive = trader profited (vault cost), negative = trader lost (vault gain).
    function settlePnL(int256 _pnl) external onlyPerpDex {
        globalTraderPnL += _pnl;
        emit PnLSettled(_pnl, globalTraderPnL);
    }

    /// @notice Transfers cNGN from the vault to a recipient.
    /// @dev Used by PerpDEX for: profit payouts to winning traders, collateral withdrawals
    ///      on position close, and liquidation bounty payments to liquidators.
    /// @param _to     The recipient address.
    /// @param _amount The amount of cNGN to transfer (token precision, 6 decimals).
    function payTrader(address _to, uint256 _amount) external onlyPerpDex {
        IERC20(asset()).safeTransfer(_to, _amount);
    }

    /// @notice Pulls cNGN from a sender into the vault.
    /// @dev Used by PerpDEX when a trader deposits collateral to open a position.
    ///      Requires prior ERC20 approval from `_from` to this vault.
    /// @param _from   The address to pull tokens from (must have approved this vault).
    /// @param _amount The amount of cNGN to pull (token precision, 6 decimals).
    function receiveFromTrader(address _from, uint256 _amount) external onlyPerpDex {
        IERC20(asset()).safeTransferFrom(_from, address(this), _amount);
    }

    /*//////////////////////////////////////////////////////////////
                     TOTAL ASSETS (MARKET PNL AWARE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the total cNGN available to LPs, accounting for trader obligations.
    /// @dev Overrides ERC4626's `totalAssets()` to produce a PnL-aware share price:
    ///
    ///      When PerpDEX is linked (normal operation):
    ///        `LP assets = vault balance − trader collateral − unrealized PnL`
    ///
    ///        - `vault balance`:      total cNGN held by this contract (LP deposits +
    ///                                trader collateral + settled PnL).
    ///        - `trader collateral`:  cNGN deposited by traders as margin — belongs to
    ///                                traders, not LPs.
    ///        - `unrealized PnL`:     live mark-to-market PnL of all open positions.
    ///                                Positive means traders are winning → those tokens
    ///                                are owed to traders → subtracted from LP assets.
    ///                                Negative means traders are losing → extra value
    ///                                accrues to LPs → subtracted negative = addition.
    ///
    ///      Fallback (PerpDEX not yet linked):
    ///        Uses `globalTraderPnL` (realized-only tally) as a simpler approximation.
    ///        This path is only active before `setPerpDex()` is called.
    ///
    /// @return The LP-available cNGN amount (token precision, 6 decimals). Floors at 0.
    function totalAssets() public view override returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));

        address _perpDex = perpDex;
        if (_perpDex != address(0) && _perpDex.code.length > 0) {
            // Primary path: query PerpDEX for live collateral & unrealized PnL data
            uint256 collateralHeld = IMarketPerpDEX(_perpDex).marketCollateralHeld(marketId);
            int256 unrealizedPnL = IMarketPerpDEX(_perpDex).getMarketUnrealizedPnL(marketId);

            // LP assets = total balance − trader collateral − unrealized trader profit
            int256 lpAssets = int256(balance) - int256(collateralHeld) - unrealizedPnL;
            return lpAssets > 0 ? uint256(lpAssets) : 0;
        }

        // Fallback path: PerpDEX not yet linked, use realized PnL tracking only
        if (globalTraderPnL >= 0) {
            // Traders collectively profitable → subtract their winnings from LP value
            uint256 absTraderPnL = uint256(globalTraderPnL);
            return balance > absTraderPnL ? balance - absTraderPnL : 0;
        } else {
            // Traders collectively lost → their losses are LP gains
            return balance + uint256(-globalTraderPnL);
        }
    }
}
