// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { IExtruction, IStaticExtruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";

import { Addresses } from "./constants/Addresses.sol";
import { IAaveV3Pool } from "./interfaces/IAaveV3Pool.sol";

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
/// @dev `view`, NOT `pure`. Since T13 the body reads chain state: one STATICCALL to Aave's
///      `getUserAccountData(query.maker)`. T14 adds the Aqua `rawBalances` reads. The
///      quote/swap consistency argument rests on `view`, not on `pure` — see
///      `_healthFactor` for why an external read does not break it.
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

    /// @notice Aave could not compute this maker's health factor, so the fill is refused.
    /// @param maker The position owner the read was for — always `query.maker`.
    /// @dev THE FILL REVERTS; IT NEVER FALLS BACK. There is no try/catch here and no default
    ///      health factor, because a default is a price, and a price computed from a number
    ///      Aave would not stand behind is exactly the mispricing this contract exists to
    ///      prevent. Refusing costs the borrower nothing: Aave's own `liquidationCall` reads
    ///      the same oracle through the same `calculateUserAccountData`, so while HF is
    ///      unreadable no liquidation is possible either — there is nothing to be late for.
    ///      (CLAUDE.md, "WHY THE HF READ IS SAFE INSIDE THE PRICING PATH"; T16 owns the
    ///      rationale and `test_RevertWhen_HealthFactorUnreadable`.)
    error FreeboardHealthFactorUnreadable(address maker);

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
    /// @dev THE HEALTH FACTOR IS READ FIRST. Solidity evaluates arguments before the call, so
    ///      `_healthFactor(query.maker)` runs ahead of `_price`'s body: an unreadable HF stops
    ///      the fill before any arithmetic, which is the ordering T16's fail-safe asks for.
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
        _price(query, updatedSwap, _healthFactor(query.maker));
        updatedNextPC = nextPC;
        choppedLength = 0;
    }

    /// @notice The maker's Aave v3 health factor, WAD, or a reverted fill.
    /// @param maker MUST be `query.maker` — the position owner the ROUTER named, taken from the
    ///        `SwapQuery` it builds from the order (swap-vm v1.0.2, `src/SwapVM.sol:130-137`,
    ///        `:176-183`). It is NEVER an address decoded from `args`, and never one from taker
    ///        data. The curve a borrower signs on the Ledger and commits with `ship()` is a risk
    ///        policy over THEIR OWN position; a strategy that could name its subject would let a
    ///        maker price their basket off a stranger's liquidation risk, or let a taker choose
    ///        whose risk to be quoted against. Freeboard makes that unexpressible rather than
    ///        merely forbidden: the address is not an input to the program. This is also why
    ///        `IAaveV3Pool` declares one function and `AAVE_V3_POOL` is a compile-time constant
    ///        — neither the subject nor the oracle of the read is chooseable.
    /// @return healthFactor WAD, 1e18 = HF 1.00; `type(uint256).max` when the maker has no debt,
    ///         which `Curve` clamps to the top row with no special case.
    ///
    /// @dev WHY AN EXTERNAL CALL HERE DOES NOT BREAK QUOTE/SWAP CONSISTENCY. `IExtruction`
    ///      warns in capitals that the two paths must agree. `getUserAccountData` is a `view`
    ///      over the pool's own state and its oracle, with no writes and no time dependence, so
    ///      it is deterministic within a block: `quote()` reaches it under STATICCALL and
    ///      `swap()` under CALL, and T8 proved the two return identical bytes in the same block
    ///      (`test_StaticCall_AndCall_AgreeWithinTheSameBlock`). The dependency is deterministic,
    ///      so the consistency the interface demands holds.
    ///
    /// @dev LOW-LEVEL, AND CHECKED FOR LENGTH. A STATICCALL to an address with no code succeeds
    ///      and returns nothing, so `success` alone would let an empty answer through, and
    ///      `abi.decode` of a short buffer reverts with NO data at all — a bare revert that says
    ///      nothing about why. Requiring exactly the six words the ABI defines turns "no pool
    ///      there", "the pool reverted" and "the pool answered short" into the same named,
    ///      deliberate refusal. The read is `staticcall` and not a typed call for one reason
    ///      only: to name the failure. What the length check cannot do is vouch for the CONTENT
    ///      of six words; that is vouched for by `AAVE_V3_POOL` being a compile-time constant,
    ///      so the only contract that can answer is the one T8 matched on the fork.
    function _healthFactor(address maker) internal view returns (uint256 healthFactor) {
        (bool ok, bytes memory ret) =
            Addresses.AAVE_V3_POOL.staticcall(abi.encodeCall(IAaveV3Pool.getUserAccountData, (maker)));
        require(ok && ret.length == 6 * 32, FreeboardHealthFactorUnreadable(maker));

        (,,,,, healthFactor) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256));
    }

    /// @dev PASS-THROUGH PRICING (T9). Fills the register the router left empty at the shipped
    ///      basket's own ratio and nothing else: no curve, no spread. This is the wiring
    ///      revision; `_healthWeightedTarget` (T14) replaces this body.
    ///
    ///      THE HEALTH FACTOR IS ALREADY READ, AND IS DELIBERATELY UNUSED HERE. T13 wired the
    ///      read and its fail-closed behaviour — both are live and tested on the deployed router
    ///      (`test_HealthFactor_IsReadForQueryMaker`) — but the curve does not price yet, so the
    ///      value has no consumer until T14 turns it into target weights. It is passed in rather
    ///      than read there so that this signature is the one T14 keeps: the third parameter is
    ///      unnamed only because nothing reads it in this revision.
    ///
    ///      Rounding follows the router's own `_xycSwapXD` (`src/instructions/XYCSwap.sol:22-33`):
    ///      floor for `amountOut`, ceiling for `amountIn`, so rounding never favours the taker.
    ///
    ///      Pure over its inputs and the block: given the same registers, the same output.
    function _price(
        SwapQuery calldata query,
        SwapRegisters memory swap,
        uint256 /* healthFactor */
    )
        internal
        pure
    {
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
