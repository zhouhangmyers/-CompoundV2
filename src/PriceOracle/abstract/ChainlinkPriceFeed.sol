// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./PriceOracle.sol";
import "../../Ctoken/abstract/CToken.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract ChainlinkPriceOracle is PriceOracle, OwnableUpgradeable {
    mapping(address => address) public priceFeeds;
    uint256 public constant PRICE_STALENESS_THRESHOLD = 3600;

    event PriceFeedUpdated(address indexed cToken, address indexed priceFeed);

    function initialize() public initializer {
        __Ownable_init(msg.sender);
    }

    function setPriceFeed(address cToken, address priceFeed) external onlyOwner {
        require(cToken != address(0), "Invalid cToken");
        require(priceFeed != address(0), "Invalid price feed");
        priceFeeds[cToken] = priceFeed;
        emit PriceFeedUpdated(cToken, priceFeed);
    }

    function getUnderlyingPrice(CToken cToken) external view override returns (uint256) {
        address priceFeed = priceFeeds[address(cToken)];
        if (priceFeed == address(0)) return 0;

        try AggregatorV3Interface(priceFeed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0 || block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) {
                return 0;
            }

            uint8 decimals = AggregatorV3Interface(priceFeed).decimals();
            if (decimals < 18) {
                return uint256(answer) * (10 ** (18 - decimals));
            } else if (decimals > 18) {
                return uint256(answer) / (10 ** (decimals - 18));
            }
            return uint256(answer);
        } catch {
            return 0;
        }
    }
}
