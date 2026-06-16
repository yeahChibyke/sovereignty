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
    ///         Reverts if the live oracle is stale and there is open interest.
    function getMarketUnrealizedPnL(bytes32 marketId) external view returns (int256);

    /// @notice Oracle-independent fallback for {getMarketUnrealizedPnL} using the last cached
    ///         mark price. Never reverts on a stale feed.
    function getMarketUnrealizedPnLSafe(bytes32 marketId) external view returns (int256);

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
///          realized PnL, then `payTrader()` to move tokens out (trader collateral is pulled in
///          directly by PerpDEX via `safeTransferFrom`, so the vault has no pull function).
///        - `globalTraderPnL` is a running tally used as a fallback before PerpDEX is linked.
///
///      Access control:
///        - `setPerpDex()` is gated by `SovereigntyAccessManager` (VAULT_MANAGER_ROLE).
///        - Settlement functions (`settlePnL`, `payTrader`) are gated by the `onlyPerpDex`
///          modifier — only the linked PerpDEX can call them.
///        - LP deposits/mints are permissionless (fresh-price gated). LP exits use a two-step
///          `requestRedeem` → `claimRedeem` cooldown; instant ERC4626 `withdraw`/`redeem` revert.
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

    /// @notice Cooldown (seconds) an LP must wait between requesting and claiming a withdrawal.
    /// @dev Makes LP liquidity sticky: it cannot be deposited and pulled within the same window
    ///      (defeating flash/transient OI-cap inflation), and a request placed during oracle
    ///      downtime simply claims on recovery at a FRESH price (no permanent freeze, no stale
    ///      exit). Governance-tunable via `setWithdrawalCooldown`.
    uint256 public withdrawalCooldown;

    /// @notice A pending LP withdrawal request. One per owner at a time.
    /// @param shares      Vault shares escrowed in this contract for the request.
    /// @param claimableAt Earliest timestamp `claimRedeem()` may execute.
    struct WithdrawalRequest {
        uint256 shares;
        uint256 claimableAt;
    }

    /// @notice Pending withdrawal request per LP. `shares == 0` means no active request.
    mapping(address => WithdrawalRequest) public withdrawalRequests;

    /// @notice Total shares currently escrowed across all pending withdrawal requests.
    uint256 public totalPendingWithdrawalShares;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown when a settlement function is called by an address other than `perpDex`.
    error OnlyPerpDex();

    /// @dev Thrown when attempting to set `perpDex` to the zero address.
    error ZeroAddress();

    /// @dev Thrown when instant ERC4626 `withdraw`/`redeem` is called — use the request flow.
    error UseRequestRedeem();

    /// @dev Thrown when `claimRedeem`/`cancelRedeem` is called with no active request.
    error NoWithdrawalRequest();

    /// @dev Thrown when `requestRedeem` is called while a request is already pending.
    error WithdrawalAlreadyPending();

    /// @dev Thrown when `claimRedeem` is called before the cooldown has elapsed.
    error CooldownNotElapsed();

    /// @dev Thrown when `requestRedeem` is called with zero shares.
    error ZeroShares();

    /// @dev Thrown when a deposit/mint is attempted while the vault is insolvent (NAV clamped to
    ///      0 with shares outstanding) — would mint value-free shares.
    error VaultInsolvent();

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

    /// @notice Emitted when an LP requests a withdrawal (shares escrowed, cooldown started).
    event WithdrawalRequested(address indexed owner, uint256 shares, uint256 claimableAt);

    /// @notice Emitted when an LP claims a matured withdrawal request.
    event WithdrawalClaimed(address indexed owner, uint256 shares, uint256 assets);

    /// @notice Emitted when an LP cancels a pending withdrawal request (shares returned).
    event WithdrawalCancelled(address indexed owner, uint256 shares);

    /// @notice Emitted when the withdrawal cooldown is changed.
    event WithdrawalCooldownSet(uint256 cooldown);

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
    /// @param _withdrawalCooldown Seconds an LP must wait between `requestRedeem` and `claimRedeem`.
    constructor(
        IERC20 _cNGN,
        address _accessManager,
        bytes32 _marketId,
        string memory _shareName,
        string memory _shareSymbol,
        uint256 _withdrawalCooldown
    ) ERC4626(_cNGN) ERC20(_shareName, _shareSymbol) AccessManaged(_accessManager) {
        marketId = _marketId;
        withdrawalCooldown = _withdrawalCooldown;
    }

    /// @notice Update the LP withdrawal cooldown.
    /// @dev Restricted via SovereigntyAccessManager (VAULT_MANAGER_ROLE). Applies to requests
    ///      made after the change; already-pending requests keep their original `claimableAt`.
    /// @param _withdrawalCooldown New cooldown in seconds.
    function setWithdrawalCooldown(uint256 _withdrawalCooldown) external restricted {
        withdrawalCooldown = _withdrawalCooldown;
        emit WithdrawalCooldownSet(_withdrawalCooldown);
    }

    /*//////////////////////////////////////////////////////////////
                           ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts function access to the linked PerpDEX contract.
    ///      Used by `settlePnL` and `payTrader`.
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
    ///      movement happens separately via `payTrader()`.
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
            uint256 collateralHeld = IMarketPerpDEX(_perpDex).marketCollateralHeld(marketId);

            // Primary path: live unrealized PnL. If the oracle is stale this reverts, so we fall
            // back to the cached-price variant so this VIEW (previews/getters) keeps working.
            // NOTE: this fallback does NOT make value-moving LP actions available during downtime —
            // deposit/mint/withdraw/redeem all call `_requireFreshPricing()` and revert when the
            // feed is stale and open interest exists, so no one enters OR exits at a stale price.
            int256 unrealizedPnL;
            try IMarketPerpDEX(_perpDex).getMarketUnrealizedPnL(marketId) returns (int256 live) {
                unrealizedPnL = live;
            } catch {
                unrealizedPnL = IMarketPerpDEX(_perpDex).getMarketUnrealizedPnLSafe(marketId);
            }

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

    /*//////////////////////////////////////////////////////////////
                     LP ENTRY/EXIT GUARD (FRESH PRICING)
    //////////////////////////////////////////////////////////////*/

    /// @dev Require a fresh oracle before any value-moving LP action (deposit/mint/withdraw/redeem)
    ///      while the market has open interest. `totalAssets()` falls back to a cached price during
    ///      oracle downtime so read-only callers (previews, getters) don't revert, but actually
    ///      MOVING value at a stale share price is unsafe in BOTH directions: a stale price lets an
    ///      entrant buy in cheap OR an exiter redeem rich. Gating both sides closes that asymmetry.
    ///      No-op before PerpDEX is linked, or when the market has no open interest (no oracle
    ///      dependency — `getMarketUnrealizedPnL` returns 0 without reading a feed), so LPs can
    ///      always enter/exit a market that holds no positions, even during an outage.
    function _requireFreshPricing() internal view {
        address _perpDex = perpDex;
        if (_perpDex != address(0) && _perpDex.code.length > 0) {
            // Reverts if there is open interest and the live oracle is stale.
            IMarketPerpDEX(_perpDex).getMarketUnrealizedPnL(marketId);
        }
    }

    /// @dev Block new LP capital while the vault is economically insolvent — i.e. `totalAssets()`
    ///      has clamped to 0 (LP-available assets ≤ 0 because traders are deeply in profit) while
    ///      shares are still outstanding. With ERC4626's `+1` virtual offset, depositing against a
    ///      zero NAV would mint ~`totalSupply` shares per asset-wei (value-free), letting a depositor
    ///      capture pre-existing LP capital once the NAV recovers. Reverting here closes that.
    function _requireSolvent() internal view {
        if (totalSupply() > 0 && totalAssets() == 0) revert VaultInsolvent();
    }

    /// @inheritdoc ERC4626
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _requireFreshPricing();
        _requireSolvent();
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626
    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _requireFreshPricing();
        _requireSolvent();
        return super.mint(shares, receiver);
    }

    /// @inheritdoc ERC4626
    /// @dev Instant withdrawal is disabled — LP exits go through the `requestRedeem`/`claimRedeem`
    ///      cooldown flow (see `requestRedeem`). This is standard for perp LP vaults (GLP/GM/HLP).
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert UseRequestRedeem();
    }

    /// @inheritdoc ERC4626
    /// @dev Instant redemption is disabled — use `requestRedeem`/`claimRedeem`.
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert UseRequestRedeem();
    }

    /*//////////////////////////////////////////////////////////////
                     LP WITHDRAWAL COOLDOWN (REQUEST → CLAIM)
    //////////////////////////////////////////////////////////////*/

    /// @notice Step 1 of LP exit: escrow `shares` and start the withdrawal cooldown.
    /// @dev The shares are transferred into the vault and held until `claimRedeem` (matured) or
    ///      `cancelRedeem`. They remain part of `totalSupply` (so per-share NAV is unaffected) and
    ///      still earn/bear PnL until claimed — the LP exits at the claim-time NAV, not now. Only
    ///      one request per owner at a time. No price oracle is consulted here (price-agnostic).
    /// @param shares Amount of vault shares to queue for withdrawal.
    function requestRedeem(uint256 shares) external {
        if (shares == 0) revert ZeroShares();
        if (withdrawalRequests[msg.sender].shares != 0) revert WithdrawalAlreadyPending();

        uint256 claimableAt = block.timestamp + withdrawalCooldown;
        withdrawalRequests[msg.sender] = WithdrawalRequest({shares: shares, claimableAt: claimableAt});
        totalPendingWithdrawalShares += shares;

        _transfer(msg.sender, address(this), shares); // escrow (reverts if caller lacks the shares)

        emit WithdrawalRequested(msg.sender, shares, claimableAt);
    }

    /// @notice Step 2 of LP exit: after the cooldown, burn the escrowed shares and pay out assets
    ///         at the current (fresh-priced) NAV.
    /// @dev Requires a fresh oracle (`_requireFreshPricing`) so the exit is never priced off a
    ///      stale feed; a request made during oracle downtime simply claims once the feed recovers.
    /// @return assets The cNGN amount transferred to the caller.
    function claimRedeem() external returns (uint256 assets) {
        WithdrawalRequest memory req = withdrawalRequests[msg.sender];
        if (req.shares == 0) revert NoWithdrawalRequest();
        if (block.timestamp < req.claimableAt) revert CooldownNotElapsed();

        _requireFreshPricing();

        uint256 shares = req.shares;
        delete withdrawalRequests[msg.sender];
        totalPendingWithdrawalShares -= shares;

        assets = previewRedeem(shares);
        // Burn the escrowed shares (owned by this contract) and pay the caller. caller==owner so
        // no allowance is consumed; the vault holds the shares from `requestRedeem`.
        _withdraw(address(this), msg.sender, address(this), assets, shares);

        emit WithdrawalClaimed(msg.sender, shares, assets);
    }

    /// @notice Cancel a pending withdrawal request and return the escrowed shares.
    function cancelRedeem() external {
        WithdrawalRequest memory req = withdrawalRequests[msg.sender];
        if (req.shares == 0) revert NoWithdrawalRequest();

        uint256 shares = req.shares;
        delete withdrawalRequests[msg.sender];
        totalPendingWithdrawalShares -= shares;

        _transfer(address(this), msg.sender, shares); // return escrowed shares

        emit WithdrawalCancelled(msg.sender, shares);
    }
}
