# NOTES-instructions.md — T1

Source of every quotation below: the pinned dependency at
`node_modules/@1inch/swap-vm`, resolved from `package.json`
(`"@1inch/swap-vm": "github:1inch/swap-vm#v1.0.2"`), and
`node_modules/@1inch/aqua` (`github:1inch/aqua#v1.0.0`, commit 81c26e4 — the
deployed tag; swap-vm's own nested `aqua#0.1.0` is routed to it by
`remappings.txt`, and `IAqua.sol` is byte-identical between the two tags, so
every Aqua quotation below holds for both).

`docs/PROGRAMS.md` in the tarball is 14,308 bytes, which is the v1.0.2 document
and not `main`'s shorter rewrite. Nothing here is recalled from memory; every
signature, field and warning is quoted from the file named above it.

Line numbers are given as `file:line` against the pinned tarball.

---

## 1. The opcode table — `AquaOpcodes._opcodes()`

`src/opcodes/AquaOpcodes.sol:32-84`. The contract inherits exactly seven
instruction contracts (`AquaOpcodes.sol:19-27`):

```solidity
contract AquaOpcodes is
    Controls,
    XYCSwap,
    XYCConcentrate,
    Decay,
    Fee,
    PeggedSwap,
    Extruction
{
    constructor(address aqua) Fee(aqua) {}
```

`AquaSwapVMRouter` adds nothing to it (`src/routers/AquaSwapVMRouter.sol:26-28`):

```solidity
    /// @dev Returns instruction set for VM execution
    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
        return _opcodes();
    }
```

### 1.1 THE OFF-BY-ONE TRAP — read this before indexing anything

The array literal is declared with **35** entries but dispatches **34**. The
tail of `_opcodes()` (`AquaOpcodes.sol:77-83`):

```solidity
        // Efficiently turning static memory array into dynamic memory array
        // by rewriting _notInstruction with array length, so it's excluded from the result
        uint256 instructionsArrayLength = instructions.length - 1;
        assembly ("memory-safe") {
            result := instructions
            mstore(result, instructionsArrayLength)
        }
```

A `T[35] memory` is 35 consecutive words with **no** length prefix; a
`T[] memory` is a length word followed by its elements. `result := instructions`
aliases the dynamic array's length slot onto the static array's **first
element**, and `mstore(result, 34)` overwrites that first `_notInstruction` with
the length. So the executable table is `instructions[1..34]`, and

> **every opcode index is the array literal's position minus one.**

Reading the literal naively puts `_extruction` at `0x21`. It is at **`0x20`**.
This is the single most expensive mistake available in this file. The resulting
34-entry table below agrees byte-for-byte with the table already verified
against the deployed router in `CLAUDE.md`.

Consequences: table length is 34 = `0x22`, so **opcode `>= 0x22` is an
out-of-bounds panic**, and `runLoop` indexes it unchecked
(`libs/VM.sol:130`, `ctx.vm.opcodes[opcode](ctx, args);`).

**Second, independent confirmation** from the debug router, which writes into
the returned array by index (`src/instructions/Debug.sol:17-24`):

```solidity
    function _injectDebugOpcodes(function(Context memory, bytes calldata) internal[] memory opcodes) internal pure returns (function(Context memory, bytes calldata) internal[] memory) {
        opcodes[0] = Debug._printSwapRegisters;
        opcodes[1] = Debug._printSwapQuery;
        opcodes[2] = Debug._printContext;
        opcodes[3] = Debug._printFreeMemoryPointer;
        opcodes[4] = Debug._printGasLeft;
        return opcodes;
    }
```

`AquaOpcodesDebug` calls this on `super._opcodes()`
(`src/opcodes/AquaOpcodesDebug.sol:15-17`). The debug handlers land in the
**Debug bank**, which in the array literal occupies positions 1–5, immediately
under the `// Debug - reserved for debugging utilities` comment. Returned index
0 therefore equals literal position 1: the shift is one, as derived above. Two
independent readings agree, and both agree with the table read off the deployed
router in `CLAUDE.md`.

### 1.2 The 34 dispatchable entries

| Opcode | Instruction | Declared as |
|---|---|---|
| `0x00`–`0x09` | *(Debug bank, reserved)* | `_notInstruction` ×10 |
| `0x0a` | `Controls._jump` | `internal pure` |
| `0x0b` | `Controls._jumpIfTokenIn` | `internal pure` |
| `0x0c` | `Controls._jumpIfTokenOut` | `internal pure` |
| `0x0d` | `Controls._deadline` | `internal view` |
| `0x0e` | `Controls._onlyTakerTokenBalanceNonZero` | `internal view` |
| `0x0f` | `Controls._onlyTakerTokenBalanceGte` | `internal view` |
| `0x10` | `Controls._onlyTakerTokenSupplyShareGte` | `internal view` |
| `0x11` | `XYCSwap._xycSwapXD` | `internal pure` |
| `0x12` | `XYCConcentrate._xycConcentrateGrowLiquidity2D` | `internal` |
| `0x13` | `Decay._decayXD` | `internal` |
| `0x14` | `Controls._salt` | `internal pure` |
| `0x15` | `Fee._flatFeeAmountInXD` | `internal` |
| `0x16`–`0x1a` | *(reserved holes)* | `_notInstruction` ×5 |
| `0x1b` | `Fee._protocolFeeAmountInXD` | `internal` |
| `0x1c` | `Fee._aquaProtocolFeeAmountInXD` | `internal` |
| `0x1d` | `Fee._dynamicProtocolFeeAmountInXD` | `internal` |
| `0x1e` | `Fee._aquaDynamicProtocolFeeAmountInXD` | `internal` |
| `0x1f` | `PeggedSwap._peggedSwapGrowPriceRange2D` | `internal pure` |
| `0x20` | **`Extruction._extruction`** | `internal` |
| `0x21` | `Controls._onlyTxOriginTokenBalanceNonZero` | `internal view` |

