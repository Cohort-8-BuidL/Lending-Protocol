// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title WadRayMath
 * @notice Fixed-point arithmetic library used throughout LendingPoolCore.
 *
 * Two precisions:
 *   WAD  — 1e18  — used for token amounts and percentages
 *   RAY  — 1e27  — used for indexes (liquidity index, borrow index, rates)
 *
 * All index variables (Cᵢᵗ, Bᵥ꜀ᵗ) are stored in RAY precision.
 * Interest rates (Rl, Rv) are stored in RAY precision (e.g. 5% = 5e25).
 */
library WadRayMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 0.5e18;

    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = 0.5e27;

    uint256 internal constant WAD_RAY_RATIO = 1e9;

    // ─────────────────────────────────────────────────────────────────────────
    // WAD operations
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev a * b in WAD, rounded half-up
 
    //note 
    function wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
       require(a <= (type(uint256).max - HALF_WAD) / b, "overflow"); 
        return (a * b + HALF_WAD) / WAD;
    }

    /// @dev a / b in WAD, rounded half-up
    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "WadRayMath: div by zero");
        require(a <= (type(uint256).max - b / 2) / WAD, "overflow");
       return (a * WAD + b / 2) / b;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // RAY operations
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev a * b in RAY, rounded half-up
    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
       require(a <= (type(uint256).max - HALF_RAY) / b, "overflow"); 
        return (a * b + HALF_RAY) / RAY;
    }

    /// @dev a / b in RAY, rounded half-up
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "WadRayMath: div by zero");
        require(a <= (type(uint256).max - b / 2) / RAY, "overflow");
        return (a * RAY + b / 2) / b;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Compound interest — used for the variable borrow index
    //
    // Exact formula:  (1 + rate/Tyear)^ΔT
    // where rate is the annual rate in RAY, Tyear = SECONDS_PER_YEAR, ΔT = seconds elapsed.
    //
    // We use binary exponentiation (rpow) on the per-second growth factor
    //   base = RAY + rate / SECONDS_PER_YEAR
    // which keeps error below 0.0001% for all realistic rate × time combinations.
    // ─────────────────────────────────────────────────────────────────────────

    uint256 internal constant SECONDS_PER_YEAR = 365 days; // 31_536_000

    /**
     * @notice Calculates compound interest using binary exponentiation.
     * @param rate   Annual rate in RAY (e.g. 5% = 5e25)
     * @param lastUpdateTimestamp  block.timestamp at last update
     * @return result  Accumulated factor in RAY to multiply into the index
     */
    function calculateCompoundedInterest(
        uint256 rate,
        uint256 lastUpdateTimestamp
    ) internal view returns (uint256) {
        return calculateCompoundedInterestAt(rate, lastUpdateTimestamp, block.timestamp);
    }

    function calculateCompoundedInterestAt(
        uint256 rate,
        uint256 lastUpdateTimestamp,
        uint256 currentTimestamp
    ) internal pure returns (uint256) {
        uint256 timeDelta = currentTimestamp - lastUpdateTimestamp;
        if (timeDelta == 0) return RAY;

        // per-second growth factor: RAY + rate/SECONDS_PER_YEAR
        uint256 base = RAY + rate / SECONDS_PER_YEAR;

        // binary exponentiation: base^timeDelta in RAY precision
        return _rpow(base, timeDelta);
    }

    /**
     * @dev Binary (fast) exponentiation in RAY precision.
     *      result = base^exp where base and result are in RAY units.
     */
    function _rpow(uint256 base, uint256 exp) private pure returns (uint256 result) {
        result = RAY;
        while (exp > 0) {
            if (exp & 1 == 1) {
                result = rayMul(result, base);
            }
            base = rayMul(base, base);
            exp >>= 1;
        }
    }

    /**
     * @notice Calculates simple (linear) interest.
     *         Used for the liquidity index: (Rl · ΔTyear + 1) · Cᵢᵗ⁻¹
     * @param rate   Annual rate in RAY
     * @param lastUpdateTimestamp  block.timestamp at last update
     * @return result  Accumulated factor in RAY
     */
    function calculateLinearInterest(
        uint256 rate,
        uint256 lastUpdateTimestamp
    ) internal view returns (uint256) {
        return calculateLinearInterestAt(rate, lastUpdateTimestamp, block.timestamp);
    }

    function calculateLinearInterestAt(
        uint256 rate,
        uint256 lastUpdateTimestamp,
        uint256 currentTimestamp
    ) internal pure returns (uint256) {
        uint256 timeDelta = currentTimestamp - lastUpdateTimestamp;
        if (timeDelta == 0) return RAY;

        // (rate * ΔT / SECONDS_PER_YEAR) + 1·RAY
        uint256 timeDeltaInRay = timeDelta * RAY;
        return RAY + (rate * timeDeltaInRay / SECONDS_PER_YEAR) / RAY;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Conversion helpers
    // ─────────────────────────────────────────────────────────────────────────

    function wadToRay(uint256 a) internal pure returns (uint256) {
        return a * WAD_RAY_RATIO;
    }

    function rayToWad(uint256 a) internal pure returns (uint256) {
        return (a + WAD_RAY_RATIO / 2) / WAD_RAY_RATIO;
    }
}
