// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { CommonBase } from "forge-std/Base.sol";
import { Script } from "forge-std/Script.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { Addresses } from "../src/constants/Addresses.sol";
import { FreeboardExtruction } from "../src/FreeboardExtruction.sol";
import { IPoolAddressesProvider } from "../src/interfaces/IAaveV3.sol";
import { IAaveV3Oracle } from "../src/interfaces/IAaveV3Oracle.sol";
import { BasketDistance } from "../src/libs/BasketDistance.sol";
import { Curve } from "../src/libs/Curve.sol";

import { IAaveProtocolDataProvider, IAaveV3PoolFixture } from "../test/utils/AaveFixtures.sol";
import { Curves } from "../test/utils/Curves.sol";
import { OracleWarp } from "../test/utils/OracleWarp.sol";
import { PricingReference } from "../test/utils/PricingReference.sol";
import { ProgramBuilder } from "../test/utils/ProgramBuilder.sol";

/// @title PricePathEngine — T23. The scripted market: one oracle path, one taker rule
/// @notice The HF path and the taker's behaviour are defined HERE and nowhere else, so the
///         paired control (T27), the UI (T29) and the video (T32) all show the same run.
///
///         The world is Alice's: a real Aave v3 position — 100 WETH and 3 WBTC of collateral
///         against USDC debt — and an $80,000 Freeboard basket shipped through the DEPLOYED
///         Aqua at the curve's top row (50 / 30 / 20 by value at the pinned prices), its USDC
///         leg drawn from the USDC she borrowed. The market is eight rungs of oracle: HF 2.00,
///         1.80, 1.60, 1.45, 1.30, 1.20, 1.15, 1.10. At the top the basket is where she said it
///         should be and no taker has anything to take; at each rung below, a taker arrives and
///         takes, up to four times, whatever the pricing has made attractive.
///
/// @dev THE TAKER RULE, IN ONE PARAGRAPH. At the health factor the Pool reports, the curve says
///      what the basket should be. The taker pays in the leg the basket wants MOST and takes out
///      the leg it wants LEAST, sized to the smaller of the two gaps, the maker's per-fill cap,
///      and the out leg itself. That size is exactly the largest fill that stays TOWARD target on
///      both legs, so every fill on this path is a ten-basis-point fill — the cheapest the
///      schedule offers, which is precisely why a rational arbitrageur takes it. Nothing about
///      the rule knows the words "rebalance" or "deleverage": the curve moves under it. At HF
///      2.00 it finds nothing to take; from 1.80 down it pays her USDC and takes collateral out;
///      at the clamped bottom, where the target has stopped moving and the prices have not, it
///      sells her a little collateral back.
///
/// @dev DETERMINISM IS THE DELIVERABLE (`test_PricePath_RunsIdenticallyThreeTimes`). Every input
///      is fixed: the fork block, the shipped amounts, the rungs, the fill rule, the four-fill
///      budget, the dust floor. Nothing here reads `block.timestamp`, a random source, a fuzz
///      input or a live price — the only prices are the pinned ones and the warps this file
///      applies to them, and each rung's warp is computed FROM the health factor the Pool reports,
///      so a rung lands on its target from wherever the previous rung left off. `walk()` returns
///      the whole run as memory, and `keccak256(abi.encode(run))` is the transcript the DoD
///      compares.
///
/// @dev THREE PRIMITIVES, FOR THE LIVE DRIVER (T29): see `_as`, `_deal`, `_warpTo` below — the
///      only places the walk writes to the chain, overridden by `script/LivePricePath.s.sol` to
///      walk the same path as transactions on anvil for the UI.
///
/// @dev TWO HOOKS, FOR THE PAIRED CONTROL (T27). Arm A is the same wallet, the same Aave
///      position, the same oracle path and the same taker, shipping a STOCK basket program
///      instead of the Freeboard one. The two things an arm replaces are `virtual`:
///
///        `buildWorld`  — what is shipped. The default composes `_openAavePosition`, `_ship`
///                        and `_fundTaker` around the Freeboard position; an arm overrides it to
///                        set `position` to its own program between the first and the second.
///        `nextFill`    — what a taker takes. The default is the toward-target rule below; an
///                        arm with no target needs its own notion of attractive.
///
///      Everything else — the rungs, `_warpTo`, `_fill`, the recording — is shared, so the two
///      arms differ by exactly what the control is meant to isolate.
abstract contract PricePathEngine is CommonBase, StdCheats {
    // -----------------------------------------------------------------------------------
    // How the walk touches the chain — three primitives, for the live driver (T29)
    // -----------------------------------------------------------------------------------

    /// @dev Every write the walk makes goes through these three, so that ONE engine walks both
    ///      a forked EVM under cheatcodes (the tests, `PricePath`) and a running anvil node under
    ///      transactions (`script/LivePricePath.s.sol`, the UI's driver). The rungs, the taker
    ///      rule, the fill and the recording are shared; what differs is only how "Alice does X"
    ///      reaches the chain. `quote` is the one call that stays a prank in both: it is a read,
    ///      and a prank outside a broadcast is plain simulation.
    ///
    ///        `_as(who)` / `_done()`  act as `who` until `_done()`: prank here, broadcast live.
    ///        `_deal(token, who, x)`  give `who` exactly `x` of `token`: the cheatcode here; live,
    ///                                the shell dealt over RPC beforehand and this only checks.
    ///        `_warpTo(hf)`           move both collateral prices so Alice lands on `hf`:
    ///                                `OracleWarp` here, the same feed migration as transactions
    ///                                live. The arithmetic is the same on both sides.
    function _as(address who) internal virtual {
        vm.startPrank(who);
    }

    function _done() internal virtual {
        vm.stopPrank();
    }

    function _deal(address token, address who, uint256 amount) internal virtual {
        deal(token, who, amount);
    }

    // -----------------------------------------------------------------------------------
    // The world, fixed
    // -----------------------------------------------------------------------------------

    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant WETH = Addresses.WETH;
    address internal constant WBTC = Addresses.WBTC;
    address internal constant USDC = Addresses.USDC;

    IAaveV3PoolFixture internal constant POOL = IAaveV3PoolFixture(Addresses.AAVE_V3_POOL);
    IPoolAddressesProvider internal constant PROVIDER =
        IPoolAddressesProvider(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER);

    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant VARIABLE_RATE = 2;
    uint256 internal constant LEGS = 3;

    /// @dev One value unit is `price(1e8) * 10 ** (18 - decimals)` per wei, so a leg's value is
    ///      `balance * unit` and one US dollar is 1e26 of them.
    uint256 internal constant VALUE_PER_USD = 1e26;

    /// @dev Alice's Aave position — T8's shape, T22's numbers.
    uint256 internal constant AAVE_WETH_COLLATERAL = 100e18;
    uint256 internal constant AAVE_WBTC_COLLATERAL = 3e8;

    /// @dev The value of the basket she ships, in value units ($80,000). Its COMPOSITION is not
    ///      typed: `shippedAmounts` derives it from the curve's top row at the pinned prices, so
    ///      the basket starts where the borrower said it should be at HF 2.00 and the first rung
    ///      has nothing to take. Her USDC leg is USDC she borrowed.
    uint256 internal constant SHIPPED_VALUE = 80_000 * VALUE_PER_USD;

    /// @dev The per-fill cap she signs into the args: 5% of the basket's value per fill.
    uint16 internal constant MAX_SHIFT_BPS = 500;

    /// @dev At most four fills a rung, so a rung can close at most 20% of the basket. The cap is
    ///      the reason more than one taker arrives at a rung at all: a single fill cannot take
    ///      the whole discount (`FreeboardExtruction.FreeboardFillExceedsMaxShift`).
    uint256 internal constant MAX_FILLS_PER_STEP = 4;

    /// @dev A fill worth less than one basis point of the basket is not worth a taker's gas, and
    ///      stopping there is what makes the fill count per rung a fixed, decidable number rather
    ///      than a race to the last wei.
    uint256 internal constant DUST_BPS = 1;

    /// @dev The taker's float. Large enough that no fill on the path is limited by it — asserted,
    ///      not assumed (`test_PricePath_WalksTheCurveDown_AndEveryFillIsTowardTarget`).
    uint256 internal constant TAKER_WETH = 100 ether;
    uint256 internal constant TAKER_WBTC = 10e8;
    uint256 internal constant TAKER_USDC = 1_000_000e6;

    bytes internal constant INSTRUCTIONS_ARGS = hex"c0ffee";

    // -----------------------------------------------------------------------------------
    // The transcript
    // -----------------------------------------------------------------------------------

    /// @notice One fill: what the taker offered, what the basket paid, and what actually moved.
    /// @param legIn Curve leg index of the token the taker pays in (0 WETH, 1 WBTC, 2 USDC).
    /// @param legOut Curve leg index of the token the taker takes out.
    /// @param quotedOut `quote()`'s answer, taken before the swap.
    /// @param referenceOut `PricingReference`'s answer for the same fill — the price derived by
    ///        integrating the marginal spread rather than by the distance delta.
    /// @param fairOut What the oracle alone would pay: `valueIn / unitOut`, no spread.
    /// @param spreadValue `valueIn - amountOut * unitOut` when positive — what the borrower kept,
    ///        value units. Zero for a fill that paid her less than the oracle.
    /// @param shiftBps The share of the basket this fill moved, against the maker's cap.
    /// @param takerPaid/takerGot/makerGot/makerPaid Real ERC-20 balance deltas.
    /// @param lossValue `amountOut * unitOut - valueIn` when positive — what the borrower gave
    ///        away above the oracle. Always zero on a Freeboard fill (no fill beats the oracle);
    ///        the paired control's unguarded arm (T27) is where it is not.
    struct Fill {
        uint256 legIn;
        uint256 legOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 quotedOut;
        uint256 referenceOut;
        uint256 fairOut;
        uint256 valueIn;
        uint256 spreadValue;
        uint256 shiftBps;
        uint256 takerPaid;
        uint256 takerGot;
        uint256 makerGot;
        uint256 makerPaid;
        uint256 lossValue;
    }

    /// @notice One rung: the oracle move, the health factor it produced, the target it slid to,
    ///         and the fills the taker took against it.
    struct Step {
        uint256 targetHf;
        uint256 healthFactor;
        uint256[] prices;
        uint256[] targets;
        uint256[] balancesBefore;
        uint256[] balancesAfter;
        uint256[] sharesAfter;
        uint256 totalBefore;
        uint256 distanceBefore;
        uint256 distanceAfter;
        Fill[] fills;
    }

    /// @notice The whole run. `keccak256(abi.encode(run))` is what "identical" means.
    /// @dev `aWeth`/`aWbtc`/`debt` are Alice's Aave balances at both ends of the walk. Freeboard
    ///      never touches the debt and never touches the collateral behind it (CLAUDE.md, "WHAT
    ///      FREEBOARD NEVER DOES"); recording both ends is what lets the test say so of a run of
    ///      nineteen fills rather than of one.
    struct Run {
        bytes32 strategyHash;
        uint256 borrowed;
        uint256[] shipped;
        Step[] steps;
        uint256 fills;
        uint256 spreadValue;
        uint256 lossValue;
        uint256[] finalBalances;
        uint256 startHealthFactor;
        uint256 finalHealthFactor;
        uint256 aWethAtStart;
        uint256 aWbtcAtStart;
        uint256 debtAtStart;
        uint256 aWethAtEnd;
        uint256 aWbtcAtEnd;
        uint256 debtAtEnd;
    }

    // -----------------------------------------------------------------------------------
    // Live state of one walk
    // -----------------------------------------------------------------------------------

    address internal alice;
    address internal taker;
    address internal aWeth;
    address internal aWbtc;
    address internal vDebtUsdc;

    FreeboardExtruction internal freeboard;
    ProgramBuilder.Position internal position;

    /// @dev What Alice's borrow put in her wallet; the basket's USDC leg comes out of it.
    uint256 internal borrowed;

    // -----------------------------------------------------------------------------------
    // The path
    // -----------------------------------------------------------------------------------

    /// @notice The rungs, top to bottom. The four that are curve breakpoints (2.00, 1.60, 1.30,
    ///         1.15) sit next to three that are not (1.80, 1.45, 1.20) — those interpolate — and
    ///         the last, 1.10, is BELOW the bottom breakpoint, so the curve clamps and the target
    ///         stops moving while the health factor keeps falling. Still well above 1.00: the
    ///         whole point is that the basket deleverages before a liquidator is entitled to.
    /// @dev RUNG 0 IS WARPED TOO. The borrow lands Alice a few parts in 1e12 under 2.00 (Aave
    ///      floors each reserve onto its 1e8 grid), and `_warpTo(2.00e18)` normalises that by
    ///      scaling both collateral prices up by about 1 + 7e-12 — two units of 1e8 on WETH. So
    ///      `WarpedPriceSource`s are installed at the TOP of the path, not first at 1.80, and the
    ///      prices the first fills see are the pinned mainnet prices nudged by that factor rather
    ///      than the pinned prices themselves. Deterministic, and harmless to every claim here;
    ///      recorded because "starts from mainnet prices" would otherwise be read as exact.
    function rungs() internal pure returns (uint256[] memory hf) {
        hf = new uint256[](8);
        hf[0] = 2.0e18;
        hf[1] = 1.8e18;
        hf[2] = 1.6e18;
        hf[3] = 1.45e18;
        hf[4] = 1.3e18;
        hf[5] = 1.2e18;
        hf[6] = 1.15e18;
        hf[7] = 1.1e18;
    }

    /// @notice Fork mainnet at the pin. Every consumer of this engine starts here.
    function createFork() internal {
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        require(forkBlock >= Addresses.MIN_FORK_BLOCK, "FORK_BLOCK is before the router exists");
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);
        require(block.chainid == Addresses.CHAIN_ID, "not forking Ethereum mainnet");
        require(ROUTER.code.length == Addresses.ROUTER_RUNTIME_SIZE, "deployed AquaSwapVMRouter runtime size");
        require(AQUA.code.length == Addresses.AQUA_RUNTIME_SIZE, "deployed Aqua runtime size");
    }

    /// @notice Deploy the pricing contract ONCE, from a fixed address, and keep it across forks.
    /// @dev The extruction's address is inside the program bytes, the program is inside the
    ///      strategy, and the strategy's hash keys Alice's Aqua balances — so the address is a
    ///      transcript input, and two things have to be pinned about it.
    ///
    ///      PERSISTENT, so re-forking between runs does not re-deploy it: a transcript that
    ///      differed by a nonce nobody chose would say nothing about determinism.
    ///
    ///      DEPLOYED BY A FIXED EOA at nonce zero on a fresh fork, so the address does not depend
    ///      on WHO walks the path. Without that, the run recorded by `PricePathWalker` under
    ///      `forge script` and the run reproduced by the test contract would carry different
    ///      strategy hashes and different transcripts while being, fill for fill, the same market
    ///      — and `results/price-path.txt` could not be checked against the test that reproduces
    ///      it. With it, they agree.
    function deployExtruction() internal {
        _as(deployer());
        freeboard = new FreeboardExtruction();
        _done();
        vm.makePersistent(address(freeboard));
        vm.label(address(freeboard), "FreeboardExtruction");
    }

    /// @dev The fixed EOA above. Its nonce-0 creation is the extruction; its nonce-1 creation,
    ///      made only by the live driver, is the `FreeboardLens` the UI reads through — so the
    ///      lens address is known to the run's JSON before anything is deployed.
    function deployer() internal returns (address) {
        return makeAddr("freeboard-deployer");
    }

    function lensAddress() internal returns (address) {
        return vm.computeCreateAddress(deployer(), 1);
    }

    /// @notice Alice's Aave position, her shipped basket, the taker's float — the state every
    ///         rung starts from. Called once per walk, on a fresh fork.
    /// @dev HOOK. An arm overrides this to ship a different program: call `_openAavePosition`,
    ///      set `position`, call `_ship` and `_fundTaker`. The three pieces are shared so that
    ///      the ONLY difference between arms is the bytes `position` carries.
    function buildWorld() internal virtual {
        _openAavePosition();
        position = ProgramBuilder.freeboardPosition(
            alice, address(freeboard), Curves.freeboard(), Curves.freeboardTokens(), MAX_SHIFT_BPS
        );
        _ship();
        _fundTaker();
    }

    /// @dev Alice: 100 WETH and 3 WBTC supplied, USDC borrowed to the top rung's health factor.
    function _openAavePosition() internal {
        IAaveProtocolDataProvider dataProvider = IAaveProtocolDataProvider(PROVIDER.getPoolDataProvider());
        (aWeth,,) = dataProvider.getReserveTokensAddresses(WETH);
        (aWbtc,,) = dataProvider.getReserveTokensAddresses(WBTC);
        (,, vDebtUsdc) = dataProvider.getReserveTokensAddresses(USDC);

        alice = makeAddr("alice");
        taker = makeAddr("freeboard-taker");

        _supply(alice, WETH, AAVE_WETH_COLLATERAL);
        _supply(alice, WBTC, AAVE_WBTC_COLLATERAL);
        borrowed = _borrowToHealthFactor(alice, rungs()[0]);

        vm.label(ROUTER, "AquaSwapVMRouter");
        vm.label(AQUA, "Aqua");
        vm.label(Addresses.AAVE_V3_POOL, "AaveV3Pool");
        vm.label(Addresses.AAVE_V3_ORACLE, "AaveOracle");
        vm.label(alice, "alice");
        vm.label(taker, "taker");
    }

    /// @dev The taker holds and approves all three legs, so any direction can settle.
    function _fundTaker() internal {
        _deal(WETH, taker, TAKER_WETH);
        _deal(WBTC, taker, TAKER_WBTC);
        _deal(USDC, taker, TAKER_USDC);
        _as(taker);
        IERC20(WETH).approve(ROUTER, type(uint256).max);
        IERC20(WBTC).approve(ROUTER, type(uint256).max);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        _done();
    }

    /// @notice The walk: build the world, then take every rung in order.
    /// @dev The return value is the entire observable run, in memory. Memory is not state, so a
    ///      caller may fork again and walk again without anything of the previous walk surviving
    ///      into the comparison.
    function walk() internal returns (Run memory run) {
        buildWorld();

        run.strategyHash = position.strategyHash;
        run.borrowed = borrowed;
        run.shipped = legBalances();
        run.startHealthFactor = healthFactorOf(alice);
        run.aWethAtStart = IERC20(aWeth).balanceOf(alice);
        run.aWbtcAtStart = IERC20(aWbtc).balanceOf(alice);
        run.debtAtStart = IERC20(vDebtUsdc).balanceOf(alice);

        uint256[] memory hfs = rungs();
        run.steps = new Step[](hfs.length);
        for (uint256 i = 0; i < hfs.length; ++i) {
            Step memory step = _step(hfs[i]);
            run.steps[i] = step;
            run.fills += step.fills.length;
            for (uint256 k = 0; k < step.fills.length; ++k) {
                run.spreadValue += step.fills[k].spreadValue;
                run.lossValue += step.fills[k].lossValue;
            }
        }

        run.finalBalances = legBalances();
        run.finalHealthFactor = healthFactorOf(alice);
        run.aWethAtEnd = IERC20(aWeth).balanceOf(alice);
        run.aWbtcAtEnd = IERC20(aWbtc).balanceOf(alice);
        run.debtAtEnd = IERC20(vDebtUsdc).balanceOf(alice);
    }

    /// @dev One rung: warp to it, read the target it slid to, then let takers arrive.
    function _step(uint256 targetHf) private returns (Step memory step) {
        _warpTo(targetHf);

        step.targetHf = targetHf;
        step.healthFactor = healthFactorOf(alice);
        step.prices = prices();
        step.targets = this.weightsAt(Curves.freeboard(), step.healthFactor);
        step.balancesBefore = legBalances();

        uint256[] memory before = values(step.balancesBefore);
        step.totalBefore = _sum(before);
        step.distanceBefore = BasketDistance.distance(before, step.targets);

        Fill[] memory taken = new Fill[](MAX_FILLS_PER_STEP);
        uint256 n;
        while (n < MAX_FILLS_PER_STEP) {
            // One read of the basket per fill: the numbers that size it are the numbers that
            // price its reference.
            Legs memory legs = readLegs();
            (bool attractive, uint256 legIn, uint256 legOut, uint256 amountIn) = nextFill(legs, step.targets);
            if (!attractive) {
                break;
            }
            taken[n++] = _fill(legs, step.targets, legIn, legOut, amountIn);
        }

        step.fills = new Fill[](n);
        for (uint256 k = 0; k < n; ++k) {
            step.fills[k] = taken[k];
        }

        step.balancesAfter = legBalances();
        uint256[] memory after_ = values(step.balancesAfter);
        uint256 total = _sum(after_);
        step.distanceAfter = BasketDistance.distance(after_, step.targets);
        step.sharesAfter = new uint256[](LEGS);
        for (uint256 l = 0; l < LEGS; ++l) {
            step.sharesAfter[l] = (after_[l] * ONE) / total;
        }

        _logStep(step);
    }

    /// @dev Move both collateral prices so that Alice lands on `targetHf`.
    ///      Health factor is `SUM(collateral_i * price_i * lt_i) / debt`, and the debt asset's
    ///      price is not touched, so scaling every collateral price by `targetHf / hf` scales the
    ///      health factor by exactly that — to the rounding of Aave's own 1e8 grid. The factor is
    ///      computed from the health factor the POOL reports, not from a running product, so each
    ///      rung is landed on rather than drifted toward.
    function _warpTo(uint256 targetHf) internal virtual {
        uint256 hf = healthFactorOf(alice);
        address[] memory collateral = new address[](2);
        collateral[0] = WETH;
        collateral[1] = WBTC;
        OracleWarp.scalePriceWad(collateral, (targetHf * ONE) / hf);
    }

    // -----------------------------------------------------------------------------------
    // The taker rule
    // -----------------------------------------------------------------------------------

    /// @notice What a taker takes here, or nothing.
    /// @dev Pay in the leg furthest BELOW its target, take out the leg furthest ABOVE it: that is
    ///      the fill the spread schedule prices at `SPREAD_TOWARD`, and no other pair of legs is
    ///      cheaper. Size it to the smallest of
    ///
    ///        - the in leg's shortfall, so that leg does not overshoot its target,
    ///        - the out leg's excess, so that leg does not undershoot its,
    ///        - `maxShiftBps` of the basket, the cap the maker signed,
    ///        - the out leg's whole value, which is all there is to take,
    ///
    ///      then round DOWN to a whole wei of the in token. Staying inside the first two bounds is
    ///      what makes the fill toward-target on both legs for its entire length, so it prices at
    ///      exactly ten basis points; the third is why a rung takes several fills instead of one.
    ///
    /// @dev The cap bound is exact, not approximate. With `x = floor(maxShiftBps * total / BPS)`
    ///      the extruction's own test is `ceilDiv(valueIn * BPS, total) <= maxShiftBps`, and
    ///      `valueIn <= x` gives `valueIn * BPS <= maxShiftBps * total`, so the fill is accepted
    ///      at the boundary rather than one wei past it.
    ///
    /// @dev HOOK. `legs` is the basket as it stands, read once by `_step` and handed to `_fill`
    ///      unchanged, so an arm's rule and the recording see the same numbers.
    /// @return attractive False when nothing is worth taking — no leg is under, none is over, or
    ///         the best fill is below the dust floor.
    function nextFill(
        Legs memory legs,
        uint256[] memory targets
    )
        internal
        view
        virtual
        returns (bool attractive, uint256 legIn, uint256 legOut, uint256 amountIn)
    {
        uint256 under;
        uint256 over;
        for (uint256 l = 0; l < LEGS; ++l) {
            uint256 have = legs.values[l] * ONE;
            uint256 want = targets[l] * legs.total;
            if (have < want && (want - have) / ONE > under) {
                under = (want - have) / ONE;
                legIn = l;
            }
            if (have > want && (have - want) / ONE > over) {
                over = (have - want) / ONE;
                legOut = l;
            }
        }
        if (under == 0 || over == 0 || legIn == legOut) {
            return (false, 0, 0, 0);
        }

        uint256 x = _min(under, over);
        x = _min(x, (MAX_SHIFT_BPS * legs.total) / BPS);
        x = _min(x, legs.values[legOut]);

        amountIn = x / legs.units[legIn];
        if (amountIn == 0 || amountIn * legs.units[legIn] * BPS < legs.total * DUST_BPS) {
            return (false, 0, 0, 0);
        }
        attractive = true;
    }

    /// @dev Quote it, price it independently, swap it, and record what actually moved. `legs`
    ///      is the snapshot `nextFill` sized the fill from.
    function _fill(
        Legs memory legs,
        uint256[] memory targets,
        uint256 legIn,
        uint256 legOut,
        uint256 amountIn
    )
        private
        returns (Fill memory fill)
    {
        address[] memory tokens = Curves.freeboardTokens();
        address tokenIn = tokens[legIn];
        address tokenOut = tokens[legOut];
        uint256[] memory unit = legs.units;

        fill.legIn = legIn;
        fill.legOut = legOut;
        fill.amountIn = amountIn;
        fill.valueIn = amountIn * unit[legIn];
        fill.fairOut = fill.valueIn / unit[legOut];
        fill.shiftBps = Math.ceilDiv(fill.valueIn * BPS, legs.total);
        fill.referenceOut = PricingReference.outValue(
            legs.values[legIn], legs.values[legOut], targets[legIn], targets[legOut], legs.total, fill.valueIn
        ) / unit[legOut];
        fill.quotedOut = quote(tokenIn, tokenOut, amountIn);

        uint256 takerIn = IERC20(tokenIn).balanceOf(taker);
        uint256 takerOut = IERC20(tokenOut).balanceOf(taker);
        uint256 makerIn = IERC20(tokenIn).balanceOf(alice);
        uint256 makerOut = IERC20(tokenOut).balanceOf(alice);

        fill.amountOut = swap(tokenIn, tokenOut, amountIn);

        fill.takerPaid = takerIn - IERC20(tokenIn).balanceOf(taker);
        fill.takerGot = IERC20(tokenOut).balanceOf(taker) - takerOut;
        fill.makerGot = IERC20(tokenIn).balanceOf(alice) - makerIn;
        fill.makerPaid = makerOut - IERC20(tokenOut).balanceOf(alice);
        uint256 valueOut = fill.amountOut * unit[legOut];
        fill.spreadValue = fill.valueIn > valueOut ? fill.valueIn - valueOut : 0;
        fill.lossValue = valueOut > fill.valueIn ? valueOut - fill.valueIn : 0;
    }

    // -----------------------------------------------------------------------------------
    // The position
    // -----------------------------------------------------------------------------------

    /// @dev `supply` auto-enables collateral on a first deposit into a reserve with LTV > 0.
    function _supply(address who, address asset, uint256 amount) private {
        _deal(asset, who, amount);
        _as(who);
        IERC20(asset).approve(Addresses.AAVE_V3_POOL, amount);
        POOL.supply(asset, amount, who, 0);
        _done();
    }

    /// @dev Inverts `GenericLogic` the way T8 does: `debtBase = SUM(collateral_i * lt_i) / HF`,
    ///      each leg on the 1e8 base-currency grid.
    function _borrowToHealthFactor(address who, uint256 targetHf) private returns (uint256 amount) {
        IAaveV3Oracle oracle = IAaveV3Oracle(PROVIDER.getPriceOracle());
        uint256 wethBase = (IERC20(aWeth).balanceOf(who) * oracle.getAssetPrice(WETH)) / 1e18;
        uint256 wbtcBase = (IERC20(aWbtc).balanceOf(who) * oracle.getAssetPrice(WBTC)) / 1e8;
        uint256 weighted = wethBase * Addresses.LT_WETH_BPS + wbtcBase * Addresses.LT_WBTC_BPS;
        uint256 debtBase = (weighted * 1e14) / targetHf;
        amount = (debtBase * 1e6) / oracle.getAssetPrice(USDC);

        _as(who);
        POOL.borrow(USDC, amount, VARIABLE_RATE, 0, who);
        _done();
    }

    /// @notice What she ships: `SHIPPED_VALUE` split by the curve's TOP ROW at the prices of the
    ///         moment, floored to a wei of each token.
    /// @dev HOOK. An arm whose instruction calls a different composition fair overrides this with
    ///      the same `SHIPPED_VALUE` split its own way (the paired control's stock constant-product
    ///      arm, which is at the oracle only with its legs equal in value).
    function shippedAmounts() internal view virtual returns (uint256[] memory amounts) {
        uint256[] memory w = this.weightsAt(Curves.freeboard(), rungs()[0]);
        uint256[] memory u = units();
        amounts = new uint256[](LEGS);
        for (uint256 l = 0; l < LEGS; ++l) {
            amounts[l] = (w[l] * SHIPPED_VALUE) / ONE / u[l];
        }
    }

    /// @dev Ships the three legs and approves Aqua without limit. T22 approves the exact shipped
    ///      amounts to make the point that the allowance, not the shipped balance, is what makes a
    ///      position fillable; a path of two dozen fills is where a real maker approves once, and
    ///      an allowance that ran out mid-path would be a fixture bug masquerading as a market.
    ///      Ships whatever `position` holds: the WETH and WBTC legs dealt to her wallet, the USDC
    ///      leg out of what she borrowed.
    function _ship() internal {
        address[] memory tokens = Curves.freeboardTokens();
        uint256[] memory amounts = shippedAmounts();
        require(amounts[2] <= borrowed, "the USDC leg is larger than the borrow");

        _deal(WETH, alice, amounts[0]);
        _deal(WBTC, alice, amounts[1]);

        _as(alice);
        bytes32 shippedHash = IAqua(AQUA).ship(ROUTER, position.strategy, tokens, amounts);
        for (uint256 l = 0; l < LEGS; ++l) {
            IERC20(tokens[l]).approve(AQUA, type(uint256).max);
        }
        _done();

        require(shippedHash == position.strategyHash, "ship() did not return keccak256(strategy)");
        require(ISwapVM(ROUTER).hash(position.order) == position.strategyHash, "router hash != strategy hash");
    }

    function _takerTraitsAndData() private view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.taker = taker;
        args.isExactIn = true;
        args.useTransferFromAndAquaPush = true;
        args.instructionsArgs = INSTRUCTIONS_ARGS;
        return TakerTraitsLib.build(args);
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        vm.prank(taker);
        (, amountOut,) = ISwapVM(ROUTER).quote(position.order, tokenIn, tokenOut, amountIn, _takerTraitsAndData());
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        _as(taker);
        (, amountOut,) = ISwapVM(ROUTER).swap(position.order, tokenIn, tokenOut, amountIn, _takerTraitsAndData());
        _done();
    }

    // -----------------------------------------------------------------------------------
    // Reading the world
    // -----------------------------------------------------------------------------------

    function healthFactorOf(address who) internal view returns (uint256 hf) {
        (,,,,, hf) = POOL.getUserAccountData(who);
    }

    /// @dev The oracle the EXTRUCTION reads: resolved from the addresses provider on every call,
    ///      exactly as `FreeboardExtruction._basket` resolves it, so a warp shows up here and
    ///      there identically.
    function prices() internal view returns (uint256[] memory p) {
        IAaveV3Oracle oracle = IAaveV3Oracle(PROVIDER.getPriceOracle());
        address[] memory tokens = Curves.freeboardTokens();
        p = new uint256[](LEGS);
        for (uint256 l = 0; l < LEGS; ++l) {
            p[l] = oracle.getAssetPrice(tokens[l]);
        }
    }

    /// @dev Value units per wei, as `FreeboardExtruction._unit` defines them.
    function units() internal view returns (uint256[] memory u) {
        uint256[] memory p = prices();
        u = new uint256[](LEGS);
        u[0] = p[0] * 10 ** (18 - 18);
        u[1] = p[1] * 10 ** (18 - 8);
        u[2] = p[2] * 10 ** (18 - 6);
    }

    /// @dev The three legs Aqua holds under Alice's strategy, through `safeBalances`.
    function legBalances() internal view returns (uint256[] memory balances) {
        balances = new uint256[](LEGS);
        (balances[0], balances[1]) = IAqua(AQUA).safeBalances(alice, ROUTER, position.strategyHash, WETH, WBTC);
        (, balances[2]) = IAqua(AQUA).safeBalances(alice, ROUTER, position.strategyHash, WETH, USDC);
    }

    function values(uint256[] memory balances) internal view returns (uint256[] memory v) {
        uint256[] memory u = units();
        v = new uint256[](LEGS);
        for (uint256 l = 0; l < LEGS; ++l) {
            v[l] = balances[l] * u[l];
        }
    }

    /// @notice The basket as it stands, in one read: balances, value units, values, total.
    /// @dev What `nextFill` sizes from and `_fill` prices from — the same snapshot for both.
    struct Legs {
        uint256[] balances;
        uint256[] units;
        uint256[] values;
        uint256 total;
    }

    function readLegs() internal view returns (Legs memory legs) {
        legs.balances = legBalances();
        legs.units = units();
        legs.values = new uint256[](LEGS);
        for (uint256 l = 0; l < LEGS; ++l) {
            legs.values[l] = legs.balances[l] * legs.units[l];
        }
        legs.total = _sum(legs.values);
    }

    /// @dev `Curve.weightsAt` reads calldata; this is the external hop that gives it some.
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }

    function _sum(uint256[] memory xs) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < xs.length; ++i) {
            total += xs[i];
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // -----------------------------------------------------------------------------------
    // Reporting
    // -----------------------------------------------------------------------------------

    function _symbol(uint256 leg) internal pure returns (string memory) {
        return leg == 0 ? "WETH" : leg == 1 ? "WBTC" : "USDC";
    }

    /// @dev Token decimals and how many of them are worth printing: two cents of USDC, but a
    ///      hundredth of a WBTC is eight dollars.
    function _decimals(uint256 leg) internal pure returns (uint256) {
        return leg == 0 ? 18 : leg == 1 ? 8 : 6;
    }

    function _places(uint256 leg) internal pure returns (uint256) {
        return leg == 0 ? 4 : leg == 1 ? 6 : 2;
    }

    function _amount(uint256 x, uint256 leg) internal pure returns (string memory) {
        return string.concat(_fixed(x, _decimals(leg), _places(leg)), " ", _symbol(leg));
    }

    /// @dev A value-unit quantity as dollars and cents.
    function _usd(uint256 value) internal pure returns (string memory) {
        return _fixed(value, 26, 2);
    }

    /// @dev A WAD fraction as a percentage: `0.5e18` reads `50.00`.
    function _pct(uint256 wad) internal pure returns (string memory) {
        return _fixed(wad * 100, 18, 2);
    }

    /// @dev A health factor, WAD, to two places. Rounded, not truncated — the warps land within
    ///      a few parts in 1e12 of a rung, and a truncating printer would call 2.00 "1.99".
    function _hf(uint256 wad) internal pure returns (string memory) {
        return _fixed(wad, 18, 2);
    }

    /// @dev `x`, which carries `decimals` decimals, printed with `places` of them, rounded
    ///      half-up. `places <= decimals`.
    function _fixed(uint256 x, uint256 decimals, uint256 places) internal pure returns (string memory) {
        uint256 divisor = 10 ** (decimals - places);
        uint256 scaled = (x + divisor / 2) / divisor;
        uint256 whole = scaled / 10 ** places;
        uint256 frac = scaled % 10 ** places;

        // Leading zeros, so `.05` does not print as `.5`.
        uint256 zeros = places - 1;
        for (uint256 t = frac; t >= 10; t /= 10) {
            --zeros;
        }
        string memory padding = "";
        for (uint256 z = 0; z < zeros; ++z) {
            padding = string.concat(padding, "0");
        }
        return string.concat(vm.toString(whole), ".", padding, vm.toString(frac));
    }

    /// @dev One rung, three shapes: where the curve moved the target, where the fills left the
    ///      basket, and what each taker paid for moving it.
    function _stepLine(Step memory step) internal pure returns (string memory) {
        return string.concat(
            "HF ",
            _hf(step.healthFactor),
            "  target ",
            _pct(step.targets[0]),
            " / ",
            _pct(step.targets[1]),
            " / ",
            _pct(step.targets[2]),
            "  basket ",
            _pct(step.sharesAfter[0]),
            " / ",
            _pct(step.sharesAfter[1]),
            " / ",
            _pct(step.sharesAfter[2]),
            "  distance ",
            _pct(step.distanceBefore),
            " -> ",
            _pct(step.distanceAfter)
        );
    }

    function _fillLine(Fill memory f) internal pure returns (string memory) {
        return string.concat(
            _amount(f.amountIn, f.legIn),
            " -> ",
            _amount(f.amountOut, f.legOut),
            "   spread $",
            _usd(f.spreadValue),
            "   shift ",
            vm.toString(f.shiftBps),
            " bps"
        );
    }

    function _logStep(Step memory step) private pure {
        console.log(string.concat("-- ", _stepLine(step)));
        for (uint256 k = 0; k < step.fills.length; ++k) {
            console.log(string.concat("     ", _fillLine(step.fills[k])));
        }
    }

    /// @notice The run as a report — the artifact T27's table, T29's UI and T32's video quote.
    function report(Run memory run) internal pure returns (string memory out) {
        out = string.concat(
            "Freeboard price path (T23)\n",
            "==========================\n\n",
            "strategy hash : ",
            vm.toString(run.strategyHash),
            "\n",
            "transcript    : ",
            vm.toString(keccak256(abi.encode(run))),
            "\n",
            "borrowed USDC : ",
            _amount(run.borrowed, 2),
            "\n",
            "shipped       : ",
            _basketLine(run.shipped),
            "\n\n"
        );

        for (uint256 i = 0; i < run.steps.length; ++i) {
            Step memory step = run.steps[i];
            out = string.concat(out, _stepLine(step), "\n");
            for (uint256 k = 0; k < step.fills.length; ++k) {
                out = string.concat(out, "    ", _fillLine(step.fills[k]), "\n");
            }
        }

        out = string.concat(
            out,
            "\nfills         : ",
            vm.toString(run.fills),
            "\n",
            "spread earned : $",
            _usd(run.spreadValue),
            "\n",
            "final HF      : ",
            _hf(run.finalHealthFactor),
            "\n",
            "final basket  : ",
            _basketLine(run.finalBalances),
            "\n"
        );
    }

    /// @notice The run as JSON — what the UI (T29) replays, and the addresses it reads live.
    /// @dev Every uint256 is a decimal STRING: JavaScript numbers lose integers above 2^53, and
    ///      a wei count of WETH is past that. Hand-assembled rather than `vm.serializeJson`, which
    ///      cannot express an array of structs of arrays without a key per element. `lens` is
    ///      where the live driver deploys the `FreeboardLens` (`lensAddress`), pinned here so the
    ///      page needs nothing but this file in either mode. `block` is the block the run was
    ///      recorded at — the pinned fork block under the tests, where the page's live mode
    ///      starts scanning for fills.
    function json(Run memory run) internal returns (string memory out) {
        address[] memory tokens = Curves.freeboardTokens();
        out = string.concat(
            "{\n",
            _kv("strategyHash", _q(vm.toString(run.strategyHash))),
            _kv("maker", _q(vm.toString(alice))),
            _kv("taker", _q(vm.toString(taker))),
            _kv("extruction", _q(vm.toString(address(freeboard)))),
            _kv("lens", _q(vm.toString(lensAddress())))
        );
        out = string.concat(
            out,
            _kv("router", _q(vm.toString(ROUTER))),
            _kv("aqua", _q(vm.toString(AQUA))),
            _kv("pool", _q(vm.toString(Addresses.AAVE_V3_POOL))),
            _kv("tokens", _addrs(tokens)),
            _kv("symbols", "[\"WETH\", \"WBTC\", \"USDC\"]"),
            _kv("decimals", "[18, 8, 6]")
        );
        out = string.concat(
            out,
            _kv("curve", _q(vm.toString(Curves.freeboard()))),
            _kv("maxShiftBps", vm.toString(MAX_SHIFT_BPS)),
            _kv("borrowed", _q(vm.toString(run.borrowed))),
            _kv("shipped", _arr(run.shipped)),
            _kv("fills", vm.toString(run.fills)),
            _kv("spreadValue", _q(vm.toString(run.spreadValue)))
        );
        out = string.concat(
            out,
            _kv("startHealthFactor", _q(vm.toString(run.startHealthFactor))),
            _kv("finalHealthFactor", _q(vm.toString(run.finalHealthFactor))),
            _kv("finalBalances", _arr(run.finalBalances)),
            _kv("block", vm.toString(block.number)),
            "\"steps\": ["
        );
        for (uint256 i = 0; i < run.steps.length; ++i) {
            out = string.concat(out, i == 0 ? "\n" : ",\n", _stepJson(run.steps[i]));
        }
        out = string.concat(out, "\n]}\n");
    }

    function _stepJson(Step memory step) private returns (string memory out) {
        out = string.concat(
            "{",
            _kv("targetHf", _q(vm.toString(step.targetHf))),
            _kv("healthFactor", _q(vm.toString(step.healthFactor))),
            _kv("prices", _arr(step.prices)),
            _kv("targets", _arr(step.targets)),
            _kv("balancesBefore", _arr(step.balancesBefore))
        );
        out = string.concat(
            out,
            _kv("balancesAfter", _arr(step.balancesAfter)),
            _kv("sharesAfter", _arr(step.sharesAfter)),
            _kv("totalBefore", _q(vm.toString(step.totalBefore))),
            _kv("distanceBefore", _q(vm.toString(step.distanceBefore))),
            _kv("distanceAfter", _q(vm.toString(step.distanceAfter))),
            "\"fills\": ["
        );
        for (uint256 k = 0; k < step.fills.length; ++k) {
            out = string.concat(out, k == 0 ? "" : ", ", _fillJson(step.fills[k]));
        }
        out = string.concat(out, "]}");
    }

    function _fillJson(Fill memory f) private pure returns (string memory out) {
        out = string.concat(
            "{",
            _kv("legIn", vm.toString(f.legIn)),
            _kv("legOut", vm.toString(f.legOut)),
            _kv("amountIn", _q(vm.toString(f.amountIn))),
            _kv("amountOut", _q(vm.toString(f.amountOut))),
            _kv("quotedOut", _q(vm.toString(f.quotedOut)))
        );
        out = string.concat(
            out,
            _kv("fairOut", _q(vm.toString(f.fairOut))),
            _kv("valueIn", _q(vm.toString(f.valueIn))),
            _kv("spreadValue", _q(vm.toString(f.spreadValue))),
            "\"shiftBps\": ",
            vm.toString(f.shiftBps),
            "}"
        );
    }

    function _addrs(address[] memory xs) private pure returns (string memory out) {
        out = "[";
        for (uint256 i = 0; i < xs.length; ++i) {
            out = string.concat(out, i == 0 ? "" : ", ", _q(vm.toString(xs[i])));
        }
        out = string.concat(out, "]");
    }

    function _kv(string memory key, string memory value) private pure returns (string memory) {
        return string.concat("\"", key, "\": ", value, ", ");
    }

    function _q(string memory s_) private pure returns (string memory) {
        return string.concat("\"", s_, "\"");
    }

    function _arr(uint256[] memory xs) private pure returns (string memory out) {
        out = "[";
        for (uint256 i = 0; i < xs.length; ++i) {
            out = string.concat(out, i == 0 ? "" : ", ", _q(vm.toString(xs[i])));
        }
        out = string.concat(out, "]");
    }

    function _basketLine(uint256[] memory balances) internal pure returns (string memory) {
        return string.concat(_amount(balances[0], 0), " / ", _amount(balances[1], 1), " / ", _amount(balances[2], 2));
    }
}

