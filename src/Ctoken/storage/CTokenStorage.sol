// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../../Comptroller/interface/ComptrollerInterface.sol";
import "../../InterestRate/abstract/InterestRateModel.sol";

contract CTokenStorage {
    string public name;
    string public symbol;
    uint8 public decimals;

    uint256 internal constant borrowRateMaxMantissa = 0.005e16; // 0.005% per block

    uint256 internal constant reserveFactorMaxMantissa = 1e18; // 100%

    // admin functionality moved to OwnableUpgradeable

    ComptrollerInterface public comptroller;

    InterestRateModel public interestRateModel;

    uint256 internal initialExchangeRateMantissa;

    uint256 public reserveFactorMantissa;

    uint256 public accrualBlockNumber;

    uint256 public borrowIndex;

    uint256 public totalBorrows;

    uint256 public totalReserves;

    uint256 public totalSupply;

    mapping(address => uint256) internal accountTokens;

    mapping(address => mapping(address => uint256)) internal transferAllowances;

    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
    }

    mapping(address => BorrowSnapshot) internal accountBorrows;

    uint256 public constant protocolSeizeShareMantissa = 2.8e16; // 2.8%
}