`_notInstruction` is a real, callable no-op — not a revert
(`AquaOpcodes.sol:30`):

```solidity
    function _notInstruction(Context memory /* ctx */, bytes calldata /* args */) internal view {}
```

### 1.3 Real signatures and argument layouts

Every instruction has the same Solidity signature —
`(Context memory ctx, bytes calldata args)` — so the useful part is the packed
`args` layout, quoted from each `@param` block.

**`Controls`** (`src/instructions/Controls.sol`), with its `ControlsArgsBuilder`
encoders at `Controls.sol:12-48`:

```solidity
    /// @dev This instruction does nothing and can be used for uniqueness order hash value.
    function _salt(Context memory /* ctx */, bytes calldata /* args */) internal pure { }          // 0x14

    /// @param args.nextPC | 2 bytes (uint16)
    function _jump(Context memory ctx, bytes calldata args) internal pure                          // 0x0a

    /// @param args.token  | 20 bytes
    /// @param args.nextPC | 2 bytes (uint16)
    function _jumpIfTokenIn(Context memory ctx, bytes calldata args) internal pure                 // 0x0b
    function _jumpIfTokenOut(Context memory ctx, bytes calldata args) internal pure                // 0x0c

    /// @param args.deadline | 5 bytes
    function _deadline(Context memory ctx, bytes calldata args) internal view                      // 0x0d

    /// @param args.token | 20 bytes
    function _onlyTakerTokenBalanceNonZero(Context memory ctx, bytes calldata args) internal view  // 0x0e

    /// @param args.token     | 20 bytes
    /// @param args.minAmount | 32 bytes
    function _onlyTakerTokenBalanceGte(Context memory ctx, bytes calldata args) internal view      // 0x0f

    /// @param args.token       | 20 bytes
    /// @param args.minShareE18 | 8 bytes
    function _onlyTakerTokenSupplyShareGte(Context memory ctx, bytes calldata args) internal view  // 0x10

    /// @dev Unlike _onlyTakerTokenBalanceNonZero, this checks tx.origin instead of ctx.query.taker
    /// @param args.token | 20 bytes
    function _onlyTxOriginTokenBalanceNonZero(Context memory /* ctx */, bytes calldata args) internal view // 0x21
```

Both jumps carry the same documented ceiling (`Controls.sol:73-74`), and it
names `_extruction` as the escape hatch:

> `/// @dev LIMITATION: Jump targets are limited to uint16 (0-65,535) due to 2-byte encoding.`
> `///      For jumps to positions >= 65,536, use Extruction with custom control flow logic.`

**`XYCSwap._xycSwapXD`** — `0x11`, takes **no args**, and is `pure`
(`src/instructions/XYCSwap.sol:17-33`, quoted in full):

```solidity
    function _xycSwapXD(Context memory ctx, bytes calldata /* args */) internal pure {
        require(ctx.swap.balanceIn > 0 && ctx.swap.balanceOut > 0, XYCSwapRequiresBothBalancesNonZero(ctx.swap.balanceIn, ctx.swap.balanceOut));

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, XYCSwapRecomputeDetected());
            ctx.swap.amountOut = ( // Floor division for tokenOut is desired behavior
                (ctx.swap.amountIn * ctx.swap.balanceOut) /
                (ctx.swap.balanceIn + ctx.swap.amountIn)
            );
        } else {
            require(ctx.swap.amountIn == 0, XYCSwapRecomputeDetected());
            ctx.swap.amountIn = Math.ceilDiv( // Ceiling division for tokenIn is desired behavior
                ctx.swap.amountOut * ctx.swap.balanceIn,
                (ctx.swap.balanceOut - ctx.swap.amountOut)
            );
        }
    }
```

Note `XYCSwapRecomputeDetected` — it **reverts if the output register is already
non-zero**. Any instruction that sets an amount before `_xycSwapXD` bricks it.
This is the mechanism behind the ordering rule in §3.

**`XYCConcentrate._xycConcentrateGrowLiquidity2D`** — `0x12`
(`src/instructions/XYCConcentrate.sol:123-125`):

```solidity
    /// @param args.sqrtPriceMin | 32 bytes (uint256, 1e18 fp) — sqrt(P_min) where P = tokenGt/tokenLt
    /// @param args.sqrtPriceMax | 32 bytes (uint256, 1e18 fp) — sqrt(P_max) where P = tokenGt/tokenLt
    function _xycConcentrateGrowLiquidity2D(Context memory ctx, bytes calldata args) internal {
```

It enforces its own ordering rule via
`error ConcentrateShouldBeUsedBeforeSwapAmountsComputed(uint256 amountIn, uint256 amountOut);`
(`XYCConcentrate.sol:121`).

**`Decay._decayXD`** — `0x13` (`src/instructions/Decay.sol:79-100`, body quoted
in full because it is one of the two nesting instructions):

