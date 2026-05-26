// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {WadRayMath}                 from "./WadRayMath.sol";
import {LendingPoolCore}            from "./LendingPoolCore.sol";
import {IPriceOracle}               from "./interfaces/IPriceOracle.sol";
import {IAToken}                    from "./interfaces/IAToken.sol";
import {ILendingPoolDataProvider}   from "./interfaces/ILendingPoolDataProvider.sol";
import {IStableDebtToken}           from "./interfaces/IStableDebtToken.sol";

/**
 * @title LiquidationManager
 * @notice Validation and amount computation for the liquidation flow.
 *
 * Architecture
 * ────────────
 * This contract is called from LendingPool.liquidationCall() only.
 * It validates all conditions and returns computed amounts.
 * LendingPool performs all LendingPoolCore state writes because
 * those functions are onlyLendingPool.
 *
 * Call flow:
 *   Liquidator
 *     → LendingPool.liquidationCall()
 *         → core.updateReserveIndexes()             [indexes current before any reads]
 *         → LiquidationManager.executeLiquidation() [validate + compute — no state writes]
 *         → core.updateTotalLiquidity(+accruedInterest)  [interest credited to depositors]
 *         → core.updateTotalXxxBorrows(-debtCovered)     [borrow total reduced]
 *         → core.updateTotalLiquidity(+debtCovered)      [repayment added to pool]
 *         → IStableDebtToken.burn() / IVariableDebtToken.burn()  [user balance zeroed]
 *         → IAToken.transferOnLiquidation()          [collateral moves to liquidator]
 *         → IERC20.transferFrom(liquidator → core)   [debt repayment received]
 *
 * Bonus encoding
 * ──────────────
 * ReserveConfiguration stores the liquidation bonus as the full multiplier:
 *   10500 → 105% → 5% discount above market price.
 * Formula: collateralAmount = debtValueETH × bonus / (collateralPrice × 10000)
 */
