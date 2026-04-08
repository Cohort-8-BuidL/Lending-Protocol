// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DataTypes}             from "./DataTypes.sol";
import {WadRayMath}            from "./WadRayMath.sol";
import {ReserveConfiguration}  from "./ReserveConfiguration.sol";

/**
 * @title LendingPoolCore
 * @notice Central state store for all reserves.
 *
 * Responsibilities
 * ────────────────
 * 1. Maintain a mapping of ReserveData for every supported asset.
 * 2. Compute and atomically update borrow/liquidity indexes on every action.
 * 3. Expose reserve configuration getters for the rest of the protocol.
 * 4. Guard all state-mutating functions — only LendingPool and
 *    LendingPoolConfigurator may call them.
 *
 * Index math (all values in RAY = 1e27)
 * ────────────────────────────────────
 *   Liquidity index (linear):
 *     Cᵢᵗ = (Rl · ΔTyear + 1) · Cᵢᵗ⁻¹
 *
 *   Normalized income (spot value of 1 ray deposited at genesis):
 *     Iₙᵗ = Cᵢᵗ                      (same calculation, read-only view)
 *
 *   Variable borrow index (compound):
 *     Bᵥ꜀ᵗ = (1 + Rv / Tyear)^ΔT · Bᵥ꜀ᵗ⁻¹
 *
 * Access control
 * ─────────────
 * • onlyLendingPool        — deposit, borrow, repay, liquidation, flash loan
 * • onlyConfigurator       — reserve init, rate strategy changes, flag updates
 * • onlyLendingPoolOrConfigurator — shared write paths (e.g. rate updates)
 */
