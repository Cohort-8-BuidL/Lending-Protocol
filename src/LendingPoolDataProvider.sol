// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LendingPoolCore}          from "./LendingPoolCore.sol";
import {IPriceOracle}             from "./interfaces/IPriceOracle.sol";
import {IAToken}                  from "./interfaces/IAToken.sol";
import {ILendingPoolDataProvider} from "./interfaces/ILendingPoolDataProvider.sol";

/**
 * @title LendingPoolDataProvider
 * @notice Aggregates raw reserve data from LendingPoolCore and oracle prices into
 *         user-facing risk metrics: health factor, borrowing capacity, LTV, and
 *         liquidation thresholds.
 *
 * Ownership
 * ─────────
 * This contract is owned by Team 3 (Health Factor System).
 * getAverageLiquidationThreshold() is fully implemented here (moved from
 * LiquidationManager per PRD Deliverable 2.4 requirement).
 * All other functions are stubs that Team 3 must complete.
 *
 * User collateral flags
 * ─────────────────────
 * When a user deposits an asset and chooses to use it as collateral, LendingPool
 * calls setUserUseReserveAsCollateral() to record that choice.  This mapping is
 * the authoritative source for isUserUsingReserveAsCollateral().
 */
contract LendingPoolDataProvider is ILendingPoolDataProvider {

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error OnlyLendingPool();
    error NotImplemented();

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    LendingPoolCore public immutable core;

    /// @dev user → reserve → enabled as collateral
    mapping(address => mapping(address => bool)) private _userCollateralEnabled;

    /// @dev Only LendingPool may update collateral flags.
    address public immutable lendingPool;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _core, address _lendingPool) {
        core        = LendingPoolCore(_core);
        lendingPool = _lendingPool;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Collateral flag management  (LendingPool only)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Records whether `user` wants `reserve` counted as collateral.
     * @dev    Called by LendingPool during deposit and setUserUseReserveAsCollateral().
     */
    function setUserUseReserveAsCollateral(
        address user,
        address reserve,
        bool useAsCollateral
    ) external {
        if (msg.sender != lendingPool) revert OnlyLendingPool();
        _userCollateralEnabled[user][reserve] = useAsCollateral;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ILendingPoolDataProvider — Deliverable 2.4 (fully implemented)
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ILendingPoolDataProvider
    function getAverageLiquidationThreshold(
        address user
    ) external view override returns (uint256 avgThreshold) {
        address oracleAddr = core.priceOracle();

        address[] memory reserves = core.getReservesList();
        uint256 totalCollateralETH;
        uint256 weightedThreshold;

        for (uint256 i = 0; i < reserves.length; i++) {
            address reserve = reserves[i];

            if (!_userCollateralEnabled[user][reserve]) continue;

            address aToken  = core.getReserveATokenAddress(reserve);
            uint256 balance = IAToken(aToken).balanceOf(user);
            if (balance == 0) continue;

            // Skip reserves where oracle has no price — do not revert, just exclude.
            uint256 price = IPriceOracle(oracleAddr).getAssetPrice(reserve);
            if (price == 0) continue;

            uint256 decimals  = core.getReserveDecimals(reserve);
            uint256 valueETH  = (balance * price) / (10 ** decimals);
            uint256 threshold = core.getReserveLiquidationThreshold(reserve);

            totalCollateralETH += valueETH;
            weightedThreshold  += valueETH * threshold;
        }

        if (totalCollateralETH == 0) return 0;
        return weightedThreshold / totalCollateralETH;
    }

    /// @inheritdoc ILendingPoolDataProvider
    function isUserUsingReserveAsCollateral(
        address user,
        address reserve
    ) external view override returns (bool) {
        return _userCollateralEnabled[user][reserve];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ILendingPoolDataProvider — Team 3 stubs (Health Factor team to implement)
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ILendingPoolDataProvider
    function getHealthFactor(address) external pure override returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc ILendingPoolDataProvider
    function getUserAccountData(address) external pure override returns (
        uint256, uint256, uint256, uint256, uint256, uint256, uint256
    ) {
        revert NotImplemented();
    }

    /// @inheritdoc ILendingPoolDataProvider
    function getCompoundedBorrowBalance(address, address) external pure override returns (uint256) {
        revert NotImplemented();
    }
}
