// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @dev TODO(prod): replace with liquidation team's oracle integration.
contract MockPriceOracle is IPriceOracle {
    mapping(address asset => uint256 price) internal prices;

    function setAssetPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getAssetPrice(address asset) external view override returns (uint256) {
        return prices[asset];
    }
}
