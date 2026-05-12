# LendingPoolDataProvider — Threat Model and Mitigations

This document describes realistic attack and failure scenarios for `src/LendingPoolDataProvider.sol`, how they materialize, and practical mitigations. Custom errors improve revert gas and observability; they do **not** change trust assumptions or economic security.

---

## Trust boundaries

The contract treats `IPoolLike` (the immutable `pool`) and `IPriceOracle` as **sources of truth**. Any compromise or bug there propagates to health factor (HF), loan-to-value (LTV), available borrows, and `validateBorrow` outcomes.

---

## 1. Malicious or compromised pool

**Scenario:** Governance upgrades the pool to a malicious implementation, or a bug returns wrong balances, decimals, reserve configuration, flags, or reserve ordering.

**Impact:** Arbitrary HF/LTV/available-borrow values; `validateBorrow` may pass or fail incorrectly relative to real protocol risk.

**Mitigations:**

- Use an **immutable**, **verified** pool address; constrain upgrades via timelock, multisig, and audits.
- Enforce **invariants at the pool layer** (decimals bounds, config consistency, reserve lifecycle).
- **Operational monitoring**: compare provider outputs against independent indexing or spot checks.

---

## 2. Oracle manipulation or incorrect non-zero prices

**Scenario:** The protocol reverts when `price == 0` for a reserve with a non-zero position (`StaleOracle`), which prevents silently skipping collateral while counting debt. An attacker who can still influence **non-zero** prices (thin liquidity, compromised feed, delayed updates) shifts valuations.

**Impact:** Misstated collateral/debt in ETH terms; distorted HF and borrow capacity; incorrect liquidation triggers if downstream systems rely solely on this view.

**Mitigations:**

- Implement **robust oracle design** outside this contract: TWAP or median across sources, **staleness checks** (timestamps), **deviation bands**, circuit breakers, and redundancy.
- **Pause** borrowing or liquidations when oracle quality is degraded.

---

## 3. Rounding and boundary health factor

**Scenario:** Integer division and mixed precision can place **post-borrow HF** immediately below `1 ray` while intuition expects equality, or vice versa.

**Impact:** Unexpected reverts on `validateBorrow` (`HealthFactorBelowOne`) or users operating closer to liquidation than UIs suggest.

**Mitigations:**

- Property tests and fuzzing near boundaries (already partially covered in tests).
- If the product requires it, introduce a small **safety margin** in validation (for example require HF ≥ `RAY + epsilon`). This is a **product trade-off**, not a universal requirement.

---

## 4. Gas denial of service via large reserve lists

**Scenario:** `getUserAccountData`, `getHealthFactor`, and related paths iterate **all reserves** returned by `getReservesList()`. An extremely large list makes **view calls** expensive; off-chain callers (RPC, indexers, bots) may **timeout**.

**Impact:** Operational degradation rather than direct theft from this contract; critical bots might fail to obtain timely HF.

**Mitigations:**

- Bound the number of listed reserves at the **pool** level, or support **pagination / user-scoped reserve sets** if the architecture allows.
- Heavy analytics via **off-chain indexing**; keep on-chain critical paths within gas budgets.

---

## 5. Misuse of `calculateHealthFactor` (pure function)

**Scenario:** `calculateHealthFactor` is **pure** and accepts arbitrary inputs. A buggy integration passes handcrafted numbers instead of values derived from aggregated pool state.

**Impact:** Misleading HF in wallets or dashboards; users act on **fake** risk metrics.

**Mitigations:**

- Document that callers must use **trusted inputs** from the same aggregation path as production (`getUserAccountData` / internal aggregation).
- In application code, avoid exposing raw `calculateHealthFactor` with user-supplied collateral/debt unless clearly labeled as hypothetical.

---

## 6. Stable-rate anti-manipulation check (design scope)

**Scenario:** `_checkStableManipulation` addresses a specific **same-reserve collateral vs stable borrow** pattern. Other stable-rate economic attacks may depend on **pool pricing and stable-rate logic**, not only this helper.

**Impact:** Risk remains if the **pool** stable borrow implementation is flawed.

**Mitigations:**

- Align rules with the **LendingPool** stable-rate design; audit the **full** stable borrow path end-to-end.

---

## 7. Integration errors after custom errors

**Scenario:** Integrators that match revert **strings** (legacy `LDP: ...`) will fail after migration to **custom errors** with ABI-encoded data.

**Impact:** Incorrect error handling in clients (wrong retries, misleading UX); not a direct on-chain theft vector.

**Mitigations:**

- Decode reverts using **error selectors** and arguments (for example `StaleOracle(address)`, `InvalidLtv(address,uint256)`).
- Provide SDK helpers or documentation listing errors exported from `LendingPoolDataProvider.sol`.

---

## Summary table

| Area | Primary risk | Typical mitigation layer |
|------|----------------|---------------------------|
| Pool state | Wrong or malicious data | Pool governance, upgrades, invariants |
| Oracle | Wrong non-zero prices | Oracle design, staleness, redundancy |
| Arithmetic | Boundary HF / rounding | Tests, optional HF margin in validation |
| Scale | Huge reserve list | Pool limits, indexing, pagination |
| Pure HF API | Untrusted inputs | Integration discipline, documentation |
| Stable borrow | Broader economic attacks | Pool + oracle + full-path audit |
| Custom errors | Client decode bugs | Documented selectors and SDK support |

---

## Related documentation

- `docs/LendingPoolDataProvider-Improvements.md` — gas, errors, and implementation notes.
