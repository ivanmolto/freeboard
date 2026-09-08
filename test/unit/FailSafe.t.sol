// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { FreeboardExtruction } from "../../src/FreeboardExtruction.sol";
import { IAaveV3Oracle } from "../../src/interfaces/IAaveV3Oracle.sol";
import { IAaveV3Pool } from "../../src/interfaces/IAaveV3Pool.sol";
import { FreeboardArgs } from "../../src/libs/FreeboardArgs.sol";

import { Curves } from "../utils/Curves.sol";
import {
    MockAaveOracle,
    MockAaveV3Pool,
    MockAqua,
    MockPoolAddressesProvider,
    MockToken,
    MockUnreadableAaveV3Pool
} from "../utils/Mocks.sol";

/// @title FailSafeTest — T16
/// @notice An unreadable health factor must never become a price.
///
/// @dev THE RULE. If Aave cannot compute the maker's health factor, the fill REVERTS, by name,
///      carrying the maker. There is no try/catch, no default, no fallback row of the curve.
///      Aave's own `liquidationCall` reads the same oracle through the same
///      `calculateUserAccountData`, so while the health factor is unreadable no liquidation is
///      possible either: refusing to trade costs the borrower nothing, and a price computed from
///      a number Aave would not stand behind could cost them everything.
///
/// @dev WHY REVERT AND NOT CLAMP. Until Rev 4 the health factor reached the strategy from an
///      off-chain writer, and "clamp to the most conservative target" was the defence against
///      that writer going quiet — a stale target being safer than no target. The extruction now
///      reads Aave directly, inside the pricing path, in the same block as the fill; there is no
///      writer to go quiet, and a clamp would turn a broken oracle into a forced deleverage at
///      the bottom of the curve, priced as if it were the right thing to do. It is not: no
///      liquidation is possible in that state, so there is nothing to be late for.
///
/// @dev THE FIXTURE is `Pricing.t.sol`'s: the extruction deployed unmodified, the four things it
///      reads etched at the constant addresses it reads them from, prices WETH 2,000 /
///      WBTC 50,000 / USDC 1.00 so a fill's value is a whole number of wei of any token. Every
///      other read stays valid throughout, so the only thing that can refuse a fill here is the
///      health factor — and the same fill prices again the moment the pool is readable.
///
/// @dev THE DoD.
///        test_RevertWhen_HealthFactorUnreadable — against a reverting mock pool, both revert
///          shapes T8 found on mainnet, both paths (quote and swap), both sides (exact-in and
///          exact-out), both directions; nothing else is read; the same fill priced a moment
///          earlier with the pool readable, so the refusal is the read's alone.
///        test_NoDebt_PricesAtTopOfCurve — Aave's no-debt sentinel, `type(uint256).max`, is a
///          READ answer and not a failure: it prices at the top of the curve, exactly as HF 2.00
///          and every health factor above it do, and the top of the curve asks for no
///          deleveraging. Deliberate, and pinned to the wei.
contract FailSafeTest is Test {
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant POOL = Addresses.AAVE_V3_POOL;
    address internal constant ORACLE = Addresses.AAVE_V3_ORACLE;
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

    /// @dev The schedule's two ends: 10 bps toward, 100 bps away.
    uint256 internal constant TOWARD = 0.001e18;
    uint256 internal constant AWAY = 0.01e18;

    /// @dev The per-fill cap is off (twice the basket); it is T15's subject, not this file's.
    uint16 internal constant MAX_SHIFT_BPS = 20_000;

    /// @dev The two revert shapes T8 found on mainnet: no data (the zero-price fall-through to a
    ///      fallback oracle at `address(0)`), and a bubbled reason (a price source that reverts).
    bytes internal constant NO_DATA = "";
    bytes internal constant FEED_DOWN = "feed down";

    /// @dev The top breakpoint of the Freeboard curve, `Curves.freeboard()`.
    uint256 internal constant HF_TOP = 2e18;

    FreeboardExtruction internal freeboard;
    bytes internal args;

    /// @dev The unreadable pool's runtime code, etched over the readable one mid-test.
    bytes internal unreadablePool;

    address internal maker = makeAddr("freeboard-maker");
    address internal taker = makeAddr("freeboard-taker");
    bytes32 internal orderHash = keccak256("freeboard-unit-strategy");

    mapping(address => uint256) internal balance;
    address[3] internal legs = [WETH, WBTC, USDC];

    // -----------------------------------------------------------------------------------
    // Fixture
    // -----------------------------------------------------------------------------------

    function setUp() public {
        unreadablePool = address(new MockUnreadableAaveV3Pool()).code;

        vm.etch(POOL, address(new MockAaveV3Pool()).code);
        vm.etch(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER, address(new MockPoolAddressesProvider()).code);
        vm.etch(ORACLE, address(new MockAaveOracle()).code);
        vm.etch(AQUA, address(new MockAqua()).code);
        vm.etch(WETH, address(new MockToken(18)).code);
        vm.etch(WBTC, address(new MockToken(8)).code);
        vm.etch(USDC, address(new MockToken(6)).code);

        MockAaveOracle(ORACLE).setPrice(WETH, PRICE_WETH);
        MockAaveOracle(ORACLE).setPrice(WBTC, PRICE_WBTC);
        MockAaveOracle(ORACLE).setPrice(USDC, PRICE_USDC);

        freeboard = new FreeboardExtruction();
        args = FreeboardArgs.encode(Curves.freeboard(), Curves.freeboardTokens(), MAX_SHIFT_BPS);

        vm.label(address(freeboard), "FreeboardExtruction");
        vm.label(POOL, "AaveV3Pool");
        vm.label(WETH, "WETH");
        vm.label(WBTC, "WBTC");
        vm.label(USDC, "USDC");
    }

    function _setHealthFactor(uint256 hf) internal {
        MockAaveV3Pool(POOL).setHealthFactor(maker, hf);
    }

    /// @dev Replace the pool with one that cannot answer, reverting with `revertData`.
    function _makePoolUnreadable(bytes memory revertData) internal {
        vm.etch(POOL, unreadablePool);
        MockUnreadableAaveV3Pool(POOL).setRevertData(revertData);
    }

    /// @dev Token wei per leg, mirrored into the Aqua mock under the deployed router as app.
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
    ///      `share` (WAD), in wei of the token at the mock price.
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

    /// @dev The exact calldata `FreeboardExtruction._healthFactor` sends for `maker`.
    function _readOf(address who) internal pure returns (bytes memory) {
        return abi.encodeCall(IAaveV3Pool.getUserAccountData, (who));
    }

    function _unreadable(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(FreeboardExtruction.FreeboardHealthFactorUnreadable.selector, who);
    }

    /// @dev One call to `extruction()` with the registers the router would preload.
    function _fill(
        bool isStaticContext,
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
        (,, out) = freeboard.extruction(isStaticContext, 0, query, swap, args, "");
    }

    function _exactIn(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        return _fill(true, tokenIn, tokenOut, amountIn, true).amountOut;
    }

    /// @dev An external hop so `vm.expectRevert` has a call frame to catch.
    function fillExternal(
        bool isStaticContext,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool isExactIn
    )
        external
        view
        returns (uint256)
    {
        SwapRegisters memory out = _fill(isStaticContext, tokenIn, tokenOut, amount, isExactIn);
        return isExactIn ? out.amountOut : out.amountIn;
    }

    // -----------------------------------------------------------------------------------
    // THE DoD — an unreadable health factor is a refused fill
    // -----------------------------------------------------------------------------------

    /// @notice Against a pool that cannot compute the health factor, the fill reverts by name,
    ///         carrying the maker — whatever the pool said, on the quote path and the swap path,
    ///         exact-in and exact-out, in the direction that would deleverage and the one that
    ///         would not. Nothing else is read: the health factor is the first read and the
    ///         refusal stops the fill before the oracle or Aqua are touched. The same basket,
    ///         the same fill, prices the moment before the pool is broken, so the refusal is
    ///         the read's alone.
    /// @dev The basket sits on the HF 1.30 target ($30k / $16k / $54k), so at HF 1.30 every
    ///      fill is away and the price is one literal: $1,000 in, $990 out.
    function test_RevertWhen_HealthFactorUnreadable() public {
        _setBasket(_wei(WETH, 100_000, 0.3e18), _wei(WBTC, 100_000, 0.16e18), _wei(USDC, 100_000, 0.54e18));
        uint256 x = 1000 * USD;
        uint256 wethIn = x / UNIT_WETH;
        uint256 usdcOut = 990e6;

        // -- 0. Every other read is valid: with the pool readable, the fill prices. -----------
        _setHealthFactor(1.3e18);
        assertEq(_exactIn(WETH, USDC, wethIn), usdcOut, "the fixture must price before the pool is broken");

        // -- 1. The pool reverts with no data — the mainnet shape when a price is zero. --------
        _makePoolUnreadable(NO_DATA);

        // From here to the end of the test: the read is attempted, for query.maker, and nothing
        // after it happens — not one oracle price, not one Aqua leg. A counted expectation of
        // zero is an assertion that the call is NOT made, checked when the test ends.
        vm.expectCall(POOL, _readOf(maker));
        vm.expectCall(ORACLE, abi.encodeCall(IAaveV3Oracle.getAssetPrice, (WETH)), 0);
        vm.expectCall(ORACLE, abi.encodeCall(IAaveV3Oracle.getAssetPrice, (USDC)), 0);
        vm.expectCall(AQUA, abi.encodeCall(IAqua.rawBalances, (maker, ROUTER, orderHash, WBTC)), 0);

        vm.expectRevert(_unreadable(maker));
        this.fillExternal(true, WETH, USDC, wethIn, true);

        // The swap path: the same refusal, the same name.
        vm.expectRevert(_unreadable(maker));
        this.fillExternal(false, WETH, USDC, wethIn, true);

        // Exact-out, both paths.
        vm.expectRevert(_unreadable(maker));
        this.fillExternal(true, WETH, USDC, usdcOut, false);
        vm.expectRevert(_unreadable(maker));
        this.fillExternal(false, WETH, USDC, usdcOut, false);

        // The direction that would DELEVERAGE (collateral out, the debt asset in) is refused
        // just the same: there is no fallback target to price toward.
        vm.expectRevert(_unreadable(maker));
        this.fillExternal(false, USDC, WETH, 1000e6, true);

        // -- 2. The pool reverts with a reason — the shape when a price source itself reverts.
        //       The reason is the pool's business; the refusal is Freeboard's, by name. -------
        _makePoolUnreadable(FEED_DOWN);

        vm.expectRevert(_unreadable(maker));
        this.fillExternal(true, WETH, USDC, wethIn, true);
        vm.expectRevert(_unreadable(maker));
        this.fillExternal(false, WETH, USDC, wethIn, true);
    }

    // -----------------------------------------------------------------------------------
    // THE DoD — the no-debt sentinel is an answer, and the answer is the top of the curve
    // -----------------------------------------------------------------------------------

    /// @notice A maker with no Aave debt reads `type(uint256).max` — the sentinel Aave returns
    ///         for an empty account and for collateral with no debt alike (T8) — and it is NOT
    ///         a failure: the fill prices, at the top of the curve, to the same wei as HF 2.00
    ///         and as every health factor above it. And the top of the curve asks for no
    ///         deleveraging: on a basket shaped for HF 1.60, heavy in the debt asset, the fill
    ///         that brings collateral INTO the basket and takes the debt asset out is the cheap
    ///         one, and the fill that takes collateral OUT — the deleveraging fill — is the
    ///         expensive one. A leveraged maker at HF 1.60 or 1.30 is paid the away spread for
    ///         both.
    /// @dev The mock pool answers the sentinel for any account never set, as the real pool
    ///      does for an untouched one; the maker is never set here. Basket $40k / $24k / $36k —
    ///      on the HF 1.60 target (40 / 24 / 36), short of the top's 50 / 30 / 20 in WETH and
    ///      long in USDC. `tokenIn` is what the taker sells INTO the basket. $1,000 fills cross
    ///      no target, so each is one piece of the schedule: 10 bps toward, 100 bps away.
    function test_NoDebt_PricesAtTopOfCurve() public {
        _setBasket(_wei(WETH, 100_000, 0.4e18), _wei(WBTC, 100_000, 0.24e18), _wei(USDC, 100_000, 0.36e18));
        uint256 x = 1000 * USD;
        uint256 wethIn = x / UNIT_WETH;
        uint256 usdcIn = x / UNIT_USDC;

        // -- 0. The sentinel is what the pool answers, and the price comes from a read of it. --
        (,,,,, uint256 hf) = IAaveV3Pool(POOL).getUserAccountData(maker);
        assertEq(hf, type(uint256).max, "a maker with no debt must read the sentinel");

        vm.expectCall(POOL, _readOf(maker));
        uint256 outCollateralIn = _exactIn(WETH, USDC, wethIn);
        uint256 outCollateralOut = _exactIn(USDC, WETH, usdcIn);

        // -- 1. No debt, no deleveraging: the basket is pulled toward the loosest target. -----
        //       WETH in, USDC out (collateral into the basket) is toward: $999 of USDC.
        //       USDC in, WETH out (collateral out of the basket)  is away:   $990 of WETH.
        assertEq(outCollateralIn, 999_000_000, "no debt: collateral into the basket is toward, 10 bps");
        assertEq(outCollateralIn * UNIT_USDC, x - x * TOWARD / ONE, "no debt: exactly the toward schedule");
        assertEq(outCollateralOut, 495_000_000_000_000_000, "no debt: collateral out of the basket is away, 100 bps");
        assertEq(outCollateralOut * UNIT_WETH, x - x * AWAY / ONE, "no debt: exactly the away schedule");

        // -- 2. It is the top of the curve: the same wei as HF 2.00, the top breakpoint, and as
        //       any health factor above it. The clamp has no special case for the sentinel. --
        uint256[4] memory atOrAboveTop = [HF_TOP, 3e18, uint256(type(uint64).max), type(uint256).max - 1];
        for (uint256 i = 0; i < atOrAboveTop.length; ++i) {
            _setHealthFactor(atOrAboveTop[i]);
            assertEq(_exactIn(WETH, USDC, wethIn), outCollateralIn, "at or above the top breakpoint: the same price");
            assertEq(_exactIn(USDC, WETH, usdcIn), outCollateralOut, "at or above the top breakpoint: the same price");
        }

        // -- 3. And it is DISTINGUISHABLE from every leveraged row: at HF 1.60 the basket is on
        //       target and at HF 1.30 it is past it, so collateral into the basket is away at
        //       both. The sentinel did not price as the bottom of the curve, nor as "some" HF. --
        _setHealthFactor(1.6e18);
        assertEq(_exactIn(WETH, USDC, wethIn) * UNIT_USDC, x - x * AWAY / ONE, "HF 1.60: collateral in is away");
        assertEq(_exactIn(USDC, WETH, usdcIn), outCollateralOut, "HF 1.60: collateral out is away here too");

        _setHealthFactor(1.3e18);
        assertEq(_exactIn(WETH, USDC, wethIn) * UNIT_USDC, x - x * AWAY / ONE, "HF 1.30: collateral in is away");

        emit log_named_decimal_uint("no debt  ($1,000 WETH -> USDC)  USDC out", outCollateralIn, 6);
        emit log_named_decimal_uint("no debt  ($1,000 USDC -> WETH)  WETH out", outCollateralOut, 18);
    }
}
