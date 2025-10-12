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
        alice = makeAddr("alice");

        cngn = new MockCngn(6);
        SLP = new SovereigntyLiquidityProvider(address(cngn), admin);
    }
}