/// @title PricePathWalker — the engine, deployed
/// @notice The walk runs from a DEPLOYED contract rather than from the script itself, because
///         `OracleWarp` grants Aave's `ASSET_LISTING_ADMIN_ROLE` to `address(this)` and forge
///         refuses to let a script contract rely on its own address (`script_execution_protection`,
///         on by default and left on). A `Test` contract has a stable address and inherits the
///         engine directly; a script deploys this.
contract PricePathWalker is PricePathEngine {
    function walkAndReport() external returns (string memory report_, string memory json_) {
        deployExtruction();
        Run memory run = walk();
        return (report(run), json(run));
    }
}

/// @title PricePath — the runnable form of the scripted market
/// @notice `forge script script/PricePath.s.sol` walks the path on a mainnet fork and writes
///         `results/price-path.txt` and its JSON twin `results/price-path.json`, the UI's data
///         (T29). Simulation only: nothing here is broadcast, and the oracle
///         warps are cheatcodes, so this cannot be pointed at a live chain by accident.
contract PricePath is Script, PricePathEngine {
    function run() external {
        createFork();
        (string memory out, string memory data) = new PricePathWalker().walkAndReport();
        vm.writeFile("results/price-path.txt", out);
        vm.writeFile("results/price-path.json", data);
        console.log(out);
    }
}