```solidity
    /// @notice Applies virtual balance adjustment based on time since last trade (Mooniswap-style MEV protection)
    /// @dev Gradually restores reserves to actual values over decay period
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction reads last update time
    ///   but does NOT update it. Quote may succeed while swap reverts if decay state changed between calls.
    ///   Makers MUST NOT use backward jumps to this instruction as it breaks numerical consistency between
    ///   quote() and swap().
    /// @param args.period | 2 bytes (uint16)
    function _decayXD(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, DecayShouldBeCalledBeforeSwapAmountsComputation(ctx.swap.amountIn, ctx.swap.amountOut));

        // Adjust balances by decayed offsets
        uint256 period = DecayArgsBuilder.parse(args);
        ctx.swap.balanceIn += _offsets[ctx.query.orderHash][ctx.query.tokenIn][true].getOffset(period);
        ctx.swap.balanceOut -= _offsets[ctx.query.orderHash][ctx.query.tokenOut][false].getOffset(period);

        (uint256 swapAmountIn, uint256 swapAmountOut) = ctx.runLoop();

        if (!ctx.vm.isStaticContext) {
            _offsets[ctx.query.orderHash][ctx.query.tokenIn][false].addOffset(swapAmountIn, period);
            _offsets[ctx.query.orderHash][ctx.query.tokenOut][true].addOffset(swapAmountOut, period);
        }
    }
```

**`PeggedSwap._peggedSwapGrowPriceRange2D`** — `0x1f`
(`src/instructions/PeggedSwap.sol:93-98`):

```solidity
    /// @dev Square-root linear swap with direct calculation
    /// @param args Swap configuration (X0, Y0, linearWidth, rateLt, rateGt) - 160 bytes
    /// @notice Calculates output amount directly using analytical solution
    /// @notice Uses rate multipliers to normalize tokens with different decimals
    function _peggedSwapGrowPriceRange2D(Context memory ctx, bytes calldata args) internal pure {
```

Its `Args` struct is `{x0, y0, linearWidth, rateLt, rateGt}`
(`PeggedSwap.sol:16-23`), and rate assignment is address-ordered
(`PeggedSwap.sol:25-27`):

> `/// @dev Rates are assigned based on token address comparison`
> `/// @dev When tokenIn < tokenOut: rateIn = rateLt, rateOut = rateGt`
> `/// @dev When tokenIn > tokenOut: rateIn = rateGt, rateOut = rateLt`

**`Fee`** — the four fee opcodes plus the flat fee
(`src/instructions/Fee.sol`); `BPS = 1e9` (`Fee.sol:17`):

```solidity
    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    function _flatFeeAmountInXD(Context memory ctx, bytes calldata args) internal              // 0x15

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _protocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal          // 0x1b
    function _aquaProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal      // 0x1c

    /// @param args.feeProvider | 20 bytes (address of the protocol fee provider)
    function _dynamicProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal   // 0x1d
    function _aquaDynamicProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal // 0x1e
```

**`Extruction._extruction`** — `0x20`. Quoted in full in §4.

### 1.4 What is NOT in the Aqua table

There is **no `Balances` instruction** — no `_staticBalancesXD`, no
`_dynamicBalancesXD`, no `LimitSwap`, no `Invalidators`, no `MinRate`, no
`DutchAuction`, no `TWAPSwap`, no `OraclePriceAdjuster`, no `BaseFeeAdjuster`.
Those files exist under `src/instructions/` but `AquaOpcodes` does not inherit
them.

On the Aqua path the balance registers are preloaded by the router **before**
the program runs, identically in both entry points
(`src/SwapVM.sol:147-149` in `quote()` and `SwapVM.sol:193-194` in `swap()`):

```solidity
        if (order.traits.useAquaInsteadOfSignature()) {
            (ctx.swap.balanceIn, ctx.swap.balanceOut) = AQUA.safeBalances(order.maker, address(this), orderHash, tokenIn, tokenOut);
        }
```

**This matters for Freeboard.** PROGRAMS.md's catalog examples all open with
`_staticBalancesXD` / `_dynamicBalancesXD`; those examples are written against
the full `Opcodes` set, **not** the Aqua router. Copying one onto
`AquaSwapVMRouter` dispatches a wrong opcode index. Our program must not
contain a balances instruction.

`safeBalances` also gives us only the two swapped legs. Reading the other
basket legs in T14 needs the per-token getter
(`node_modules/@1inch/aqua/src/interfaces/IAqua.sol:78`):

```solidity
    function rawBalances(address maker, address app, bytes32 strategyHash, address token) external view returns (uint248 balance, uint8 tokensCount);
```

Note the return is **`uint248`**, not `uint256`, and that `safeBalances`
"reverts if any of the tokens is not part of the active strategy"
(`IAqua.sol:80`) — so a leg absent from the strategy is a revert, not a zero.

---

## 2. `libs/VM.sol` — the four structs, quoted verbatim

All four are quoted complete from `src/libs/VM.sol:12-65`, natspec included.

