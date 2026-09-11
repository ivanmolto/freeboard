// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { FreeboardExtruction } from "../../src/FreeboardExtruction.sol";
import { BasketDistance } from "../../src/libs/BasketDistance.sol";
import { Curve } from "../../src/libs/Curve.sol";
import { FreeboardArgs } from "../../src/libs/FreeboardArgs.sol";

import { Curves } from "../utils/Curves.sol";
import { MockAaveOracle, MockAaveV3Pool, MockAqua, MockPoolAddressesProvider, MockToken } from "../utils/Mocks.sol";

/// @dev Reads the schedule constants out of the contract; nothing else is exposed, so every
///      pricing assertion below goes through `extruction()` exactly as the router calls it.
contract ScheduleHarness is FreeboardExtruction {
    function spreadToward() external pure returns (uint256) {
        return SPREAD_TOWARD;
    }

    function spreadMixed() external pure returns (uint256) {
        return SPREAD_MIXED;
    }

    function spreadAway() external pure returns (uint256) {
        return SPREAD_AWAY;
    }

    function spreadSlope() external pure returns (uint256) {
        return SPREAD_SLOPE;
    }
}

/// @title PricingTest — T14
/// @notice `_healthWeightedTarget`, no fork: the extruction is deployed unmodified and the four
///         things it reads — the Aave pool, the provider's oracle, the tokens' decimals and
///         Aqua's `rawBalances` — are mocks etched AT the constant addresses it reads them from.
///
/// @dev THE PRICES ARE CHOSEN SO VALUES ARE EXACT. WETH 2,000, WBTC 50,000, USDC 1.00 (1e8
///      USD) give value units per wei of 2e11, 5e22 and 1e20: every unit divides 5e22, so a
///      trade size expressed as a multiple of 5e22 value units converts to a whole number of wei
///      of ANY token, and two trades of "the same size" in different tokens are the same value
///      to the unit. One value unit is 1e-26 USD.
///
/// @dev THE DoD.
///        test_TowardTarget_PricesBetterThan_AwayFromTarget — same size, three directions.
///        testFuzz_Pricing_IsMonotoneInDistanceReduction — the rule the README's price
///          monotonicity invariant becomes when "size" is replaced by "distance closed".
///      And the properties the router's own invariant suite (T28) will hold this to: exact-out
///      is the exact inverse of exact-in, larger fills never get better prices, and no fill is
///      ever better than the oracle.
contract PricingTest is Test {
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant WETH = Addresses.WETH;
    address internal constant WBTC = Addresses.WBTC;
    address internal constant USDC = Addresses.USDC;

    uint256 internal constant ONE = 1e18;

    /// @dev Oracle prices, 1e8 USD, and the value units per wei they produce.
    uint256 internal constant PRICE_WETH = 2000e8;
    uint256 internal constant PRICE_WBTC = 50_000e8;
    uint256 internal constant PRICE_USDC = 1e8;
    uint256 internal constant UNIT_WETH = 2e11;
    uint256 internal constant UNIT_WBTC = 5e22;
    uint256 internal constant UNIT_USDC = 1e20;

    /// @dev Value units per US dollar.
    uint256 internal constant USD = 1e26;

    /// @dev The schedule as the natspec states it: 10 / 55 / 100 bps.
    uint256 internal constant TOWARD = 0.001e18;
    uint256 internal constant MIXED = 0.0055e18;
    uint256 internal constant AWAY = 0.01e18;

    /// @dev The per-fill cap is OFF here: 20,000 bps is twice the basket, and no fill can move
    ///      more than the basket. These tests fuzz fills up to the whole out leg to pin the
    ///      PRICE; the cap that would refuse most of them is T15's subject, `PerFillCap.t.sol`.
    uint16 internal constant MAX_SHIFT_BPS = 20_000;

    FreeboardExtruction internal freeboard;
    bytes internal args;

    address internal maker = makeAddr("freeboard-maker");
    address internal taker = makeAddr("freeboard-taker");
    bytes32 internal orderHash = keccak256("freeboard-unit-strategy");

    /// @dev The basket, in token wei; what the registers and the Aqua mock report.
    mapping(address => uint256) internal balance;
    address[3] internal legs = [WETH, WBTC, USDC];

    // -----------------------------------------------------------------------------------
    // Fixture
    // -----------------------------------------------------------------------------------

    function setUp() public {
        vm.etch(Addresses.AAVE_V3_POOL, address(new MockAaveV3Pool()).code);
        vm.etch(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER, address(new MockPoolAddressesProvider()).code);
        vm.etch(Addresses.AAVE_V3_ORACLE, address(new MockAaveOracle()).code);
        vm.etch(AQUA, address(new MockAqua()).code);
        vm.etch(WETH, address(new MockToken(18)).code);
        vm.etch(WBTC, address(new MockToken(8)).code);
        vm.etch(USDC, address(new MockToken(6)).code);

        MockAaveOracle(Addresses.AAVE_V3_ORACLE).setPrice(WETH, PRICE_WETH);
        MockAaveOracle(Addresses.AAVE_V3_ORACLE).setPrice(WBTC, PRICE_WBTC);
        MockAaveOracle(Addresses.AAVE_V3_ORACLE).setPrice(USDC, PRICE_USDC);

        freeboard = new FreeboardExtruction();
        args = FreeboardArgs.encode(Curves.freeboard(), Curves.freeboardTokens(), MAX_SHIFT_BPS);

        vm.label(address(freeboard), "FreeboardExtruction");
        vm.label(WETH, "WETH");
        vm.label(WBTC, "WBTC");
        vm.label(USDC, "USDC");
    }

    function _setHealthFactor(uint256 hf) internal {
        MockAaveV3Pool(Addresses.AAVE_V3_POOL).setHealthFactor(maker, hf);
    }

    /// @dev Token wei per leg. Every leg is also written into the Aqua mock under the deployed
    ///      router as app, which is where the extruction reads the non-swapped legs.
    function _setBasket(uint256 weth, uint256 wbtc, uint256 usdc) internal {
        balance[WETH] = weth;
        balance[WBTC] = wbtc;
        balance[USDC] = usdc;
        for (uint256 l = 0; l < 3; ++l) {
            // forge-lint: disable-next-line(unsafe-typecast)
            MockAqua(AQUA).setRawBalance(maker, ROUTER, orderHash, legs[l], uint248(balance[legs[l]]), 3);
        }
    }

    /// @dev The value of `token`'s balance in a basket worth `usd` dollars total, held at
    ///      `share` (WAD). Converted to wei of the token at the mock price.
    function _wei(address token, uint256 usd, uint256 share) internal pure returns (uint256) {
        return (usd * USD * share / ONE) / _unit(token);
    }

    function _unit(address token) internal pure returns (uint256) {
        if (token == WETH) {
            return UNIT_WETH;
        }
        if (token == WBTC) {
            return UNIT_WBTC;
        }
        return UNIT_USDC;
    }

    /// @dev One call to `extruction()` with the registers the router would preload.
    function _fill(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool isExactIn
    )
        internal
        view
        returns (SwapRegisters memory out)
    {
        SwapQuery memory query = SwapQuery({
            orderHash: orderHash, maker: maker, taker: taker, tokenIn: tokenIn, tokenOut: tokenOut, isExactIn: isExactIn
        });
        SwapRegisters memory swap = SwapRegisters({
            balanceIn: balance[tokenIn],
            balanceOut: balance[tokenOut],
            amountIn: isExactIn ? amount : 0,
            amountOut: isExactIn ? 0 : amount,
            amountNetPulled: 0
        });
        (,, out) = freeboard.extruction(true, 0, query, swap, args, "");
    }

    function _exactIn(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        return _fill(tokenIn, tokenOut, amountIn, true).amountOut;
    }

    function _exactOut(address tokenIn, address tokenOut, uint256 amountOut) internal view returns (uint256) {
        return _fill(tokenIn, tokenOut, amountOut, false).amountIn;
    }

    /// @dev The six ordered pairs of the three legs.
    function _pair(uint8 seed) internal pure returns (address tokenIn, address tokenOut) {
        address[3] memory t = [WETH, WBTC, USDC];
        uint256 i = seed % 3;
        uint256 j = (i + 1 + (seed / 3) % 2) % 3;
        return (t[i], t[j]);
    }

    function _leg(address token) internal pure returns (uint256) {
        return token == WETH ? 0 : token == WBTC ? 1 : 2;
    }

    function _values() internal view returns (uint256[] memory v) {
        v = new uint256[](3);
        for (uint256 l = 0; l < 3; ++l) {
            v[l] = balance[legs[l]] * _unit(legs[l]);
        }
    }

    /// @dev How much distance a fill of `x` value units from `tokenIn` to `tokenOut` closes, as
    ///      the exact difference of the two distance numerators (they share the denominator).
    ///      Negative when the fill opens distance.
    function _closes(address tokenIn, address tokenOut, uint256 x, uint256 hf) internal view returns (int256) {
        uint256[] memory targets = this.weightsAt(Curves.freeboard(), hf);
        uint256[] memory before = _values();
        (uint256 scaledBefore,) = BasketDistance.scaledDistance(before, targets);
        before[_leg(tokenIn)] += x;
        before[_leg(tokenOut)] -= x;
        (uint256 scaledAfter,) = BasketDistance.scaledDistance(before, targets);
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(scaledBefore) - int256(scaledAfter);
    }

    /// @dev `Curve.weightsAt` reads calldata.
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }

    // -----------------------------------------------------------------------------------
    // 0. The units and the schedule are what the natspec says
    // -----------------------------------------------------------------------------------

    function test_ValueUnits_AreTheOraclePriceScaledToEighteenDecimals() public pure {
        assertEq(UNIT_WETH, PRICE_WETH * 10 ** (18 - 18), "WETH unit");
        assertEq(UNIT_WBTC, PRICE_WBTC * 10 ** (18 - 8), "WBTC unit");
        assertEq(UNIT_USDC, PRICE_USDC * 10 ** (18 - 6), "USDC unit");
        assertEq(UNIT_WBTC % UNIT_WETH, 0, "the WBTC unit must be a multiple of the WETH unit");
        assertEq(UNIT_WBTC % UNIT_USDC, 0, "the WBTC unit must be a multiple of the USDC unit");
        assertEq(USD, 1e8 * 1e18, "one dollar at the oracle's 1e8, scaled to 18 decimals");
    }

    /// @dev The no-underflow argument in `_spreadNumerator` needs `MIXED - 2 * SLOPE == TOWARD`
    ///      exactly, and the marginal rates to be the three named constants.
    function test_Schedule_IsExactInWad() public {
        ScheduleHarness h = new ScheduleHarness();
        assertEq(h.spreadToward(), TOWARD, "10 bps toward");
        assertEq(h.spreadMixed(), MIXED, "55 bps mixed");
        assertEq(h.spreadAway(), AWAY, "100 bps away");
        assertEq(h.spreadMixed() - 2 * h.spreadSlope(), h.spreadToward(), "mixed - 2 * slope must be toward, exactly");
        assertEq(h.spreadMixed() + 2 * h.spreadSlope(), h.spreadAway(), "mixed + 2 * slope must be away, exactly");
        assertLt(h.spreadAway(), ONE, "a spread of 100% or more would pay the taker nothing");
    }

    // -----------------------------------------------------------------------------------
    // 1. THE DoD — same size, toward vs away
    // -----------------------------------------------------------------------------------

    /// @notice The same $1,000 fill on the same basket at the same health factor, in three
    ///         directions. Toward target — the basket sheds the leg it has too much of and
    ///         takes the leg it has too little of — pays the maker 10 bps. Away — the reverse —
    ///         pays 100 bps. One leg toward and one at target pays 55 bps.
    /// @dev Basket at HF 2.00 (target 50 / 30 / 20): $60k WETH / $20k WBTC / $20k USDC, so
    ///      WETH is $10k over, WBTC $10k under, USDC on target. $1,000 crosses no target, so
    ///      each fill is a single piece and the price is a pinned literal.
    function test_TowardTarget_PricesBetterThan_AwayFromTarget() public {
        _setHealthFactor(2.0e18);
        _setBasket(_wei(WETH, 100_000, 0.6e18), _wei(WBTC, 100_000, 0.2e18), _wei(USDC, 100_000, 0.2e18));
        uint256 x = 1000 * USD;

        // Toward: the taker sells WBTC (the basket takes what it lacks) for WETH (it sheds
        // what it has too much of). 0.02 WBTC in, 0.4995 WETH out: $1,000 less 10 bps.
        uint256 outToward = _exactIn(WBTC, WETH, x / UNIT_WBTC);
        assertEq(outToward, 499_500_000_000_000_000, "toward: $999 of WETH");
        assertEq(outToward * UNIT_WETH, x - x * TOWARD / ONE, "toward: exactly the 10 bps schedule");

        // Away: the taker sells WETH for WBTC — the mirror image. 0.5 WETH in, 0.0198 WBTC out.
        uint256 outAway = _exactIn(WETH, WBTC, x / UNIT_WETH);
        assertEq(outAway, 1_980_000, "away: $990 of WBTC");
        assertEq(outAway * UNIT_WBTC, x - x * AWAY / ONE, "away: exactly the 100 bps schedule");

        // Mixed: WBTC in (toward) for USDC out (USDC is on target, so shedding it is away).
        uint256 outMixed = _exactIn(WBTC, USDC, x / UNIT_WBTC);
        assertEq(outMixed, 994_500_000, "mixed: $994.50 of USDC");
        assertEq(outMixed * UNIT_USDC, x - x * MIXED / ONE, "mixed: exactly the 55 bps schedule");

        assertGt(outToward * UNIT_WETH, outMixed * UNIT_USDC, "toward must beat mixed");
        assertGt(outMixed * UNIT_USDC, outAway * UNIT_WBTC, "mixed must beat away");

        // The same ordering exact-out: to receive 0.4 WETH ($800) the taker pays 10 bps more
        // in WBTC; to receive 0.02 WBTC ($1,000) they pay 100 bps more in WETH.
        uint256 inToward = _exactOut(WBTC, WETH, 0.4e18);
        uint256 inAway = _exactOut(WETH, WBTC, 0.02e8);
        assertEq(inToward, 1_601_602, "toward: 0.01601602 WBTC for $800 of WETH (800 / 0.999 / 50,000, ceiled)");
        assertEq(inAway, 505_050_505_050_505_051, "away: $1,010.10 of WETH for $1,000 of WBTC (1,000 / 0.99, ceiled)");
        assertLt(
            inToward * UNIT_WBTC * 1000 / 800, inAway * UNIT_WETH, "per dollar received, toward costs less than away"
        );

        emit log_named_decimal_uint("toward  ($1,000 WBTC -> WETH)  WETH out", outToward, 18);
        emit log_named_decimal_uint("mixed   ($1,000 WBTC -> USDC)  USDC out", outMixed, 6);
        emit log_named_decimal_uint("away    ($1,000 WETH -> WBTC)  WBTC out", outAway, 8);
    }

    /// @notice As the health factor falls, the fill that de-risks the basket becomes the
    ///         cheap one — with nothing about the basket changing.
    /// @dev A basket exactly on the HF 2.00 target. Selling USDC to it for WETH is away at HF
    ///      2.00 (both legs leave their targets) and toward at HF 1.60 and below (the target
    ///      has moved: WETH now has too much, USDC too little). The reverse fill is away at
    ///      every health factor.
    function test_AsHealthFactorFalls_TheDeleveragingFillBecomesTheCheapOne() public {
        _setBasket(_wei(WETH, 100_000, 0.5e18), _wei(WBTC, 100_000, 0.3e18), _wei(USDC, 100_000, 0.2e18));
        uint256 usdcIn = 1000 * USD / UNIT_USDC;
        uint256 wethIn = 1000 * USD / UNIT_WETH;

        _setHealthFactor(2.0e18);
        assertEq(
            _exactIn(USDC, WETH, usdcIn) * UNIT_WETH, 1000 * USD * (ONE - AWAY) / ONE, "HF 2.00: USDC -> WETH is away"
        );
        assertEq(
            _exactIn(WETH, USDC, wethIn) * UNIT_USDC, 1000 * USD * (ONE - AWAY) / ONE, "HF 2.00: WETH -> USDC is away"
        );

        _setHealthFactor(1.6e18);
        assertEq(
            _exactIn(USDC, WETH, usdcIn) * UNIT_WETH,
            1000 * USD * (ONE - TOWARD) / ONE,
            "HF 1.60: USDC -> WETH is toward"
        );
        assertEq(
            _exactIn(WETH, USDC, wethIn) * UNIT_USDC, 1000 * USD * (ONE - AWAY) / ONE, "HF 1.60: WETH -> USDC is away"
        );

        _setHealthFactor(1.3e18);
        assertEq(
            _exactIn(USDC, WETH, usdcIn) * UNIT_WETH,
            1000 * USD * (ONE - TOWARD) / ONE,
            "HF 1.30: USDC -> WETH is toward"
        );

        // Interpolated, HF 1.80: the target is 45 / 27 / 28, the basket 50 / 30 / 20 — toward.
        _setHealthFactor(1.8e18);
        assertEq(
            _exactIn(USDC, WETH, usdcIn) * UNIT_WETH,
            1000 * USD * (ONE - TOWARD) / ONE,
            "HF 1.80: USDC -> WETH is toward"
        );
    }

    /// @notice A fill that crosses a target is priced piece by piece: toward until the leg
    ///         reaches its target, then mixed, then away — and the whole is exactly the sum.
    /// @dev WETH $1,000 over target, USDC $500 under (HF 2.00, $100k basket). Selling $2,000 of
    ///      USDC for WETH: the first $500 has both legs toward (USDC reaches its target), the
    ///      next $500 is mixed (WETH still toward), the last $1,000 is away.
    function test_AFillAcrossATarget_IsPricedPieceByPiece() public {
        _setHealthFactor(2.0e18);
        _setBasket(_wei(WETH, 100_000, 0.51e18), _wei(WBTC, 100_000, 0.295e18), _wei(USDC, 100_000, 0.195e18));
        uint256 x = 2000 * USD;

        uint256 spread = 500 * USD * TOWARD / ONE + 500 * USD * MIXED / ONE + 1000 * USD * AWAY / ONE;
        uint256 out = _exactIn(USDC, WETH, x / UNIT_USDC);
        assertEq(out * UNIT_WETH, x - spread, "the three pieces, summed");

        // Exact-out lands on the same fill: asking for exactly that WETH costs exactly x.
        assertEq(_exactOut(USDC, WETH, out) * UNIT_USDC, x, "the inverse of the piecewise fill");
    }

    /// @notice The DoD fill once more, with the reference position's 500 bps cap LIVE in the
    ///         args: $1,000 on a $100k basket is 100 bps of it, well inside, and lands on the
    ///         same wei. The cap only ever reverts (T15); this pins that it changes nothing
    ///         else on the path every other test here takes with the cap off.
    function test_UnderALiveCap_TheSameFillPricesToTheSameWei() public {
        _setHealthFactor(2.0e18);
        _setBasket(_wei(WETH, 100_000, 0.6e18), _wei(WBTC, 100_000, 0.2e18), _wei(USDC, 100_000, 0.2e18));
        uint256 amountIn = 1000 * USD / UNIT_WBTC;
        uint256 capOff = _exactIn(WBTC, WETH, amountIn);

        bytes memory off = args;
        args = FreeboardArgs.encode(Curves.freeboard(), Curves.freeboardTokens(), 500);
        uint256 capOn = _exactIn(WBTC, WETH, amountIn);
        args = off;

        assertEq(capOn, capOff, "a live 500 bps cap must not move the price of a fill inside it");
        assertEq(capOn, 499_500_000_000_000_000, "the DoD literal, with the cap on");
    }

    // -----------------------------------------------------------------------------------
    // 2. THE DoD — monotone in distance reduction
    // -----------------------------------------------------------------------------------

    /// @notice Two fills of the same size on the same basket at the same health factor: the
    ///         one that closes more distance never prices worse. Any basket, any HF on or off
    ///         the curve's breakpoints, any two of the six directions, any size up to the
    ///         smaller out leg.
    /// @dev "Prices worse" is in value: the spread the maker keeps, `x - outValue`. A wei of
    ///      the out token is the flooring tolerance — the compared fills may pay out different
    ///      tokens, so the tolerance is the coarser of the two.
    function testFuzz_Pricing_IsMonotoneInDistanceReduction(
        uint64 weth,
        uint48 wbtc,
        uint64 usdc,
        uint256 hfSeed,
        uint8 pairA,
        uint8 pairB,
        uint32 sizeSeed
    )
        public
    {
        _setBasket(weth, wbtc, usdc);
        uint256 hf = 1e18 + hfSeed % 1.5e18;
        _setHealthFactor(hf);
        (address inA, address outA) = _pair(pairA);
        (address inB, address outB) = _pair(pairB);

        uint256 room = _min(balance[outA] * _unit(outA), balance[outB] * _unit(outB));
        vm.assume(room >= UNIT_WBTC);
        uint256 x = (1 + sizeSeed % (room / UNIT_WBTC)) * UNIT_WBTC;

        uint256 spreadA = x - _exactIn(inA, outA, x / _unit(inA)) * _unit(outA);
        uint256 spreadB = x - _exactIn(inB, outB, x / _unit(inB)) * _unit(outB);
        int256 closesA = _closes(inA, outA, x, hf);
        int256 closesB = _closes(inB, outB, x, hf);

        if (closesA >= closesB) {
            assertLe(spreadA, spreadB + _unit(outA), "the fill closing more distance was charged more");
        } else {
            assertLe(spreadB, spreadA + _unit(outB), "the fill closing more distance was charged more");
        }
    }

    // -----------------------------------------------------------------------------------
    // 3. The properties the invariant suite will hold this to
    // -----------------------------------------------------------------------------------

    /// @notice No fill is ever better than the oracle, and none is ever worse than the away
    ///         spread: the maker keeps between 10 and 100 bps of every fill's value.
    function testFuzz_Pricing_NeverBeatsTheOracle_AndNeverExceedsTheAwaySpread(
        uint64 weth,
        uint48 wbtc,
        uint64 usdc,
        uint256 hfSeed,
        uint8 pair,
        uint32 sizeSeed
    )
        public
    {
        _setBasket(weth, wbtc, usdc);
        _setHealthFactor(1e18 + hfSeed % 1.5e18);
        (address tokenIn, address tokenOut) = _pair(pair);

        uint256 room = balance[tokenOut] * _unit(tokenOut);
        vm.assume(room >= UNIT_WBTC);
        uint256 x = (1 + sizeSeed % (room / UNIT_WBTC)) * UNIT_WBTC;

        uint256 spread = x - _exactIn(tokenIn, tokenOut, x / _unit(tokenIn)) * _unit(tokenOut);
        assertGe(spread, x * TOWARD / ONE, "the fill beat the toward spread: better than the oracle");
        assertLe(spread, x * AWAY / ONE + _unit(tokenOut), "the fill was charged more than the away spread");
    }

    /// @notice Exact-out is the exact inverse of exact-in, to the wei of the in token: the
    ///         input it quotes delivers at least the requested output, and one wei less does not.
    function testFuzz_ExactOut_IsTheExactInverseOfExactIn(
        uint64 weth,
        uint48 wbtc,
        uint64 usdc,
        uint256 hfSeed,
        uint8 pair,
        uint64 outSeed
    )
        public
    {
        _setBasket(weth, wbtc, usdc);
        _setHealthFactor(1e18 + hfSeed % 1.5e18);
        (address tokenIn, address tokenOut) = _pair(pair);

        // At most half the leg, so the spread cannot push the fill past what the leg holds,
        // and a leg worth at least a few wei of the in token, so a whole wei of input fits.
        vm.assume(balance[tokenOut] >= 2);
        vm.assume(balance[tokenOut] * _unit(tokenOut) >= 4 * _unit(tokenIn));
        uint256 amountOut = 1 + outSeed % (balance[tokenOut] / 2);

        uint256 amountIn = _exactOut(tokenIn, tokenOut, amountOut);
        assertGe(_exactIn(tokenIn, tokenOut, amountIn), amountOut, "the quoted input does not deliver the output");
        if (amountIn > 1) {
            assertLt(_exactIn(tokenIn, tokenOut, amountIn - 1), amountOut, "one wei less still delivers: not minimal");
        }
    }

    /// @notice A larger fill never gets a better average price (README invariant 4).
    function testFuzz_Pricing_IsMonotoneInSize(
        uint64 weth,
        uint48 wbtc,
        uint64 usdc,
        uint256 hfSeed,
        uint8 pair,
        uint64 sizeA,
        uint64 sizeB
    )
        public
    {
        _setBasket(weth, wbtc, usdc);
        _setHealthFactor(1e18 + hfSeed % 1.5e18);
        (address tokenIn, address tokenOut) = _pair(pair);

        uint256 roomIn = balance[tokenOut] * _unit(tokenOut) / _unit(tokenIn);
        vm.assume(roomIn >= 2);
        uint256 a = 1 + sizeA % roomIn;
        uint256 b = 1 + sizeB % roomIn;
        vm.assume(a != b);
        (uint256 small, uint256 large) = a < b ? (a, b) : (b, a);

        uint256 outSmall = _exactIn(tokenIn, tokenOut, small);
        uint256 outLarge = _exactIn(tokenIn, tokenOut, large);
        // outLarge / large <= outSmall / small, with a wei of flooring on the small side.
        assertLe(outLarge * small, (outSmall + 1) * large, "the larger fill got a better price");
    }

    /// @notice A fill split in two never pays the taker less than the same fill in one piece,
    ///         and never more than `SPREAD_AWAY - SPREAD_TOWARD` of the spread the first slice
    ///         paid — under 0.9 bps of the first slice's value. Any basket, any health factor,
    ///         any pair, any two slices that fit the out leg.
    /// @dev THE SINGLE FILL IS THE ONE THAT OVERCHARGES. `_spreadNumerator` prices a move as if
    ///      the whole value in left the out leg (`after_[legOut] -= x`), but the maker keeps the
    ///      spread: after the first slice the out leg really holds `S(A)` more, and the basket
    ///      is `S(A)` larger, than the single fill's model of that point. The second slice is
    ///      priced from the live basket, so it reaches each target crossing up to `S(A)` of
    ///      value later — every crossing along a move raises the marginal spread, so later is
    ///      cheaper for the taker. Where no leg crosses a target during the second slice the
    ///      two agree to rounding; the gap exists only across a crossing. Bound: each moving
    ///      leg's distance term shifts by at most `S(A)`, at `2 * SPREAD_SLOPE` per unit, so
    ///      the second slice's spread falls by at most `4 * SPREAD_SLOPE * S(A)`, which is
    ///      `(SPREAD_AWAY - SPREAD_TOWARD) * S(A)`, and `S(A) <= SPREAD_AWAY * A`. Rounding is
    ///      two wei: the split floors twice and ceils its spread twice. T28 measures the gap on
    ///      the deployed router (`test_Additivity_TheGapIsTheSpreadTheSingleFillsModelDropped`).
    function testFuzz_ASplitFill_PaysAtLeastTheSingleFill_AndAtMostTheBoundMore(
        uint64 weth,
        uint48 wbtc,
        uint64 usdc,
        uint256 hfSeed,
        uint8 pair,
        uint64 sizeA,
        uint64 sizeB
    )
        public
    {
        _setBasket(weth, wbtc, usdc);
        _setHealthFactor(1e18 + hfSeed % 1.5e18);
        (address tokenIn, address tokenOut) = _pair(pair);

        uint256 roomIn = balance[tokenOut] * _unit(tokenOut) / _unit(tokenIn);
        vm.assume(roomIn >= 2);
        uint256 a = 1 + sizeA % (roomIn / 2);
        uint256 b = 1 + sizeB % (roomIn - a);

        uint256 single = _exactIn(tokenIn, tokenOut, a + b);

        uint256 outA = _exactIn(tokenIn, tokenOut, a);
        balance[tokenIn] += a;
        balance[tokenOut] -= outA;
        uint256 split = outA + _exactIn(tokenIn, tokenOut, b);

        uint256 spreadA = a * _unit(tokenIn) - outA * _unit(tokenOut);
        uint256 bound = (AWAY - TOWARD) * spreadA / ONE / _unit(tokenOut);

        assertGe(split + 2, single, "the split paid the taker less than one fill");
        assertLe(split, single + bound + 2, "the split paid the taker more than the bound");
        // 0.9 bps = 9 / 100,000.
        assertLe(bound, 9 * a * _unit(tokenIn) / 100_000 / _unit(tokenOut) + 1, "the bound is under 0.9 bps of the first slice");
    }

    // -----------------------------------------------------------------------------------
    // 4. The non-swapped leg comes from Aqua, and it matters
    // -----------------------------------------------------------------------------------

    /// @notice The leg that is neither `tokenIn` nor `tokenOut` is read from Aqua's
    ///         `rawBalances` under the deployed router as app, and it changes the price: the
    ///         same WETH -> USDC fill is away against a small WBTC leg and mixed against a large
    ///         one, because the large leg pushes WETH under its target.
    function test_NonSwappedLeg_IsReadFromAquaRawBalances_AndMovesThePrice() public {
        _setHealthFactor(2.0e18);
        uint256 x = 1000 * USD;

        // $60k / $20k / $20k: WETH over, USDC on target -> selling WETH for USDC is away.
        _setBasket(_wei(WETH, 100_000, 0.6e18), _wei(WBTC, 100_000, 0.2e18), _wei(USDC, 100_000, 0.2e18));
        vm.expectCall(AQUA, abi.encodeCall(IAqua.rawBalances, (maker, ROUTER, orderHash, WBTC)));
        uint256 outSmallBtc = _exactIn(WETH, USDC, x / UNIT_WETH);
        assertEq(outSmallBtc * UNIT_USDC, x - x * AWAY / ONE, "against a $20k WBTC leg: away");

        // The same WETH and USDC, but $200k of WBTC in Aqua: WETH is now 21% of a $280k
        // basket, under its 50% target, so taking WETH is toward; USDC at 7% is under 20%, so
        // shedding it is away. Mixed.
        _setBasket(balance[WETH], _wei(WBTC, 100_000, 2e18), balance[USDC]);
        vm.expectCall(AQUA, abi.encodeCall(IAqua.rawBalances, (maker, ROUTER, orderHash, WBTC)));
        uint256 outLargeBtc = _exactIn(WETH, USDC, x / UNIT_WETH);
        assertEq(outLargeBtc * UNIT_USDC, x - x * MIXED / ONE, "against a $200k WBTC leg: mixed");

        assertGt(outLargeBtc, outSmallBtc, "the Aqua leg must have moved the price");
    }

    /// @notice A committed leg Aqua does not hold under this strategy is a revert, not a zero:
    ///         never shipped (`tokensCount == 0`) and docked (`0xff`) alike. A shipped set of
    ///         the wrong size is refused too.
    function test_RevertWhen_ACommittedLegIsNotInTheStrategy() public {
        _setHealthFactor(2.0e18);
        _setBasket(_wei(WETH, 100_000, 0.6e18), _wei(WBTC, 100_000, 0.2e18), _wei(USDC, 100_000, 0.2e18));
        uint256 amountIn = 1000 * USD / UNIT_WETH;

        MockAqua(AQUA).setRawBalance(maker, ROUTER, orderHash, WBTC, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(FreeboardExtruction.FreeboardLegNotInStrategy.selector, maker, orderHash, WBTC)
        );
        this.fillExternal(WETH, USDC, amountIn, true);

        MockAqua(AQUA).setRawBalance(maker, ROUTER, orderHash, WBTC, 0, 0xff);
        vm.expectRevert(
            abi.encodeWithSelector(FreeboardExtruction.FreeboardLegNotInStrategy.selector, maker, orderHash, WBTC)
        );
        this.fillExternal(WETH, USDC, amountIn, true);

        MockAqua(AQUA).setRawBalance(maker, ROUTER, orderHash, WBTC, 1e8, 2);
        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardStrategyLegCountMismatch.selector, 3, 2));
        this.fillExternal(WETH, USDC, amountIn, true);

        // A leg the maker sold out entirely is a zero with a live count, and prices.
        MockAqua(AQUA).setRawBalance(maker, ROUTER, orderHash, WBTC, 0, 3);
        assertGt(this.fillExternal(WETH, USDC, amountIn, true), 0, "an empty leg is a value, not a refusal");
    }

    // -----------------------------------------------------------------------------------
    // 5. Refusals, by name
    // -----------------------------------------------------------------------------------

    function test_RevertWhen_ASwappedTokenIsNotABasketLeg() public {
        _setHealthFactor(2.0e18);
        _setBasket(_wei(WETH, 100_000, 0.5e18), _wei(WBTC, 100_000, 0.3e18), _wei(USDC, 100_000, 0.2e18));

        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardTokenNotInBasket.selector, Addresses.DAI));
        this.fillExternal(Addresses.DAI, USDC, 1e18, true);

        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardTokenNotInBasket.selector, Addresses.DAI));
        this.fillExternal(WETH, Addresses.DAI, 1e18, true);

        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardSameTokenBothSides.selector, WETH));
        this.fillExternal(WETH, WETH, 1e18, true);
    }

    /// @dev Exact-in for more value than the out leg holds; exact-out for the whole leg, which
    ///      the spread makes undeliverable; exact-out for more than the leg.
    function test_RevertWhen_TheFillExceedsTheOutLeg() public {
        _setHealthFactor(2.0e18);
        _setBasket(_wei(WETH, 100_000, 0.5e18), _wei(WBTC, 100_000, 0.3e18), _wei(USDC, 100_000, 0.2e18));
        uint256 usdcHeld = balance[USDC] * UNIT_USDC;

        uint256 tooMuch = usdcHeld / UNIT_WETH + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                FreeboardExtruction.FreeboardFillExceedsLeg.selector, USDC, tooMuch * UNIT_WETH, usdcHeld
            )
        );
        this.fillExternal(WETH, USDC, tooMuch, true);

        vm.expectRevert(
            abi.encodeWithSelector(FreeboardExtruction.FreeboardFillExceedsLeg.selector, USDC, usdcHeld, usdcHeld)
        );
        this.fillExternal(WETH, USDC, balance[USDC], false);

        vm.expectRevert(
            abi.encodeWithSelector(
                FreeboardExtruction.FreeboardFillExceedsLeg.selector, USDC, usdcHeld + UNIT_USDC, usdcHeld
            )
        );
        this.fillExternal(WETH, USDC, balance[USDC] + 1, false);

        // The whole leg less the away spread is deliverable, exact-out.
        uint256 deliverable = balance[USDC] * (ONE - AWAY) / ONE;
        assertGt(this.fillExternal(WETH, USDC, deliverable, false), 0, "just inside the leg must price");
    }

    function test_RevertWhen_AnAssetPriceIsZero() public {
        _setHealthFactor(2.0e18);
        _setBasket(_wei(WETH, 100_000, 0.5e18), _wei(WBTC, 100_000, 0.3e18), _wei(USDC, 100_000, 0.2e18));
        MockAaveOracle(Addresses.AAVE_V3_ORACLE).setPrice(WBTC, 0);

        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardAssetPriceUnreadable.selector, WBTC));
        this.fillExternal(WETH, USDC, 1e18, true);
    }

    function test_RevertWhen_TheArgsAreNotExactlyTheLayout() public {
        _setHealthFactor(2.0e18);
        _setBasket(_wei(WETH, 100_000, 0.5e18), _wei(WBTC, 100_000, 0.3e18), _wei(USDC, 100_000, 0.2e18));

        bytes memory good = args;
        args = bytes.concat(good, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(
                FreeboardExtruction.FreeboardArgsLengthMismatch.selector, good.length + 1, good.length
            )
        );
        this.fillExternal(WETH, USDC, 1e18, true);
        args = good;
    }

    // -----------------------------------------------------------------------------------
    // 6. The registers
    // -----------------------------------------------------------------------------------

    /// @notice Every register the extruction does not price is copied forward, `nextPC` is
    ///         returned unchanged and no taker data is consumed — whatever the taker data.
    function test_Registers_AreCopiedForward_AndNothingElseChanges() public {
        _setHealthFactor(2.0e18);
        _setBasket(_wei(WETH, 100_000, 0.5e18), _wei(WBTC, 100_000, 0.3e18), _wei(USDC, 100_000, 0.2e18));

        SwapQuery memory query = SwapQuery({
            orderHash: orderHash, maker: maker, taker: taker, tokenIn: WETH, tokenOut: USDC, isExactIn: true
        });
        SwapRegisters memory entry = SwapRegisters({
            balanceIn: balance[WETH], balanceOut: balance[USDC], amountIn: 1e18, amountOut: 0, amountNetPulled: 7
        });

        (uint256 nextPC, uint256 chopped, SwapRegisters memory out) =
            freeboard.extruction(false, 0xfeed, query, entry, args, hex"c0ffee");
        assertEq(nextPC, 0xfeed, "nextPC must be returned unchanged");
        assertEq(chopped, 0, "no taker data consumed");
        assertEq(out.balanceIn, entry.balanceIn, "balanceIn copied");
        assertEq(out.balanceOut, entry.balanceOut, "balanceOut copied");
        assertEq(out.amountIn, entry.amountIn, "amountIn copied on exact-in");
        assertEq(out.amountNetPulled, 7, "amountNetPulled copied");
        assertGt(out.amountOut, 0, "amountOut priced");

        (,, SwapRegisters memory viaStatic) = freeboard.extruction(true, 0xfeed, query, entry, args, "");
        assertEq(
            keccak256(abi.encode(viaStatic)),
            keccak256(abi.encode(out)),
            "the static flag and taker data must not matter"
        );
    }

    // -----------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------

    /// @dev An external hop so `vm.expectRevert` has a call frame to catch.
    function fillExternal(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool isExactIn
    )
        external
        view
        returns (uint256)
    {
        SwapRegisters memory out = _fill(tokenIn, tokenOut, amount, isExactIn);
        return isExactIn ? out.amountOut : out.amountIn;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
