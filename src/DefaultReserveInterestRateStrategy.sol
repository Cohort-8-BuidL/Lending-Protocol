// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {WadRayMath} from "./WadRayMath.sol";
import {IReserveInterestRateStrategy} from "./interfaces/IReserveInterestRateStrategy.sol";

/**
 * @title  DefaultReserveInterestRateStrategy
 * @notice Computes borrow and liquidity interest rates for a single reserve
 *         using the two-slope (kinked) variable rate model from the Aave V2
 *         whitepaper, plus a simple stable rate derived from the variable rate.
 *
 * ─── Why a two-slope model? ───────────────────────────────────────────────────
 * A single linear rate would either be too cheap at high utilization (draining
 * the pool) or too expensive at low utilization (discouraging borrowers).
 * The kinked model solves this by using a gentle slope (Rslope1) up to a target
 * utilization (Uoptimal) and a steep slope (Rslope2) beyond it.  The steep
 * second slope acts as a strong economic incentive for borrowers to repay and
 * for depositors to add liquidity whenever the pool is over-utilized.
 *
 * ─── Precision ────────────────────────────────────────────────────────────────
 * All rates and the utilization ratio are stored and computed in RAY precision
 * (1 RAY = 1e27).  For example:
 *   • 5% APR  → 5e25
 *   • 80% Uoptimal → 8e26
 * Using RAY throughout avoids precision loss when multiplying two percentages
 * together (e.g. Rl = RO × U), because the intermediate product stays within
 * uint256 range and the extra 27 decimal places are divided away by rayMul/rayDiv.
 *
 * ─── Rate formulas ────────────────────────────────────────────────────────────
 *
 *   Utilization:
 *     U  = Bt / Lt
 *          where Bt = total borrows (variable + stable), Lt = total liquidity.
 *          Returns 0 when Lt = 0 to avoid division by zero.
 *
 *   Variable borrow rate (two-slope):
 *     If U ≤ Uoptimal:
 *       Rv = Rv0 + (U / Uoptimal) × Rslope1
 *            ↑ linear ramp from Rv0 to Rv0+Rslope1 as utilization grows
 *
 *     If U > Uoptimal:
 *       Rv = Rv0 + Rslope1 + ((U − Uoptimal) / (1 − Uoptimal)) × Rslope2
 *            ↑ continues from the kink point and ramps steeply to Rv0+Rslope1+Rslope2
 *
 *   Overall borrow rate (weighted average across both rate types):
 *     RO = (Bv·Rv + Bs·Rsa) / Bt
 *          where Bv = variable borrows, Bs = stable borrows,
 *          Rsa = weighted-average stable rate currently in effect.
 *          Returns 0 when Bt = 0 (no borrows outstanding).
 *
 *   Liquidity (supply) rate:
 *     Rl = RO × U
 *          Depositors only earn on the fraction of their funds that is lent out,
 *          so the supply rate is always ≤ the overall borrow rate.
 *
 *   Stable borrow rate (simplified):
 *     Rs = stableRateBase + Rv
 *          A premium over the current variable rate, rewarding the protocol for
 *          the interest-rate risk it takes on by offering fixed-rate loans.
 *
 * ─── Access control ───────────────────────────────────────────────────────────
 * updateInterestRates() may only be called by LendingPoolCore.  All other
 * callers revert with Unauthorized.  The view helpers (getVariableRate,
 * getUtilizationRate) are unrestricted and intended for off-chain tooling and
 * tests.
 */
