// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { IExtruction, IStaticExtruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";

/// @title FreeboardExtruction — the contract the deployed AquaSwapVMRouter calls
/// @notice Freeboard's pricing lives here, behind the ONE function the router's `_extruction`
///         instruction (opcode 0x20) reaches by selector. The router is the deployed
///         `AquaSwapVMRouter` at `Addresses.AQUA_SWAP_VM_ROUTER`, swap-vm tag v1.0.2; nothing of
///         swap-vm is redeployed or modified for this contract to run.
///
/// @dev ONE FUNCTION, TWO INTERFACES. `Extruction._extruction` picks the interface from the
///      VM's static flag (swap-vm v1.0.2, `src/instructions/Extruction.sol:95-113`):
///
///        if (ctx.vm.isStaticContext) {
///            (ctx.vm.nextPC, choppedLength, ctx.swap) = IStaticExtruction(target).extruction(...);
///        } else {
///            (ctx.vm.nextPC, choppedLength, ctx.swap) = IExtruction(target).extruction(...);
///        }
///
///      `IStaticExtruction.extruction` (`:40-51`) is `view`; `IExtruction.extruction` (`:18-29`)
///      is not. Their parameter lists are identical, so the selector is identical
///      (`PinTest.test_PinnedSwapVM_ExtructionSelectorsAgree`). One `view` implementation
///      satisfies both: Solidity lets an override tighten mutability, so `view` overrides the
///      non-view base, and `view` is exactly the base of the other. That is not a convenience.
///      It is the guarantee the interfaces demand in capital letters — "The same inputs MUST
///      yield the same swap amounts in both interfaces" — made structural: a `view` function
///      cannot write state, so there is no side effect for `quote()` and `swap()` to differ by.
///
/// @dev THE REGISTERS ARE OVERWRITTEN WHOLESALE. The router assigns `ctx.swap` from
///      `updatedSwap` (`:96`, `:105`), so any register this function does not copy forward
///      reaches settlement as zero. Every register is copied first; only the priced one is
///      then changed.
///
/// @dev IMMUTABLE. No owner, no upgrade, no constructor arguments, no storage. The code that
///      priced the quote is the code that prices the swap, in every block, forever.
///
/// @dev `view`, NOT `pure`, on purpose. In this revision the body reads no state, and solc
///      says so (warning 2018, "can be restricted to pure"). It stays `view` because that is
///      the contract's permanent mutability: T13 adds the `staticcall` to Aave's
///      `getUserAccountData(query.maker)` and T14 the Aqua `rawBalances` reads, and the
///      quote/swap consistency argument rests on `view`, not on `pure`.
///
/// @dev `isStaticContext` is accepted because the router passes it, and is never read. Pricing
///      that branches on the quote/swap flag is the non-determinism the interfaces forbid;
///      `test_QuoteAndSwapPaths_ReturnIdenticalRegisters` proves the two paths agree on the
///      deployed router.
///
/// @dev `takerData` is `ctx.takerArgs()` — the taker's remaining `instructionsArgs`, a
///      taker-controlled input (`Extruction.sol:102`, `:111`). Freeboard ignores it and
///      returns `choppedLength = 0`, consuming none of it. `tryChopTakerArgs` would truncate a
///      shortfall silently and the `require` after it would revert (`:114-115`), so zero is
///      the only value that is safe without reading the data.
contract FreeboardExtruction is IExtruction, IStaticExtruction {
    /// @dev The router preloads both balances from `AQUA.safeBalances` before the program runs
    ///      (swap-vm v1.0.2, `src/SwapVM.sol:193-194`); on the signature path they stay zero.
    ///      Freeboard prices only Aqua positions, and a zero balance is a position that cannot
    ///      be priced, so it is a revert rather than a zero quote.
    error FreeboardRequiresBothBalancesNonZero(uint256 balanceIn, uint256 balanceOut);

    /// @notice The extruction entry point, called by the deployed router at opcode 0x20.
    /// @dev Signature quoted from swap-vm v1.0.2 `src/instructions/Extruction.sol:18-29`.
    /// @param nextPC Already the offset of the instruction AFTER this one
    ///        (`src/libs/VM.sol:122-132`); returned unchanged, so the program continues — and,
    ///        with `_extruction` last in the Freeboard program, terminates.
    /// @param query Read-only swap information. `query.maker` is the position owner.
    /// @param swap The registers as the router holds them on entry.
    /// @dev The unnamed parameters are, in order, `isStaticContext` (see the contract notes),
    ///      `args` — the instruction's args with the router-stripped 20-byte target removed
    ///      (`Extruction.sol:101`, `:110`), unread in this revision — and `takerData`.
    /// @return updatedNextPC `nextPC`, unchanged.
    /// @return choppedLength 0 — no taker data consumed.
    /// @return updatedSwap Every input register copied forward, with the missing amount set.
    function extruction(
        bool, /* isStaticContext */
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata, /* args */
        bytes calldata /* takerData */
    )
        external
        view
        override(IExtruction, IStaticExtruction)
        returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap)
    {
        updatedSwap = swap;
        _price(query, updatedSwap);
        updatedNextPC = nextPC;
        choppedLength = 0;
    }

    /// @dev PASS-THROUGH PRICING (T9). Fills the register the router left empty at the shipped
    ///      basket's own ratio and nothing else: no curve, no health factor, no spread. This is
    ///      the wiring revision; `_healthWeightedTarget` (T14) replaces this body.
    ///
    ///      Rounding follows the router's own `_xycSwapXD` (`src/instructions/XYCSwap.sol:22-33`):
    ///      floor for `amountOut`, ceiling for `amountIn`, so rounding never favours the taker.
    ///
    ///      Pure over its inputs and the block: given the same registers, the same output.
    function _price(SwapQuery calldata query, SwapRegisters memory swap) internal pure {
        require(
            swap.balanceIn > 0 && swap.balanceOut > 0,
            FreeboardRequiresBothBalancesNonZero(swap.balanceIn, swap.balanceOut)
        );

        if (query.isExactIn) {
            swap.amountOut = (swap.amountIn * swap.balanceOut) / swap.balanceIn;
        } else {
            swap.amountIn = Math.ceilDiv(swap.amountOut * swap.balanceIn, swap.balanceOut);
        }
    }
}
