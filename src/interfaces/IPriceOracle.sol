// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceOracle
/// @notice Price oracle interface consumed by LendingPoolDataProvider.
/// @dev Prices MUST be normalized to 1e18 precision in ETH terms (WAD).
///      A return value of 0 is treated as a stale/invalid price and will
///      cause the consuming function to revert — NOT silently skip.
///      Expected implementations: Chainlink ETH-denominated aggregator or
///      a TWAP oracle with a minimum observation window.
interface IPriceOracle {
  /// @notice Returns the price of `asset` in ETH with 18-decimal precision.
  /// @dev    MUST return 0 if the price is stale, unavailable, or invalid.
  ///         Consumers treat 0 as a hard revert condition.
  /// @param asset The ERC-20 token address to price.
  /// @return priceInETH The ETH price with WAD (1e18) precision.
  function getAssetPrice(address asset) external view returns (uint256 priceInETH);
