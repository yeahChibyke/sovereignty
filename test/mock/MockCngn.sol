// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockCngn is ERC20 {
    uint8 dec;

    constructor(uint8 _dec) ERC20("Mock Cngn", "mcngn") {
        dec = _dec;
    }

    function mint(address _to, uint256 _amount) public {
        _mint(_to, _amount);
    }

    function decimals() public view override returns (uint8) {
        return dec;
    }
}