```solidity
/// @dev Represents the state of the VM
/// @param isStaticContext Whether the quote is in a static context (e.g., for quoting)
/// @param nextPC The program counter for the next instruction to execute
/// @param programPtr Pointer to the program in calldata (offset and length)
/// @param takerArgsPtr Pointer to the taker's data in calldata (offset and length)
/// @param opcodes The set of instructions (functions) that can be executed by the VM
/// @dev This struct is used to track the execution state of instructions during a swap
struct VM {
    bool isStaticContext;
    uint256 nextPC;
    CalldataPtr programPtr; // Use ContextLib.program()
    CalldataPtr takerArgsPtr; // Use ContextLib.takerArgs()
    function(Context memory, bytes calldata) internal[] opcodes;
}

/// @dev Represents the read-only swap information
/// @param orderHash The unique (per maker) position/strategy identifier for the swap position
/// @param maker The address of the maker (the one who provides liquidity)
/// @param taker The address of the taker (the one who performs the swap)
/// @param tokenIn The address of the input token
/// @param tokenOut The address of the output token
struct SwapQuery {
    bytes32 orderHash;
    address maker;
    address taker;
    address tokenIn;
    address tokenOut;
    bool isExactIn;
}

/// @dev Registers used to compute missing amount: `isExactIn() ? amountOut : amountIn`
/// @param balanceIn The current balance of the input token
/// @param balanceOut The current balance of the output token
/// @param amountIn The amount of input token being swapped
/// @param amountOut The amount of output token being swapped
/// @param amountNetPulled The net amount pulled from the maker during the swap, used for fee calculations
struct SwapRegisters {
    uint256 balanceIn;
    uint256 balanceOut;
    uint256 amountIn;
    uint256 amountOut;
    uint256 amountNetPulled;
}

/// @title SwapVM context
/// @notice Complete execution state for a swap operation
/// @param vm The VM execution state including program counter and bytecode
/// @param query Read-only swap information (maker, taker, tokens, etc.)
/// @param swap Mutable registers for computing swap amounts
struct Context {
    VM vm;
    SwapQuery query;
    SwapRegisters swap;
}
```

`SwapQuery` is 6 fields / 6 words and `SwapRegisters` 5 fields / 5 words, which
is what `test/unit/Pin.t.sol` already asserts. Note the natspec for `SwapQuery`
documents only five params but the struct has six — `isExactIn` is undocumented
in the block. The README's Context tree does document it
(`README.md:752-754`):

> `│   └── isExactIn`
> `│       - Swap direction`
> `│       - true = exact in, false = exact out`

The README labels the mutability of each group (`README.md:741`, `756`):
`SwapQuery (READ-ONLY)`, `SwapRegisters (MUTABLE)`, and within `VM`, `nextPC`
`- Program counter (MUTABLE, used by jumps)` and `takerArgsPtr`
`- Taker dynamic data pointer (MUTABLE)`.

### 2.1 `runLoop` — the wire format, quoted

`libs/VM.sol:109-136`:

```solidity
    /// @notice Execute program instructions sequentially
    /// @dev Iterates through bytecode, executing each instruction until program end
    /// @dev LIMITATION: Program size is effectively limited to 65,535 bytes due to Controls
    ///      jump instructions using uint16 addressing. Programs exceeding this size can execute,
    ///      but jump instructions cannot address positions >= 65,536. For custom control flow in
    ///      larger programs, use Extruction._extruction which supports arbitrary uint256 nextPC.
    function runLoop(Context memory ctx) internal returns (uint256 swapAmountIn, uint256 swapAmountOut) {
        bytes calldata programBytes = ctx.program();
        require(ctx.vm.nextPC < programBytes.length, RunLoopExcessiveCall(ctx.vm.nextPC, programBytes.length));

        for (uint256 pc = ctx.vm.nextPC; pc < programBytes.length; ) {
            unchecked {
                uint256 opcode = uint8(programBytes[pc++]);
                uint256 argsLength = uint8(programBytes[pc++]);
                uint256 nextPC = pc + argsLength;
                bytes calldata args = programBytes[pc:nextPC];

                ctx.vm.nextPC = nextPC;
                ctx.vm.opcodes[opcode](ctx, args);
                pc = ctx.vm.nextPC;
            }
        }

        return (ctx.swap.amountIn, ctx.swap.amountOut);
    }
```

Three facts to build on: the format is `[1 byte opcode][1 byte argsLength][args]`
(so 255 args bytes max per instruction); `ctx.vm.nextPC` is written **before**
dispatch and re-read **after**, which is exactly the hook `_extruction` returns
into; and the loop terminates only when `pc >= programBytes.length`.

`tryChopTakerArgs` (`VM.sol:102-107`) silently truncates — `length = Math.min(length, data.length)` —
which is why `_extruction` has to re-check the chop afterwards (§4).

---

## 3. Instruction ORDERING is security-critical

### 3.1 What PROGRAMS.md says, quoted directly

From `docs/PROGRAMS.md:26-37`, "SwapVM Program Key Points":

> When designing a SwapVM program, we focus on these security-critical technical points:
>
> - **Instruction ordering is security-critical:**
>   - Reordering instructions can change pricing, settlement amounts, invalidation behavior, and external side effects.
>   - Fee instruction placement is especially sensitive and can alter economic outcomes.
> - **Invariant requirements must hold for the full composed program:**
>   - Symmetry, additivity profile, monotonicity, quote/swap consistency, balance sufficiency, and strategy liveness.
>   - Validate invariants with scenario tests before production deployment.

And immediately after (`PROGRAMS.md:39`):

> **Thorough testing and audit are mandatory for every program before production use.**

