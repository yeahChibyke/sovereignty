// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICngn is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool);
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool);
    function mint(uint256 _amount, address _mintTo) external returns (bool);
    function burnByUser(uint256 _amount) external returns (bool);
    function pause() external returns (bool);
    function unPause() external returns (bool);
    function isTrustedForwarder(address forwarder) external view returns (bool);
    function updateAdminOperationsAddress(address _newAdmin) external returns (bool);
    function updateForwarderContract(address _newForwarderContract) external returns (bool);
}
