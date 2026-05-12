# LendingPoolDataProvider Improvements

This document captures practical improvement opportunities for `src/LendingPoolDataProvider.sol`, with emphasis on:

- better error handling
- gas efficiency
- arithmetic robustness

## Scope

Reviewed areas:

- account aggregation (`_aggregateAccountData`)
- health factor calculation (`calculateHealthFactor`)
- ETH normalization (`_toEthValue`)
- borrow validation path (`validateBorrow`, `_validateReserveChecks`, `_validateUserChecks`)

---

## 1) Error Handling Improvements

### 1.1 Replace revert strings with custom errors

**Status:** Implemented in `src/LendingPoolDataProvider.sol` (file-level `error` declarations; `if`/`revert` instead of string `require`).

Previously the contract used string-based `require` messages such as:

- `LDP: INVALID_USER`
- `LDP: STALE_ORACLE`
- `LDP: HF_BELOW_ONE`

Using custom errors lowers deploy bytecode size and reduces revert gas.

Example:

```solidity
error InvalidUser();
error InvalidReserve();
error StaleOracle(address reserve);
error OracleNotSet();
error HealthFactorBelowOne();
error InvalidRateMode(uint256 rateMode);
```

Then replace:

```solidity
require(user != address(0), "LDP: INVALID_USER");
```

with:

```solidity
if (user == address(0)) revert InvalidUser();
```

### 1.2 Add reserve context for oracle/config failures

**Status:** Implemented — `StaleOracle`, `InvalidLtv`, and `InvalidLiquidationThreshold` carry the offending `reserve` (and values where relevant).

When stale oracle or invalid config is detected during reserve iteration, include reserve address in error arguments for easier debugging and monitoring.

Errors:

- `StaleOracle(address reserve)`
- `InvalidLtv(address reserve, uint256 ltv)`
- `InvalidLiquidationThreshold(address reserve, uint256 liquidationThreshold)`

### 1.3 Add explicit decimal bounds checks

`_toEthValue` computes powers of ten from token decimals. If decimals are unexpectedly large, exponentiation may revert or consume unnecessary gas.

Add a bound check before scaling math:

```solidity
error UnsupportedTokenDecimals(uint8 decimals);
```

and enforce a supported range according to protocol assumptions.

### 1.4 Keep comments aligned with implementation

`calculateHealthFactor` comments mention `WadRayMath.mulDiv`, while implementation uses direct arithmetic. Keep docs/comments synchronized to avoid integration mistakes.

---

## 2) Gas Efficiency Improvements

### 2.1 Loop micro-optimizations in `_aggregateAccountData`

Small but safe improvements:

- cache `reserves.length` in a local `uint256 len`
- use `unchecked { ++i; }` in loop increment
- minimize repeated memory reads where possible

Pattern:

```solidity
uint256 len = reserves.length;
for (uint256 i; i < len; ) {
  // ...
  unchecked {
    ++i;
  }
}
```

### 2.2 Prefer one full snapshot call where possible

`getHealthFactor`, `getAverageLtv`, `getAverageLiquidationThreshold`, and `getTotalFeesETH` each perform a full reserve scan.

When called on-chain by other contracts, this is expensive. If integration allows, prefer a single `getUserAccountData` call and reuse returned fields.

### 2.3 Early exits in validation paths

In user-side borrow checks, fail as early as possible (e.g., no collateral or zero borrow capacity) before extra derived computations, to reduce average execution cost on invalid inputs.

### 2.4 Keep immutable pool

`pool` as `immutable` is already gas-efficient and safer than repeated storage loads. The note suggesting removal of immutable can be removed unless upgradeability architecture requires a different pattern.

---

## 3) Arithmetic Safety and Precision

### 3.1 Use full-precision mul/div for cross-precision operations

Expressions like:

- `(tokenAmount * price) / WAD`
- `(totalCollateralETH * liquidationThreshold) / BPS`

can overflow on intermediate multiplication even if final result would fit.

Use a full-precision `mulDiv` helper (e.g., from math library) to improve safety and precision:

```solidity
collateralAdjusted = Math.mulDiv(totalCollateralETH, liquidationThreshold, BPS);
```

and similarly in `_toEthValue`.

### 3.2 Optional protocol invariant checks

If protocol design assumes it, enforce:

- `ltv <= liquidationThreshold <= MAX_BPS`

This prevents misconfigured reserves from creating invalid risk profiles.

---

## 4) Suggested Prioritization

1. **High**: custom errors migration (low risk, immediate gas + debugging gains)  
2. **High**: decimal bounds + full-precision mul/div in conversion/math paths  
3. **Medium**: loop micro-optimizations in account aggregation  
4. **Medium**: stronger reserve config invariants (if protocol intends strict relation between LTV and LT)  
5. **Low**: cleanup of stale comments and TODO notes

---

## 5) Recommended Next Step

Implement changes in this order:

1. Introduce custom errors and replace `require` strings.
2. Refactor `_toEthValue` and `calculateHealthFactor` to use safe mul/div.
3. Apply loop gas micro-optimizations and run tests/benchmarks.
4. Optionally add invariant enforcement for reserve configuration.

---

## Related documentation

- [LendingPoolDataProvider — Threat model and mitigations](./LendingPoolDataProvider-Security.md)