For AMM programs specifically (`PROGRAMS.md:121-125`):

> - **Ordering Note:** Fee instruction placement is security-critical and changes pricing/settlement behavior.
> - **Protocol fee on amountIn:** charged before the taker's tokenIn is settled, so it comes out of inventory
>   the maker already holds. The Aqua variants skip the fee and emit `ProtocolFeeSkipped` when the maker cannot
>   cover it, which keeps one-sided positions tradable; the wallet variants revert instead. Only use an Aqua
>   fee instruction on an Aqua order. See "Protocol Fee on amountIn" in the README.

On `_extruction` in particular (`PROGRAMS.md:288`):

> Complex scenarios with conditional jumps/branching (and, especially, containing ```_extruction```) should be tested very carefully; they can contain hidden logical flaws and unsafe edge paths.

And the invariant focus for conditional-flow programs, which is our category
(`PROGRAMS.md:290-295`):

> - Branch determinism and quote/swap path consistency (same inputs -> same branch).
> - Jump-target correctness (no invalid offsets, no accidental instruction skipping/corruption).
> - Authorization/gating correctness (restricted users fail, authorized users pass as intended).
> - Economic safety across all branches (no branch yields unintended favorable pricing or bypasses checks).
> - Termination/liveness: no hidden loops or dead-end paths that break execution.

The README states the same rule in bold at the head of the execution-flow
section (`README.md:99`):

> **VERY IMPORTANT:** Instruction order is security-critical. The same instructions in a different order can change strategy behavior and, in some cases, introduce dangerous outcomes. Any SwapVM program used by makers and takers should be audited before production use.

And in Maker best practices (`README.md:612`):

> - Treat instruction ordering as security-critical, especially around fee instructions

The document also opens with the scope notice (`PROGRAMS.md:7`):

> **Important Notice:** 1inch production integrations (including AggregationRouter flows) will use only a strict, predefined subset of SwapVM programs with tightly bounded parameter ranges and completed security reviews. Risk from interacting with arbitrary or maliciously crafted SwapVM programs remains with the taker/resolver choosing to execute them.

…and asks builders to (`PROGRAMS.md:11-13`):

> - Provide analytical proof (or strong formal/empirical evidence) of model stability; public notes or papers are encouraged.
> - Constrain dangerous parameter ranges in instruction builders to prevent unsafe program construction.
> - Provide a thorough composition guide when your design supports multiple instruction-order variants.

### 3.2 Ordering is not sequential — fee instructions NEST the rest of the program

This is the mechanism the ordering warnings are about, and it is stronger than
"order changes results". The README names it (`README.md:865-870`):

> #### Special: Nested Execution (`ctx.runLoop()`)
> Instructions can invoke `ctx.runLoop()` to execute remaining instructions and then continue:
> - Apply pre-processing, let other instructions compute amounts, then post-processing
> - Wrap amount computations with fee calculations
> - Wait for amount computation before validation
> - Implement complex multi-phase amount calculations

Two families in the Aqua table do this: `Decay._decayXD` (`0x13`, body in
§1.3) and the `Fee` opcodes. `_flatFeeAmountInXD` (`0x15`) calls
`ctx.runLoop()` inline in its own body (`Fee.sol:90` and `Fee.sol:94`); the
four protocol-fee variants go through `Fee._feeAmountIn` (`Fee.sol:277-293`,
quoted in full):

```solidity
    function _feeAmountIn(Context memory ctx, uint256 feeBps) internal returns (uint256 feeAmountIn) {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, FeeShouldBeAppliedBeforeSwapAmountsComputation());

        if (ctx.query.isExactIn) {
            // Decrease amountIn by fee only during swap-instruction
            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            feeAmountIn = ctx.swap.amountIn * feeBps / BPS;
            ctx.swap.amountIn -= feeAmountIn;
            ctx.runLoop();
            ctx.swap.amountIn = takerDefinedAmountIn;
        } else {
            // Increase amountIn by fee after swap-instruction
            ctx.runLoop();
            feeAmountIn = ctx.swap.amountIn * feeBps / (BPS - feeBps);
            ctx.swap.amountIn += feeAmountIn;
        }
    }
```

So a fee opcode does not run *between* its neighbours. **Everything after it in
the byte stream runs inside it.** "Before the fee opcode" and "after the fee
opcode" are not two points on a line; they are outside and inside a wrapper.

The `require` on the first line is what forces the ordering: a fee opcode placed
after any amount-computing instruction reverts with
`FeeShouldBeAppliedBeforeSwapAmountsComputation()`. `_flatFeeAmountInXD`
carries the same guard inline (`Fee.sol:83`), as do `_decayXD`
(`DecayShouldBeCalledBeforeSwapAmountsComputation`) and
`_xycConcentrateGrowLiquidity2D`
(`ConcentrateShouldBeUsedBeforeSwapAmountsComputed`).

One nuance: the two **dynamic** variants (`0x1d`, `0x1e`) call `_feeAmountIn`
only inside `if (feeBps != 0)` (`Fee.sol:184-187`, `233-236`). When the
provider returns a zero fee they nest nothing, and the outer loop simply
continues to the next instruction. Nesting is unconditional for `0x15`, `0x1b`
and `0x1c`, conditional for `0x1d` and `0x1e`. Either way the conclusions in
§3.4 hold.

