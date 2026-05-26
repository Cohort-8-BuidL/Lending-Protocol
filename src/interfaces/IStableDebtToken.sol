// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStableDebtToken
 * @notice Interface for the stable-rate debt token.
 *         Implemented by Team 4 (Token team).
 *
 * Each reserve has one StableDebtToken tracking per-user principal and locked rate.
 * Only LendingPool may mint or burn.
 */
interface IStableDebtToken {
    /**
     * @notice Returns the current compounded balance (principal + accrued interest).
     */
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Returns the stored principal — the amount borrowed before any interest.
     */
    function principalBalanceOf(address user) external view returns (uint256);

    /**
     * @notice Returns the stable rate locked at the time of the user's last borrow.
     */
    function getUserStableRate(address user) external view returns (uint256);

    /**
     * @notice Burns `amount` of debt from `user`.
     * @dev    Called by LendingPool on repay and liquidation.
     *         Only callable by LendingPool.
     * @param user    Borrower whose debt is being reduced
     * @param amount  Amount of underlying debt to burn (in token units)
     */
    function burn(address user, uint256 amount) external;
}
