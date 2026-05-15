// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DefaultReserveInterestRateStrategy} from "../src/DefaultReserveInterestRateStrategy.sol";
import {WadRayMath} from "../src/WadRayMath.sol";

contract InterestRateStrategyTest is Test {
    using WadRayMath for uint256;

    uint256 constant RAY = 1e27;

    // Parameters matching a typical USDC-like reserve
    uint256 constant OPTIMAL_UR   = 0.80e27; // 80%
    uint256 constant BASE_RATE    = 0;        // Rv0 = 0
    uint256 constant SLOPE1       = 0.04e27;  // 4%
    uint256 constant SLOPE2       = 0.75e27;  // 75%
    uint256 constant STABLE_BASE  = 0.02e27;  // 2%

    DefaultReserveInterestRateStrategy strategy;
    address core = address(0xC04E);

    function setUp() public {
        strategy = new DefaultReserveInterestRateStrategy(
            core,
            OPTIMAL_UR,
            BASE_RATE,
            SLOPE1,
            SLOPE2,
            STABLE_BASE
        );
    }

    // ── AC-5: U = 0 → Rv = Rv0 ───────────────────────────────────────────────

    function test_variableRate_atZeroUtilization() public view {
        uint256 rv = strategy.getVariableRate(0);
        assertEq(rv, BASE_RATE, "Rv at U=0 must equal Rv0");
    }

    // ── AC-6: U = Uoptimal → Rv = Rv0 + Rslope1 ─────────────────────────────

    function test_variableRate_atOptimalUtilization() public view {
        uint256 rv = strategy.getVariableRate(OPTIMAL_UR);
        assertEq(rv, BASE_RATE + SLOPE1, "Rv at U=Uoptimal must equal Rv0 + Rslope1");
    }

    // ── AC-7: Above Uoptimal — slope 2 kicks in ───────────────────────────────

    function _expectedRv(uint256 u) internal pure returns (uint256) {
        if (u <= OPTIMAL_UR) {
            return BASE_RATE + u.rayDiv(OPTIMAL_UR).rayMul(SLOPE1);
        }
        uint256 excess = u - OPTIMAL_UR;
        uint256 excessUR = RAY - OPTIMAL_UR;
        return BASE_RATE + SLOPE1 + excess.rayDiv(excessUR).rayMul(SLOPE2);
    }

    function test_variableRate_above_optimal_0_85() public view {
        uint256 u = 0.85e27;
        assertEq(strategy.getVariableRate(u), _expectedRv(u));
    }

    function test_variableRate_above_optimal_0_90() public view {
        uint256 u = 0.90e27;
        assertEq(strategy.getVariableRate(u), _expectedRv(u));
    }

    function test_variableRate_above_optimal_0_95() public view {
        uint256 u = 0.95e27;
        assertEq(strategy.getVariableRate(u), _expectedRv(u));
    }

    function test_variableRate_above_optimal_1_00() public view {
        uint256 u = 1.00e27;
        assertEq(strategy.getVariableRate(u), _expectedRv(u));
    }

    // ── AC-8: Rl ≤ RO always ─────────────────────────────────────────────────

    function test_liquidityRate_leq_overallBorrowRate() public {
        // Use U = 0.90 scenario: 900 borrowed out of 1000 liquidity
        uint256 totalLiquidity = 1000e18;
        uint256 totalVariable  = 900e18;
        uint256 totalStable    = 0;

        vm.prank(core);
        (uint256 rl, , uint256 rv) = strategy.updateInterestRates(
            totalLiquidity, totalVariable, totalStable, 0
        );

        // RO = rv (only variable borrows), Rl = RO × U
        uint256 u = strategy.getUtilizationRate(totalLiquidity, totalVariable);
        uint256 ro = rv; // only variable borrows, so RO = Rv
        uint256 expectedRl = ro.rayMul(u);

        assertEq(rl, expectedRl);
        assertLe(rl, ro, "Rl must be <= RO");
    }

    function test_liquidityRate_leq_overallBorrowRate_mixed() public {
        uint256 totalLiquidity = 1000e18;
        uint256 totalVariable  = 500e18;
        uint256 totalStable    = 200e18;
        uint256 avgStableRate  = 0.05e27; // 5%

        vm.prank(core);
        (uint256 rl, , uint256 rv) = strategy.updateInterestRates(
            totalLiquidity, totalVariable, totalStable, avgStableRate
        );

        uint256 totalBorrows = totalVariable + totalStable;
        uint256 u = strategy.getUtilizationRate(totalLiquidity, totalBorrows);
        uint256 weightedRO = (totalVariable.rayMul(rv) + totalStable.rayMul(avgStableRate))
            .rayDiv(totalBorrows);
        uint256 expectedRl = weightedRO.rayMul(u);

        assertEq(rl, expectedRl);
        assertLe(rl, weightedRO, "Rl must be <= RO");
    }

    // ── AC-9: No overflow — fuzz ──────────────────────────────────────────────

    function testFuzz_noOverflow(uint256 totalLiquidity, uint256 totalVariable, uint256 totalStable) public {
        // Bound to realistic token amounts (up to 1 trillion tokens with 18 decimals)
        totalLiquidity = bound(totalLiquidity, 0, 1e30);
        totalVariable  = bound(totalVariable,  0, totalLiquidity);
        totalStable    = bound(totalStable,    0, totalLiquidity - totalVariable);

        vm.prank(core);
        // Should not revert
        strategy.updateInterestRates(totalLiquidity, totalVariable, totalStable, 0.05e27);
    }

    // ── Access control ────────────────────────────────────────────────────────

    function test_updateInterestRates_onlyCore() public {
        vm.expectRevert(
            abi.encodeWithSelector(DefaultReserveInterestRateStrategy.Unauthorized.selector, address(this))
        );
        strategy.updateInterestRates(1000e18, 500e18, 0, 0);
    }

    // ── Edge: zero liquidity → U = 0 → Rv = Rv0 ──────────────────────────────

    function test_zeroLiquidity_returnsBaseRate() public {
        vm.prank(core);
        (, , uint256 rv) = strategy.updateInterestRates(0, 0, 0, 0);
        assertEq(rv, BASE_RATE);
    }
}
