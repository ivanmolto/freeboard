// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { IStaticExtruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { ProbeExtruction } from "../utils/ProbeExtruction.sol";
import { ProgramLib } from "../utils/ProgramLib.sol";

/// @dev `SwapVM` exposes its Aqua as a public immutable (`src/SwapVM.sol:74`):
///        IAqua public immutable AQUA;
///      Read as `address` here purely as an identity check on the deployed router.
interface IRouterAqua {
    function AQUA() external view returns (address);
}

/// @title ExtructionDispatchForkTest — T2
/// @notice Proves Freeboard's program bytes reach `_extruction` on the DEPLOYED
///         AquaSwapVMRouter, and that the target is handed the SwapQuery/SwapRegisters we
///         expect. No router is deployed by this test; nothing is forked-and-patched.
///
/// @dev Route B compliance evidence: the only contract this test deploys is the extruction
///      target. The VM, the opcode table and the dispatch at 0x20 are all the live router's.
///
///      The order here uses the SIGNATURE path, not the Aqua path
///      (`MakerTraitsLib.USE_AQUA_INSTEAD_OF_SIGNATURE_BIT_FLAG`, bit 254, is left clear), so
///      `SwapVM.quote`/`swap` never call `AQUA.safeBalances` (`SwapVM.sol:147-149`,
///      `:193-198`) and no shipped Aqua strategy is required. That keeps balanceIn/balanceOut
///      at 0 in the registers asserted below. Running the same program on an Aqua order is
///      T7/T9, not T2.
contract ExtructionDispatchForkTest is Test {
    /// @dev The deployed AquaSwapVMRouter. Not deployed by this test. Every address below
    ///      comes from `src/constants/Addresses.sol`, where each is pinned by bytecode (T4);
    ///      this test carries no literals of its own.
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    /// @dev Canonical Aqua for that router, read from `AquaSwapVMRouter.AQUA()`.
    address internal constant AQUA = Addresses.AQUA;

    address internal constant WETH = Addresses.WETH;
    address internal constant DAI = Addresses.DAI;

    /// @dev Distinctive payload placed after the 20-byte target inside the instruction args.
    ///      The router must strip the target and hand exactly these bytes to the extruction.
    bytes internal constant EXTRUCTION_ARGS = hex"f1eeb0a4d0";
    /// @dev Distinctive taker `instructionsArgs`. Reaches the extruction as `takerData` via
    ///      `ctx.takerArgs()` (`Extruction.sol:102`, `:111`).
    bytes internal constant INSTRUCTIONS_ARGS = hex"c0ffee";

    uint256 internal constant AMOUNT_IN = 1 ether;

    uint256 internal makerPk = 0xA11CE;
    address internal maker;
    address internal taker = address(0x7A4E5);

    ProbeExtruction internal probe;
    bytes internal program;

    function setUp() public {
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        require(forkBlock >= Addresses.MIN_FORK_BLOCK, "FORK_BLOCK is before the router exists");
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);

        assertGt(ROUTER.code.length, 0, "no code at the deployed AquaSwapVMRouter on this fork block");
        assertEq(IRouterAqua(ROUTER).AQUA(), AQUA, "router.AQUA() is not the canonical Aqua: wrong contract");

        maker = vm.addr(makerPk);
        probe = new ProbeExtruction();
        program = ProgramLib.extruction(address(probe), EXTRUCTION_ARGS);

        vm.label(ROUTER, "AquaSwapVMRouter");
        vm.label(address(probe), "ProbeExtruction");
    }

    // -------------------------------------------------------------------------------------
    // The program bytes themselves
    // -------------------------------------------------------------------------------------

    /// @dev Pins the exact bytes so a change in the encoder is visible, not silent.
    function test_Program_IsOneExtructionInstruction() public view {
        assertEq(program.length, 2 + 20 + EXTRUCTION_ARGS.length, "program is [opcode][argsLength][target][args]");
        assertEq(uint8(program[0]), 0x20, "instruction byte must be _extruction");
        assertEq(uint8(program[1]), 20 + EXTRUCTION_ARGS.length, "argsLength must cover target + extructionArgs");
        assertEq(address(bytes20(_slice(program, 2, 22))), address(probe), "args.target must be the extruction target");
        assertEq(_slice(program, 22, program.length), EXTRUCTION_ARGS, "extructionArgs must follow the target");
        assertEq(program, abi.encodePacked(hex"2019", address(probe), EXTRUCTION_ARGS), "program bytes drifted");
    }

    // -------------------------------------------------------------------------------------
    // quote(): isStaticContext == true, IStaticExtruction, STATICCALL
    // -------------------------------------------------------------------------------------

    function test_QuotePath_DispatchesOpcode0x20WithExpectedQueryAndRegisters() public {
        ISwapVM.Order memory order = _order();
        bytes memory takerTraitsAndData = _takerTraitsAndData("");

        bytes32 orderHash = ISwapVM(ROUTER).hash(order);
        SwapQuery memory expectedQuery = _expectedQuery(orderHash);
        SwapRegisters memory expectedSwap = _expectedSwap();
        uint256 expectedNextPC = program.length;

        // The strongest form of "called with what we expect". expectCall matches on prefix,
        // but this is the complete ABI encoding, so a prefix match is a byte-for-byte match.
        vm.expectCall(
            address(probe),
            abi.encodeCall(
                IStaticExtruction.extruction,
                (true, expectedNextPC, expectedQuery, expectedSwap, EXTRUCTION_ARGS, INSTRUCTIONS_ARGS)
            )
        );

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut, bytes32 returnedHash) =
            ISwapVM(ROUTER).quote(order, WETH, DAI, AMOUNT_IN, takerTraitsAndData);

        assertEq(returnedHash, orderHash, "orderHash");
        assertEq(amountIn, AMOUNT_IN, "amountIn must survive the extruction unchanged");
        // Independent of the cheatcode: the probe's price is a hash of everything it was
        // handed, so this equality only holds if every argument matched.
        assertEq(
            amountOut,
            probe.priceOf(expectedNextPC, expectedQuery, expectedSwap, EXTRUCTION_ARGS, INSTRUCTIONS_ARGS),
            "amountOut must be the probe's price for exactly the expected inputs"
        );
        // A STATICCALL cannot write, so quote() must have left the recorder untouched.
        assertEq(probe.calls(), 0, "quote() must reach the probe through the view interface");
    }

    // -------------------------------------------------------------------------------------
    // swap(): isStaticContext == false, IExtruction, CALL, real settlement
    // -------------------------------------------------------------------------------------

    function test_SwapPath_DispatchesOpcode0x20AndRecordsExpectedQueryAndRegisters() public {
        ISwapVM.Order memory order = _order();
        bytes32 orderHash = ISwapVM(ROUTER).hash(order);
        bytes memory takerTraitsAndData = _takerTraitsAndData(_sign(orderHash));

        SwapQuery memory expectedQuery = _expectedQuery(orderHash);
        SwapRegisters memory expectedSwap = _expectedSwap();
        uint256 expectedNextPC = program.length;
        uint256 expectedAmountOut =
            probe.priceOf(expectedNextPC, expectedQuery, expectedSwap, EXTRUCTION_ARGS, INSTRUCTIONS_ARGS);

        deal(WETH, taker, AMOUNT_IN);
        deal(DAI, maker, expectedAmountOut);
        vm.prank(taker);
        IERC20(WETH).approve(ROUTER, AMOUNT_IN);
        vm.prank(maker);
        IERC20(DAI).approve(ROUTER, expectedAmountOut);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = ISwapVM(ROUTER).swap(order, WETH, DAI, AMOUNT_IN, takerTraitsAndData);

        // 1. The router called the target, through the state-modifying interface. The probe
        //    only records when isStaticContext is false, and a write under STATICCALL would have
        //    reverted the whole swap, so calls() == 1 already proves both the branch and the flag.
        assertEq(probe.calls(), 1, "swap() must reach the probe exactly once, through IExtruction");
        assertEq(probe.lastNextPC(), expectedNextPC, "nextPC must be the offset past this instruction");

        // 2. With the SwapQuery we expect.
        (bytes32 gotOrderHash, address gotMaker, address gotTaker, address gotTokenIn, address gotTokenOut, bool gotIsExactIn)
            = probe.lastQuery();
        assertEq(gotOrderHash, expectedQuery.orderHash, "query.orderHash");
        assertEq(gotMaker, expectedQuery.maker, "query.maker");
        assertEq(gotTaker, expectedQuery.taker, "query.taker");
        assertEq(gotTokenIn, expectedQuery.tokenIn, "query.tokenIn");
        assertEq(gotTokenOut, expectedQuery.tokenOut, "query.tokenOut");
        assertEq(gotIsExactIn, expectedQuery.isExactIn, "query.isExactIn");

        // 3. And the SwapRegisters we expect.
        (uint256 gotBalanceIn, uint256 gotBalanceOut, uint256 gotAmountIn, uint256 gotAmountOut, uint256 gotNetPulled)
            = probe.lastSwap();
        assertEq(gotBalanceIn, expectedSwap.balanceIn, "swap.balanceIn");
        assertEq(gotBalanceOut, expectedSwap.balanceOut, "swap.balanceOut");
        assertEq(gotAmountIn, expectedSwap.amountIn, "swap.amountIn");
        assertEq(gotAmountOut, expectedSwap.amountOut, "swap.amountOut");
        assertEq(gotNetPulled, expectedSwap.amountNetPulled, "swap.amountNetPulled");

        // 4. And the args, with the 20-byte target stripped, plus the taker's instructionsArgs.
        assertEq(probe.lastArgs(), EXTRUCTION_ARGS, "args must be extructionArgs with target stripped");
        assertEq(probe.lastTakerData(), INSTRUCTIONS_ARGS, "takerData must be the taker's instructionsArgs");

        // 5. The registers the probe returned are the registers the router settled.
        assertEq(amountIn, AMOUNT_IN, "settled amountIn");
        assertEq(amountOut, expectedAmountOut, "settled amountOut is the probe's price");
        assertEq(IERC20(WETH).balanceOf(taker), 0, "taker paid tokenIn");
        assertEq(IERC20(WETH).balanceOf(maker), AMOUNT_IN, "maker received tokenIn");
        assertEq(IERC20(DAI).balanceOf(taker), expectedAmountOut, "taker received tokenOut");
        assertEq(IERC20(DAI).balanceOf(maker), 0, "maker paid tokenOut");
    }

    // -------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------

    /// @dev Built through the pinned library so the order bytes have one source of truth.
    ///      Everything left at its zero value: no hooks, no custom receiver, no unwrap, and
    ///      `useAquaInsteadOfSignature == false`.
    function _order() internal view returns (ISwapVM.Order memory) {
        MakerTraitsLib.Args memory args;
        args.maker = maker;
        args.program = program;
        return MakerTraitsLib.build(args);
    }

    /// @dev Likewise for taker traits. `threshold` is empty, so `TakerTraitsLib.validate`
    ///      applies no bound on amountOut beyond `amountOut > 0` (`TakerTraits.sol:173`).
    function _takerTraitsAndData(bytes memory signature) internal view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.taker = taker;
        args.isExactIn = true;
        args.instructionsArgs = INSTRUCTIONS_ARGS;
        args.signature = signature;
        return TakerTraitsLib.build(args);
    }

    function _sign(bytes32 orderHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, orderHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Mirrors the SwapQuery the router builds in `quote()` (`SwapVM.sol:130-137`) and
    ///      `swap()` (`SwapVM.sol:176-183`). `taker` is `msg.sender`, hence the pranks.
    function _expectedQuery(bytes32 orderHash) internal view returns (SwapQuery memory) {
        return SwapQuery({
            orderHash: orderHash,
            maker: maker,
            taker: taker,
            tokenIn: WETH,
            tokenOut: DAI,
            isExactIn: true
        });
    }

    /// @dev Mirrors the SwapRegisters the router builds (`SwapVM.sol:138-144`, `:184-190`):
    ///      `amountIn: isExactIn ? amount : 0`, everything else zero. The balances stay zero
    ///      because this is not an Aqua order.
    function _expectedSwap() internal pure returns (SwapRegisters memory) {
        return SwapRegisters({
            balanceIn: 0,
            balanceOut: 0,
            amountIn: AMOUNT_IN,
            amountOut: 0,
            amountNetPulled: 0
        });
    }

    function _slice(bytes memory data, uint256 begin, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - begin);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[begin + i];
        }
    }
}
