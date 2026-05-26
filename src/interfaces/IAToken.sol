// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAToken
 * @notice Interface for the aToken receipt token.
 *         Used by LiquidationManager to move collateral aTokens.
 *
 * Full implementation is owned by Team 4 (Token team).
 * Only the functions consumed by the liquidation flow are declared here.
 */
interface IAToken {
    /**
     * @notice Returns the current compounded balance of `user`.
     * @dev    Grows continuously with interest — NOT equal to the stored principal.
     */
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Transfers collateral aTokens from `from` (borrower) to `to` (liquidator).
     * @dev    Called by LendingPool during liquidationCall().
     *         Must update both parties' principal balance, index snapshot, and
     *         any interest redirection state.
     *         Only callable by LendingPool.
     * @param from    The borrower being liquidated
     * @param to      The liquidator receiving the discounted collateral
     * @param value   Amount of aTokens to transfer
     */
    function transferOnLiquidation(address from, address to, uint256 value) external;

    /**
     * @notice Mints aTokens to `user` on deposit.
     * @dev    Only callable by LendingPool.
     * @param user    Recipient
     * @param amount  Amount to mint (1:1 with underlying)
     * @param index   Current reserve normalized income (used to snapshot user's index)
     */
    function mint(address user, uint256 amount, uint256 index) external;

    /**
     * @notice Burns aTokens from `user` on redeem/liquidation.
     * @dev    Only callable by LendingPool.
     * @param user                 Token holder
     * @param receiverOfUnderlying Address receiving the underlying asset
     * @param amount               Amount to burn
     * @param index                Current reserve normalized income
     */
    function burn(address user, address receiverOfUnderlying, uint256 amount, uint256 index) external;
}