Also note which variants touch `amountNetPulled` at all: only the two **Aqua**
variants (`0x1c`, `0x1e`), via `_tryPullFee`. The wallet variants (`0x1b`,
`0x1d`) settle by `safeTransferFrom` (`Fee.sol:115`, `190`) and never write the
register.

### 3.3 `_tryPullFee` mutates `amountNetPulled` DURING program execution

`Fee._tryPullFee` (`Fee.sol:246-275`, quoted in full — the comment is the
clearest statement of the accounting in the whole repo):

```solidity
    /// @dev Pulls the protocol fee from the maker's Aqua balance, tolerating a maker who cannot cover it.
    ///   The pull runs before SwapVM credits the taker's tokenIn, so it is payable only out of inventory the
    ///   maker already holds. Reverting instead would make a one-sided position untradable and cap a
    ///   two-sided one at `balanceIn * BPS / feeBps` per swap (OpenZeppelin M-09, Theori #10).
    ///
    ///   ACCEPTED RISK: pricing is not adjusted when the pull fails, so the taker still pays the fee and the
    ///   maker keeps it. Collection is therefore best-effort and the maker controls the trigger through their
    ///   own Aqua balance, wallet balance and allowance. Strategies must be validated before being
    ///   whitelisted, and ProtocolFeeSkipped must be monitored.
    ///
    ///   Both callers reject a zero recipient before reaching here, so the only failures this swallows are
    ///   a maker who cannot cover the fee and a token that refuses the transfer.
    ///
    ///   amountNetPulled is credited only when the pull lands. It reports how much tokenIn the program
    ///   already took out of the maker's ledger, which is what keeps the pre-push check in
    ///   SwapVM._transferIn resolving to "the taker owes exactly amountIn" even though the fee left the
    ///   ledger mid-swap. Crediting it for a pull that never happened would drop that requirement to
    ///   amountIn - fee and let the taker keep the fee instead of the maker.
    function _tryPullFee(Context memory ctx, address to, uint256 feeAmountIn) private {
        if (feeAmountIn == 0) return; // Nothing was skipped, so do not report a skip

        // A parameterless catch is deliberate: it is the only form that catches both the Panic from Aqua's
        // balance underflow and the custom error from the token leg, and it avoids copying revert data that
        // a malicious tokenIn could inflate.
        try _AQUA.pull(ctx.query.maker, ctx.query.orderHash, ctx.query.tokenIn, feeAmountIn, to) {
            ctx.swap.amountNetPulled += feeAmountIn;
        } catch {
            emit ProtocolFeeSkipped(ctx.query.orderHash, ctx.query.tokenIn, to, feeAmountIn);
        }
    }
```

`ctx.swap.amountNetPulled += feeAmountIn` is a **write to a shared register in
the middle of program execution**, conditional on an external call succeeding.
The register it feeds is read after `runLoop` returns, in
`SwapVM._transferIn` (`SwapVM.sol:239-240`):

```solidity
                    (uint256 balanceIn,) = AQUA.rawBalances(order.maker, address(this), ctx.query.orderHash, ctx.query.tokenIn);
                    require(balanceIn >= originalAquaBalanceIn + ctx.swap.amountIn - ctx.swap.amountNetPulled, AquaBalanceInsufficientAfterTakerPush(balanceIn, originalAquaBalanceIn, ctx.swap.amountIn, ctx.swap.amountNetPulled));
```

The README restates the timing (`README.md:569-577`):

> The protocol-fee-on-amountIn instructions charge the maker inside `runLoop()`, which runs before `SwapVM`
> settles the taker's tokenIn. The fee is therefore payable only out of tokenIn the maker already holds, not
> out of the amount the swap is about to deliver.
>
> For the Aqua variants (`_aquaProtocolFeeAmountInXD`, `_aquaDynamicProtocolFeeAmountInXD`) **collection is
> best-effort**. If the maker's Aqua balance, wallet balance or Aqua allowance cannot cover the fee, the fee is
> skipped, the swap proceeds, and the router emits `ProtocolFeeSkipped(orderHash, token, to, amount)`. This is
> what keeps one-sided positions tradable. Pricing is not adjusted, so the taker still pays for the fee and an
> uncollected fee stays with the maker.

The event's own natspec (`Fee.sol:65-67`):

> `/// @notice Emitted when an Aqua protocol fee could not be collected and the swap proceeded without it`
> `/// @dev Off-chain monitoring MUST watch this event: it is the only signal that protocol revenue was`
> `///   not collected, and an uncollected fee stays with the maker.`

### 3.4 Therefore: where `_extruction` sits relative to a fee opcode

Tracing `_aquaProtocolFeeAmountInXD` (`Fee.sol:130-144`) with an `_extruction`
placed **after** it in the byte stream:

1. The fee opcode parses `feeBps`/`to` and calls `_feeAmountIn`.
2. Exact-in: `amountIn` is **reduced by the fee**, then `ctx.runLoop()` runs the
   remainder — our `_extruction` executes here, seeing the *reduced* `amountIn`.
   After it returns, `amountIn` is restored to `takerDefinedAmountIn`.
3. Exact-out: `ctx.runLoop()` runs **first** — our `_extruction` computes
   `amountIn` — and then the fee is **added on top of what we returned**.
4. Only after `runLoop` has returned does `_tryPullFee` run and credit
   `amountNetPulled`.

Three consequences, all load-bearing for `FreeboardExtruction`:

