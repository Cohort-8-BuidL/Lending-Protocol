// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from 'forge-std/Test.sol';

import {LendingPoolDataProvider} from 'src/LendingPoolDataProvider.sol';
import {MockPoolLike} from 'src/mocks/MockPoolLike.sol';
import {MockPriceOracle} from 'src/mocks/MockPriceOracle.sol';

/// @title LendingPoolDataProviderTest
/// @notice Unit + fuzz + invariant tests for LendingPoolDataProvider.
///         Naming: test_<function>_<condition>_<expectedBehavior>
contract LendingPoolDataProviderTest is Test {
  uint256 internal constant RAY = 1e27;
  uint256 internal constant BPS = 1e4;
  uint256 internal constant WAD = 1e18;

  address internal constant USER = address(0xBEEF);
  address internal constant ETH_ASSET = address(0xE1);
  address internal constant DAI_ASSET = address(0xD1);
  address internal constant USDC_ASSET = address(0xC1);

  MockPriceOracle internal oracle;
  MockPoolLike internal pool;
  LendingPoolDataProvider internal dp;

  function setUp() external {
    oracle = new MockPriceOracle();
    pool = new MockPoolLike();
    dp = new LendingPoolDataProvider(pool);

    pool.setPriceOracle(oracle);

    // ETH: 18 dec, LTV 75%, LT 80%
    pool.addReserve(ETH_ASSET, 18, 7500, 8000);
    // DAI: 18 dec, LTV 80%, LT 85%
    pool.addReserve(DAI_ASSET, 18, 8000, 8500);
    // USDC: 6 dec, LTV 70%, LT 75%
    pool.addReserve(USDC_ASSET, 6, 7000, 7500);

    // Prices: 1 ETH = 1 ETH, 1 DAI = 0.001 ETH, 1 USDC = 0.001 ETH
    oracle.setAssetPrice(ETH_ASSET, 1e18);
    oracle.setAssetPrice(DAI_ASSET, 1e15);
    oracle.setAssetPrice(USDC_ASSET, 1e15);
  }

  // === Constructor
  function test_constructor_zeroPool_reverts() external {
    vm.expectRevert('LDP: INVALID_POOL');
    new LendingPoolDataProvider(MockPoolLike(address(0)));
  }

  // === Input validation
  function test_getUserAccountData_zeroUser_reverts() external {
    vm.expectRevert('LDP: INVALID_USER');
    dp.getUserAccountData(address(0));
  }

  function test_getHealthFactor_zeroUser_reverts() external {
    vm.expectRevert('LDP: INVALID_USER');
    dp.getHealthFactor(address(0));
  }

  function test_getCompoundedBorrowBalance_zeroUser_reverts() external {
    vm.expectRevert('LDP: INVALID_USER');
    dp.getCompoundedBorrowBalance(address(0), ETH_ASSET);
  }

  function test_getCompoundedBorrowBalance_zeroReserve_reverts() external {
    vm.expectRevert('LDP: INVALID_RESERVE');
    dp.getCompoundedBorrowBalance(USER, address(0));
  }

  // === Oracle safety
  function test_getHealthFactor_oracleNotSet_reverts() external {
    // Deploy a fresh pool with no oracle set.
    MockPoolLike freshPool = new MockPoolLike();
    freshPool.addReserve(ETH_ASSET, 18, 7500, 8000);
    freshPool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    freshPool.setUserCollateralBalance(USER, ETH_ASSET, 1 ether);

    LendingPoolDataProvider freshDp = new LendingPoolDataProvider(freshPool);
    vm.expectRevert('LDP: ORACLE_NOT_SET');
    freshDp.getHealthFactor(USER);
  }

  function test_getHealthFactor_stalePriceOnCollateral_reverts() external {
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    // Set ETH price to 0 (stale).
    oracle.setAssetPrice(ETH_ASSET, 0);

    vm.expectRevert('LDP: STALE_ORACLE');
    dp.getHealthFactor(USER);
  }

  function test_getHealthFactor_stalePriceOnDebt_reverts() external {
    // Collateral is fine, but debt asset oracle goes stale.
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 1_000e18);
    oracle.setAssetPrice(DAI_ASSET, 0);

    vm.expectRevert('LDP: STALE_ORACLE');
    dp.getHealthFactor(USER);
  }

  function test_getHealthFactor_stalePriceOnFee_reverts() external {
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    pool.setUserOriginationFee(USER, DAI_ASSET, 100e18);
    oracle.setAssetPrice(DAI_ASSET, 0);

    vm.expectRevert('LDP: STALE_ORACLE');
    dp.getHealthFactor(USER);
  }

  // === Health factor — core cases
  function test_getHealthFactor_noDebt_returnsMax() external {
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);

    assertEq(dp.getHealthFactor(USER), type(uint256).max);
  }

  function test_getHealthFactor_noCollateralWithDebt_returnsZero() external {
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 1_000e18);
    assertEq(dp.getHealthFactor(USER), 0);
  }

  function test_getHealthFactor_singleAsset_correct() external {
    // 10 ETH collateral, LT 80%, 6 ETH debt => HF = 8/6 = 1.333...
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 6_000e18);

    assertApproxEqAbs(dp.getHealthFactor(USER), 1_333_333_333_333_333_333_333_333_333, 5);
  }

  function test_getHealthFactor_exactLiquidationBoundary_returnsOneRay() external {
    // 10 ETH * 80% LT = 8 ETH boundary; debt = 8 ETH => HF = 1.0
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 8_000e18);

    assertEq(dp.getHealthFactor(USER), RAY);
  }

  function test_getHealthFactor_feesIncludedInDenominator() external {
    // debt 6 ETH + fees 1 ETH => denom 7; HF = 8/7
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 6_000e18);
    pool.setUserOriginationFee(USER, DAI_ASSET, 1_000e18);

    assertApproxEqAbs(dp.getHealthFactor(USER), 1_142_857_142_857_142_857_142_857_142, 5);
  }

  function test_getHealthFactor_priceDropPushesBelow1() external {
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 7_500e18);

    assertGt(dp.getHealthFactor(USER), RAY);

    oracle.setAssetPrice(ETH_ASSET, 0.5e18);
    assertLt(dp.getHealthFactor(USER), RAY);
  }

  // === getUserAccountData — 7-value return tuple
  function test_getUserAccountData_returnsTotalFeesETH() external {
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 5_000e18);
    pool.setUserOriginationFee(USER, DAI_ASSET, 500e18); // 0.5 ETH fees

    (, , uint256 totalFeesETH, , , , ) = dp.getUserAccountData(USER);

    // 500 DAI * 0.001 ETH/DAI = 0.5 ETH
    assertEq(totalFeesETH, 0.5 ether);
  }

  function test_getUserAccountData_availableBorrowsFlooredAtZero() external {
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 1 ether);
    // max borrow = 0.75 ETH; debt+fees = 0.8 ETH => floor to 0
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 700e18);
    pool.setUserOriginationFee(USER, DAI_ASSET, 100e18);

    (, , , uint256 availableBorrowsETH, , , ) = dp.getUserAccountData(USER);
    assertEq(availableBorrowsETH, 0);
  }

  function test_getUserAccountData_consistentWithGetHealthFactor() external {
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 6_000e18);

    (, , , , , , uint256 hfFromAccountData) = dp.getUserAccountData(USER);
    uint256 hfDirect = dp.getHealthFactor(USER);

    assertEq(hfFromAccountData, hfDirect);
  }

  // === Weighted averages
  function test_getAverageLtv_disabledCollateralExcluded() external {
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 5 ether);
    pool.setUserUsingReserveAsCollateral(USER, DAI_ASSET, false);
    pool.setUserCollateralBalance(USER, DAI_ASSET, 5_000e18);

    assertEq(dp.getAverageLtv(USER), 7500);
    assertEq(dp.getAverageLiquidationThreshold(USER), 8000);
  }

  function test_getAverageLtv_multiAssetEqualWeights_correct() external {
    // ETH: 5 ETH value, LTV 75, LT 80
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 5 ether);
    // DAI: 5 ETH value, LTV 80, LT 85
    pool.setUserUsingReserveAsCollateral(USER, DAI_ASSET, true);
    pool.setUserCollateralBalance(USER, DAI_ASSET, 5_000e18);

    assertEq(dp.getAverageLtv(USER), 7750);
    assertEq(dp.getAverageLiquidationThreshold(USER), 8250);
  }

  // === Decimal normalisation
  function test_toEthValue_usdcSixDecimals_correct() external {
    // 2,000 USDC (6 dec) at 0.001 ETH/USDC = 2 ETH collateral
    pool.setUserUsingReserveAsCollateral(USER, USDC_ASSET, true);
    pool.setUserCollateralBalance(USER, USDC_ASSET, 2_000e6);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 1_000e18);

    // HF = (2 * 0.75) / 1 = 1.5
    assertApproxEqAbs(dp.getHealthFactor(USER), 1_500_000_000_000_000_000_000_000_000, 5);
  }

  // === getCompoundedBorrowBalance
  function test_getCompoundedBorrowBalance_returnsPoolValue() external {
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 5_000e18);
    assertEq(dp.getCompoundedBorrowBalance(USER, DAI_ASSET), 5_000e18);
  }

  function test_getCompoundedBorrowBalance_noDebt_returnsZero() external view {
    assertEq(dp.getCompoundedBorrowBalance(USER, DAI_ASSET), 0);
  }

  // === Reserve config bounds
  function test_getHealthFactor_ltvAboveBPS_reverts() external {
    // Misconfigured reserve: LTV > 10000
    pool.setReserveConfiguration(ETH_ASSET, 15000, 8000);
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 1 ether);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 100e18);

    vm.expectRevert('LDP: INVALID_LTV');
    dp.getHealthFactor(USER);
  }

  function test_getHealthFactor_ltAboveBPS_reverts() external {
    pool.setReserveConfiguration(ETH_ASSET, 7500, 15000);
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 1 ether);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 100e18);

    vm.expectRevert('LDP: INVALID_LT');
    dp.getHealthFactor(USER);
  }

  // === calculateHealthFactor — pure function edge cases
  function test_calculateHealthFactor_zeroDebt_returnsMax() external view {
    assertEq(dp.calculateHealthFactor(10 ether, 0, 0, 8000), type(uint256).max);
  }

  function test_calculateHealthFactor_zeroCollateral_returnsZero() external view {
    assertEq(dp.calculateHealthFactor(0, 5 ether, 0, 8000), 0);
  }

  function test_calculateHealthFactor_zeroThreshold_returnsZero() external view {
    assertEq(dp.calculateHealthFactor(10 ether, 5 ether, 0, 0), 0);
  }

  // === Fuzz tests
  /// @dev HF must be max when there is no debt, regardless of collateral.
  function testFuzz_calculateHealthFactor_noDebt_alwaysMax(
    uint256 collateral,
    uint256 threshold
  ) external view {
    threshold = bound(threshold, 0, BPS);
    assertEq(dp.calculateHealthFactor(collateral, 0, 0, threshold), type(uint256).max);
  }

  /// @dev HF must be zero when collateral is zero and debt is positive.
  function testFuzz_calculateHealthFactor_noCollateral_alwaysZero(
    uint256 debt,
    uint256 fees,
    uint256 threshold
  ) external view {
    debt = bound(debt, 1, type(uint128).max);
    fees = bound(fees, 0, type(uint128).max - debt);
    threshold = bound(threshold, 0, BPS);
    assertEq(dp.calculateHealthFactor(0, debt, fees, threshold), 0);
  }

  /// @dev HF must be >= 1 ray when collateral * LT >= debt + fees.
  function testFuzz_calculateHealthFactor_aboveThreshold_hfAboveOne(
    uint128 collateral,
    uint128 debt,
    uint256 threshold
  ) external view {
    // Ensure collateral * threshold >= debt (no fees for simplicity).
    threshold = bound(threshold, 1, BPS);
    collateral = uint128(bound(collateral, 1, type(uint64).max));
    // debt <= collateral * threshold / BPS => HF >= 1
    uint256 maxDebt = (uint256(collateral) * threshold) / BPS;
    vm.assume(maxDebt > 0);
    debt = uint128(bound(debt, 1, maxDebt));

    uint256 hf = dp.calculateHealthFactor(collateral, debt, 0, threshold);
    assertGe(hf, RAY);
  }

  /// @dev availableBorrowsETH must never underflow (always >= 0).
  function testFuzz_getUserAccountData_availableBorrowsNeverUnderflows(
    uint128 collateralAmt,
    uint128 debtAmt,
    uint128 feeAmt
  ) external {
    collateralAmt = uint128(bound(collateralAmt, 0, 1_000_000 ether));
    debtAmt = uint128(bound(debtAmt, 0, 1_000_000_000e18));
    feeAmt = uint128(bound(feeAmt, 0, 1_000_000_000e18));

    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, collateralAmt);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, debtAmt);
    pool.setUserOriginationFee(USER, DAI_ASSET, feeAmt);

    (, , , uint256 available, , , ) = dp.getUserAccountData(USER);
    // Must never revert and must always be >= 0 (uint256 guarantees this,
    // but we verify no revert path exists).
    assertGe(available, 0);
  }

  // === validateBorrow — Deliverable 3.5

  uint256 internal constant STABLE = 1;
  uint256 internal constant VARIABLE = 2;

  /// @dev Helper: set up a standard borrowable position.
  ///      10 ETH collateral, 6 ETH debt already, 4 ETH available.
  function _setupBorrowPosition() internal {
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 6_000e18);
    // Available liquidity: 100,000 DAI
    pool.setReserveAvailableLiquidity(DAI_ASSET, 100_000e18);
  }

  // === Check 1: reserve active + borrowing enabled
  function test_validateBorrow_inactiveReserve_reverts() external {
    _setupBorrowPosition();
    pool.setReserveFlags(DAI_ASSET, false, true, false);

    vm.expectRevert('LDP: RESERVE_INACTIVE');
    dp.validateBorrow(USER, DAI_ASSET, 100e18, VARIABLE);
  }

  function test_validateBorrow_borrowingDisabled_reverts() external {
    _setupBorrowPosition();
    pool.setReserveFlags(DAI_ASSET, true, false, false);

    vm.expectRevert('LDP: BORROWING_DISABLED');
    dp.validateBorrow(USER, DAI_ASSET, 100e18, VARIABLE);
  }

  // === Check 2: stable rate enabled
  function test_validateBorrow_stableDisabled_stableMode_reverts() external {
    _setupBorrowPosition();
    // stableBorrowingEnabled = false (default from addReserve)

    vm.expectRevert('LDP: STABLE_BORROWING_DISABLED');
    dp.validateBorrow(USER, DAI_ASSET, 100e18, STABLE);
  }

  function test_validateBorrow_stableDisabled_variableMode_succeeds() external {
    _setupBorrowPosition();
    // Variable mode should not care about stable flag — no revert expected.
    dp.validateBorrow(USER, DAI_ASSET, 100e18, VARIABLE);
  }

  // === Check 3: available liquidity
  function test_validateBorrow_exceedsAvailableLiquidity_reverts() external {
    _setupBorrowPosition();
    pool.setReserveAvailableLiquidity(DAI_ASSET, 50e18); // only 50 DAI available

    vm.expectRevert('LDP: INSUFFICIENT_LIQUIDITY');
    dp.validateBorrow(USER, DAI_ASSET, 100e18, VARIABLE);
  }

  // === Check 4: collateral capacity
  function test_validateBorrow_insufficientCollateral_reverts() external {
    _setupBorrowPosition();
    // User has 10 ETH collateral, LTV 75% = 7.5 ETH max borrow.
    // Already borrowed 6 ETH worth. Available = 1.5 ETH = 1500 DAI.
    // Trying to borrow 2000 DAI (2 ETH) — exceeds capacity.

    vm.expectRevert('LDP: COLLATERAL_INSUFFICIENT');
    dp.validateBorrow(USER, DAI_ASSET, 2_000e18, VARIABLE);
  }

  // === Check 5: post-borrow health factor
  function test_validateBorrow_postBorrowHFBelowOne_reverts() external {
    // LTV=85%, LT=80%. 10 ETH collateral.
    // LTV capacity = 10 * 85% = 8.5 ETH. LT boundary = 10 * 80% = 8 ETH.
    // Existing debt = 7.9 ETH. Available (LTV) = 8.5 - 7.9 = 0.6 ETH.
    // Borrow 500 DAI (0.5 ETH) → within LTV capacity (check 4 passes).
    // Post-borrow debt = 8.4 ETH > LT boundary 8 ETH → HF < 1 → check 5 fires.
    pool.setReserveConfiguration(ETH_ASSET, 8500, 8000);
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 7_900e18);
    pool.setReserveAvailableLiquidity(DAI_ASSET, 100_000e18);

    vm.expectRevert('LDP: HF_BELOW_ONE');
    dp.validateBorrow(USER, DAI_ASSET, 500e18, VARIABLE);
  }

  function test_validateBorrow_postBorrowHFExactlyOne_succeeds() external {
    // LTV=85%, LT=80%. 10 ETH collateral. LT boundary = 8 ETH.
    pool.setReserveConfiguration(ETH_ASSET, 8500, 8000);
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);
    // Existing debt: 7.9 ETH. Borrow exactly 100 DAI (0.1 ETH) → total 8 ETH → HF = 1.
    pool.setUserCompoundedBorrowBalance(USER, DAI_ASSET, 7_900e18);
    pool.setReserveAvailableLiquidity(DAI_ASSET, 100_000e18);

    // Should not revert — HF == 1 ray is exactly acceptable.
    dp.validateBorrow(USER, DAI_ASSET, 100e18, VARIABLE);
  }

  // === Check 6: stable rate anti-manipulation
  function test_validateBorrow_stableManipulation_reverts() external {
    // Enable stable borrowing on DAI.
    pool.setReserveFlags(DAI_ASSET, true, true, true);
    pool.setReserveAvailableLiquidity(DAI_ASSET, 100_000e18);

    // User deposits 5 ETH as collateral AND 5,000 DAI as collateral.
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 5 ether);
    pool.setUserUsingReserveAsCollateral(USER, DAI_ASSET, true);
    pool.setUserCollateralBalance(USER, DAI_ASSET, 5_000e18); // 5 ETH value

    // Tries to borrow 100 DAI (0.1 ETH) from DAI reserve while depositing
    // 5,000 DAI (5 ETH) in the same reserve — collateral > borrow amount.
    vm.expectRevert('LDP: STABLE_BORROW_MANIPULATION');
    dp.validateBorrow(USER, DAI_ASSET, 100e18, STABLE);
  }

  function test_validateBorrow_stableNoManipulation_succeeds() external {
    // Enable stable borrowing on DAI.
    pool.setReserveFlags(DAI_ASSET, true, true, true);
    pool.setReserveAvailableLiquidity(DAI_ASSET, 100_000e18);

    // User only has ETH as collateral — no DAI collateral in the borrow reserve.
    pool.setUserUsingReserveAsCollateral(USER, ETH_ASSET, true);
    pool.setUserCollateralBalance(USER, ETH_ASSET, 10 ether);

    // Borrow 1,000 DAI (1 ETH) stable — no manipulation possible.
    dp.validateBorrow(USER, DAI_ASSET, 1_000e18, STABLE);
  }

  // === Happy path
  function test_validateBorrow_happyPath_variable_succeeds() external {
    _setupBorrowPosition();
    // Borrow 500 DAI (0.5 ETH) — well within capacity, HF stays healthy.
    dp.validateBorrow(USER, DAI_ASSET, 500e18, VARIABLE);
  }

  // === Input guards
  function test_validateBorrow_zeroUser_reverts() external {
    vm.expectRevert('LDP: INVALID_USER');
    dp.validateBorrow(address(0), DAI_ASSET, 100e18, VARIABLE);
  }

  function test_validateBorrow_zeroReserve_reverts() external {
    vm.expectRevert('LDP: INVALID_RESERVE');
    dp.validateBorrow(USER, address(0), 100e18, VARIABLE);
  }

  function test_validateBorrow_zeroAmount_reverts() external {
    vm.expectRevert('LDP: ZERO_AMOUNT');
    dp.validateBorrow(USER, DAI_ASSET, 0, VARIABLE);
  }

  function test_validateBorrow_invalidRateMode_reverts() external {
    vm.expectRevert('LDP: INVALID_RATE_MODE');
    dp.validateBorrow(USER, DAI_ASSET, 100e18, 99);
  }

  // === Invariant tests
  /// @dev Invariant: HF == max iff totalDebt + totalFees == 0.
  function invariant_healthFactorMaxOnlyWhenNoDebt() external view {
    uint256 hf = dp.getHealthFactor(USER);
    uint256 debt = dp.getCompoundedBorrowBalance(USER, DAI_ASSET) +
      dp.getCompoundedBorrowBalance(USER, ETH_ASSET) +
      dp.getCompoundedBorrowBalance(USER, USDC_ASSET);

    if (hf == type(uint256).max) {
      assertEq(debt, 0);
    }
  }

  /// @dev Invariant: availableBorrowsETH is always >= 0 (no underflow).
  function invariant_availableBorrowsNonNegative() external view {
    (, , , uint256 available, , , ) = dp.getUserAccountData(USER);
    assertGe(available, 0);
  }
}
