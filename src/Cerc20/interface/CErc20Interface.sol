// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../storage/CErc20Storage.sol";
import "../../Ctoken/interface/CTokenInterface.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract CErc20Interface is CErc20Storage {
    /**
     * User Interface
     */
    function mint(uint256 mintAmount) external virtual returns (bool);

    function redeem(uint256 redeemTokens) external virtual returns (bool);

    function redeemUnderlying(uint256 redeemUnderlying) external virtual returns (bool);

    function borrow(uint256 borrowAmount) external virtual returns (bool);

    function repayBorrow(uint256 repayAmount) external virtual returns (bool);

    function repayBorrowBehalf(address borrower, uint256 repayAmount)
        external
        virtual
        returns (bool);

    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        CTokenInterface cTokenCollateral
    ) external virtual returns (bool);

    function sweepToken(IERC20 token) external virtual; //use SafeERC20

    /**
     * Admin Functions
     */
    function _addReserves(uint256 addAmount) external virtual;
}
