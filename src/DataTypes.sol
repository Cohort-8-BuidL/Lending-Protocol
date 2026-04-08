// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DataTypes
 * @notice Canonical struct definitions shared across the entire protocol.
 *
 * Storage layout notes
 * ─────────────────────
 * Solidity packs variables into 32-byte slots from top to bottom.
 * Each struct field is annotated with its slot number to make the layout
 * explicit — this matters when external tooling or assembly reads raw slots.
 *
 * Index precision: RAY (1e27)
 * Amount precision: underlying token decimals (stored as-is)
 * Rate precision: RAY (1e27)  e.g. 5% APR = 5e25
 * Percentage precision: RAY   e.g. 80% LTV = 8e26
 */
library DataTypes {

    // ─────────────────────────────────────────────────────────────────────────
    // ReserveConfigurationMap
    //
    // Bit-packed into a single uint256 to save storage slots.
    //
    // Bit layout:
    //   [0..15]   LTV (loan-to-value) in basis points  (max 10000 = 100%)
    //   [16..31]  Liquidation threshold in basis points
    //   [32..47]  Liquidation bonus in basis points (e.g. 10500 = 105%)
    //   [48..55]  Decimals of the underlying asset
    //   [56]      Reserve active flag
    //   [57]      Borrowing enabled flag
    //   [58]      Stable-rate borrowing enabled flag
    //   [59]      Frozen flag (deposits disabled, borrows disabled)
    //   [60..115] Reserved for future use
    // ─────────────────────────────────────────────────────────────────────────

    struct ReserveConfigurationMap {
        uint256 data;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ReserveData
    //
    // Core per-reserve state.  Every field is updated atomically on each
    // protocol action (deposit, borrow, repay, liquidation, flash loan).
    // ─────────────────────────────────────────────────────────────────────────

    struct ReserveData {
        // ── Slot 0 ────────────────────────────────────────────────────────────
        // Packed configuration (LTV, thresholds, flags, decimals)
        ReserveConfigurationMap configuration;

        // ── Slot 1 ────────────────────────────────────────────────────────────
        // Cᵢᵗ  — Cumulated liquidity index in RAY.
        // Tracks the cumulative growth of 1 liquidity unit deposited at
        // genesis.  Updated via simple (linear) interest on each action:
        //   Cᵢᵗ = (Rl · ΔTyear + 1) · Cᵢᵗ⁻¹
        uint128 liquidityIndex;

        // Bᵥ꜀ᵗ  — Cumulated variable borrow index in RAY.
        // Tracks the cumulative growth of 1 unit borrowed at variable rate.
        // Updated via compound interest on each action:
        //   Bᵥ꜀ᵗ = (1 + Rv/Tyear)^ΔT × Bᵥ꜀ᵗ⁻¹
        uint128 variableBorrowIndex;

        // ── Slot 2 ────────────────────────────────────────────────────────────
        // Rl — current liquidity (supply) rate per second in RAY
        uint128 currentLiquidityRate;

        // Rv — current variable borrow rate per second in RAY
        uint128 currentVariableBorrowRate;

        // ── Slot 3 ────────────────────────────────────────────────────────────
        // Rs — current stable borrow rate per second in RAY
        uint128 currentStableBorrowRate;

        // Tl — last time indexes were updated (block.timestamp)
        uint40 lastUpdateTimestamp;

        // Padding to complete the slot (128 + 40 = 168 bits used, 88 free)
        uint88 __reserved;

        // ── Slot 4 ────────────────────────────────────────────────────────────
        // Address of the aToken (receipt token) for this reserve
        address aTokenAddress; //address-> bytes32 (256bit)

        // ── Slot 5 ────────────────────────────────────────────────────────────
        // Address of the StableDebtToken for this reserve
        address stableDebtTokenAddress;

        // ── Slot 6 ────────────────────────────────────────────────────────────
        // Address of the VariableDebtToken for this reserve
        address variableDebtTokenAddress;

        // ── Slot 7 ────────────────────────────────────────────────────────────
        // Address of the interest rate strategy for this reserve
        address interestRateStrategyAddress;

        // ── Slot 8 ────────────────────────────────────────────────────────────
        // Lt — total liquidity (deposits) in underlying token units
        uint128 totalLiquidity;

        // Bs — total stable borrows in underlying token units
        uint128 totalStableBorrows;

        // ── Slot 9 ────────────────────────────────────────────────────────────
        // Bv — total variable borrows in underlying token units
        uint128 totalVariableBorrows;

        // Position of this reserve in the reservesList array
        uint8 id;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // InterestRateMode
    // ─────────────────────────────────────────────────────────────────────────

    enum InterestRateMode { NONE, STABLE, VARIABLE }
}
