// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
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
import { IAaveOracle, OracleWarp } from "../utils/OracleWarp.sol";
import { PricingReference } from "../utils/PricingReference.sol";
import { ProgramBuilder } from "../utils/ProgramBuilder.sol";

/// @title EndToEndForkTest — T22
/// @notice The whole story in one test, on the DEPLOYED AquaSwapVMRouter and the DEPLOYED Aqua,
///         against real Aave v3:
///
///           1. Alice has a real Aave position — WETH and WBTC collateral, USDC debt — at HF 2.00.
///           2. She ships a Freeboard basket through Aqua, her curve in the program.
///           3. A taker fills a toward-target trade. Real ERC-20s move. The composition moves.
///           4. The oracle falls. Her health factor falls.
///           5. The next fill prices against the NEW target — and nobody wrote anything between
///              4 and 5. The extruction read it.
///
/// @dev "NOBODY WROTE ANYTHING" IS ASSERTED, NOT NARRATED. A state-diff recording runs from just
///      before the oracle move to just after the first quote at the new health factor. Every
///      storage write in it must belong to the oracle move itself — `AaveOracle`, the ACL manager
///      that authorises it, and the two price sources it installs. Aqua, the router, the
///      extruction, the three tokens, Alice's aTokens and her debt token are written by no one.
///      The quote is a STATICCALL and could not write; the point is that nothing ELSE wrote
///      either: no keeper pushed a target, no owner set a parameter, no storage on the extruction
///      exists to set. The target moved because the extruction re-read the health factor, and
///      the counted `expectCall` on `getUserAccountData(alice)` pins that read to the fills.
///
/// @dev THE BASKET IS THE T14/T21 ONE — 10 WETH, 0.3 WBTC, 30,000 USDC — but its USDC leg is
///      the USDC Alice BORROWED: she ships thirty thousand of the debt asset she holds in her
///      wallet. Aqua takes no custody (`ship()` moves nothing), so her wallet is the leg, and
///      every fill's USDC delta lands on the balance her borrow created. Her variable-debt
///      balance never changes: Freeboard rebalances what her collateral is made of and never
///      touches the debt (CLAUDE.md, "WHAT FREEBOARD NEVER DOES").
///
/// @dev THE SHAPE OF THE STORY, IN NUMBERS. At HF 2.00 the curve says 50 / 30 / 20 and the
///      basket sits near 31.5 / 30.6 / 37.9: WETH is under, USDC is over, so selling WETH into
///      the basket for USDC is toward on both legs — the step-3 fill, at 10 bps. Cutting both
///      collateral prices by 35% lands Alice on HF 1.30, where the curve says 30 / 16 / 54, and
///      revalues the basket to about 29 / 26 / 45: now USDC is UNDER and WBTC is OVER. The very
///      same WETH-for-USDC fill is no longer toward, and the deleveraging fill — a taker paying
///      USDC to take WBTC out of the basket — is. That flip is the product: the borrower's
///      basket rebalances toward the debt asset as her margin thins, and a taker pays her a
///      spread to do it.
contract EndToEndForkTest is Test {
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
    uint256 internal constant HF_TOLERANCE = 1e12;

    /// @dev T8's three-reserve position: ~$250k of WETH and ~$243k of WBTC at the pin.
    uint256 internal constant AAVE_WETH_COLLATERAL = 100e18;
    uint256 internal constant AAVE_WBTC_COLLATERAL = 3e8;
    uint256 internal constant HF_START = 2.0e18;
    uint256 internal constant HF_AFTER = 1.3e18;

    uint256 internal constant SHIPPED_WETH = 10 ether;
    uint256 internal constant SHIPPED_WBTC = 0.3e8;
    uint256 internal constant SHIPPED_USDC = 30_000e6;
    uint16 internal constant MAX_SHIFT_BPS = 500;

    /// @dev Step 3: the taker sells 1 WETH into the basket for USDC.
    uint256 internal constant REBALANCE_IN = 1 ether;
    /// @dev Step 5: the taker pays 1,000 USDC into the basket and takes WBTC out.
    uint256 internal constant DELEVERAGE_IN = 1000e6;

    bytes internal constant INSTRUCTIONS_ARGS = hex"c0ffee";

    address internal alice;
    address internal taker;
    address internal aWeth;
    address internal aWbtc;
    address internal vDebtUsdc;
    IAaveV3Oracle internal oracle;

    FreeboardExtruction internal freeboard;
    ProgramBuilder.Position internal position;

    /// @dev What Alice's borrow put in her wallet — the USDC her basket's third leg is made of.
    uint256 internal borrowed;

    // -----------------------------------------------------------------------------------
    // Fixture: the fork, the contracts, the taker. Alice's story starts in the test.
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
        (aWbtc,,) = dataProvider.getReserveTokensAddresses(WBTC);
        (,, vDebtUsdc) = dataProvider.getReserveTokensAddresses(USDC);
        oracle = IAaveV3Oracle(PROVIDER.getPriceOracle());
        assertEq(address(oracle), Addresses.AAVE_V3_ORACLE, "the provider names the pinned oracle");

        freeboard = new FreeboardExtruction();
        alice = makeAddr("alice");
        taker = makeAddr("freeboard-taker");

        // The taker holds WETH to sell in step 3 and USDC to pay in step 5, and can settle both.
        deal(WETH, taker, 10 ether);
        deal(USDC, taker, 100_000e6);
        vm.startPrank(taker);
        IERC20(WETH).approve(ROUTER, type(uint256).max);
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
    }

    // -----------------------------------------------------------------------------------
    // THE DoD
    // -----------------------------------------------------------------------------------

    /// @notice Steps 1 to 5, each with its balance deltas asserted, and step 5 with a state-diff
    ///         recording proving the only storage written since the fill before it is the
    ///         oracle's own.
    function test_EndToEnd_TheNextFillPricesAgainstTheNewTarget_WithNobodyWritingInBetween() public {
        // ===================================================================================
        // 1. Alice has a real Aave v3 position: WETH + WBTC collateral, USDC debt, HF 2.00.
        // ===================================================================================
        assertEq(IERC20(aWeth).balanceOf(alice), 0, "alice starts with no Aave position");
        assertEq(IERC20(vDebtUsdc).balanceOf(alice), 0, "alice starts with no Aave debt");
        assertEq(IERC20(USDC).balanceOf(alice), 0, "alice starts with no USDC");

        _supply(alice, WETH, AAVE_WETH_COLLATERAL);
        _supply(alice, WBTC, AAVE_WBTC_COLLATERAL);
        borrowed = _borrowToHealthFactor(alice, HF_START);

        uint256 hfStart = _poolHealthFactor(alice);
        assertApproxEqAbs(hfStart, HF_START, HF_TOLERANCE, "step 1: alice is at HF 2.00");
        // Real deltas: the collateral left her wallet for Aave, the borrow arrived in it.
        assertEq(IERC20(WETH).balanceOf(alice), 0, "step 1: her WETH is in Aave");
        assertEq(IERC20(WBTC).balanceOf(alice), 0, "step 1: her WBTC is in Aave");
        assertApproxEqAbs(IERC20(aWeth).balanceOf(alice), AAVE_WETH_COLLATERAL, 1, "step 1: aWETH minted");
        assertApproxEqAbs(IERC20(aWbtc).balanceOf(alice), AAVE_WBTC_COLLATERAL, 1, "step 1: aWBTC minted");
        // A debt balance is a scaled balance times a ray index (`rayMul`), so it reads a couple
        // of wei above the amount borrowed; the deltas below are exact, this one is Aave's.
        assertApproxEqAbs(IERC20(vDebtUsdc).balanceOf(alice), borrowed, 2, "step 1: variable debt minted");
        assertEq(IERC20(USDC).balanceOf(alice), borrowed, "step 1: the borrowed USDC is in her wallet");
        assertGt(borrowed, SHIPPED_USDC, "step 1: she borrowed more than the basket's USDC leg");

        uint256 aWethAtStart = IERC20(aWeth).balanceOf(alice);
        uint256 aWbtcAtStart = IERC20(aWbtc).balanceOf(alice);
        uint256 debtAtStart = IERC20(vDebtUsdc).balanceOf(alice);

        emit log_string("== 1. alice's Aave position ==");
        emit log_named_decimal_uint("  HF", hfStart, 18);
        emit log_named_decimal_uint("  USDC borrowed", borrowed, 6);

        // ===================================================================================
        // 2. She ships a Freeboard basket through Aqua with her curve in the program.
        // ===================================================================================
        position = ProgramBuilder.freeboardPosition(
            alice, address(freeboard), Curves.freeboard(), Curves.freeboardTokens(), MAX_SHIFT_BPS
        );

        // 10 WETH and 0.3 WBTC she holds outside Aave, and 30,000 of the USDC she borrowed.
        deal(WETH, alice, SHIPPED_WETH);
        deal(WBTC, alice, SHIPPED_WBTC);
        _ship(alice);

        // Shipping moves nothing (VERIFIED FACTS: `ship()` succeeds with zero allowance and
        // consumes it only on a fill). Her wallet is the basket.
        assertEq(IERC20(WETH).balanceOf(alice), SHIPPED_WETH, "step 2: ship() moved no WETH");
        assertEq(IERC20(WBTC).balanceOf(alice), SHIPPED_WBTC, "step 2: ship() moved no WBTC");
        assertEq(IERC20(USDC).balanceOf(alice), borrowed, "step 2: ship() moved no USDC");
        uint256[] memory shipped = _liveBalances();
        assertEq(shipped[0], SHIPPED_WETH, "step 2: Aqua accounts the WETH leg");
        assertEq(shipped[1], SHIPPED_WBTC, "step 2: Aqua accounts the WBTC leg");
        assertEq(shipped[2], SHIPPED_USDC, "step 2: Aqua accounts the USDC leg");
        for (uint256 l = 0; l < 3; ++l) {
            (, uint8 tokensCount) =
                IAqua(AQUA).rawBalances(alice, ROUTER, position.strategyHash, Curves.freeboardTokens()[l]);
            assertEq(tokensCount, 3, "step 2: the strategy holds exactly the three committed legs");
        }

        emit log_string("== 2. shipped through Aqua ==");
        emit log_named_bytes32("  strategy hash", position.strategyHash);

        // ===================================================================================
        // 3. A taker fills a toward-target trade; real ERC-20 transfers; composition moves.
        // ===================================================================================
        uint256[] memory wStart = this.weightsAt(Curves.freeboard(), hfStart);
        assertApproxEqAbs(wStart[0], 0.5e18, 1e12, "target WETH at HF 2.00");
        assertApproxEqAbs(wStart[1], 0.3e18, 1e12, "target WBTC at HF 2.00");
        assertApproxEqAbs(wStart[2], 0.2e18, 1e12, "target USDC at HF 2.00");

        uint256[] memory values = _liveValues();
        uint256 total = _sum(values);
        uint256 x3 = REBALANCE_IN * _unit(WETH);
        // WETH under target and USDC over, each by more than the fill: the fill is toward on
        // both legs the whole way, so its spread is exactly the 10 bps of the schedule.
        assertGt(wStart[0] * total, values[0] * ONE + x3 * ONE, "fixture: WETH's shortfall exceeds the fill");
        assertGt(values[2] * ONE, wStart[2] * total + x3 * ONE, "fixture: USDC's excess exceeds the fill");
        _logShares("== 3. before the toward-target fill ==", values, wStart);

        (uint256 reference3, uint256 fair3) = _reference(values, wStart, WETH, USDC, REBALANCE_IN);
        uint256 quoted3 = _quote(WETH, USDC, REBALANCE_IN);
        assertEq(quoted3, reference3, "step 3: quote != the reference at HF 2.00's targets");
        _assertSpreadIs(fair3 - quoted3, fair3, PricingReference.TOWARD, "step 3: toward on both legs, 10 bps");

        uint256 takerWeth = IERC20(WETH).balanceOf(taker);
        uint256 takerUsdc = IERC20(USDC).balanceOf(taker);
        uint256 aliceWeth = IERC20(WETH).balanceOf(alice);
        uint256 aliceUsdc = IERC20(USDC).balanceOf(alice);

        uint256 swapped3 = _swap(WETH, USDC, REBALANCE_IN);
        assertEq(swapped3, quoted3, "step 3: swap() != quote()");

        assertEq(takerWeth - IERC20(WETH).balanceOf(taker), REBALANCE_IN, "step 3: taker paid 1 WETH");
        assertEq(IERC20(USDC).balanceOf(taker) - takerUsdc, swapped3, "step 3: taker received USDC");
        assertEq(IERC20(WETH).balanceOf(alice) - aliceWeth, REBALANCE_IN, "step 3: alice received 1 WETH");
        assertEq(aliceUsdc - IERC20(USDC).balanceOf(alice), swapped3, "step 3: alice paid USDC from her wallet");
        assertEq(IERC20(WBTC).balanceOf(alice), SHIPPED_WBTC, "step 3: the WBTC leg was read, not moved");
        assertEq(IERC20(WBTC).balanceOf(taker), 0, "step 3: the taker touched no WBTC");

        uint256[] memory after3 = _liveBalances();
        assertEq(after3[0], SHIPPED_WETH + REBALANCE_IN, "step 3: Aqua WETH leg after the push");
        assertEq(after3[1], SHIPPED_WBTC, "step 3: Aqua WBTC leg untouched");
        assertEq(after3[2], SHIPPED_USDC - swapped3, "step 3: Aqua USDC leg after the pull");

        // The composition moved toward target: closer to 50 / 30 / 20 than before.
        assertLt(_distance(_liveValues(), wStart), _distance(values, wStart), "step 3: the basket moved toward target");

        // The fill read her position and did not touch it.
        assertEq(IERC20(aWeth).balanceOf(alice), aWethAtStart, "step 3: her Aave WETH collateral is untouched");
        assertEq(IERC20(aWbtc).balanceOf(alice), aWbtcAtStart, "step 3: her Aave WBTC collateral is untouched");
        assertEq(IERC20(vDebtUsdc).balanceOf(alice), debtAtStart, "step 3: her Aave debt is untouched");
        assertEq(_poolHealthFactor(alice), hfStart, "step 3: her health factor is where it was");

        emit log_named_decimal_uint("  fair USDC out", fair3, 6);
        emit log_named_decimal_uint("  paid USDC out", swapped3, 6);
        emit log_named_decimal_uint("  spread kept by alice, USDC", fair3 - swapped3, 6);

        // ===================================================================================
        // 4. Oracle warps down; HF falls. RECORDING STARTS HERE and runs into step 5.
        // ===================================================================================
        uint256 wethPriceBefore = oracle.getAssetPrice(WETH);
        uint256 wbtcPriceBefore = oracle.getAssetPrice(WBTC);
        uint256 usdcPriceBefore = oracle.getAssetPrice(USDC);
        uint256[] memory legsBeforeWarp = _liveBalances();

        vm.startStateDiffRecording();

        address[] memory collateral = new address[](2);
        collateral[0] = WETH;
        collateral[1] = WBTC;
        OracleWarp.scalePriceWad(collateral, (HF_AFTER * ONE) / hfStart);

        uint256 hfAfter = _poolHealthFactor(alice);
        assertApproxEqAbs(hfAfter, HF_AFTER, HF_TOLERANCE, "step 4: alice fell to HF 1.30");
        assertLt(hfAfter, hfStart, "step 4: her health factor fell");
        assertApproxEqAbs(oracle.getAssetPrice(WETH) * ONE / wethPriceBefore, 0.65e18, 1e10, "step 4: WETH cut by 35%");
        assertApproxEqAbs(oracle.getAssetPrice(WBTC) * ONE / wbtcPriceBefore, 0.65e18, 1e10, "step 4: WBTC cut by 35%");
        assertEq(oracle.getAssetPrice(USDC), usdcPriceBefore, "step 4: the debt asset's price did not move");

        // Nothing but prices changed. The legs, her collateral and her debt are where they were.
        uint256[] memory legsAfterWarp = _liveBalances();
        for (uint256 l = 0; l < 3; ++l) {
            assertEq(legsAfterWarp[l], legsBeforeWarp[l], "step 4: an Aqua leg moved on an oracle move");
        }
        assertEq(IERC20(aWeth).balanceOf(alice), aWethAtStart, "step 4: her Aave WETH collateral is untouched");
        assertEq(IERC20(aWbtc).balanceOf(alice), aWbtcAtStart, "step 4: her Aave WBTC collateral is untouched");
        assertEq(IERC20(vDebtUsdc).balanceOf(alice), debtAtStart, "step 4: her Aave debt is untouched");

        emit log_string("== 4. the oracle falls ==");
        emit log_named_decimal_uint("  HF", hfAfter, 18);
        emit log_named_decimal_uint("  WETH price (USD)", oracle.getAssetPrice(WETH), 8);
        emit log_named_decimal_uint("  WBTC price (USD)", oracle.getAssetPrice(WBTC), 8);

        // ===================================================================================
        // 5. The next fill prices against the NEW target — nobody wrote anything; it was read.
        // ===================================================================================
        uint256[] memory wAfter = this.weightsAt(Curves.freeboard(), hfAfter);
        assertApproxEqAbs(wAfter[0], 0.3e18, 1e12, "target WETH at HF 1.30");
        assertApproxEqAbs(wAfter[1], 0.16e18, 1e12, "target WBTC at HF 1.30");
        assertApproxEqAbs(wAfter[2], 0.54e18, 1e12, "target USDC at HF 1.30");

        // The same legs, revalued at the fallen prices, against the new targets: USDC is now
        // UNDER its target and WBTC OVER, each by more than the deleveraging fill moves.
        uint256[] memory values5 = _liveValues();
        uint256 total5 = _sum(values5);
        uint256 x5 = DELEVERAGE_IN * _unit(USDC);
        assertGt(wAfter[2] * total5, values5[2] * ONE + x5 * ONE, "fixture: USDC's shortfall exceeds the fill");
        assertGt(values5[1] * ONE, wAfter[1] * total5 + x5 * ONE, "fixture: WBTC's excess exceeds the fill");
        // ...and the step-3 fill would now overshoot WETH's target, so it is no longer toward.
        uint256 x3again = REBALANCE_IN * _unit(WETH);
        assertLt(wAfter[0] * total5, values5[0] * ONE + x3again * ONE, "fixture: 1 WETH now crosses WETH's target");
        _logShares("== 5. against the new target ==", values5, wAfter);

        // The references, computed before the counted expectations are armed: at the NEW
        // targets (what the extruction must price) and at the OLD ones (what a stale, pushed
        // target would have priced).
        (uint256 rebalanceAtNew, uint256 fairRebalance) = _reference(values5, wAfter, WETH, USDC, REBALANCE_IN);
        (uint256 rebalanceAtOld,) = _reference(values5, wStart, WETH, USDC, REBALANCE_IN);
        (uint256 deleverAtNew, uint256 fairDelever) = _reference(values5, wAfter, USDC, WBTC, DELEVERAGE_IN);
        (uint256 deleverAtOld,) = _reference(values5, wStart, USDC, WBTC, DELEVERAGE_IN);
        assertNotEq(rebalanceAtNew, rebalanceAtOld, "the two targets price the rebalance differently");
        assertNotEq(deleverAtNew, deleverAtOld, "the two targets price the deleverage differently");

        // Three fills follow — quote, quote, swap — and each must read Alice's health factor
        // from the Pool: exactly three reads, for her. The third leg is read from Aqua once per
        // fill: WBTC once (the WETH -> USDC quote), WETH twice (the USDC -> WBTC quote and swap).
        vm.expectCall(Addresses.AAVE_V3_POOL, abi.encodeCall(IAaveV3Pool.getUserAccountData, (alice)), 3);
        vm.expectCall(AQUA, abi.encodeCall(IAqua.rawBalances, (alice, ROUTER, position.strategyHash, WBTC)), 1);
        vm.expectCall(AQUA, abi.encodeCall(IAqua.rawBalances, (alice, ROUTER, position.strategyHash, WETH)), 2);
        vm.expectCall(AQUA, abi.encodeCall(IAqua.rawBalances, (alice, ROUTER, position.strategyHash, USDC)), 0);

        // 5a. The step-3 trade again: priced against the NEW target, to the wei, and no longer
        //     toward — the same fill, worse, because the basket now wants USDC, not WETH.
        uint256 quotedRebalance = _quote(WETH, USDC, REBALANCE_IN);

        // RECORDING STOPS HERE. Everything written since just before the oracle move:
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        _assertOnlyTheOracleMoveWrote(accesses);

        assertEq(quotedRebalance, rebalanceAtNew, "step 5a: quote != the reference at the NEW targets");
        assertNotEq(quotedRebalance, rebalanceAtOld, "step 5a: the quote is not the old target's price");
        assertLt(quotedRebalance, rebalanceAtOld, "step 5a: the old target would have paid the taker more");
        assertGt(
            fairRebalance - quotedRebalance,
            fairRebalance * PricingReference.TOWARD / ONE + 2,
            "step 5a: the rebalance fill is no longer toward"
        );
        emit log_named_decimal_uint("  1 WETH -> USDC, fair", fairRebalance, 6);
        emit log_named_decimal_uint("  1 WETH -> USDC, quoted now", quotedRebalance, 6);
        emit log_named_decimal_uint("  1 WETH -> USDC, at the OLD target", rebalanceAtOld, 6);

        // 5b. The deleveraging fill: USDC in, WBTC out. Toward on both legs at the new target,
        //     10 bps; at the old target it would have been away. Real tokens move.
        uint256 quotedDelever = _quote(USDC, WBTC, DELEVERAGE_IN);
        assertEq(quotedDelever, deleverAtNew, "step 5b: quote != the reference at the NEW targets");
        assertGt(quotedDelever, deleverAtOld, "step 5b: the old target would have charged the taker more");
        _assertSpreadIs(fairDelever - quotedDelever, fairDelever, PricingReference.TOWARD, "step 5b: toward, 10 bps");

        takerUsdc = IERC20(USDC).balanceOf(taker);
        uint256 takerWbtc = IERC20(WBTC).balanceOf(taker);
        aliceUsdc = IERC20(USDC).balanceOf(alice);
        uint256 aliceWbtc = IERC20(WBTC).balanceOf(alice);
        aliceWeth = IERC20(WETH).balanceOf(alice);

        uint256 swappedDelever = _swap(USDC, WBTC, DELEVERAGE_IN);
        assertEq(swappedDelever, quotedDelever, "step 5b: swap() != quote()");

        assertEq(takerUsdc - IERC20(USDC).balanceOf(taker), DELEVERAGE_IN, "step 5b: taker paid 1,000 USDC");
        assertEq(IERC20(WBTC).balanceOf(taker) - takerWbtc, swappedDelever, "step 5b: taker received WBTC");
        assertEq(IERC20(USDC).balanceOf(alice) - aliceUsdc, DELEVERAGE_IN, "step 5b: alice received USDC");
        assertEq(aliceWbtc - IERC20(WBTC).balanceOf(alice), swappedDelever, "step 5b: alice paid WBTC");
        assertEq(IERC20(WETH).balanceOf(alice), aliceWeth, "step 5b: the WETH leg was read, not moved");

        uint256[] memory after5 = _liveBalances();
        assertEq(after5[0], after3[0], "step 5b: Aqua WETH leg untouched");
        assertEq(after5[1], after3[1] - swappedDelever, "step 5b: Aqua WBTC leg after the pull");
        assertEq(after5[2], after3[2] + DELEVERAGE_IN, "step 5b: Aqua USDC leg after the push");
        assertLt(
            _distance(_liveValues(), wAfter),
            _distance(values5, wAfter),
            "step 5b: the basket moved toward the NEW target"
        );

        // Her Aave position, at the end of the story: read five times, written never.
        assertEq(IERC20(aWeth).balanceOf(alice), aWethAtStart, "end: her Aave WETH collateral is untouched");
        assertEq(IERC20(aWbtc).balanceOf(alice), aWbtcAtStart, "end: her Aave WBTC collateral is untouched");
        assertEq(IERC20(vDebtUsdc).balanceOf(alice), debtAtStart, "end: her Aave debt is untouched");
        assertEq(IERC20(WETH).balanceOf(ROUTER), 0, "end: router retains no WETH");
        assertEq(IERC20(WBTC).balanceOf(ROUTER), 0, "end: router retains no WBTC");
        assertEq(IERC20(USDC).balanceOf(ROUTER), 0, "end: router retains no USDC");

        emit log_named_decimal_uint("  1,000 USDC -> WBTC, fair", fairDelever, 8);
        emit log_named_decimal_uint("  1,000 USDC -> WBTC, paid", swappedDelever, 8);
        emit log_named_decimal_uint("  1,000 USDC -> WBTC, at the OLD target", deleverAtOld, 8);
    }

    // -----------------------------------------------------------------------------------
    // "Nobody wrote anything": the recording's writes, every one accounted for
    // -----------------------------------------------------------------------------------

    /// @dev Every non-reverted storage write in `accesses` belongs to the oracle move: the
    ///      `AaveOracle` (its `assetsSources`), the ACL manager (the listing-admin grant
    ///      `OracleWarp` needs), or one of the two `WarpedPriceSource`s it installed (their
    ///      constructors' `_answer`). Nothing else was written by anyone, and the writes that
    ///      did happen are counted so the check is not vacuous.
    function _assertOnlyTheOracleMoveWrote(Vm.AccountAccess[] memory accesses) internal {
        address sourceWeth = IAaveOracle(address(oracle)).getSourceOfAsset(WETH);
        address sourceWbtc = IAaveOracle(address(oracle)).getSourceOfAsset(WBTC);
        assertTrue(OracleWarp.isWarped(WETH) && OracleWarp.isWarped(WBTC), "both sources are the warp's");

        uint256 writes;
        uint256 oracleWrites;
        for (uint256 i = 0; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory slots = accesses[i].storageAccesses;
            for (uint256 j = 0; j < slots.length; ++j) {
                if (!slots[j].isWrite || slots[j].reverted) {
                    continue;
                }
                ++writes;
                address who = slots[j].account;
                if (who == address(oracle)) {
                    ++oracleWrites;
                }
                assertTrue(
                    who == address(oracle) || who == Addresses.AAVE_V3_ACL_MANAGER || who == sourceWeth
                        || who == sourceWbtc,
                    string.concat("a storage write outside the oracle move: ", vm.toString(who))
                );
                assertNotEq(who, AQUA, "Aqua was written");
                assertNotEq(who, ROUTER, "the router was written");
                assertNotEq(who, address(freeboard), "the extruction was written");
                assertNotEq(who, Addresses.AAVE_V3_POOL, "the Pool was written");
            }
        }
        assertGt(writes, 0, "the recording captured no writes at all");
        assertGe(oracleWrites, 2, "the oracle move installed two sources");
        emit log_named_uint("  storage writes between the fills, all the oracle move's", writes);
    }

    // -----------------------------------------------------------------------------------
    // Alice's Aave position (T8's shape: two collaterals, one debt)
    // -----------------------------------------------------------------------------------

    /// @dev `supply` auto-enables collateral on a user's first deposit into a reserve with LTV > 0.
    function _supply(address who, address asset, uint256 amount) internal {
        deal(asset, who, amount);
        vm.startPrank(who);
        IERC20(asset).approve(Addresses.AAVE_V3_POOL, amount);
        POOL.supply(asset, amount, who, 0);
        vm.stopPrank();
    }

    /// @dev Inverts `GenericLogic` as T8 does: `debtBase = SUM(collateral_i * lt_i) * 1e14 / HF`,
    ///      each leg floored to the 1e8 grid the way `_getUserBalanceInBaseCurrency` floors it.
    ///      Returns the USDC borrowed.
    function _borrowToHealthFactor(address who, uint256 targetHf) internal returns (uint256 amount) {
        uint256 wethBase = (IERC20(aWeth).balanceOf(who) * oracle.getAssetPrice(WETH)) / 1e18;
        uint256 wbtcBase = (IERC20(aWbtc).balanceOf(who) * oracle.getAssetPrice(WBTC)) / 1e8;
        uint256 weighted = wethBase * Addresses.LT_WETH_BPS + wbtcBase * Addresses.LT_WBTC_BPS;
        uint256 debtBase = (weighted * 1e14) / targetHf;
        amount = (debtBase * 1e6) / oracle.getAssetPrice(USDC);

        vm.prank(who);
        POOL.borrow(USDC, amount, VARIABLE_RATE, 0, who);
    }

    function _poolHealthFactor(address who) internal view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = POOL.getUserAccountData(who);
    }

    // -----------------------------------------------------------------------------------
    // The basket on Aqua
    // -----------------------------------------------------------------------------------

    /// @dev Ships the three legs under `position` and approves Aqua for each — the allowance,
    ///      not the shipped amounts, is what makes a position fillable.
    function _ship(address maker) internal {
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

    function _takerTraitsAndData() internal view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.taker = taker;
        args.isExactIn = true;
        args.useTransferFromAndAquaPush = true;
        args.instructionsArgs = INSTRUCTIONS_ARGS;
        return TakerTraitsLib.build(args);
    }

    function _quote(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        vm.prank(taker);
        (, amountOut,) = ISwapVM(ROUTER).quote(position.order, tokenIn, tokenOut, amountIn, _takerTraitsAndData());
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        vm.prank(taker);
        (, amountOut,) = ISwapVM(ROUTER).swap(position.order, tokenIn, tokenOut, amountIn, _takerTraitsAndData());
    }

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

    /// @dev Value units per wei, as the extruction defines them: the oracle price scaled to 18
    ///      decimals. Reflects a warp, because it goes through `AaveOracle`.
    function _unit(address token) internal view returns (uint256) {
        uint256 decimals = token == WETH ? 18 : token == WBTC ? 8 : 6;
        return oracle.getAssetPrice(token) * 10 ** (18 - decimals);
    }

    /// @dev `Curve.weightsAt` reads calldata.
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }

    /// @dev The three legs' balances Aqua holds under Alice's strategy now — through
    ///      `safeBalances`, NOT `rawBalances`, so the test's own reads are never mistaken for
    ///      the extruction's under the counted `expectCall`s.
    function _liveBalances() internal view returns (uint256[] memory balances) {
        balances = new uint256[](3);
        (balances[0], balances[1]) = IAqua(AQUA).safeBalances(alice, ROUTER, position.strategyHash, WETH, WBTC);
        (, balances[2]) = IAqua(AQUA).safeBalances(alice, ROUTER, position.strategyHash, WETH, USDC);
    }

    /// @dev The three legs' values, at the oracle as it stands now.
    function _liveValues() internal view returns (uint256[] memory values) {
        address[] memory tokens = Curves.freeboardTokens();
        uint256[] memory balances = _liveBalances();
        values = new uint256[](3);
        for (uint256 l = 0; l < 3; ++l) {
            values[l] = balances[l] * _unit(tokens[l]);
        }
    }

    function _sum(uint256[] memory values) internal pure returns (uint256 total) {
        for (uint256 l = 0; l < values.length; ++l) {
            total += values[l];
        }
    }

    /// @dev The basket's L1 distance from `w`, scaled by `ONE * total` — enough to compare two
    ///      baskets of the same total, which every fill preserves up to the spread.
    function _distance(uint256[] memory values, uint256[] memory w) internal pure returns (uint256 d) {
        uint256 total = _sum(values);
        for (uint256 l = 0; l < values.length; ++l) {
            uint256 have = values[l] * ONE;
            uint256 want = w[l] * total;
            d += have > want ? have - want : want - have;
        }
        // Normalise by the total so a basket a few USDC lighter compares fairly.
        d = d / total;
    }

    /// @dev The reference price of selling `amountIn` of `tokenIn` for `tokenOut` against
    ///      `values` at targets `w`, by the integral form (`PricingReference`).
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
        uint256 x = amountIn * _unit(tokenIn);
        amountOut = PricingReference.outValue(values[i], values[o], w[i], w[o], _sum(values), x) / _unit(tokenOut);
        fairOut = x / _unit(tokenOut);
    }

    /// @dev `kept / fair` is the average spread over the move: `rate`, within the rounding of
    ///      three integer steps — the bound T21 derives (`kept - expected` in `[-1, 2]`).
    function _assertSpreadIs(uint256 kept, uint256 fairOut, uint256 rate, string memory why) internal pure {
        uint256 expected = fairOut * rate / ONE;
        assertGe(kept + 1, expected, why);
        assertLe(kept, expected + 2, why);
    }

    function _logShares(string memory heading, uint256[] memory values, uint256[] memory w) internal {
        uint256 total = _sum(values);
        emit log_string(heading);
        emit log_named_decimal_uint("  WETH share (%)", values[0] * 100e18 / total, 18);
        emit log_named_decimal_uint("  WBTC share (%)", values[1] * 100e18 / total, 18);
        emit log_named_decimal_uint("  USDC share (%)", values[2] * 100e18 / total, 18);
        emit log_named_decimal_uint("  target WETH (%)", w[0] * 100, 18);
        emit log_named_decimal_uint("  target WBTC (%)", w[1] * 100, 18);
        emit log_named_decimal_uint("  target USDC (%)", w[2] * 100, 18);
    }
}
