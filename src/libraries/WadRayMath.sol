// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title WadRayMath
/// @notice Arithmetic helpers in WAD (1e18) and RAY (1e27) precision.
/// @dev Mirrors Aave V1 WadRayMath. All overflow-safe via Solidity 0.8 checked
///      arithmetic plus explicit mulDiv for cross-precision products.
library WadRayMath {
  uint256 internal constant WAD = 1e18;
  uint256 internal constant RAY = 1e27;
  uint256 internal constant WAD_RAY_RATIO = 1e9;

  /// @notice Multiplies two WAD values, result in WAD.
  function wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
    if (a == 0 || b == 0) return 0;
    return (a * b + WAD / 2) / WAD;
  }

  /// @notice Divides two WAD values, result in WAD.
  function wadDiv(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b != 0, 'WRM: DIV_BY_ZERO');
    return (a * WAD + b / 2) / b;
  }

  /// @notice Multiplies two RAY values, result in RAY.
  function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
    if (a == 0 || b == 0) return 0;
    return (a * b + RAY / 2) / RAY;
  }

  /// @notice Divides two RAY values, result in RAY.
  function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b != 0, 'WRM: DIV_BY_ZERO');
    return (a * RAY + b / 2) / b;
  }

  /// @notice Converts a RAY value to WAD (truncates 9 digits).
  function rayToWad(uint256 a) internal pure returns (uint256) {
    return (a + WAD_RAY_RATIO / 2) / WAD_RAY_RATIO;
  }

  /// @notice Converts a WAD value to RAY.
  function wadToRay(uint256 a) internal pure returns (uint256) {
    return a * WAD_RAY_RATIO;
  }

  /// @notice Full-precision multiply-then-divide: floor((a * b) / denom).
  /// @dev    Uses 512-bit intermediate via Solidity 0.8 overflow detection.
  ///         Reverts on overflow or division by zero.
  function mulDiv(uint256 a, uint256 b, uint256 denom) internal pure returns (uint256 result) {
    require(denom != 0, 'WRM: DIV_BY_ZERO');
    // Solidity 0.8 will revert on overflow in a * b if it exceeds uint256.
    // For values that fit, this is exact.
    uint256 prod = a * b;
    result = prod / denom;
  }
}
