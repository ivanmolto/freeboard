// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

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

/// @title MultiTokenForkTest — T21
/// @notice Three tokens, one strategy, one ship. A single Aqua strategy over WETH / WBTC / USDC,
///         shipped once, quotes and fills EVERY pair of its legs on the DEPLOYED AquaSwapVMRouter,
///         each fill priced against the same target weights from one health-factor read, with
///         the leg that is neither `tokenIn` nor `tokenOut` read from Aqua every time.
///
/// @dev THE XD PATH. swap-vm's README names two AMM shapes, "2D" and "XD"
///      (swap-vm v1.0.2 `README.md:163`, "AMM STRATEGIES (2D/XD Bidirectional, Two Balance
///      Options)"): a 2D instruction assumes an order over exactly two tokens
///      (`_xycConcentrateGrowLiquidity2D`, `_peggedSwapGrowPriceRange2D`), an XD instruction is
///      pair-agnostic and works over whatever pair the taker names. Nothing in an Aqua order
///      names its tokens — `MakerTraitsLib.Args` (`MakerTraits.sol:72-92`) carries a maker, flags,
///      hooks and the program, no token list — so the strategy's token SET lives in Aqua alone:
///      `ship()` stores every listed token under one hash with `tokensCount = tokens.length`
///      (`Aqua.sol:39-51`), and the router keys the pair it preloads by `(maker, this, orderHash,
///      tokenIn, tokenOut)` (`SwapVM.sol:193-194`). So one shipped strategy serves any pair of
///      its legs, and the extruction — an XD instruction in that sense — reads the rest of the
///      basket from Aqua by the same key. That is the path this test walks, on all three pairs,
///      in both directions.
///
/// @dev THE FIXTURE is T14's: Alice at HF 1.60 (40 / 24 / 36) with 10 WETH, 0.3 WBTC and
///      30,000 USDC shipped — about 31.5% / 30.6% / 37.9% at the pin, so WETH is under its
///      target and both WBTC and USDC are over. That makes the six directed pairs land in every
///      spread regime the schedule has: WETH in with WBTC or USDC out is toward on both legs,
///      WBTC or USDC in with WETH out is away on both, and WBTC against USDC is mixed. Each is
///      asserted to the wei against `PricingReference` evaluated with ONE target vector.
///
/// @dev WHY THE MISMATCH IS PROVED HERE AND NOT ONLY IN `test/unit/Pricing.t.sol`. The unit test
///      sets `rawBalances` answers on a mock; this one ships real token sets to the DEPLOYED
///      Aqua and shows the two layers that refuse them: the router's own `safeBalances` for a
///      swapped token outside the strategy (`SafeBalancesForTokenNotInActiveStrategy`,
///      `Aqua.sol:31`), and the extruction for a committed leg the strategy does not hold
///      (`FreeboardLegNotInStrategy`) or a set of the wrong size (`FreeboardStrategyLegCountMismatch`).
///      The deployed `rawBalances` does NOT revert for an unknown token — it answers `(0, 0)`
///      (`Aqua.sol:26-28`) — so the revert the design requires is the extruction's, and a test
///      that trusts the mock's `(0, 0)` has not shown the real contract answers the same.
contract MultiTokenForkTest is Test {
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant WETH = Addresses.WETH;
    address internal constant WBTC = Addresses.WBTC;
    address internal constant USDC = Addresses.USDC;
    address internal constant DAI = Addresses.DAI;

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

    /// @dev Every fill moves about this much value: 1,000 USD in the extruction's value units
    ///      (the oracle's 1e8 per USD, scaled to 18 decimals), so the same size is used whatever
    ///      the in token, and it is well under the 500 bps cap on a basket worth tens of
    ///      thousands.
    uint256 internal constant FILL_VALUE = 1000 * 1e8 * 1e18;

    bytes internal constant INSTRUCTIONS_ARGS = hex"c0ffee";

    address internal alice;
    address internal taker;
    address internal aWeth;
    address internal vDebtUsdc;
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

        IAaveProtocolDataProvider dataProvider = IAaveProtocolDataProvider(PROVIDER.getPoolDataProvider());
        (aWeth,,) = dataProvider.getReserveTokensAddresses(WETH);
        (,, vDebtUsdc) = dataProvider.getReserveTokensAddresses(USDC);
        oracle = IAaveV3Oracle(PROVIDER.getPriceOracle());

        freeboard = new FreeboardExtruction();
        alice = makeAddr("alice");
        taker = makeAddr("freeboard-taker");

        _openAavePosition(alice, HF_TARGET);
        position = _position(alice);
        _ship(alice, position, Curves.freeboardTokens(), _amounts3(SHIPPED_WETH, SHIPPED_WBTC, SHIPPED_USDC));

        // The taker holds and approves all three, so any direction can settle.
        deal(WETH, taker, 100 ether);
        deal(WBTC, taker, 10e8);
        deal(USDC, taker, 1_000_000e6);
        vm.startPrank(taker);
        IERC20(WETH).approve(ROUTER, type(uint256).max);
        IERC20(WBTC).approve(ROUTER, type(uint256).max);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.stopPrank();

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
        vm.label(DAI, "DAI");
    }

    /// @dev A real Aave position at `targetHf`: WETH collateral, USDC variable debt (T14).
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

    /// @dev THE Freeboard program for `maker`: the same curve, the same three committed tokens,
    ///      the same cap, whoever ships it. What differs between makers is only the order's
    ///      `maker` field — and therefore the strategy hash.
    function _position(address maker) internal view returns (ProgramBuilder.Position memory) {
        return ProgramBuilder.freeboardPosition(
            maker, address(freeboard), Curves.freeboard(), Curves.freeboardTokens(), MAX_SHIFT_BPS
        );
    }

    /// @dev Ships `tokens` / `amounts` under `pos` for `maker` and approves Aqua for each — the
    ///      allowance, not the shipped amounts, is what makes a position fillable. The token
    ///      list is a PARAMETER here, deliberately: the mismatch test ships sets that are not
    ///      the program's.
    function _ship(
        address maker,
        ProgramBuilder.Position memory pos,
        address[] memory tokens,
        uint256[] memory amounts
    )
        internal
    {
        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(tokens[i], maker, amounts[i]);
        }
        vm.startPrank(maker);
        bytes32 shippedHash = IAqua(AQUA).ship(ROUTER, pos.strategy, tokens, amounts);
        for (uint256 i = 0; i < tokens.length; ++i) {
            IERC20(tokens[i]).approve(AQUA, amounts[i]);
        }
        vm.stopPrank();

        assertEq(shippedHash, pos.strategyHash, "ship() did not return keccak256(strategy)");
        assertEq(ISwapVM(ROUTER).hash(pos.order), pos.strategyHash, "router hash != shipped strategy hash");
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

    function _quote(
        ProgramBuilder.Position memory pos,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    )
        internal
        returns (uint256 amountOut)
    {
        vm.prank(taker);
        (, amountOut,) = ISwapVM(ROUTER).quote(pos.order, tokenIn, tokenOut, amountIn, _takerTraitsAndData());
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        vm.prank(taker);
        (, amountOut,) = ISwapVM(ROUTER).swap(position.order, tokenIn, tokenOut, amountIn, _takerTraitsAndData());
    }

    // -----------------------------------------------------------------------------------
    // The basket, as the test sees it — by leg index, so any pair is one call
    // -----------------------------------------------------------------------------------

    /// @dev Leg index in curve order, the order `Curves.freeboardTokens` commits.
    function _leg(address token) internal pure returns (uint256) {
        if (token == WETH) {
            return 0;
        }
        if (token == WBTC) {
            return 1;
        }
        if (token == USDC) {
            return 2;
        }
        revert("not a basket leg");
    }

    /// @dev The third leg: the one that is neither `tokenIn` nor `tokenOut`.
    function _other(address tokenIn, address tokenOut) internal pure returns (address) {
        address[] memory tokens = Curves.freeboardTokens();
        for (uint256 l = 0; l < 3; ++l) {
            if (tokens[l] != tokenIn && tokens[l] != tokenOut) {
                return tokens[l];
            }
        }
        revert("no third leg");
    }

    /// @dev Value units per wei, as the extruction defines them: price scaled to 18 decimals.
    function _unit(address token) internal view returns (uint256) {
        uint256 decimals = token == WETH ? 18 : token == WBTC ? 8 : 6;
        return oracle.getAssetPrice(token) * 10 ** (18 - decimals);
    }

    /// @dev The largest whole amount of `token` worth at most `FILL_VALUE`.
    function _fillAmount(address token) internal view returns (uint256) {
        return FILL_VALUE / _unit(token);
    }

    /// @dev `Curve.weightsAt` reads calldata.
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }

    /// @dev The three legs' balances Aqua holds under Alice's strategy now — through
    ///      `safeBalances`, NOT `rawBalances`, so the test's own reads are never mistaken for
    ///      the extruction's under the counted `expectCall`s below.
    function _liveBalances() internal view returns (uint256[] memory balances) {
        balances = new uint256[](3);
        (balances[0], balances[1]) = IAqua(AQUA).safeBalances(alice, ROUTER, position.strategyHash, WETH, WBTC);
        (, balances[2]) = IAqua(AQUA).safeBalances(alice, ROUTER, position.strategyHash, WETH, USDC);
    }

    /// @dev The three legs' values, at the oracle.
    function _liveValues() internal view returns (uint256[] memory values) {
        address[] memory tokens = Curves.freeboardTokens();
        uint256[] memory balances = _liveBalances();
        values = new uint256[](3);
        for (uint256 l = 0; l < 3; ++l) {
            values[l] = balances[l] * _unit(tokens[l]);
        }
    }

    /// @dev Arms the counted expectations for `fills` fills through the router: the health
    ///      factor read once per fill, for Alice; each leg read from Aqua's `rawBalances` once
    ///      per fill in which it is the third leg — `thirdReads` times — and never otherwise,
    ///      because the swapped pair reaches the extruction in the registers the router
    ///      preloaded. Counted `expectCall`s are exact and may be set once per calldata, so
    ///      they are set here, once, for the whole sequence.
    function _expectReads(uint64 fills, uint64 thirdReads) internal {
        vm.expectCall(Addresses.AAVE_V3_POOL, abi.encodeCall(IAaveV3Pool.getUserAccountData, (alice)), fills);
        address[] memory tokens = Curves.freeboardTokens();
        for (uint256 l = 0; l < 3; ++l) {
            vm.expectCall(
                AQUA, abi.encodeCall(IAqua.rawBalances, (alice, ROUTER, position.strategyHash, tokens[l])), thirdReads
            );
        }
    }

    /// @dev The reference price of selling `amountIn` of `tokenIn` for `tokenOut` against
    ///      `values` at targets `w`, by the integral form — the same two-leg rule for any pair,
    ///      with the third leg entering only through `total`.
    function _reference(
        uint256[] memory values,
        uint256[] memory w,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    )
        internal
        view
        returns (uint256 amountOut, uint256 fairOut)
    {
        uint256 i = _leg(tokenIn);
        uint256 o = _leg(tokenOut);
        uint256 total = values[0] + values[1] + values[2];
        uint256 x = amountIn * _unit(tokenIn);
        amountOut = PricingReference.outValue(values[i], values[o], w[i], w[o], total, x) / _unit(tokenOut);
        fairOut = x / _unit(tokenOut);
    }

    function _amounts3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](3);
        amounts[0] = a;
        amounts[1] = b;
        amounts[2] = c;
    }

    // -----------------------------------------------------------------------------------
    // THE DoD: one shipped strategy quotes all three pairs against one set of targets
    // -----------------------------------------------------------------------------------

    /// @notice Six directed pairs, one strategy hash, one target vector. Six quotes make
    ///         exactly six health-factor reads — one each, for Alice — and read each leg from
    ///         Aqua exactly twice: once per quote in which it is the third leg, never as a
    ///         swapped leg (the router preloaded those). Every quote lands to the wei on the
    ///         reference evaluated at the SAME targets. `quote()` is `view` (`ISwapVM.sol:38-44`),
    ///         so nothing here can move a leg or the debt.
    function test_OneShip_QuotesAllThreePairs_FromOneHealthFactorRead() public {
        uint256 hf = _poolHealthFactor(alice);
        assertApproxEqAbs(hf, HF_TARGET, HF_TOLERANCE, "alice is at HF 1.60");
        uint256[] memory w = this.weightsAt(Curves.freeboard(), hf);
        assertApproxEqAbs(w[0], 0.4e18, 1e12, "target WETH at HF 1.60");
        assertApproxEqAbs(w[1], 0.24e18, 1e12, "target WBTC at HF 1.60");
        assertApproxEqAbs(w[2], 0.36e18, 1e12, "target USDC at HF 1.60");

        uint256[] memory values = _liveValues();
        uint256 total = values[0] + values[1] + values[2];
        assertLt(values[0] * ONE, w[0] * total, "fixture: WETH under target");
        assertGt(values[1] * ONE, w[1] * total, "fixture: WBTC over target");
        assertGt(values[2] * ONE, w[2] * total, "fixture: USDC over target");
        // ...and each by more than one fill moves, so no fill below crosses a target and the
        // marginal spread is one constant along every move — which is what makes the regime
        // assertions inside the loop exact.
        assertGt(w[0] * total - values[0] * ONE, FILL_VALUE * ONE, "fixture: WETH's shortfall exceeds a fill");
        assertGt(values[1] * ONE - w[1] * total, FILL_VALUE * ONE, "fixture: WBTC's excess exceeds a fill");
        assertGt(values[2] * ONE - w[2] * total, FILL_VALUE * ONE, "fixture: USDC's excess exceeds a fill");

        // Six quotes: six HF reads; each leg is the third leg of exactly two directed pairs.
        _expectReads(6, 2);

        address[] memory tokens = Curves.freeboardTokens();
        for (uint256 i = 0; i < 3; ++i) {
            for (uint256 o = 0; o < 3; ++o) {
                if (i == o) {
                    continue;
                }
                address tokenIn = tokens[i];
                address tokenOut = tokens[o];
                uint256 amountIn = _fillAmount(tokenIn);

                (uint256 referenceOut, uint256 fairOut) = _reference(values, w, tokenIn, tokenOut, amountIn);
                uint256 quotedOut = _quote(position, tokenIn, tokenOut, amountIn);

                assertEq(quotedOut, referenceOut, "quote != the reference at the shared targets");
                assertGt(quotedOut, 0, "every pair is quotable");
                assertLt(quotedOut, fairOut, "no fill beats the oracle");

                // The regime each pair lands in, from the basket's shape above. WETH in is
                // toward on both legs; WETH out is away on both; WBTC against USDC is mixed.
                // The fixture checks above bound every fill under its leg's gap to target, so
                // the marginal spread is one constant along the move.
                uint256 kept = fairOut - quotedOut;
                if (tokenIn == WETH) {
                    _assertSpreadIs(kept, fairOut, PricingReference.TOWARD, "WETH in: toward");
                } else if (tokenOut == WETH) {
                    _assertSpreadIs(kept, fairOut, PricingReference.AWAY, "WETH out: away");
                } else {
                    _assertSpreadIs(kept, fairOut, PricingReference.MIXED, "WBTC vs USDC: mixed");
                }
            }
        }
    }

    /// @dev `kept / fair` is the average spread over the move: `rate`, within the rounding of
    ///      three integer steps. With `A = x / unitOut` and `B = (x - ceil(S)) / unitOut` as
    ///      reals, `kept = floor(A) - floor(B)` lies within one unit of `A - B`, `A - B` lies
    ///      within a unit above `rate * A`, and `expected = floor(floor(A) * rate)` lies within
    ///      about a unit below `rate * A`; so `kept - expected` is in `[-1, 2]`.
    function _assertSpreadIs(uint256 kept, uint256 fairOut, uint256 rate, string memory why) internal pure {
        uint256 expected = fairOut * rate / ONE;
        assertGe(kept + 1, expected, why);
        assertLe(kept, expected + 2, why);
    }

    // -----------------------------------------------------------------------------------
    // Every leg settles: three fills, each pair once, real tokens on all three
    // -----------------------------------------------------------------------------------

    /// @notice One ship, three fills that between them move every token in and every token out:
    ///         WETH -> USDC, WBTC -> WETH, USDC -> WBTC. Each fill is quoted to the wei against
    ///         the reference at the basket Aqua holds at that moment, swaps at the quote, moves
    ///         real ERC-20s on both sides, leaves the third token untouched for both parties, and
    ///         leaves Aqua's three legs accounted to the wei.
    function test_OneShip_FillsEveryPair_OnTheDeployedRouter() public {
        uint256 hf = _poolHealthFactor(alice);
        uint256[] memory w = this.weightsAt(Curves.freeboard(), hf);
        uint256 aWethBefore = IERC20(aWeth).balanceOf(alice);
        uint256 debtBefore = IERC20(vDebtUsdc).balanceOf(alice);

        address[3] memory ins = [WETH, WBTC, USDC];
        address[3] memory outs = [USDC, WETH, WBTC];
        uint256[3] memory aqua = [SHIPPED_WETH, SHIPPED_WBTC, SHIPPED_USDC];
        uint256 spreadKeptValue;

        // Three quotes and three swaps: six HF reads; each leg is the third leg of one pair,
        // so it is read from Aqua once by that pair's quote and once by its swap.
        _expectReads(6, 2);

        for (uint256 k = 0; k < 3; ++k) {
            address tokenIn = ins[k];
            address tokenOut = outs[k];
            address third = _other(tokenIn, tokenOut);
            uint256 amountIn = _fillAmount(tokenIn);

            (uint256 referenceOut, uint256 fairOut) = _reference(_liveValues(), w, tokenIn, tokenOut, amountIn);
            uint256 quotedOut = _quote(position, tokenIn, tokenOut, amountIn);
            assertEq(quotedOut, referenceOut, "quote != the reference from live balances");

            uint256 takerInBefore = IERC20(tokenIn).balanceOf(taker);
            uint256 takerOutBefore = IERC20(tokenOut).balanceOf(taker);
            uint256 takerThirdBefore = IERC20(third).balanceOf(taker);
            uint256 aliceInBefore = IERC20(tokenIn).balanceOf(alice);
            uint256 aliceOutBefore = IERC20(tokenOut).balanceOf(alice);
            uint256 aliceThirdBefore = IERC20(third).balanceOf(alice);

            uint256 swappedOut = _swap(tokenIn, tokenOut, amountIn);
            assertEq(swappedOut, quotedOut, "swap() != quote()");

            assertEq(takerInBefore - IERC20(tokenIn).balanceOf(taker), amountIn, "taker paid tokenIn");
            assertEq(IERC20(tokenOut).balanceOf(taker) - takerOutBefore, swappedOut, "taker received tokenOut");
            assertEq(IERC20(third).balanceOf(taker), takerThirdBefore, "taker's third token untouched");
            assertEq(IERC20(tokenIn).balanceOf(alice) - aliceInBefore, amountIn, "alice received tokenIn");
            assertEq(aliceOutBefore - IERC20(tokenOut).balanceOf(alice), swappedOut, "alice paid tokenOut");
            assertEq(IERC20(third).balanceOf(alice), aliceThirdBefore, "alice's third token untouched");

            aqua[_leg(tokenIn)] += amountIn;
            aqua[_leg(tokenOut)] -= swappedOut;
            uint256[] memory live = _liveBalances();
            for (uint256 l = 0; l < 3; ++l) {
                assertEq(live[l], aqua[l], "Aqua leg after the fill");
            }

            spreadKeptValue += (fairOut - swappedOut) * _unit(tokenOut);
            emit log_named_decimal_uint("fill: fair out", fairOut, tokenOut == WETH ? 18 : tokenOut == WBTC ? 8 : 6);
            emit log_named_decimal_uint("fill: paid out", swappedOut, tokenOut == WETH ? 18 : tokenOut == WBTC ? 8 : 6);
        }

        // Every fill was a read of Alice's Aave position, never a write: her collateral and
        // her debt, in Aave's own tokens, are where they were. (Freeboard never touches the
        // debt — CLAUDE.md, "WHAT FREEBOARD NEVER DOES".)
        assertEq(IERC20(aWeth).balanceOf(alice), aWethBefore, "a fill moved alice's Aave collateral");
        assertEq(IERC20(vDebtUsdc).balanceOf(alice), debtBefore, "a fill moved alice's Aave debt");
        assertEq(IERC20(WETH).balanceOf(ROUTER), 0, "router retains no WETH");
        assertEq(IERC20(WBTC).balanceOf(ROUTER), 0, "router retains no WBTC");
        assertEq(IERC20(USDC).balanceOf(ROUTER), 0, "router retains no USDC");
        assertGt(spreadKeptValue, 0, "alice was paid a spread on every fill");
        emit log_named_decimal_uint("spread kept by alice over three fills, USD", spreadKeptValue / 1e18, 8);
    }

    // -----------------------------------------------------------------------------------
    // The committed token list must be the shipped token set
    // -----------------------------------------------------------------------------------

    /// @notice The same program, shipped by three makers with three token sets that are not the
    ///         program's, is refused on every pair — by the router where the swapped token is
    ///         outside the strategy, and by the extruction where a committed leg is missing or
    ///         the set is the wrong size. In no case is a price produced.
    function test_RevertWhen_ArgsTokensAreNotTheShippedTokenSet() public {
        // Sized up front: `_fillAmount` reads the oracle, and a call between `expectRevert`
        // and the quote would be the call the expectation attaches to.
        uint256 amountIn = _fillAmount(WETH);
        uint256 wbtcIn = _fillAmount(WBTC);

        // -- (a) Fewer: bob ships WETH / USDC under the three-leg program. -------------------
        address bob = makeAddr("bob");
        ProgramBuilder.Position memory two = _position(bob);
        address[] memory twoTokens = new address[](2);
        twoTokens[0] = WETH;
        twoTokens[1] = USDC;
        uint256[] memory twoAmounts = new uint256[](2);
        twoAmounts[0] = SHIPPED_WETH;
        twoAmounts[1] = SHIPPED_USDC;
        _ship(bob, two, twoTokens, twoAmounts);

        // The pair IS shipped, so the router preloads it; the extruction then asks Aqua for
        // WBTC, gets `(0, 0)`, and refuses by name.
        vm.expectRevert(
            abi.encodeWithSelector(FreeboardExtruction.FreeboardLegNotInStrategy.selector, bob, two.strategyHash, WBTC)
        );
        _quote(two, WETH, USDC, amountIn);

        // A pair that names the missing token never reaches the program: the router's own
        // preload refuses it.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAqua.SafeBalancesForTokenNotInActiveStrategy.selector, bob, ROUTER, two.strategyHash, WBTC
            )
        );
        _quote(two, WBTC, USDC, wbtcIn);

        // -- (b) More: carol ships WETH / WBTC / USDC / DAI under the same program. ----------
        address carol = makeAddr("carol");
        ProgramBuilder.Position memory four = _position(carol);
        address[] memory fourTokens = new address[](4);
        fourTokens[0] = WETH;
        fourTokens[1] = WBTC;
        fourTokens[2] = USDC;
        fourTokens[3] = DAI;
        uint256[] memory fourAmounts = new uint256[](4);
        fourAmounts[0] = SHIPPED_WETH;
        fourAmounts[1] = SHIPPED_WBTC;
        fourAmounts[2] = SHIPPED_USDC;
        fourAmounts[3] = 30_000e18;
        _ship(carol, four, fourTokens, fourAmounts);

        // Every committed leg is there, but `tokensCount` is 4 against a three-leg curve: the
        // committed list cannot be the strategy's set, so the extruction refuses.
        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardStrategyLegCountMismatch.selector, 3, 4));
        _quote(four, WETH, USDC, amountIn);

        // The uncommitted fourth token is shipped, so the router preloads it — and the
        // extruction still refuses, on the first leg it reads from Aqua.
        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardStrategyLegCountMismatch.selector, 3, 4));
        _quote(four, DAI, USDC, 1000e18);

        // -- (c) Different: dave ships WETH / WBTC / DAI — three tokens, one of them wrong. ---
        address dave = makeAddr("dave");
        ProgramBuilder.Position memory swapped = _position(dave);
        address[] memory swappedTokens = new address[](3);
        swappedTokens[0] = WETH;
        swappedTokens[1] = WBTC;
        swappedTokens[2] = DAI;
        _ship(dave, swapped, swappedTokens, _amounts3(SHIPPED_WETH, SHIPPED_WBTC, 30_000e18));

        // The count matches; the set does not. USDC, committed, is not held.
        vm.expectRevert(
            abi.encodeWithSelector(
                FreeboardExtruction.FreeboardLegNotInStrategy.selector, dave, swapped.strategyHash, USDC
            )
        );
        _quote(swapped, WETH, WBTC, amountIn);

        // And DAI, held but not committed, cannot be traded either: the router preloads the
        // pair, the extruction walks the committed list and stops at the leg Aqua lacks.
        vm.expectRevert(
            abi.encodeWithSelector(
                FreeboardExtruction.FreeboardLegNotInStrategy.selector, dave, swapped.strategyHash, USDC
            )
        );
        _quote(swapped, WETH, DAI, amountIn);

        // The control: Alice's set IS the program's, and the same pair prices.
        assertGt(_quote(position, WETH, USDC, amountIn), 0, "the matching set prices");
    }
}
