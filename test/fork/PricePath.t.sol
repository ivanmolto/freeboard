// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PricePathEngine } from "../../script/PricePath.s.sol";
import { PricingReference } from "../utils/PricingReference.sol";

/// @title PricePathForkTest — T23
/// @notice The scripted market, and the three things that have to be true of it.
///
///         `test_PricePath_RunsIdenticallyThreeTimes` is the DoD: three fresh mainnet forks,
///         three walks of `script/PricePath.s.sol`, and every number in all three the same —
///         every fill, its price, the health factor at each rung, the basket at the end, and
///         one transcript hash over the lot. The path drives the paired control (T27), the
///         UI (T29) and the video (T32), so a flaky run costs three deliverables, not one.
///
///         `test_PricePath_WalksTheCurveDown_AndEveryFillIsTowardTarget` is what stops the
///         first test from being a tautology: three identical recordings of nothing would pass
///         it. This one says the recording is of a market — the health factor really falls from
///         2.00 to 1.10, the target really slides from 50/30/20 to 20/10/70, every fill is
///         priced to the wei by an independent reference, no fill beats the oracle, real ERC-20
///         balances move on both sides, and Alice's Aave position is never touched by any of it.
///
///         `test_PricePath_MatchesTheCommittedArtifact` keeps `results/price-path.txt` honest.
///
/// @dev WHAT DETERMINISM RESTS ON, AND WHAT IT DOES NOT. Each run gets its own fork of the same
///      pinned block, so every run starts from identical chain state, and the walk reads nothing
///      that a rerun could answer differently: no timestamp, no fuzz input, no live price, no
///      randomness. Two things deliberately do NOT vary between runs and would otherwise: the
///      `FreeboardExtruction` is deployed once, from a fixed address, and made persistent,
///      because its address is inside the program and therefore inside the strategy hash Aqua
///      keys balances by; and Alice and the taker come from `makeAddr`, which is a hash of a
///      label. The `WarpedPriceSource` contracts `OracleWarp` installs DO land on different
///      addresses in each run, since the engine's nonce keeps climbing — and nothing in the
///      transcript is allowed to depend on them, which is itself part of what the DoD checks.
///
/// @dev MUTATION-CHECKED, Sep 8. Dropping `makePersistent` and the fixed deployer, so that each
///      run deploys its own extruction, fails run 1 against run 2 on the strategy hash — the
///      exact class of drift this test exists to catch, and the reason `deployExtruction` pins
///      both.
contract PricePathForkTest is Test, PricePathEngine {
    /// @dev Aave's health factor lands within a few parts in 1e12 of a rung: the warp is exact in
    ///      WAD, but `getUserAccountData` floors each reserve onto the 1e8 base-currency grid.
    uint256 internal constant HF_TOLERANCE = 1e12;

    function setUp() public {
        createFork();
        deployExtruction();
    }

    // -----------------------------------------------------------------------------------
    // THE DoD
    // -----------------------------------------------------------------------------------

    /// @notice Three walks, three fresh forks, one transcript.
    function test_PricePath_RunsIdenticallyThreeTimes() public {
        createFork();
        Run memory first = walk();

        createFork();
        Run memory second = walk();

        createFork();
        Run memory third = walk();

        _assertIdentical(first, second, "run 1 vs run 2");
        _assertIdentical(second, third, "run 2 vs run 3");

        // Not a recording of nothing: the walk that was reproduced three times did something.
        assertEq(first.steps.length, rungs().length, "the run has a rung for every rung");
        assertGt(first.fills, 0, "the run has fills");
        assertGt(first.spreadValue, 0, "the run earned a spread");

        emit log_named_bytes32("  transcript", keccak256(abi.encode(first)));
        emit log_named_uint("  fills", first.fills);
    }

    /// @notice The committed artifact is this run, and not a run from some earlier version of it.
    /// @dev `results/price-path.txt` is what T27's table, T29's UI and T32's video quote, so it
    ///      being stale is a way for the demo to disagree with the code without anything failing.
    ///      It cannot go stale while this passes. The walker under `forge script` and this test
    ///      contract produce the same report because the extruction is deployed from a fixed
    ///      address (`deployExtruction`), so the strategy hash is not a function of who walked.
    function test_PricePath_MatchesTheCommittedArtifact() public {
        createFork();
        assertEq(
            report(walk()),
            vm.readFile("results/price-path.txt"),
            "results/price-path.txt is stale: regenerate with `forge script script/PricePath.s.sol --tc PricePath`"
        );
    }

    // -----------------------------------------------------------------------------------
    // What the recording is a recording OF
    // -----------------------------------------------------------------------------------

    /// @notice The market the DoD reproduces: a health factor walked down, a target sliding under
    ///         it, and a taker at every rung being paid ten basis points to move the basket.
    function test_PricePath_WalksTheCurveDown_AndEveryFillIsTowardTarget() public {
        createFork();
        Run memory run = walk();

        // --- the position she shipped -------------------------------------------------
        assertEq(run.shipped[0], SHIPPED_WETH, "Aqua accounts the WETH leg");
        assertEq(run.shipped[1], SHIPPED_WBTC, "Aqua accounts the WBTC leg");
        assertEq(run.shipped[2], SHIPPED_USDC, "Aqua accounts the USDC leg");
        assertGt(run.borrowed, SHIPPED_USDC, "her USDC leg came out of the USDC she borrowed");

        // --- the path ------------------------------------------------------------------
        uint256[] memory hfs = rungs();
        assertEq(run.steps.length, hfs.length, "one step per rung");
        for (uint256 i = 0; i < run.steps.length; ++i) {
            Step memory step = run.steps[i];
            assertApproxEqAbs(step.healthFactor, hfs[i], HF_TOLERANCE, "the rung was landed on");
            if (i > 0) {
                assertLt(step.healthFactor, run.steps[i - 1].healthFactor, "the health factor fell");
            }
            assertGt(step.fills.length, 0, "a taker arrived at this rung");
            assertLe(step.fills.length, MAX_FILLS_PER_STEP, "no more takers than the budget");
            assertLt(step.distanceAfter, step.distanceBefore, "the rung's fills moved the basket toward target");
        }
        assertApproxEqAbs(run.startHealthFactor, 2.0e18, HF_TOLERANCE, "the path starts at HF 2.00");
        assertApproxEqAbs(run.finalHealthFactor, 1.1e18, HF_TOLERANCE, "the path ends at HF 1.10");
        assertGt(run.finalHealthFactor, ONE, "never once liquidatable");

        // --- the target slid, and stopped sliding where the curve stops ----------------
        _assertTargetIs(run.steps[0], 0.5e18, 0.3e18, 0.2e18, "HF 2.00");
        _assertTargetIs(run.steps[2], 0.4e18, 0.24e18, 0.36e18, "HF 1.60");
        _assertTargetIs(run.steps[4], 0.3e18, 0.16e18, 0.54e18, "HF 1.30");
        _assertTargetIs(run.steps[6], 0.2e18, 0.1e18, 0.7e18, "HF 1.15");
        // HF 1.80 and 1.45 are between breakpoints: interpolated, so strictly between the rows.
        _assertBetween(run.steps[1], run.steps[0], run.steps[2], "HF 1.80 interpolates");
        _assertBetween(run.steps[3], run.steps[2], run.steps[4], "HF 1.45 interpolates");
        // ...and 1.10 is below the bottom breakpoint, where the curve clamps: the health factor
        // keeps falling and the target stops moving. That is the bottom row doing its job.
        _assertTargetIs(run.steps[7], 0.2e18, 0.1e18, 0.7e18, "HF 1.10 clamps to the bottom row");
        assertLt(run.steps[7].healthFactor, run.steps[6].healthFactor, "1.10 is below 1.15");

        // --- the trade reverses as her margin thins ------------------------------------
        // At HF 2.00 the basket is short WETH and long USDC, so the taker SELLS her collateral
        // and takes USDC out. By HF 1.30 the curve wants 54% USDC and the same greedy rule PAYS
        // USDC in and takes collateral out: the deleverage. Nothing in the taker rule changed.
        assertEq(run.steps[0].fills[0].legIn, 0, "at HF 2.00 the taker pays WETH in");
        assertEq(run.steps[0].fills[0].legOut, 2, "at HF 2.00 the taker takes USDC out");
        for (uint256 k = 0; k < run.steps[4].fills.length; ++k) {
            assertEq(run.steps[4].fills[k].legIn, 2, "at HF 1.30 the taker pays USDC in");
            assertNotEq(run.steps[4].fills[k].legOut, 2, "at HF 1.30 the taker takes collateral out");
        }
        // She ends up holding much less collateral and much more of the debt asset.
        assertLt(run.finalBalances[0], run.shipped[0], "the WETH leg shrank");
        assertLt(run.finalBalances[1], run.shipped[1], "the WBTC leg shrank");
        assertGt(run.finalBalances[2], run.shipped[2], "the USDC leg grew");

        // --- every fill ----------------------------------------------------------------
        uint256 fills;
        uint256 spread;
        for (uint256 i = 0; i < run.steps.length; ++i) {
            for (uint256 k = 0; k < run.steps[i].fills.length; ++k) {
                _assertFillIsSound(run.steps[i].fills[k]);
                spread += run.steps[i].fills[k].spreadValue;
                ++fills;
            }
        }
        assertEq(fills, run.fills, "the run counted its own fills");
        assertEq(spread, run.spreadValue, "the run added up its own spread");
        assertGt(fills, run.steps.length, "some rung took more than one fill");

        // --- and the taker was never the binding constraint -----------------------------
        assertGt(IERC20(WETH).balanceOf(taker), 0, "the taker still holds WETH");
        assertGt(IERC20(WBTC).balanceOf(taker), 0, "the taker still holds WBTC");
        assertGt(IERC20(USDC).balanceOf(taker), 0, "the taker still holds USDC");

        // --- her Aave position, after nineteen fills -------------------------------------
        assertEq(run.aWethAtEnd, run.aWethAtStart, "her Aave WETH collateral is untouched");
        assertEq(run.aWbtcAtEnd, run.aWbtcAtStart, "her Aave WBTC collateral is untouched");
        assertEq(run.debtAtEnd, run.debtAtStart, "her Aave debt is untouched");
        assertEq(IERC20(WETH).balanceOf(ROUTER), 0, "the router retains no WETH");
        assertEq(IERC20(WBTC).balanceOf(ROUTER), 0, "the router retains no WBTC");
        assertEq(IERC20(USDC).balanceOf(ROUTER), 0, "the router retains no USDC");

        emit log_named_uint("  fills", run.fills);
        emit log_string(string.concat("  spread earned  $", _usd(run.spreadValue)));
    }

    // -----------------------------------------------------------------------------------
    // One fill, from four directions
    // -----------------------------------------------------------------------------------

    /// @dev Quote agrees with swap; the price agrees with a reference derived the other way; the
    ///      taker never beats the oracle; the spread is the toward-target rate; the cap held; and
    ///      the ERC-20s that moved are the amounts that were priced.
    function _assertFillIsSound(Fill memory f) internal pure {
        assertGt(f.amountIn, 0, "a fill of nothing");
        assertGt(f.amountOut, 0, "a fill paying nothing");
        assertEq(f.quotedOut, f.amountOut, "quote() != swap()");
        assertEq(f.referenceOut, f.amountOut, "the router's price != the reference price");
        assertLt(f.amountOut, f.fairOut, "the fill beat the oracle");
        assertLe(f.shiftBps, MAX_SHIFT_BPS, "the fill moved more of the basket than the cap allows");

        // Toward on both legs for the whole move, so the average spread is the marginal one:
        // ten basis points, within the rounding of the three integer steps that produced it
        // (floor of the output, ceiling of the spread, floor of the fair amount) — T21's bound.
        uint256 kept = f.fairOut - f.amountOut;
        uint256 expected = (f.fairOut * PricingReference.TOWARD) / ONE;
        assertGe(kept + 1, expected, "the fill was cheaper than the toward-target rate");
        assertLe(kept, expected + 2, "the fill was dearer than the toward-target rate");

        assertEq(f.takerPaid, f.amountIn, "the taker paid the priced amount");
        assertEq(f.takerGot, f.amountOut, "the taker received the priced amount");
        assertEq(f.makerGot, f.amountIn, "the maker received what the taker paid");
        assertEq(f.makerPaid, f.amountOut, "the maker paid what the taker received");
    }

    function _assertTargetIs(Step memory step, uint256 w0, uint256 w1, uint256 w2, string memory why) internal pure {
        assertApproxEqAbs(step.targets[0], w0, 1e12, string.concat(why, ": WETH"));
        assertApproxEqAbs(step.targets[1], w1, 1e12, string.concat(why, ": WBTC"));
        assertApproxEqAbs(step.targets[2], w2, 1e12, string.concat(why, ": USDC"));
    }

    /// @dev A rung between two breakpoints: strictly inside both rows on every leg.
    function _assertBetween(Step memory step, Step memory above, Step memory below, string memory why) internal pure {
        for (uint256 l = 0; l < LEGS; ++l) {
            uint256 hi = above.targets[l] > below.targets[l] ? above.targets[l] : below.targets[l];
            uint256 lo = above.targets[l] > below.targets[l] ? below.targets[l] : above.targets[l];
            assertGt(step.targets[l], lo, why);
            assertLt(step.targets[l], hi, why);
        }
    }

    // -----------------------------------------------------------------------------------
    // "Identical", spelled out
    // -----------------------------------------------------------------------------------

    /// @dev Field by field before the digest, so a difference names itself instead of arriving as
    ///      two unequal hashes. The digest is then asserted over the whole encoding, which catches
    ///      any field this function forgot to look at.
    function _assertIdentical(Run memory a, Run memory b, string memory why) internal pure {
        assertEq(a.strategyHash, b.strategyHash, string.concat(why, ": strategy hash"));
        assertEq(a.borrowed, b.borrowed, string.concat(why, ": borrowed"));
        assertEq(a.shipped, b.shipped, string.concat(why, ": shipped"));
        assertEq(a.fills, b.fills, string.concat(why, ": fill count"));
        assertEq(a.spreadValue, b.spreadValue, string.concat(why, ": spread earned"));
        assertEq(a.finalBalances, b.finalBalances, string.concat(why, ": final basket"));
        assertEq(a.startHealthFactor, b.startHealthFactor, string.concat(why, ": starting health factor"));
        assertEq(a.finalHealthFactor, b.finalHealthFactor, string.concat(why, ": final health factor"));
        assertEq(a.aWethAtEnd, b.aWethAtEnd, string.concat(why, ": aWETH"));
        assertEq(a.aWbtcAtEnd, b.aWbtcAtEnd, string.concat(why, ": aWBTC"));
        assertEq(a.debtAtEnd, b.debtAtEnd, string.concat(why, ": debt"));

        assertEq(a.steps.length, b.steps.length, string.concat(why, ": step count"));
        for (uint256 i = 0; i < a.steps.length; ++i) {
            string memory at = string.concat(why, ", step ", vm.toString(i));
            Step memory x = a.steps[i];
            Step memory y = b.steps[i];
            assertEq(x.healthFactor, y.healthFactor, string.concat(at, ": health factor"));
            assertEq(x.prices, y.prices, string.concat(at, ": oracle prices"));
            assertEq(x.targets, y.targets, string.concat(at, ": targets"));
            assertEq(x.balancesBefore, y.balancesBefore, string.concat(at, ": basket before"));
            assertEq(x.balancesAfter, y.balancesAfter, string.concat(at, ": basket after"));
            assertEq(x.sharesAfter, y.sharesAfter, string.concat(at, ": shares"));
            assertEq(x.totalBefore, y.totalBefore, string.concat(at, ": basket value"));
            assertEq(x.distanceBefore, y.distanceBefore, string.concat(at, ": distance before"));
            assertEq(x.distanceAfter, y.distanceAfter, string.concat(at, ": distance after"));

            assertEq(x.fills.length, y.fills.length, string.concat(at, ": fill count"));
            for (uint256 k = 0; k < x.fills.length; ++k) {
                assertEq(
                    keccak256(abi.encode(x.fills[k])),
                    keccak256(abi.encode(y.fills[k])),
                    string.concat(at, ", fill ", vm.toString(k))
                );
            }
        }

        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), string.concat(why, ": transcript"));
    }
}
