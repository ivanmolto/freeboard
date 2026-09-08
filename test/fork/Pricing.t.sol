// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { IStaticExtruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { FreeboardExtruction } from "../../src/FreeboardExtruction.sol";
import { IPoolAddressesProvider } from "../../src/interfaces/IAaveV3.sol";
import { IAaveV3Oracle } from "../../src/interfaces/IAaveV3Oracle.sol";
import { IAaveV3Pool } from "../../src/interfaces/IAaveV3Pool.sol";
import { Curve } from "../../src/libs/Curve.sol";

import { IAaveProtocolDataProvider, IAaveV3PoolFixture } from "../utils/AaveFixtures.sol";
import { Curves } from "../utils/Curves.sol";
import { PricingReference } from "../utils/PricingReference.sol";
import { ProgramBuilder } from "../utils/ProgramBuilder.sol";

/// @title PricingForkTest — T14
/// @notice `_healthWeightedTarget` on the DEPLOYED AquaSwapVMRouter, on a real three-leg Aqua
///         basket, priced against a real Aave v3 position: the health factor read from the
///         Pool, the prices from the oracle the provider names, the WBTC leg — the one that is
///         neither `tokenIn` nor `tokenOut` — read from Aqua's `rawBalances`, and the fill
///         settled with real WETH and USDC moving. The quote is asserted to the wei against
///         `PricingReference`, an independent derivation of the same rule.
///
/// @dev THE FIXTURE. Alice has 100 WETH of Aave collateral and enough USDC debt to sit at HF
///      1.60, where the curve says 40 / 24 / 36. Her basket is 10 WETH, 0.3 WBTC and 30,000
///      USDC — at the pin about 31.5% / 30.6% / 37.9% — so WETH is under target and USDC over:
///      a taker selling WETH for USDC moves BOTH legs toward target, and 1 WETH is more than
///      USDC's excess, so the fill crosses USDC's target part-way and finishes mixed. That
///      crossing is what makes the reference a real check: the contract prices by distance
///      before and after, the reference integrates two pieces, and they must agree.
///
/// @dev THE GAS ARTIFACT. `test_Gas_OneFillThroughTheDeployedRouter` writes `results/gas.txt`:
///      `quote()` and `swap()` through the deployed router, the extruction alone with the
///      router's exact inputs, and the Aave read alone — each COLD, by restoring a state
///      snapshot taken before the first touch (`docs/NOTES-gas.md` §6).
contract PricingForkTest is Test {
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant WETH = Addresses.WETH;
    address internal constant WBTC = Addresses.WBTC;
    address internal constant USDC = Addresses.USDC;

    IAaveV3PoolFixture internal constant POOL = IAaveV3PoolFixture(Addresses.AAVE_V3_POOL);
    IPoolAddressesProvider internal constant PROVIDER =
        IPoolAddressesProvider(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER);

    uint256 internal constant ONE = 1e18;
    uint256 internal constant VARIABLE_RATE = 2;
    uint256 internal constant AAVE_WETH_COLLATERAL = 100e18;
    uint256 internal constant HF_TARGET = 1.6e18;
    uint256 internal constant HF_TOLERANCE = 1e12;

    uint256 internal constant SHIPPED_WETH = 10 ether;
    uint256 internal constant SHIPPED_WBTC = 0.3e8;
    uint256 internal constant SHIPPED_USDC = 30_000e6;
    uint16 internal constant MAX_SHIFT_BPS = 500;

    /// @dev The taker sells 1 WETH for USDC, exact-in.
    uint256 internal constant AMOUNT_IN = 1 ether;

    bytes internal constant INSTRUCTIONS_ARGS = hex"c0ffee";

    address internal alice;
    address internal taker;
    address internal aWeth;
    IAaveV3Oracle internal oracle;

    FreeboardExtruction internal freeboard;
    ProgramBuilder.Position internal position;

    // -----------------------------------------------------------------------------------
    // Fixture
    // -----------------------------------------------------------------------------------

    function setUp() public {
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        require(forkBlock >= Addresses.MIN_FORK_BLOCK, "FORK_BLOCK is before the router exists");
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);

        assertEq(block.chainid, Addresses.CHAIN_ID, "not forking Ethereum mainnet");
        assertEq(ROUTER.code.length, Addresses.ROUTER_RUNTIME_SIZE, "deployed AquaSwapVMRouter runtime size");
        assertEq(AQUA.code.length, Addresses.AQUA_RUNTIME_SIZE, "deployed Aqua runtime size");

        (aWeth,,) = IAaveProtocolDataProvider(PROVIDER.getPoolDataProvider()).getReserveTokensAddresses(WETH);
        oracle = IAaveV3Oracle(PROVIDER.getPriceOracle());
        assertEq(address(oracle), Addresses.AAVE_V3_ORACLE, "the provider names the pinned oracle");

        freeboard = new FreeboardExtruction();
        alice = makeAddr("alice");
        taker = makeAddr("freeboard-taker");

        _openAavePosition(alice, HF_TARGET);
        position = ProgramBuilder.freeboardPosition(
            alice, address(freeboard), Curves.freeboard(), Curves.freeboardTokens(), MAX_SHIFT_BPS
        );
        _ship(alice);

        deal(WETH, taker, 10 * AMOUNT_IN);
        vm.prank(taker);
        IERC20(WETH).approve(ROUTER, type(uint256).max);

        vm.label(ROUTER, "AquaSwapVMRouter");
        vm.label(AQUA, "Aqua");
        vm.label(Addresses.AAVE_V3_POOL, "AaveV3Pool");
        vm.label(address(oracle), "AaveOracle");
        vm.label(address(freeboard), "FreeboardExtruction");
        vm.label(alice, "alice");
        vm.label(taker, "taker");
        vm.label(WETH, "WETH");
        vm.label(WBTC, "WBTC");
        vm.label(USDC, "USDC");
    }

    /// @dev A real Aave position at `targetHf`: WETH collateral, USDC variable debt. Inverts
    ///      `GenericLogic` as `HealthFactorForkTest` does.
    function _openAavePosition(address maker, uint256 targetHf) internal {
        deal(WETH, maker, AAVE_WETH_COLLATERAL);
        vm.startPrank(maker);
        IERC20(WETH).approve(Addresses.AAVE_V3_POOL, AAVE_WETH_COLLATERAL);
        POOL.supply(WETH, AAVE_WETH_COLLATERAL, maker, 0);
        vm.stopPrank();

        uint256 weightedCollateral =
            ((IERC20(aWeth).balanceOf(maker) * oracle.getAssetPrice(WETH)) / 1e18) * Addresses.LT_WETH_BPS;
        uint256 borrowAmount = ((weightedCollateral * 1e14) / targetHf) * 1e6 / oracle.getAssetPrice(USDC);

        vm.prank(maker);
        POOL.borrow(USDC, borrowAmount, VARIABLE_RATE, 0, maker);

        assertApproxEqAbs(_poolHealthFactor(maker), targetHf, HF_TOLERANCE, "fixture missed its target HF");
    }

    /// @dev Ships the three-token basket and approves Aqua for every leg: the allowance, not the
    ///      shipped amounts, is what makes a position fillable.
    function _ship(address maker) internal {
        deal(WETH, maker, SHIPPED_WETH);
        deal(WBTC, maker, SHIPPED_WBTC);
        deal(USDC, maker, SHIPPED_USDC);

        address[] memory tokens = Curves.freeboardTokens();
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = SHIPPED_WETH;
        amounts[1] = SHIPPED_WBTC;
        amounts[2] = SHIPPED_USDC;

        vm.startPrank(maker);
        bytes32 shippedHash = IAqua(AQUA).ship(ROUTER, position.strategy, tokens, amounts);
        IERC20(WETH).approve(AQUA, SHIPPED_WETH);
        IERC20(WBTC).approve(AQUA, SHIPPED_WBTC);
        IERC20(USDC).approve(AQUA, SHIPPED_USDC);
        vm.stopPrank();

        assertEq(shippedHash, position.strategyHash, "ship() did not return keccak256(strategy)");
        assertEq(ISwapVM(ROUTER).hash(position.order), position.strategyHash, "router hash != shipped strategy hash");
    }

    function _poolHealthFactor(address who) internal view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = POOL.getUserAccountData(who);
    }

    function _takerTraitsAndData() internal view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.taker = taker;
        args.isExactIn = true;
        args.useTransferFromAndAquaPush = true;
        args.instructionsArgs = INSTRUCTIONS_ARGS;
        return TakerTraitsLib.build(args);
    }

    function _quote() internal returns (uint256 amountOut) {
        vm.prank(taker);
        (, amountOut,) = ISwapVM(ROUTER).quote(position.order, WETH, USDC, AMOUNT_IN, _takerTraitsAndData());
    }

    function _swap() internal returns (uint256 amountOut) {
        vm.prank(taker);
        (, amountOut,) = ISwapVM(ROUTER).swap(position.order, WETH, USDC, AMOUNT_IN, _takerTraitsAndData());
    }

    /// @dev Value units per wei, as the extruction defines them: price scaled to 18 decimals.
    function _unit(address token, uint256 decimals) internal view returns (uint256) {
        return oracle.getAssetPrice(token) * 10 ** (18 - decimals);
    }

    /// @dev `Curve.weightsAt` reads calldata.
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }

    /// @dev The reference price of selling `amountIn` WETH for USDC against the basket Aqua
    ///      holds right now, at Alice's health factor right now, by the integral form.
    function _referenceOut(uint256 amountIn) internal returns (uint256 amountOut, uint256 fairOut) {
        (uint256 weth,) = IAqua(AQUA).rawBalances(alice, ROUTER, position.strategyHash, WETH);
        (uint256 wbtc,) = IAqua(AQUA).rawBalances(alice, ROUTER, position.strategyHash, WBTC);
        (uint256 usdc,) = IAqua(AQUA).rawBalances(alice, ROUTER, position.strategyHash, USDC);

        uint256 vW = weth * _unit(WETH, 18);
        uint256 vB = wbtc * _unit(WBTC, 8);
        uint256 vU = usdc * _unit(USDC, 6);
        uint256[] memory w = this.weightsAt(Curves.freeboard(), _poolHealthFactor(alice));

        uint256 x = amountIn * _unit(WETH, 18);
        amountOut = PricingReference.outValue(vW, vU, w[0], w[2], vW + vB + vU, x) / _unit(USDC, 6);
        fairOut = x / _unit(USDC, 6);
    }

    // -----------------------------------------------------------------------------------
    // THE DoD, on the deployed router
    // -----------------------------------------------------------------------------------

    /// @notice A real fill, priced by the health-weighted target, settled through Aqua.
    function test_Fill_PricesTheThreeLegBasketOnTheDeployedRouter() public {
        // -- 0. Where the basket stands against the curve at Alice's real HF. ----------------
        uint256 hf = _poolHealthFactor(alice);
        assertApproxEqAbs(hf, HF_TARGET, HF_TOLERANCE, "alice is at HF 1.60");
        uint256[] memory w = this.weightsAt(Curves.freeboard(), hf);

        uint256 vW = SHIPPED_WETH * _unit(WETH, 18);
        uint256 vB = SHIPPED_WBTC * _unit(WBTC, 8);
        uint256 vU = SHIPPED_USDC * _unit(USDC, 6);
        uint256 total = vW + vB + vU;
        uint256 x = AMOUNT_IN * _unit(WETH, 18);

        assertLt(vW * ONE, w[0] * total, "fixture: WETH must start under its target");
        assertGt(vU * ONE, w[2] * total, "fixture: USDC must start over its target");
        assertGt(w[0] * total - vW * ONE, x * ONE, "fixture: 1 WETH must not reach WETH's target");
        assertLt(vU * ONE - w[2] * total, x * ONE, "fixture: 1 WETH must cross USDC's target");

        emit log_named_decimal_uint("alice HF", hf, 18);
        emit log_named_decimal_uint("WETH share (%)", vW * 100e18 / total, 18);
        emit log_named_decimal_uint("WBTC share (%)", vB * 100e18 / total, 18);
        emit log_named_decimal_uint("USDC share (%)", vU * 100e18 / total, 18);
        emit log_named_decimal_uint("target WETH (%)", w[0] * 100, 18);
        emit log_named_decimal_uint("target WBTC (%)", w[1] * 100, 18);
        emit log_named_decimal_uint("target USDC (%)", w[2] * 100, 18);

        // -- 1. The quote: the HF read for Alice, the WBTC leg read from Aqua. --------------
        (uint256 referenceOut, uint256 fairOut) = _referenceOut(AMOUNT_IN);

        vm.expectCall(Addresses.AAVE_V3_POOL, abi.encodeCall(IAaveV3Pool.getUserAccountData, (alice)));
        vm.expectCall(AQUA, abi.encodeCall(IAqua.rawBalances, (alice, ROUTER, position.strategyHash, WBTC)));
        uint256 quotedOut = _quote();

        assertEq(quotedOut, referenceOut, "the deployed router's quote != the integral-form reference");
        assertLt(quotedOut, fairOut * (ONE - PricingReference.TOWARD) / ONE, "part of the fill is mixed: below 10 bps");
        assertGt(quotedOut, fairOut * (ONE - PricingReference.MIXED) / ONE, "part of the fill is toward: above 55 bps");

        emit log_named_decimal_uint("fair (oracle) USDC out", fairOut, 6);
        emit log_named_decimal_uint("quoted USDC out", quotedOut, 6);
        emit log_named_decimal_uint("spread kept by alice, USDC", fairOut - quotedOut, 6);

        // -- 2. The swap settles the quoted amount, with real tokens moving. ----------------
        uint256 takerWethBefore = IERC20(WETH).balanceOf(taker);
        uint256 takerUsdcBefore = IERC20(USDC).balanceOf(taker);
        uint256 aliceWethBefore = IERC20(WETH).balanceOf(alice);
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        uint256 aliceWbtcBefore = IERC20(WBTC).balanceOf(alice);

        vm.expectCall(AQUA, abi.encodeCall(IAqua.rawBalances, (alice, ROUTER, position.strategyHash, WBTC)));
        uint256 swappedOut = _swap();
        assertEq(swappedOut, quotedOut, "swap() != quote()");

        assertEq(takerWethBefore - IERC20(WETH).balanceOf(taker), AMOUNT_IN, "taker paid WETH");
        assertEq(IERC20(USDC).balanceOf(taker) - takerUsdcBefore, swappedOut, "taker received USDC");
        assertEq(IERC20(WETH).balanceOf(alice) - aliceWethBefore, AMOUNT_IN, "alice received WETH");
        assertEq(aliceUsdcBefore - IERC20(USDC).balanceOf(alice), swappedOut, "alice paid USDC");
        assertEq(IERC20(WBTC).balanceOf(alice), aliceWbtcBefore, "the WBTC leg was read, not moved");

        (uint256 aquaWeth, uint256 aquaUsdc) =
            IAqua(AQUA).safeBalances(alice, ROUTER, position.strategyHash, WETH, USDC);
        (uint256 aquaWbtc,) = IAqua(AQUA).rawBalances(alice, ROUTER, position.strategyHash, WBTC);
        assertEq(aquaWeth, SHIPPED_WETH + AMOUNT_IN, "Aqua WETH after the push");
        assertEq(aquaUsdc, SHIPPED_USDC - swappedOut, "Aqua USDC after the pull");
        assertEq(aquaWbtc, SHIPPED_WBTC, "Aqua WBTC untouched");

        // The read is a read: Alice's Aave position is where it was.
        assertApproxEqAbs(_poolHealthFactor(alice), hf, HF_TOLERANCE, "the fill moved alice's Aave debt");

        // -- 3. The next fill reprices from the moved basket, same block. --------------------
        //
        // USDC is now under its target, so shedding more of it is away; the next 1 WETH is
        // mixed the whole way and prices worse. The reference tracks the live Aqua balances.
        (uint256 referenceAfter,) = _referenceOut(AMOUNT_IN);
        uint256 quotedAfter = _quote();
        assertEq(quotedAfter, referenceAfter, "the repriced quote != the reference from live balances");
        assertLt(quotedAfter, quotedOut, "after the fill the same trade must price worse");
        emit log_named_decimal_uint("next quote USDC out", quotedAfter, 6);
    }

    // -----------------------------------------------------------------------------------
    // The gas artifact
    // -----------------------------------------------------------------------------------

    /// @notice One fill's gas through the deployed router, quote and swap, each cold, and the
    ///         Aave read's share of it. Emits `results/gas.txt`.
    /// @dev Every measurement restores the snapshot taken as the FIRST statement of the test,
    ///      which `docs/NOTES-gas.md` §6 shows restores the cold-access surcharges; each figure
    ///      is therefore what the first fill of a transaction pays. `lastCallGas().gasTotalUsed`
    ///      is the callee-perspective cost, as T8 measured the read.
    function test_Gas_OneFillThroughTheDeployedRouter() public {
        uint256 snapshot = vm.snapshotState();

        bytes memory takerTraitsAndData = _takerTraitsAndData();

        vm.prank(taker);
        ISwapVM(ROUTER).quote(position.order, WETH, USDC, AMOUNT_IN, takerTraitsAndData);
        uint256 gasQuote = vm.lastCallGas().gasTotalUsed;

        vm.revertToState(snapshot);
        vm.prank(taker);
        ISwapVM(ROUTER).swap(position.order, WETH, USDC, AMOUNT_IN, takerTraitsAndData);
        uint256 gasSwap = vm.lastCallGas().gasTotalUsed;

        // The extruction alone, with exactly the inputs the router hands it (T9 pinned them).
        vm.revertToState(snapshot);
        SwapQuery memory query = SwapQuery({
            orderHash: position.strategyHash, maker: alice, taker: taker, tokenIn: WETH, tokenOut: USDC, isExactIn: true
        });
        SwapRegisters memory entry = SwapRegisters({
            balanceIn: SHIPPED_WETH, balanceOut: SHIPPED_USDC, amountIn: AMOUNT_IN, amountOut: 0, amountNetPulled: 0
        });
        IStaticExtruction(address(freeboard))
            .extruction(true, position.order.data.length, query, entry, position.extructionArgs, INSTRUCTIONS_ARGS);
        uint256 gasExtruction = vm.lastCallGas().gasTotalUsed;

        vm.revertToState(snapshot);
        POOL.getUserAccountData(alice);
        uint256 gasAave = vm.lastCallGas().gasTotalUsed;

        assertLt(gasAave, gasExtruction, "the read is part of the extruction");
        assertLt(gasExtruction, gasQuote, "the extruction is part of the quote");
        assertLt(gasQuote, gasSwap, "settlement costs more than quoting");

        string memory report = string.concat(
            "# results/gas.txt - T14\n",
            "# Emitted by test/fork/Pricing.t.sol (PricingForkTest.test_Gas_OneFillThroughTheDeployedRouter).\n",
            "# Never edited by hand. Ethereum mainnet fork, FORK_BLOCK=",
            vm.toString(block.number),
            ".\n#\n",
            "# One fill through the DEPLOYED AquaSwapVMRouter (0x111111338c5091E8440b67B168bAe16a668AC0De)\n",
            "# with the Freeboard program: one _extruction (0x20) to FreeboardExtruction, 212 bytes of\n",
            "# args (4-breakpoint curve, 3 tokens, maxShiftBps). Basket WETH / WBTC / USDC, maker at Aave\n",
            "# health factor 1.60 (WETH collateral, USDC variable debt: a 2-reserve read), taker sells\n",
            "# 1 WETH for USDC exact-in. The fill crosses USDC's target, so both pricing pieces run.\n",
            "# Every figure is COLD: measured after restoring a state snapshot taken before the first\n",
            "# touch (docs/NOTES-gas.md section 6); gasTotalUsed from the callee's perspective.\n#\n"
        );
        report = string.concat(
            report,
            _row("quote() through the deployed router", gasQuote),
            _row("swap() through the deployed router", gasSwap),
            _row("FreeboardExtruction.extruction(), router's exact inputs", gasExtruction),
            _row("Aave Pool.getUserAccountData(maker), 2 reserves", gasAave),
            "#\n# The Aave read's share:  ",
            _pct(gasAave, gasQuote),
            "% of quote()   ",
            _pct(gasAave, gasSwap),
            "% of swap()   ",
            _pct(gasAave, gasExtruction),
            "% of the extruction\n",
            "# The extruction's share: ",
            _pct(gasExtruction, gasQuote),
            "% of quote()   ",
            _pct(gasExtruction, gasSwap),
            "% of swap()\n"
        );
        vm.writeFile("results/gas.txt", report);

        emit log_named_uint("quote() cold", gasQuote);
        emit log_named_uint("swap() cold", gasSwap);
        emit log_named_uint("extruction() cold", gasExtruction);
        emit log_named_uint("Aave read cold", gasAave);
    }

    function _row(string memory label, uint256 gas) internal pure returns (string memory) {
        bytes memory padded = bytes(label);
        while (padded.length < 58) {
            padded = bytes.concat(padded, " ");
        }
        return string.concat(string(padded), vm.toString(gas), "\n");
    }

    /// @dev One decimal place.
    function _pct(uint256 part, uint256 whole) internal pure returns (string memory) {
        uint256 tenths = part * 1000 / whole;
        return string.concat(vm.toString(tenths / 10), ".", vm.toString(tenths % 10));
    }
}
