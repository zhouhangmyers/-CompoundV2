// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

abstract contract InterestRateModel {
    bool public constant isInterestRateModel = true;

    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves)
        external
        view
        virtual
        returns (uint256);

    function getSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactorMantissa
    ) external view virtual returns (uint256);
}
