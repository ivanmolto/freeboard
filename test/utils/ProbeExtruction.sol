// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";

/// @title ProbeExtruction
/// @notice A recording extruction target. NOT FreeboardExtruction — this contract exists only
///         to prove that a program byte 0x20 dispatches to its target on the DEPLOYED
///         AquaSwapVMRouter, carrying the SwapQuery/SwapRegisters we expect.
/// @dev Signature is the one both extruction interfaces share, quoted from the pinned
///      swap-vm v1.0.2 `src/instructions/Extruction.sol:17-30` (`IExtruction`) and
///      `:39-52` (`IStaticExtruction`); the two differ only in the `view` modifier, so the
///      selector is identical.
///
///      Declared NON-view on purpose. `Extruction._extruction` picks the interface from
///      `ctx.vm.isStaticContext` (`Extruction.sol:95-113`): `quote()` goes through
///      `IStaticExtruction`, which is `view`, so the compiler emits a STATICCALL and no
///      storage write may happen; `swap()` goes through `IExtruction` with a plain CALL, where
///      recording is allowed. Hence the `if (!isStaticContext)` guard on the recorder.
///
///      The RETURNED registers are computed from every input EXCEPT `isStaticContext`, so the
///      two paths price identically — the determinism the interface natspec demands
///      ("The same inputs MUST yield the same swap amounts in both interfaces").
contract ProbeExtruction {
    uint256 public calls;

    uint256 public lastNextPC;
    SwapQuery public lastQuery;
    SwapRegisters public lastSwap;
    bytes public lastArgs;
    bytes public lastTakerData;

    /// @notice The price this probe returns for a given call, as a pure function of the inputs.
    /// @dev Every byte the router passes feeds the hash, so one byte of drift between what the
    ///      test expects and what the router actually sent changes `amountOut`. Bounded to
    ///      [1e15, 2e15) so the settled amount reads as a trade in an 18-decimal token rather
    ///      than dust, and is never zero — `TakerTraitsLib.validate` requires `amountOut > 0`
    ///      (`src/libs/TakerTraits.sol:173`, `TakerTraitsAmountOutMustBeGreaterThanZero`).
    function priceOf(
        uint256 nextPC,
        SwapQuery memory query,
        SwapRegisters memory swap,
        bytes memory args,
        bytes memory takerData
    ) public pure returns (uint256) {
        return 1e15 + (uint256(keccak256(abi.encode(nextPC, query, swap, args, takerData))) % 1e15);
    }

    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap) {
        if (!isStaticContext) {
            calls++;
            lastNextPC = nextPC;
            lastQuery = query;
            lastSwap = swap;
            lastArgs = args;
            lastTakerData = takerData;
        }

        // The router overwrites ctx.swap wholesale with updatedSwap (Extruction.sol:96, :105:
        // `(ctx.vm.nextPC, choppedLength, ctx.swap) = I[Static]Extruction(target).extruction(...)`),
        // so every register we do not copy forward is zeroed. Copy, then re-price.
        updatedSwap = swap;
        updatedSwap.amountOut = priceOf(nextPC, query, swap, args, takerData);

        // nextPC unchanged: this instruction is last in the program, so runLoop terminates.
        updatedNextPC = nextPC;
        // Consume no taker data. tryChopTakerArgs truncates silently and the require after it
        // reverts on a shortfall (Extruction.sol:114-115), so 0 is the only safe default here.
        choppedLength = 0;
    }
}
