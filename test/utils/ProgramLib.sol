// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ProgramLib
/// @notice Encoder for SwapVM program bytes.
/// @dev Wire format quoted from the pinned dependency, `@1inch/swap-vm` v1.0.2,
///      `src/libs/VM.sol:122-132` (`ContextLib.runLoop`):
///
///        for (uint256 pc = ctx.vm.nextPC; pc < programBytes.length; ) {
///            unchecked {
///                uint256 opcode = uint8(programBytes[pc++]);
///                uint256 argsLength = uint8(programBytes[pc++]);
///                uint256 nextPC = pc + argsLength;
///                bytes calldata args = programBytes[pc:nextPC];
///
///                ctx.vm.nextPC = nextPC;
///                ctx.vm.opcodes[opcode](ctx, args);
///                pc = ctx.vm.nextPC;
///            }
///        }
///
///      i.e. `[1 byte opcode][1 byte argsLength][argsLength bytes of args]`, and the
///      program counter handed to the instruction is already the offset of the NEXT
///      instruction.
library ProgramLib {
    /// @dev `Extruction._extruction` on the deployed `AquaSwapVMRouter`'s instruction table.
    ///      `AquaOpcodes._opcodes()` declares a 35-entry static array and republishes it as a
    ///      34-entry dynamic array by overwriting element 0 with the length
    ///      (`src/opcodes/AquaOpcodes.sol:79-83`), so every dispatchable index is the array
    ///      literal position minus one. `Extruction._extruction` is literal position 33
    ///      (`AquaOpcodes.sol:73`) and therefore opcode 0x20.
    ///      Derivation: docs/NOTES-instructions.md §1.1.
    uint8 internal constant EXTRUCTION = 0x20;

    /// @dev `XYCSwap._xycSwapXD` on the same table, by the same minus-one derivation: it is
    ///      array literal position 18 (`AquaOpcodes.sol:55`) and therefore opcode 0x11.
    ///      A constant-product swap over the two preloaded balance registers, taking no args:
    ///
    ///        function _xycSwapXD(Context memory ctx, bytes calldata /* args */) internal pure {
    ///            require(ctx.swap.balanceIn > 0 && ctx.swap.balanceOut > 0, XYCSwapRequiresBothBalancesNonZero(...));
    ///            if (ctx.query.isExactIn) {
    ///                require(ctx.swap.amountOut == 0, XYCSwapRecomputeDetected());
    ///                ctx.swap.amountOut = (
    ///                    (ctx.swap.amountIn * ctx.swap.balanceOut) /
    ///                    (ctx.swap.balanceIn + ctx.swap.amountIn)
    ///                );
    ///            } else { ... }
    ///        }
    ///
    ///      (`src/instructions/XYCSwap.sol:17-33`). On an Aqua order those balances are the
    ///      shipped strategy balances, which the router preloads from `AQUA.safeBalances`
    ///      before the program runs (`SwapVM.sol:193-194`) — there is no balances instruction
    ///      on this router.
    uint8 internal constant XYC_SWAP_XD = 0x11;

    /// @dev argsLength is a single byte in the wire format, so args cannot exceed 255 bytes.
    error ProgramInstructionArgsTooLong(uint256 length);

    /// @notice Encode one instruction in SwapVM wire format.
    function instruction(uint8 opcode, bytes memory args) internal pure returns (bytes memory) {
        require(args.length <= type(uint8).max, ProgramInstructionArgsTooLong(args.length));
        return abi.encodePacked(opcode, uint8(args.length), args);
    }

    // Encode an `_extruction` instruction (opcode 0x20).
    //
    // The instruction's own arg layout, quoted from `src/instructions/Extruction.sol:89-92`:
    //
    //     /// @param args.target         | 20 bytes
    //     /// @param args.extructionArgs | N bytes
    //     function _extruction(Context memory ctx, bytes calldata args) internal {
    //         address target = address(bytes20(args.slice(0, 20, ExtructionMissingTargetArg.selector)));
    //
    // The router strips those 20 bytes; the target receives `args.slice(20)`
    // (`Extruction.sol:101` quote branch, `Extruction.sol:110` swap branch) as its own
    // `args` parameter.
    function extruction(address target, bytes memory extructionArgs) internal pure returns (bytes memory) {
        return instruction(EXTRUCTION, abi.encodePacked(target, extructionArgs));
    }

    /// @notice Encode an `_xycSwapXD` instruction (opcode 0x11). It reads no args, so the
    ///         encoded instruction is exactly the two wire-format header bytes: `0x1100`.
    function xycSwapXD() internal pure returns (bytes memory) {
        return instruction(XYC_SWAP_XD, "");
    }
}
