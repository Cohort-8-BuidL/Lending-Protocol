// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DataTypes} from "../DataTypes.sol";

interface ILendingPoolCore {

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// Thrown when a caller is not the authorized address for the function.
    error Unauthorized(address caller);

    /// Thrown when initReserve is called for an asset that already exists.
    error ReserveAlreadyInitialized(address asset);

    ///  Thrown when an operation targets an asset that has not been initialized.
    error ReserveNotInitialized(address asset);

    ///  Thrown when a required address argument is the zero address.
    error ZeroAddress();

    ///  Thrown when reserve state is internally inconsistent.
    error InvalidReserveState();

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event ReserveInitialized(
        address indexed asset,
        address aToken,
        address stableDebtToken,
        address variableDebtToken,
        address interestRateStrategy
    );

    event ReserveIndexesUpdated(
        address indexed asset,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex,
        uint40  lastUpdateTimestamp
    );

    event ReserveRatesUpdated(
        address indexed asset,
        uint256 liquidityRate,
        uint256 stableBorrowRate,
        uint256 variableBorrowRate
    );

    event ReserveInterestRateStrategyChanged(address indexed asset, address strategy);
    event ReserveConfigurationUpdated(address indexed asset, uint256 configurationData);

    // ─────────────────────────────────────────────────────────────────────────
    // Configurator-only state mutators
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes a new reserve. Can only be called once per asset.
     * @dev    Access: onlyConfigurator — reverts with Unauthorized(caller) otherwise.
     * @param asset                ERC-20 token address.
     * @param aTokenAddress        Receipt token address.
     * @param stableDebtToken      Stable debt token address.
     * @param variableDebtToken    Variable debt token address.
     * @param interestRateStrategy Interest rate strategy address.
     */
    function initReserve(
        address asset,
        address aTokenAddress,
        address stableDebtToken,
        address variableDebtToken,
        address interestRateStrategy
    ) external;

    /**
     * @notice Overwrites the packed configuration bitmap for a reserve.
     * @dev    Access: onlyConfigurator — reverts with Unauthorized(caller) otherwise.
     * @param asset      The reserve asset.
     * @param configData Raw packed uint256 configuration value.
     */
    function setReserveConfiguration(address asset, uint256 configData) external;

    /**
     * @notice Replaces the interest rate strategy contract for a reserve.
     * @dev    Access: onlyConfigurator — reverts with Unauthorized(caller) otherwise.
     * @param asset    The reserve asset.
     * @param strategy New IReserveInterestRateStrategy implementation address.
     */
    function setReserveInterestRateStrategyAddress(address asset, address strategy) external;

    /**
     * @notice Sets the active flag on a reserve.
     * @dev    Access: onlyConfigurator — reverts with Unauthorized(caller) otherwise.
     * @param asset  The reserve asset.
     * @param active True to activate, false to deactivate.
     */
    function setReserveActive(address asset, bool active) external;

    /**
     * @notice Enables or disables borrowing on a reserve.
     * @dev    Access: onlyConfigurator — reverts with Unauthorized(caller) otherwise.
     * @param asset   The reserve asset.
     * @param enabled True to enable borrowing.
     */
    function setReserveBorrowingEnabled(address asset, bool enabled) external;

    /**
     * @notice Enables or disables stable-rate borrowing on a reserve.
     * @dev    Access: onlyConfigurator — reverts with Unauthorized(caller) otherwise.
     * @param asset   The reserve asset.
     * @param enabled True to enable stable-rate borrowing.
     */
    function setReserveStableBorrowRateEnabled(address asset, bool enabled) external;

    /**
     * @notice Freezes or unfreezes a reserve (blocks new deposits and borrows).
     * @dev    Access: onlyConfigurator — reverts with Unauthorized(caller) otherwise.
     * @param asset  The reserve asset.
     * @param frozen True to freeze.
     */
    function setReserveFrozen(address asset, bool frozen) external;

    // ─────────────────────────────────────────────────────────────────────────
    // LendingPool-only state mutators
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Accrues interest and updates the liquidity and variable borrow
     *         indexes to the current block timestamp.
     * @dev    Access: onlyLendingPool — reverts with Unauthorized(caller) otherwise.
     *         Must be called before any balance read or write for the reserve.
     * @param asset The reserve to update.
     */
    function updateReserveIndexes(address asset) external;

    /**
     * @notice Stores new interest rates for a reserve.
     * @dev    Access: onlyLendingPool — reverts with Unauthorized(caller) otherwise.
     * @param asset               The reserve asset.
     * @param liquidityRate       New liquidity rate in RAY.
     * @param stableBorrowRate    New stable borrow rate in RAY.
     * @param variableBorrowRate  New variable borrow rate in RAY.
     */
    function updateReserveInterestRates(
        address asset,
        uint256 liquidityRate,
        uint256 stableBorrowRate,
        uint256 variableBorrowRate
    ) external;

    /**
     * @notice Applies a signed delta to the total liquidity (deposits) of a reserve.
     * @dev    Access: onlyLendingPool — reverts with Unauthorized(caller) otherwise.
     * @param asset  The reserve asset.
     * @param amount Positive for deposits, negative for withdrawals.
     */
    function updateTotalLiquidity(address asset, int256 amount) external;

