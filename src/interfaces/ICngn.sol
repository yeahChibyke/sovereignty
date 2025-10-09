    // SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface ICngn {
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
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
