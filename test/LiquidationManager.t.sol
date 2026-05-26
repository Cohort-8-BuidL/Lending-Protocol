// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {LendingPoolCore} from "../src/LendingPoolCore.sol";
import {LiquidationManager} from "../src/LiquidationManager.sol";
import {ILendingPoolDataProvider} from "../src/interfaces/ILendingPoolDataProvider.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IAToken} from "../src/interfaces/IAToken.sol";
import {IStableDebtToken} from "../src/interfaces/IStableDebtToken.sol";
import {WadRayMath} from "../src/WadRayMath.sol";

contract LiquidationManagerTest is Test {
    using WadRayMath for uint256;

    uint256 private constant RAY = 1e27;

    address private constant POOL = address(0xA001);
    address private constant CONFIGURATOR = address(0xA002);
    address private constant ATTACKER = address(0xDEAD);
    address private constant LIQUIDATOR = address(0xBEEF);

    address private constant BORROWER = address(0xB0B);

    address private constant COLLATERAL_ASSET = address(0xC001);
    address private constant DEBT_ASSET = address(0xC002);

    address private constant COLLATERAL_ATOKEN = address(0xD001);
    address private constant COLLATERAL_STABLE_DEBT = address(0xD002);
    address private constant COLLATERAL_VARIABLE_DEBT = address(0xD003);
    address private constant DEBT_ATOKEN = address(0xD101);
    address private constant DEBT_STABLE_DEBT = address(0xD102);
    address private constant DEBT_VARIABLE_DEBT = address(0xD103);

    address private constant COLLATERAL_STRATEGY = address(0xE001);
    address private constant DEBT_STRATEGY = address(0xE002);

    LendingPoolCore private core;
    LiquidationManager private liquidationManager;
    MockDataProvider private dataProvider;
    MockPriceOracle private oracle;
    MockAToken private collateralAToken;
    MockDebtToken private stableDebtToken;
    MockDebtToken private variableDebtToken;

    function setUp() public {
        dataProvider = new MockDataProvider();
        oracle = new MockPriceOracle();
        collateralAToken = new MockAToken();
        stableDebtToken = new MockDebtToken();
        variableDebtToken = new MockDebtToken();

        core = new LendingPoolCore(POOL, CONFIGURATOR);

        vm.startPrank(CONFIGURATOR);
        core.initReserve(
            COLLATERAL_ASSET,
            address(collateralAToken),
            address(stableDebtToken),
            address(variableDebtToken),
            COLLATERAL_STRATEGY
        );
        core.initReserve(
            DEBT_ASSET,
            address(collateralAToken),
            address(stableDebtToken),
            address(variableDebtToken),
            DEBT_STRATEGY
        );

        core.setReserveConfiguration(COLLATERAL_ASSET, _packReserveConfiguration(18, 10500));
        core.setReserveConfiguration(DEBT_ASSET, _packReserveConfiguration(18, 10500));
        vm.stopPrank();

        liquidationManager = new LiquidationManager(address(core), address(dataProvider), POOL);

        oracle.setAssetPrice(COLLATERAL_ASSET, 1e18);
        oracle.setAssetPrice(DEBT_ASSET, 1e18);

        dataProvider.setHealthFactor(BORROWER, 0.8e27);
        dataProvider.setCollateralEnabled(BORROWER, COLLATERAL_ASSET, true);
        collateralAToken.setBalance(BORROWER, 1_000e18);
    }

    function test_executeLiquidation_revertsWhenCallerIsNotLendingPool() public {
        vm.prank(ATTACKER);
        vm.expectRevert(LiquidationManager.OnlyLendingPool.selector);
        liquidationManager.executeLiquidation(COLLATERAL_ASSET, DEBT_ASSET, BORROWER, 1e18, LIQUIDATOR);
    }

    function test_executeLiquidation_revertsWhenOracleNotSet() public {
        _seedStableBorrow(100e18, 90e18, 100e18);

        vm.prank(POOL);
        vm.expectRevert(LiquidationManager.OracleNotSet.selector);
        liquidationManager.executeLiquidation(COLLATERAL_ASSET, DEBT_ASSET, BORROWER, 50e18, LIQUIDATOR);
    }

    function test_executeLiquidation_revertsWhenOraclePriceIsZero() public {
        _seedStableBorrow(100e18, 90e18, 100e18);
        _configureOracle();
        oracle.setAssetPrice(DEBT_ASSET, 0);

        vm.prank(POOL);
        vm.expectRevert(abi.encodeWithSelector(LiquidationManager.InvalidOraclePrice.selector, DEBT_ASSET));
        liquidationManager.executeLiquidation(COLLATERAL_ASSET, DEBT_ASSET, BORROWER, 50e18, LIQUIDATOR);
    }

    function test_executeLiquidation_revertsWhenHealthFactorIsHealthy() public {
        _seedStableBorrow(100e18, 90e18, 100e18);
        _configureOracle();
        dataProvider.setHealthFactor(BORROWER, RAY);

        vm.prank(POOL);
        vm.expectRevert(LiquidationManager.HealthFactorNotBelowThreshold.selector);
        liquidationManager.executeLiquidation(COLLATERAL_ASSET, DEBT_ASSET, BORROWER, 50e18, LIQUIDATOR);
    }

    function test_executeLiquidation_revertsWhenCollateralNotEnabled() public {
        _seedStableBorrow(100e18, 90e18, 100e18);
        _configureOracle();
        dataProvider.setCollateralEnabled(BORROWER, COLLATERAL_ASSET, false);

        vm.prank(POOL);
        vm.expectRevert(LiquidationManager.CollateralNotEnabledForUser.selector);
        liquidationManager.executeLiquidation(COLLATERAL_ASSET, DEBT_ASSET, BORROWER, 50e18, LIQUIDATOR);
    }

    function test_executeLiquidation_revertsWhenNoBorrowBalance() public {
        _configureOracle();
        dataProvider.setCompoundedBorrowBalance(BORROWER, DEBT_ASSET, 0);

        vm.prank(POOL);
        vm.expectRevert(LiquidationManager.NoBorrowBalance.selector);
        liquidationManager.executeLiquidation(COLLATERAL_ASSET, DEBT_ASSET, BORROWER, 50e18, LIQUIDATOR);
    }

    function test_executeLiquidation_capsDebtToCloseFactorAndEmitsEvent() public {
        _seedStableBorrow(120e18, 100e18, 120e18);
        _configureOracle();

        vm.expectEmit(true, true, true, true);
        emit LiquidationManager.LiquidationCall(
            COLLATERAL_ASSET,
            DEBT_ASSET,
            BORROWER,
            60e18,
            63e18,
            LIQUIDATOR,
            block.timestamp
        );

        vm.prank(POOL);
        LiquidationManager.LiquidationResult memory result = liquidationManager.executeLiquidation(
            COLLATERAL_ASSET,
            DEBT_ASSET,
            BORROWER,
            80e18,
            LIQUIDATOR
        );

        assertEq(result.actualDebtToCover, 60e18, "close factor cap");
        assertEq(result.collateralAmountToSeize, 63e18, "bonus applied");
        assertEq(result.accruedInterest, 20e18, "principal to compounded delta");
        assertTrue(result.isStableBorrow, "stable borrow path");
    }

    function test_executeLiquidation_capsCollateralAndUsesVariablePrincipal() public {
        _seedVariableBorrow(100e18, 90e18, 42e18);
        _configureOracle();

        vm.expectEmit(true, true, true, true);
        emit LiquidationManager.LiquidationCall(
            COLLATERAL_ASSET,
            DEBT_ASSET,
            BORROWER,
            40e18,
            42e18,
            LIQUIDATOR,
            block.timestamp
        );

        vm.prank(POOL);
        LiquidationManager.LiquidationResult memory result = liquidationManager.executeLiquidation(
            COLLATERAL_ASSET,
            DEBT_ASSET,
            BORROWER,
            80e18,
            LIQUIDATOR
        );

        assertEq(result.actualDebtToCover, 40e18, "collateral cap backsolves debt");
        assertEq(result.collateralAmountToSeize, 42e18, "collateral capped to balance");
        assertEq(result.accruedInterest, 10e18, "variable principal delta");
        assertFalse(result.isStableBorrow, "variable borrow path");
    }

    function _configureOracle() internal {
        vm.prank(CONFIGURATOR);
        core.setPriceOracle(address(oracle));
    }

    function _seedStableBorrow(uint256 compoundedDebt, uint256 principalDebt, uint256 collateralBalance) internal {
        dataProvider.setHealthFactor(BORROWER, 0.8e27);
        dataProvider.setCollateralEnabled(BORROWER, COLLATERAL_ASSET, true);
        dataProvider.setCompoundedBorrowBalance(BORROWER, DEBT_ASSET, compoundedDebt);

        stableDebtToken.setBalance(BORROWER, compoundedDebt);
        stableDebtToken.setPrincipal(BORROWER, principalDebt);
        variableDebtToken.setBalance(BORROWER, 0);
        variableDebtToken.setPrincipal(BORROWER, 0);

        collateralAToken.setBalance(BORROWER, collateralBalance);
    }

    function _seedVariableBorrow(uint256 compoundedDebt, uint256 principalDebt, uint256 collateralBalance) internal {
        dataProvider.setHealthFactor(BORROWER, 0.8e27);
        dataProvider.setCollateralEnabled(BORROWER, COLLATERAL_ASSET, true);
        dataProvider.setCompoundedBorrowBalance(BORROWER, DEBT_ASSET, compoundedDebt);

        stableDebtToken.setBalance(BORROWER, 0);
        stableDebtToken.setPrincipal(BORROWER, 0);
        variableDebtToken.setBalance(BORROWER, 0);
        variableDebtToken.setPrincipal(BORROWER, principalDebt);

        collateralAToken.setBalance(BORROWER, collateralBalance);
    }

    function _packReserveConfiguration(uint256 decimals, uint256 liquidationBonus) internal pure returns (uint256) {
        uint256 data = 8000 | (8500 << 16) | (liquidationBonus << 32) | (decimals << 48);
        data |= (1 << 56) | (1 << 57) | (1 << 58);
        return data;
    }
}

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) private _prices;

    function setAssetPrice(address asset, uint256 price) external {
        _prices[asset] = price;
    }

    function getAssetPrice(address asset) external view returns (uint256 priceInETH) {
        return _prices[asset];
    }
}

