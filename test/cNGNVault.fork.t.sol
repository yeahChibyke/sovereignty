// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {cNGNVault} from "../src/cNGNVault.sol";
import {MockPerpDEX} from "./mocks/MockPerpDEX.sol";

/// @title cNGNVault Fork Test
/// @notice Tests the vault against the real cNGN token on a Base mainnet fork.
contract cNGNVaultForkTest is Test {
    /*//////////////////////////////////////////////////////////////
                         BASE MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    address constant CNGN = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F;

    /*//////////////////////////////////////////////////////////////
                              STATE
    //////////////////////////////////////////////////////////////*/

    IERC20 public cNGN;
    cNGNVault public vault;
    MockPerpDEX public perpDexMock;

    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address perpDex;
    address trader = makeAddr("trader");

    uint256 constant ONE_CNGN = 1e6; // 6 decimals

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Fork Base mainnet
        string memory rpcUrl =
            vm.envOr("BASE_RPC_URL", string("https://base-mainnet.g.alchemy.com/v2/Ca9M-U7msUU-au5jYSolQfd_eQ3xQlaB"));
        vm.createSelectFork(rpcUrl);

        cNGN = IERC20(CNGN);

        // Deploy the vault against the real cNGN token
        vault = new cNGNVault(cNGN);
        perpDexMock = new MockPerpDEX();
        perpDex = address(perpDexMock);

        // Deal cNGN to LPs using foundry cheatcodes
        deal(CNGN, lp1, 5_000_000 * ONE_CNGN);
        deal(CNGN, lp2, 5_000_000 * ONE_CNGN);
        deal(CNGN, trader, 1_000_000 * ONE_CNGN);

        // Approve vault
        vm.prank(lp1);
        cNGN.approve(address(vault), type(uint256).max);
        vm.prank(lp2);
        cNGN.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                 SECTION 1: REAL TOKEN BASIC CHECKS
    //////////////////////////////////////////////////////////////*/

    function test_fork_cNGN_decimals() public view {
        // Confirm real cNGN has 6 decimals
        (bool ok, bytes memory data) = CNGN.staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(ok);
        uint8 decimals = abi.decode(data, (uint8));
        assertEq(decimals, 6);
    }

    function test_fork_cNGN_totalSupply_positive() public view {
        uint256 supply = cNGN.totalSupply();
        assertGt(supply, 0, "cNGN should have nonzero supply on Base");
    }

    function test_fork_vault_asset() public view {
        assertEq(vault.asset(), CNGN);
    }

    /*//////////////////////////////////////////////////////////////
             SECTION 2: DEPOSIT & WITHDRAW WITH REAL TOKEN
    //////////////////////////////////////////////////////////////*/

    function test_fork_deposit() public {
        uint256 amount = 1_000_000 * ONE_CNGN;

        vm.prank(lp1);
        uint256 shares = vault.deposit(amount, lp1);

        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.balanceOf(lp1), shares);
        assertEq(cNGN.balanceOf(address(vault)), amount);
        assertEq(vault.totalAssets(), amount);
    }

    function test_fork_deposit_multipleUsers() public {
        uint256 amount1 = 1_000_000 * ONE_CNGN;
        uint256 amount2 = 2_000_000 * ONE_CNGN;

        vm.prank(lp1);
        vault.deposit(amount1, lp1);

        vm.prank(lp2);
        vault.deposit(amount2, lp2);

        assertEq(cNGN.balanceOf(address(vault)), amount1 + amount2);
        assertEq(vault.totalAssets(), amount1 + amount2);
        // LP2 deposited more → should have more shares
        assertGt(vault.balanceOf(lp2), vault.balanceOf(lp1));
    }

    function test_fork_withdraw_full() public {
        uint256 amount = 500_000 * ONE_CNGN;
        uint256 balBefore = cNGN.balanceOf(lp1);

        vm.prank(lp1);
        vault.deposit(amount, lp1);

        vm.prank(lp1);
        vault.withdraw(amount, lp1, lp1);

        assertEq(cNGN.balanceOf(lp1), balBefore);
        assertEq(vault.balanceOf(lp1), 0);
    }

    function test_fork_redeem_all() public {
        uint256 amount = 500_000 * ONE_CNGN;

        vm.prank(lp1);
        uint256 shares = vault.deposit(amount, lp1);

        vm.prank(lp1);
        uint256 assets = vault.redeem(shares, lp1, lp1);

        assertEq(assets, amount);
        assertEq(vault.balanceOf(lp1), 0);
    }

    function test_fork_partialWithdraw() public {
        uint256 amount = 1_000_000 * ONE_CNGN;

        vm.prank(lp1);
        vault.deposit(amount, lp1);

        vm.prank(lp1);
        vault.withdraw(amount / 2, lp1, lp1);

        assertApproxEqAbs(vault.totalAssets(), amount / 2, 1);
        assertGt(vault.balanceOf(lp1), 0);
    }

    /*//////////////////////////////////////////////////////////////
          SECTION 3: PERPDEX LINK & PNL SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function test_fork_setPerpDex() public {
        vault.setPerpDex(perpDex);
        assertEq(vault.perpDex(), perpDex);
    }

    function test_fork_setPerpDex_revertsDouble() public {
        vault.setPerpDex(perpDex);
        vm.expectRevert(cNGNVault.PerpDexAlreadySet.selector);
        vault.setPerpDex(makeAddr("other"));
    }

    function test_fork_settlePnL_traderLoss() public {
        uint256 deposit = 2_000_000 * ONE_CNGN;
        vm.prank(lp1);
        vault.deposit(deposit, lp1);

        vault.setPerpDex(perpDex);

        // Simulate: traders have 100k unrealized loss
        perpDexMock.setGlobalUnrealizedPnL(-int256(100_000 * ONE_CNGN));

        // totalAssets should increase because trader loss benefits LPs
        assertEq(vault.totalAssets(), deposit + 100_000 * ONE_CNGN);
    }

    function test_fork_settlePnL_traderProfit() public {
        uint256 deposit = 2_000_000 * ONE_CNGN;
        vm.prank(lp1);
        vault.deposit(deposit, lp1);

        vault.setPerpDex(perpDex);

        // Simulate: traders have 50k unrealized profit
        perpDexMock.setGlobalUnrealizedPnL(int256(50_000 * ONE_CNGN));

        assertEq(vault.totalAssets(), deposit - 50_000 * ONE_CNGN);
    }

    function test_fork_payTrader() public {
        uint256 deposit = 2_000_000 * ONE_CNGN;
        vm.prank(lp1);
        vault.deposit(deposit, lp1);

        vault.setPerpDex(perpDex);

        uint256 payout = 100_000 * ONE_CNGN;
        vm.prank(perpDex);
        vault.payTrader(trader, payout);

        assertEq(cNGN.balanceOf(trader), 1_000_000 * ONE_CNGN + payout);
    }

    function test_fork_payTrader_onlyPerpDex() public {
        vault.setPerpDex(perpDex);

        vm.expectRevert(cNGNVault.OnlyPerpDex.selector);
        vm.prank(lp1);
        vault.payTrader(trader, 100);
    }

    /*//////////////////////////////////////////////////////////////
       SECTION 4: SHARE PRICE DYNAMICS UNDER PNL
    //////////////////////////////////////////////////////////////*/

    function test_fork_sharePrice_decreasesOnTraderProfit() public {
        vault.setPerpDex(perpDex);

        uint256 deposit = 2_000_000 * ONE_CNGN;
        vm.prank(lp1);
        vault.deposit(deposit, lp1);

        uint256 shares = vault.balanceOf(lp1);
        uint256 previewBefore = vault.previewRedeem(shares);

        // Simulate trader unrealized profit
        perpDexMock.setGlobalUnrealizedPnL(int256(200_000 * ONE_CNGN));

        uint256 previewAfter = vault.previewRedeem(shares);
        assertLt(previewAfter, previewBefore, "Share value should drop when traders profit");
    }

    function test_fork_sharePrice_increasesOnTraderLoss() public {
        vault.setPerpDex(perpDex);

        uint256 deposit = 2_000_000 * ONE_CNGN;
        vm.prank(lp1);
        vault.deposit(deposit, lp1);

        uint256 shares = vault.balanceOf(lp1);
        uint256 previewBefore = vault.previewRedeem(shares);

        // Simulate trader unrealized loss
        perpDexMock.setGlobalUnrealizedPnL(-int256(200_000 * ONE_CNGN));

        uint256 previewAfter = vault.previewRedeem(shares);
        assertGt(previewAfter, previewBefore, "Share value should rise when traders lose");
    }

    function test_fork_lp2_depositsAfterPnL_getsFewerShares() public {
        vault.setPerpDex(perpDex);

        uint256 deposit = 2_000_000 * ONE_CNGN;

        // LP1 deposits first
        vm.prank(lp1);
        vault.deposit(deposit, lp1);
        uint256 sharesLp1 = vault.balanceOf(lp1);

        // Trader loses → vault gains → share price goes up
        perpDexMock.setGlobalUnrealizedPnL(-int256(500_000 * ONE_CNGN));

        // LP2 deposits the same amount but share price is now higher
        vm.prank(lp2);
        uint256 sharesLp2 = vault.deposit(deposit, lp2);

        assertLt(sharesLp2, sharesLp1, "LP2 should get fewer shares at higher price");
    }
}
