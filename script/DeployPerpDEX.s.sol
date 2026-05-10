// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PerpDEX} from "../src/PerpDEX.sol";
import {MarketVault} from "../src/MarketVault.sol";
import {SovereigntyAccessManager} from "../src/SovereigntyAccessManager.sol";

/// @title DeployPerpDEX
/// @notice Deployment script for the full PerpDEX trading engine + all 11 MarketVaults on Base.
/// @dev Deploys the PerpDEX contract, then loops through 11 market definitions
///      (3 Crypto, 1 Commodity, 2 Metal, 3 Equity, 2 FX), deploying an isolated
///      ERC4626 MarketVault for each, and configuring SAM function-level access control.
///
///      Deployment flow:
///        1. Deploy PerpDEX (constructor: cNGN, Pyth, Chainlink NGN/USD, staleness, SAM).
///        2. Define all 11 markets via `_defineMarkets()` with per-category parameters.
///        3. For each market: deploy MarketVault → link vault to PerpDEX → add market to PerpDEX.
///        4. Configure SAM function roles for PerpDEX (MARKET_MANAGER, OPERATOR, PAUSER).
///
///      Required environment variables:
///        SAM_PROXY            — deployed SovereigntyAccessManager proxy address.
///        DEPLOYER_PRIVATE_KEY — wallet that broadcasts (must hold MARKET_MANAGER + VAULT_MANAGER roles).
///
///      Hardcoded Base mainnet addresses:
///        cNGN             = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F (6 decimals)
///        Pyth             = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a
///        Chainlink NGN/USD = 0xdfbb5Cbc88E382de007bfe6CE99C388176ED80aD (8 decimals)
///
///      Usage:
///        forge script script/DeployPerpDEX.s.sol --rpc-url $BASE_RPC --broadcast --verify
contract DeployPerpDEX is Script {
    /*//////////////////////////////////////////////////////////////
                          TOKEN & ORACLE ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @dev cNGN stablecoin on Base — 6 decimals, used as collateral and settlement token.
    address constant CNGN = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F;

    /// @dev Pyth Network oracle contract on Base — provides Asset/USD price feeds.
    address constant PYTH = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;

    /// @dev Chainlink NGN/USD price feed on Base (8 decimals).
    ///      Inverted on-chain to produce USD/NGN for price triangulation.
    address constant NGN_USD_CHAINLINK = 0xdfbb5Cbc88E382de007bfe6CE99C388176ED80aD;

    /// @dev Maximum age (in seconds) for the Chainlink NGN/USD answer.
    ///      Set to 1 hour — Chainlink forex feeds update on a heartbeat schedule.
    uint256 constant USD_NGN_STALENESS = 3600;

    /*//////////////////////////////////////////////////////////////
                     PYTH ASSET/USD FEED IDS
    //////////////////////////////////////////////////////////////*/

    /// @dev Each bytes32 is a Pyth price feed ID (keccak of the feed descriptor).
    ///      Used by PerpDEX.getAssetUsdPrice() to query the Pyth oracle.
    bytes32 constant BTC_USD_FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant ETH_USD_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 constant SOL_USD_FEED = 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d;
    bytes32 constant BRENT_USD_FEED = 0x27f0d5e09a830083e5491795cac9ca521399c8f7fd56240d09484b14e614d57a;
    bytes32 constant XAG_USD_FEED = 0xf2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e;
    bytes32 constant XAU_USD_FEED = 0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2;
    bytes32 constant NVDA_USD_FEED = 0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593;
    bytes32 constant TSLA_USD_FEED = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
    bytes32 constant AAPL_USD_FEED = 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688;
    bytes32 constant EUR_USD_FEED = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;
    bytes32 constant GBP_USD_FEED = 0x84c2dde9633d93d1bcad84e7dc41c9d56578b7ec52fabedc1f335d673df0a7c1;

    /*//////////////////////////////////////////////////////////////
                          MARKET IDS
    //////////////////////////////////////////////////////////////*/

    /// @dev Each market ID is a keccak256 hash of the human-readable pair name.
    ///      These must match exactly what the front-end and keeper bots use.
    bytes32 constant BTC_MARKET = keccak256("BTC-PERP");
    bytes32 constant ETH_MARKET = keccak256("ETH-PERP");
    bytes32 constant SOL_MARKET = keccak256("SOL-PERP");
    bytes32 constant BRENT_MARKET = keccak256("BRENT-PERP");
    bytes32 constant XAG_MARKET = keccak256("XAG-PERP");
    bytes32 constant XAU_MARKET = keccak256("XAU-PERP");
    bytes32 constant NVDA_MARKET = keccak256("NVDA-PERP");
    bytes32 constant TSLA_MARKET = keccak256("TSLA-PERP");
    bytes32 constant AAPL_MARKET = keccak256("AAPL-PERP");
    bytes32 constant EUR_MARKET = keccak256("EUR-PERP");
    bytes32 constant GBP_MARKET = keccak256("GBP-PERP");

    /*//////////////////////////////////////////////////////////////
                 PER-CATEGORY MARKET PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Staleness thresholds per asset category (in seconds).
    ///      Crypto feeds update every ~2 min; commodities/metals/equities every ~5 min;
    ///      FX feeds every ~10 min.
    uint256 constant CRYPTO_MAX_STALENESS = 120; // 2 min
    uint256 constant COMMODITY_MAX_STALENESS = 300; // 5 min
    uint256 constant METAL_MAX_STALENESS = 300;
    uint256 constant EQUITY_MAX_STALENESS = 300;
    uint256 constant FX_MAX_STALENESS = 600; // 10 min

    /// @dev Maximum leverage per asset category. Crypto is more liquid → 5x;
    ///      non-crypto categories are capped at 3x to limit vault exposure.
    uint256 constant CRYPTO_MAX_LEVERAGE = 5;
    uint256 constant METAL_MAX_LEVERAGE = 3;
    uint256 constant EQUITY_MAX_LEVERAGE = 3;
    uint256 constant FX_MAX_LEVERAGE = 3;
    uint256 constant COMMODITY_MAX_LEVERAGE = 3;

    /// @dev Maintenance margin ratio — 2% (2e16 / 1e18). Positions with equity
    ///      below this fraction of notional are liquidatable.
    uint256 constant MAINTENANCE_MARGIN = 2e16;

    /// @dev Open interest cap multiplier — 5× vault TVL. Maximum total OI per
    ///      market is `vaultTVL * OI_MULTIPLIER / 1e18`.
    uint256 constant OI_MULTIPLIER = 5e18;

    /*//////////////////////////////////////////////////////////////
                        MARKET DEFINITION
    //////////////////////////////////////////////////////////////*/

    /// @dev Aggregates all per-market deployment parameters into a single struct
    ///      so `_defineMarkets()` can return a cleanly iterable array.
    /// @param marketId     keccak256 hash of the market pair name (e.g. "ETH-PERP").
    /// @param feedId       Pyth price feed ID for the Asset/USD pair.
    /// @param maxStaleness Maximum allowable age (seconds) for the Pyth price.
    /// @param maxLeverage  Maximum leverage traders can use on this market.
    /// @param marketType   Asset category enum (Crypto, Commodity, Metal, Equity, FX).
    /// @param shareName    ERC20 name for the MarketVault share token.
    /// @param shareSymbol  ERC20 symbol for the MarketVault share token.
    struct MarketDef {
        bytes32 marketId;
        bytes32 feedId;
        uint256 maxStaleness;
        uint256 maxLeverage;
        PerpDEX.MarketType marketType;
        string shareName;
        string shareSymbol;
    }

    /*//////////////////////////////////////////////////////////////
                          MAIN DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys the full PerpDEX stack: engine + 11 vaults + SAM role bindings.
    /// @dev Steps:
    ///      1. Deploy PerpDEX with oracle and SAM references.
    ///      2. Build market definitions via `_defineMarkets()`.
    ///      3. For each market: deploy MarketVault → link to PerpDEX → register market.
    ///      4. Bind SAM function-level roles: MARKET_MANAGER, OPERATOR, PAUSER.
    function run() external {
        address samProxy = vm.envAddress("SAM_PROXY");

        vm.startBroadcast();

        // 1. Deploy PerpDEX
        PerpDEX perp = new PerpDEX(CNGN, PYTH, NGN_USD_CHAINLINK, USD_NGN_STALENESS, samProxy);
        console.log("PerpDEX deployed at:", address(perp));

        // 2. Define all markets
        MarketDef[] memory markets = _defineMarkets();

        // 3. Deploy vaults and add markets
        for (uint256 i = 0; i < markets.length; i++) {
            MarketDef memory m = markets[i];

            // Deploy vault
            MarketVault vault = new MarketVault(IERC20(CNGN), samProxy, m.marketId, m.shareName, m.shareSymbol);
            console.log(string.concat("Vault ", m.shareSymbol, " deployed at:"), address(vault));

            // Link vault to PerpDEX
            vault.setPerpDex(address(perp));

            // Add market to PerpDEX
            perp.addMarket(
                m.marketId,
                m.feedId,
                m.maxStaleness,
                m.maxLeverage,
                MAINTENANCE_MARGIN,
                OI_MULTIPLIER,
                m.marketType,
                address(vault)
            );
        }

        // 4. Configure SAM roles for PerpDEX and all vaults
        SovereigntyAccessManager sam = SovereigntyAccessManager(samProxy);

        // PerpDEX: market manager selectors
        bytes4[] memory marketMgrSels = new bytes4[](3);
        marketMgrSels[0] = PerpDEX.addMarket.selector;
        marketMgrSels[1] = PerpDEX.disableMarket.selector;
        marketMgrSels[2] = PerpDEX.updateMarketParams.selector;
        sam.setTargetFunctionRole(address(perp), marketMgrSels, sam.MARKET_MANAGER_ROLE());

        // PerpDEX: operator selectors
        bytes4[] memory operatorSels = new bytes4[](3);
        operatorSels[0] = PerpDEX.setUsdNgnFeed.selector;
        operatorSels[1] = PerpDEX.setForwarder.selector;
        operatorSels[2] = PerpDEX.unpause.selector;
        sam.setTargetFunctionRole(address(perp), operatorSels, sam.OPERATOR_ROLE());

        // PerpDEX: pauser selectors
        bytes4[] memory pauserSels = new bytes4[](1);
        pauserSels[0] = PerpDEX.pause.selector;
        sam.setTargetFunctionRole(address(perp), pauserSels, sam.PAUSER_ROLE());

        console.log("SAM function roles configured for PerpDEX");

        vm.stopBroadcast();
    }

    /// @notice Builds the array of all 11 market definitions.
    /// @dev Markets are grouped by category:
    ///      - Crypto (3): BTC, ETH, SOL — 120s staleness, 5× leverage
    ///      - Commodity (1): BRENT — 300s staleness, 3× leverage
    ///      - Metal (2): XAG, XAU — 300s staleness, 3× leverage
    ///      - Equity (3): NVDA, TSLA, AAPL — 300s staleness, 3× leverage
    ///      - FX (2): EUR, GBP — 600s staleness, 3× leverage
    ///      All markets share 2% maintenance margin and 5× OI cap multiplier.
    /// @return m Array of MarketDef structs, one per market.
    function _defineMarkets() internal pure returns (MarketDef[] memory) {
        MarketDef[] memory m = new MarketDef[](11);

        // Crypto
        m[0] = MarketDef(
            BTC_MARKET,
            BTC_USD_FEED,
            CRYPTO_MAX_STALENESS,
            CRYPTO_MAX_LEVERAGE,
            PerpDEX.MarketType.Crypto,
            "cNGN Vault Share - BTC",
            "vcNGN-BTC"
        );
        m[1] = MarketDef(
            ETH_MARKET,
            ETH_USD_FEED,
            CRYPTO_MAX_STALENESS,
            CRYPTO_MAX_LEVERAGE,
            PerpDEX.MarketType.Crypto,
            "cNGN Vault Share - ETH",
            "vcNGN-ETH"
        );
        m[2] = MarketDef(
            SOL_MARKET,
            SOL_USD_FEED,
            CRYPTO_MAX_STALENESS,
            CRYPTO_MAX_LEVERAGE,
            PerpDEX.MarketType.Crypto,
            "cNGN Vault Share - SOL",
            "vcNGN-SOL"
        );

        // Commodity
        m[3] = MarketDef(
            BRENT_MARKET,
            BRENT_USD_FEED,
            COMMODITY_MAX_STALENESS,
            COMMODITY_MAX_LEVERAGE,
            PerpDEX.MarketType.Commodity,
            "cNGN Vault Share - BRENT",
            "vcNGN-BRENT"
        );

        // Metal
        m[4] = MarketDef(
            XAG_MARKET,
            XAG_USD_FEED,
            METAL_MAX_STALENESS,
            METAL_MAX_LEVERAGE,
            PerpDEX.MarketType.Metal,
            "cNGN Vault Share - XAG",
            "vcNGN-XAG"
        );
        m[5] = MarketDef(
            XAU_MARKET,
            XAU_USD_FEED,
            METAL_MAX_STALENESS,
            METAL_MAX_LEVERAGE,
            PerpDEX.MarketType.Metal,
            "cNGN Vault Share - XAU",
            "vcNGN-XAU"
        );

        // Equity
        m[6] = MarketDef(
            NVDA_MARKET,
            NVDA_USD_FEED,
            EQUITY_MAX_STALENESS,
            EQUITY_MAX_LEVERAGE,
            PerpDEX.MarketType.Equity,
            "cNGN Vault Share - NVDA",
            "vcNGN-NVDA"
        );
        m[7] = MarketDef(
            TSLA_MARKET,
            TSLA_USD_FEED,
            EQUITY_MAX_STALENESS,
            EQUITY_MAX_LEVERAGE,
            PerpDEX.MarketType.Equity,
            "cNGN Vault Share - TSLA",
            "vcNGN-TSLA"
        );
        m[8] = MarketDef(
            AAPL_MARKET,
            AAPL_USD_FEED,
            EQUITY_MAX_STALENESS,
            EQUITY_MAX_LEVERAGE,
            PerpDEX.MarketType.Equity,
            "cNGN Vault Share - AAPL",
            "vcNGN-AAPL"
        );

        // Forex
        m[9] = MarketDef(
            EUR_MARKET,
            EUR_USD_FEED,
            FX_MAX_STALENESS,
            FX_MAX_LEVERAGE,
            PerpDEX.MarketType.FX,
            "cNGN Vault Share - EUR",
            "vcNGN-EUR"
        );
        m[10] = MarketDef(
            GBP_MARKET,
            GBP_USD_FEED,
            FX_MAX_STALENESS,
            FX_MAX_LEVERAGE,
            PerpDEX.MarketType.FX,
            "cNGN Vault Share - GBP",
            "vcNGN-GBP"
        );

        return m;
    }
}