contract MockDataProvider is ILendingPoolDataProvider {
    mapping(address => uint256) private _healthFactor;
    mapping(address => mapping(address => bool)) private _collateralEnabled;
    mapping(address => mapping(address => uint256)) private _compoundedBorrowBalance;

    function setHealthFactor(address user, uint256 healthFactor) external {
        _healthFactor[user] = healthFactor;
    }

    function setCollateralEnabled(address user, address reserve, bool enabled) external {
        _collateralEnabled[user][reserve] = enabled;
    }

    function setCompoundedBorrowBalance(address user, address reserve, uint256 balance) external {
        _compoundedBorrowBalance[user][reserve] = balance;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor[user];
    }

    function getUserAccountData(address)
        external
        pure
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
        return (0, 0, 0, 0, 0, 0, 0);
    }

    function getCompoundedBorrowBalance(address user, address reserve) external view returns (uint256) {
        return _compoundedBorrowBalance[user][reserve];
    }

    function isUserUsingReserveAsCollateral(address user, address reserve) external view returns (bool) {
        return _collateralEnabled[user][reserve];
    }

    function getAverageLiquidationThreshold(address) external pure returns (uint256 avgThreshold) {
        return 0;
    }
}

contract MockAToken is IAToken {
    mapping(address => uint256) private _balances;

    function setBalance(address user, uint256 balance) external {
        _balances[user] = balance;
    }

    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    function transferOnLiquidation(address, address, uint256) external pure {
    }

    function mint(address, uint256, uint256) external pure {
    }

    function burn(address, address, uint256, uint256) external pure {
    }
}

contract MockDebtToken is IStableDebtToken {
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _principalBalances;

    function setBalance(address user, uint256 balance) external {
        _balances[user] = balance;
    }

    function setPrincipal(address user, uint256 principal) external {
        _principalBalances[user] = principal;
    }

    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    function principalBalanceOf(address user) external view returns (uint256) {
        return _principalBalances[user];
    }

    function getUserStableRate(address) external pure returns (uint256) {
        return 0;
    }

    function burn(address, uint256) external pure {
    }
}
