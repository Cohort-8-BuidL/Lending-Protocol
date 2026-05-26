// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard}          from "./utils/ReentrancyGuard.sol";
import {LendingPoolCore}          from "./LendingPoolCore.sol";
import {LiquidationManager}      from "./LiquidationManager.sol";
import {IAToken}                  from "./interfaces/IAToken.sol";
import {IStableDebtToken}         from "./interfaces/IStableDebtToken.sol";
import {IVariableDebtToken}       from "./interfaces/IVariableDebtToken.sol";
import {IERC20}                   from "./interfaces/IERC20.sol";

/**
 * @title LendingPool
 * @notice User-facing entry point for all protocol actions.
 *         The only contract authorised to write LendingPoolCore state.
 *
 * Only liquidationCall() is implemented here — the AMM team owns the rest
 * (deposit, borrow, repay, redeem, swapBorrowRateMode, flashLoan).
 */
contract LendingPool is ReentrancyGuard {

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error InvalidAmount();
    error TransferFailed();

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    LendingPoolCore    public immutable core;
    LiquidationManager public immutable liquidationManager;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _core, address _liquidationManager) {
        core               = LendingPoolCore(_core);
        liquidationManager = LiquidationManager(_liquidationManager);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // liquidationCall
    //
    // Execution order matches the PRD (Deliverable 2.1) exactly:
    //
    //  1. Update indexes on both reserves            [before any balance reads]
    //  2. Delegate to LiquidationManager             [validate + compute amounts]
    //  3. Credit accrued interest to reserve liquidity [PRD requirement 7]
    //  4. Reduce reserve borrow total                [by rate mode bucket]
    //  5. Add repaid principal back to reserve liquidity
    //  6. Burn borrower's debt tokens                [fix individual balance — Gap 2]
    //  7. Transfer collateral aTokens to liquidator  [INTERACTION — after all state]
    //  8. Pull debt repayment from liquidator        [INTERACTION — last]
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Liquidates an under-collateralised position.
     * @dev    Any external account may call this when the borrower's Hf < 1.
     *
     * @param collateralAsset  The reserve the liquidator receives as collateral
     * @param debtAsset        The reserve the liquidator repays
     * @param user             The borrower to liquidate
     * @param debtToCover      Amount of debt (in debtAsset units) the liquidator pays
     */
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover
    ) external nonReentrant {
        if (debtToCover == 0) revert InvalidAmount();

        // ── STEP 1: Refresh indexes — must precede all balance reads ──────────
        core.updateReserveIndexes(debtAsset);
        core.updateReserveIndexes(collateralAsset);

        // ── STEP 2: Validate and compute via LiquidationManager ──────────────
        // msg.sender (the liquidator) is forwarded explicitly — fixes the
        // tx.origin anti-pattern that was in the previous implementation.
        LiquidationManager.LiquidationResult memory result =
            liquidationManager.executeLiquidation(
                collateralAsset,
                debtAsset,
                user,
                debtToCover,
                msg.sender      // liquidator address — used in the emitted event
            );

        // ── STEP 3: Credit accrued interest to reserve liquidity (PRD req 7) ─
        // The interest that has grown since the user's last action is now
        // formally recognised as income to depositors before the borrow is cut.
        if (result.accruedInterest > 0) {
            core.updateTotalLiquidity(debtAsset, int256(result.accruedInterest));
        }

        // ── STEP 4: Reduce the correct borrow bucket ──────────────────────────
        if (result.isStableBorrow) {
            core.updateTotalStableBorrows(debtAsset, -int256(result.actualDebtToCover));
        } else {
            core.updateTotalVariableBorrows(debtAsset, -int256(result.actualDebtToCover));
        }

        // ── STEP 5: Repaid principal re-enters the pool as available liquidity ─
        core.updateTotalLiquidity(debtAsset, int256(result.actualDebtToCover));

        // ── STEP 6: Burn the borrower's individual debt token balance ─────────
        // Without this the borrower's Hf never improves and acceptance
        // criterion 30 cannot pass.  Stable and variable tokens have
        // different burn signatures (variable requires the current index).
        if (result.isStableBorrow) {
            address stableToken = core.getReserveStableDebtTokenAddress(debtAsset);
            IStableDebtToken(stableToken).burn(user, result.actualDebtToCover);
        } else {
            address variableToken = core.getReserveVariableDebtTokenAddress(debtAsset);
            uint256 variableIndex = core.getReserveNormalizedVariableDebt(debtAsset);
            IVariableDebtToken(variableToken).burn(user, result.actualDebtToCover, variableIndex);
        }

        // ── STEP 7: Transfer collateral aTokens to liquidator (INTERACTION) ───
        address aToken = core.getReserveATokenAddress(collateralAsset);
        IAToken(aToken).transferOnLiquidation(user, msg.sender, result.collateralAmountToSeize);

        // ── STEP 8: Pull debt repayment from liquidator (INTERACTION) ─────────
        bool ok = IERC20(debtAsset).transferFrom(
            msg.sender,
            address(core),
            result.actualDebtToCover
        );
        if (!ok) revert TransferFailed();
    }
}
