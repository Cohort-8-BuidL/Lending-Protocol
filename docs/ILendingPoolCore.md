# ILendingPoolCore Interface

Interface for `LendingPoolCore.sol` — the central state store for all reserves in the lending protocol.

---

## Access Control

Interfaces cannot define modifiers (modifiers contain executable logic, which interfaces forbid). Access control is instead enforced in two complementary ways in this interface:

### 1. NatSpec `@dev` comments

Every state-mutating function documents which role is required and what happens if the caller is wrong:

```
@dev Access: onlyLendingPool — reverts with Unauthorized(caller) otherwise.
```

This makes the restriction visible to any developer reading the interface, IDE tooling, and auto-generated docs.

### 2. Custom errors

The interface declares the same custom errors that the implementation's modifiers revert with. Any caller can therefore catch and identify access-control failures without needing the implementation source:

| Error | When thrown |
|---|---|
| `Unauthorized(address caller)` | `msg.sender` is not the authorized address for that function |
| `ReserveAlreadyInitialized(address asset)` | `initReserve` called on an already-initialized asset |
| `ReserveNotInitialized(address asset)` | Operation targets an asset that has never been initialized |
| `ZeroAddress()` | A required address argument is `address(0)` |
| `InvalidReserveState()` | Internal reserve state is inconsistent |

The three access roles and which functions they gate:

| Role | Authorized address | Functions |
|---|---|---|
| `onlyConfigurator` | `lendingPoolConfigurator` | `initReserve`, all `setReserve*` functions |
| `onlyLendingPool` | `lendingPool` | `updateReserveIndexes`, `updateReserveInterestRates`, `updateTotal*` |
| Public (view) | anyone | All `get*` / `is*` functions |

---

## Configurator-only Functions

### `initReserve`

```solidity
function initReserve(
    address asset,
    address aTokenAddress,
    address stableDebtToken,
    address variableDebtToken,
    address interestRateStrategy
) external;
```

Registers a brand-new reserve. Sets the liquidity index and variable borrow index to `1 RAY` (1e27) and records the current timestamp. Pushes the asset onto the internal `_reservesList`. Can only be called once per asset — reverts with `ReserveAlreadyInitialized` on a second call. Any zero address argument reverts with `ZeroAddress`.

---

### `setReserveConfiguration`

```solidity
function setReserveConfiguration(address asset, uint256 configData) external;
```

Overwrites the entire packed configuration bitmap for a reserve in one write. The bitmap encodes LTV, liquidation threshold, liquidation bonus, decimals, and four boolean flags (see `DataTypes.ReserveConfigurationMap`). Emits `ReserveConfigurationUpdated`.

---

### `setReserveInterestRateStrategyAddress`

```solidity
function setReserveInterestRateStrategyAddress(address asset, address strategy) external;
```

Replaces the `IReserveInterestRateStrategy` implementation used to compute rates for this reserve. Reverts with `ZeroAddress` if `strategy` is zero. Emits `ReserveInterestRateStrategyChanged`.

---

### `setReserveActive`

```solidity
function setReserveActive(address asset, bool active) external;
```

Flips bit 56 of the configuration bitmap. An inactive reserve blocks all user interactions (deposits, borrows, repayments).

---

### `setReserveBorrowingEnabled`

```solidity
function setReserveBorrowingEnabled(address asset, bool enabled) external;
```

Flips bit 57. When disabled, new borrows against this reserve are rejected by `LendingPool`.

---

### `setReserveStableBorrowRateEnabled`

```solidity
function setReserveStableBorrowRateEnabled(address asset, bool enabled) external;
```

Flips bit 58. Controls whether users may open stable-rate borrow positions on this reserve.

---

### `setReserveFrozen`

```solidity
function setReserveFrozen(address asset, bool frozen) external;
```

Flips bit 59. A frozen reserve blocks new deposits and new borrows but still allows repayments and withdrawals, letting existing users exit safely.

---

## LendingPool-only Functions

### `updateReserveIndexes`

```solidity
function updateReserveIndexes(address asset) external;
```

The most critical function in the protocol. Accrues interest since the last update and writes three values atomically: `liquidityIndex`, `variableBorrowIndex`, and `lastUpdateTimestamp`. Must be called at the start of every user-facing action so that all subsequent balance calculations use current indexes.

- Liquidity index uses **linear** interest: `Cᵢᵗ = (Rl · ΔTyear + 1) · Cᵢᵗ⁻¹`
- Variable borrow index uses **compound** interest: `Bᵥ꜀ᵗ = (1 + Rv/Tyear)^ΔT · Bᵥ꜀ᵗ⁻¹`