contract LendingPoolCore {
    using WadRayMath           for uint256;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error Unauthorized(address caller);
    error ReserveAlreadyInitialized(address asset);
    error ReserveNotInitialized(address asset);
    error ZeroAddress();
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
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public constant REBALANCE_UP_LIQUIDITY_RATE_THRESHOLD = 0.9e27; // 90% in RAY
    uint256 public constant REBALANCE_UP_USAGE_RATIO_THRESHOLD    = 0.95e27;

    /// @dev Initial index value — "1" in RAY.  Every reserve starts here.
    uint128 private constant INITIAL_INDEX = uint128(WadRayMath.RAY); // 1e27

    // ─────────────────────────────────────────────────────────────────────────
    // Access control state
    // ─────────────────────────────────────────────────────────────────────────

    address public immutable lendingPool;
    address public immutable lendingPoolConfigurator;

    // ─────────────────────────────────────────────────────────────────────────
    // Reserve state
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev asset address → ReserveData
    mapping(address => DataTypes.ReserveData) private _reserves;

    /// @dev ordered list of all initialized reserve addresses
    address[] private _reservesList;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _lendingPool, address _configurator) {
        if (_lendingPool == address(0) || _configurator == address(0)) revert ZeroAddress();
        lendingPool              = _lendingPool;
        lendingPoolConfigurator  = _configurator;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Access control modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyLendingPool() {
        if (msg.sender != lendingPool) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyConfigurator() {
        if (msg.sender != lendingPoolConfigurator) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyLendingPoolOrConfigurator() {
        if (msg.sender != lendingPool && msg.sender != lendingPoolConfigurator)
            revert Unauthorized(msg.sender);
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reserve initialization  (Configurator only)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes a new reserve.  Can only be called once per asset.
     * @param asset                  ERC-20 token address (ETH handled as WETH)
     * @param aTokenAddress          Receipt token
     * @param stableDebtToken        Stable debt token
     * @param variableDebtToken      Variable debt token
     * @param interestRateStrategy   IReserveInterestRateStrategy implementation
     */
    function initReserve(
        address asset,
        address aTokenAddress,
        address stableDebtToken,
        address variableDebtToken,
        address interestRateStrategy
    ) external onlyConfigurator {
        if (asset == address(0))                 revert ZeroAddress();
        if (aTokenAddress == address(0))         revert ZeroAddress();
        if (stableDebtToken == address(0))       revert ZeroAddress();
        if (variableDebtToken == address(0))     revert ZeroAddress();
        if (interestRateStrategy == address(0))  revert ZeroAddress();

        DataTypes.ReserveData storage reserve = _reserves[asset];
        if (reserve.aTokenAddress != address(0)) revert ReserveAlreadyInitialized(asset);

        reserve.liquidityIndex       = INITIAL_INDEX;
        reserve.variableBorrowIndex  = INITIAL_INDEX;
        reserve.lastUpdateTimestamp  = uint40(block.timestamp);

        reserve.aTokenAddress            = aTokenAddress;
        reserve.stableDebtTokenAddress   = stableDebtToken;
        reserve.variableDebtTokenAddress = variableDebtToken;
        reserve.interestRateStrategyAddress = interestRateStrategy;

        reserve.id = uint8(_reservesList.length);
        _reservesList.push(asset);

        emit ReserveInitialized(
            asset,
            aTokenAddress,
            stableDebtToken,
            variableDebtToken,
            interestRateStrategy
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Index update  (LendingPool only)
    //
    // This is the most critical function in the entire protocol.
    // It MUST be called at the start of every user-facing action so that
    // indexes are current before any balance computation.
    //
    // Atomicity guarantee: all three index values (liquidityIndex,
    // variableBorrowIndex, lastUpdateTimestamp) are written in a single
    // transaction — there is no state where two are updated and one is not.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Updates cumulated liquidity and variable borrow indexes.
     * @dev    Must be called before any balance read or write for the reserve.
     * @param  asset  The reserve to update.
     */
    function updateReserveIndexes(address asset) external onlyLendingPool {
        _updateIndexes(asset);
    }

    /**
     * @notice Updates interest rates for a reserve.
     * @param asset             The reserve
     * @param liquidityRate     New liquidity rate in RAY
     * @param stableBorrowRate  New stable borrow rate in RAY
     * @param variableBorrowRate New variable borrow rate in RAY
     */
    function updateReserveInterestRates(
        address asset,
        uint256 liquidityRate,
        uint256 stableBorrowRate,
        uint256 variableBorrowRate
    ) external onlyLendingPool {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        // forge-lint: disable-next-line(unsafe-typecast) — rates are in RAY (1e27), well within uint128 max (≈3.4e38)
        reserve.currentLiquidityRate      = uint128(liquidityRate);
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve.currentStableBorrowRate   = uint128(stableBorrowRate);
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve.currentVariableBorrowRate = uint128(variableBorrowRate);

        emit ReserveRatesUpdated(asset, liquidityRate, stableBorrowRate, variableBorrowRate);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Borrow / liquidity tracking  (LendingPool only)
    //
    // These are called by LendingPool on every deposit, borrow, repay, and
    // liquidation so that totalLiquidity, totalStableBorrows, and
    // totalVariableBorrows are always consistent.
    //
    // Invariant enforced: totalBorrows = totalStableBorrows + totalVariableBorrows
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Updates total liquidity (deposits) for a reserve.
     * @param asset   The reserve asset
     * @param amount  Signed delta — positive for deposits, negative for withdrawals
     */
    function updateTotalLiquidity(address asset, int256 amount) external onlyLendingPool {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);
        if (amount >= 0) {
            // forge-lint: disable-next-line(unsafe-typecast) — token amounts fit in uint128 (max ~3.4e38 wei)
            reserve.totalLiquidity += uint128(uint256(amount));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            reserve.totalLiquidity -= uint128(uint256(-amount));
        }
    }

    /**
     * @notice Updates total stable borrows for a reserve.
     * @param asset   The reserve asset
     * @param amount  Signed delta — positive for new borrows, negative for repayments
     */
    function updateTotalStableBorrows(address asset, int256 amount) external onlyLendingPool {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);
        if (amount >= 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            reserve.totalStableBorrows += uint128(uint256(amount));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            reserve.totalStableBorrows -= uint128(uint256(-amount));
        }
    }

    /**
     * @notice Updates total variable borrows for a reserve.
     * @param asset   The reserve asset
     * @param amount  Signed delta — positive for new borrows, negative for repayments
     */
    function updateTotalVariableBorrows(address asset, int256 amount) external onlyLendingPool {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);
        if (amount >= 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            reserve.totalVariableBorrows += uint128(uint256(amount));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            reserve.totalVariableBorrows -= uint128(uint256(-amount));
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Configuration setters  (Configurator only)
    // ─────────────────────────────────────────────────────────────────────────

    function setReserveConfiguration(address asset, uint256 configData) external onlyConfigurator {
        _getInitializedReserve(asset).configuration.data = configData;
        emit ReserveConfigurationUpdated(asset, configData);
    }

    function setReserveInterestRateStrategyAddress(
        address asset,
        address strategy
    ) external onlyConfigurator {
        if (strategy == address(0)) revert ZeroAddress();
        _getInitializedReserve(asset).interestRateStrategyAddress = strategy;
        emit ReserveInterestRateStrategyChanged(asset, strategy);
    }

    function setReserveActive(address asset, bool active) external onlyConfigurator {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);
        DataTypes.ReserveConfigurationMap memory config = reserve.configuration;
        config.setActive(active);
        reserve.configuration = config;
    }

    function setReserveBorrowingEnabled(address asset, bool enabled) external onlyConfigurator {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);
        DataTypes.ReserveConfigurationMap memory config = reserve.configuration;
        config.setBorrowingEnabled(enabled);
        reserve.configuration = config;
    }

    function setReserveStableBorrowRateEnabled(address asset, bool enabled) external onlyConfigurator {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);
        DataTypes.ReserveConfigurationMap memory config = reserve.configuration;
        config.setStableBorrowRateEnabled(enabled);
        reserve.configuration = config;
    }

    function setReserveFrozen(address asset, bool frozen) external onlyConfigurator {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);
        DataTypes.ReserveConfigurationMap memory config = reserve.configuration;
        config.setFrozen(frozen);
        reserve.configuration = config;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Getters — index and rate reads
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the current (already-accrued) liquidity index Cᵢᵗ.
     * @dev    This is the stored value; call getNormalizedIncome() for the
     *         live projected value since last update.
     */
    function getReserveLiquidityIndex(address asset) external view returns (uint256) {
        return _reserves[asset].liquidityIndex;
    }

    /**
     * @notice Returns the current variable borrow index Bᵥ꜀ᵗ (stored).
     */
    function getReserveVariableBorrowIndex(address asset) external view returns (uint256) {
        return _reserves[asset].variableBorrowIndex;
    }

    /**
     * @notice Iₙᵗ — the normalized income: projects the current liquidity
     *         index forward to NOW without writing to storage.
     *
     *         Iₙᵗ = (Rl · ΔTyear + 1) · Cᵢᵗ⁻¹
     *
     *         Used by aToken to compute balances.
     */
    function getReserveNormalizedIncome(address asset) external view returns (uint256) {
        DataTypes.ReserveData storage reserve = _reserves[asset];

        // If no time has passed, return stored index (gas optimization)
        if (uint40(block.timestamp) == reserve.lastUpdateTimestamp) {
            return reserve.liquidityIndex;
        }

        uint256 linearInterest = WadRayMath.calculateLinearInterestAt(
            reserve.currentLiquidityRate,
            reserve.lastUpdateTimestamp,
            block.timestamp
        );

        return linearInterest.rayMul(reserve.liquidityIndex);
    }

    /**
     * @notice Projects the variable borrow index forward to NOW without
     *         writing to storage.  Used by VariableDebtToken.
     */
    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256) {
        DataTypes.ReserveData storage reserve = _reserves[asset];

        if (uint40(block.timestamp) == reserve.lastUpdateTimestamp) {
            return reserve.variableBorrowIndex;
        }

        uint256 compoundedInterest = WadRayMath.calculateCompoundedInterestAt(
            reserve.currentVariableBorrowRate,
            reserve.lastUpdateTimestamp,
            block.timestamp
        );

        return compoundedInterest.rayMul(reserve.variableBorrowIndex);
    }

    function getReserveCurrentLiquidityRate(address asset) external view returns (uint256) {
        return _reserves[asset].currentLiquidityRate;
    }

    function getReserveCurrentVariableBorrowRate(address asset) external view returns (uint256) {
        return _reserves[asset].currentVariableBorrowRate;
    }

    function getReserveCurrentStableBorrowRate(address asset) external view returns (uint256) {
        return _reserves[asset].currentStableBorrowRate;
    }

    function getReserveLastUpdateTimestamp(address asset) external view returns (uint40) {
        return _reserves[asset].lastUpdateTimestamp;
    }

    /// @notice Lt — total liquidity (deposits) for a reserve.
    function getReserveTotalLiquidity(address asset) external view returns (uint256) {
        return _reserves[asset].totalLiquidity;
    }

    /// @notice Bs — total stable borrows for a reserve.
    function getReserveTotalStableBorrows(address asset) external view returns (uint256) {
        return _reserves[asset].totalStableBorrows;
    }

    /// @notice Bv — total variable borrows for a reserve.
    function getReserveTotalVariableBorrows(address asset) external view returns (uint256) {
        return _reserves[asset].totalVariableBorrows;
    }

    /**
     * @notice Returns total borrows = stable + variable.
     * @dev    Acceptance criterion: this must always equal the sum of the two
     *         individual totals — no partial-update state is ever committed.
     */
    function getReserveTotalBorrows(address asset) external view returns (uint256) {
        DataTypes.ReserveData storage reserve = _reserves[asset];
        return uint256(reserve.totalStableBorrows) + uint256(reserve.totalVariableBorrows);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Getters — configuration
    //
    // All of these are used by LendingPool, LendingPoolCollateralManager,
    // and PriceOracle to validate user actions.
    // ─────────────────────────────────────────────────────────────────────────

    function getReserveConfiguration(
        address asset
    ) external view returns (DataTypes.ReserveConfigurationMap memory) {
        return _reserves[asset].configuration;
    }

    /// @notice Returns LTV, liquidation threshold, bonus, and decimals in one call.
    function getReserveConfigurationParams(
        address asset
    ) external view returns (
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 decimals
    ) {
        return _reserves[asset].configuration.getParams();
    }

    function getReserveLtv(address asset) external view returns (uint256) {
        return _reserves[asset].configuration.getLtv();
    }

    function getReserveLiquidationThreshold(address asset) external view returns (uint256) {
        return _reserves[asset].configuration.getLiquidationThreshold();
    }

    function getReserveLiquidationBonus(address asset) external view returns (uint256) {
        return _reserves[asset].configuration.getLiquidationBonus();
    }

    function getReserveDecimals(address asset) external view returns (uint256) {
        return _reserves[asset].configuration.getDecimals();
    }

    /// @notice Returns all four boolean flags in one call.
    function getReserveFlags(
        address asset
    ) external view returns (bool active, bool borrowing, bool stableBorrowing, bool frozen) {
        return _reserves[asset].configuration.getFlags();
    }

    function isReserveActive(address asset) external view returns (bool) {
        return _reserves[asset].configuration.getActive();
    }

    function isReserveBorrowingEnabled(address asset) external view returns (bool) {
        return _reserves[asset].configuration.getBorrowingEnabled();
    }

    function isReserveStableBorrowRateEnabled(address asset) external view returns (bool) {
        return _reserves[asset].configuration.getStableBorrowRateEnabled();
    }

    function isReserveFrozen(address asset) external view returns (bool) {
        return _reserves[asset].configuration.getFrozen();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Getters — token addresses
    // ─────────────────────────────────────────────────────────────────────────

    function getReserveATokenAddress(address asset) external view returns (address) {
        return _reserves[asset].aTokenAddress;
    }

    function getReserveStableDebtTokenAddress(address asset) external view returns (address) {
        return _reserves[asset].stableDebtTokenAddress;
    }

    function getReserveVariableDebtTokenAddress(address asset) external view returns (address) {
        return _reserves[asset].variableDebtTokenAddress;
    }

    function getReserveInterestRateStrategyAddress(address asset) external view returns (address) {
        return _reserves[asset].interestRateStrategyAddress;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Getters — full data
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the full ReserveData struct.
     * @dev    Prefer specific getters in hot paths; this is for off-chain reads.
     */
    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory) {
        return _reserves[asset];
    }

    /**
     * @notice Returns the ordered list of all initialized reserves.
     */
    function getReservesList() external view returns (address[] memory) {
        return _reservesList;
    }

    function getReservesCount() external view returns (uint256) {
        return _reservesList.length;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Core index update logic.
     *
     * Atomicity: liquidityIndex, variableBorrowIndex, and lastUpdateTimestamp
     * are always written together in a single function call.  No intermediate
     * state is ever committed to storage.
     *
     * Math:
     *   newLiquidityIndex     = linearInterest(Rl, Tl→T) · Cᵢᵗ⁻¹
     *   newVariableBorrowIdx  = compoundInterest(Rv, Tl→T) · Bᵥ꜀ᵗ⁻¹
     */
    function _updateIndexes(address asset) internal {
        DataTypes.ReserveData storage reserve = _reserves[asset];

        uint40 currentTimestamp = uint40(block.timestamp);

        // Short-circuit: already updated this block, no interest accrued
        if (currentTimestamp == reserve.lastUpdateTimestamp) return;

        uint256 currentLiquidityRate     = reserve.currentLiquidityRate;
        uint256 currentVariableBorrowRate = reserve.currentVariableBorrowRate;

        uint256 newLiquidityIndex    = reserve.liquidityIndex;
        uint256 newVariableBorrowIdx = reserve.variableBorrowIndex;

        // ── Liquidity index (linear) ──────────────────────────────────────────
        if (currentLiquidityRate > 0) {
            uint256 linearInterest = WadRayMath.calculateLinearInterestAt(
                currentLiquidityRate,
                reserve.lastUpdateTimestamp,
                currentTimestamp
            );
            newLiquidityIndex = linearInterest.rayMul(newLiquidityIndex);

            // Sanity: index must never decrease
            assert(newLiquidityIndex >= reserve.liquidityIndex);
        }

        // ── Variable borrow index (compound) ─────────────────────────────────
        if (currentVariableBorrowRate > 0) {
            uint256 compoundedInterest = WadRayMath.calculateCompoundedInterestAt(
                currentVariableBorrowRate,
                reserve.lastUpdateTimestamp,
                currentTimestamp
            );
            newVariableBorrowIdx = compoundedInterest.rayMul(newVariableBorrowIdx);

            assert(newVariableBorrowIdx >= reserve.variableBorrowIndex);
        }

        // ── Atomic write ─────────────────────────────────────────────────────
        // forge-lint: disable-next-line(unsafe-typecast) — indexes are in RAY (1e27), well within uint128 max
        reserve.liquidityIndex      = uint128(newLiquidityIndex);
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve.variableBorrowIndex = uint128(newVariableBorrowIdx);
        reserve.lastUpdateTimestamp = currentTimestamp;

        emit ReserveIndexesUpdated(
            asset,
            newLiquidityIndex,
            newVariableBorrowIdx,
            currentTimestamp
        );
    }

    /**
     * @dev Returns a storage pointer to a reserve, reverting if not initialized.
     */
    function _getInitializedReserve(
        address asset
    ) internal view returns (DataTypes.ReserveData storage) {
        DataTypes.ReserveData storage reserve = _reserves[asset];
        if (reserve.aTokenAddress == address(0)) revert ReserveNotInitialized(asset);
        return reserve;
    }
}
