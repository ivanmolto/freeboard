# DEPLOYED-OPCODES.md — the AquaSwapVMRouter instruction table (T5)

The opcode table dispatched by the live `AquaSwapVMRouter`
(`0x111111338c…`), derived from `docs/NOTES-instructions.md` §1.1–1.2 and
cited line-by-line against the pinned source.

**Source.** `node_modules/@1inch/swap-vm/src/opcodes/AquaOpcodes.sol`, resolved
by `package.json` (`"@1inch/swap-vm": "github:1inch/swap-vm#v1.0.2"`) to commit
`32c687c2b73101fc26549e48fa1ff8a4d73afbac` (`yarn.lock:61-63`). That commit is
the one whose bytecode matches the deployed router (CLAUDE.md, VERIFIED FACTS,
"SETTLED Sep 5"). `AquaSwapVMRouter._instructions()` returns `_opcodes()`
unchanged (`src/routers/AquaSwapVMRouter.sol:26-28`), so this table is the
router's table.

## The off-by-one, in one paragraph

`_opcodes()` declares a fixed array of **35** function pointers
(`AquaOpcodes.sol:33`, `function(Context memory, bytes calldata) internal[35] memory instructions = [`)
whose first element is `_notInstruction` (`AquaOpcodes.sol:34`), then converts
it to a dynamic array in place (`AquaOpcodes.sol:79-83`): it computes
`instructions.length - 1` = 34, does `result := instructions`, and
`mstore(result, instructionsArrayLength)`. A `T[35] memory` is 35 bare words
with no length prefix, while a `T[] memory` is a length word followed by its
elements, so aliasing the two makes the static array's **first element** the
dynamic array's **length slot**, and the `mstore` overwrites that first
`_notInstruction` with 34. The executable table is therefore literal positions
1 through 34, and **every opcode is its literal position minus one**: reading
the literal naively puts `_extruction` at `0x21`, but it dispatches at
**`0x20`**. The returned length is 34 = `0x22`, and `runLoop` indexes it
unchecked (`src/libs/VM.sol:130`, `ctx.vm.opcodes[opcode](ctx, args);`), so any
program byte `>= 0x22` is an out-of-bounds panic rather than a revert with a
reason. The debug router confirms the shift independently: it writes
`opcodes[0..4]` (`src/instructions/Debug.sol:17-24`) and those land on the
Debug bank, which occupies literal positions 1–5.

## The 34 dispatchable entries

`Line` is the line in `AquaOpcodes.sol` (commit 32c687c) holding that literal
entry. Literal position = line-derived index; opcode = position − 1.

| Opcode | Instruction | Line | Declared as |
|---|---|---|---|
| — | `_notInstruction` (position 0, overwritten by the length word) | 34 | — |
| `0x00`–`0x09` | *(Debug bank, reserved)* — `_notInstruction` ×10 | 36–45 | `internal view` no-op |
| `0x0a` | `Controls._jump` | 47 | `internal pure` |
| `0x0b` | `Controls._jumpIfTokenIn` | 48 | `internal pure` |
| `0x0c` | `Controls._jumpIfTokenOut` | 49 | `internal pure` |
| `0x0d` | `Controls._deadline` | 50 | `internal view` |
| `0x0e` | `Controls._onlyTakerTokenBalanceNonZero` | 51 | `internal view` |
| `0x0f` | `Controls._onlyTakerTokenBalanceGte` | 52 | `internal view` |
| `0x10` | `Controls._onlyTakerTokenSupplyShareGte` | 53 | `internal view` |
| `0x11` | `XYCSwap._xycSwapXD` | 55 | `internal pure` |
| `0x12` | `XYCConcentrate._xycConcentrateGrowLiquidity2D` | 57 | `internal` |
| `0x13` | `Decay._decayXD` | 59 | `internal` |
| `0x14` | `Controls._salt` | 61 | `internal pure` |
| `0x15` | `Fee._flatFeeAmountInXD` | 62 | `internal` |
| `0x16`–`0x1a` | *(reserved holes)* — `_notInstruction` ×5 | 63–67 | `internal view` no-op |
| `0x1b` | `Fee._protocolFeeAmountInXD` | 68 | `internal` |
| `0x1c` | `Fee._aquaProtocolFeeAmountInXD` | 69 | `internal` |
| `0x1d` | `Fee._dynamicProtocolFeeAmountInXD` | 70 | `internal` |
| `0x1e` | `Fee._aquaDynamicProtocolFeeAmountInXD` | 71 | `internal` |
| `0x1f` | `PeggedSwap._peggedSwapGrowPriceRange2D` | 72 | `internal pure` |
| **`0x20`** | **`Extruction._extruction`** | **73** | `internal` |
| `0x21` | `Controls._onlyTxOriginTokenBalanceNonZero` | 74 | `internal view` |
| `>= 0x22` | *(out of bounds — panic)* | — | — |

Two things the table implies for Freeboard programs:

- `_notInstruction` is a callable no-op, not a revert
  (`AquaOpcodes.sol:30`,
  `function _notInstruction(Context memory, bytes calldata) internal view {}`).
  A stray byte in `0x00`–`0x09` or `0x16`–`0x1a` silently does nothing and
  skips its `argsLength` bytes; it does not fail the fill.
- There is **no balances instruction** in this table. `balanceIn`/`balanceOut`
  are preloaded by the router from `AQUA.safeBalances` before `runLoop`
  starts. `PROGRAMS.md` examples that open with `_staticBalancesXD` target the
  full `Opcodes` set and must not be copied (CLAUDE.md, VERIFIED FACTS).

## Where this table is proven, not asserted

- `test/fork/ExtructionDispatch.t.sol`:
  `test_QuotePath_DispatchesOpcode0x20WithExpectedQueryAndRegisters` and
  `test_SwapPath_DispatchesOpcode0x20AndRecordsExpectedQueryAndRegisters`
  execute a program whose single instruction is byte `0x20` against the
  deployed router on the mainnet fork and observe the call landing on our
  target with the expected `SwapQuery` and `SwapRegisters`.
- `test/unit/Pin.t.sol`: `test_PinnedSwapVM_ExtructionSelectorsAgree` pins the
  `IExtruction`/`IStaticExtruction` selectors of the same source.
- `test/utils/ProgramLib.sol` encodes the wire format this table is read
  through: `[1 byte opcode][1 byte argsLength][args]`, 255-byte cap per
  instruction (`src/libs/VM.sol:124-127`).
