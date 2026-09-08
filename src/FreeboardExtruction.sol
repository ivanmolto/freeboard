// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { IExtruction, IStaticExtruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";

import { Addresses } from "./constants/Addresses.sol";
import { IPoolAddressesProvider } from "./interfaces/IAaveV3.sol";
import { IAaveV3Oracle } from "./interfaces/IAaveV3Oracle.sol";
import { IAaveV3Pool } from "./interfaces/IAaveV3Pool.sol";
import { BasketDistance } from "./libs/BasketDistance.sol";
import { Curve } from "./libs/Curve.sol";
import { FreeboardArgs } from "./libs/FreeboardArgs.sol";

/// @title FreeboardExtruction — the contract the deployed AquaSwapVMRouter calls
/// @notice Freeboard's pricing lives here, behind the ONE function the router's `_extruction`
///         instruction (opcode 0x20) reaches by selector. The router is the deployed
///         `AquaSwapVMRouter` at `Addresses.AQUA_SWAP_VM_ROUTER`, swap-vm tag v1.0.2; nothing of
///         swap-vm is redeployed or modified for this contract to run.
///
/// @dev ONE FUNCTION, TWO INTERFACES. `Extruction._extruction` picks the interface from the
///      VM's static flag (swap-vm v1.0.2, `src/instructions/Extruction.sol:95-113`):
///
///        if (ctx.vm.isStaticContext) {
///            (ctx.vm.nextPC, choppedLength, ctx.swap) = IStaticExtruction(target).extruction(...);
///        } else {
///            (ctx.vm.nextPC, choppedLength, ctx.swap) = IExtruction(target).extruction(...);
///        }
///
///      `IStaticExtruction.extruction` (`:40-51`) is `view`; `IExtruction.extruction` (`:18-29`)
///      is not. Their parameter lists are identical, so the selector is identical
///      (`PinTest.test_PinnedSwapVM_ExtructionSelectorsAgree`). One `view` implementation
///      satisfies both: Solidity lets an override tighten mutability, so `view` overrides the
///      non-view base, and `view` is exactly the base of the other. That is not a convenience.
///      It is the guarantee the interfaces demand in capital letters — "The same inputs MUST
///      yield the same swap amounts in both interfaces" — made structural: a `view` function
///      cannot write state, so there is no side effect for `quote()` and `swap()` to differ by.
///
/// @dev THE REGISTERS ARE OVERWRITTEN WHOLESALE. The router assigns `ctx.swap` from
///      `updatedSwap` (`:96`, `:105`), so any register this function does not copy forward
///      reaches settlement as zero. Every register is copied first; only the priced one is
///      then changed.
///
/// @dev IMMUTABLE. No owner, no upgrade, no constructor arguments, no storage. The code that
///      priced the quote is the code that prices the swap, in every block, forever.
///
/// @dev `view`, NOT `pure`. The body reads chain state: the maker's health factor from Aave,
///      the oracle's prices, the tokens' decimals and the basket's other legs from Aqua. Every
///      one of those is a `view` over state that does not change within a block, so the
///      quote/swap consistency argument rests on `view` — see `_healthFactor` for the argument
///      in full; it applies to each read the same way.
///
/// @dev `isStaticContext` is accepted because the router passes it, and is never read. Pricing
///      that branches on the quote/swap flag is the non-determinism the interfaces forbid;
///      `test_QuoteAndSwapPaths_ReturnIdenticalRegisters` proves the two paths agree on the
///      deployed router.
///
/// @dev `takerData` is `ctx.takerArgs()` — the taker's remaining `instructionsArgs`, a
///      taker-controlled input (`Extruction.sol:102`, `:111`). Freeboard ignores it and
///      returns `choppedLength = 0`, consuming none of it. `tryChopTakerArgs` would truncate a
///      shortfall silently and the `require` after it would revert (`:114-115`), so zero is
///      the only value that is safe without reading the data.
contract FreeboardExtruction is IExtruction, IStaticExtruction {
    using FreeboardArgs for bytes;

    // -----------------------------------------------------------------------------------
    // The spread schedule — the only pricing parameters, and they are not in the args
    // -----------------------------------------------------------------------------------

    /// @dev WAD, shared with `Curve.ONE` and `BasketDistance.ONE`.
    uint256 internal constant ONE = 1e18;

    /// @dev THE MARGINAL SPREAD, per unit of value moved, by what the move does to the basket:
    ///        SPREAD_TOWARD  both legs move toward their targets     10 bps
    ///        SPREAD_MIXED   one toward, one away, distance unchanged 55 bps
    ///        SPREAD_AWAY    both legs move away from their targets  100 bps
    ///      A fill never beats the oracle: even a pure toward-target fill pays the maker ten
    ///      basis points, so the borrower is paid for every rebalance — the tagline's "paid a
    ///      spread to do it" — and the taker's discount is the ninety basis points a
    ///      toward-target fill does NOT pay. Ten times cheaper than away, and fifty times
    ///      cheaper than a liquidation bonus.
    ///
    ///      NOT IN THE ARGS. The args are the risk policy the borrower signs on the Ledger —
    ///      the curve and the per-fill cap — and a spread schedule is not a risk policy. It is
    ///      a compile-time constant of an immutable contract so it cannot vary by position and
    ///      cannot change after deployment. `SPREAD_MIXED` is the midpoint and `SPREAD_SLOPE`
    ///      a quarter of the gap so that `SPREAD_MIXED - 2 * SPREAD_SLOPE == SPREAD_TOWARD`
    ///      exactly (`test_Schedule_IsExactInWad`), which the no-underflow argument in
    ///      `_spreadNumerator` relies on.
    uint256 internal constant SPREAD_TOWARD = 0.001e18;
    uint256 internal constant SPREAD_AWAY = 0.01e18;
    uint256 internal constant SPREAD_MIXED = (SPREAD_TOWARD + SPREAD_AWAY) / 2;
    uint256 internal constant SPREAD_SLOPE = (SPREAD_AWAY - SPREAD_TOWARD) / 4;

    /// @dev The value unit: a leg's balance times its oracle price, scaled to 18 decimals.
    ///      `unit = price * 10 ** (VALUE_DECIMALS - decimals)` per wei of the token, so the value
    ///      of a balance is an exact product with no division until the final amount is formed.
    uint256 internal constant VALUE_DECIMALS = 18;

    /// @dev The largest basket, in value units, the arithmetic below holds without overflow:
    ///      `SPREAD_MIXED * x * ONE` with `x <= MAX_BASKET_VALUE` is 1e76 < 2^256, and the
    ///      `SPREAD_SLOPE * scaled` terms are bounded by `2 * ONE * MAX_BASKET_VALUE * ONE` on
    ///      the same order. At the 1e8 USD oracle unit scaled by 1e18 that is a basket worth
    ///      1e14 dollars; anything larger is refused by name rather than left to a panic.
    uint256 internal constant MAX_BASKET_VALUE = 1e40;

    /// @dev The per-fill cap's unit: `maxShiftBps` is basis points of the BASKET'S VALUE that
    ///      one fill may move — the larger of what comes in and what goes out, over the total
    ///      before the fill. 500 is five percent of the basket per fill. Neither side of a fill
    ///      exceeds the OUT LEG in value: exact-in, `_spreadNumerator` requires `x <= held`;
    ///      exact-out, `_inValue` returns at most `held` (its pieces are clipped to the leg),
    ///      and `ceilDiv` to a whole wei of the in token adds under one unit of it. So the
    ///      share a fill can move is under `10,000 + unitIn * BPS / total` bps: on any basket
    ///      that is not dust, a cap of 10,001 bps or more can never bind — it is no cap, and a
    ///      borrower who ships one has signed away the bound (uint16 allows 65,535); the tests'
    ///      20,000 never binds on a basket worth at least one wei of each of its tokens. On a
    ///      dust basket worth less than a wei of the in token, that one wei is itself more
    ///      than the basket, and the cap refuses it: right.
    uint256 internal constant BPS = 10_000;

    /// @dev Aqua's docked marker (`Aqua.sol`, `_DOCKED = 0xff`); `tokensCount == 0` is inactive.
    uint8 internal constant AQUA_DOCKED = 0xff;

    uint256 internal constant NO_LEG = type(uint256).max;

    // -----------------------------------------------------------------------------------
    // Errors — every refusal by name
    // -----------------------------------------------------------------------------------

    /// @notice Aave could not compute this maker's health factor, so the fill is refused.
    /// @param maker The position owner the read was for — always `query.maker`.
    /// @dev THE FILL REVERTS; IT NEVER FALLS BACK. There is no try/catch here and no default
    ///      health factor, because a default is a price, and a price computed from a number
    ///      Aave would not stand behind is exactly the mispricing this contract exists to
    ///      prevent. Refusing costs the borrower nothing: Aave's own `liquidationCall` reads
    ///      the same oracle through the same `calculateUserAccountData`, so while HF is
    ///      unreadable no liquidation is possible either — there is nothing to be late for.
    ///      (CLAUDE.md, "WHY THE HF READ IS SAFE INSIDE THE PRICING PATH"; T16 owns the
    ///      rationale and `test_RevertWhen_HealthFactorUnreadable`.)
    error FreeboardHealthFactorUnreadable(address maker);

    /// @notice The args are not exactly `FreeboardArgs.size(m, n)` bytes.
    error FreeboardArgsLengthMismatch(uint256 actual, uint256 expected);

    /// @notice A swapped token is not a leg of the committed basket.
    error FreeboardTokenNotInBasket(address token);

    /// @notice `tokenIn == tokenOut`; there is no basket move to price.
    error FreeboardSameTokenBothSides(address token);

    /// @notice A committed leg is not in the maker's active Aqua strategy: `rawBalances`
    ///         reports it inactive (never shipped) or docked. A missing leg is a revert, not a
    ///         zero (CLAUDE.md, "a missing leg is a revert, not zero").
    error FreeboardLegNotInStrategy(address maker, bytes32 strategyHash, address token);

    /// @notice The shipped strategy holds a different number of tokens than the curve has legs,
    ///         so the committed token list cannot be the strategy's token set.
    error FreeboardStrategyLegCountMismatch(uint256 legs, uint256 tokensCount);

    /// @notice The oracle returned zero for a basket token.
    error FreeboardAssetPriceUnreadable(address token);

    /// @notice A basket token has more than 18 decimals.
    error FreeboardTokenDecimalsUnsupported(address token, uint256 decimals);

    /// @notice The basket is worth more than `MAX_BASKET_VALUE` value units.
    error FreeboardBasketValueTooLarge(uint256 total);

    /// @notice The fill would take more of `token` than the basket's leg holds.
    /// @param wanted The value the fill moves out of the leg; `held` is the leg's value.
    error FreeboardFillExceedsLeg(address token, uint256 wanted, uint256 held);

    /// @notice The fill would move more of the basket's value than the cap the maker committed
    ///         in the args (`FreeboardArgs.maxShiftBps`).
    /// @param shift Basis points of the basket's value the fill moves, rounded up.
    /// @param maxShift The cap, `maxShiftBps`.
    /// @dev THE PROPERTY THAT BOUNDS EVERY FAILURE MODE THIS CONTRACT CANNOT EXCLUDE. A wrong
    ///      health factor, a wrong oracle price, a curve the borrower mis-signed, a taker who
    ///      has found something nobody thought of — whatever the cause, one fill moves at most
    ///      this share of the basket, out of any leg, in any direction. It is also the on-chain
    ///      answer to "the curve is public": closing `d` of basket distance takes moving at
    ///      least `d / 2` of the basket's value (each moving leg's share changes by the value
    ///      moved over the total), so a cap of `c` on value is a cap of `2c` on the distance
    ///      one fill can close, and the whole rebalance cannot be taken in one fill at the
    ///      deepest discount (`docs/freeboard-v0.md` §7).
    ///
    /// @dev TWO BOUNDS, SIDE BY SIDE. This one is on COMPOSITION, per fill. The bound on VALUE
    ///      is the pricing rule's: no fill ever beats the oracle (`_spreadNumerator`, the
    ///      no-underflow argument; `testFuzz_Pricing_NeverBeatsTheOracle_AndNeverExceedsTheAwaySpread`),
    ///      so whoever moves the basket pays the borrower at least `SPREAD_TOWARD` for it, and
    ///      there is no price below fair to drain at. What a wrong HF can still do is move the
    ///      basket to the wrong composition at a fair price, and that is what this cap bounds —
    ///      PER FILL, not per block. This function is `view` and keeps no count, so a sequence
    ///      of `k` fills is bounded by `k` caps, each re-reading the health factor and the live
    ///      basket and priced along the same path as one large fill (`_healthWeightedTarget`,
    ///      convexity). A per-block budget would need storage written on the swap path, which
    ///      gives up the structural quote/swap consistency above, and would ration the
    ///      deleveraging the basket exists to do; `PerFillCap.t.sol` says what it would take.
    ///
    /// @dev WHY VALUE AND NOT DISTANCE. The first cut of this cap bounded the change in
    ///      `BasketDistance` a fill causes. That metric is blind along a whole family of
    ///      fills: one leg moving toward its target and the other away leaves the L1 distance
    ///      unchanged however much value moves, so under it a taker could take two thirds of
    ///      a leg in one fill against a 500 bps cap (review, Sep 8; `PerFillCap.t.sol`,
    ///      `test_AMixedFill_MovesNoDistance_AndIsCappedAllTheSame`). Value moved has no blind
    ///      direction, and it bounds the distance change from above — so it carries both
    ///      claims, and it costs one comparison.
    error FreeboardFillExceedsMaxShift(uint256 shift, uint256 maxShift);

    // -----------------------------------------------------------------------------------
    // The basket, as the pricing core sees it
    // -----------------------------------------------------------------------------------

    /// @dev One fill's view of the position, built by `_basket`. Values and `total` are in
    ///      value units; `targets` are the curve's WAD weights at the maker's health factor.
    /// @param scaledBefore `BasketDistance.scaledDistance` of the basket as it stands — the
    ///        numerator; `total` is its denominator.
    struct Basket {
        uint256[] values;
        uint256[] targets;
        uint256 total;
        uint256 scaledBefore;
        uint256 legIn;
        uint256 legOut;
        uint256 unitIn;
        uint256 unitOut;
        address tokenOut;
    }

    /// @notice The extruction entry point, called by the deployed router at opcode 0x20.
    /// @dev Signature quoted from swap-vm v1.0.2 `src/instructions/Extruction.sol:18-29`.
    /// @param nextPC Already the offset of the instruction AFTER this one
    ///        (`src/libs/VM.sol:122-132`); returned unchanged, so the program continues — and,
    ///        with `_extruction` last in the Freeboard program, terminates.
    /// @param query Read-only swap information. `query.maker` is the position owner.
    /// @param swap The registers as the router holds them on entry.
    /// @param args The instruction's args with the router-stripped 20-byte target removed
    ///        (`Extruction.sol:101`, `:110`): the `FreeboardArgs` layout — curve, tokens, cap.
    /// @dev The unnamed parameters are, in order, `isStaticContext` (see the contract notes)
    ///      and `takerData`.
    /// @return updatedNextPC `nextPC`, unchanged.
    /// @return choppedLength 0 — no taker data consumed.
    /// @return updatedSwap Every input register copied forward, with the missing amount set.
    /// @dev THE HEALTH FACTOR IS READ FIRST. Solidity evaluates arguments before the call, so
    ///      `_healthFactor(query.maker)` runs ahead of `_healthWeightedTarget`'s body: an
    ///      unreadable HF stops the fill before any other read or any arithmetic, which is the
    ///      ordering T16's fail-safe asks for.
    function extruction(
        bool, /* isStaticContext */
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata /* takerData */
    )
        external
        view
        override(IExtruction, IStaticExtruction)
        returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap)
    {
        updatedSwap = swap;
        _healthWeightedTarget(query, updatedSwap, args, _healthFactor(query.maker));
        updatedNextPC = nextPC;
        choppedLength = 0;
    }

    // -----------------------------------------------------------------------------------
    // 1. The health factor
    // -----------------------------------------------------------------------------------

    /// @notice The maker's Aave v3 health factor, WAD, or a reverted fill.
    /// @param maker MUST be `query.maker` — the position owner the ROUTER named, taken from the
    ///        `SwapQuery` it builds from the order (swap-vm v1.0.2, `src/SwapVM.sol:130-137`,
    ///        `:176-183`). It is NEVER an address decoded from `args`, and never one from taker
    ///        data. The curve a borrower signs on the Ledger and commits with `ship()` is a risk
    ///        policy over THEIR OWN position; a strategy that could name its subject would let a
    ///        maker price their basket off a stranger's liquidation risk, or let a taker choose
    ///        whose risk to be quoted against. Freeboard makes that unexpressible rather than
    ///        merely forbidden: the address is not an input to the program. This is also why
    ///        `IAaveV3Pool` declares one function and `AAVE_V3_POOL` is a compile-time constant
    ///        — neither the subject nor the oracle of the read is chooseable.
    /// @return healthFactor WAD, 1e18 = HF 1.00; `type(uint256).max` when the maker has no debt,
    ///         which `Curve` clamps to the top row with no special case.
    ///
    /// @dev WHY AN EXTERNAL CALL HERE DOES NOT BREAK QUOTE/SWAP CONSISTENCY. `IExtruction`
    ///      warns in capitals that the two paths must agree. `getUserAccountData` is a `view`
    ///      over the pool's own state and its oracle, with no writes and no time dependence, so
    ///      it is deterministic within a block: `quote()` reaches it under STATICCALL and
    ///      `swap()` under CALL, and T8 proved the two return identical bytes in the same block
    ///      (`test_StaticCall_AndCall_AgreeWithinTheSameBlock`). The dependency is deterministic,
    ///      so the consistency the interface demands holds.
    ///
    /// @dev LOW-LEVEL, AND CHECKED FOR LENGTH. A STATICCALL to an address with no code succeeds
    ///      and returns nothing, so `success` alone would let an empty answer through, and
    ///      `abi.decode` of a short buffer reverts with NO data at all — a bare revert that says
    ///      nothing about why. Requiring exactly the six words the ABI defines turns "no pool
    ///      there", "the pool reverted" and "the pool answered short" into the same named,
    ///      deliberate refusal. The read is `staticcall` and not a typed call for one reason
    ///      only: to name the failure. What the length check cannot do is vouch for the CONTENT
    ///      of six words; that is vouched for by `AAVE_V3_POOL` being a compile-time constant,
    ///      so the only contract that can answer is the one T8 matched on the fork.
    function _healthFactor(address maker) internal view returns (uint256 healthFactor) {
        (bool ok, bytes memory ret) =
            Addresses.AAVE_V3_POOL.staticcall(abi.encodeCall(IAaveV3Pool.getUserAccountData, (maker)));
        require(ok && ret.length == 6 * 32, FreeboardHealthFactorUnreadable(maker));

        (,,,,, healthFactor) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256));
    }

    // -----------------------------------------------------------------------------------
    // 2-4. The pricing core
    // -----------------------------------------------------------------------------------

    /// @notice `_healthWeightedTarget` — the one pricing rule (CLAUDE.md, "THE PRICING CORE").
    ///         HF -> curve -> target weights; the basket's legs valued at the oracle; the
    ///         basket's distance from target before and after the fill; the price by the delta.
    ///
    /// @dev THE RULE. Let `x` be the value the fill moves — out of the `tokenOut` leg and into
    ///      the `tokenIn` leg, valued at the oracle, so the basket's total value `T` does not
    ///      change along the move — and `D(x)` the basket's L1 distance from target after it
    ///      (`BasketDistance`). The spread the maker keeps, in value, is
    ///
    ///        S(x) = SPREAD_MIXED * x  -  SPREAD_SLOPE * T * (D(0) - D(x))
    ///
    ///      a flat charge on the size, minus a rebate proportional to how much distance the
    ///      fill closes — or plus a surcharge for the distance it opens. That is "price by the
    ///      delta", and it is also, exactly, the integral along the move of a MARGINAL spread
    ///      that is `SPREAD_TOWARD` while both legs move toward their targets, `SPREAD_MIXED`
    ///      while one does and one does not, and `SPREAD_AWAY` while both move away: `D` is
    ///      piecewise linear in `x`, each leg's term changing at the rate `1 / T` in one
    ///      direction until the leg crosses its target and the other direction after, so
    ///      `T * dD/dx` is `-2`, `0` or `+2` and `SPREAD_MIXED + SPREAD_SLOPE * T * dD/dx`
    ///      is one of the three constants. Because each leg crosses its target at most once
    ///      along a move, the marginal spread never decreases along it: `S` is convex, so a
    ///      larger fill never gets a better average price (README invariant 4), and the price
    ///      of a fill is a non-decreasing function of the distance it closes — the two
    ///      properties `test/unit/Pricing.t.sol` fuzzes.
    ///
    ///      Exact-in: `amountOut = floor((x - S(x)) / unitOut)`. Exact-out: `x` is the least
    ///      value with `x - S(x) >= y`, solved exactly by `_inValue`, and
    ///      `amountIn = ceil(x / unitIn)`. Rounding favours the maker at every step (README
    ///      invariant 5): the spread is ceiled, the output floored, the input ceiled.
    ///
    /// @dev ORDER OF READS. The health factor is read before this function is entered; the
    ///      curve is decoded and the targets derived before anything else is read; then the
    ///      basket. Every read is a `view` over state fixed within the block. Last, on the
    ///      amounts that will settle, the per-fill cap (`_requireWithinMaxShift`).
    function _healthWeightedTarget(
        SwapQuery calldata query,
        SwapRegisters memory swap,
        bytes calldata args,
        uint256 healthFactor
    )
        internal
        view
    {
        bytes calldata curve = args.curve();
        uint256 n = Curve.legs(curve);
        uint256 expectedSize = FreeboardArgs.size(Curve.breakpoints(curve), n);
        require(args.length == expectedSize, FreeboardArgsLengthMismatch(args.length, expectedSize));

        uint256[] memory targets = Curve.weightsAt(curve, healthFactor);
        Basket memory basket = _basket(query, swap, args, n, targets);

        uint256 valueIn;
        uint256 valueOut;
        if (query.isExactIn) {
            valueIn = swap.amountIn * basket.unitIn;
            swap.amountOut = _outValue(basket, valueIn) / basket.unitOut;
            valueOut = swap.amountOut * basket.unitOut;
        } else {
            valueOut = swap.amountOut * basket.unitOut;
            swap.amountIn = Math.ceilDiv(_inValue(basket, valueOut), basket.unitIn);
            valueIn = swap.amountIn * basket.unitIn;
        }
        _requireWithinMaxShift(basket, valueIn, valueOut, args.maxShiftBps());
    }

    // -----------------------------------------------------------------------------------
    // 5. The per-fill cap
    // -----------------------------------------------------------------------------------

    /// @notice Refuses the fill if it would move more than `maxShiftBps` of the basket's value
    ///         — the cap the maker signed into the args.
    /// @param valueIn The value the taker pays in, `amountIn * unitIn`, as it will SETTLE.
    /// @param valueOut The value the taker takes out, `amountOut * unitOut`, as it will SETTLE.
    /// @dev THE LARGER SIDE, OVER THE BASKET BEFORE THE FILL. The two sides differ by the spread
    ///      the maker keeps, so the in side is the larger; the larger is measured rather than
    ///      assumed. The denominator is the basket as it stands, the same total every other
    ///      number in this fill is taken against.
    ///
    /// @dev CHECKED AFTER PRICING, ON THE FINAL AMOUNTS. `_inValue` evaluates the spread at
    ///      piece boundaries that are not the fill; only the amounts that reach the registers
    ///      are the fill, so the cap is applied once, here, to exactly what settles — the same
    ///      two numbers whatever the fill's direction or side.
    ///
    /// @dev EXACT. `ceilDiv(moved * BPS, total) <= cap` is `moved * BPS <= cap * total` with no
    ///      rounding in the comparison, and the bps it names in the refusal is strictly above
    ///      the cap whenever it refuses. `moved` is under the out leg plus one unit of the in
    ///      token (see `BPS`), so the product is under `(MAX_BASKET_VALUE + unitIn) * BPS`,
    ///      about 1e44.
    function _requireWithinMaxShift(
        Basket memory basket,
        uint256 valueIn,
        uint256 valueOut,
        uint256 maxShiftBps
    )
        internal
        pure
    {
        uint256 moved = valueIn > valueOut ? valueIn : valueOut;
        uint256 shift = Math.ceilDiv(moved * BPS, basket.total);
        require(shift <= maxShiftBps, FreeboardFillExceedsMaxShift(shift, maxShiftBps));
    }

    /// @dev Values every committed leg at the oracle. The swapped pair comes from the registers
    ///      the router preloaded from `AQUA.safeBalances` (`SwapVM.sol:193-194`); every other
    ///      leg is read from Aqua here, because `SwapRegisters` carries only the pair.
    function _basket(
        SwapQuery calldata query,
        SwapRegisters memory swap,
        bytes calldata args,
        uint256 n,
        uint256[] memory targets
    )
        internal
        view
        returns (Basket memory basket)
    {
        require(query.tokenIn != query.tokenOut, FreeboardSameTokenBothSides(query.tokenIn));

        IAaveV3Oracle oracle =
            IAaveV3Oracle(IPoolAddressesProvider(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER).getPriceOracle());

        basket.values = new uint256[](n);
        basket.targets = targets;
        basket.legIn = NO_LEG;
        basket.legOut = NO_LEG;
        basket.tokenOut = query.tokenOut;

        for (uint256 l = 0; l < n; ++l) {
            address token = args.tokenAt(l);
            uint256 unit = _unit(oracle, token);
            uint256 balance;
            if (token == query.tokenIn) {
                balance = swap.balanceIn;
                basket.legIn = l;
                basket.unitIn = unit;
            } else if (token == query.tokenOut) {
                balance = swap.balanceOut;
                basket.legOut = l;
                basket.unitOut = unit;
            } else {
                balance = _aquaLeg(query, token, n);
            }
            basket.values[l] = balance * unit;
            basket.total += basket.values[l];
        }
        require(basket.legIn != NO_LEG, FreeboardTokenNotInBasket(query.tokenIn));
        require(basket.legOut != NO_LEG, FreeboardTokenNotInBasket(query.tokenOut));
        require(basket.total <= MAX_BASKET_VALUE, FreeboardBasketValueTooLarge(basket.total));

        (basket.scaledBefore,) = BasketDistance.scaledDistance(basket.values, targets);
    }

    /// @dev A non-swapped leg, from Aqua. `rawBalances` is quoted at the pin
    ///      (aqua v1.0.0, `src/interfaces/IAqua.sol:78`):
    ///
    ///        function rawBalances(address maker, address app, bytes32 strategyHash, address token)
    ///            external view returns (uint248 balance, uint8 tokensCount);
    ///
    ///      Unlike `safeBalances` it does NOT revert for a token outside the strategy — it
    ///      answers `(0, 0)` — so the revert the design requires is made here: `tokensCount`
    ///      is 0 for a token never shipped under this hash and `0xff` once docked
    ///      (`Aqua.sol`, `_DOCKED`), and either is refused by name. A leg the maker sold out
    ///      entirely is a real zero with a positive `tokensCount`, and is priced as such.
    ///      `tokensCount` is also the size of the shipped token set; requiring it to equal the
    ///      curve's leg count is what binds the committed token list to the shipped strategy.
    ///      The app is the deployed router: `SwapVM` reads the pair under `address(this)`
    ///      (`SwapVM.sol:194`), and `Addresses.AQUA_SWAP_VM_ROUTER` is that address.
    function _aquaLeg(SwapQuery calldata query, address token, uint256 n) internal view returns (uint256) {
        (uint248 balance, uint8 tokensCount) =
            IAqua(Addresses.AQUA).rawBalances(query.maker, Addresses.AQUA_SWAP_VM_ROUTER, query.orderHash, token);
        require(
            tokensCount != 0 && tokensCount != AQUA_DOCKED,
            FreeboardLegNotInStrategy(query.maker, query.orderHash, token)
        );
        require(tokensCount == n, FreeboardStrategyLegCountMismatch(n, tokensCount));
        return balance;
    }

    /// @dev Value units per wei of `token`: the oracle price scaled so that every leg's value
    ///      has `VALUE_DECIMALS` decimals whatever the token's own. Aave values a reserve as
    ///      `balance * price / 10 ** decimals`; this is the same quantity times
    ///      `10 ** VALUE_DECIMALS`, kept as a product so nothing is floored before the end.
    function _unit(IAaveV3Oracle oracle, address token) internal view returns (uint256) {
        uint256 price = oracle.getAssetPrice(token);
        require(price > 0, FreeboardAssetPriceUnreadable(token));
        uint256 decimals = IERC20Metadata(token).decimals();
        require(decimals <= VALUE_DECIMALS, FreeboardTokenDecimalsUnsupported(token, decimals));
        return price * 10 ** (VALUE_DECIMALS - decimals);
    }

    // -----------------------------------------------------------------------------------
    // The spread
    // -----------------------------------------------------------------------------------

    /// @dev The value the taker receives for moving `x` into the basket: `x - S(x)`, exact-in.
    function _outValue(Basket memory basket, uint256 x) internal pure returns (uint256) {
        return x - Math.ceilDiv(_spreadNumerator(basket, x), ONE * ONE);
    }

    /// @dev `S(x) * ONE * ONE`, exact in integers — the rule in `_healthWeightedTarget` with
    ///      `T * (D(x) - D(0))` written as the difference of the two distance NUMERATORS
    ///      (`BasketDistance.scaledDistance`), which share the denominator `T` because the move
    ///      preserves it; so no division happens before the caller's one ceiling.
    ///
    ///      NO UNDERFLOW. Each of the two moving legs changes its numerator term by at most
    ///      `ONE * x` (triangle inequality), so `scaledAfter >= scaledBefore - 2 * ONE * x`, and
    ///      the sum is at least `(SPREAD_MIXED - 2 * SPREAD_SLOPE) * x * ONE`, which is
    ///      `SPREAD_TOWARD * x * ONE >= 0` — the schedule constants are chosen to make that
    ///      identity exact. A fill therefore never pays the taker more than the oracle value.
    function _spreadNumerator(Basket memory basket, uint256 x) internal pure returns (uint256) {
        uint256 held = basket.values[basket.legOut];
        require(x <= held, FreeboardFillExceedsLeg(basket.tokenOut, x, held));

        uint256[] memory after_ = new uint256[](basket.values.length);
        for (uint256 l = 0; l < after_.length; ++l) {
            after_[l] = basket.values[l];
        }
        after_[basket.legIn] += x;
        after_[basket.legOut] -= x;
        (uint256 scaledAfter,) = BasketDistance.scaledDistance(after_, basket.targets);

        return SPREAD_MIXED * x * ONE + SPREAD_SLOPE * scaledAfter - SPREAD_SLOPE * basket.scaledBefore;
    }

    /// @dev The least value `x` the taker must move in so that the basket pays out at least
    ///      `y` — the exact inverse of `_outValue`, exact-out.
    ///
    ///      `g(x) = x - S(x)` is increasing and piecewise linear, with slope `1 - r` on each
    ///      piece where `r` is the marginal spread there, and the pieces change only where a
    ///      moving leg crosses its target. Those crossings are at value offsets `_kink` computes;
    ///      a crossing that is not on the integer grid falls inside one unit interval, so the
    ///      grid points one below and at each crossing are taken as piece boundaries and every
    ///      unit interval that may contain a crossing is decided by evaluating `g` at both ends.
    ///      On every other piece `g` is exactly linear, and the least integer `x` with
    ///      `g(x) >= y` is solved in closed form with all rounding toward the maker. `g` is
    ///      evaluated from `_spreadNumerator` at every boundary, so the inverse is defined by
    ///      the forward rule and cannot drift from it.
    ///
    ///      If the whole leg pays out less than `y`, the fill exceeds the leg.
    function _inValue(Basket memory basket, uint256 y) internal pure returns (uint256) {
        if (y == 0) {
            return 0;
        }
        uint256 held = basket.values[basket.legOut];
        uint256[] memory bounds = _bounds(basket, held);

        uint256 wanted = y * ONE * ONE;
        uint256 p = 0;
        uint256 gp = 0; // g(0) * ONE * ONE
        for (uint256 i = 1; i < bounds.length; ++i) {
            uint256 q = bounds[i];
            uint256 gq = q * ONE * ONE - _spreadNumerator(basket, q);
            if (gq >= wanted) {
                if (q - p == 1) {
                    return q;
                }
                uint256 rate = _rateFrom(basket, p);
                return p + Math.ceilDiv(wanted - gp, (ONE - rate) * ONE);
            }
            p = q;
            gp = gq;
        }
        revert FreeboardFillExceedsLeg(basket.tokenOut, y, held);
    }

    /// @dev Piece boundaries for `_inValue`: 0, one below and at each positive crossing, and
    ///      the whole out leg — clipped to the leg, sorted, deduplicated.
    function _bounds(Basket memory basket, uint256 held) internal pure returns (uint256[] memory bounds) {
        uint256[] memory raw = new uint256[](6);
        uint256 count = 1; // raw[0] = 0
        uint256 kinkIn = _kink(basket, basket.legIn, true);
        uint256 kinkOut = _kink(basket, basket.legOut, false);
        if (kinkIn > 0) {
            raw[count++] = kinkIn - 1;
            raw[count++] = kinkIn;
        }
        if (kinkOut > 0) {
            raw[count++] = kinkOut - 1;
            raw[count++] = kinkOut;
        }
        raw[count++] = held;

        // Insertion sort, clipping to the leg.
        for (uint256 i = 1; i < count; ++i) {
            uint256 v = raw[i] > held ? held : raw[i];
            uint256 j = i;
            while (j > 0 && raw[j - 1] > v) {
                raw[j] = raw[j - 1];
                --j;
            }
            raw[j] = v;
        }

        // Deduplicate.
        bounds = new uint256[](count);
        uint256 kept = 0;
        for (uint256 i = 0; i < count; ++i) {
            if (i == 0 || raw[i] != raw[i - 1]) {
                bounds[kept++] = raw[i];
            }
        }
        assembly ("memory-safe") {
            mstore(bounds, kept)
        }
    }

    /// @dev The value offset at which a moving leg reaches its target, rounded up to the grid,
    ///      or 0 if it starts at or past it. A rising leg (`tokenIn`) reaches its target from
    ///      below; a falling leg (`tokenOut`) from above.
    function _kink(Basket memory basket, uint256 leg, bool rising) internal pure returns (uint256) {
        uint256 heldScaled = basket.values[leg] * ONE;
        uint256 wantedScaled = basket.targets[leg] * basket.total;
        if (rising) {
            return heldScaled < wantedScaled ? Math.ceilDiv(wantedScaled - heldScaled, ONE) : 0;
        }
        return heldScaled > wantedScaled ? Math.ceilDiv(heldScaled - wantedScaled, ONE) : 0;
    }

    /// @dev The marginal spread on the piece that starts at `p`: whether each moving leg is
    ///      moving toward or away from its target just past `p`. A leg exactly at its target
    ///      at `p` moves away from it immediately after.
    function _rateFrom(Basket memory basket, uint256 p) internal pure returns (uint256) {
        bool inToward = (basket.values[basket.legIn] + p) * ONE < basket.targets[basket.legIn] * basket.total;
        bool outToward = (basket.values[basket.legOut] - p) * ONE > basket.targets[basket.legOut] * basket.total;
        if (inToward && outToward) {
            return SPREAD_TOWARD;
        }
        if (inToward || outToward) {
            return SPREAD_MIXED;
        }
        return SPREAD_AWAY;
    }
}
