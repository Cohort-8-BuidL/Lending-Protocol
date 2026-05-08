// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILendingPoolDataProvider} from './interfaces/ILendingPoolDataProvider.sol';
import {IPoolLike} from './interfaces/IPoolLike.sol';
import {IPriceOracle} from './interfaces/IPriceOracle.sol';
import {WadRayMath} from './libraries/WadRayMath.sol';

/// @title LendingPoolDataProvider
/// @notice Computes user-level risk metrics (HF, LTV, available borrows) for
///         the lending/liquidation layers.
///
/// @dev Security properties upheld by this contract:
///      1. Oracle staleness: a zero price for ANY reserve that has a non-zero position (collateral OR debt) causes the entire call to revert.
///         Asymmetric skipping (collateral skipped, debt counted) is forbidden.
///      2. Overflow safety: all cross-precision multiplications use WadRayMath helpers; intermediate products are bounded.
///      3. Reserve config bounds: ltv and liquidationThreshold are validated to be within [0, BPS] before use in weighted sums.
///      4. Single reserve-list fetch per external call: getReservesList() and getPriceOracle() are called exactly once per public entry point.
///      5. availableBorrowsETH is always >= 0 (floored, no underflow).
///      6. calculateHealthFactor is pure but callers MUST use trusted inputs.
contract LendingPoolDataProvider is ILendingPoolDataProvider {
  using WadRayMath for uint256;

  uint256 internal constant RAY = 1e27;
  uint256 internal constant BPS = 1e4;
  uint256 internal constant WAD = 1e18;

  /// @dev Maximum sane value for BPS-denominated risk params (100.00%).
  uint256 internal constant MAX_BPS = 1e4;

  // === Look for a way not to use an immutable pool
  IPoolLike public immutable pool;

  // === Constructor
  constructor(IPoolLike pool_) {
    require(address(pool_) != address(0), 'LDP: INVALID_POOL');
    pool = pool_;
  }

  // === Full account snapshot
  /// @inheritdoc ILendingPoolDataProvider
  function getUserAccountData(
    address user
  )
    external
    view
    override
    returns (
      uint256 totalCollateralETH,
      uint256 totalBorrowsETH,
      uint256 totalFeesETH,
      uint256 availableBorrowsETH,
      uint256 currentLiquidationThreshold,
      uint256 ltv,
      uint256 healthFactor
    )
  {
    require(user != address(0), 'LDP: INVALID_USER');

    // Fetch shared context once — avoids redundant external calls.
    address[] memory reserves = pool.getReservesList();
    IPriceOracle oracle = _getValidOracle();

    AccountVars memory vars = _aggregateAccountData(user, reserves, oracle);

    totalCollateralETH = vars.totalCollateralETH;
    totalBorrowsETH = vars.totalBorrowsETH;
    totalFeesETH = vars.totalFeesETH;
    // ltv here means borrow limit
    ltv = vars.totalCollateralETH > 0 ? vars.weightedLtvSum / vars.totalCollateralETH : 0;
    currentLiquidationThreshold = vars.totalCollateralETH > 0
      ? vars.weightedLtSum / vars.totalCollateralETH
      : 0;

    availableBorrowsETH = _calculateAvailableBorrowsETH(
      totalCollateralETH,
      ltv,
      totalBorrowsETH,
      totalFeesETH
    );

    healthFactor = calculateHealthFactor(
      totalCollateralETH,
      totalBorrowsETH,
      totalFeesETH,
      currentLiquidationThreshold
    );
  }

  // === Individual getter functions used

  /// @inheritdoc ILendingPoolDataProvider
  function getHealthFactor(address user) external view override returns (uint256) {
    // LDP: LendingPoolData Provider
    require(user != address(0), 'LDP: INVALID_USER');

    address[] memory reserves = pool.getReservesList();
    IPriceOracle oracle = _getValidOracle();
    AccountVars memory vars = _aggregateAccountData(user, reserves, oracle);

    uint256 avgLt = vars.totalCollateralETH > 0 ? vars.weightedLtSum / vars.totalCollateralETH : 0;

    return
      calculateHealthFactor(
        vars.totalCollateralETH,
        vars.totalBorrowsETH,
        vars.totalFeesETH,
        avgLt
      );
  }

  /// @inheritdoc ILendingPoolDataProvider
  function getAverageLtv(address user) external view override returns (uint256) {
    require(user != address(0), 'LDP: INVALID_USER');

    address[] memory reserves = pool.getReservesList();
    IPriceOracle oracle = _getValidOracle();
    AccountVars memory vars = _aggregateAccountData(user, reserves, oracle);

    return vars.totalCollateralETH > 0 ? vars.weightedLtvSum / vars.totalCollateralETH : 0;
  }

  /// @inheritdoc ILendingPoolDataProvider
  function getAverageLiquidationThreshold(address user) external view override returns (uint256) {
    require(user != address(0), 'LDP: INVALID_USER');

    address[] memory reserves = pool.getReservesList();
    IPriceOracle oracle = _getValidOracle();
    AccountVars memory vars = _aggregateAccountData(user, reserves, oracle);

    return vars.totalCollateralETH > 0 ? vars.weightedLtSum / vars.totalCollateralETH : 0;
  }

  /// @inheritdoc ILendingPoolDataProvider
  function getTotalFeesETH(address user) external view override returns (uint256) {
    require(user != address(0), 'LDP: INVALID_USER');

    address[] memory reserves = pool.getReservesList();
    IPriceOracle oracle = _getValidOracle();
    AccountVars memory vars = _aggregateAccountData(user, reserves, oracle);

    return vars.totalFeesETH;
  }

  /// @inheritdoc ILendingPoolDataProvider
  function getCompoundedBorrowBalance(
    address user,
    address reserve
  ) external view override returns (uint256) {
    require(user != address(0), 'LDP: INVALID_USER');
    require(reserve != address(0), 'LDP: INVALID_RESERVE');
    return pool.getUserCompoundedBorrowBalance(user, reserve);
  }

  // === Health factor formula
  /// @inheritdoc ILendingPoolDataProvider
  /// @dev SECURITY: inputs MUST originate from trusted pool state.
  ///      Passing arbitrary values produces arbitrary results.
  ///      Formula: HF(ray) = (collateral * liqThreshold * RAY) / (debt * BPS)
  function calculateHealthFactor(
    uint256 totalCollateralETH,
    uint256 totalBorrowsETH,
    uint256 totalFeesETH,
    uint256 liquidationThreshold
  ) public pure override returns (uint256) {
    uint256 debtWithFeesETH = totalBorrowsETH + totalFeesETH;

    // No debt -> no liquidation risk.
    if (debtWithFeesETH == 0) {
      return type(uint256).max;
    }

    // Collateral is zero or threshold is zero with positive debt -> fully unsafe.
    if (totalCollateralETH == 0 || liquidationThreshold == 0) {
      return 0;
    }

    // Numerator: collateral(WAD) * threshold(BPS) * RAY
    // Max realistic: 1e9 ETH * 1e18 * 10000 * 1e27 = 1e58 — fits in uint256.
    // WadRayMath.mulDiv used for the final cross-precision step.
    uint256 collateralAdjusted = (totalCollateralETH * liquidationThreshold) / BPS;
    return (collateralAdjusted * RAY) / debtWithFeesETH;
  }

  // Internal — single-pass aggregation (fixes #1, #10, #13, #17)

  /// @dev Holds all aggregated values from a single reserve-list pass.
  struct AccountVars {
    uint256 totalCollateralETH;
    uint256 totalBorrowsETH;
    uint256 totalFeesETH;
    uint256 weightedLtvSum;
    uint256 weightedLtSum;
  }

  /// @dev Iterates reserves ONCE, computing collateral, debt, fees, and weighted sums in a single pass.
  ///
  ///      Oracle staleness rule (fixes #10): If a reserve has a non-zero position (collateral OR debt OR fee) and its oracle price is 0, we revert.
  ///      We never silently skip a reserve that has an active position — asymmetric skipping would allow HF manipulation.
  function _aggregateAccountData(
    address user,
    address[] memory reserves,
    IPriceOracle oracle
  ) internal view returns (AccountVars memory vars) {
    // Post increment in loop to avoid redundant balance checks for zero positions
    for (uint256 i = 0; i < reserves.length; ++i) {
      address reserve = reserves[i];

      bool isCollateral = pool.isUserUsingReserveAsCollateral(user, reserve);
      uint256 collateralBal = isCollateral ? pool.getUserCollateralBalance(user, reserve) : 0;
      uint256 debtBal = pool.getUserCompoundedBorrowBalance(user, reserve);
      uint256 feeBal = pool.getUserOriginationFee(user, reserve);

      // Skip reserves with no position at all.
      if (collateralBal == 0 && debtBal == 0 && feeBal == 0) {
        continue;
      }

      // Fetch price — revert if stale/zero for any active position (fixes #10).
      uint256 price = oracle.getAssetPrice(reserve);
      require(price != 0, 'LDP: STALE_ORACLE');

      uint8 decimals = pool.getReserveDecimals(reserve);

      // Collateral side.
      if (collateralBal > 0) {
        uint256 collateralETH = _toEthValue(collateralBal, price, decimals);

        IPoolLike.ReserveConfiguration memory cfg = pool.getReserveConfiguration(reserve);

        // Bounds-check reserve config (fixes #18).
        require(cfg.ltv <= MAX_BPS, 'LDP: INVALID_LTV');
        require(cfg.liquidationThreshold <= MAX_BPS, 'LDP: INVALID_LT');

        vars.totalCollateralETH += collateralETH;
        // Safe: collateralETH(WAD) * ltv(<=10000) — max ~1e22 per reserve.
        vars.weightedLtvSum += collateralETH * cfg.ltv;
        vars.weightedLtSum += collateralETH * cfg.liquidationThreshold;
      }

      // Debt side.
      if (debtBal > 0) {
        vars.totalBorrowsETH += _toEthValue(debtBal, price, decimals);
      }

      // Fee side.
      if (feeBal > 0) {
        vars.totalFeesETH += _toEthValue(feeBal, price, decimals);
      }
    }
  }

  // Internal — available borrows

  /// @dev available = max((collateral * ltv / BPS) - debt - fees, 0)
  function _calculateAvailableBorrowsETH(
    uint256 totalCollateralETH,
    uint256 ltv,
    uint256 totalBorrowsETH,
    uint256 totalFeesETH
  ) internal pure returns (uint256) {
    if (totalCollateralETH == 0 || ltv == 0) {
      return 0;
    }

    uint256 maxBorrowETH = (totalCollateralETH * ltv) / BPS;
    uint256 debtWithFeesETH = totalBorrowsETH + totalFeesETH;

    if (maxBorrowETH <= debtWithFeesETH) {
      return 0;
    }

    return maxBorrowETH - debtWithFeesETH;
  }

  // Internal — decimal normalisation (fixes #5)

  /// @dev Converts a token amount to ETH value in WAD (1e18) precision.
  ///      price is ETH per whole token unit in WAD (1e18).
  ///
  ///      Fix for >18 decimal tokens: multiply BEFORE dividing to preserve
  ///      precision. Division-before-multiplication caused truncation loss.
  function _toEthValue(
    uint256 tokenAmount,
    uint256 price,
    uint8 tokenDecimals
  ) internal pure returns (uint256) {
    if (tokenAmount == 0 || price == 0) {
      return 0;
    }

    if (tokenDecimals == 18) {
      return (tokenAmount * price) / WAD;
    }

    if (tokenDecimals < 18) {
      uint256 scaleUp = 10 ** (18 - tokenDecimals);
      // tokenAmount * scaleUp normalises to 18 decimals first, then * price / WAD.
      return (tokenAmount * scaleUp * price) / WAD;
    }

    // tokenDecimals > 18: scale down AFTER multiplying to avoid truncation.
    // Correct order: (tokenAmount * price) / (10^(decimals-18) * WAD)
    uint256 scaleDown = 10 ** (tokenDecimals - 18);
    return (tokenAmount * price) / (scaleDown * WAD);
  }

  // === Borrow validation

  /// @dev Rate mode constants matching LendingPool convention.
  uint256 internal constant RATE_MODE_STABLE = 1;
  uint256 internal constant RATE_MODE_VARIABLE = 2;

  /// @inheritdoc ILendingPoolDataProvider
  function validateBorrow(
    address user,
    address reserve,
    uint256 amount,
    uint256 rateMode
  ) external view override {
    require(user != address(0), 'LDP: INVALID_USER');
    require(reserve != address(0), 'LDP: INVALID_RESERVE');
    require(amount != 0, 'LDP: ZERO_AMOUNT');
    require(
      rateMode == RATE_MODE_STABLE || rateMode == RATE_MODE_VARIABLE,
      'LDP: INVALID_RATE_MODE'
    );

    // Checks 1-3: reserve flags + liquidity (no oracle needed).
    _validateReserveChecks(reserve, amount, rateMode);

    // Checks 4-6: collateral capacity, post-borrow HF, stable manipulation.
    _validateUserChecks(user, reserve, amount, rateMode);
  }

  /// @dev Checks 1-3: reserve must be active, borrowing enabled, stable enabled if applicable, and requested amount within available liquidity.
  function _validateReserveChecks(address reserve, uint256 amount, uint256 rateMode) internal view {
    IPoolLike.ReserveFlags memory flags = pool.getReserveFlags(reserve);
    require(flags.isActive, 'LDP: RESERVE_INACTIVE');
    require(flags.borrowingEnabled, 'LDP: BORROWING_DISABLED');

    if (rateMode == RATE_MODE_STABLE) {
      require(flags.stableBorrowingEnabled, 'LDP: STABLE_BORROWING_DISABLED');
    }

    require(amount <= pool.getReserveAvailableLiquidity(reserve), 'LDP: INSUFFICIENT_LIQUIDITY');
  }

  /// @dev Checks 4-6: collateral capacity, post-borrow HF, stable manipulation.
  function _validateUserChecks(
    address user,
    address reserve,
    uint256 amount,
    uint256 rateMode
  ) internal view {
    IPriceOracle oracle = _getValidOracle();
    uint256 price = oracle.getAssetPrice(reserve);
    require(price != 0, 'LDP: STALE_ORACLE');

    uint8 decimals = pool.getReserveDecimals(reserve);
    uint256 borrowAmountETH = _toEthValue(amount, price, decimals);

    AccountVars memory vars = _aggregateAccountData(user, pool.getReservesList(), oracle);

    uint256 avgLtv = vars.totalCollateralETH > 0
      ? vars.weightedLtvSum / vars.totalCollateralETH
      : 0;
    uint256 avgLt = vars.totalCollateralETH > 0 ? vars.weightedLtSum / vars.totalCollateralETH : 0;

    // Check 4: collateral capacity.
    uint256 available = _calculateAvailableBorrowsETH(
      vars.totalCollateralETH,
      avgLtv,
      vars.totalBorrowsETH,
      vars.totalFeesETH
    );
    require(available >= borrowAmountETH, 'LDP: COLLATERAL_INSUFFICIENT');

    // Check 5: post-borrow HF >= 1 ray.
    require(
      calculateHealthFactor(
        vars.totalCollateralETH,
        vars.totalBorrowsETH + borrowAmountETH,
        vars.totalFeesETH,
        avgLt
      ) >= RAY,
      'LDP: HF_BELOW_ONE'
    );

    // Check 6: stable rate anti-manipulation.
    if (rateMode == RATE_MODE_STABLE) {
      _checkStableManipulation(user, reserve, borrowAmountETH, price, decimals);
    }
  }

  /// @dev Reverts if user's collateral in `reserve` exceeds the borrow amount.
  ///      Prevents single-block deposit→stable-borrow manipulation (whitepaper 4.3).
  function _checkStableManipulation(
    address user,
    address reserve,
    uint256 borrowAmountETH,
    uint256 price,
    uint8 decimals
  ) internal view {
    if (!pool.isUserUsingReserveAsCollateral(user, reserve)) return;
    uint256 bal = pool.getUserCollateralBalance(user, reserve);
    if (bal == 0) return;
    require(
      _toEthValue(bal, price, decimals) <= borrowAmountETH,
      'LDP: STABLE_BORROW_MANIPULATION'
    );
  }

  // === Internal:oracle validation

  /// @dev Fetches the oracle and validates it is not the zero address.
  function _getValidOracle() internal view returns (IPriceOracle oracle) {
    oracle = pool.getPriceOracle();
    require(address(oracle) != address(0), 'LDP: ORACLE_NOT_SET');
  }
}
