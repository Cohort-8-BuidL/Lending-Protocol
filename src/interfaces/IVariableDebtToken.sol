// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVariableDebtToken
 * @notice Interface for the variable-rate debt token.
 *         Implemented by Team 4 (Token team).
 *
 * Variable debt tokens store a *scaled* balance: scaledBalance = principal / borrowIndexAtMint.
 * The compounded balance at any time is: scaledBalance × currentVariableBorrowIndex.
 * Only LendingPool may mint or burn.
 */
interface IVariableDebtToken {
    /**
     * @notice Returns the current compounded balance (scaledBalance × currentIndex).
     */
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Returns the unscaled principal — the amount borrowed before any compounding.
     * @dev    Computed as scaledBalance × borrowIndexAtTimeOfLastMint.
     */
    function principalBalanceOf(address user) external view returns (uint256);

    /**
     * @notice Burns `amount` of debt from `user` using `index` to scale correctly.
     * @dev    Called by LendingPool on repay and liquidation.
     *         Only callable by LendingPool.
     * @param user    Borrower whose debt is being reduced
     * @param amount  Amount of underlying debt to burn (in token units, NOT scaled)
     * @param index   Current reserve variable borrow index (from LendingPoolCore)
     */
    function burn(address user, uint256 amount, uint256 index) external;
}
