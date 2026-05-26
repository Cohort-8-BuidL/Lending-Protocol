// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPoolCore} from "../src/LendingPoolCore.sol";
import {DataTypes} from "../src/DataTypes.sol";
import {WadRayMath} from "../src/WadRayMath.sol";

/**
 * @title LendingPoolCoreTest
 * @notice Acceptance-criteria tests for Deliverable 1.1.
 *
 * AC1 — Indexes update within 0.0001% margin over 1, 5, 10-year periods.
 * AC2 — All reserve state variables update atomically (no partial state).
 * AC3 — totalBorrows == stableBorrows + variableBorrows at all times.
 * AC4 — Access control: only lendingPool / configurator may mutate state.
 */
contract LendingPoolCoreTest is Test {
    using WadRayMath for uint256;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 constant RAY              = 1e27;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    /// @dev 0.0001% tolerance expressed as a fraction of RAY
    uint256 constant TOLERANCE_RAY    = RAY / 1_000_000; // 1e21

    // ── Actors ────────────────────────────────────────────────────────────────
    address constant POOL        = address(0xA001);
    address constant CONFIGURATOR = address(0xA002);
    address constant ASSET       = address(0xB001);
    address constant ATOKEN      = address(0xC001);
    address constant STABLE_DEBT = address(0xC002);
    address constant VAR_DEBT    = address(0xC003);
    address constant STRATEGY    = address(0xC004);
    address constant ATTACKER    = address(0xDEAD);

    LendingPoolCore core;

    function setUp() public {
        core = new LendingPoolCore(POOL, CONFIGURATOR);

        // Initialize a reserve via the configurator
        vm.prank(CONFIGURATOR);
        core.initReserve(ASSET, ATOKEN, STABLE_DEBT, VAR_DEBT, STRATEGY);

        // Set a 5% liquidity rate and 8% variable borrow rate (in RAY)
        vm.prank(POOL);
        core.updateReserveInterestRates(ASSET, 5e25, 6e25, 8e25);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC1 — Index accuracy over 1, 5, 10-year periods
    // ─────────────────────────────────────────────────────────────────────────

    function test_liquidityIndex_1year() public {
        _warpAndUpdate(SECONDS_PER_YEAR);

        uint256 idx = core.getReserveLiquidityIndex(ASSET);
        // Expected: (1 + 0.05) * RAY = 1.05e27
        uint256 expected = RAY + 5e25; // 1.05 RAY
        _assertWithinTolerance(idx, expected, "liquidity index 1yr");
    }

    function test_liquidityIndex_5year() public {
        _warpAndUpdate(5 * SECONDS_PER_YEAR);

        uint256 idx = core.getReserveLiquidityIndex(ASSET);
        // Linear: (1 + 0.05*5) * RAY = 1.25 RAY
        uint256 expected = RAY + 25e25;
        _assertWithinTolerance(idx, expected, "liquidity index 5yr");
    }

    function test_liquidityIndex_10year() public {
        _warpAndUpdate(10 * SECONDS_PER_YEAR);

        uint256 idx = core.getReserveLiquidityIndex(ASSET);
        // Linear: (1 + 0.05*10) * RAY = 1.50 RAY
        uint256 expected = RAY + 50e25;
        _assertWithinTolerance(idx, expected, "liquidity index 10yr");
    }

    function test_variableBorrowIndex_1year() public {
        _warpAndUpdate(SECONDS_PER_YEAR);

        uint256 idx = core.getReserveVariableBorrowIndex(ASSET);
        // (1 + 0.08/SECONDS_PER_YEAR)^SECONDS_PER_YEAR ≈ e^0.08 ≈ 1.08329 RAY
        // rpow result (verified off-chain): 1083287067565035970354473776
        uint256 expected = 1_083_287_067_565_035_970_354_473_776;
        _assertWithinTolerance(idx, expected, "variable borrow index 1yr");
    }

    function test_variableBorrowIndex_5year() public {
        _warpAndUpdate(5 * SECONDS_PER_YEAR);

        uint256 idx = core.getReserveVariableBorrowIndex(ASSET);
        // rpow result for 5yr at 8%: 1491824696884383105647424579
        uint256 expected = 1_491_824_696_884_383_105_647_424_579;
        _assertWithinTolerance(idx, expected, "variable borrow index 5yr");
    }

    function test_variableBorrowIndex_10year() public {
        _warpAndUpdate(10 * SECONDS_PER_YEAR);

        uint256 idx = core.getReserveVariableBorrowIndex(ASSET);
        // rpow result for 10yr at 8%: 2225540926234181532242143586
        uint256 expected = 2_225_540_926_234_181_532_242_143_586;
        _assertWithinTolerance(idx, expected, "variable borrow index 10yr");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC1 — getNormalizedIncome / getNormalizedVariableDebt (view projections)
    // ─────────────────────────────────────────────────────────────────────────

    function test_normalizedIncome_matchesStoredAfterUpdate() public {
        uint256 ts = block.timestamp + SECONDS_PER_YEAR;
        // View projection before update
        vm.warp(ts);
        uint256 projected = core.getReserveNormalizedIncome(ASSET);

        // Now actually update
        vm.prank(POOL);
        core.updateReserveIndexes(ASSET);

        uint256 stored = core.getReserveLiquidityIndex(ASSET);
        assertEq(projected, stored, "normalized income should match stored after update");
    }

    function test_normalizedVariableDebt_matchesStoredAfterUpdate() public {
        uint256 ts = block.timestamp + SECONDS_PER_YEAR;
        vm.warp(ts);
        uint256 projected = core.getReserveNormalizedVariableDebt(ASSET);

        vm.prank(POOL);
        core.updateReserveIndexes(ASSET);

        uint256 stored = core.getReserveVariableBorrowIndex(ASSET);
        assertEq(projected, stored, "normalized variable debt should match stored after update");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC2 — Atomic updates (no partial state)
    // ─────────────────────────────────────────────────────────────────────────

    function test_indexesUpdateAtomically() public {
        uint256 tsBefore = core.getReserveLastUpdateTimestamp(ASSET);
        uint256 liBefore = core.getReserveLiquidityIndex(ASSET);
        uint256 vbiBefore = core.getReserveVariableBorrowIndex(ASSET);

        vm.warp(block.timestamp + 30 days);
        vm.prank(POOL);
        core.updateReserveIndexes(ASSET);

        uint256 tsAfter  = core.getReserveLastUpdateTimestamp(ASSET);
        uint256 liAfter  = core.getReserveLiquidityIndex(ASSET);
        uint256 vbiAfter = core.getReserveVariableBorrowIndex(ASSET);

        // All three must have changed together
        assertGt(tsAfter,  tsBefore,  "timestamp must advance");
        assertGt(liAfter,  liBefore,  "liquidity index must increase");
        assertGt(vbiAfter, vbiBefore, "variable borrow index must increase");

        // Timestamp must equal block.timestamp exactly
        assertEq(tsAfter, block.timestamp, "timestamp must equal block.timestamp");
    }

    function test_sameBlockUpdateIsNoop() public {
        // Second call in same block must not change anything
        vm.prank(POOL);
        core.updateReserveIndexes(ASSET);

        uint256 li1  = core.getReserveLiquidityIndex(ASSET);
        uint256 vbi1 = core.getReserveVariableBorrowIndex(ASSET);
        uint256 ts1  = core.getReserveLastUpdateTimestamp(ASSET);

        vm.prank(POOL);
        core.updateReserveIndexes(ASSET);

        assertEq(core.getReserveLiquidityIndex(ASSET),     li1,  "no change same block");
        assertEq(core.getReserveVariableBorrowIndex(ASSET), vbi1, "no change same block");
        assertEq(core.getReserveLastUpdateTimestamp(ASSET), ts1,  "no change same block");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC3 — totalBorrows == stableBorrows + variableBorrows
    // ─────────────────────────────────────────────────────────────────────────

    function test_totalBorrows_invariant_afterBorrow() public {
        vm.startPrank(POOL);
        core.updateTotalStableBorrows(ASSET, 500e18);
        core.updateTotalVariableBorrows(ASSET, 1000e18);
        vm.stopPrank();

        uint256 stable   = core.getReserveTotalStableBorrows(ASSET);
        uint256 variable = core.getReserveTotalVariableBorrows(ASSET);
        uint256 total    = core.getReserveTotalBorrows(ASSET);

        assertEq(total, stable + variable, "totalBorrows must equal stable + variable");
    }

    function test_totalBorrows_invariant_afterRepay() public {
        vm.startPrank(POOL);
        core.updateTotalStableBorrows(ASSET, 500e18);
        core.updateTotalVariableBorrows(ASSET, 1000e18);
        // Partial repay
        core.updateTotalStableBorrows(ASSET, -200e18);
        core.updateTotalVariableBorrows(ASSET, -400e18);
        vm.stopPrank();

        uint256 stable   = core.getReserveTotalStableBorrows(ASSET);
        uint256 variable = core.getReserveTotalVariableBorrows(ASSET);
        uint256 total    = core.getReserveTotalBorrows(ASSET);

        assertEq(stable,   300e18,  "stable borrows after repay");
        assertEq(variable, 600e18,  "variable borrows after repay");
        assertEq(total, stable + variable, "invariant holds after repay");
    }

    function test_totalLiquidity_tracking() public {
        vm.startPrank(POOL);
        core.updateTotalLiquidity(ASSET, 2000e18);
        assertEq(core.getReserveTotalLiquidity(ASSET), 2000e18, "deposit tracked");

        core.updateTotalLiquidity(ASSET, -500e18);
        assertEq(core.getReserveTotalLiquidity(ASSET), 1500e18, "withdrawal tracked");
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC4 — Access control
    // ─────────────────────────────────────────────────────────────────────────

    function test_revert_updateIndexes_notPool() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(LendingPoolCore.Unauthorized.selector, ATTACKER));
        core.updateReserveIndexes(ASSET);
    }

    function test_revert_initReserve_notConfigurator() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(LendingPoolCore.Unauthorized.selector, ATTACKER));
        core.initReserve(address(0x1), address(0x2), address(0x3), address(0x4), address(0x5));
    }

    function test_revert_setConfig_notConfigurator() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(LendingPoolCore.Unauthorized.selector, ATTACKER));
        core.setReserveConfiguration(ASSET, 0);
    }

    function test_revert_updateRates_notPool() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(LendingPoolCore.Unauthorized.selector, ATTACKER));
        core.updateReserveInterestRates(ASSET, 0, 0, 0);
    }

    function test_revert_updateTotalBorrows_notPool() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(LendingPoolCore.Unauthorized.selector, ATTACKER));
        core.updateTotalVariableBorrows(ASSET, 100e18);
    }

    function test_revert_initReserve_twice() public {
        vm.prank(CONFIGURATOR);
        vm.expectRevert(abi.encodeWithSelector(LendingPoolCore.ReserveAlreadyInitialized.selector, ASSET));
        core.initReserve(ASSET, ATOKEN, STABLE_DEBT, VAR_DEBT, STRATEGY);
    }

    function test_revert_zeroAddress_constructor() public {
        vm.expectRevert(LendingPoolCore.ZeroAddress.selector);
        new LendingPoolCore(address(0), CONFIGURATOR);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Configuration getters
    // ─────────────────────────────────────────────────────────────────────────

    function test_configurationGetters() public {
        // Set LTV=8000, threshold=8500, bonus=10500, decimals=18, active=true, borrowing=true
        DataTypes.ReserveConfigurationMap memory cfg;
        cfg.data = 0;

        // Build config via ReserveConfiguration library (tested indirectly through LendingPoolCore)
        // We encode manually: LTV=8000 in [0..15], threshold=8500 in [16..31], bonus=10500 in [32..47], decimals=18 in [48..55]
        uint256 data = 8000 | (8500 << 16) | (10500 << 32) | (uint256(18) << 48);
        // active=true bit 56, borrowing=true bit 57
        data |= (1 << 56) | (1 << 57);

        vm.prank(CONFIGURATOR);
        core.setReserveConfiguration(ASSET, data);

        (uint256 ltv, uint256 threshold, uint256 bonus, uint256 decimals) =
            core.getReserveConfigurationParams(ASSET);

        assertEq(ltv,       8000,  "LTV");
        assertEq(threshold, 8500,  "liquidation threshold");
        assertEq(bonus,     10500, "liquidation bonus");
        assertEq(decimals,  18,    "decimals");
        assertTrue(core.isReserveActive(ASSET),            "active");
        assertTrue(core.isReserveBorrowingEnabled(ASSET),  "borrowing enabled");
    }

    function test_reservesList() public view {
        address[] memory list = core.getReservesList();
        assertEq(list.length, 1,     "one reserve");
        assertEq(list[0],     ASSET, "correct asset");
        assertEq(core.getReservesCount(), 1, "count matches");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _warpAndUpdate(uint256 secondsToAdvance) internal {
        vm.warp(block.timestamp + secondsToAdvance);
        vm.prank(POOL);
        core.updateReserveIndexes(ASSET);
    }

    /// @dev Asserts |actual - expected| / expected <= 0.0001% (1e-6 relative)
    function _assertWithinTolerance(uint256 actual, uint256 expected, string memory label) internal pure {
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        // diff / expected <= 1e-6  ⟺  diff * 1e6 <= expected
        assertLe(diff * 1_000_000, expected, string.concat(label, ": exceeds 0.0001% tolerance"));
    }
}