Short-circuits (no-op) if already called in the same block. Emits `ReserveIndexesUpdated`.

---

### `updateReserveInterestRates`

```solidity
function updateReserveInterestRates(
    address asset,
    uint256 liquidityRate,
    uint256 stableBorrowRate,
    uint256 variableBorrowRate
) external;
```

Stores the three new rates (all in RAY) computed by the interest rate strategy after a deposit, borrow, repay, or liquidation. Called by `LendingPool` immediately after it invokes the strategy. Emits `ReserveRatesUpdated`.

---

### `updateTotalLiquidity`

```solidity
function updateTotalLiquidity(address asset, int256 amount) external;
```

Applies a signed delta to `totalLiquidity` (total deposits). Pass a positive value on deposit and a negative value on withdrawal. Maintains the invariant that `totalLiquidity` always reflects the actual underlying token balance held by the aToken contract.

---

### `updateTotalStableBorrows`

```solidity
function updateTotalStableBorrows(address asset, int256 amount) external;
```

Applies a signed delta to `totalStableBorrows`. Positive on a new stable borrow, negative on repayment or liquidation. Together with `updateTotalVariableBorrows`, maintains the invariant: `totalBorrows = totalStableBorrows + totalVariableBorrows`.

---

### `updateTotalVariableBorrows`

```solidity
function updateTotalVariableBorrows(address asset, int256 amount) external;
```

Same as above but for variable-rate positions.

---

## View Functions — Indexes and Rates

### `getReserveLiquidityIndex`

```solidity
function getReserveLiquidityIndex(address asset) external view returns (uint256);
```

Returns the **stored** cumulative liquidity index `Cᵢᵗ` in RAY. This is the value written at the last `updateReserveIndexes` call. For the live projected value (not yet written to storage), use `getReserveNormalizedIncome`.

---

### `getReserveVariableBorrowIndex`

```solidity
function getReserveVariableBorrowIndex(address asset) external view returns (uint256);
```

Returns the **stored** cumulative variable borrow index `Bᵥ꜀ᵗ` in RAY. For the live projected value, use `getReserveNormalizedVariableDebt`.

---

### `getReserveNormalizedIncome`

```solidity
function getReserveNormalizedIncome(address asset) external view returns (uint256);
```

Projects the liquidity index forward to `block.timestamp` using linear interest, without writing to storage. Used by `aToken` to compute user balances in real time. Returns the stored index directly if called in the same block as the last update (gas optimization).

---

### `getReserveNormalizedVariableDebt`

```solidity
function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);
```

Projects the variable borrow index forward to `block.timestamp` using compound interest, without writing to storage. Used by `VariableDebtToken` to compute scaled debt balances.

---

### `getReserveCurrentLiquidityRate`

```solidity
function getReserveCurrentLiquidityRate(address asset) external view returns (uint256);
```

Returns the current per-second liquidity (supply) rate in RAY. Example: 5% APR ≈ `5e25`.

---

### `getReserveCurrentVariableBorrowRate`

```solidity
function getReserveCurrentVariableBorrowRate(address asset) external view returns (uint256);
```

Returns the current per-second variable borrow rate in RAY.

---

### `getReserveCurrentStableBorrowRate`

```solidity
function getReserveCurrentStableBorrowRate(address asset) external view returns (uint256);
```

Returns the current per-second stable borrow rate in RAY. This is the rate locked in for new stable-rate positions.

---

### `getReserveLastUpdateTimestamp`

```solidity
function getReserveLastUpdateTimestamp(address asset) external view returns (uint40);
```

Returns the `block.timestamp` at which indexes were last written. Used internally to compute `ΔT` for interest accrual.

---

## View Functions — Totals

### `getReserveTotalLiquidity`

```solidity
function getReserveTotalLiquidity(address asset) external view returns (uint256);
```

Returns `Lt` — total deposits in underlying token units.

---

### `getReserveTotalStableBorrows`

```solidity
function getReserveTotalStableBorrows(address asset) external view returns (uint256);
```

Returns `Bs` — total stable borrows in underlying token units.

---

### `getReserveTotalVariableBorrows`

```solidity
function getReserveTotalVariableBorrows(address asset) external view returns (uint256);
```

Returns `Bv` — total variable borrows in underlying token units.

---

### `getReserveTotalBorrows`

