// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Ctoken/abstract/CToken.sol";
import "../Cerc20/interface/CErc20Interface.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface CompLike {
    function delegate(address delegatee) external;
}

contract CErc20 is CToken, CErc20Interface, UUPSUpgradeable {
    function initialize(
        address _underlying,
        ComptrollerInterface _comptroller,
        InterestRateModel _interestRateModel,
        uint256 _initialExchangeRateMantissa,
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) public initializer {
        __UUPSUpgradeable_init();
        super.initialize(_comptroller, _interestRateModel, _initialExchangeRateMantissa, _name, _symbol, _decimals);

        underlying = _underlying;

        //防御性机制
        IERC20(underlying).totalSupply();
    }

    function mint(uint256 mintAmount) external override returns (bool) {
        mintInternal(mintAmount);
        return true;
    }

    function redeem(uint256 redeemTokens) external override returns (bool) {
        redeemInternal(redeemTokens);
        return true;
    }

    function redeemUnderlying(uint256 redeemAmount) external override returns (bool) {
        redeemUnderlyingInternal(redeemAmount);
        return true;
    }

    function borrow(uint256 borrowAmount) external override returns (bool) {
        borrowInternal(borrowAmount);
        return true;
    }

    function repayBorrow(uint256 repayAmount) external override returns (bool) {
        repayBorrowInternal(repayAmount);
        return true;
    }

    function repayBorrowBehalf(address borrower, uint256 repayAmount) external override returns (bool) {
        repayBorrowBehalfInternal(borrower, repayAmount);
        return true;
    }

    function liquidateBorrow(address borrower, uint256 repayAmount, CTokenInterface cTokenCollateral)
        external
        override
        returns (bool)
    {
        liquidateBorrowInternal(borrower, repayAmount, cTokenCollateral);
        return true;
    }

    function sweepToken(IERC20 token) external override onlyOwner {
        require(address(token) != underlying, "CErc20::sweepToken: can not sweep underlying token");
        uint256 balance = token.balanceOf(address(this));
        SafeERC20.safeTransfer(token, owner(), balance);
    }

    function _addReserves(uint256 addAmount) external override {
        _addReservesInternal(addAmount);
    }

    function getCashPrior() internal view virtual override returns (uint256) {
        IERC20 token = IERC20(underlying);
        return token.balanceOf(address(this));
    }

    function doTransferIn(address from, uint256 amount) internal virtual override returns (uint256) {
        // Read from storage once
        address underlying_ = underlying;
        IERC20 token = IERC20(underlying_);
        uint256 balanceBefore = IERC20(underlying_).balanceOf(address(this));
        // token.transferFrom(from, address(this), amount);

        // bool success;
        // assembly {
        //     switch returndatasize()
        //     case 0 {
        //         // This is a non-standard ERC-20
        //         success := not(0) // set success to true
        //     }
        //     case 32 {
        //         // This is a compliant ERC-20
        //         returndatacopy(0, 0, 32)
        //         success := mload(0) // Set `success = returndata` of override external call
        //     }
        //     default {
        //         // This is an excessively non-compliant ERC-20, revert.
        //         revert(0, 0)
        //     }
        // }
        // require(success, "TOKEN_TRANSFER_IN_FAILED");

        // Calculate the amount that was *actually* transferred
        SafeERC20.safeTransferFrom(token, from, address(this), amount);
        uint256 balanceAfter = IERC20(underlying_).balanceOf(address(this));
        return balanceAfter - balanceBefore; // underflow already checked above, just subtract
    }

    function doTransferOut(address payable to, uint256 amount) internal virtual override {
        IERC20 token = IERC20(underlying);
        // token.transfer(to, amount);

        // bool success;
        // assembly {
        //     switch returndatasize()
        //     case 0 {
        //         // This is a non-standard ERC-20
        //         success := not(0) // set success to true
        //     }
        //     case 32 {
        //         // This is a compliant ERC-20
        //         returndatacopy(0, 0, 32)
        //         success := mload(0) // Set `success = returndata` of override external call
        //     }
        //     default {
        //         // This is an excessively non-compliant ERC-20, revert.
        //         revert(0, 0)
        //     }
        // }
        // require(success, "TOKEN_TRANSFER_OUT_FAILED");
        SafeERC20.safeTransfer(token, to, amount);
    }

    /**
     * @notice Admin call to delegate the votes of the COMP-like underlying
     * @param compLikeDelegatee The address to delegate votes to
     * @dev CTokens whose underlying are not CompLike should revert here
     */
    function _delegateCompLikeTo(address compLikeDelegatee) external {
        require(msg.sender == owner(), "only the admin may set the comp-like delegate");
        CompLike(underlying).delegate(compLikeDelegatee);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
