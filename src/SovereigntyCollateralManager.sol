// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {ICollateralManager} from "./interfaces/ICollateralManager.sol";

contract SovereigntyCollateralManager is Ownable, ICollateralManager {
    using SafeERC20 for IERC20;

    address collateralToken;
    IPositionManager positionManager;
    mapping(address depositor => Deposit) private userDeposits;
    uint256 public totalDeposits;

    uint256 public constant MIN_DEPOSIT = 100_000e5; // 100_000 cngn

    constructor(address _cngn, address _positionManager) Ownable(msg.sender) {
        collateralToken = _cngn;
        positionManager = IPositionManager(_positionManager);
    }

    modifier validDeposit(uint256 _amount) {
        if (_amount < MIN_DEPOSIT) {
            revert CollateralManager__InvalidDeposit();
        }
        _;
    }

    modifier canWithdraw(address _trader, uint256 _amount) {
        if (positionManager.hasOpenPosition(_trader) != true) {
            revert CollateralManager__PositionStillOpen();
        } else if (userDeposits[msg.sender].amount < _amount) {
            revert CollateralManager__LowBalance();
        }
        _;
    }

    function deposit(uint256 _amount) external validDeposit(_amount) {
        totalDeposits += _amount;

        Deposit storage userDeposit = userDeposits[msg.sender];
        userDeposit.user = msg.sender;
        userDeposit.amount += _amount;
        userDeposit.lastUpdatedAt = block.timestamp;

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), _amount);

        emit DepositCreated(msg.sender, _amount, block.timestamp);
    }

    function withdraw(uint256 _amount) external canWithdraw(msg.sender, _amount) {
        Deposit storage userDeposit = userDeposits[msg.sender];
        totalDeposits -= _amount;
        userDeposit.amount -= _amount;
        userDeposit.lastUpdatedAt = block.timestamp;

        IERC20(collateralToken).safeTransfer(msg.sender, _amount);

        emit FundsWithdrawn(msg.sender, _amount, block.timestamp);
    }

    function withdrawLosses(address _to, uint256 _amount) external onlyOwner {
        IERC20(collateralToken).safeTransfer(_to, _amount);

        emit LossesWithdrawn(_to, _amount, block.timestamp);
    }

    function getUserDeposit(address user) external view returns (address, uint256, uint256) {
        Deposit memory userDeposit = userDeposits[user];
        return (userDeposit.user, userDeposit.amount, userDeposit.lastUpdatedAt);
    }

    function updateUserDeposit(address user, uint256 amount, bool isIncreasing) public onlyOwner {
        Deposit storage userDeposit = userDeposits[user];
        if (isIncreasing) {
            totalDeposits += amount;
            userDeposit.amount += amount;
        } else {
            totalDeposits -= amount;
            userDeposit.amount -= amount;
        }
        userDeposit.lastUpdatedAt = block.timestamp;
        emit UpdatedUserDeposit(user, amount, block.timestamp);
    }
}
