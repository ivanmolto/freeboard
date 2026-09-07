// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAaveV3 — the two Aave v3 surfaces Freeboard reads, quoted from upstream
/// @notice Freeboard NEVER writes to Aave. `IAaveV3Pool.getUserAccountData` is the only call
///         `FreeboardExtruction._healthWeightedTarget` makes into the lending protocol, and it
///         makes it with STATICCALL. The mutating entrypoints below (`supply`, `borrow`,
///         `setUserUseReserveAsCollateral`) are declared ONLY so fork tests can build a real
///         position to read; nothing under `src/` calls them, and nothing ever will —
///         see CLAUDE.md, "WHAT FREEBOARD NEVER DOES".
///
/// @dev Every declaration here is copied from `aave-dao/aave-v3-origin`,
///      `src/contracts/interfaces/IPool.sol` and `IPoolAddressesProvider.sol`. Return
///      parameter NAMES and ORDER are preserved verbatim because the six-tuple's order is
///      load-bearing: `healthFactor` is the SIXTH return value, and reading the fifth by
///      mistake yields `ltv` in bps, which looks like a plausible number and is not.

/// @notice The Aave v3 `Pool`, reached through its proxy at `Addresses.AAVE_V3_POOL`.
interface IAaveV3Pool {
    /// @notice Returns the user account data across all the reserves
    /// @param user The address of the user
    /// @return totalCollateralBase The total collateral of the user in the base currency used by the price feed
    /// @return totalDebtBase The total debt of the user in the base currency used by the price feed
    /// @return availableBorrowsBase The borrowing power left of the user in the base currency used by the price feed
    /// @return currentLiquidationThreshold The liquidation threshold of the user
    /// @return ltv The loan to value of The user
    /// @return healthFactor The current health factor of the user
    ///
    /// @dev DECIMALS, and they are not uniform:
    ///        totalCollateralBase / totalDebtBase / availableBorrowsBase — base-currency units,
    ///          `AaveOracle.BASE_CURRENCY_UNIT`. On Ethereum mainnet that is USD at 1e8.
    ///        currentLiquidationThreshold / ltv — basis points, 1e4 = 100%.
    ///        healthFactor — WAD, 1e18 = HF 1.00. `type(uint256).max` when there is no debt.
    ///      Quoted from `GenericLogic.calculateUserAccountData`:
    ///        `healthFactor = (totalDebtInBaseCurrency == 0)`
    ///        `  ? type(uint256).max`
    ///        `  : avgLiquidationThreshold.wadDiv(totalDebtInBaseCurrency) / 100_00;`
    ///      where `avgLiquidationThreshold` is still the UNNORMALISED accumulator
    ///      `SUM(collateral_base_i * liquidationThreshold_i)` at that point in the function.
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    /// @notice Returns the eMode the user is using
    function getUserEMode(address user) external view returns (uint256);

    /// @notice Returns the list of the underlying assets of all the initialized reserves
    function getReservesList() external view returns (address[] memory);

    /// @notice Returns the PoolAddressesProvider connected to this contract
    function ADDRESSES_PROVIDER() external view returns (address);

    /// @notice Returns the revision number of the contract
    function POOL_REVISION() external view returns (uint256);

    // -----------------------------------------------------------------------------------
    // Mutating — TEST FIXTURES ONLY. Freeboard never calls these. See the title NatSpec.
    // -----------------------------------------------------------------------------------

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    )
        external;

    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
}

/// @notice The Aave v3 `PoolAddressesProvider` — the registry that NAMES the Pool.
/// @dev This exists so no Aave address in this repo is a literal typed from memory:
///      `test/fork/HealthFactor.t.sol` reads `getPool()` off the provider on the fork and
///      asserts it equals `Addresses.AAVE_V3_POOL`, and closes the loop the other way with
///      `Pool.ADDRESSES_PROVIDER()`.
interface IPoolAddressesProvider {
    function getMarketId() external view returns (string memory);
    function getPool() external view returns (address);
    function getPriceOracle() external view returns (address);
    function getACLAdmin() external view returns (address);
    function getACLManager() external view returns (address);
    function getPoolDataProvider() external view returns (address);
}
