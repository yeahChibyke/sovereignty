// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {SovereigntyLiquidityProvider} from "../src/SovereigntyLiquidityProvider.sol";
import {MockCngn} from "./mock/MockCngn.sol";

contract TestSLP is Test {
    SovereigntyLiquidityProvider SLP;
    MockCngn cngn;

    address admin;
    address alice;

    uint256 LP_AMOUNT = 1_000_000e6;

    function setUp() public {
        admin = makeAddr("admin");
        alice = makeAddr("first LP");

        cngn = new MockCngn(6);
        SLP = new SovereigntyLiquidityProvider(address(cngn), admin);

        cngn.mint(alice, LP_AMOUNT);
    }

    function testDeposit() public {
        vm.startPrank(alice);
        cngn.approve(address(SLP), LP_AMOUNT);
        SLP.deposit(LP_AMOUNT, alice);
        vm.stopPrank();

        assert(cngn.balanceOf(alice) == 0);
        assert(cngn.balanceOf(address(SLP)) == LP_AMOUNT);
    }
}
