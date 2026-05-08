// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILendingPoolDataProvider
/// @notice Cross-team interface for health factor and account data queries.
/// @dev All ETH values are in WAD (1e18). Health factor is in RAY (1e27).
///      Callers MUST source inputs to calculateHealthFactor from trusted pool
///      state only — passing arbitrary values will produce meaningless results.
interface ILendingPoolDataProvider {
  /// @notice Returns the full account snapshot for a user.
  /// @dev Return order matches Aave V1 spec (7 values).
  /// @param user The address to query.
  /// @return totalCollateralETH   Sum of enabled collateral in ETH (WAD).
  /// @return totalBorrowsETH      Sum of compounded debt in ETH (WAD).
  /// @return totalFeesETH         Sum of origination fees in ETH (WAD).
  /// @return availableBorrowsETH  Remaining borrow capacity in ETH (WAD), floored at 0.
  /// @return currentLiquidationThreshold  Weighted avg liquidation threshold (BPS).
  /// @return ltv                  Weighted avg loan-to-value (BPS).
  /// @return healthFactor         Health factor in RAY; type(uint256).max if no debt.
  function getUserAccountData(
    address user
  )
    external
    view
    returns (
      uint256 totalCollateralETH,
      uint256 totalBorrowsETH,
      uint256 totalFeesETH,
      uint256 availableBorrowsETH,
      uint256 currentLiquidationThreshold,
      uint256 ltv,
      uint256 healthFactor
    );

  /// @notice Returns the live health factor for a user in RAY precision.
  function getHealthFactor(address user) external view returns (uint256);

  /// @notice Pure health factor formula — inputs must come from trusted pool state.
  function calculateHealthFactor(
    uint256 totalCollateralETH,
    uint256 totalBorrowsETH,
    uint256 totalFeesETH,
    uint256 liquidationThreshold
  ) external pure returns (uint256);

  /// @notice Returns the weighted average LTV for a user's collateral (BPS).
  function getAverageLtv(address user) external view returns (uint256);

  /// @notice Returns the weighted average liquidation threshold (BPS).
  function getAverageLiquidationThreshold(address user) external view returns (uint256);

  /// @notice Returns total outstanding origination fees in ETH (WAD).
  function getTotalFeesETH(address user) external view returns (uint256);

  /// @notice Returns the compounded borrow balance for a user on a specific reserve.
  /// @dev    Delegated to pool.getUserCompoundedBorrowBalance — exposed here for
  ///         cross-team consumers (AMM borrow action, liquidation engine).
  function getCompoundedBorrowBalance(
    address user,
    address reserve
  ) external view returns (uint256);

  /// @notice Validates all preconditions for a borrow action.
  /// @dev    Implements the 6 checks from spec Deliverable 3.5.
  ///         Reverts with a descriptive error if any check fails.
  ///         Called by Team 1's LendingPool.borrow() before any state change.
  ///
  ///         Checks (in order):
  ///         1. Reserve is active and borrowing is enabled.
  ///         2. If rateMode == STABLE: stable borrowing is enabled on the reserve.
  ///         3. Requested amount <= available liquidity in the reserve.
  ///         4. User collateral is sufficient: availableBorrowsETH >= borrowAmountInETH.
  ///         5. Post-borrow health factor >= 1 ray (simulated).
  ///         6. If rateMode == STABLE: anti-manipulation check — user must not be
  ///            depositing more in this reserve than they are borrowing (whitepaper 4.3).
  ///
  /// @param user      The borrower address.
  /// @param reserve   The asset being borrowed.
  /// @param amount    The borrow amount in token-native decimals.
  /// @param rateMode  1 = stable, 2 = variable.
  function validateBorrow(
    address user,
    address reserve,
    uint256 amount,
    uint256 rateMode
  ) external view;
}
