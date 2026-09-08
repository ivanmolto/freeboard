// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { IExtruction, IStaticExtruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { FreeboardExtruction } from "../../src/FreeboardExtruction.sol";
import { IAaveV3Oracle } from "../../src/interfaces/IAaveV3Oracle.sol";
import { Curve } from "../../src/libs/Curve.sol";

import { Curves } from "../utils/Curves.sol";
import { PricingReference } from "../utils/PricingReference.sol";
import { ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { ProgramLib } from "../utils/ProgramLib.sol";

/// @title QuoteSwapConsistencyForkTest — T9
/// @notice `FreeboardExtruction` on the DEPLOYED AquaSwapVMRouter, on an AQUA order: the
///         static path (`quote()`, `IStaticExtruction`, STATICCALL) and the non-static path
///         (`swap()`, `IExtruction`, CALL) hand the extruction identical inputs and settle
///         identical registers, in the same block, and the swap moves real WETH and USDC
///         through Aqua. The only contract this test deploys is `FreeboardExtruction`.
///
/// @dev THIS IS THE "OFFICIAL CONTRACTS" EVIDENCE. The router at
///      `Addresses.AQUA_SWAP_VM_ROUTER` and the Aqua at `Addresses.AQUA` are the live
///      deployments, matched to their tags by bytecode (`PinnedAddressesForkTest`). The
///      Freeboard strategy executes on them through the router's own `_extruction`
///      instruction at 0x20. `test_Repo_ContainsZeroModifiedSwapVMSource` closes the other
///      half of the claim: nothing of swap-vm is copied into this repo, and the dependency
///      compiled against is the v1.0.2 tag, unmodified.
///
/// @dev WHY "IDENTICAL REGISTERS" IS PROVABLE FROM OUTSIDE THE ROUTER. `SwapVM.quote` and
///      `SwapVM.swap` return only `(amountIn, amountOut, orderHash)`, not the register
///      struct. But `Extruction._extruction` assigns `ctx.swap` WHOLESALE from what the target
///      returns (`Extruction.sol:96`, `:105`), and `_extruction` is the LAST instruction in the
///      Freeboard program, so the registers the extruction returns ARE the registers the
///      router settles. The proof is therefore in three parts:
///        1. `vm.expectCall` with the complete ABI encoding pins the INPUT registers on each
///           path — the same `nextPC`, `SwapQuery`, `SwapRegisters`, `args` and `takerData`,
///           differing only in the `isStaticContext` flag;
///        2. the OUTPUT registers are read back by calling the extruction through each
///           interface with exactly those inputs and compared field by field;
///        3. the router's settled amounts on both paths equal those outputs.
///
/// @dev THE PROGRAM IS ONE INSTRUCTION. `[0x20][0xa0][FreeboardExtruction][140 arg bytes]`,
///      no fee opcode, nothing after it: NOTES-instructions.md §3.4 shows a fee opcode nests
///      what follows and re-prices after it, so the registers our extruction returns would not
///      be the settled ones. 162 bytes, pinned exactly below. The args are `FreeboardArgs`
///      over the two-leg WETH / USDC curve (T14); the maker has no Aave debt, so the sentinel
///      health factor prices at the top row, 50 / 50.
///
/// @dev THE BASKET CROSSES A TARGET MID-FILL. 10 WETH against USDC worth 11 WETH: WETH is half
///      a WETH under its 50% target and USDC half a WETH over, so the first half of the taker's
///      1 WETH moves both legs toward target and the second half moves both away. The expected
///      amount is derived by `PricingReference` — the integral form — and the extruction, which
///      prices by distance before and after, must land on the same wei. After the fill both
///      legs are past their targets and the next quote is one away-priced piece: worse.
contract QuoteSwapConsistencyForkTest is Test {
    /// @dev Every address comes from `src/constants/Addresses.sol`; no literals of our own.
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant WETH = Addresses.WETH;
    address internal constant USDC = Addresses.USDC;

    /// @dev The shipped basket: 10 WETH (18 decimals) and, in USDC (6 decimals), the oracle
    ///      value of 11 WETH — computed in `setUp` from the pin's prices.
    uint256 internal constant SHIPPED_WETH = 10 ether;
    uint256 internal shippedUsdc;

    /// @dev The taker sells 1 WETH for USDC, exact-in.
    uint256 internal constant AMOUNT_IN = 1 ether;

    uint16 internal constant MAX_SHIFT_BPS = 500;
    uint256 internal constant ONE = 1e18;

    /// @dev The USDC the fill must settle at, by `PricingReference` from the shipped basket:
    ///      half a WETH of value at 10 bps, half at 100 bps. Fixed in `setUp`, asserted against
    ///      the router and the extruction below.
    uint256 internal expectedAmountOut;

    /// @dev Taker `instructionsArgs`. They reach the extruction as `takerData` and are ignored
    ///      by it; non-empty so the calldata match below covers the variable-length tail too.
    bytes internal constant INSTRUCTIONS_ARGS = hex"c0ffee";

    address internal maker = address(0xB0A2E4);
    address internal taker = address(0x7A4E5);

    FreeboardExtruction internal freeboard;
    ProgramBuilder.Position internal position;
    IAaveV3Oracle internal oracle = IAaveV3Oracle(Addresses.AAVE_V3_ORACLE);

    function setUp() public {
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        require(forkBlock >= Addresses.MIN_FORK_BLOCK, "FORK_BLOCK is before the router exists");
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);

        assertEq(block.chainid, Addresses.CHAIN_ID, "not forking Ethereum mainnet");
        assertEq(ROUTER.code.length, Addresses.ROUTER_RUNTIME_SIZE, "deployed AquaSwapVMRouter runtime size");
        assertEq(AQUA.code.length, Addresses.AQUA_RUNTIME_SIZE, "deployed Aqua runtime size");

        // The one contract of ours on this fork. No constructor arguments: nothing to configure.
        freeboard = new FreeboardExtruction();
        position = ProgramBuilder.freeboardPosition(
            maker, address(freeboard), Curves.twoLeg(), Curves.twoLegTokens(), MAX_SHIFT_BPS
        );

        shippedUsdc = 11 * oracle.getAssetPrice(WETH) * 1e6 / oracle.getAssetPrice(USDC);
        expectedAmountOut = _referenceOut(SHIPPED_WETH, shippedUsdc);

        vm.label(ROUTER, "AquaSwapVMRouter");
        vm.label(AQUA, "Aqua");
        vm.label(address(freeboard), "FreeboardExtruction");
        vm.label(maker, "maker");
        vm.label(taker, "taker");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
    }

    // -------------------------------------------------------------------------------------
    // The DoD
    // -------------------------------------------------------------------------------------

    function test_QuoteAndSwapPaths_ReturnIdenticalRegisters() public {
        // -- 0. The program: one _extruction, last, no fee opcode. --------------------------
        bytes memory program = position.order.data;
        bytes memory args = position.extructionArgs;
        assertEq(args.length, 140, "two-leg FreeboardArgs: 98-byte curve, two tokens, the cap");
        assertEq(program, abi.encodePacked(hex"20a0", address(freeboard), args), "program bytes drifted");
        assertEq(program.length, 2 + 20 + args.length, "the program is exactly one instruction");
        assertEq(uint8(program[0]), ProgramLib.EXTRUCTION, "the one instruction is _extruction");
        uint256 expectedNextPC = program.length;

        // The fill crosses both targets half-way, so the reference has two pieces and the
        // price sits strictly between the toward and away schedules.
        uint256 fairOut = AMOUNT_IN * oracle.getAssetPrice(WETH) / (oracle.getAssetPrice(USDC) * 1e12);
        assertLt(expectedAmountOut, fairOut * (ONE - PricingReference.TOWARD) / ONE, "below the toward price");
        assertGt(expectedAmountOut, fairOut * (ONE - PricingReference.AWAY) / ONE, "above the away price");

        // -- 1. Ship, and prove the ship -> execute round trip. ---------------------------
        _ship();
        bytes32 orderHash = ISwapVM(ROUTER).hash(position.order);
        assertEq(orderHash, position.strategyHash, "router order hash != shipped strategy hash");

        // The maker's Aqua allowance is what makes the position fillable (Aqua.sol:63-70);
        // ship() consumed none of it.
        vm.prank(maker);
        IERC20(USDC).approve(AQUA, shippedUsdc);

        deal(WETH, taker, AMOUNT_IN);
        vm.prank(taker);
        IERC20(WETH).approve(ROUTER, AMOUNT_IN);

        bytes memory takerTraitsAndData = _takerTraitsAndData();

        // -- 2. The inputs each path must hand the extruction. ------------------------------
        //
        // Mirrors the SwapQuery the router builds in quote() (SwapVM.sol:130-137) and swap()
        // (:176-183), and the registers it preloads for an Aqua order (:193-194): both
        // balances from AQUA.safeBalances, amountIn = the taker's amount, the rest zero.
        SwapQuery memory query = SwapQuery({
            orderHash: orderHash, maker: maker, taker: taker, tokenIn: WETH, tokenOut: USDC, isExactIn: true
        });
        SwapRegisters memory entry = SwapRegisters({
            balanceIn: SHIPPED_WETH, balanceOut: shippedUsdc, amountIn: AMOUNT_IN, amountOut: 0, amountNetPulled: 0
        });

        uint256 blockNumber = block.number;

        // -- 3. quote(): the static path. ---------------------------------------------------
        //
        // expectCall matches on prefix; this is the complete ABI encoding, so it is a
        // byte-for-byte match of every argument the router passes.
        vm.expectCall(
            address(freeboard),
            abi.encodeCall(IStaticExtruction.extruction, (true, expectedNextPC, query, entry, args, INSTRUCTIONS_ARGS))
        );
        vm.prank(taker);
        (uint256 quotedIn, uint256 quotedOut, bytes32 quotedHash) =
            ISwapVM(ROUTER).quote(position.order, WETH, USDC, AMOUNT_IN, takerTraitsAndData);

        assertEq(quotedHash, orderHash, "quote() orderHash");
        assertEq(quotedIn, AMOUNT_IN, "quote() amountIn");
        assertEq(quotedOut, expectedAmountOut, "quote() amountOut by the health-weighted target");

        // -- 4. swap(): the non-static path, same block, same inputs. -----------------------
        assertEq(block.number, blockNumber, "quote and swap must run in the same block");

        vm.expectCall(
            address(freeboard),
            abi.encodeCall(IExtruction.extruction, (false, expectedNextPC, query, entry, args, INSTRUCTIONS_ARGS))
        );

        Balances memory before = _balances();

        vm.prank(taker);
        (uint256 swappedIn, uint256 swappedOut, bytes32 swappedHash) =
            ISwapVM(ROUTER).swap(position.order, WETH, USDC, AMOUNT_IN, takerTraitsAndData);

        assertEq(swappedHash, quotedHash, "swap() orderHash == quote() orderHash");
        assertEq(swappedIn, quotedIn, "swap() amountIn == quote() amountIn");
        assertEq(swappedOut, quotedOut, "swap() amountOut == quote() amountOut");

        // -- 5. The full register struct, both interfaces, field by field. ------------------
        //
        // The router settles exactly what the extruction returns (Extruction.sol:96, :105,
        // and nothing runs after it). Call it through each interface with the inputs the
        // router was just proven to pass, and compare every register.
        uint256 pricedAmountOut = _assertIdenticalRegistersThroughBothInterfaces(expectedNextPC, query, entry, args);

        // And that is the amount the router settled on both paths.
        assertEq(quotedOut, pricedAmountOut, "quote() settled the static path's registers");
        assertEq(swappedOut, pricedAmountOut, "swap() settled the non-static path's registers");

        // -- 6. Real tokens moved through Aqua, both sides. ---------------------------------
        _assertRealDeltas(before, orderHash);

        // -- 7. Same block, moved basket: the quote follows Aqua's balances. ----------------
        //
        // Quoted in the same block as the fill, this proves the extruction prices from the
        // live Aqua balances the router preloads, not from anything it remembers — it has
        // nothing to remember with. Both legs are now past their targets: one away piece.
        assertEq(block.number, blockNumber, "still the same block");
        uint256 expectedAfter = _referenceOut(SHIPPED_WETH + AMOUNT_IN, shippedUsdc - quotedOut);
        vm.prank(taker);
        (, uint256 quotedOutAfter,) = ISwapVM(ROUTER).quote(position.order, WETH, USDC, AMOUNT_IN, takerTraitsAndData);
        assertEq(quotedOutAfter, expectedAfter, "the quote must reprice from the live Aqua balances");
        assertEq(quotedOutAfter, _singleRateOut(PricingReference.AWAY), "one away piece, to the wei");
        assertLt(quotedOutAfter, quotedOut, "selling into the basket must worsen the next quote");
    }

    // -------------------------------------------------------------------------------------
    // The other half of the "official contracts" claim
    // -------------------------------------------------------------------------------------

    /// @notice The repo contains zero modified swap-vm source: none copied under `src/` or
    ///         `test/`, and the dependency compiled against is the v1.0.2 tag, unmodified.
    /// @dev The needles are assembled with `string.concat` so this file does not match itself.
    function test_Repo_ContainsZeroModifiedSwapVMSource() public view {
        // 1. Every swap-vm source file carries Degensoft's license identifier (40 of 40 under
        //    `src/` at v1.0.2), and these are the declarations a modified copy would have to
        //    keep to be dispatchable. None may appear in our tracked Solidity.
        string[] memory needles = new string[](6);
        needles[0] = string.concat("LicenseRef-", "Degensoft");
        needles[1] = string.concat("contract ", "SwapVM ");
        needles[2] = string.concat("contract ", "AquaOpcodes ");
        needles[3] = string.concat("contract ", "AquaSwapVMRouter ");
        needles[4] = string.concat("contract ", "Extruction ");
        needles[5] = string.concat("library ", "ContextLib ");

        uint256 scanned = _scanTree("src", needles) + _scanTree("test", needles);
        assertGt(scanned, 5, "the walk must have visited the repo's Solidity");

        // 2. The swap-vm this repo compiles against resolves to the v1.0.2 tag's commit.
        string memory lock = vm.readFile("yarn.lock");
        assertTrue(
            vm.contains(
                lock, "https://codeload.github.com/1inch/swap-vm/tar.gz/32c687c2b73101fc26549e48fa1ff8a4d73afbac"
            ),
            "yarn.lock must resolve @1inch/swap-vm to tag v1.0.2 (32c687c)"
        );

        // 3. And the two files `FreeboardExtruction` is built against are byte-for-byte the
        //    tag's. Hashes computed outside forge (`cast keccak` over the raw file bytes).
        assertEq(
            keccak256(bytes(vm.readFile("node_modules/@1inch/swap-vm/src/instructions/Extruction.sol"))),
            0xc19583963ef3af3669750497f657cd8b18f40969b8b1c858d7f8133fcdfd1146,
            "Extruction.sol is not the v1.0.2 file"
        );
        assertEq(
            keccak256(bytes(vm.readFile("node_modules/@1inch/swap-vm/src/libs/VM.sol"))),
            0x12f80cb69f6b3e6a7cdb6c7c2a95d59944faf75c4067b933199432d6e38fb35a,
            "VM.sol is not the v1.0.2 file"
        );
    }

    // -------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------

    /// @dev Calls the extruction through each interface with the inputs the router was just
    ///      proven to pass. The static call goes out as a STATICCALL because the interface is
    ///      `view`; the other as a CALL. Compares every register, and checks the three the
    ///      extruction does not price are the router's entry values, not zeros.
    /// @return pricedAmountOut The one register the extruction set, identical on both paths.
    function _assertIdenticalRegistersThroughBothInterfaces(
        uint256 expectedNextPC,
        SwapQuery memory query,
        SwapRegisters memory entry,
        bytes memory args
    )
        internal
        returns (uint256 pricedAmountOut)
    {
        (uint256 staticNextPC, uint256 staticChopped, SwapRegisters memory viaStatic) = IStaticExtruction(
                address(freeboard)
            ).extruction(true, expectedNextPC, query, entry, args, INSTRUCTIONS_ARGS);
        (uint256 nonStaticNextPC, uint256 nonStaticChopped, SwapRegisters memory viaNonStatic) =
            IExtruction(address(freeboard)).extruction(false, expectedNextPC, query, entry, args, INSTRUCTIONS_ARGS);

        assertEq(staticNextPC, expectedNextPC, "static path must return nextPC unchanged");
        assertEq(nonStaticNextPC, expectedNextPC, "non-static path must return nextPC unchanged");
        assertEq(staticChopped, 0, "static path must consume no taker data");
        assertEq(nonStaticChopped, 0, "non-static path must consume no taker data");

        assertEq(viaStatic.balanceIn, viaNonStatic.balanceIn, "balanceIn differs between paths");
        assertEq(viaStatic.balanceOut, viaNonStatic.balanceOut, "balanceOut differs between paths");
        assertEq(viaStatic.amountIn, viaNonStatic.amountIn, "amountIn differs between paths");
        assertEq(viaStatic.amountOut, viaNonStatic.amountOut, "amountOut differs between paths");
        assertEq(viaStatic.amountNetPulled, viaNonStatic.amountNetPulled, "amountNetPulled differs between paths");
        assertEq(
            keccak256(abi.encode(viaStatic)), keccak256(abi.encode(viaNonStatic)), "SwapRegisters are not identical"
        );

        assertEq(viaStatic.balanceIn, entry.balanceIn, "balanceIn must be copied forward");
        assertEq(viaStatic.balanceOut, entry.balanceOut, "balanceOut must be copied forward");
        assertEq(viaStatic.amountIn, entry.amountIn, "amountIn must be copied forward");
        assertEq(viaStatic.amountNetPulled, entry.amountNetPulled, "amountNetPulled must be copied forward");
        assertEq(viaStatic.amountOut, expectedAmountOut, "amountOut is the priced register");

        pricedAmountOut = viaStatic.amountOut;

        // `amountNetPulled` is zero on entry for every Freeboard program (no fee opcode ever
        // credits it — NOTES-instructions.md §3.4), so the assertion above cannot tell a
        // copied zero from a dropped register. Hand the extruction a non-zero value directly
        // and require it back, through both interfaces.
        SwapRegisters memory perturbed = entry;
        perturbed.amountNetPulled = 7;
        (,, SwapRegisters memory perturbedViaStatic) = IStaticExtruction(address(freeboard))
            .extruction(true, expectedNextPC, query, perturbed, args, INSTRUCTIONS_ARGS);
        (,, SwapRegisters memory perturbedViaNonStatic) =
            IExtruction(address(freeboard)).extruction(false, expectedNextPC, query, perturbed, args, INSTRUCTIONS_ARGS);
        assertEq(perturbedViaStatic.amountNetPulled, 7, "amountNetPulled must be copied forward (static)");
        assertEq(perturbedViaNonStatic.amountNetPulled, 7, "amountNetPulled must be copied forward (non-static)");
        assertEq(perturbedViaStatic.amountOut, pricedAmountOut, "amountNetPulled must not influence the price");
    }

    struct Balances {
        uint256 makerWeth;
        uint256 makerUsdc;
        uint256 takerWeth;
        uint256 takerUsdc;
    }

    function _balances() internal view returns (Balances memory b) {
        b.makerWeth = IERC20(WETH).balanceOf(maker);
        b.makerUsdc = IERC20(USDC).balanceOf(maker);
        b.takerWeth = IERC20(WETH).balanceOf(taker);
        b.takerUsdc = IERC20(USDC).balanceOf(taker);
    }

    /// @dev Taker's WETH: taker -> router -> maker's Aqua balance (useTransferFromAndAquaPush,
    ///      SwapVM.sol:234-237, Aqua.sol:78). Maker's USDC: maker -> taker via AQUA.pull
    ///      (SwapVM.sol:266, :286, Aqua.sol:63-70), spending the allowance approved in the test.
    function _assertRealDeltas(Balances memory before, bytes32 orderHash) internal view {
        Balances memory after_ = _balances();
        assertEq(before.takerWeth - after_.takerWeth, AMOUNT_IN, "taker paid WETH");
        assertEq(after_.makerWeth - before.makerWeth, AMOUNT_IN, "maker received WETH");
        assertEq(after_.takerUsdc - before.takerUsdc, expectedAmountOut, "taker received USDC");
        assertEq(before.makerUsdc - after_.makerUsdc, expectedAmountOut, "maker paid USDC");

        assertEq(IERC20(WETH).balanceOf(ROUTER), 0, "router must not retain WETH");
        assertEq(IERC20(USDC).balanceOf(ROUTER), 0, "router must not retain USDC");
        assertEq(IERC20(WETH).balanceOf(address(freeboard)), 0, "the extruction never holds WETH");
        assertEq(IERC20(USDC).balanceOf(address(freeboard)), 0, "the extruction never holds USDC");

        (uint256 aquaWeth, uint256 aquaUsdc) = IAqua(AQUA).safeBalances(maker, ROUTER, orderHash, WETH, USDC);
        assertEq(aquaWeth, SHIPPED_WETH + AMOUNT_IN, "Aqua WETH balance after the push");
        assertEq(aquaUsdc, shippedUsdc - expectedAmountOut, "Aqua USDC balance after the pull");
    }

    function _ship() internal {
        deal(WETH, maker, SHIPPED_WETH);
        deal(USDC, maker, shippedUsdc);

        address[] memory tokens = Curves.twoLegTokens();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SHIPPED_WETH;
        amounts[1] = shippedUsdc;

        vm.prank(maker);
        bytes32 shippedHash = IAqua(AQUA).ship(ROUTER, position.strategy, tokens, amounts);
        assertEq(shippedHash, position.strategyHash, "ship() did not return keccak256(strategy)");
    }

    /// @dev Built through the pinned library; TakerTraits is a packed layout, not a struct.
    ///      `useTransferFromAndAquaPush` makes the router pull tokenIn from the taker and push
    ///      it into the maker's Aqua balance (SwapVM.sol:234-237). `threshold` is empty, so
    ///      `validate` bounds amountOut only by `> 0` (TakerTraits.sol:173); the exact price is
    ///      asserted in the test. `instructionsArgs` reaches the extruction as `takerData`.
    function _takerTraitsAndData() internal view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.taker = taker;
        args.isExactIn = true;
        args.useTransferFromAndAquaPush = true;
        args.instructionsArgs = INSTRUCTIONS_ARGS;
        return TakerTraitsLib.build(args);
    }

    /// @dev `Curve.weightsAt` reads calldata.
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }

    /// @dev The USDC a basket of `weth` and `usdc` pays for `AMOUNT_IN` WETH at the top of the
    ///      two-leg curve (the maker has no debt: the sentinel HF), by the integral-form
    ///      reference at the pin's oracle prices.
    function _referenceOut(uint256 weth, uint256 usdc) internal returns (uint256) {
        uint256 unitWeth = oracle.getAssetPrice(WETH);
        uint256 unitUsdc = oracle.getAssetPrice(USDC) * 1e12;
        uint256 vW = weth * unitWeth;
        uint256 vU = usdc * unitUsdc;
        uint256[] memory w = this.weightsAt(Curves.twoLeg(), type(uint256).max);
        return PricingReference.outValue(vW, vU, w[0], w[1], vW + vU, AMOUNT_IN * unitWeth) / unitUsdc;
    }

    /// @dev The single-rate price of `AMOUNT_IN` WETH: the fill's value less `rate`, the spread
    ///      ceiled and the output floored, in USDC. What `_referenceOut` reduces to when the
    ///      fill crosses no target.
    function _singleRateOut(uint256 rate) internal view returns (uint256) {
        uint256 x = AMOUNT_IN * oracle.getAssetPrice(WETH);
        return (x - (x * rate + ONE - 1) / ONE) / (oracle.getAssetPrice(USDC) * 1e12);
    }

    /// @dev Walks `root` and reads every `.sol` file, failing on any needle. Returns the
    ///      number of files scanned.
    function _scanTree(string memory root, string[] memory needles) internal view returns (uint256 scanned) {
        Vm.DirEntry[] memory entries = vm.readDir(root, 8);
        for (uint256 i = 0; i < entries.length; i++) {
            string memory path = entries[i].path;
            if (entries[i].isDir || !_endsWith(path, ".sol")) {
                continue;
            }
            string memory source = vm.readFile(path);
            for (uint256 j = 0; j < needles.length; j++) {
                assertFalse(vm.contains(source, needles[j]), string.concat("swap-vm source found in ", path));
            }
            scanned++;
        }
    }

    function _endsWith(string memory subject, string memory suffix) internal pure returns (bool) {
        bytes memory s = bytes(subject);
        bytes memory x = bytes(suffix);
        if (x.length > s.length) {
            return false;
        }
        for (uint256 i = 0; i < x.length; i++) {
            if (s[s.length - x.length + i] != x[i]) {
                return false;
            }
        }
        return true;
    }
}