- **An `_extruction` placed after a fee opcode always observes
  `amountNetPulled == 0` from that fee.** The credit happens strictly after the
  nested `runLoop` returns. Reading `amountNetPulled` to infer "a fee was
  charged" is unsound in that position.
- **The amounts our extruction sets are not the settled amounts.** Exact-in, we
  price against a fee-reduced `amountIn` while the taker is charged the full
  one; exact-out, the router inflates our `amountIn` after we return. Either
  way basket-distance pricing computed inside the extruction diverges from what
  actually moves.
- **Placed before the fee opcode**, our extruction runs in the outer loop with
  the taker's true `amountIn`, but then the fee instruction re-prices on top of
  it — and would revert anyway on
  `FeeShouldBeAppliedBeforeSwapAmountsComputation()` because we have already set
  an amount.

**Design conclusion for T14/T15: the Freeboard program contains no fee
instruction, and `_extruction` (`0x20`) is the last instruction in the byte
stream.** Then nothing nests it, nothing re-prices after it, and the registers
it returns are the registers `SwapVM` settles. The spread Freeboard earns comes
from the pricing curve inside the extruction, not from a fee opcode. If a fee
opcode is ever added, every number in §3.4 has to be rederived first.

---

## 4. `Extruction.sol` — verbatim

This is the contract Freeboard implements against. The whole file is
`src/instructions/Extruction.sol`, 117 lines; §4.1–§4.3 reproduce it complete.

### 4.1 `IExtruction` — verbatim (`Extruction.sol:10-30`)

```solidity
/// @title IExtruction - State-modifying external logic interface
/// @notice Interface for external contracts that implement custom swap logic during swap() execution
/// @dev CRITICAL SECURITY REQUIREMENTS:
///      - Implementations MUST produce deterministic and consistent results with IStaticExtruction
///      - The same inputs MUST yield the same swap amounts in both interfaces
///      - Non-deterministic behavior will cause quote/swap inconsistencies and unexpected execution
///      - Target contracts SHOULD be immutable (non-upgradeable) to prevent logic changes between quote/swap
interface IExtruction {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external returns (
        uint256 updatedNextPC,
        uint256 choppedLength,
        SwapRegisters memory updatedSwap
    );
}
```

### 4.2 `IStaticExtruction` — verbatim (`Extruction.sol:32-52`)

```solidity
/// @title IStaticExtruction - View-only external logic interface
/// @notice Interface for external contracts that implement custom swap logic during quote() execution
/// @dev CRITICAL SECURITY REQUIREMENTS:
///      - Implementations MUST be deterministic and consistent with IExtruction
///      - The same inputs MUST yield the same swap amounts in both interfaces
///      - This is the read-only version called during quoting operations
///      - Inconsistent implementations will break quote/swap consistency guarantees
interface IStaticExtruction {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external view returns (
        uint256 updatedNextPC,
        uint256 choppedLength,
        SwapRegisters memory updatedSwap
    );
}
```

The two differ **only** in the `view` modifier. Parameter lists, order, types
and return tuples are identical, so the selector is identical — which is why a
single `view` `extruction()` satisfies both, and why declaring ours `view` makes
quote/swap consistency structural rather than a property we have to test into
existence. `test/unit/Pin.t.sol::test_PinnedSwapVM_ExtructionSelectorsAgree`
already asserts `IExtruction.extruction.selector == IStaticExtruction.extruction.selector`.

### 4.3 `contract Extruction` — verbatim (`Extruction.sol:54-117`)

Every warning in the file, and the full `_extruction` body:

```solidity
/// @title Extruction - External Custom Logic Delegation
/// @notice Allows makers to delegate pricing and state logic to external contracts for advanced strategies
/// @dev IMPORTANT SECURITY CONSIDERATIONS FOR TAKERS/RESOLVERS:
///
///      Quote/Swap Consistency Risk:
///      - This instruction delegates logic to maker-controlled external contracts
///      - Takers MUST validate strategy consistency before execution
///      - IStaticExtruction.extruction() (quote) and IExtruction.extruction() (swap) MUST return
///        consistent results for the same inputs
///
///      Validation Requirements:
///      - Verify target contract is non-upgradeable or has trusted governance
///      - Ensure target implementation is deterministic and cannot change between quote/swap
///      - Review target contract code for correctness and security
///      - Test quote/swap consistency before routing significant volume
///
///      Risk Mitigation:
///      - Takers already have slippage protection via threshold amounts
///      - Consider using additional monitoring for Extruction-based strategies
///      - Only interact with strategies that have been thoroughly validated
///
///      This is a "use at your own risk" feature designed for advanced use cases.
///      Failure to validate may result in quote/swap inconsistencies, reverts, or unexpected execution.
contract Extruction {
    using Calldata for bytes;
    using ContextLib for Context;

    error ExtructionMissingTargetArg();
    error ExtructionChoppedExceededLength(bytes chopped, uint256 requested);

    /// @dev Calls an external contract to perform custom logic, potentially modifying the swap state
    /// @dev QUOTE/SWAP DIVERGENCE: This instruction delegates to external contracts (IStaticExtruction for
    ///   quote, IExtruction for swap). Target implementations MUST be deterministic and return consistent
    ///   results in both modes. Non-deterministic behavior breaks numerical consistency. Makers MUST NOT
    ///   use backward jumps to this instruction as it breaks consistency between quote() and swap().
    /// @param args.target         | 20 bytes
    /// @param args.extructionArgs | N bytes
    function _extruction(Context memory ctx, bytes calldata args) internal {
        address target = address(bytes20(args.slice(0, 20, ExtructionMissingTargetArg.selector)));
        uint256 choppedLength;

        if (ctx.vm.isStaticContext) {
            (ctx.vm.nextPC, choppedLength, ctx.swap) = IStaticExtruction(target).extruction(
                ctx.vm.isStaticContext,
                ctx.vm.nextPC,
                ctx.query,
                ctx.swap,
                args.slice(20),
                ctx.takerArgs()
            );
        } else {
            (ctx.vm.nextPC, choppedLength, ctx.swap) = IExtruction(target).extruction(
                ctx.vm.isStaticContext,
                ctx.vm.nextPC,
                ctx.query,
                ctx.swap,
                args.slice(20),
                ctx.takerArgs()
            );
        }
        bytes calldata chopped = ctx.tryChopTakerArgs(choppedLength);
        require(chopped.length == choppedLength, ExtructionChoppedExceededLength(chopped, choppedLength)); // Revert if not enough data
    }
}
```

