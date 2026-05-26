// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILendingPoolDataProvider
 * @notice Interface for the health factor and collateral computation layer.
 *         Implemented by Team 3 (Health Factor team).
 *
 * LiquidationManager calls getHealthFactor() to check liquidation eligibility
 * and getCompoundedBorrowBalance() to calculate the actual debt to repay.
 */
interface ILendingPoolDataProvider {
    /**
     * @notice Returns the health factor of `user` in RAY precision.
     * @dev    Hf = (totalCollateralETH × avgLiquidationThreshold) / (totalBorrowsETH + totalFeesETH)
     *         Returns type(uint256).max if the user has no debt.
     *         Hf < 1e27 (1 RAY) means the position is eligible for liquidation.
     */
    function getHealthFactor(address user) external view returns (uint256);

    /**
     * @notice Returns the full account snapshot for `user`.
     * @return totalCollateralETH          Sum of all collateral in ETH (WAD)
     * @return totalBorrowsETH             Sum of all borrows incl. accrued interest in ETH (WAD)
     * @return totalFeesETH                Sum of outstanding origination fees in ETH (WAD)
     * @return availableBorrowsETH         Remaining borrowing capacity in ETH (WAD)
     * @return currentLiquidationThreshold Weighted average liquidation threshold (basis points)
     * @return ltv                         Weighted average loan-to-value (basis points)
     * @return healthFactor                Hf in RAY — type(uint256).max if no debt
     */
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralETH,
        uint256 totalBorrowsETH,
        uint256 totalFeesETH,
        uint256 availableBorrowsETH,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );

    /**
     * @notice Returns the compounded borrow balance of `user` for `reserve`.
     * @dev    For variable: Bxc = (currentVariableBorrowIndex / userIndexSnapshot) × principal
     *         For stable:   Bxc = (1 + Rs/Tyear)^ΔT × principal
     *         Returns 0 if the user has no borrow in that reserve.
     */
    function getCompoundedBorrowBalance(address user, address reserve) external view returns (uint256);

    /**
     * @notice Returns whether `user` has enabled `reserve` as collateral.
     */
    function isUserUsingReserveAsCollateral(address user, address reserve) external view returns (bool);

    /**
     * @notice Returns the weighted-average liquidation threshold across all of `user`'s
     *         collateral positions.
     * @dev    Formula: LQᵃ = Σ(collateralValueETH_i × LQ_i) / Σ(collateralValueETH_i)
     *         Used by LiquidationManager to validate eligibility and by Health Factor
     *         (Team 3) for Hf computation.
     *         AC 40 — single collateral → exact LQ of that reserve
     *         AC 41 — multi-collateral  → correct weighted average
     *         AC 42 — zero collateral   → returns 0
     * @return avgThreshold  In basis points (e.g. 8000 = 80%)
     */
    function getAverageLiquidationThreshold(address user) external view returns (uint256 avgThreshold);
}
