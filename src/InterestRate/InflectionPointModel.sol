// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./abstract/InterestRateModel.sol";

contract InflectionPointModel is InterestRateModel {
    event NewInterestParams(
        uint256 baseRatePerBlock, uint256 multiplierPerBlock, uint256 jumpMultiplierPerBlock, uint256 kink
    );

    uint256 private constant BASE = 1e18;

    uint256 public constant blocksPerYear = 2102400; // ETH block per year (assuming 15s blocks)

    uint256 public multiplierPerBlock;
    uint256 public baseRatePerBlock;
    uint256 public jumpMultiplierPerBlock;
    uint256 public kink;

    constructor(uint256 baseRatePerYear, uint256 multiplierPerYear, uint256 jumpMultiplierPerYear, uint256 _kink) {
        baseRatePerBlock = baseRatePerYear / blocksPerYear;
        multiplierPerBlock = multiplierPerYear / blocksPerYear;
        jumpMultiplierPerBlock = jumpMultiplierPerYear / blocksPerYear;
        kink = _kink;

        emit NewInterestParams(baseRatePerBlock, multiplierPerBlock, jumpMultiplierPerBlock, kink);
    }

    function utilizationRate(uint256 cash, uint256 borrows, uint256 reserves) public pure returns (uint256) {
        if (borrows == 0) {
            return 0;
        }

        return (borrows * BASE) / (cash + borrows - reserves);
    }

    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) public view override returns (uint256) {
        uint256 ur = utilizationRate(cash, borrows, reserves);
        if (ur <= kink) {
            return (ur * multiplierPerBlock) / BASE + baseRatePerBlock;
        } else {
            uint256 normalRate = (kink * multiplierPerBlock) / BASE + baseRatePerBlock;
            uint256 excessUtil = ur - kink;
            return (excessUtil * jumpMultiplierPerBlock) / BASE + normalRate;
        }
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
