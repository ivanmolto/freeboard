// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { ProgramLib } from "../utils/ProgramLib.sol";

/// @title AquaPathForkTest — T7
/// @notice The first end-to-end fill on the AQUA path: a strategy shipped to the DEPLOYED
///         Aqua at `Addresses.AQUA`, executed by the DEPLOYED AquaSwapVMRouter at
///         `Addresses.AQUA_SWAP_VM_ROUTER`, settling real mainnet ERC-20s in both directions.
///         Nothing of ours is deployed: this test deploys no contract of any kind.
///
/// @dev HOW THIS DIFFERS FROM T2. `ExtructionDispatchForkTest` runs the SIGNATURE path — bit
///      254 clear — so the router never touches Aqua, `balanceIn`/`balanceOut` stay 0, and no
///      shipped position is needed. Here bit 254 is SET, which changes three things
///      (`SwapVM.sol:193-198`, `:230-241`, `:266`):
///        - the maker's signature is not checked at all; the shipped strategy IS the mandate,
///        - `balanceIn`/`balanceOut` are preloaded from `AQUA.safeBalances` before the
///          program runs, which is what makes a balance-reading stock opcode meaningful,
///        - settlement goes through `AQUA.pull` / `AQUA.push` instead of a direct
///          `transferFrom`.
///
/// @dev THE PROGRAM IS ONE STOCK OPCODE. `_xycSwapXD` (0x11), no args, no extruction: this
///      task is about the Aqua plumbing, so the pricing is the router's own constant-product
///      instruction over the two preloaded balances. Because those balances are the SHIPPED
///      amounts and nothing else, the expected `amountOut` is a fixed integer independent of
///      the fork block — see `EXPECTED_AMOUNT_OUT`.
contract AquaPathForkTest is Test {
    /// @dev Every address comes from `src/constants/Addresses.sol`, where each is pinned by
    ///      bytecode (T3/T4). This test carries no address literals of its own.
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;

    address internal constant WETH = Addresses.WETH;
    address internal constant USDC = Addresses.USDC;

    /// @dev The shipped basket: 10 WETH (18 decimals) and 30,000 USDC (6 decimals).
    uint256 internal constant SHIPPED_WETH = 10 ether;
    uint256 internal constant SHIPPED_USDC = 30_000e6;

    /// @dev The taker sells 1 WETH for USDC, exact-in.
    uint256 internal constant AMOUNT_IN = 1 ether;

    /// @dev `_xycSwapXD`, exact-in branch (`XYCSwap.sol:22-25`):
    ///        amountOut = amountIn * balanceOut / (balanceIn + amountIn)
    ///                  = 1e18 * 30_000e6 / (10e18 + 1e18)
    ///                  = 3e28 / 11e18
    ///                  = 2_727_272_727 (floor division, as the instruction comment says it
    ///                    intends), i.e. 2727.272727 USDC.
    ///      Written as a literal, not recomputed from the formula, so a change in the
    ///      router's pricing is a failing assertion rather than a silently-tracking one.
    uint256 internal constant EXPECTED_AMOUNT_OUT = 2_727_272_727;

    address internal maker = address(0xB0A2E4);
    address internal taker = address(0x7A4E5);

    ProgramBuilder.Position internal position;

    function setUp() public {
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        require(forkBlock >= Addresses.MIN_FORK_BLOCK, "FORK_BLOCK is before the router exists");
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);

        assertEq(block.chainid, Addresses.CHAIN_ID, "not forking Ethereum mainnet");
        assertGt(ROUTER.code.length, 0, "no code at the deployed AquaSwapVMRouter on this fork block");
        assertGt(AQUA.code.length, 0, "no code at the deployed Aqua on this fork block");

        // The program: one stock instruction, `0x1100`.
        position = ProgramBuilder.aquaPosition(maker, ProgramLib.xycSwapXD());

        vm.label(ROUTER, "AquaSwapVMRouter");
        vm.label(AQUA, "Aqua");
        vm.label(maker, "maker");
        vm.label(taker, "taker");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
    }

    // -------------------------------------------------------------------------------------
    // The one test
    // -------------------------------------------------------------------------------------

    function test_AquaPath_ShipThenSwapMovesRealTokensOnBothSides() public {
        assertEq(position.order.data, hex"1100", "program must be exactly [0x11][0x00]");

        // -- 1. The ship -> execute round trip. -------------------------------------------
        //
        // The first assertion, because it is the one that goes wrong invisibly. `ship`
        // returns `keccak256(strategy)`; the router derives `keccak256(abi.encode(order))`
        // for an Aqua order. If those two numbers differ by one bit, everything below still
        // "works" right up to `safeBalances`, which then reverts against a strategy that was
        // never shipped.
        deal(WETH, maker, SHIPPED_WETH);
        deal(USDC, maker, SHIPPED_USDC);

        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SHIPPED_WETH;
        amounts[1] = SHIPPED_USDC;

        vm.prank(maker);
        bytes32 shippedHash = IAqua(AQUA).ship(ROUTER, position.strategy, tokens, amounts);

        assertEq(shippedHash, position.strategyHash, "ship() did not return keccak256(strategy)");
        assertEq(
            shippedHash,
            ISwapVM(ROUTER).hash(position.order),
            "shipped strategy hash != the router's order hash: the two calldatas have drifted"
        );

        // The router will read the balances under exactly this key: (maker, ROUTER as app,
        // orderHash, token). Reading them here proves the key resolves before any swap does.
        (uint256 balanceIn, uint256 balanceOut) = IAqua(AQUA).safeBalances(maker, ROUTER, shippedHash, WETH, USDC);
        assertEq(balanceIn, SHIPPED_WETH, "shipped WETH balance");
        assertEq(balanceOut, SHIPPED_USDC, "shipped USDC balance");

        // -- 2. The allowance gate. --------------------------------------------------------
        //
        // `ship()` moved no tokens — it only wrote the balance mapping (`Aqua.sol:46-51`, no
        // transfer in the loop). So the position now looks healthy by every observable
        // measure above AND is unfillable, because settlement is
        // `AQUA.pull` -> `IERC20(token).safeTransferFrom(maker, to, amount)`
        // (`Aqua.sol:63-70`), which spends the maker's ERC-20 allowance to Aqua.
        assertEq(IERC20(USDC).allowance(maker, AQUA), 0, "precondition: maker has not approved Aqua yet");

        bytes memory takerTraitsAndData = _takerTraitsAndData();

        // Proof, not commentary: the fill reverts right now, in `_transferOut`, and the
        // revert is the token transfer failing — not a strategy, balance or pricing error.
        vm.prank(taker);
        vm.expectRevert(SafeERC20.SafeTransferFromFailed.selector);
        ISwapVM(ROUTER).swap(position.order, WETH, USDC, AMOUNT_IN, takerTraitsAndData);

        // This is the line that makes the position live.
        vm.prank(maker);
        IERC20(USDC).approve(AQUA, SHIPPED_USDC);
        assertGe(IERC20(USDC).allowance(maker, AQUA), EXPECTED_AMOUNT_OUT, "maker's Aqua allowance must cover the fill");

        // -- 3. The quote, before any state moves. ----------------------------------------
        //
        // Same entry point as the swap for the Aqua preload (`SwapVM.sol:147-149`), so this
        // also proves the balances reach the program on the read-only path.
        deal(WETH, taker, AMOUNT_IN);
        vm.prank(taker);
        IERC20(WETH).approve(ROUTER, AMOUNT_IN);

        vm.prank(taker);
        (uint256 quotedIn, uint256 quotedOut, bytes32 quotedHash) =
            ISwapVM(ROUTER).quote(position.order, WETH, USDC, AMOUNT_IN, takerTraitsAndData);
        assertEq(quotedHash, shippedHash, "quote() orderHash");
        assertEq(quotedIn, AMOUNT_IN, "quote() amountIn");
        assertEq(quotedOut, EXPECTED_AMOUNT_OUT, "quote() amountOut is the constant-product price of the shipped basket");

        // -- 4. The fill, and the real ERC-20 deltas. --------------------------------------
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 takerWethBefore = IERC20(WETH).balanceOf(taker);
        uint256 takerUsdcBefore = IERC20(USDC).balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut, bytes32 orderHash) =
            ISwapVM(ROUTER).swap(position.order, WETH, USDC, AMOUNT_IN, takerTraitsAndData);

        assertEq(orderHash, shippedHash, "swap() orderHash");
        assertEq(amountIn, AMOUNT_IN, "swap() amountIn");
        assertEq(amountOut, EXPECTED_AMOUNT_OUT, "swap() amountOut must equal the quote");

        // Real tokens, both sides. The taker's WETH went taker -> router -> maker
        // (`useTransferFromAndAquaPush`: `SwapVM.sol:234-237` then `Aqua.sol:78`); the
        // maker's USDC went maker -> taker through `AQUA.pull` (`SwapVM.sol:266`, `:286`).
        assertEq(takerWethBefore - IERC20(WETH).balanceOf(taker), AMOUNT_IN, "taker paid WETH");
        assertEq(IERC20(WETH).balanceOf(maker) - makerWethBefore, AMOUNT_IN, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(taker) - takerUsdcBefore, EXPECTED_AMOUNT_OUT, "taker received USDC");
        assertEq(makerUsdcBefore - IERC20(USDC).balanceOf(maker), EXPECTED_AMOUNT_OUT, "maker paid USDC");

        // The router holds nothing afterwards: it was a conduit for the push, not a vault.
        assertEq(IERC20(WETH).balanceOf(ROUTER), 0, "router must not retain WETH");
        assertEq(IERC20(USDC).balanceOf(ROUTER), 0, "router must not retain USDC");

        // And Aqua's own accounting moved by the same amounts, so the position is still
        // fillable and now holds a different basket than the one that was shipped.
        (uint256 balanceInAfter, uint256 balanceOutAfter) =
            IAqua(AQUA).safeBalances(maker, ROUTER, shippedHash, WETH, USDC);
        assertEq(balanceInAfter, SHIPPED_WETH + AMOUNT_IN, "Aqua WETH balance after the push");
        assertEq(balanceOutAfter, SHIPPED_USDC - EXPECTED_AMOUNT_OUT, "Aqua USDC balance after the pull");
    }

    // -------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------

    /// @dev Built through the pinned library, because TakerTraits is a packed layout with a
    ///      20-byte slice table and a 22-byte header, not an ABI struct; passing `0x` reverts
    ///      in `TakerTraitsLib.parse` (`TakerTraits.sol:167-170`).
    ///
    ///      `useTransferFromAndAquaPush` is the flag that makes the router pull tokenIn from
    ///      the taker and push it into the maker's Aqua balance itself (`SwapVM.sol:234-237`).
    ///      Without it the router only CHECKS that the taker already pushed
    ///      (`SwapVM.sol:239-240`), which would need a callback the taker here does not have.
    ///
    ///      `threshold` is empty, so `validate` bounds `amountOut` only by `> 0`
    ///      (`TakerTraits.sol:173`); the exact price is asserted in the test instead.
    ///      `signature` is empty: on the Aqua path it is never read.
    function _takerTraitsAndData() internal view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.taker = taker;
        args.isExactIn = true;
        args.useTransferFromAndAquaPush = true;
        return TakerTraitsLib.build(args);
    }
}
