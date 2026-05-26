// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPriceOracle
 * @notice Price feed interface consumed by LiquidationManager and LendingPoolDataProvider.
 *
 * All prices are denominated in ETH with WAD precision (1e18).
 * e.g. if 1 DAI = 0.0004 ETH, getAssetPrice(DAI) returns 4e14.
 *
 * Expected implementation: Chainlink aggregator or on-chain TWAP.
 * The oracle address is stored in LendingPoolCore and updatable only by governance.
 */
interface IPriceOracle {
    /**
     * @notice Returns the ETH-denominated price of `asset` in WAD precision.
     * @param  asset  ERC-20 token address (use WETH address for native ETH)
     * @return priceInETH  Price of 1 whole token unit in ETH (18 decimals)
     *
     * @dev Returns 0 if the price is unavailable or stale.
     *      Callers MUST revert if this returns 0.
     */
    function getAssetPrice(address asset) external view returns (uint256 priceInETH);
}
