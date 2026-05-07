// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceOracle} from './IPriceOracle.sol';

/// @title IPoolLike
/// @notice Minimal read surface needed for Health Factor and borrow validation.
/// @dev TODO(prod): replace with real LendingPool/LendingPoolCore interfaces.
interface IPoolLike {
  struct ReserveConfiguration {
    // Loan to value in basis points (1e4): 7500 = 75.00%.
    uint256 ltv;
    // Liquidation threshold in basis points (1e4): 8000 = 80.00%.
    uint256 liquidationThreshold;
  }

  struct ReserveFlags {
    // Whether the reserve is active and accepting deposits/borrows.
    bool isActive;
    // Whether borrowing is enabled on this reserve.
    bool borrowingEnabled;
    // Whether stable-rate borrowing is enabled on this reserve.
    bool stableBorrowingEnabled;
  }

  function getPriceOracle() external view returns (IPriceOracle);

  function getReservesList() external view returns (address[] memory);

  /// @notice Returns whether a reserve is enabled as collateral for a user.
  function isUserUsingReserveAsCollateral(
    address user,
    address reserve
  ) external view returns (bool);

  /// @notice Returns user collateral amount for reserve in token-native decimals.
  function getUserCollateralBalance(address user, address reserve) external view returns (uint256);

  /// @notice Returns user total compounded debt for reserve in token-native decimals.
  function getUserCompoundedBorrowBalance(
    address user,
    address reserve
  ) external view returns (uint256);

  /// @notice Returns user outstanding origination fees for reserve in token-native decimals.
  function getUserOriginationFee(address user, address reserve) external view returns (uint256);

  /// @notice Returns reserve risk parameters in basis points (1e4).
  function getReserveConfiguration(
    address reserve
  ) external view returns (ReserveConfiguration memory);

  /// @notice Returns reserve underlying decimals.
  function getReserveDecimals(address reserve) external view returns (uint8);

  /// @notice Returns reserve operational flags (active, borrowing, stable borrow).
  function getReserveFlags(address reserve) external view returns (ReserveFlags memory);

  /// @notice Returns total available liquidity in the reserve in token-native decimals.
  /// @dev    availableLiquidity = totalDeposited - totalBorrowed
  function getReserveAvailableLiquidity(address reserve) external view returns (uint256);
}
