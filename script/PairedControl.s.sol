// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Addresses } from "../src/constants/Addresses.sol";
import { ProgramBuilder } from "../test/utils/ProgramBuilder.sol";
import { ProgramLib } from "../test/utils/ProgramLib.sol";
import { PricePathEngine } from "./PricePath.s.sol";

/// @title PairedControlEngine — T27. Same wallet, same path, same taker, one instruction apart
/// @notice Two arms of the T23 market. Arm B is the Freeboard walk exactly as `PricePath.s.sol`
///         records it — `results/price-path.txt` is that arm. Arm A ships the SAME wallet, the
///         SAME three tokens for the SAME $80,000, from the SAME Aave position, through the SAME
///         deployed Aqua and router, down the SAME eight oracle rungs, against the SAME taker
///         float and fill budget, with one instruction in the program instead of another:
///
///           Unguarded : [0x11 _xycSwapXD]                     swap-vm's stock constant-product
///           Freeboard : [0x20 _extruction -> FreeboardExtruction]
///
///         The stock instruction prices each pair by the ratio of its two balances and knows
///         nothing else — no oracle, no health factor, no target, no cap (`XYCSwap.sol:17-33`).
///         A basket built from it is what "an ordinary Aqua basket" means on this router.
///
/// @dev THE TAKER, IN BOTH ARMS, TAKES WHAT THE PRICING MAKES ATTRACTIVE. The engine's rule for
///      Freeboard is toward-target, because that is the fill the schedule prices cheapest. A
///      constant-product basket has no target, so its attractive fill is the other thing a taker
///      does with a book that has fallen behind the oracle: arbitrage it back to the oracle. For
///      the pair (in, out) that is the fill after which the two legs are worth the same —
///      `(bIn + dx)^2 = bIn * bOut * unitOut / unitIn` — and the taker keeps the difference
///      between the pool's price and the oracle's. Both rules are greedy, both take the whole of
///      what is on offer up to the same per-rung budget and the same dust floor, and neither
///      knows which arm it is in.
///
/// @dev THE EPILOGUE IS THE BORROWER'S ACTION, NOT FREEBOARD'S. No fill in either arm touches
///      Alice's Aave position (asserted for both), so her health factor at the bottom is the
///      same number twice. What differs is what her wallet holds when she gets there. The
///      epilogue makes that legible with one action, taken identically in both arms: she repays
///      her USDC debt with the USDC her basket holds, and the health factor she reaches is
///      recorded. `IPool.repay` is reached through the TEST fixture interface; nothing under
///      `src/` can call it.
abstract contract PairedControlEngine is PricePathEngine {
    /// @dev Which program `buildWorld` ships and which rule `nextFill` applies.
    bool internal unguarded;

    /// @dev The program bytes the arm shipped, kept so the report can print them.
    bytes internal program;

    /// @notice The borrower's one action after the walk, in both arms.
    struct Repay {
        uint256 usdcLeg;
        uint256 debtBefore;
        uint256 repaid;
        uint256 debtAfter;
        uint256 healthFactorAfter;
    }

    /// @notice One arm: the walk, and what it left the borrower with.
    /// @param topValue The basket's value at the top rung, after the first warp.
    /// @param bottomValue The basket's value at the bottom, at the bottom's prices.
    /// @param holdValue What the SHIPPED basket would be worth at the bottom's prices, untouched.
    /// @param tradedValue Sum of `valueIn` over every fill — the base for the realized price.
    /// @param seizedWeth/seizedWbtc aToken balance lost over the walk: a liquidation's footprint.
    struct Arm {
        bytes program;
        Run run;
        uint256 topValue;
        uint256 bottomValue;
        uint256 holdValue;
        uint256 tradedValue;
        uint256 lowestHealthFactor;
        uint256 seizedWeth;
        uint256 seizedWbtc;
        Repay repay;
    }

    // -----------------------------------------------------------------------------------
    // The two hooks
    // -----------------------------------------------------------------------------------

    /// @dev Arm A ships `SHIPPED_VALUE` with its three legs EQUAL in value. `_xycSwapXD` prices a
    ///      pair at the ratio of its two balances, so a constant-product basket is at the oracle
    ///      only when every pair's legs are worth the same; shipped at the curve's 50 / 30 / 20 it
    ///      would hand the first taker a tenth of the basket for being mis-seeded, which would
    ///      be a comparison against a mistake. Each arm ships the composition its own instruction
    ///      calls fair, for the same money.
    function shippedAmounts() internal view override returns (uint256[] memory amounts) {
        if (!unguarded) {
            return super.shippedAmounts();
        }
        uint256[] memory u = units();
        amounts = new uint256[](LEGS);
        for (uint256 l = 0; l < LEGS; ++l) {
            amounts[l] = SHIPPED_VALUE / LEGS / u[l];
        }
    }

    /// @dev Arm A: the same three pieces the engine composes, with the stock program in the
    ///      middle.
    function buildWorld() internal override {
        if (!unguarded) {
            super.buildWorld();
            program = ProgramLib.extruction(address(freeboard), position.extructionArgs);
            return;
        }
        _openAavePosition();
        program = ProgramLib.xycSwapXD();
        position = ProgramBuilder.aquaPosition(alice, program);
        _ship();
        _fundTaker();
    }

    /// @dev Arm A's notion of attractive: the pair whose arbitrage to the oracle pays the taker
    ///      most, sized to exactly that arbitrage. The pool is behind the oracle on pair (in, out)
    ///      whenever the out leg is worth more than the in leg, because `_xycSwapXD` prices at the
    ///      ratio of the two balances. Same dust floor as the toward-target rule.
    function nextFill(
        Legs memory legs,
        uint256[] memory targets
    )
        internal
        view
        override
        returns (bool attractive, uint256 legIn, uint256 legOut, uint256 amountIn)
    {
        if (!unguarded) {
            return super.nextFill(legs, targets);
        }

        uint256 bestProfit;
        for (uint256 i = 0; i < LEGS; ++i) {
            for (uint256 j = 0; j < LEGS; ++j) {
                if (i == j || legs.values[j] <= legs.values[i]) {
                    continue;
                }
                (uint256 dx, uint256 profit) = _arbitrage(legs, i, j);
                if (profit > bestProfit) {
                    bestProfit = profit;
                    legIn = i;
                    legOut = j;
                    amountIn = dx;
                }
            }
        }
        if (bestProfit == 0 || amountIn * legs.units[legIn] * BPS < legs.total * DUST_BPS) {
            return (false, 0, 0, 0);
        }
        attractive = true;
    }

    /// @dev The exact-in fill that brings pair (i, j) of a constant-product pool to the oracle,
    ///      and what the taker keeps for it. With `k = bIn * bOut` preserved by the swap, the two
    ///      legs are worth the same after the fill when `(bIn + dx) * uIn = k * uOut / (bIn + dx)`.
    function _arbitrage(Legs memory legs, uint256 i, uint256 j) private pure returns (uint256 dx, uint256 profit) {
        uint256 bIn = legs.balances[i];
        uint256 bOut = legs.balances[j];
        uint256 root = Math.sqrt(Math.mulDiv(bIn * bOut, legs.units[j], legs.units[i]));
        if (root <= bIn) {
            return (0, 0);
        }
        dx = root - bIn;
        uint256 dy = (dx * bOut) / (bIn + dx); // `_xycSwapXD`, exact-in, floor
        uint256 valueIn = dx * legs.units[i];
        uint256 valueOut = dy * legs.units[j];
        profit = valueOut > valueIn ? valueOut - valueIn : 0;
    }

    // -----------------------------------------------------------------------------------
    // One arm
    // -----------------------------------------------------------------------------------

    /// @notice Walk one arm on the current fork, then the borrower's epilogue.
    function runArm(bool stock) internal returns (Arm memory arm) {
        unguarded = stock;
        arm.run = walk();
        arm.program = program;

        arm.topValue = arm.run.steps[0].totalBefore;
        arm.bottomValue = _sum(values(arm.run.finalBalances));
        arm.holdValue = _sum(values(arm.run.shipped));
        arm.lowestHealthFactor = type(uint256).max;
        for (uint256 i = 0; i < arm.run.steps.length; ++i) {
            Step memory step = arm.run.steps[i];
            arm.lowestHealthFactor = _min(arm.lowestHealthFactor, step.healthFactor);
            for (uint256 k = 0; k < step.fills.length; ++k) {
                arm.tradedValue += step.fills[k].valueIn;
            }
        }
        arm.seizedWeth = arm.run.aWethAtStart > arm.run.aWethAtEnd ? arm.run.aWethAtStart - arm.run.aWethAtEnd : 0;
        arm.seizedWbtc = arm.run.aWbtcAtStart > arm.run.aWbtcAtEnd ? arm.run.aWbtcAtStart - arm.run.aWbtcAtEnd : 0;

        arm.repay = _repayWithBasketUsdc();
    }

    /// @dev Alice repays what her basket's USDC leg holds. Aqua is allowance-based, so that USDC
    ///      is in her wallet; the leg is Aqua's accounting of it, read before the repay.
    function _repayWithBasketUsdc() private returns (Repay memory r) {
        r.usdcLeg = legBalances()[2];
        r.debtBefore = IERC20(vDebtUsdc).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(USDC).approve(Addresses.AAVE_V3_POOL, r.usdcLeg);
        r.repaid = POOL.repay(USDC, r.usdcLeg, VARIABLE_RATE, alice);
        vm.stopPrank();

        r.debtAfter = IERC20(vDebtUsdc).balanceOf(alice);
        r.healthFactorAfter = healthFactorOf(alice);
    }

    // -----------------------------------------------------------------------------------
    // The table
    // -----------------------------------------------------------------------------------

    uint256 private constant LABEL_WIDTH = 54;
    uint256 private constant CELL_WIDTH = 16;

    /// @notice `results/paired-control.txt`.
    function table(Arm memory a, Arm memory b) internal pure returns (string memory out) {
        out = string.concat(
            "Freeboard paired control (T27)\n",
            "==============================\n\n",
            "Same wallet, same Aave position, same oracle path, same taker, same fill budget,\n",
            "same three tokens for the same $80,000, shipped through the DEPLOYED Aqua and\n",
            "AquaSwapVMRouter, each arm at the composition its own instruction calls fair.\n",
            "One instruction of difference in the shipped program:\n\n",
            "  Unguarded : ",
            vm.toString(a.program),
            "\n",
            "              [0x11 _xycSwapXD] - swap-vm's stock constant-product swap. Prices each\n",
            "              pair by the ratio of its balances. No oracle, no health factor, no cap.\n",
            "  Freeboard : [0x20 _extruction -> FreeboardExtruction][curve . maxShiftBps]\n",
            "              HF -> target weights, priced by basket distance, 500 bps cap per fill.\n",
            "              (",
            vm.toString(b.program.length),
            " bytes; the same bytes as results/price-path.txt)\n\n"
        );

        out = string.concat(
            out,
            "strategy hash, unguarded : ",
            vm.toString(a.run.strategyHash),
            "\n",
            "strategy hash, freeboard : ",
            vm.toString(b.run.strategyHash),
            "\n",
            "transcript, unguarded    : ",
            vm.toString(keccak256(abi.encode(a.run))),
            "\n",
            "transcript, freeboard    : ",
            vm.toString(keccak256(abi.encode(b.run))),
            "\n",
            "Aave collateral          : ",
            _amount(a.run.aWethAtStart, 0),
            " / ",
            _amount(a.run.aWbtcAtStart, 1),
            "\n",
            "USDC debt                : ",
            _amount(a.run.debtAtStart, 2),
            "\n",
            "shipped, unguarded       : ",
            _basketLine(a.run.shipped),
            "   (equal thirds by value: the only ratio a constant product prices at the oracle)\n",
            "shipped, freeboard       : ",
            _basketLine(b.run.shipped),
            "   (the curve's top row, 50 / 30 / 20 by value)\n",
            "oracle path              : HF 2.00 -> 1.80 -> 1.60 -> 1.45 -> 1.30 -> 1.20 -> 1.15 -> 1.10\n\n"
        );

        out = string.concat(
            out,
            _row("", "Unguarded", "Freeboard"),
            _rule(),
            _row("Final health factor", _hf(a.run.finalHealthFactor), _hf(b.run.finalHealthFactor)),
            _row("Lowest health factor on the path", _hf(a.lowestHealthFactor), _hf(b.lowestHealthFactor)),
            _row("Liquidated", _liquidated(a), _liquidated(b)),
            _row("Liquidation penalty paid", _penalty(a), _penalty(b)),
            _row(
                "Spread earned on the way down",
                _signedUsd(a.run.spreadValue, a.run.lossValue),
                _signedUsd(b.run.spreadValue, b.run.lossValue)
            ),
            _row("Collateral remaining in Aave: WETH", _amount(a.run.aWethAtEnd, 0), _amount(b.run.aWethAtEnd, 0)),
            _row("Collateral remaining in Aave: WBTC", _amount(a.run.aWbtcAtEnd, 1), _amount(b.run.aWbtcAtEnd, 1)),
            _rule()
        );

        out = string.concat(
            out,
            _row("Fills", vm.toString(a.run.fills), vm.toString(b.run.fills)),
            _row(
                "Realized price vs oracle, over all fills",
                _signedBps(a.run.spreadValue, a.run.lossValue, a.tradedValue),
                _signedBps(b.run.spreadValue, b.run.lossValue, b.tradedValue)
            ),
            _row("Basket value at the top", string.concat("$", _usd(a.topValue)), string.concat("$", _usd(b.topValue))),
            _row(
                "Basket value at the bottom", string.concat("$", _usd(a.bottomValue)), string.concat("$", _usd(b.bottomValue))
            ),
            _row(
                "  vs holding the shipped basket untouched",
                _signedUsd(a.bottomValue, a.holdValue),
                _signedUsd(b.bottomValue, b.holdValue)
            ),
            _row("Basket at the bottom: WETH", _amount(a.run.finalBalances[0], 0), _amount(b.run.finalBalances[0], 0)),
            _row("Basket at the bottom: WBTC", _amount(a.run.finalBalances[1], 1), _amount(b.run.finalBalances[1], 1)),
            _row(
                "Basket at the bottom: USDC (the debt asset)",
                _amount(a.run.finalBalances[2], 2),
                _amount(b.run.finalBalances[2], 2)
            ),
            _rule()
        );

        out = string.concat(
            out,
            _row("She repays her USDC debt with the basket's USDC", _amount(a.repay.repaid, 2), _amount(b.repay.repaid, 2)),
            _row(
                "  share of the debt repaid",
                _pctOf(a.repay.repaid, a.repay.debtBefore),
                _pctOf(b.repay.repaid, b.repay.debtBefore)
            ),
            _row("  health factor after", _hf(a.repay.healthFactorAfter), _hf(b.repay.healthFactorAfter)),
            "\n"
        );

        out = string.concat(
            out,
            "Notes\n",
            "-----\n",
            "The first two rows are the same number twice, and they have to be: the basket is the\n",
            "borrower's wallet, not her Aave collateral. No fill in either arm touches her aTokens\n",
            "or her debt, so Aave's health factor cannot move, and on a path that stops at HF 1.10\n",
            "neither arm is liquidated. What the instruction changes is what she is HOLDING when\n",
            "she gets to the bottom, and what she was paid or charged on the way. The last three\n",
            "rows are her own action, taken identically in both arms: repay the USDC debt with the\n",
            "USDC her basket holds. Freeboard never repays; it puts the USDC in her hand.\n\n",
            "Spread: for the Freeboard arm this is what takers paid her above the Aave oracle,\n",
            "ten basis points a fill. For the unguarded arm it is what takers took from her below\n",
            "the oracle: a constant-product basket keeps its price until an arbitrageur moves it,\n",
            "so on a falling oracle it buys the falling asset above market at every rung.\n\n",
            "Hold: each arm's own shipped basket, untouched, at the bottom's prices. Both arms\n",
            "start at the oracle for their instruction, so neither is charged for its seeding:\n",
            "at HF 2.00 the Freeboard basket is at the top row and no taker has anything to take,\n",
            "and the unguarded basket's pairs are at the oracle until the first warp moves it.\n\n",
            "Emitted by `forge script script/PairedControl.s.sol --tc PairedControl` on a mainnet\n",
            "fork at FORK_BLOCK; asserted by test/fork/PairedControl.t.sol. The Freeboard arm's\n",
            "rung-by-rung record is results/price-path.txt. The unguarded arm's follows.\n\n"
        );

        out = string.concat(out, "The unguarded arm, rung by rung\n", "-------------------------------\n");
        for (uint256 i = 0; i < a.run.steps.length; ++i) {
            Step memory step = a.run.steps[i];
            out = string.concat(out, _stockStepLine(step), "\n");
            for (uint256 k = 0; k < step.fills.length; ++k) {
                out = string.concat(out, "    ", _stockFillLine(step.fills[k]), "\n");
            }
        }
    }

    // -----------------------------------------------------------------------------------
    // Cells
    // -----------------------------------------------------------------------------------

    function _liquidated(Arm memory arm) private pure returns (string memory) {
        return arm.lowestHealthFactor > ONE && arm.seizedWeth == 0 && arm.seizedWbtc == 0 ? "no" : "YES";
    }

    /// @dev Collateral seized over the walk, valued at the bottom's prices. Prices are not in the
    ///      arm, so a nonzero seizure is reported in kind; the number a judge wants is zero.
    function _penalty(Arm memory arm) private pure returns (string memory) {
        if (arm.seizedWeth == 0 && arm.seizedWbtc == 0) {
            return "$0.00";
        }
        return string.concat(_amount(arm.seizedWeth, 0), " / ", _amount(arm.seizedWbtc, 1));
    }

    function _signedUsd(uint256 gain, uint256 loss) private pure returns (string memory) {
        return gain >= loss ? string.concat("+$", _usd(gain - loss)) : string.concat("-$", _usd(loss - gain));
    }

    /// @dev `(gain - loss) / base` in basis points, one decimal.
    function _signedBps(uint256 gain, uint256 loss, uint256 base) private pure returns (string memory) {
        (string memory sign, uint256 net) = gain >= loss ? ("+", gain - loss) : ("-", loss - gain);
        return string.concat(sign, _fixed((net * BPS * 10) / base, 1, 1), " bps");
    }

    function _pctOf(uint256 part, uint256 whole) private pure returns (string memory) {
        return string.concat(_pct((part * ONE) / whole), "%");
    }

    function _row(string memory label, string memory a, string memory b) private pure returns (string memory) {
        return string.concat("| ", _pad(label, LABEL_WIDTH), " | ", _pad(a, CELL_WIDTH), " | ", _pad(b, CELL_WIDTH), " |\n");
    }

    function _rule() private pure returns (string memory) {
        return string.concat("|", _dashes(LABEL_WIDTH + 2), "|", _dashes(CELL_WIDTH + 2), "|", _dashes(CELL_WIDTH + 2), "|\n");
    }

    function _pad(string memory s, uint256 width) private pure returns (string memory out) {
        out = s;
        for (uint256 n = bytes(s).length; n < width; ++n) {
            out = string.concat(out, " ");
        }
    }

    function _dashes(uint256 n) private pure returns (string memory out) {
        for (uint256 i = 0; i < n; ++i) {
            out = string.concat(out, "-");
        }
    }

    /// @dev A stock rung has no target; its shares are reported against nothing.
    function _stockStepLine(Step memory step) private pure returns (string memory) {
        return string.concat(
            "HF ",
            _hf(step.healthFactor),
            "  basket ",
            _pct(step.sharesAfter[0]),
            " / ",
            _pct(step.sharesAfter[1]),
            " / ",
            _pct(step.sharesAfter[2])
        );
    }

    function _stockFillLine(Fill memory f) private pure returns (string memory) {
        return string.concat(
            _amount(f.amountIn, f.legIn),
            " -> ",
            _amount(f.amountOut, f.legOut),
            "   taker kept ",
            _signedUsd(f.lossValue, f.spreadValue)
        );
    }
}

/// @title PairedControlWalker — both arms, from one deployed contract
/// @notice Persistent across the re-fork between arms, so its storage (and the one extruction it
///         deploys from the fixed address) survives; see `PricePathWalker` for why the walk runs
///         from a deployed contract at all.
contract PairedControlWalker is PairedControlEngine {
    function runAndReport() external returns (string memory) {
        vm.makePersistent(address(this));
        deployExtruction();

        Arm memory freeboardArm = runArm(false);
        createFork();
        Arm memory unguardedArm = runArm(true);

        return table(unguardedArm, freeboardArm);
    }
}

/// @title PairedControl — `forge script script/PairedControl.s.sol --tc PairedControl`
/// @notice Writes `results/paired-control.txt`. Simulation only, on a fork; the warps are
///         cheatcodes and nothing is broadcast.
contract PairedControl is Script, PairedControlEngine {
    function run() external {
        createFork();
        string memory out = new PairedControlWalker().runAndReport();
        vm.writeFile("results/paired-control.txt", out);
        console.log(out);
    }
}
