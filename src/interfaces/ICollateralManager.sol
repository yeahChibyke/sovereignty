// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface ICollateralManager {
    struct Deposit {
        address user;
        uint256 amount;
        uint256 lastUpdatedAt;
    }

    event DepositCreated(address indexed user, uint256 amount, uint256 depositedAt);
    event UpdatedUserDeposit(address indexed user, uint256 amount, uint256 updatedAt);

    /**
     * @return -
     */
    function totalDeposits() external returns (uint256);

    /**
     *
     * @param user -
     * @return -
     * @return -
     * @return -
     */
    function getUserDeposit(address user) external view returns (address, uint256, uint256);

    /**
     *
     * @param user -
     * @param amount -
     * @param isIncreasing -
     */
    function updateUserDeposit(address user, uint256 amount, bool isIncreasing) external;

    /**
     *
     * @param amount -
     */
    function deposit(uint256 amount) external;

    /**
     *
     * @param amount -
     */
    function withdraw(uint256 amount) external;

    /**
     *
     * @param recipient -
     * @param amount -
     */
    function withdrawLosses(address recipient, uint256 amount) external;
}
