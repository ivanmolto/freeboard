// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { FreeboardExtruction } from "../../src/FreeboardExtruction.sol";
import { BasketDistance } from "../../src/libs/BasketDistance.sol";
import { Curve } from "../../src/libs/Curve.sol";
import { FreeboardArgs } from "../../src/libs/FreeboardArgs.sol";

import { Curves } from "../utils/Curves.sol";
import { MockAaveOracle, MockAaveV3Pool, MockAqua, MockPoolAddressesProvider, MockToken } from "../utils/Mocks.sol";

/// @title PerFillCapTest — T15
/// @notice No single fill may move more than `maxShiftBps` of the basket's value. The property
///         that bounds every failure mode the extruction cannot exclude — a wrong health factor
///         above all — and the on-chain answer to "the curve is public": the rebalance cannot
///         be drained in one fill.
///
/// @dev THE SAME FIXTURE AS `Pricing.t.sol`: the extruction deployed unmodified, the four things
///      it reads etched at the constant addresses it reads them from, prices WETH 2,000 /
///      WBTC 50,000 / USDC 1.00 so every trade size is a whole number of wei of any token.
///
/// @dev WHAT "MOVE THE BASKET" MEANS. The larger of the value that comes in and the value that
///      goes out, as the fill will SETTLE, over the basket's value before it, in basis points,
///      rounded up. The reference below computes it from the test's own book of balances and
///      the amounts the extruction returned; a refusal must name that same number.
///
/// @dev WHY VALUE AND NOT DISTANCE. The first cut of this cap bounded the change in
///      `BasketDistance` a fill causes, and a reviewer showed it blind: a fill with one leg
///      moving toward its target and the other away leaves the L1 distance unchanged however
///      much value it moves, so under a 500 bps cap a taker could take two thirds of a leg in
///      one fill — on the very fixture the wrong-HF test below uses, in the direction that test
///      did not try. Value moved has no blind direction, and it bounds the distance change from
///      above (`test_AMixedFill_MovesNoDistance_AndIsCappedAllTheSame`, the corollary in the
///      fuzz).
///
/// @dev THE DoD.
///        test_RevertWhen_SingleFillExceedsMaxShiftPct — the boundary to the wei, in every
///          direction and on both sides (exact-in, exact-out); the cap is the args' number.
///        testFuzz_EveryFillInAnySequence_IsWithinTheCap — any basket, any HF, any cap, any
///          sequence of fills applied one after another with the health factor fixed, as
///          within one block: every fill that settles moved at most the cap, every refusal was
///          of a fill that would have moved more, and the cap changed no price. Per fill: the
///          sequence itself is not bounded, and the docstring says why.
contract PerFillCapTest is Test {
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant WETH = Addresses.WETH;
    address internal constant WBTC = Addresses.WBTC;
    address internal constant USDC = Addresses.USDC;

    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;

    uint256 internal constant PRICE_WETH = 2000e8;
    uint256 internal constant PRICE_WBTC = 50_000e8;
    uint256 internal constant PRICE_USDC = 1e8;
    uint256 internal constant UNIT_WETH = 2e11;
    uint256 internal constant UNIT_WBTC = 5e22;
    uint256 internal constant UNIT_USDC = 1e20;

    /// @dev Value units per US dollar.
    uint256 internal constant USD = 1e26;

    /// @dev The cap the DoD tests ship: 500 bps, five percent of the basket per fill.
    uint16 internal constant CAP = 500;

    /// @dev Twice the basket: no fill can move it, so this is no cap.
    uint16 internal constant NO_CAP = 20_000;

    /// @dev Fills per fuzzed sequence.
    uint256 internal constant STEPS = 8;

    FreeboardExtruction internal freeboard;

    address internal maker = makeAddr("freeboard-maker");
    address internal taker = makeAddr("freeboard-taker");
    bytes32 internal orderHash = keccak256("freeboard-unit-strategy");

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

        vm.label(address(freeboard), "FreeboardExtruction");
        vm.label(WETH, "WETH");
        vm.label(WBTC, "WBTC");
        vm.label(USDC, "USDC");
    }

    /// @dev The Freeboard args with the given cap — the only byte that differs between two
    ///      programs in these tests is the cap.
    function _args(uint16 capBps) internal pure returns (bytes memory) {
        return FreeboardArgs.encode(Curves.freeboard(), Curves.freeboardTokens(), capBps);
    }

    function _setHealthFactor(uint256 hf) internal {
        MockAaveV3Pool(Addresses.AAVE_V3_POOL).setHealthFactor(maker, hf);
    }

    function _setBasket(uint256 weth, uint256 wbtc, uint256 usdc) internal {
        balance[WETH] = weth;
        balance[WBTC] = wbtc;
        balance[USDC] = usdc;
        for (uint256 l = 0; l < 3; ++l) {
            // forge-lint: disable-next-line(unsafe-typecast)
            MockAqua(AQUA).setRawBalance(maker, ROUTER, orderHash, legs[l], uint248(balance[legs[l]]), 3);
        }
    }

    /// @dev Settle a fill in the test's book: what Aqua would hold after it.
    function _settle(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) internal {
        _setBasket(
            balance[WETH] + (tokenIn == WETH ? amountIn : 0) - (tokenOut == WETH ? amountOut : 0),
            balance[WBTC] + (tokenIn == WBTC ? amountIn : 0) - (tokenOut == WBTC ? amountOut : 0),
            balance[USDC] + (tokenIn == USDC ? amountIn : 0) - (tokenOut == USDC ? amountOut : 0)
        );
    }

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

    function _leg(address token) internal pure returns (uint256) {
        return token == WETH ? 0 : token == WBTC ? 1 : 2;
    }

    /// @dev The six ordered pairs of the three legs.
    function _pair(uint8 seed) internal pure returns (address tokenIn, address tokenOut) {
        address[3] memory t = [WETH, WBTC, USDC];
        uint256 i = seed % 3;
        uint256 j = (i + 1 + (seed / 3) % 2) % 3;
        return (t[i], t[j]);
    }

    function _values() internal view returns (uint256[] memory v) {
        v = new uint256[](3);
        for (uint256 l = 0; l < 3; ++l) {
            v[l] = balance[legs[l]] * _unit(legs[l]);
        }
    }

    function _total() internal view returns (uint256) {
        uint256[] memory v = _values();
        return v[0] + v[1] + v[2];
    }

    /// @dev `Curve.weightsAt` reads calldata.
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }

    /// @dev THE REFERENCE: the basis points of the basket's value that settling `amountIn` in
    ///      and `amountOut` out moves — the larger side over the basket as it stands, rounded
    ///      up. From the test's own book, not from anything the extruction computed.
    function _moved(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    )
        internal
        view
        returns (uint256)
    {
        uint256 valueIn = amountIn * _unit(tokenIn);
        uint256 valueOut = amountOut * _unit(tokenOut);
        return Math.ceilDiv((valueIn > valueOut ? valueIn : valueOut) * BPS, _total());
    }

    /// @dev The change in WAD distance from target that a value-preserving move of `x` — out
    ///      of `tokenOut`'s leg and into `tokenIn`'s — makes at the targets for `hf`; the move
    ///      the pricing rule walks. Exact: the two numerators share the denominator.
    function _distanceMove(address tokenIn, address tokenOut, uint256 x, uint256 hf) internal view returns (uint256) {
        uint256[] memory targets = this.weightsAt(Curves.freeboard(), hf);
        uint256[] memory values = _values();
        (uint256 before,) = BasketDistance.scaledDistance(values, targets);
        values[_leg(tokenIn)] += x;
        values[_leg(tokenOut)] -= x;
        (uint256 after_, uint256 total) = BasketDistance.scaledDistance(values, targets);
        return (after_ > before ? after_ - before : before - after_) / total;
    }

    /// @dev One call to `extruction()` with the registers the router would preload, under
    ///      `args`. An external hop so `vm.expectRevert` and `try` have a frame to catch.
    function fill(
        bytes memory args,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool isExactIn
    )
        external
        view
        returns (uint256 amountIn, uint256 amountOut)
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
        (,, SwapRegisters memory out) = freeboard.extruction(true, 0, query, swap, args, "");
        return (out.amountIn, out.amountOut);
    }

    /// @dev The revert data of `FreeboardFillExceedsMaxShift`, or `matched == false`.
    function _decodeExceedsMaxShift(bytes memory reason)
        internal
        pure
        returns (bool matched, uint256 shift, uint256 maxShift)
    {
        if (reason.length != 4 + 64) {
            return (false, 0, 0);
        }
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 32))
            shift := mload(add(reason, 36))
            maxShift := mload(add(reason, 68))
        }
        matched = selector == FreeboardExtruction.FreeboardFillExceedsMaxShift.selector;
    }

    function _expectExceedsMaxShift(uint256 shift, uint256 cap) internal {
        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardFillExceedsMaxShift.selector, shift, cap));
    }

    /// @dev Under the uncapped twin, what the fill would settle at; and the reference's bps.
    function _wouldMove(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool isExactIn
    )
        internal
        view
        returns (uint256 moved)
    {
        (uint256 amountIn, uint256 amountOut) = this.fill(_args(NO_CAP), tokenIn, tokenOut, amount, isExactIn);
        return _moved(tokenIn, tokenOut, amountIn, amountOut);
    }

    // -----------------------------------------------------------------------------------
    // 1. THE DoD — one fill, the cap, by name, to the wei
    // -----------------------------------------------------------------------------------

    /// @notice $100k basket at HF 2.00, $60k WETH / $20k WBTC / $20k USDC. Cap 500 bps: $5,000
    ///         per fill. Exactly $5,000 in prices; one wei of WBTC more is 501 bps and refused
    ///         with that number. Every one of the six directions, both sides. Re-encode the
    ///         args with a 600 bps cap and the refused fill prices, at the same price — the cap
    ///         is the args' number and only ever reverts. At 20,000 bps the whole leg goes.
    function test_RevertWhen_SingleFillExceedsMaxShiftPct() public {
        _setHealthFactor(2.0e18);
        _setBasket(_wei(WETH, 100_000, 0.6e18), _wei(WBTC, 100_000, 0.2e18), _wei(USDC, 100_000, 0.2e18));
        bytes memory capped = _args(CAP);

        // -- The boundary, exact-in: $5,000 of WBTC is 500 bps and prices; one wei more is
        //    501 and is refused. --------------------------------------------------------
        uint256 atCap = 5000 * USD / UNIT_WBTC;
        (, uint256 outAtCap) = this.fill(capped, WBTC, WETH, atCap, true);
        assertGt(outAtCap, 0, "exactly the cap must price");
        assertEq(_moved(WBTC, WETH, atCap, outAtCap), CAP, "exactly the cap, by the reference");

        assertEq(_wouldMove(WBTC, WETH, atCap + 1, true), CAP + 1, "one wei of WBTC more is 501 bps");
        _expectExceedsMaxShift(CAP + 1, CAP);
        this.fill(capped, WBTC, WETH, atCap + 1, true);

        // -- Every direction, both sides: $4,900 prices, $5,100 is refused. -----------------
        for (uint8 p = 0; p < 6; ++p) {
            (address tokenIn, address tokenOut) = _pair(p);
            (uint256 okIn, uint256 okOut) = this.fill(capped, tokenIn, tokenOut, 4900 * USD / _unit(tokenIn), true);
            assertLe(_moved(tokenIn, tokenOut, okIn, okOut), CAP, "exact-in $4,900 must be within the cap");

            uint256 tooMuchIn = 5100 * USD / _unit(tokenIn);
            uint256 moved = _wouldMove(tokenIn, tokenOut, tooMuchIn, true);
            assertGt(moved, CAP, "fixture: exact-in $5,100 must exceed the cap");
            _expectExceedsMaxShift(moved, CAP);
            this.fill(capped, tokenIn, tokenOut, tooMuchIn, true);

            (okIn, okOut) = this.fill(capped, tokenIn, tokenOut, 4900 * USD / _unit(tokenOut), false);
            assertLe(_moved(tokenIn, tokenOut, okIn, okOut), CAP, "exact-out $4,900 must be within the cap");

            uint256 tooMuchOut = 5100 * USD / _unit(tokenOut);
            moved = _wouldMove(tokenIn, tokenOut, tooMuchOut, false);
            assertGt(moved, CAP, "fixture: exact-out $5,100 must exceed the cap");
            _expectExceedsMaxShift(moved, CAP);
            this.fill(capped, tokenIn, tokenOut, tooMuchOut, false);
        }

        // -- The cap is the number in the args and nothing else: 600 bps lets $5,100 through,
        //    at the price the uncapped twin gives — the cap only ever reverts. -------------
        uint256 refused = 5100 * USD / UNIT_WBTC;
        (, uint256 outAt600) = this.fill(_args(600), WBTC, WETH, refused, true);
        (, uint256 outUncapped) = this.fill(_args(NO_CAP), WBTC, WETH, refused, true);
        assertEq(outAt600, outUncapped, "the cap must not change the price");

        // -- 20,000 bps is no cap: the whole WETH leg, less the spread, in one fill. -------
        uint256 wholeLeg = balance[WETH] * UNIT_WETH / UNIT_WBTC;
        uint256 movedWhole = _wouldMove(WBTC, WETH, wholeLeg, true);
        assertEq(movedWhole, 6000, "fixture: the whole $60k leg is 6,000 bps of the $100k basket");
        _expectExceedsMaxShift(movedWhole, CAP);
        this.fill(capped, WBTC, WETH, wholeLeg, true);

        emit log_named_uint("cap, bps of basket value", CAP);
        emit log_named_uint("$5,000 exact-in, bps", CAP);
        emit log_named_uint("$5,000 + 1 wei WBTC, bps (refused)", CAP + 1);
        emit log_named_uint("whole WETH leg, bps (refused)", movedWhole);
    }

    /// @notice The reviewer's case, and why the cap is on value. A basket exactly on the HF
    ///         2.00 target, the pool reporting HF 1.15 (target 20 / 10 / 70). Selling WETH for
    ///         WBTC moves WETH away from its target and WBTC toward it: the L1 distance does
    ///         not change, however much moves — a cap on distance would let $20k through, two
    ///         thirds of the WBTC leg. The cap on value refuses it at 2,000 bps, and everything
    ///         above $5,000 with it.
    function test_AMixedFill_MovesNoDistance_AndIsCappedAllTheSame() public {
        _setBasket(_wei(WETH, 100_000, 0.5e18), _wei(WBTC, 100_000, 0.3e18), _wei(USDC, 100_000, 0.2e18));
        _setHealthFactor(1.15e18);
        bytes memory capped = _args(CAP);

        uint256 x = 20_000 * USD;
        assertEq(_distanceMove(WETH, WBTC, x, 1.15e18), 0, "fixture: $20k WETH -> WBTC moves no distance at all");

        uint256 amountIn = x / UNIT_WETH;
        uint256 moved = _wouldMove(WETH, WBTC, amountIn, true);
        assertEq(moved, 2000, "$20k is 2,000 bps of the basket");
        _expectExceedsMaxShift(moved, CAP);
        this.fill(capped, WETH, WBTC, amountIn, true);

        // The same in the other mixed direction on the 60/20/20 basket at HF 2.00: $10k of
        // USDC for WETH takes WETH exactly to its target and USDC exactly off it.
        _setHealthFactor(2.0e18);
        _setBasket(_wei(WETH, 100_000, 0.6e18), _wei(WBTC, 100_000, 0.2e18), _wei(USDC, 100_000, 0.2e18));
        x = 10_000 * USD;
        assertEq(_distanceMove(USDC, WETH, x, 2.0e18), 0, "fixture: $10k USDC -> WETH moves no distance at all");
        moved = _wouldMove(USDC, WETH, x / UNIT_USDC, true);
        assertEq(moved, 1000, "$10k is 1,000 bps of the basket");
        _expectExceedsMaxShift(moved, CAP);
        this.fill(capped, USDC, WETH, x / UNIT_USDC, true);
    }

    /// @notice The reason the cap exists. A basket exactly on the HF 2.00 target, and the pool
    ///         reports HF 1.15 — whether because the borrower is really there or because the
    ///         number is wrong. The curve now says the basket is a full 1.00 of distance from
    ///         target and prices the deleveraging fill cheaply. Whatever a taker tries, in any
    ///         direction, one fill moves at most 5% of the basket and no leg loses more than
    ///         $5,000 of its value.
    function test_AWrongHealthFactor_CannotRestructureTheBasketInOneFill() public {
        _setBasket(_wei(WETH, 100_000, 0.5e18), _wei(WBTC, 100_000, 0.3e18), _wei(USDC, 100_000, 0.2e18));
        _setHealthFactor(1.15e18);
        bytes memory capped = _args(CAP);
        uint256[] memory targets = this.weightsAt(Curves.freeboard(), 1.15e18);
        assertEq(BasketDistance.distance(_values(), targets), 1.0e18, "fixture: 1.00 of distance to close");

        // The drain: the whole $50k WETH leg for USDC. Refused at 5,000 bps.
        uint256 drain = 50_000 * USD / UNIT_USDC;
        _expectExceedsMaxShift(_wouldMove(USDC, WETH, drain, true), CAP);
        this.fill(capped, USDC, WETH, drain, true);

        // What one fill CAN do, in every direction: the largest passing fill leaves every leg
        // within $5,000 of where it stood.
        uint256[] memory before = _values();
        for (uint8 p = 0; p < 6; ++p) {
            (address tokenIn, address tokenOut) = _pair(p);
            uint256 snapshot = vm.snapshotState();

            (uint256 amountIn, uint256 amountOut) =
                this.fill(capped, tokenIn, tokenOut, 5000 * USD / _unit(tokenIn), true);
            _settle(tokenIn, tokenOut, amountIn, amountOut);
            uint256[] memory after_ = _values();
            for (uint256 l = 0; l < 3; ++l) {
                uint256 lost = before[l] > after_[l] ? before[l] - after_[l] : 0;
                assertLe(lost, 5000 * USD, "one fill took more than the cap's share out of a leg");
            }

            vm.revertToState(snapshot);
        }
    }

    // -----------------------------------------------------------------------------------
    // 2. THE DoD — any sequence of fills within one block
    // -----------------------------------------------------------------------------------

    /// @notice Any basket, any health factor, any cap from 1 to 2,000 bps, and a sequence of
    ///         eight fills — any pair, any side, any size up to the out leg — applied one after
    ///         another with the health factor held fixed, as within one block. Every fill that
    ///         settled moved at most the cap of the basket's value, and closed at most twice
    ///         the cap of distance; every refusal named a share above the cap, and that share
    ///         is the one the reference measures for the amounts the fill would have settled at
    ///         (read from an uncapped twin of the args); and the twin prices every settled fill
    ///         identically — the cap changes nothing but the revert.
    /// @dev PER FILL, AND ONLY PER FILL. What is bounded is each fill against the basket as it
    ///      then stands: no ordering, side, direction or splitting of inputs lets a single
    ///      fill past the cap. A sequence of `k` fills is bounded by `k` caps and nothing
    ///      tighter — `extruction()` is `view` and keeps no count, and the slices are priced
    ///      along the same path as one large fill would be (convexity), so splitting costs a
    ///      taker nothing but gas. This test does not claim a per-block bound and does not
    ///      advance blocks; there is nothing block-shaped to assert.
    ///
    ///      WHAT A PER-BLOCK BOUND WOULD NEED, AND WHY IT IS OUT OF SCOPE. A slot per strategy
    ///      holding `(block.number, bps moved)`; a write on the swap path only, which means
    ///      dropping `IStaticExtruction`, branching on `isStaticContext` as `ProbeExtruction`
    ///      does, and giving up the one-`view`-function argument that makes quote/swap
    ///      consistency structural (T9); a `msg.sender == router` gate so nobody burns a
    ///      strategy's budget by calling the extruction directly; and a new refusal mode in
    ///      which one taker's fill refuses another's quote. And a block is the wrong unit: a
    ///      5% per-block budget is a four-minute drain, a per-hour budget is the same state
    ///      with a bigger number, and either RATIONS THE DELEVERAGING THE BASKET EXISTS TO DO
    ///      — in a crash the toward-target fills must happen now. The value a drain can take
    ///      is bounded elsewhere: no fill beats the oracle
    ///      (`Pricing.t.sol`, `testFuzz_Pricing_NeverBeatsTheOracle_AndNeverExceedsTheAwaySpread`),
    ///      so whoever moves the basket pays the borrower for it; what remains is composition
    ///      under a wrong HF, and that is per fill, here, and T16's fail-safe.
    function testFuzz_EveryFillInAnySequence_IsWithinTheCap(
        uint64 weth,
        uint48 wbtc,
        uint64 usdc,
        uint256 hfSeed,
        uint16 capSeed,
        bytes32 seed
    )
        public
    {
        _setBasket(weth, wbtc, usdc);
        // A basket worth at least one wei of every token (UNIT_WBTC is the largest unit: half
        // a milli-dollar). Below that, the exact-out ceiling to one whole wei of the in token
        // can itself be worth more than the basket, and then even the 20,000 bps twin refuses —
        // correctly: that fill moves several baskets' worth of value in. The twin must be
        // uncapped for the comparison below, so dust is excluded, not the cap.
        vm.assume(_total() >= UNIT_WBTC);
        uint256 hf = 1e18 + hfSeed % 1.5e18;
        _setHealthFactor(hf);
        uint16 cap = uint16(bound(capSeed, 1, 2000));
        bytes memory capped = _args(cap);
        bytes memory uncapped = _args(NO_CAP);

        for (uint256 k = 0; k < STEPS; ++k) {
            bytes32 r = keccak256(abi.encode(seed, k));
            (address tokenIn, address tokenOut) = _pair(uint8(r[0]));
            bool isExactIn = uint8(r[1]) % 2 == 0;
            uint256 room = isExactIn ? balance[tokenOut] * _unit(tokenOut) / _unit(tokenIn) : balance[tokenOut];
            if (room == 0) {
                continue;
            }
            uint256 amount = 1 + (uint256(r) >> 16) % room;

            try this.fill(capped, tokenIn, tokenOut, amount, isExactIn) returns (uint256 amountIn, uint256 amountOut) {
                assertLe(_moved(tokenIn, tokenOut, amountIn, amountOut), cap, "a fill settled past the cap");

                // The corollary: the value that leaves, walked as the pricing rule walks it,
                // closes at most twice the cap of distance.
                uint256 closed = _distanceMove(tokenIn, tokenOut, amountOut * _unit(tokenOut), hf);
                assertLe(closed, 2 * uint256(cap) * ONE / BPS, "a fill closed more than twice the cap of distance");

                (uint256 twinIn, uint256 twinOut) = this.fill(uncapped, tokenIn, tokenOut, amount, isExactIn);
                assertEq(twinIn, amountIn, "the cap changed amountIn");
                assertEq(twinOut, amountOut, "the cap changed amountOut");

                _settle(tokenIn, tokenOut, amountIn, amountOut);
            } catch (bytes memory reason) {
                (bool matched, uint256 shift, uint256 maxShift) = _decodeExceedsMaxShift(reason);
                if (!matched) {
                    continue; // exceeds the leg, no value, ...: not this test's subject
                }
                assertEq(maxShift, cap, "the refusal named a cap other than the args'");
                assertGt(shift, cap, "refused, but the named share is within the cap");

                (uint256 wouldIn, uint256 wouldOut) = this.fill(uncapped, tokenIn, tokenOut, amount, isExactIn);
                assertEq(
                    _moved(tokenIn, tokenOut, wouldIn, wouldOut),
                    shift,
                    "the refusal's share is not the settled share of the fill it refused"
                );
            }
        }
    }
}