contract LiquidationManager {
    using WadRayMath for uint256;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error OnlyLendingPool();
    error HealthFactorNotBelowThreshold();
    error CollateralNotEnabledForUser();
    error InvalidOraclePrice(address asset);
    error OracleNotSet();
    error NoBorrowBalance();

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event LiquidationCall(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        uint256 debtAmountCovered,
        uint256 collateralAmountReceived,
        address liquidator,
        uint256 timestamp
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Immutable state
    // ─────────────────────────────────────────────────────────────────────────

    LendingPoolCore          public immutable core;
    ILendingPoolDataProvider public immutable dataProvider;

    /// @dev Only LendingPool may call executeLiquidation().
    address public immutable lendingPool;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev 50% close factor — liquidation can cover at most half the compounded debt.
    uint256 private constant CLOSE_FACTOR_PERCENT = 50;

    /// @dev Bonus denominator — bonus stored as e.g. 10500 meaning 105%.
    uint256 private constant BONUS_DENOMINATOR = 10_000;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address _core,
        address _dataProvider,
        address _lendingPool
    ) {
        core         = LendingPoolCore(_core);
        dataProvider = ILendingPoolDataProvider(_dataProvider);
        lendingPool  = _lendingPool;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Returned to LendingPool after all validation and computation.
     *      LendingPool uses these values to write state and execute transfers.
     */
    struct LiquidationResult {
        uint256 actualDebtToCover;        // capped at 50% or by collateral availability
        uint256 collateralAmountToSeize;  // aToken units to transfer to liquidator
        uint256 accruedInterest;          // interest to credit to reserve liquidity before borrow reduction
        bool    isStableBorrow;           // which borrow bucket to reduce
    }

    /// @dev Intermediate values — struct avoids stack-too-deep.
    struct LiquidationVars {
        uint256 collateralPrice;
        uint256 debtPrice;
        uint256 collateralDecimals;
        uint256 debtDecimals;
        uint256 liquidationBonus;
        uint256 compoundedDebt;
        uint256 principalDebt;
        uint256 accruedInterest;
        uint256 collateralAmount;
        uint256 maxCollateral;
        bool    isStableBorrow;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Main entry point
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Validates and computes all amounts for a liquidation.
     * @dev    Pure computation — does NOT write any state.
     *         LendingPool performs all state mutations after this returns.
     *
     * @param collateralAsset  The asset the liquidator will receive
     * @param debtAsset        The asset the liquidator will repay
     * @param user             The under-collateralised borrower
     * @param debtToCover      Requested repayment amount (in debtAsset token units)
     * @param liquidator       The address calling LendingPool — used in the event
     *
     * @return result  Validated amounts for LendingPool to execute
     */
    function executeLiquidation(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        address liquidator
    ) external returns (LiquidationResult memory result) {
        if (msg.sender != lendingPool) revert OnlyLendingPool();

        LiquidationVars memory vars;

        // ── 1. Oracle — read address from Core (governance-updatable) ─────────
        address oracleAddr = core.priceOracle();
        if (oracleAddr == address(0)) revert OracleNotSet();

        vars.collateralPrice = _getSafePrice(oracleAddr, collateralAsset);
        vars.debtPrice       = _getSafePrice(oracleAddr, debtAsset);

        // ── 2. Health factor — must be below 1 RAY ────────────────────────────
        if (dataProvider.getHealthFactor(user) >= WadRayMath.RAY)
            revert HealthFactorNotBelowThreshold();

        // ── 3. Collateral eligibility ─────────────────────────────────────────
        if (!dataProvider.isUserUsingReserveAsCollateral(user, collateralAsset))
            revert CollateralNotEnabledForUser();

        // ── 4. Determine borrow mode ──────────────────────────────────────────
        // A user holds either stable OR variable debt on a reserve, not both.
        vars.isStableBorrow =
            IStableDebtToken(core.getReserveStableDebtTokenAddress(debtAsset))
                .balanceOf(user) > 0;

        // ── 5. Compounded debt + 50% cap ──────────────────────────────────────
        vars.compoundedDebt = dataProvider.getCompoundedBorrowBalance(user, debtAsset);
        if (vars.compoundedDebt == 0) revert NoBorrowBalance();

        uint256 maxDebt = vars.compoundedDebt * CLOSE_FACTOR_PERCENT / 100;
        if (debtToCover > maxDebt) debtToCover = maxDebt;

        // ── 6. Accrued interest = compounded − principal ──────────────────────
        //
        // The PRD requires this to be credited to reserve liquidity BEFORE the
        // borrow total is reduced (Deliverable 2.1 requirement 7).
        // principalBalanceOf returns the stored amount before interest accrual.
        vars.principalDebt =
            vars.isStableBorrow
                ? IStableDebtToken(core.getReserveStableDebtTokenAddress(debtAsset))
                    .principalBalanceOf(user)
                : _getVariablePrincipal(debtAsset, user);

        vars.accruedInterest =
            vars.compoundedDebt > vars.principalDebt
                ? vars.compoundedDebt - vars.principalDebt
                : 0;

        // ── 7. Collateral amount with bonus (overflow-safe) ───────────────────
        //
        // Previous implementation multiplied 4 large numbers before dividing,
        // risking overflow on large positions.  Breaking into three steps keeps
        // each intermediate within safe uint256 bounds for any realistic amount.
        //
        // Step A: ETH value of the debt to cover
        //   debtValueETH = debtToCover × debtPrice / 10^debtDecimals
        // Step B: apply the liquidation bonus
        //   debtValueWithBonus = debtValueETH × liquidationBonus / BONUS_DENOMINATOR
        // Step C: convert to collateral token units
        //   collateralAmount = debtValueWithBonus × 10^collateralDecimals / collateralPrice

        vars.debtDecimals       = core.getReserveDecimals(debtAsset);
        vars.collateralDecimals = core.getReserveDecimals(collateralAsset);
        vars.liquidationBonus   = core.getReserveLiquidationBonus(collateralAsset);

        vars.collateralAmount = _calculateCollateralAmount(
            debtToCover,
            vars.debtPrice,
            vars.debtDecimals,
            vars.collateralPrice,
            vars.collateralDecimals,
            vars.liquidationBonus
        );

        // ── 8. Cap collateral at borrower's actual aToken balance ─────────────
        vars.maxCollateral =
            IAToken(core.getReserveATokenAddress(collateralAsset)).balanceOf(user);

        if (vars.collateralAmount > vars.maxCollateral) {
            vars.collateralAmount = vars.maxCollateral;
            // Proportionally reduce debt so accounting stays consistent
            debtToCover = _calculateDebtFromCollateral(
                vars.collateralAmount,
                vars.collateralPrice,
                vars.collateralDecimals,
                vars.debtPrice,
                vars.debtDecimals,
                vars.liquidationBonus
            );
        }

        emit LiquidationCall(
            collateralAsset,
            debtAsset,
            user,
            debtToCover,
            vars.collateralAmount,
            liquidator,           // passed in from LendingPool — not tx.origin
            block.timestamp
        );

        result.actualDebtToCover       = debtToCover;
        result.collateralAmountToSeize = vars.collateralAmount;
        result.accruedInterest         = vars.accruedInterest;
        result.isStableBorrow          = vars.isStableBorrow;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _getSafePrice(address oracleAddr, address asset) internal view returns (uint256 price) {
        price = IPriceOracle(oracleAddr).getAssetPrice(asset);
        if (price == 0) revert InvalidOraclePrice(asset);
    }

    /// @dev Returns the pre-interest principal for a variable-rate borrow.
    ///      principalBalanceOf on the VariableDebtToken returns the original borrowed amount.
    function _getVariablePrincipal(address debtAsset, address user) internal view returns (uint256) {
        // Import is avoided by casting; IVariableDebtToken.principalBalanceOf is
        // identical in ABI to IStableDebtToken.principalBalanceOf.
        return IStableDebtToken(core.getReserveVariableDebtTokenAddress(debtAsset))
            .principalBalanceOf(user);
    }

    /**
     * @dev Converts debt amount → collateral amount with bonus.
     *      Three sequential operations keep each intermediate safely within uint256.
     *
     *   Step A: debtValueETH      = debtAmount × debtPrice        / 10^debtDecimals
     *   Step B: debtValueBonused  = debtValueETH × bonus          / BONUS_DENOMINATOR
     *   Step C: collateralAmount  = debtValueBonused × 10^colDec  / collateralPrice
     */
    function _calculateCollateralAmount(
        uint256 debtAmount,
        uint256 debtPrice,
        uint256 debtDecimals,
        uint256 collateralPrice,
        uint256 collateralDecimals,
        uint256 liquidationBonus
    ) internal pure returns (uint256) {
        uint256 debtValueETH     = (debtAmount * debtPrice) / (10 ** debtDecimals);
        uint256 debtValueBonused = (debtValueETH * liquidationBonus) / BONUS_DENOMINATOR;
        return (debtValueBonused * (10 ** collateralDecimals)) / collateralPrice;
    }

    /**
     * @dev Inverse of _calculateCollateralAmount — used when collateral is capped.
     *
     *   Step A: colValueETH  = colAmount × colPrice          / 10^colDecimals
     *   Step B: debtValueETH = colValueETH × BONUS_DENOM     / bonus
     *   Step C: debtAmount   = debtValueETH × 10^debtDecimals / debtPrice
     */
    function _calculateDebtFromCollateral(
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint256 collateralDecimals,
        uint256 debtPrice,
        uint256 debtDecimals,
        uint256 liquidationBonus
    ) internal pure returns (uint256) {
        uint256 colValueETH  = (collateralAmount * collateralPrice) / (10 ** collateralDecimals);
        uint256 debtValueETH = (colValueETH * BONUS_DENOMINATOR) / liquidationBonus;
        return (debtValueETH * (10 ** debtDecimals)) / debtPrice;
    }
}
