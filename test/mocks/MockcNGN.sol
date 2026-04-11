// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockcNGN
/// @notice Minimal ERC20 mock with 6 decimals, matching the production cNGN stablecoin.
/// @dev Provides an unrestricted `mint()` for test setup. Used by PerpDEXTest and
///      MarketVaultTest to supply collateral and LP funds without needing real cNGN.
contract MockcNGN is ERC20 {
    constructor() ERC20("cNGN Stablecoin", "cNGN") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint arbitrary amounts of mock cNGN to any address.
    /// @param to     Recipient address.
    /// @param amount Amount in 6-decimal units.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
