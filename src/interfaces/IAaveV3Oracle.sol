// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAaveV3Oracle — the ONE oracle call Freeboard makes, and nothing else
/// @notice One function, on purpose, for the same reason `IAaveV3Pool` has one: the pricing
///         path holds no type that can do anything but read a price. `FreeboardExtruction`
///         values every basket leg in the oracle's base currency so that the composition it
///         prices and the health factor it prices AGAINST are computed from the same numbers —
///         Aave's `GenericLogic.calculateUserAccountData` values collateral and debt through
///         exactly this call.
///
/// @dev NEVER A PINNED ADDRESS. The extruction resolves the oracle from the
///      `PoolAddressesProvider` on every fill (`getPriceOracle()`), which is what the Pool
///      itself does inside `getUserAccountData`. A governance oracle migration therefore moves
///      the health factor and the basket valuation together; a pinned oracle would let them
///      drift apart. `Addresses.AAVE_V3_ORACLE` exists for the test fixture that warps prices,
///      and `AaveHealthFactorForkTest` asserts it is what the provider resolves to at the pin.
///
/// @dev Copied from `aave-dao/aave-v3-origin`, `src/contracts/interfaces/IPriceOracleGetter.sol`.
///      `AaveOracle.getAssetPrice` (quoted in `test/utils/OracleWarp.sol`) returns the source's
///      `latestAnswer()` when positive and otherwise falls through to a fallback oracle, which
///      is `address(0)` on mainnet, so an unreadable price is a revert there and not a zero.
///      The extruction still refuses a zero by name rather than trusting that.
interface IAaveV3Oracle {
    /// @notice Returns the asset price in the base currency
    /// @param asset The address of the asset
    /// @return The price of the asset
    /// @dev Base currency units: `BASE_CURRENCY_UNIT`, which is USD at 1e8 on Ethereum mainnet
    ///      (`Addresses.AAVE_BASE_CURRENCY_UNIT`). Every leg is scaled by the same unit, and the
    ///      distance is invariant under it, so the unit never appears in the pricing.
    function getAssetPrice(address asset) external view returns (uint256);
}
