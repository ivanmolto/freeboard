// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAaveV3Pool — the ONE Aave v3 call Freeboard makes, and nothing else
/// @notice This interface declares a single function on purpose. `getUserAccountData` is the
///         only thing `FreeboardExtruction` asks the lending protocol for, and a type that
///         cannot express `supply`, `borrow` or `repay` is the cheapest possible proof that the
///         pricing path cannot perform them — see CLAUDE.md, "WHAT FREEBOARD NEVER DOES".
///         Freeboard never touches the debt; it only changes what the collateral is made of.
///         The test fixtures that DO build real Aave positions use a separate interface that
///         lives under `test/` (`test/utils/AaveFixtures.sol`), not here.
///
/// @dev THE ARGUMENT IS ALWAYS `query.maker`. `FreeboardExtruction._healthFactor` is called with
///      the maker the ROUTER put in `SwapQuery`, never with an address decoded from the
///      extruction's `args` and never with one from taker data. The curve committed by `ship()`
///      is a risk policy over the SHIPPER'S OWN position; a strategy that could name its subject
///      would let a maker price their basket off somebody else's health factor — a stranger's
///      liquidation risk deciding a third party's rebalance. Freeboard makes that unexpressible:
///      the address is not an input to the program.
///
/// @dev VERIFIED AGAINST THE DEPLOYED POOL, not just against upstream source. T8 read
///      `Addresses.AAVE_V3_POOL` on the mainnet fork at `FORK_BLOCK` and rebuilt all six return
///      values from prices, aToken balances and liquidation thresholds
///      (`test_ReturnShape_DecimalsAreBase1e8ForValues_Bps_AndWadForHealthFactor`), resolved the
///      Pool address from the `PoolAddressesProvider` rather than pasting it
///      (`test_AaveAddresses_ResolveFromTheProviderAndRoundTrip`), and enumerated the read's
///      revert set and gas (`docs/NOTES-gas.md`). The selector this declaration produces is
///      `0xbf92857c`, asserted in `HealthFactorForkTest`.
///
/// @dev The declaration below is copied from `aave-dao/aave-v3-origin`,
///      `src/contracts/interfaces/IPool.sol`. Return parameter NAMES and ORDER are preserved
///      verbatim because the six-tuple's order is load-bearing: `healthFactor` is the SIXTH
///      return value, and reading the fifth by mistake yields `ltv` in bps, which looks like a
///      plausible number and is not.
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
    ///
    /// @dev WAD is exactly what `libs/Curve.sol` takes, so the health factor crosses from Aave
    ///      into the curve with no conversion, sentinel included: `type(uint256).max` clamps to
    ///      the top row (`test_NoDebtSentinel_MaxUint256_ClampsToTheTop`).
    ///
    /// @dev `view`, and deterministic within a block: it reads the pool's own state and its
    ///      oracle, with no writes and no time dependence. That is why it is safe on the pricing
    ///      path — `quote()` (STATICCALL) and `swap()` (CALL) in the same block see the same
    ///      number (`test_StaticCall_AndCall_AgreeWithinTheSameBlock`), so the external call
    ///      does not break the quote/swap consistency `IExtruction` demands.
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
}