```solidity
function getReserveTotalBorrows(address asset) external view returns (uint256);
```

Returns `Bs + Bv`. Always equals the sum of the two individual totals — no partial-update state is ever committed.

---

## View Functions — Configuration

### `getReserveConfiguration`

```solidity
function getReserveConfiguration(address asset)
    external view returns (DataTypes.ReserveConfigurationMap memory);
```

Returns the raw packed `uint256` configuration bitmap. Prefer the specific getters below in on-chain code; use this for off-chain reads or when you need the full bitmap.

---

### `getReserveConfigurationParams`

```solidity
function getReserveConfigurationParams(address asset)
    external view returns (
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 decimals
    );
```

Decodes and returns the four numeric parameters from the bitmap in a single call. Saves gas compared to four individual getter calls.

---

### `getReserveLtv`

```solidity
function getReserveLtv(address asset) external view returns (uint256);
```

Returns the loan-to-value ratio in basis points (e.g. `8000` = 80%). The maximum a user can borrow against their collateral.

---

### `getReserveLiquidationThreshold`

```solidity
function getReserveLiquidationThreshold(address asset) external view returns (uint256);
```

Returns the liquidation threshold in basis points. When a position's health factor drops below 1 (collateral value × threshold < debt), it becomes eligible for liquidation.

---

### `getReserveLiquidationBonus`

```solidity
function getReserveLiquidationBonus(address asset) external view returns (uint256);
```

Returns the liquidation bonus in basis points (e.g. `10500` = 105%). The liquidator receives this percentage of the collateral they seize as an incentive.

---

### `getReserveDecimals`

```solidity
function getReserveDecimals(address asset) external view returns (uint256);
```

Returns the decimals of the underlying ERC-20 asset as stored in the configuration bitmap.

---

### `getReserveFlags`

```solidity
function getReserveFlags(address asset)
    external view returns (bool active, bool borrowing, bool stableBorrowing, bool frozen);
```

Returns all four boolean flags in a single call. More gas-efficient than four individual `is*` calls when you need multiple flags.

---

### `isReserveActive`

```solidity
function isReserveActive(address asset) external view returns (bool);
```

Returns `true` if the reserve is active (bit 56 of the configuration bitmap is set).

---

### `isReserveBorrowingEnabled`

```solidity
function isReserveBorrowingEnabled(address asset) external view returns (bool);
```

Returns `true` if borrowing is enabled (bit 57).

---

### `isReserveStableBorrowRateEnabled`

```solidity
function isReserveStableBorrowRateEnabled(address asset) external view returns (bool);
```

Returns `true` if stable-rate borrowing is enabled (bit 58).

---

### `isReserveFrozen`

```solidity
function isReserveFrozen(address asset) external view returns (bool);
```

Returns `true` if the reserve is frozen (bit 59). Frozen reserves block new deposits and borrows.

---

## View Functions — Token Addresses

### `getReserveATokenAddress`

```solidity
function getReserveATokenAddress(address asset) external view returns (address);
```

Returns the address of the `aToken` (receipt/interest-bearing token) for this reserve.

---

### `getReserveStableDebtTokenAddress`

```solidity
function getReserveStableDebtTokenAddress(address asset) external view returns (address);
```

Returns the address of the `StableDebtToken` for this reserve.

---

### `getReserveVariableDebtTokenAddress`

```solidity
function getReserveVariableDebtTokenAddress(address asset) external view returns (address);
```

Returns the address of the `VariableDebtToken` for this reserve.

---

### `getReserveInterestRateStrategyAddress`

```solidity
function getReserveInterestRateStrategyAddress(address asset) external view returns (address);
```

Returns the address of the `IReserveInterestRateStrategy` implementation currently used by this reserve.

---

## View Functions — Full Data

### `getReserveData`

```solidity
function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);
```

Returns the complete `ReserveData` struct for a reserve. Contains all indexes, rates, totals, addresses, and configuration. Intended for off-chain reads (e.g. subgraphs, frontends). Prefer specific getters in on-chain hot paths to avoid loading the full struct.

---

### `getReservesList`

```solidity
function getReservesList() external view returns (address[] memory);
```

Returns the ordered array of all initialized reserve asset addresses. The position of each address in this array matches the `id` field stored in its `ReserveData`.

---

### `getReservesCount`

```solidity
function getReservesCount() external view returns (uint256);
```

Returns the number of initialized reserves. Equivalent to `getReservesList().length` but cheaper since it avoids copying the array.
