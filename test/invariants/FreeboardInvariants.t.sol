// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { CoreInvariants } from "@1inch/swap-vm/test/invariants/CoreInvariants.t.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { FreeboardExtruction } from "../../src/FreeboardExtruction.sol";
import { IPoolAddressesProvider } from "../../src/interfaces/IAaveV3.sol";
import { IAaveV3Oracle } from "../../src/interfaces/IAaveV3Oracle.sol";
import { Curve } from "../../src/libs/Curve.sol";

import { IAaveProtocolDataProvider, IAaveV3PoolFixture } from "../utils/AaveFixtures.sol";
import { Curves } from "../utils/Curves.sol";
import { ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { ProgramLib } from "../utils/ProgramLib.sol";

/// @title FreeboardInvariantsForkTest — T28
/// @notice swap-vm's OWN invariant suite, `CoreInvariants.assertAllInvariantsWithConfig`
///         (swap-vm v1.0.2, `test/invariants/CoreInvariants.t.sol:107-218`), imported from the
///         pinned dependency, not copied, and run against THE Freeboard program — one
///         `_extruction` (0x20) to `FreeboardExtruction`, nothing else — on the DEPLOYED
///         AquaSwapVMRouter and the deployed Aqua, over every directed pair of the three-leg
///         basket.
///
/// @dev WHAT THE SUITE CHECKS, as the file at the pin has it (each against `quote()`/`swap()`
///      on the router handed in, here the deployed one):
///        symmetry            exactOut(exactIn(X)) is X within `symmetryTolerance`   (:224-262)
///        quote/swap          quote() == swap(), both amounts, exact-in AND exact-out (:336-367)
///        monotonicity        a larger exact-in never gets a better average price     (:374-419)
///        additivity          swap(A+B) pays out at least swap(A) then swap(B)        (:270-330)
///        rounding            1..1000-wei fills never beat the one-token spot rate    (:426-510)
///        balance sufficiency a 1e24-unit fill reverts or quotes non-zero            (:516-536)
///      Every check runs; no `skip*` flag is set. There is no "strategy liveness" check in the
///      suite at v1.0.2 — the word does not occur under `test/invariants/`. The nearest it
///      comes is the consistency check's `assertGt(quotedIn, 0)` / `assertGt(quotedOut, 0)`
///      (:349-350), which here runs on every amount, both sides, on all six pairs.
///
/// @dev THE HARNESS IS THE AQUA PATH, WHICH NO UPSTREAM SUITE WALKS. Every `CoreInvariants`
///      subclass at the pin signs its orders (`useAquaInsteadOfSignature: false`) against a
///      freshly deployed router. Here the order is an Aqua order shipped by the maker, and
///      `_executeSwap` settles through the deployed router with `useTransferFromAndAquaPush`
///      (`SwapVM.sol:234-237`). It returns the REAL ERC-20 deltas of the taker, not the router's
///      return values, and requires the router's values and the maker's deltas to equal them —
///      so the consistency check compares the quote with tokens that moved.
///
/// @dev THE FIXTURE. Alice borrows USDC against 100 WETH on Aave to HF 1.45, between the curve's
///      1.60 and 1.30 rows, so the targets are interpolated: 35 / 20 / 45. Her basket is shipped
///      at 33 / 21 / 46 — WETH 2 points under target, WBTC and USDC 1 point over each. On a
///      $4,000,000 basket that puts a target crossing $40,000 into every fill out of WBTC or
///      USDC, inside the tested sizes, so the six pairs cover every regime of the schedule:
///        WETH -> WBTC, WETH -> USDC   toward, then mixed past $40,000
///        WBTC -> USDC, USDC -> WBTC   mixed, then away past $40,000
///        WBTC -> WETH, USDC -> WETH   away throughout
///
/// @dev CONFIGURATION, AND WHY EACH VALUE. The suite's defaults are written for two 18-decimal
///      mock tokens of equal value. Freeboard's legs are 18, 8 and 6 decimals at $2,498, $80,903
///      and $1 a token; the three settings below are those defaults restated in these units,
///      not relaxations:
///        testAmounts         $5,000 / $20,000 / $60,000 of the in token (exact-out: of the
///                            out token), not 1e18 / 10e18 / 50e18 — 50 WETH is 3% of this
///                            basket, 50e18 wei of USDC is 5e13 USDC. Additivity fills
///                            3 x $60,000 = $180,000, under the 500 bps cap of $200,000.
///        symmetryTolerance   2 * ceil(unitOut / unitIn) wei of the in token. The default is
///                            2 wei, and it is exactly this when a wei of each token is worth
///                            the same. An exact-in fill FLOORS its output to a whole wei of the
///                            out token, so the exact-out fill for that output can cost up to
///                            one out-token wei of value less, in in-token wei — one wei of
///                            USDC is 4e8 wei of WETH. See `_symmetryTolerance`.
///        basket size         $4,000,000, because the rounding check probes the spot rate with
///                            ONE WHOLE in token, outside any try/catch (:448-450), and one
///                            WBTC is $80,903: a legal fill under a 500 bps cap needs a basket
///                            of at least $1.62M.
///      `roundingToleranceBps` is the suite's default, 100. Two settings ARE relaxed from the
///      defaults, each for a measured reason, and each paired with an exact assertion of its
///      own so the relaxation hides nothing:
///        monotonicityToleranceBps  1, from 0. The suite compares average prices of a $5,000
///                            and a $20,000 fill; in a flat-rate stretch of the schedule the
///                            two differ only by the wei the smaller fill's output was floored
///                            to, and the suite's check has no wei-level allowance. One bps is
///                            the smallest tolerance it can express; `_assertMonotoneToTheWei`
///                            then asserts the exact statement — larger never better, within
///                            one wei of output on the smaller fill — the form
///                            `testFuzz_Pricing_IsMonotoneInSize` fuzzes.
///        additivityTolerance a bound derived from the spread schedule, from 0:
///                            `(SPREAD_AWAY - SPREAD_TOWARD) * SPREAD_AWAY * A` in out-token
///                            wei, under 0.9 bps of the first slice `A`, plus two wei of
///                            rounding. A split fill across a target crossing DOES pay the
///                            taker slightly more than one fill: the single fill prices its
///                            move as if the whole value in left the out leg, while the maker
///                            keeps the spread. `test_Additivity_TheGapIsTheSpreadTheSingleFillsModelDropped`
///                            measures the gap on the two crossing pairs and shows it is
///                            exactly that dropped spread; `testFuzz_ASplitFill_PaysAtLeastTheSingleFill_AndAtMostTheBoundMore`
///                            fuzzes the bound and the direction. The suite's exact-out
///                            additivity is vacuous — it compares outputs, and exact-out fixes
///                            them — so the exact-in run is the one that counts.
contract FreeboardInvariantsForkTest is CoreInvariants {
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant WETH = Addresses.WETH;
    address internal constant WBTC = Addresses.WBTC;
    address internal constant USDC = Addresses.USDC;

    /// @dev The suite's methods take the concrete `SwapVM` type; the deployed router inherits
    ///      it. A cast of the pinned address — nothing is deployed.
    SwapVM internal constant DEPLOYED_ROUTER = SwapVM(payable(Addresses.AQUA_SWAP_VM_ROUTER));

    IAaveV3PoolFixture internal constant POOL = IAaveV3PoolFixture(Addresses.AAVE_V3_POOL);
    IPoolAddressesProvider internal constant PROVIDER =
        IPoolAddressesProvider(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER);

    uint256 internal constant ONE = 1e18;
    uint256 internal constant USD = Addresses.AAVE_BASE_CURRENCY_UNIT;
    uint256 internal constant VARIABLE_RATE = 2;

    uint256 internal constant AAVE_WETH_COLLATERAL = 100e18;
    uint256 internal constant HF_TARGET = 1.45e18;
    uint256 internal constant HF_TOLERANCE = 1e12;

    /// @dev The basket, by value at the oracle, and its composition — off the HF 1.45 targets
    ///      of 35 / 20 / 45 by -2 / +1 / +1 points.
    uint256 internal constant BASKET_USD = 4_000_000;
    uint256 internal constant SHIP_W_WETH = 0.33e18;
    uint256 internal constant SHIP_W_WBTC = 0.21e18;
    uint256 internal constant SHIP_W_USDC = 0.46e18;

    uint16 internal constant MAX_SHIFT_BPS = 500;

    /// @dev The schedule, 10 / 55 / 100 bps, as `test_Schedule_IsExactInWad` pins it to the
    ///      contract's constants. Used only to derive the additivity bound and the closed form.
    uint256 internal constant TOWARD = 0.001e18;
    uint256 internal constant MIXED = 0.0055e18;
    uint256 internal constant AWAY = 0.01e18;

    /// @dev The tested fill sizes, in USD, ascending — the suite's monotonicity check reads the
    ///      array in order.
    uint256 internal constant FILL_S_USD = 5000;
    uint256 internal constant FILL_M_USD = 20_000;
    uint256 internal constant FILL_L_USD = 60_000;

    address internal alice;
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

        oracle = IAaveV3Oracle(PROVIDER.getPriceOracle());
        freeboard = new FreeboardExtruction();
        alice = makeAddr("alice");

        _openAavePosition(alice, HF_TARGET);
        position = ProgramBuilder.freeboardPosition(
            alice, address(freeboard), Curves.freeboard(), Curves.freeboardTokens(), MAX_SHIFT_BPS
        );
        _ship(position, _shippedAmounts());

        // The taker is this contract: the suite quotes with `swapVM.asView().quote(...)` from
        // here, so `query.taker` is `address(this)` on both paths, and the router pulls
        // tokenIn from it (`SwapVM.sol:235`). Funded far past any fill the suite makes.
        deal(WETH, address(this), 100_000 ether);
        deal(WBTC, address(this), 10_000e8);
        deal(USDC, address(this), 1_000_000_000e6);
        IERC20(WETH).approve(ROUTER, type(uint256).max);
        IERC20(WBTC).approve(ROUTER, type(uint256).max);
        IERC20(USDC).approve(ROUTER, type(uint256).max);

        vm.label(ROUTER, "AquaSwapVMRouter");
        vm.label(AQUA, "Aqua");
        vm.label(address(freeboard), "FreeboardExtruction");
        vm.label(alice, "alice");
    }

    // -----------------------------------------------------------------------------------
    // The DoD: the suite, on every directed pair
    // -----------------------------------------------------------------------------------

    function test_CoreInvariants_WethIn_WbtcOut() public {
        _assertAllInvariants(WETH, WBTC);
    }

    function test_CoreInvariants_WethIn_UsdcOut() public {
        _assertAllInvariants(WETH, USDC);
    }

    function test_CoreInvariants_WbtcIn_WethOut() public {
        _assertAllInvariants(WBTC, WETH);
    }

    function test_CoreInvariants_WbtcIn_UsdcOut() public {
        _assertAllInvariants(WBTC, USDC);
    }

    function test_CoreInvariants_UsdcIn_WethOut() public {
        _assertAllInvariants(USDC, WETH);
    }

    function test_CoreInvariants_UsdcIn_WbtcOut() public {
        _assertAllInvariants(USDC, WBTC);
    }

    /// @notice The fixture the six runs share: HF 1.45 on the pool, the curve interpolated to
    ///         35 / 20 / 45, the basket at 33 / 21 / 46, one instruction in the program.
    function test_Fixture_IsTheFreeboardProgram_OffTarget_BetweenTwoRows() public {
        assertApproxEqAbs(_poolHealthFactor(alice), HF_TARGET, HF_TOLERANCE, "alice is at HF 1.45");
        uint256[] memory w = this.weightsAt(Curves.freeboard(), _poolHealthFactor(alice));
        assertApproxEqAbs(w[0], 0.35e18, 1e12, "target WETH at HF 1.45");
        assertApproxEqAbs(w[1], 0.2e18, 1e12, "target WBTC at HF 1.45");
        assertApproxEqAbs(w[2], 0.45e18, 1e12, "target USDC at HF 1.45");

        uint256[3] memory v = [_aquaValue(WETH), _aquaValue(WBTC), _aquaValue(USDC)];
        uint256 total = v[0] + v[1] + v[2];
        assertApproxEqRel(total, BASKET_USD * USD * ONE, 1e12, "basket value");
        assertApproxEqAbs(v[0] * ONE / total, SHIP_W_WETH, 1e12, "WETH 2 points under target");
        assertApproxEqAbs(v[1] * ONE / total, SHIP_W_WBTC, 1e12, "WBTC 1 point over target");
        assertApproxEqAbs(v[2] * ONE / total, SHIP_W_USDC, 1e12, "USDC 1 point over target");

        bytes memory program = position.order.data;
        assertEq(uint8(program[0]), ProgramLib.EXTRUCTION, "the one instruction is _extruction");
        assertEq(
            program, abi.encodePacked(hex"20", uint8(20 + position.extructionArgs.length), address(freeboard), position.extructionArgs)
        );
        assertEq(ISwapVM(ROUTER).hash(position.order), position.strategyHash, "router hash == shipped hash");
    }

    /// @notice The suite's additivity gap, measured on the deployed router on the two pairs
    ///         whose second slice crosses a target, and shown to be exactly the spread the single
    ///         fill's model dropped: pricing the second slice from the state the single fill
    ///         MODELS after the first — the whole value in gone from the out leg, the basket
    ///         unchanged in size — reproduces the single fill to rounding, while pricing it
    ///         from the LIVE basket, as the router does, pays the spread of the first slice
    ///         back at the rate step it crossed. The gap is strictly positive, under the bound,
    ///         and in this regime — first slice toward, out leg crossing in the second, in leg
    ///         not crossing — equal to `(SPREAD_MIXED - SPREAD_TOWARD) * (1 - w_out) * S(A)`.
    function test_Additivity_TheGapIsTheSpreadTheSingleFillsModelDropped() public {
        _assertAdditivityGap(WETH, USDC);
        _assertAdditivityGap(WETH, WBTC);
    }

    function _assertAdditivityGap(address tokenIn, address tokenOut) internal {
        uint256 a = _tokens(tokenIn, FILL_M_USD);
        uint256 b = 2 * a;
        bytes memory takerData = _takerData(true);
        (uint256 bIn, uint256 bOut) = IAqua(AQUA).safeBalances(alice, ROUTER, position.strategyHash, tokenIn, tokenOut);

        // One fill of A + B.
        uint256 snapshot = vm.snapshotState();
        (, uint256 single) = _executeSwap(DEPLOYED_ROUTER, position.order, tokenIn, tokenOut, a + b, takerData);
        vm.revertToState(snapshot);

        // A, then B from the live basket — what the suite's split does.
        snapshot = vm.snapshotState();
        (, uint256 outA) = _executeSwap(DEPLOYED_ROUTER, position.order, tokenIn, tokenOut, a, takerData);
        (, uint256 outB) = _executeSwap(DEPLOYED_ROUTER, position.order, tokenIn, tokenOut, b, takerData);
        vm.revertToState(snapshot);
        uint256 split = outA + outB;

        // B from the state the single fill MODELS after A: the whole value of A gone from the
        // out leg, the third leg (read from Aqua, untouched by the revert) as it is.
        SwapQuery memory query = SwapQuery({
            orderHash: position.strategyHash,
            maker: alice,
            taker: address(this),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            isExactIn: true
        });
        SwapRegisters memory modelled = SwapRegisters({
            balanceIn: bIn + a,
            balanceOut: bOut - a * _unit(tokenIn) / _unit(tokenOut),
            amountIn: b,
            amountOut: 0,
            amountNetPulled: 0
        });
        (,, SwapRegisters memory priced) = freeboard.extruction(true, 0, query, modelled, position.extructionArgs, "");
        uint256 splitOnTheModelledPath = outA + priced.amountOut;

        uint256 spreadA = a * _unit(tokenIn) - outA * _unit(tokenOut);
        uint256[] memory w = this.weightsAt(Curves.freeboard(), _poolHealthFactor(alice));
        uint256 closedForm = (MIXED - TOWARD) * (ONE - w[_leg(tokenOut)]) / ONE * spreadA / ONE / _unit(tokenOut);

        console.log(string.concat(IERC20Metadata(tokenIn).symbol(), " -> ", IERC20Metadata(tokenOut).symbol()));
        console.log("  single fill of A + B        ", single);
        console.log("  A, then B on the live basket", split);
        console.log("  A, then B on the modelled   ", splitOnTheModelledPath);
        console.log("  gap (split - single)        ", split - single);
        console.log("  closed form                 ", closedForm);
        console.log("  bound                       ", _additivityBound(tokenIn, tokenOut, a));

        assertApproxEqAbs(splitOnTheModelledPath, single, 2, "the single fill is A then B along its own modelled path");
        assertGt(split, single, "the split pays the taker more: a crossing is in the second slice");
        assertLe(split - single, _additivityBound(tokenIn, tokenOut, a), "the gap is within the schedule bound");
        assertApproxEqAbs(split - single, closedForm, 2, "the gap is the dropped spread at the crossed rate step");
    }

    /// @notice The suite has teeth on this harness: a target that prices through the same
    ///         `FreeboardExtruction` and then shaves one wei off the SWAP path only is caught
    ///         by the suite's own quote/swap check, by its own message, on the deployed router.
    ///         Freeboard cannot do this — its `extruction` is `view` and never reads the flag —
    ///         which is why the six runs above pass.
    function test_Suite_CatchesAnExtructionThatBranchesOnTheStaticFlag() public {
        StaticFlagSkew skew = new StaticFlagSkew(freeboard);
        ProgramBuilder.Position memory skewed = ProgramBuilder.aquaPosition(
            alice,
            ProgramLib.extruction(
                address(skew),
                ProgramBuilder.freeboardPosition(
                    alice, address(freeboard), Curves.freeboard(), Curves.freeboardTokens(), MAX_SHIFT_BPS
                ).extructionArgs
            )
        );
        _ship(skewed, _shippedAmounts());

        uint256 amount = _tokens(WETH, FILL_M_USD);
        bytes memory takerData = _takerData(true);
        (, uint256 quotedOut,) = ISwapVM(ROUTER).quote(skewed.order, WETH, USDC, amount, takerData);

        vm.expectRevert(
            bytes(
                string.concat(
                    "Swap output does not match quote output: ",
                    vm.toString(quotedOut - 1),
                    " != ",
                    vm.toString(quotedOut)
                )
            )
        );
        this.quoteSwapConsistency(skewed.order, WETH, USDC, amount, takerData);
    }

    /// @dev External so the suite's assertion revert can be expected.
    function quoteSwapConsistency(
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    )
        external
    {
        assertQuoteSwapConsistencyInvariant(DEPLOYED_ROUTER, order, tokenIn, tokenOut, amount, takerData);
    }

    // -----------------------------------------------------------------------------------
    // The suite's one hook
    // -----------------------------------------------------------------------------------

    /// @dev `CoreInvariants._executeSwap` (`:57-64`): a real fill through the router handed in.
    ///      Returns what the taker actually paid and received, measured on the tokens, and
    ///      requires the router's return values and the maker's side to agree with it.
    ///      tokenIn goes taker -> router -> Aqua push to the maker (`SwapVM.sol:235-237`);
    ///      tokenOut maker -> taker via `AQUA.pull` (`:266`, `:286`).
    function _executeSwap(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    )
        internal
        override
        returns (uint256 amountIn, uint256 amountOut)
    {
        uint256 takerInBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 takerOutBefore = IERC20(tokenOut).balanceOf(address(this));
        uint256 makerInBefore = IERC20(tokenIn).balanceOf(order.maker);
        uint256 makerOutBefore = IERC20(tokenOut).balanceOf(order.maker);

        (uint256 routerIn, uint256 routerOut,) = swapVM.swap(order, tokenIn, tokenOut, amount, takerData);

        amountIn = takerInBefore - IERC20(tokenIn).balanceOf(address(this));
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - takerOutBefore;

        assertEq(amountIn, routerIn, "taker paid what the router reports");
        assertEq(amountOut, routerOut, "taker received what the router reports");
        assertEq(IERC20(tokenIn).balanceOf(order.maker) - makerInBefore, amountIn, "maker received tokenIn");
        assertEq(makerOutBefore - IERC20(tokenOut).balanceOf(order.maker), amountOut, "maker paid tokenOut");
    }

    // -----------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------

    function _assertAllInvariants(address tokenIn, address tokenOut) internal {
        InvariantConfig memory config = _getDefaultConfig();
        config.testAmounts = _fillSizes(tokenIn);
        config.testAmountsExactOut = _fillSizes(tokenOut);
        config.symmetryTolerance = _symmetryTolerance(tokenIn, tokenOut);
        config.monotonicityToleranceBps = 1;
        config.additivityTolerance = _additivityBound(tokenIn, tokenOut, config.testAmounts[2]);
        config.exactInTakerData = _takerData(true);
        config.exactOutTakerData = _takerData(false);

        console.log(
            string.concat(
                IERC20Metadata(tokenIn).symbol(), " -> ", IERC20Metadata(tokenOut).symbol(), ", Alice at HF "
            ),
            _poolHealthFactor(alice)
        );
        console.log("  exact-in amounts   ", _join(config.testAmounts));
        console.log("  exact-out amounts  ", _join(config.testAmountsExactOut));
        console.log("  symmetryTolerance  ", config.symmetryTolerance);
        console.log("  additivityTolerance", config.additivityTolerance);
        console.log("  monotonicityBps    ", config.monotonicityToleranceBps);
        console.log("  roundingBps        ", config.roundingToleranceBps);
        console.log("  skipped            ", _skipped(config));

        assertAllInvariantsWithConfig(DEPLOYED_ROUTER, position.order, tokenIn, tokenOut, config);
        _assertMonotoneToTheWei(tokenIn, tokenOut, config.testAmounts);
    }

    /// @dev What the suite's monotonicity check means at wei level: for each consecutive pair
    ///      of sizes, the larger fill's average price is no better than the smaller's, allowing
    ///      the one wei the smaller fill's output was floored to — `outL / L <= (outS + 1) / S`.
    function _assertMonotoneToTheWei(address tokenIn, address tokenOut, uint256[] memory amounts) internal {
        bytes memory takerData = _takerData(true);
        for (uint256 i = 1; i < amounts.length; ++i) {
            (, uint256 outS,) = ISwapVM(ROUTER).quote(position.order, tokenIn, tokenOut, amounts[i - 1], takerData);
            (, uint256 outL,) = ISwapVM(ROUTER).quote(position.order, tokenIn, tokenOut, amounts[i], takerData);
            assertLe(outL * amounts[i - 1], (outS + 1) * amounts[i], "the larger fill got a better price");
        }
        console.log("  monotone to the wei  yes");
    }

    /// @dev The additivity bound for a first slice of `amountIn`: the second slice's spread can
    ///      fall by at most `(SPREAD_AWAY - SPREAD_TOWARD) * S(A)`, and `S(A) <= SPREAD_AWAY * A`
    ///      — under 0.9 bps of the slice — in out-token wei, plus two wei of rounding.
    function _additivityBound(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        return (AWAY - TOWARD) * AWAY * amountIn * _unit(tokenIn) / ONE / ONE / _unit(tokenOut) + 2;
    }

    /// @dev The suite's 2-wei default, in units of one wei of the OUT token's value expressed
    ///      in wei of the IN token, rounded up: `2 * ceil(unitOut / unitIn)`.
    ///
    ///      Exact-in X gives Y = floor(g(X * unitIn) / unitOut), where g is the value the basket
    ///      pays out for value moved in (`FreeboardExtruction._outValue`). Exact-out Y costs
    ///      X' = ceil(x / unitIn) for the least x with g(x) >= Y * unitOut (`_inValue`). So
    ///      X' <= X, and since g(X * unitIn) - g(x) < unitOut while g rises at least 99 cents
    ///      on the dollar (the away spread is 100 bps), X - X' <= unitOut / (0.99 * unitIn) + 1.
    ///      Twice the ratio covers that, and when the out token's wei is worth less than the in
    ///      token's the tolerance is the suite's own 2.
    function _symmetryTolerance(address tokenIn, address tokenOut) internal view returns (uint256) {
        return 2 * Math.ceilDiv(_unit(tokenOut), _unit(tokenIn));
    }

    function _fillSizes(address token) internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](3);
        amounts[0] = _tokens(token, FILL_S_USD);
        amounts[1] = _tokens(token, FILL_M_USD);
        amounts[2] = _tokens(token, FILL_L_USD);
    }

    /// @dev `usd` dollars of `token` at the oracle, in its wei.
    function _tokens(address token, uint256 usd) internal view returns (uint256) {
        return usd * USD * 10 ** IERC20Metadata(token).decimals() / oracle.getAssetPrice(token);
    }

    /// @dev The extruction's value unit per wei (`FreeboardExtruction._unit`).
    function _unit(address token) internal view returns (uint256) {
        return oracle.getAssetPrice(token) * 10 ** (18 - IERC20Metadata(token).decimals());
    }

    function _aquaValue(address token) internal view returns (uint256) {
        (uint248 balance,) = IAqua(AQUA).rawBalances(alice, ROUTER, position.strategyHash, token);
        return uint256(balance) * _unit(token);
    }

    function _shippedAmounts() internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](3);
        amounts[0] = _tokens(WETH, BASKET_USD * SHIP_W_WETH / ONE);
        amounts[1] = _tokens(WBTC, BASKET_USD * SHIP_W_WBTC / ONE);
        amounts[2] = _tokens(USDC, BASKET_USD * SHIP_W_USDC / ONE);
    }

    /// @dev Built through the pinned library. No threshold: the suite asserts the amounts.
    function _takerData(bool isExactIn) internal view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.taker = address(this);
        args.isExactIn = isExactIn;
        args.useTransferFromAndAquaPush = true;
        return TakerTraitsLib.build(args);
    }

    /// @dev T14's fixture (`MultiToken.t.sol`), at HF 1.45: WETH collateral, USDC variable debt.
    function _openAavePosition(address maker, uint256 targetHf) internal {
        (address aWeth,,) =
            IAaveProtocolDataProvider(PROVIDER.getPoolDataProvider()).getReserveTokensAddresses(WETH);

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

    /// @dev Ships the three legs under `pos` and approves Aqua for exactly the shipped amounts
    ///      — the allowance, not the shipped balance, is what makes a position fillable.
    function _ship(ProgramBuilder.Position memory pos, uint256[] memory amounts) internal {
        address[] memory tokens = Curves.freeboardTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(tokens[i], alice, amounts[i]);
        }
        vm.startPrank(alice);
        bytes32 shippedHash = IAqua(AQUA).ship(ROUTER, pos.strategy, tokens, amounts);
        for (uint256 i = 0; i < tokens.length; ++i) {
            IERC20(tokens[i]).approve(AQUA, amounts[i]);
        }
        vm.stopPrank();
        assertEq(shippedHash, pos.strategyHash, "ship() did not return keccak256(strategy)");
    }

    function _poolHealthFactor(address who) internal view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = POOL.getUserAccountData(who);
    }

    /// @dev `Curve.weightsAt` reads calldata.
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }

    function _leg(address token) internal pure returns (uint256) {
        return token == WETH ? 0 : token == WBTC ? 1 : 2;
    }

    function _join(uint256[] memory xs) internal pure returns (string memory s) {
        for (uint256 i = 0; i < xs.length; ++i) {
            s = string.concat(s, i == 0 ? "" : " / ", vm.toString(xs[i]));
        }
    }

    function _skipped(InvariantConfig memory c) internal pure returns (string memory) {
        return (c.skipSymmetry || c.skipMonotonicity || c.skipAdditivity || c.skipSpotPrice) ? "SOME" : "none";
    }
}

/// @notice The negative control's target: prices through `FreeboardExtruction` with the router's
///         exact inputs, then pays one wei less on the swap path only. Test-only.
contract StaticFlagSkew {
    FreeboardExtruction internal immutable inner;

    constructor(FreeboardExtruction inner_) {
        inner = inner_;
    }

    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    )
        external
        view
        returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap)
    {
        (updatedNextPC, choppedLength, updatedSwap) =
            inner.extruction(isStaticContext, nextPC, query, swap, args, takerData);
        if (!isStaticContext) {
            updatedSwap.amountOut -= 1;
        }
    }
}
