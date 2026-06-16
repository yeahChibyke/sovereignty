// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {PerpDEX} from "../../src/PerpDEX.sol";
import {MarketVault} from "../../src/MarketVault.sol";
import {SovereigntyAccessManager} from "../../src/SovereigntyAccessManager.sol";

/// @title BaseForkSetup
/// @notice Shared setup for all mainnet fork tests. Forks Base, deploys
///         the full protocol stack using real Pyth and real cNGN.
/// @dev Inheriting test contracts call `super.setUp()` (or just `setUp()` by default)
///      to get:
///        - A pinned Base mainnet fork via `vm.createSelectFork`.
///        - Real cNGN (ERC20 proxy) and real Pyth (push-oracle) at their mainnet addresses.
///        - SAM deployed via ERC1967 proxy with OPERATOR, MARKET_MANAGER, VAULT_MANAGER, PAUSER
///          granted to `operator`.
///        - PerpDEX wired to real Pyth + Chainlink NGN/USD (inverted to USD/NGN).
///        - Three MarketVaults (ETH, BTC, SOL) linked to PerpDEX with 5× leverage,
///          2% maintenance margin, 5× OI cap.
///        - Forwarder set for Automation performUpkeep.
///        - 50M cNGN seeded as LP liquidity across all three vaults.
///        - Traders funded with 2M cNGN each + ETH for Pyth update fees.
///
///      Helper functions:
///        - `_fetchHermesPriceUpdate(feedIds)` — FFI shell call to Hermes for live price blobs.
///        - `_refreshPythPrices(feedIds)` — fetch + push prices on-chain in one call.
///        - `_refreshCryptoPrices()` / `_refreshEthPrices()` / etc. — per-asset convenience wrappers.
///        - `_dealcNGN(to, amount)` — Foundry `deal()` for cNGN (proxy-safe storage write).
///        - `_commitAndExecute(...)` — full commit-reveal helper: hash → request → roll → execute.
///        - `_logPrice(label, price)` — formatted console output.
abstract contract BaseForkSetup is Test {
    /*//////////////////////////////////////////////////////////////
                        BASE MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @dev Live contract addresses on Base mainnet.
    address constant CNGN_ADDRESS = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F;
    address constant PYTH_ADDRESS = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;
    address constant NGN_USD_CHAINLINK = 0xdfbb5Cbc88E382de007bfe6CE99C388176ED80aD;
    address constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    /*//////////////////////////////////////////////////////////////
                         PYTH FEED IDS
    //////////////////////////////////////////////////////////////*/

    /// @dev Production Pyth price feed IDs for all 11 supported Asset/USD pairs.
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

    /// @dev keccak256 hashes of human-readable market pair names.
    bytes32 constant ETH_MARKET = keccak256("ETH-PERP");
    bytes32 constant BTC_MARKET = keccak256("BTC-PERP");
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
                         MARKET PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Per-category staleness thresholds, leverage caps, and shared risk params.
    uint256 constant CRYPTO_MAX_STALENESS = 120;
    uint256 constant COMMODITY_MAX_STALENESS = 300;
    uint256 constant METAL_MAX_STALENESS = 300;
    uint256 constant EQUITY_MAX_STALENESS = 300;
    uint256 constant FX_MAX_STALENESS = 600;
    // Generous NGN/USD staleness for FORK TESTS ONLY. Fork tests read the REAL Base Chainlink
    // NGN/USD feed (a forex feed with a long, irregular heartbeat) and several tests `vm.warp`
    // forward; with the production 3600s window, a test that runs while the live feed is near its
    // heartbeat would intermittently revert `StaleChainlinkPrice()` on a price read it expects to
    // succeed. The staleness *behavior* is covered deterministically by the unit tests (mocked
    // feed); production deploys 3600s (see DeployPerpDEX). 365 days here removes the live-feed
    // timing dependency without affecting the per-market Pyth staleness tests.
    uint256 constant USD_NGN_STALENESS = 365 days;

    uint256 constant CRYPTO_MAX_LEVERAGE = 5;
    uint256 constant NON_CRYPTO_MAX_LEVERAGE = 3;

    uint256 constant MAINTENANCE_MARGIN = 2e16; // 2%
    uint256 constant OI_MULTIPLIER = 5e18; // 5x
    uint256 constant MAX_OPEN_INTEREST = type(uint256).max; // absolute OI ceiling (unbounded for fork tests)
    uint256 constant PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                           CONTRACTS
    //////////////////////////////////////////////////////////////*/

    IERC20 cNGN;
    IPyth pyth;
    SovereigntyAccessManager sam;
    PerpDEX perp;

    MarketVault ethVault;
    MarketVault btcVault;
    MarketVault solVault;

    /*//////////////////////////////////////////////////////////////
                            ACTORS
    //////////////////////////////////////////////////////////////*/

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address trader1 = makeAddr("trader1");
    address trader2 = makeAddr("trader2");
    address trader3 = makeAddr("trader3");
    address liquidator = makeAddr("liquidator");
    address lpProvider = makeAddr("lpProvider");
    address lpProvider2 = makeAddr("lpProvider2");
    address forwarder = makeAddr("forwarder");

    /*//////////////////////////////////////////////////////////////
                          FORK STATE
    //////////////////////////////////////////////////////////////*/

    uint256 baseFork;

    /*//////////////////////////////////////////////////////////////
                             SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Forks Base mainnet and deploys the full protocol stack.
    /// @dev Override in subclasses with `super.setUp()` to extend.
    ///      Steps: fork → reference cNGN/Pyth → deploy SAM → deploy PerpDEX →
    ///      deploy 3 vaults → configure SAM roles → link vaults → add markets →
    ///      set forwarder → deal cNGN → seed LP liquidity → approve PerpDEX → fund ETH.
    function setUp() public virtual {
        // 1. Fork Base mainnet
        baseFork = vm.createSelectFork(vm.envString("RPC_URL"));

        // 2. Reference real contracts
        cNGN = IERC20(CNGN_ADDRESS);
        pyth = IPyth(PYTH_ADDRESS);

        // 3. Deploy SAM
        vm.startPrank(admin);
        SovereigntyAccessManager samImpl = new SovereigntyAccessManager();
        bytes memory initData = abi.encodeCall(SovereigntyAccessManager.initialize, (admin));
        ERC1967Proxy samProxy = new ERC1967Proxy(address(samImpl), initData);
        sam = SovereigntyAccessManager(address(samProxy));

        sam.grantRole(sam.OPERATOR_ROLE(), operator, 0);
        sam.grantRole(sam.MARKET_MANAGER_ROLE(), operator, 0);
        sam.grantRole(sam.VAULT_MANAGER_ROLE(), operator, 0);
        sam.grantRole(sam.PAUSER_ROLE(), operator, 0);
        vm.stopPrank();

        // 4. Deploy PerpDEX with real Pyth + Chainlink NGN/USD
        perp = new PerpDEX(
            CNGN_ADDRESS, PYTH_ADDRESS, NGN_USD_CHAINLINK, USD_NGN_STALENESS, address(sam), SEQUENCER_UPTIME_FEED
        );

        // 5. Deploy MarketVaults for crypto markets
        ethVault = new MarketVault(cNGN, address(sam), ETH_MARKET, "cNGN Vault Share - ETH", "vcNGN-ETH", 0);
        btcVault = new MarketVault(cNGN, address(sam), BTC_MARKET, "cNGN Vault Share - BTC", "vcNGN-BTC", 0);
        solVault = new MarketVault(cNGN, address(sam), SOL_MARKET, "cNGN Vault Share - SOL", "vcNGN-SOL", 0);

        // 6. Configure SAM roles
        vm.startPrank(admin);

        bytes4[] memory marketMgrSelectors = new bytes4[](3);
        marketMgrSelectors[0] = PerpDEX.addMarket.selector;
        marketMgrSelectors[1] = PerpDEX.disableMarket.selector;
        marketMgrSelectors[2] = PerpDEX.updateMarketParams.selector;
        sam.setTargetFunctionRole(address(perp), marketMgrSelectors, sam.MARKET_MANAGER_ROLE());

        bytes4[] memory operatorSelectors = new bytes4[](3);
        operatorSelectors[0] = PerpDEX.setUsdNgnFeed.selector;
        operatorSelectors[1] = PerpDEX.setForwarder.selector;
        operatorSelectors[2] = PerpDEX.unpause.selector;
        sam.setTargetFunctionRole(address(perp), operatorSelectors, sam.OPERATOR_ROLE());

        bytes4[] memory pauserSelectors = new bytes4[](1);
        pauserSelectors[0] = PerpDEX.pause.selector;
        sam.setTargetFunctionRole(address(perp), pauserSelectors, sam.PAUSER_ROLE());

        bytes4[] memory vaultMgrSelectors = new bytes4[](1);
        vaultMgrSelectors[0] = MarketVault.setPerpDex.selector;
        sam.setTargetFunctionRole(address(ethVault), vaultMgrSelectors, sam.VAULT_MANAGER_ROLE());
        sam.setTargetFunctionRole(address(btcVault), vaultMgrSelectors, sam.VAULT_MANAGER_ROLE());
        sam.setTargetFunctionRole(address(solVault), vaultMgrSelectors, sam.VAULT_MANAGER_ROLE());

        vm.stopPrank();

        // 7. Link vaults to PerpDEX + add markets
        vm.startPrank(operator);

        ethVault.setPerpDex(address(perp));
        btcVault.setPerpDex(address(perp));
        solVault.setPerpDex(address(perp));

        perp.addMarket(
            ETH_MARKET,
            ETH_USD_FEED,
            CRYPTO_MAX_STALENESS,
            CRYPTO_MAX_LEVERAGE,
            MAINTENANCE_MARGIN,
            OI_MULTIPLIER,
            MAX_OPEN_INTEREST,
            PerpDEX.MarketType.Crypto,
            address(ethVault)
        );
        perp.addMarket(
            BTC_MARKET,
            BTC_USD_FEED,
            CRYPTO_MAX_STALENESS,
            CRYPTO_MAX_LEVERAGE,
            MAINTENANCE_MARGIN,
            OI_MULTIPLIER,
            MAX_OPEN_INTEREST,
            PerpDEX.MarketType.Crypto,
            address(btcVault)
        );
        perp.addMarket(
            SOL_MARKET,
            SOL_USD_FEED,
            CRYPTO_MAX_STALENESS,
            CRYPTO_MAX_LEVERAGE,
            MAINTENANCE_MARGIN,
            OI_MULTIPLIER,
            MAX_OPEN_INTEREST,
            PerpDEX.MarketType.Crypto,
            address(solVault)
        );

        // Set forwarder for automation tests
        perp.setForwarder(forwarder);

        vm.stopPrank();

        // 8. Deal cNGN to actors (using Foundry's deal for ERC20s)
        _dealcNGN(lpProvider, 50_000_000e6);
        _dealcNGN(lpProvider2, 10_000_000e6);
        _dealcNGN(trader1, 2_000_000e6);
        _dealcNGN(trader2, 2_000_000e6);
        _dealcNGN(trader3, 2_000_000e6);

        // 9. Seed LP liquidity
        vm.startPrank(lpProvider);
        cNGN.approve(address(ethVault), type(uint256).max);
        ethVault.deposit(10_000_000e6, lpProvider);
        cNGN.approve(address(btcVault), type(uint256).max);
        btcVault.deposit(10_000_000e6, lpProvider);
        cNGN.approve(address(solVault), type(uint256).max);
        solVault.deposit(10_000_000e6, lpProvider);
        vm.stopPrank();

        // 10. Approve PerpDEX for traders
        vm.prank(trader1);
        cNGN.approve(address(perp), type(uint256).max);
        vm.prank(trader2);
        cNGN.approve(address(perp), type(uint256).max);
        vm.prank(trader3);
        cNGN.approve(address(perp), type(uint256).max);

        // 11. Fund ETH for Pyth fees
        vm.deal(address(this), 100 ether);
        vm.deal(address(perp), 10 ether);
        vm.deal(trader1, 10 ether);
        vm.deal(trader2, 10 ether);
        vm.deal(trader3, 10 ether);
        vm.deal(liquidator, 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         HERMES FFI HELPER
    //////////////////////////////////////////////////////////////*/

    /// @notice Fetch live price updates from Hermes via FFI.
    ///         Returns encoded bytes[] for pyth.updatePriceFeeds().
    function _fetchHermesPriceUpdate(bytes32[] memory feedIds) internal returns (bytes[] memory) {
        // Build command: script/fetch_pyth_prices.sh <id1> <id2> ...
        string[] memory inputs = new string[](feedIds.length + 2);
        inputs[0] = "bash";
        inputs[1] = "script/fetch_pyth_prices.sh";
        for (uint256 i = 0; i < feedIds.length; i++) {
            inputs[i + 2] = vm.toString(feedIds[i]);
        }

        bytes memory result = vm.ffi(inputs);

        // The script returns one 0x-prefixed hex line per update blob.
        // For single-blob responses (typical), the entire output is one blob.
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = result;
        return updateData;
    }

    /// @notice Fetch and push fresh prices to the on-chain Pyth contract.
    function _refreshPythPrices(bytes32[] memory feedIds) internal {
        bytes[] memory updateData = _fetchHermesPriceUpdate(feedIds);
        uint256 fee = pyth.getUpdateFee(updateData);
        pyth.updatePriceFeeds{value: fee}(updateData);
    }

    /// @notice Convenience: refresh all 3 crypto feeds.
    ///         USD/NGN uses Chainlink -- no Pyth refresh needed.
    function _refreshCryptoPrices() internal {
        bytes32[] memory feeds = new bytes32[](3);
        feeds[0] = ETH_USD_FEED;
        feeds[1] = BTC_USD_FEED;
        feeds[2] = SOL_USD_FEED;
        _refreshPythPrices(feeds);
    }

    /// @notice Refresh ETH/USD feed only. USD/NGN uses Chainlink.
    function _refreshEthPrices() internal {
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = ETH_USD_FEED;
        _refreshPythPrices(feeds);
    }

    /// @notice Refresh BTC/USD feed only. USD/NGN uses Chainlink.
    function _refreshBtcPrices() internal {
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = BTC_USD_FEED;
        _refreshPythPrices(feeds);
    }

    /// @notice Refresh SOL/USD feed only. USD/NGN uses Chainlink.
    function _refreshSolPrices() internal {
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = SOL_USD_FEED;
        _refreshPythPrices(feeds);
    }

    /*//////////////////////////////////////////////////////////////
                         DEAL cNGN HELPER
    //////////////////////////////////////////////////////////////*/

    /// @notice Deal cNGN tokens to an address. cNGN is a proxy, so we use
    ///         Foundry's deal cheatcode which writes storage directly.
    function _dealcNGN(address to, uint256 amount) internal {
        deal(CNGN_ADDRESS, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                    COMMIT-REVEAL HELPER
    //////////////////////////////////////////////////////////////*/

    function _commitAndExecute(
        address trader,
        bytes32 marketId,
        PerpDEX.Side side,
        uint256 collateral,
        uint256 leverage
    ) internal {
        bytes32 salt = keccak256(abi.encode(trader, block.number, block.timestamp));
        // Opt out of the slippage bound (max for long, 0 for short) and use a far deadline.
        uint256 acceptablePrice = side == PerpDEX.Side.Long ? type(uint256).max : 0;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 orderHash =
            keccak256(abi.encode(trader, marketId, side, collateral, leverage, acceptablePrice, deadline, salt));

        vm.prank(trader);
        perp.requestTrade(orderHash);

        // Advance past MIN_BLOCK_DELAY
        vm.roll(block.number + 2);

        vm.prank(trader);
        perp.executeTrade(marketId, side, collateral, leverage, acceptablePrice, deadline, salt);
    }

    /*//////////////////////////////////////////////////////////////
                      LOGGING HELPERS
    //////////////////////////////////////////////////////////////*/

    function _logPrice(string memory label, uint256 price) internal pure {
        console.log(string.concat(label, ":"), price);
    }
}