    /**
     * @notice Applies a signed delta to the total stable borrows of a reserve.
     * @dev    Access: onlyLendingPool — reverts with Unauthorized(caller) otherwise.
     * @param asset  The reserve asset.
     * @param amount Positive for new borrows, negative for repayments.
     */
    function updateTotalStableBorrows(address asset, int256 amount) external;

    /**
     * @notice Applies a signed delta to the total variable borrows of a reserve.
     * @dev    Access: onlyLendingPool — reverts with Unauthorized(caller) otherwise.
     * @param asset  The reserve asset.
     * @param amount Positive for new borrows, negative for repayments.
     */
    function updateTotalVariableBorrows(address asset, int256 amount) external;

    // ─────────────────────────────────────────────────────────────────────────
    // View — indexes and rates
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the stored cumulative liquidity index (Cᵢᵗ) in RAY.
    function getReserveLiquidityIndex(address asset) external view returns (uint256);

    /// @notice Returns the stored cumulative variable borrow index (Bᵥ꜀ᵗ) in RAY.
    function getReserveVariableBorrowIndex(address asset) external view returns (uint256);

    /// @notice Projects the liquidity index to the current timestamp without writing storage.
    function getReserveNormalizedIncome(address asset) external view returns (uint256);

    /// @notice Projects the variable borrow index to the current timestamp without writing storage.
    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);

    /// @notice Returns the current liquidity (supply) rate in RAY.
    function getReserveCurrentLiquidityRate(address asset) external view returns (uint256);

    /// @notice Returns the current variable borrow rate in RAY.
    function getReserveCurrentVariableBorrowRate(address asset) external view returns (uint256);

    /// @notice Returns the current stable borrow rate in RAY.
    function getReserveCurrentStableBorrowRate(address asset) external view returns (uint256);

    /// @notice Returns the block timestamp of the last index update.
    function getReserveLastUpdateTimestamp(address asset) external view returns (uint40);

    // ─────────────────────────────────────────────────────────────────────────
    // View — totals
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns total deposits (Lt) in underlying token units.
    function getReserveTotalLiquidity(address asset) external view returns (uint256);

    /// @notice Returns total stable borrows (Bs) in underlying token units.
    function getReserveTotalStableBorrows(address asset) external view returns (uint256);

    /// @notice Returns total variable borrows (Bv) in underlying token units.
    function getReserveTotalVariableBorrows(address asset) external view returns (uint256);

    /// @notice Returns total borrows = stable + variable in underlying token units.
    function getReserveTotalBorrows(address asset) external view returns (uint256);

    // ─────────────────────────────────────────────────────────────────────────
    // View — configuration
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the raw packed configuration bitmap.
    function getReserveConfiguration(
        address asset
    ) external view returns (DataTypes.ReserveConfigurationMap memory);

    /// @notice Returns LTV, liquidation threshold, liquidation bonus, and decimals in one call.
    function getReserveConfigurationParams(
        address asset
    ) external view returns (
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 decimals
    );

    /// @notice Returns the loan-to-value ratio in basis points.
    function getReserveLtv(address asset) external view returns (uint256);

    /// @notice Returns the liquidation threshold in basis points.
    function getReserveLiquidationThreshold(address asset) external view returns (uint256);

    /// @notice Returns the liquidation bonus in basis points (e.g. 10500 = 105%).
    function getReserveLiquidationBonus(address asset) external view returns (uint256);

    /// @notice Returns the decimals of the underlying asset.
    function getReserveDecimals(address asset) external view returns (uint256);

    /// @notice Returns all four boolean flags in one call.
    function getReserveFlags(
        address asset
    ) external view returns (bool active, bool borrowing, bool stableBorrowing, bool frozen);

    /// @notice Returns true if the reserve is active.
    function isReserveActive(address asset) external view returns (bool);

    /// @notice Returns true if borrowing is enabled on the reserve.
    function isReserveBorrowingEnabled(address asset) external view returns (bool);

    /// @notice Returns true if stable-rate borrowing is enabled on the reserve.
    function isReserveStableBorrowRateEnabled(address asset) external view returns (bool);

    /// @notice Returns true if the reserve is frozen.
    function isReserveFrozen(address asset) external view returns (bool);

    // ─────────────────────────────────────────────────────────────────────────
    // View — token addresses
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the aToken (receipt token) address for the reserve.
    function getReserveATokenAddress(address asset) external view returns (address);

    /// @notice Returns the StableDebtToken address for the reserve.
    function getReserveStableDebtTokenAddress(address asset) external view returns (address);

    /// @notice Returns the VariableDebtToken address for the reserve.
    function getReserveVariableDebtTokenAddress(address asset) external view returns (address);

    /// @notice Returns the interest rate strategy address for the reserve.
    function getReserveInterestRateStrategyAddress(address asset) external view returns (address);

    // ─────────────────────────────────────────────────────────────────────────
    // View — full data
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the full ReserveData struct. Prefer specific getters in hot paths.
    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);

    /// @notice Returns the ordered list of all initialized reserve asset addresses.
    function getReservesList() external view returns (address[] memory);

    /// @notice Returns the number of initialized reserves.
    function getReservesCount() external view returns (uint256);
}
