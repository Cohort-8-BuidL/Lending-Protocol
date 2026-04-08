// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DataTypes} from "./DataTypes.sol";

/**
 * @title ReserveConfiguration
 * @notice Bit-mask getters and setters for ReserveConfigurationMap.
 *
 * All values are packed into a single uint256 to avoid paying for
 * multiple cold storage reads when multiple fields are needed together.
 *
 * Bit layout (matches DataTypes.sol comment):
 *   [0..15]   LTV (basis points, 0-10000)
 *   [16..31]  Liquidation threshold (basis points)
 *   [32..47]  Liquidation bonus (basis points, e.g. 10500 = 105%)
 *   [48..55]  Decimals (0-255)
 *   [56]      Active
 *   [57]      Borrowing enabled
 *   [58]      Stable-rate borrowing enabled
 *   [59]      Frozen
 */
library ReserveConfiguration {
    // ── Masks ─────────────────────────────────────────────────────────────────
    uint256 internal constant LTV_MASK                    = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0000; // [0..15] → ~mask
    uint256 internal constant LIQUIDATION_THRESHOLD_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0000FFFF;
    uint256 internal constant LIQUIDATION_BONUS_MASK     = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0000FFFFFFFF;
    uint256 internal constant DECIMALS_MASK              = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00FFFFFFFFFFFF;
    uint256 internal constant ACTIVE_MASK                = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFFFFFFFF;
    uint256 internal constant BORROWING_MASK             = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFDFFFFFFFFFFFFFF;
    uint256 internal constant STABLE_BORROWING_MASK      = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBFFFFFFFFFFFFFF;
    uint256 internal constant FROZEN_MASK                = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7FFFFFFFFFFFFFF;

    // ── Bit positions ─────────────────────────────────────────────────────────
    uint256 internal constant LIQUIDATION_THRESHOLD_START_BIT = 16;
    uint256 internal constant LIQUIDATION_BONUS_START_BIT     = 32;
    uint256 internal constant DECIMALS_START_BIT              = 48;
    uint256 internal constant ACTIVE_START_BIT                = 56;
    uint256 internal constant BORROWING_ENABLED_START_BIT     = 57;
    uint256 internal constant STABLE_BORROWING_ENABLED_BIT    = 58;
    uint256 internal constant FROZEN_START_BIT                = 59;

    // ── Validation constants ──────────────────────────────────────────────────
    uint256 internal constant MAX_VALID_LTV                    = 65535;
    uint256 internal constant MAX_VALID_LIQUIDATION_THRESHOLD  = 65535;
    uint256 internal constant MAX_VALID_LIQUIDATION_BONUS      = 65535;
    uint256 internal constant MAX_VALID_DECIMALS               = 255;

    // ─────────────────────────────────────────────────────────────────────────
    // Setters
    // ─────────────────────────────────────────────────────────────────────────

    function setLtv(DataTypes.ReserveConfigurationMap memory self, uint256 ltv) internal pure {
        require(ltv <= MAX_VALID_LTV, "RC: invalid LTV");
        self.data = (self.data & LTV_MASK) | ltv;
    }

    function setLiquidationThreshold(
        DataTypes.ReserveConfigurationMap memory self,
        uint256 threshold
    ) internal pure {
        require(threshold <= MAX_VALID_LIQUIDATION_THRESHOLD, "RC: invalid threshold");
        self.data = (self.data & LIQUIDATION_THRESHOLD_MASK) | (threshold << LIQUIDATION_THRESHOLD_START_BIT);
    }

    function setLiquidationBonus(
        DataTypes.ReserveConfigurationMap memory self,
        uint256 bonus
    ) internal pure {
        require(bonus <= MAX_VALID_LIQUIDATION_BONUS, "RC: invalid bonus");
        self.data = (self.data & LIQUIDATION_BONUS_MASK) | (bonus << LIQUIDATION_BONUS_START_BIT);
    }

    function setDecimals(DataTypes.ReserveConfigurationMap memory self, uint256 decimals) internal pure {
        require(decimals <= MAX_VALID_DECIMALS, "RC: invalid decimals");
        self.data = (self.data & DECIMALS_MASK) | (decimals << DECIMALS_START_BIT);
    }

    function setActive(DataTypes.ReserveConfigurationMap memory self, bool active) internal pure {
        // forge-lint: disable-next-line(incorrect-shift)
        self.data = (self.data & ACTIVE_MASK) | (active ? 1 << ACTIVE_START_BIT : 0);
    }

    function setBorrowingEnabled(
        DataTypes.ReserveConfigurationMap memory self,
        bool enabled
    ) internal pure {
        // forge-lint: disable-next-line(incorrect-shift)
        self.data = (self.data & BORROWING_MASK) | (enabled ? 1 << BORROWING_ENABLED_START_BIT : 0);
    }

    function setStableBorrowRateEnabled(
        DataTypes.ReserveConfigurationMap memory self,
        bool enabled
    ) internal pure {
        // forge-lint: disable-next-line(incorrect-shift)
        self.data = (self.data & STABLE_BORROWING_MASK) | (enabled ? 1 << STABLE_BORROWING_ENABLED_BIT : 0);
    }

    function setFrozen(DataTypes.ReserveConfigurationMap memory self, bool frozen) internal pure {
        // forge-lint: disable-next-line(incorrect-shift)
        self.data = (self.data & FROZEN_MASK) | (frozen ? 1 << FROZEN_START_BIT : 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Getters
    // ─────────────────────────────────────────────────────────────────────────

    function getLtv(DataTypes.ReserveConfigurationMap memory self) internal pure returns (uint256) {
        return self.data & ~LTV_MASK;
    }

    function getLiquidationThreshold(
        DataTypes.ReserveConfigurationMap memory self
    ) internal pure returns (uint256) {
        return (self.data & ~LIQUIDATION_THRESHOLD_MASK) >> LIQUIDATION_THRESHOLD_START_BIT;
    }

    function getLiquidationBonus(
        DataTypes.ReserveConfigurationMap memory self
    ) internal pure returns (uint256) {
        return (self.data & ~LIQUIDATION_BONUS_MASK) >> LIQUIDATION_BONUS_START_BIT;
    }

    function getDecimals(
        DataTypes.ReserveConfigurationMap memory self
    ) internal pure returns (uint256) {
        return (self.data & ~DECIMALS_MASK) >> DECIMALS_START_BIT;
    }

    function getActive(DataTypes.ReserveConfigurationMap memory self) internal pure returns (bool) {
        return (self.data & ~ACTIVE_MASK) != 0;
    }

    function getBorrowingEnabled(
        DataTypes.ReserveConfigurationMap memory self
    ) internal pure returns (bool) {
        return (self.data & ~BORROWING_MASK) != 0;
    }

    function getStableBorrowRateEnabled(
        DataTypes.ReserveConfigurationMap memory self
    ) internal pure returns (bool) {
        return (self.data & ~STABLE_BORROWING_MASK) != 0;
    }

    function getFrozen(DataTypes.ReserveConfigurationMap memory self) internal pure returns (bool) {
        return (self.data & ~FROZEN_MASK) != 0;
    }

    /// @notice Returns all flags in one SLOAD-equivalent call
    function getFlags(
        DataTypes.ReserveConfigurationMap memory self
    ) internal pure returns (bool active, bool borrowing, bool stableBorrowing, bool frozen) {
        uint256 data = self.data;
        active          = (data & ~ACTIVE_MASK) != 0;
        borrowing       = (data & ~BORROWING_MASK) != 0;
        stableBorrowing = (data & ~STABLE_BORROWING_MASK) != 0;
        frozen          = (data & ~FROZEN_MASK) != 0;
    }

    /// @notice Returns LTV and thresholds in one call (used by collateral logic)
    function getParams(
        DataTypes.ReserveConfigurationMap memory self
    ) internal pure returns (
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 decimals
    ) {
        uint256 data = self.data;
        ltv                  = data & ~LTV_MASK;
        liquidationThreshold = (data & ~LIQUIDATION_THRESHOLD_MASK) >> LIQUIDATION_THRESHOLD_START_BIT;
        liquidationBonus     = (data & ~LIQUIDATION_BONUS_MASK)      >> LIQUIDATION_BONUS_START_BIT;
        decimals             = (data & ~DECIMALS_MASK)               >> DECIMALS_START_BIT;
    }
}
