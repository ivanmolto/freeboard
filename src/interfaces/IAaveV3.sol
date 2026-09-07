// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAaveV3 — the Aave v3 registry, so no Aave address in this repo is typed from memory
/// @notice The Pool interface Freeboard's pricing path uses is NOT here: it is
///         `IAaveV3Pool.sol`, and it declares `getUserAccountData` and nothing else (T13). The
///         mutating entrypoints that build real positions for fork tests are not here either —
///         they are `IAaveV3PoolFixture` under `test/utils/AaveFixtures.sol`, deliberately
///         outside `src/`, so no type reachable from the pricing path can express a write to
///         Aave. See CLAUDE.md, "WHAT FREEBOARD NEVER DOES".
///
/// @dev Every declaration here is copied from `aave-dao/aave-v3-origin`,
///      `src/contracts/interfaces/IPoolAddressesProvider.sol`.

/// @notice The Aave v3 `PoolAddressesProvider` — the registry that NAMES the Pool.
/// @dev This exists so no Aave address in this repo is a literal typed from memory:
///      `test/fork/AaveHF.t.sol` reads `getPool()` off the provider on the fork and asserts it
///      equals `Addresses.AAVE_V3_POOL`, and closes the loop the other way with
///      `Pool.ADDRESSES_PROVIDER()`.
interface IPoolAddressesProvider {
    function getMarketId() external view returns (string memory);
    function getPool() external view returns (address);
    function getPriceOracle() external view returns (address);
    function getACLAdmin() external view returns (address);
    function getACLManager() external view returns (address);
    function getPoolDataProvider() external view returns (address);
}
