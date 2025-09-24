// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./abstract/InterestRateModel.sol";

contract LinearModel is InterestRateModel {
    event NewInterestParams(uint256 baseRatePerBlock, uint256 multiplierPerBlock);

    uint256 private constant BASE = 1e18;

    // ETH block per year (assuming 15s blocks)
    uint256 public blocksPerYear = 2102400;

    uint256 public multiplierPerBlock;
    uint256 public baseRatePerBlock;

    constructor(uint256 baseRatePerYear, uint256 multiplierPerYear) {
        // baseRatePerBlock unit: 1e18
        baseRatePerBlock = baseRatePerYear / blocksPerYear;
        multiplierPerBlock = multiplierPerYear / blocksPerYear;

        emit NewInterestParams(baseRatePerBlock, multiplierPerBlock);
    }

    function utilizationRate(uint256 cash, uint256 borrows, uint256 reserves) public pure returns (uint256) {
        if (borrows == 0) {
            return 0;
        }

        return (borrows * BASE) / (cash + borrows - reserves);
    }

    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) public view override returns (uint256) {
        uint256 ur = utilizationRate(cash, borrows, reserves);
        return (ur * multiplierPerBlock) / BASE + baseRatePerBlock;
    }

    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint256 reserveFactorMantissa)
        external
        view
        override
        returns (uint256)
    {
        uint256 oneMinusReserveFactor = BASE - reserveFactorMantissa;
        uint256 borrowRate = getBorrowRate(cash, borrows, reserves);
        uint256 rateToPool = (borrowRate * oneMinusReserveFactor) / BASE;
        return (utilizationRate(cash, borrows, reserves) * rateToPool) / BASE;
    }
}
