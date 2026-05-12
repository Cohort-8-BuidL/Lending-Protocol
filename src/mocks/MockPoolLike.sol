// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolLike} from '../interfaces/IPoolLike.sol';
import {IPriceOracle} from '../interfaces/IPriceOracle.sol';

/// @dev Test/staging mock for IPoolLike.
///      TODO(prod): replace with real LendingPoolCore read surface.
///
///      SECURITY: all state-mutating setters are restricted to `owner`.
///      This prevents arbitrary manipulation on shared testnets.
contract MockPoolLike is IPoolLike {
  address public immutable owner;

  IPriceOracle internal oracle;
  address[] internal reserves;

  mapping(address reserve => bool initialized) internal isReserveInitialized;
  mapping(address reserve => ReserveConfiguration) internal reserveConfiguration;
  mapping(address reserve => ReserveFlags) internal reserveFlags;
  mapping(address reserve => uint8 decimals) internal reserveDecimals;
  mapping(address reserve => uint256 availableLiquidity) internal reserveAvailableLiquidity;

  mapping(address user => mapping(address reserve => bool enabled)) internal userCollateralEnabled;
  mapping(address user => mapping(address reserve => uint256 amount))
    internal userCollateralBalance;
  mapping(address user => mapping(address reserve => uint256 amount)) internal userDebtBalance;
  mapping(address user => mapping(address reserve => uint256 amount)) internal userOriginationFee;

  modifier onlyOwner() {
    require(msg.sender == owner, 'MockPool: NOT_OWNER');
    _;
  }

  constructor() {
    owner = msg.sender;
  }

  // Setters (owner-only)
  function setPriceOracle(IPriceOracle newOracle) external onlyOwner {
    oracle = newOracle;
  }

  function addReserve(
    address reserve,
    uint8 decimals_,
    uint256 ltv,
    uint256 liquidationThreshold
  ) external onlyOwner {
    if (!isReserveInitialized[reserve]) {
      reserves.push(reserve);
      isReserveInitialized[reserve] = true;
    }
    reserveDecimals[reserve] = decimals_;
    reserveConfiguration[reserve] = ReserveConfiguration({
      ltv: ltv,
      liquidationThreshold: liquidationThreshold
    });
    // Default flags: active, borrowing enabled, stable disabled.
    reserveFlags[reserve] = ReserveFlags({
      isActive: true,
      borrowingEnabled: true,
      stableBorrowingEnabled: false
    });
    reserveAvailableLiquidity[reserve] = type(uint256).max;
  }

  function setReserveFlags(
    address reserve,
    bool isActive,
    bool borrowingEnabled,
    bool stableBorrowingEnabled
  ) external onlyOwner {
    reserveFlags[reserve] = ReserveFlags({
      isActive: isActive,
      borrowingEnabled: borrowingEnabled,
      stableBorrowingEnabled: stableBorrowingEnabled
    });
  }

  function setReserveAvailableLiquidity(address reserve, uint256 amount) external onlyOwner {
    reserveAvailableLiquidity[reserve] = amount;
  }

  function setReserveConfiguration(
    address reserve,
    uint256 ltv,
    uint256 liquidationThreshold
  ) external onlyOwner {
    reserveConfiguration[reserve] = ReserveConfiguration({
      ltv: ltv,
      liquidationThreshold: liquidationThreshold
    });
  }

  function setUserUsingReserveAsCollateral(
    address user,
    address reserve,
    bool enabled
  ) external onlyOwner {
    userCollateralEnabled[user][reserve] = enabled;
  }

  function setUserCollateralBalance(
    address user,
    address reserve,
    uint256 amount
  ) external onlyOwner {
    userCollateralBalance[user][reserve] = amount;
  }

  function setUserCompoundedBorrowBalance(
    address user,
    address reserve,
    uint256 amount
  ) external onlyOwner {
    userDebtBalance[user][reserve] = amount;
  }

  function setUserOriginationFee(address user, address reserve, uint256 amount) external onlyOwner {
    userOriginationFee[user][reserve] = amount;
  }

  // ── IPoolLike read surface ────────────────────────────────────────────────

  function getPriceOracle() external view override returns (IPriceOracle) {
    return oracle;
  }

  function getReservesList() external view override returns (address[] memory) {
    return reserves;
  }

  function isUserUsingReserveAsCollateral(
    address user,
    address reserve
  ) external view override returns (bool) {
    return userCollateralEnabled[user][reserve];
  }

  function getUserCollateralBalance(
    address user,
    address reserve
  ) external view override returns (uint256) {
    return userCollateralBalance[user][reserve];
  }

  function getUserCompoundedBorrowBalance(
    address user,
    address reserve
  ) external view override returns (uint256) {
    return userDebtBalance[user][reserve];
  }

  function getUserOriginationFee(
    address user,
    address reserve
  ) external view override returns (uint256) {
    return userOriginationFee[user][reserve];
  }

  function getReserveConfiguration(
    address reserve
  ) external view override returns (ReserveConfiguration memory) {
    return reserveConfiguration[reserve];
  }

  function getReserveDecimals(address reserve) external view override returns (uint8) {
    return reserveDecimals[reserve];
  }

  function getReserveFlags(address reserve) external view override returns (ReserveFlags memory) {
    return reserveFlags[reserve];
  }

  function getReserveAvailableLiquidity(address reserve) external view override returns (uint256) {
    return reserveAvailableLiquidity[reserve];
  }
}