### 4.4 What the body obliges us to do

Read off the code above, not inferred:

- **The first 20 bytes of `args` are the target address and the router strips
  them.** `args.slice(0, 20, ...)` takes the target; `args.slice(20)` is what
  arrives as our `args` parameter. `FreeboardArgs` therefore encodes only what
  follows the 20-byte target. A shorter-than-20-byte arg reverts with
  `ExtructionMissingTargetArg()`.
- **We are handed the whole `SwapQuery` and `SwapRegisters` by value and the
  router overwrites `ctx.swap` wholesale** with our returned `updatedSwap`. Any
  register we fail to copy forward is zeroed — including `balanceIn`,
  `balanceOut` and `amountNetPulled`.
- **We control `nextPC` directly**, with `uint256` range rather than the `uint16`
  of `_jump`. Returning `nextPC` unchanged continues execution at the next
  instruction; because we are last in the program, that ends the loop.
  Returning a *smaller* `nextPC` is the forbidden backward jump.
- **`choppedLength` must be honoured or the swap reverts.** `tryChopTakerArgs`
  truncates silently to what is available (`VM.sol:104`), and the `require`
  immediately after catches the shortfall with
  `ExtructionChoppedExceededLength`. Freeboard returns `choppedLength = 0` and
  consumes no taker data — one less taker-controlled input on the pricing path.
- **`isStaticContext` is passed to us but must not change our arithmetic.**
  It is the quote/swap flag; branching pricing on it is precisely the
  non-determinism every warning above forbids. Be precise about what `view`
  buys here: it rules out *side effects* that differ between quote and swap
  (the divergence class `_decayXD` and the fee opcodes document), but a `view`
  function can still branch on a `bool` parameter. Arithmetic consistency is a
  discipline we keep, not one the compiler enforces — which is what
  `test_QuoteAndSwapPaths_ReturnIdenticalRegisters` (T9) exists to prove.
- **`takerData` is `ctx.takerArgs()`** — the taker's remaining
  `instructionsArgs` slice, attacker-controlled. Freeboard ignores it.

The corresponding invariant this all serves (`README.md:348-353`):

> ### 3. Quote/Swap Consistency
>
> Quote and swap functions must return identical amounts:
> - `quote()` is a view function that previews swap results
> - `swap()` execution must match the quoted amounts exactly
> - Essential for MEV protection and predictable execution

And the README's blunt statement of the limit of the guarantee
(`README.md:896`):

> - Deterministic execution is guaranteed only for deterministic instruction sets and deterministic external dependencies

That sentence is the constraint the HF read has to satisfy, and it does
(Rev 4, Sep 6 — the Chainlink CRE consumer is gone, see `CLAUDE.md` §A "Why
the HF read is safe"): Aave's `getUserAccountData` is a view over the pool's
own state and its oracle, so it is deterministic within a block, and
`extruction()` is itself `view`. A `quote()` and a `swap()` in the same block
therefore see the same health factor, which is exactly the "deterministic
external dependency" the README allows. The non-deterministic case — Aave
unable to compute HF — is handled by reverting the fill (T16), never by
falling back to a stale or default target.

The remaining invariants the composed program must still satisfy
(`README.md:329-369`): Exact In/Out Symmetry, Swap Additivity, Quote/Swap
Consistency, Price Monotonicity, and Rounding Favors Maker —

> - `amountIn` always rounds UP (ceil)
> - `amountOut` always rounds DOWN (floor)

Freeboard's pricing must follow the same rounding convention; `_xycSwapXD`
(§1.3) is the reference implementation of it.

---

## 5. Open items found while reading

- ~~`docs/DEPLOYED-OPCODES.md` did not exist when this file was written.~~
  Landed Sep 6 (T5). The table in §1.2 above was derived independently from
  source and agrees with it and with `CLAUDE.md`.
- PROGRAMS.md's catalog examples are written against the full `Opcodes` set and
  open with balances instructions that **do not exist on `AquaSwapVMRouter`**
  (§1.4). They are not templates for our program.
- `IAqua.rawBalances` returns `uint248`, and `safeBalances` reverts for a token
  outside the active strategy. T12/T14 must handle both — a missing leg is a
  revert, not a zero.