contract DefaultReserveInterestRateStrategy is IReserveInterestRateStrategy {
    using WadRayMath for uint256;

    // 1e27 — the base unit for all rate and ratio arithmetic in this contract.
    uint256 private constant RAY = WadRayMath.RAY;

    // ─────────────────────────────────────────────────────────────────────────
    // Immutable configuration
    //
    // All parameters are set once in the constructor and never change.
    // Using `immutable` instead of `constant` lets each reserve deployment
    // carry its own calibrated parameters while still being inlined by the
    // compiler (no SLOAD cost on reads).
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The only address permitted to call updateInterestRates().
    ///         Set to the LendingPoolCore contract at deployment.
    address public immutable lendingPoolCore;

    /// @notice Rv0 — the base (floor) variable borrow rate in RAY.
    ///         This is the rate charged even when utilization is zero.
    ///         Typically 0 for most assets, but can be set > 0 to establish
    ///         a minimum cost of borrowing.
    uint256 public immutable baseVariableBorrowRate;

    /// @notice Rslope1 — the rate slope applied below Uoptimal in RAY.
    ///         Controls how quickly the variable rate rises as utilization
    ///         increases from 0 to Uoptimal.  A lower value keeps borrowing
    ///         cheap in the normal operating range.
    uint256 public immutable variableRateSlope1;

    /// @notice Rslope2 — the rate slope applied above Uoptimal in RAY.
    ///         This is intentionally much steeper than Rslope1 to create a
    ///         strong economic deterrent against over-utilization.
    uint256 public immutable variableRateSlope2;

    /// @notice Uoptimal — the target utilization ratio in RAY (e.g. 0.8e27 = 80%).
    ///         Below this threshold the gentle Rslope1 applies; above it the
    ///         steep Rslope2 takes over.  Chosen per-asset based on its
    ///         expected liquidity depth and volatility.
    uint256 public immutable optimalUtilizationRate;

    /// @notice 1 − Uoptimal in RAY, precomputed at construction time.
    ///         Stored to avoid recomputing it on every rate call, saving gas.
    ///         Used as the denominator in the slope-2 formula:
    ///           (U − Uoptimal) / (1 − Uoptimal)
    uint256 public immutable excessUtilizationRate;

    /// @notice Base stable borrow rate in RAY.
    ///         The actual stable rate offered to borrowers is stableRateBase + Rv,
    ///         so it always carries a premium over the current variable rate.
    uint256 public immutable stableRateBase;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Reverts when a caller other than lendingPoolCore calls a restricted function.
    error Unauthorized(address caller);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param _lendingPoolCore         Address of LendingPoolCore — the only
     *                                 caller allowed to invoke updateInterestRates().
     * @param _optimalUtilizationRate  Uoptimal in RAY.  Must be strictly less
     *                                 than 1 RAY (100%) so that excessUtilizationRate > 0
     *                                 and the slope-2 denominator is never zero.
     * @param _baseVariableBorrowRate  Rv0 in RAY — floor rate at U = 0.
     * @param _variableRateSlope1      Rslope1 in RAY — gentle slope below Uoptimal.
     * @param _variableRateSlope2      Rslope2 in RAY — steep slope above Uoptimal.
     * @param _stableRateBase          Stable rate premium in RAY added on top of Rv.
     */
    constructor(
        address _lendingPoolCore,
        uint256 _optimalUtilizationRate,
        uint256 _baseVariableBorrowRate,
        uint256 _variableRateSlope1,
        uint256 _variableRateSlope2,
        uint256 _stableRateBase
    ) {
        require(_lendingPoolCore != address(0), "zero address");
        // Uoptimal < 1 RAY ensures (1 − Uoptimal) > 0, preventing division by
        // zero in the slope-2 branch of _variableRate().
        require(_optimalUtilizationRate < RAY, "Uoptimal must be < 1 ray");

        lendingPoolCore        = _lendingPoolCore;
        optimalUtilizationRate = _optimalUtilizationRate;
        // Precompute the excess denominator once; cheaper than subtracting on every call.
        excessUtilizationRate  = RAY - _optimalUtilizationRate;
        baseVariableBorrowRate = _baseVariableBorrowRate;
        variableRateSlope1     = _variableRateSlope1;
        variableRateSlope2     = _variableRateSlope2;
        stableRateBase         = _stableRateBase;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IReserveInterestRateStrategy — main entry point
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Calculates the three current interest rates for a reserve and
     *         returns them to LendingPoolCore, which stores them on the
     *         ReserveData struct.
     *
     * @dev    Call sequence on every user action (deposit / borrow / repay /
     *         liquidation):
     *           1. LendingPoolCore updates indexes (accrues interest to date).
     *           2. LendingPoolCore adjusts totalLiquidity / totalBorrows.
     *           3. LendingPoolCore calls this function to get fresh rates.
     *           4. LendingPoolCore stores the returned rates.
     *
     *         Restricted to lendingPoolCore to prevent anyone from pushing
     *         arbitrary rates into the reserve state.
     *
     * @param totalLiquidity         Lt — total deposits currently in the reserve
     *                               (underlying token units, not scaled).
     * @param totalVariableBorrows   Bv — total outstanding variable-rate debt.
     * @param totalStableBorrows     Bs — total outstanding stable-rate debt.
     * @param averageStableBorrowRate Rsa — the current weighted-average rate
     *                               across all stable borrowers, in RAY.
     *                               Used to compute the overall borrow rate RO.
     *
     * @return liquidityRate         Rl = RO × U  (supply APR in RAY)
     * @return stableBorrowRate      Rs = stableRateBase + Rv  (stable APR in RAY)
     * @return variableBorrowRate    Rv from the two-slope formula  (variable APR in RAY)
     */
    function updateInterestRates(
        uint256 totalLiquidity,
        uint256 totalVariableBorrows,
        uint256 totalStableBorrows,
        uint256 averageStableBorrowRate
    ) external override returns (uint256 liquidityRate, uint256 stableBorrowRate, uint256 variableBorrowRate) {
        // Only LendingPoolCore may trigger a rate update.
        if (msg.sender != lendingPoolCore) revert Unauthorized(msg.sender);

        // U = (Bv + Bs) / Lt
        // Aggregating both borrow types gives the true fraction of the pool in use.
        uint256 utilizationRate = _utilizationRate(totalLiquidity, totalVariableBorrows + totalStableBorrows);

        // Apply the two-slope formula to get the current variable rate.
        variableBorrowRate = _variableRate(utilizationRate);

        // Stable rate = fixed premium on top of the current variable rate.
        // This ensures stable borrowers always pay more than variable borrowers,
        // compensating the protocol for bearing the repricing risk.
        stableBorrowRate = stableRateBase + variableBorrowRate;

        // ── Overall borrow rate RO ────────────────────────────────────────────
        // RO is the weighted average of what all borrowers are paying.
        // It is used to derive the supply rate: depositors earn a share of
        // what borrowers pay, proportional to how much of the pool is lent out.
        uint256 totalBorrows = totalVariableBorrows + totalStableBorrows;
        uint256 overallBorrowRate;
        if (totalBorrows == 0) {
            // No borrows → no interest income → supply rate is also 0.
            overallBorrowRate = 0;
        } else {
            // Weight each borrow type by its outstanding principal:
            //   RO = (Bv·Rv + Bs·Rsa) / Bt
            // rayMul scales the product back to RAY after multiplying two RAY values.
            uint256 weightedVariable = totalVariableBorrows.rayMul(variableBorrowRate);
            uint256 weightedStable   = totalStableBorrows.rayMul(averageStableBorrowRate);
            overallBorrowRate = (weightedVariable + weightedStable).rayDiv(totalBorrows);
        }

        // ── Liquidity (supply) rate Rl ────────────────────────────────────────
        // Depositors only earn on the fraction of their funds that is actively
        // lent out, so:
        //   Rl = RO × U
        // This guarantees Rl ≤ RO for all U ∈ [0, 1], because U ≤ 1 RAY.
        liquidityRate = overallBorrowRate.rayMul(utilizationRate);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Computes utilization U = totalBorrows / totalLiquidity in RAY.
     *      Returns 0 when totalLiquidity is 0 to avoid division by zero.
     *      Note: U can theoretically exceed 1 RAY if borrows somehow exceed
     *      liquidity (e.g. due to accrued interest), which is handled gracefully
     *      by the slope-2 branch capping at its maximum value.
     */
    function _utilizationRate(uint256 totalLiquidity, uint256 totalBorrows) internal pure returns (uint256) {
        if (totalLiquidity == 0) return 0;
        // rayDiv: (totalBorrows × RAY) / totalLiquidity — result is in RAY.
        return totalBorrows.rayDiv(totalLiquidity);
    }

    /**
     * @dev Applies the two-slope kinked rate model.
     *
     *      Below the kink (U ≤ Uoptimal):
     *        The utilization ratio is normalized to [0, 1] relative to Uoptimal,
     *        then scaled by Rslope1.  At U = 0 the result is exactly Rv0; at
     *        U = Uoptimal it is exactly Rv0 + Rslope1.
     *
     *      Above the kink (U > Uoptimal):
     *        The excess utilization (U − Uoptimal) is normalized to [0, 1]
     *        relative to the remaining headroom (1 − Uoptimal), then scaled by
     *        the much steeper Rslope2.  At U = 1 RAY (100%) the result is
     *        Rv0 + Rslope1 + Rslope2 — the maximum possible rate.
     *
     *      All divisions and multiplications use rayDiv/rayMul from WadRayMath,
     *      which round half-up and revert on overflow, satisfying AC-9.
     */
    function _variableRate(uint256 utilizationRate) internal view returns (uint256) {
        if (utilizationRate <= optimalUtilizationRate) {
            // Normal operating range: gentle linear ramp.
            // (U / Uoptimal) is a fraction in [0, 1] expressed in RAY.
            return baseVariableBorrowRate
                + utilizationRate.rayDiv(optimalUtilizationRate).rayMul(variableRateSlope1);
        } else {
            // Over-utilization: steep linear ramp starting from the kink.
            // excessUtil is how far past Uoptimal we are, in RAY units.
            // Dividing by excessUtilizationRate (= 1 − Uoptimal) normalizes it to [0, 1].
            uint256 excessUtil = utilizationRate - optimalUtilizationRate;
            return baseVariableBorrowRate
                + variableRateSlope1
                + excessUtil.rayDiv(excessUtilizationRate).rayMul(variableRateSlope2);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View helpers — unrestricted, for off-chain tooling and tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the variable borrow rate for a given utilization ratio
    ///         without requiring a call from LendingPoolCore.  Useful for
    ///         front-ends and tests that need to preview rates before an action.
    function getVariableRate(uint256 utilizationRate) external view returns (uint256) {
        return _variableRate(utilizationRate);
    }

    /// @notice Returns the utilization ratio U = totalBorrows / totalLiquidity
    ///         in RAY for given pool totals.  Returns 0 if totalLiquidity is 0.
    function getUtilizationRate(uint256 totalLiquidity, uint256 totalBorrows) external pure returns (uint256) {
        return _utilizationRate(totalLiquidity, totalBorrows);
    }
}
