// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { PairedControlEngine } from "../../script/PairedControl.s.sol";
import { ProgramLib } from "../utils/ProgramLib.sol";

/// @title PairedControlForkTest — T27
/// @notice `results/paired-control.txt` is this run, and the run is what it says it is: the same
///         world twice with one instruction changed, every unguarded fill priced by swap-vm's
///         own constant-product formula to the wei, every Freeboard fill the committed price
///         path, neither arm touching Aave, and the outcomes the table claims actually ordered
///         the way the table shows them — so a regression that turned the comparison around
///         fails here rather than being retyped into a README.
contract PairedControlForkTest is Test, PairedControlEngine {
    function setUp() public {
        createFork();
        deployExtruction();
    }

    /// @notice The committed table is this run; the Freeboard arm is the committed price path.
    function test_PairedControl_MatchesTheCommittedArtifact() public {
        createFork();
        Arm memory freeboardArm = runArm(false);
        createFork();
        Arm memory unguardedArm = runArm(true);

        assertEq(
            table(unguardedArm, freeboardArm),
            vm.readFile("results/paired-control.txt"),
            "results/paired-control.txt is stale: regenerate with `forge script script/PairedControl.s.sol --tc PairedControl`"
        );
        assertEq(
            report(freeboardArm.run),
            vm.readFile("results/price-path.txt"),
            "the Freeboard arm is not the committed price path"
        );
    }

    /// @notice Same world, one instruction apart, and the comparison the table draws.
    function test_PairedControl_OneInstructionApart_AndFreeboardKeepsMore() public {
        createFork();
        Arm memory b = runArm(false);
        createFork();
        Arm memory a = runArm(true);

        // --- one instruction of difference --------------------------------------------
        assertEq(a.program, ProgramLib.xycSwapXD(), "the unguarded arm ships the stock instruction");
        assertEq(a.program.length, 2, "0x11, no args");
        assertEq(uint8(b.program[0]), ProgramLib.EXTRUCTION, "the Freeboard arm ships one _extruction");
        assertEq(b.program.length, 2 + uint8(b.program[1]), "...and nothing after it");
        assertNotEq(a.run.strategyHash, b.run.strategyHash, "two strategies");

        // --- the same world -----------------------------------------------------------
        assertApproxEqAbs(a.topValue, b.topValue, VALUE_PER_USD, "the same money shipped, to the dollar");
        assertApproxEqAbs(a.topValue, SHIPPED_VALUE, VALUE_PER_USD, "...and it is $80,000");
        // Each arm at the composition its own instruction calls fair: Freeboard at the curve's top
        // row (distance below the dust floor), the constant product with its legs equal in value.
        assertLt(b.run.steps[0].distanceBefore, DUST_BPS * 1e14, "Freeboard ships at the top row");
        // Valued at the top rung's own recorded prices, not the live oracle (which is at the bottom).
        Step memory top = a.run.steps[0];
        uint256[] memory unit = new uint256[](LEGS);
        unit[0] = top.prices[0];
        unit[1] = top.prices[1] * 1e10;
        unit[2] = top.prices[2] * 1e12;
        for (uint256 l = 0; l < LEGS; ++l) {
            assertApproxEqAbs(
                top.balancesBefore[l] * unit[l], a.topValue / LEGS, VALUE_PER_USD, "the stock basket ships in equal thirds"
            );
        }
        assertEq(a.run.steps[0].fills.length, 0, "at the top, nothing to take from the stock basket either");
        assertEq(b.run.steps[0].fills.length, 0, "at the top, nothing to take from Freeboard");
        assertEq(a.run.borrowed, b.run.borrowed, "same borrow");
        assertEq(a.run.aWethAtStart, b.run.aWethAtStart, "same Aave WETH collateral");
        assertEq(a.run.aWbtcAtStart, b.run.aWbtcAtStart, "same Aave WBTC collateral");
        assertEq(a.run.debtAtStart, b.run.debtAtStart, "same debt");
        assertEq(a.run.steps.length, b.run.steps.length, "same rungs");
        for (uint256 i = 0; i < a.run.steps.length; ++i) {
            assertEq(a.run.steps[i].healthFactor, b.run.steps[i].healthFactor, "same health factor at every rung");
            assertEq(a.run.steps[i].prices, b.run.steps[i].prices, "same oracle at every rung");
        }
        assertEq(a.run.finalHealthFactor, b.run.finalHealthFactor, "the health factor ends the same: no arm can move it");

        // --- neither arm touches Aave ----------------------------------------------------
        _assertAaveUntouched(a);
        _assertAaveUntouched(b);

        // --- every unguarded fill is swap-vm's constant product, and pays the taker ------
        for (uint256 i = 0; i < a.run.steps.length; ++i) {
            _assertStepIsConstantProduct(a.run.steps[i]);
        }
        assertGt(a.run.fills, 0, "the unguarded basket was traded");
        assertEq(a.run.spreadValue, 0, "no unguarded fill paid the borrower above the oracle");
        assertGt(a.run.lossValue, 0, "the unguarded basket paid its takers");

        // --- every Freeboard fill paid the borrower -------------------------------------
        assertEq(b.run.lossValue, 0, "no Freeboard fill beat the oracle");
        assertGt(b.run.spreadValue, 0, "Freeboard earned a spread");

        // --- the comparison, as the table draws it --------------------------------------
        assertGt(b.run.finalBalances[2], a.run.finalBalances[2], "Freeboard holds more of the debt asset at the bottom");
        assertGt(b.bottomValue, a.bottomValue, "Freeboard's basket is worth more at the bottom");
        assertGt(b.bottomValue, b.holdValue, "Freeboard beats holding the shipped basket");
        assertLt(a.bottomValue, a.holdValue, "the stock basket loses to holding it");
        assertGt(b.repay.repaid, a.repay.repaid, "Freeboard's basket repays more");
        assertGt(b.repay.healthFactorAfter, a.repay.healthFactorAfter, "...and reaches a higher health factor");
        assertGt(b.repay.healthFactorAfter, b.run.finalHealthFactor, "the repay raised it");

        emit log_named_string("  unguarded USDC at the bottom", _amount(a.run.finalBalances[2], 2));
        emit log_named_string("  freeboard USDC at the bottom", _amount(b.run.finalBalances[2], 2));
        emit log_named_string("  unguarded HF after repay", _hf(a.repay.healthFactorAfter));
        emit log_named_string("  freeboard HF after repay", _hf(b.repay.healthFactorAfter));
    }

    function _assertAaveUntouched(Arm memory arm) private pure {
        assertEq(arm.run.aWethAtEnd, arm.run.aWethAtStart, "aWETH untouched");
        assertEq(arm.run.aWbtcAtEnd, arm.run.aWbtcAtStart, "aWBTC untouched");
        assertEq(arm.run.debtAtEnd, arm.run.debtAtStart, "debt untouched by the walk");
        assertEq(arm.seizedWeth, 0, "nothing seized");
        assertEq(arm.seizedWbtc, 0, "nothing seized");
        assertGt(arm.lowestHealthFactor, ONE, "never liquidatable");
    }

    /// @dev Replays the rung's fills over Aqua's balances: each `amountOut` is
    ///      `amountIn * balanceOut / (balanceIn + amountIn)` (`XYCSwap.sol:22-25`) on the balances
    ///      as they stood, the quote agreed, the ERC-20s moved by the priced amounts, and the
    ///      balances after the rung are where the replay lands.
    function _assertStepIsConstantProduct(Step memory step) private pure {
        uint256[] memory bal = step.balancesBefore;
        for (uint256 k = 0; k < step.fills.length; ++k) {
            Fill memory f = step.fills[k];
            uint256 expected = (f.amountIn * bal[f.legOut]) / (bal[f.legIn] + f.amountIn);
            assertEq(f.amountOut, expected, "not the constant-product price");
            assertEq(f.quotedOut, f.amountOut, "quote() != swap()");
            assertGt(f.amountOut, f.fairOut, "an arbitrage that did not beat the oracle");
            assertGt(f.lossValue, 0, "the borrower paid for it");
            assertEq(f.spreadValue, 0, "and kept nothing");
            assertEq(f.takerPaid, f.amountIn, "the taker paid the priced amount");
            assertEq(f.takerGot, f.amountOut, "the taker received the priced amount");
            assertEq(f.makerGot, f.amountIn, "the maker received what the taker paid");
            assertEq(f.makerPaid, f.amountOut, "the maker paid what the taker received");
            bal[f.legIn] += f.amountIn;
            bal[f.legOut] -= f.amountOut;
        }
        assertEq(bal, step.balancesAfter, "the replay lands on Aqua's balances");
    }
}
