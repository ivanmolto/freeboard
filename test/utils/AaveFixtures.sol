// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAaveV3Pool } from "../../src/interfaces/IAaveV3Pool.sol";

/// @title AaveFixtures — the Aave v3 surface that only fork TESTS are allowed to reach
/// @notice These declarations live under `test/` on purpose. `src/interfaces/IAaveV3Pool.sol`
///         declares exactly one function, so nothing on Freeboard's pricing path holds a type
///         that can `supply`, `borrow` or re-flag collateral. The fixtures that build real
///         positions to read obviously need those calls; keeping them here means the separation
///         is enforced by where the file sits, not by a comment asking nicely.
///
/// @dev Every declaration is copied from `aave-dao/aave-v3-origin`,
///      `src/contracts/interfaces/IPool.sol` and `IAaveProtocolDataProvider.sol`.

/// @notice The deployed Pool as a TEST sees it: the one production call, plus writes.
/// @dev Inherits `IAaveV3Pool` rather than redeclaring `getUserAccountData`, so the repo has one
///      and only one declaration of the call that prices Freeboard, and a fixture reads through
///      exactly the type the extruction reads through.
interface IAaveV3PoolFixture is IAaveV3Pool {
    function getUserEMode(address user) external view returns (uint256);

    /// @notice Returns the list of the underlying assets of all the initialized reserves
    function getReservesList() external view returns (address[] memory);

    /// @notice Returns the PoolAddressesProvider connected to this contract
    function ADDRESSES_PROVIDER() external view returns (address);

    /// @notice Returns the revision number of the contract
    function POOL_REVISION() external view returns (uint256);

    // -----------------------------------------------------------------------------------
    // Mutating. Nothing under `src/` imports this file, and an `import "../test/..."` from
    // `src/` would be a visible, reviewable line — unlike a mutating function sitting inside
    // the interface the pricing path already holds, which is what this file replaces.
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

    /// @dev `IPool.sol:279-284`. The paired control's epilogue (T27) is the only caller: the
    ///      BORROWER repays with the USDC her basket holds, in both arms. Nothing of Freeboard's
    ///      calls it — see CLAUDE.md, "WHAT FREEBOARD NEVER DOES".
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
}

/// @notice `AaveProtocolDataProvider`, reached through `IPoolAddressesProvider.getPoolDataProvider()`.
interface IAaveProtocolDataProvider {
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );

    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);
}

/// @notice The aToken / variable-debt token surface the fixtures read balances through.
interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function POOL() external view returns (address);
    function scaledBalanceOf(address user) external view returns (uint256);
}
