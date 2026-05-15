// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IReserveInterestRateStrategy {
    /**
     * @notice Calculates and stores updated interest rates for a reserve.
     * @dev    Callable only by LendingPoolCore.
     * @param  totalLiquidity      Lt — total deposits in underlying units
     * @param  totalVariableBorrows Bv — total variable borrows in underlying units
     * @param  totalStableBorrows   Bs — total stable borrows in underlying units
     * @param  averageStableBorrowRate Rsa — weighted average stable rate in RAY
     * @return liquidityRate        Rl in RAY
     * @return stableBorrowRate     Rs in RAY
     * @return variableBorrowRate   Rv in RAY
     */
    function updateInterestRates(
        uint256 totalLiquidity,
        uint256 totalVariableBorrows,
        uint256 totalStableBorrows,
        uint256 averageStableBorrowRate
    ) external returns (uint256 liquidityRate, uint256 stableBorrowRate, uint256 variableBorrowRate);
}
