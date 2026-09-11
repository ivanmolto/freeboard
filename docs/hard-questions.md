# Hard questions

The questions Freeboard gets asked, and what in the repo answers each one. Every
answer ends in a test you can run, or says plainly that there isn't one.

`forge test` — 130 tests, 20 suites, 0 failed.

---

## The curve is public

### A public HF→weights curve tells an attacker exactly what the basket will sell. Isn't that front-runnable?

**Not for a *continuous* curve.** Front-running a rule needs a moment worth
waiting for, and a curve interpolated between breakpoints has none. Four things
an observer might try:

1. **Wait for the worst moment.** There isn't one. The basket sells a little at
   every health factor, so there is no cliff where a large forced sale appears.
2. **Push the health factor to where the curve is juiciest.** See
   [below](#can-someone-push-my-health-factor-to-where-the-curve-pays-best) — HF
   moves with Aave's oracle and the borrower's own debt, neither flash-loanable.
3. **Front-run another taker's fill.** The first taker gets the better price, the
   second a worse one. That is MEV among takers, as on any AMM; the borrower's
   basket was rebalanced at the curve price either way.
4. **Take the whole rebalance in one block at the deepest price.** No fill ever
   beats the oracle, so there is no price below fair to drain at, and the
   per-fill cap bounds the composition change regardless.

The intuition that flips it: a public curve means *more* takers compete for the
same fill, which pushes the price toward the curve rather than away from it.
Secrecy shrinks the set of counterparties; it does not protect the borrower.

This is why a revision dropped a Chainlink CRE enclave that existed only to hide the
curve. An enclave is a liveness dependency on a liquidation guard, and it was
buying secrecy that a continuous curve does not need.

> `Curve.weightsAt` interpolates linearly between breakpoints and clamps outside
> them — `test_Interpolated_OneWeiOffABreakpointUsesTheSegmentBetween`,
> `testFuzz_Weights_AreMonotoneInHealthFactor`,
> `test_Clamp_AboveTheTopBreakpointIsTheTopRow`. Full argument:
> `docs/freeboard-v0.md` §7.

### Can someone push my health factor to where the curve pays best?

**No, and they cannot point the read at anyone else's position either.** The
health factor comes from Aave's oracle and the borrower's own debt. Neither is
flash-loanable, and neither moves on the swap path.

The subject of the read is not an input to the program. `_healthFactor` is called
with `query.maker` — the address the *router* names from the order — never an
address decoded from args and never from taker data. `IAaveV3Pool` declares one
function and the pool address is a compile-time constant, so neither the subject
nor the oracle of the read is chooseable. A strategy that could name its subject
would let a maker price their basket off a stranger's liquidation risk. Freeboard
makes that unexpressible rather than merely forbidden.

> `test_HealthFactor_IsReadForQueryMaker`,
> `test_ArgsCannotRedirectTheReadToAnotherPosition`,
> `test_Seize_DoesNotMoveThePrice`.

---

## The health factor

### What if the health factor is simply wrong?

**One fill moves at most `maxShiftBps` of the basket's value, whatever the
cause.** A wrong oracle, a curve the borrower mis-signed, a taker who found
something nobody thought of — the cap does not care why. It is checked once,
after pricing, on the amounts that actually settle, in any direction and on
either side.

Two bounds sit side by side:

- **On value** — no fill ever beats the oracle. Even a pure toward-target fill
  pays the maker ten basis points, so whoever moves the basket pays for it.
- **On composition** — the per-fill cap. What a wrong HF can still do is move the
  basket to the wrong *composition* at a *fair price*, and that is exactly what
  the cap bounds.

The cap is per fill, not per block, and that is deliberate: `extruction()` is
`view` and keeps no count. A per-block budget would need storage written on the
swap path, which gives up the structural quote/swap consistency argument below,
and would ration the very deleveraging the basket exists to do.

> `test_AWrongHealthFactor_CannotRestructureTheBasketInOneFill`,
> `testFuzz_EveryFillInAnySequence_IsWithinTheCap` (256 runs),
> `testFuzz_Pricing_NeverBeatsTheOracle_AndNeverExceedsTheAwaySpread`,
> `test_RevertWhen_SingleFillExceedsMaxShiftPct`.

The first version of this cap bounded the *change in basket distance*, and that
metric turned out to be blind along a whole family of fills: one leg moving
toward its target and the other away leaves the L1 distance unchanged however
much value moves. Under it a taker could take two thirds of a leg in one fill
against a 500 bps cap. Value moved has no blind direction and bounds the distance
change from above, so it carries both claims for one comparison.

> `test_AMixedFill_MovesNoDistance_AndIsCappedAllTheSame`.

### What if Aave cannot compute the health factor at all?

**The fill reverts.** No try/catch, no default health factor, no fallback row of
the curve. A default is a price, and a price computed from a number Aave would
not stand behind is exactly the mispricing this contract exists to prevent.

Refusing costs the borrower nothing. Aave's own `liquidationCall` reads the same
oracle through the same `calculateUserAccountData`, so while the health factor is
unreadable no liquidation is possible either — there is nothing to be late for.

The read is a low-level `staticcall` checked for exactly six words, so "no pool
there", "the pool reverted" and "the pool answered short" all become one named
refusal: `FreeboardHealthFactorUnreadable(maker)`.

> `test_RevertWhen_HealthFactorUnreadable` — both revert shapes found on mainnet,
> on both paths, both sides, both directions, with a counted `expectCall` of zero
> proving nothing else is read afterwards. Also
> `test_RevertWhen_ThePoolCallReverts`, `test_RevertWhen_ThePoolHasNoCode`,
> `test_RevertWhen_ThePoolReturnsTheWrongShape`.

Separately: Aave's no-debt sentinel (`type(uint256).max`) is an *answer*, not a
failure. It prices at the **top** of the curve — the loosest target — because
with no debt there is nothing to deleverage. No special case; the clamp handles
it. `test_NoDebt_PricesAtTopOfCurve`, `test_NoDebtSentinel_MaxUint256_ClampsToTheTop`.

### You call an external contract inside the pricing path. 1inch warns that breaks quote/swap consistency.

**It is structural here, not hoped-for.** `extruction()` is declared `view`, so
it cannot write state — there is no side effect for `quote()` and `swap()` to
differ by. One `view` implementation satisfies both `IStaticExtruction` and
`IExtruction`, whose parameter lists are identical and whose selectors therefore
agree.

And the dependency is deterministic: `getUserAccountData` is a view over the
pool's own state and its oracle, with no writes and no time dependence, so within
one block it returns one number. `quote()` reaches it under `STATICCALL` and
`swap()` under `CALL`, and the two return identical bytes.

> `test_QuoteAndSwapPaths_ReturnIdenticalRegisters` on the **deployed** router,
> `test_StaticCall_AndCall_AgreeWithinTheSameBlock`,
> `test_StaticCall_ReadsIdenticallyAtEveryDepth`,
> `test_PinnedSwapVM_ExtructionSelectorsAgree`.

---

## The design

### Isn't this just a stop-loss, or a signed price floor?

**A floor stops you trading at the exact moment you most need to trade.** Below
it, nothing fills — which is the same cliff as a liquidation trigger, wearing a
different hat. Freeboard has no level at which it refuses to trade. It re-prices:
as the health factor falls, the deleveraging direction gets progressively
cheaper for the taker and the opposite direction progressively dearer.

A floor answers *how do I stop a bad fill*. Freeboard answers *how do I keep
filling when things get bad, and get paid for it*.

> `test_AsHealthFactorFalls_TheDeleveragingFillBecomesTheCheapOne`,
> `test_TowardTarget_PricesBetterThan_AwayFromTarget`.

### Why not just trigger a deleverage at HF 1.15?

**Because a trigger sells everything at the worst moment, into the thinnest
book, at the price everyone else is also selling into.** A sliding target has no
cliff: deleveraging starts gently high on the curve and intensifies
continuously. By the time the position is near liquidation it is already mostly
in the debt asset, having been *paid* a spread the whole way down instead of
paying a liquidation bonus at the end.

The incentive appears on its own, too. As the health factor falls, an untouched
basket drifts further from its target without anyone doing anything — which is
precisely what makes the rebalancing fill attractive.

> `test_Normal_AnUnchangedBasketDriftsFromTargetAsHealthFactorFalls`.

### Why not a keeper or a TEE in the pricing path?

**Because every one of those is a liveness dependency on a liquidation guard.**
If the keeper is down, the enclave is unreachable, or the attestation is stale,
the position is either frozen or unprotected at the moment it matters. There is
no third outcome.

Freeboard has no writer. The health factor is read from Aave in the same block as
the fill, inside the pricing path. Move the oracle and the *next* fill prices
against the new target with nobody having written anything in between. The
keeper agent in `agent/` is a taker, not a writer: it decides what to fill, never
what the target is, and the basket re-prices the same whether it is running or not.

> `test_EndToEnd_TheNextFillPricesAgainstTheNewTarget_WithNobodyWritingInBetween`.

This is also the answer to "why not hide the curve in an enclave": the enclave
exists to hide a cliff, and a continuous curve has no cliff to hide.

### Can a taker drain the basket over many small fills?

**Not below fair value, and not into an arbitrary composition.** The value bound
holds per fill and therefore over any sequence: no fill beats the oracle, so
every fill pays the maker. The composition bound is the cap, applied to each
fill, each one re-reading the health factor and the live basket.

Splitting a fill buys at most 0.9 bps of the first slice, and only across a
target crossing — measured, and the single fill is the one that overcharges.
The spread schedule is convex along a move — the marginal spread never
decreases — so a larger fill never gets a better average price than a smaller
one. But a sequence is not priced along exactly the path of one large fill:
the pricing rule models a move as if the whole value in left the out leg, while
the maker keeps the spread, so after the first slice the live basket is
`S(A)` larger than the single fill's model of that point and the second slice
reaches its target crossing that much later. The gap is at most
`(SPREAD_AWAY − SPREAD_TOWARD) × S(A)` — under 0.9 bps of the first slice — and
zero where nothing crosses. On the deployed router, a $60,000 WETH → USDC fill
split $20,000 / $40,000 pays the taker $0.0495 more than in one piece;
predicted to the wei by that formula (`results/invariants.txt`).

> `testFuzz_EveryFillInAnySequence_IsWithinTheCap`,
> `testFuzz_Pricing_IsMonotoneInSize`,
> `testFuzz_Pricing_IsMonotoneInDistanceReduction`,
> `test_AFillAcrossATarget_IsPricedPieceByPiece`,
> `testFuzz_ASplitFill_PaysAtLeastTheSingleFill_AndAtMostTheBoundMore`,
> `test_Additivity_TheGapIsTheSpreadTheSingleFillsModelDropped`.

---

## Scope and compliance

### What if the borrower revokes the allowance, moves the funds, or docks the strategy?

**The position stops being fillable, and nobody is exposed — because nothing is
ever owed.**

Aqua is allowance-based. It holds no tokens; settlement is `Aqua.pull`, which is
`IERC20(token).safeTransferFrom(maker, to, amount)` against the maker's own
wallet (aqua v1.0.0, `Aqua.sol:63-70`). `ship()` moves no tokens at all — it only
writes the balance mapping — so a shipped position with no allowance looks
healthy by every observable measure and is silently unfillable. That is the trap:
gate end-to-end tests on the **allowance**, never on `safeBalances`.

The consequence for a maker who walks is small and lands entirely on them. A
revoked allowance or an emptied wallet makes the transfer fail, and because a
swap is atomic — the taker's side and the maker's side settle in one transaction
— the whole fill reverts and the taker keeps their tokens. The taker pays gas;
that is the entire loss. Docking is not even silent: `rawBalances` reports
`tokensCount == 0xff`, and the extruction refuses by name with
`FreeboardLegNotInStrategy` rather than treating a missing leg as a zero balance.

**Why this is a design property and not luck.** Aqua's custody model has exactly
one failure mode: the maker can walk. Whether that is benign or fatal depends on
whether the app ever needs to *take* money from an unwilling maker. Freeboard
never does — the collateral being repriced is the maker's own, the taker brings
the other side, and both move in the same transaction. There is no moment at
which the maker owes something they have not already delivered.

An app that settles an obligation *after* the fact — an insurance payout, an
underwriting loss, a loan repayment — sits on the other side of that line, and
there the maker's incentive to walk peaks at exactly the moment they lose. For
those, funds in the maker's wallet are a solvency problem rather than a capital
efficiency win. Freeboard's design and Aqua's custody model agree, which is why
the allowance model costs it nothing.

> `test_AquaPath_ShipThenSwapMovesRealTokensOnBothSides` — asserts the allowance
> is zero, shows the fill reverting with `SafeERC20.SafeTransferFromFailed`
> before any state moves, then makes the position live with one `approve` and
> fills it. `test_RevertWhen_ACommittedLegIsNotInTheStrategy` — never shipped
> (`tokensCount == 0`) and docked (`0xff`), both refused by name.

### Does this touch my debt?

**No.** Freeboard never supplies, borrows or repays. It only changes what the
basket beside the loan is made of. The end-to-end fill test asserts the maker's
aToken and variable-debt balances are unchanged after real fills in both
directions.

> `test_OneShip_FillsEveryPair_OnTheDeployedRouter`.

### Your basket isn't Aave collateral. How does rebalancing it protect the loan?

**It does not raise the health factor, and nothing here claims it does.** The
basket is the borrower's wallet: `ship()` moves nothing and Aqua settles by
allowance, so a fill changes what the borrower holds outside Aave and leaves the
aTokens and the debt exactly where they were. Aave's health factor is computed
from those two, so no fill can move it. The tests assert this rather than skirt
it.

What Freeboard does instead is turn the borrower's non-Aave holdings into the
debt asset as their margin thins, and get them paid for it. Walk the eight-rung
path from HF 2.00 to 1.10 and an $80,000 basket shipped at the curve's top row
(16.02 WETH / 0.30 WBTC / 16,002 USDC) ends as 8.20 WETH / 0.127 WBTC / 39,435
USDC, with $24.47 of spread earned and worth $5,128 more than the same basket
held untouched. At the bottom of the curve the borrower holds more of what
repaying needs and less of the asset that is falling, and every step of that
shift was taken by a taker who paid ten basis points over the oracle for it.
Repaying is still the borrower's own action — Freeboard never touches the debt —
but the means to repay are sitting in the wallet, priced in, rather than needing
a sale into the same falling market. The same wallet down the same path with
swap-vm's stock constant-product instruction instead — the paired control,
`results/paired-control.txt` — ends with 17,888 USDC, $2,297 below hold, having
paid its takers $395.83.

Two things follow. First, the benchmark for Freeboard is not the health factor
but the borrower's **net exposure**: the basket's value in the collateral asset,
or the share of the debt it could repay, with Freeboard against holding the
shipped basket untouched. Second, Aave's liquidation is unchanged behind it, and
the oracle path in the tests stops at HF 1.10, so "never liquidated" on that
path is true of the untouched basket too and is not evidence for Freeboard.

> `test_EndToEnd_TheNextFillPricesAgainstTheNewTarget_WithNobodyWritingInBetween`
> — a state-diff recording across the oracle move shows no write to the aTokens
> or the debt token; `test_PricePath_WalksTheCurveDown_AndEveryFillIsTowardTarget`
> — the eight-rung path with the end balances above, aTokens and debt unchanged;
> `test_PairedControl_OneInstructionApart_AndFreeboardKeepsMore` — the control,
> every stock fill replayed against swap-vm's own formula to the wei.

### Did you fork or modify SwapVM?

**No.** The strategy executes on the deployed `AquaSwapVMRouter`
(`0x111111338c…`, swap-vm tag `v1.0.2`) through its own stock `_extruction`
instruction at opcode `0x20`. No router redeploy, no vendored 1inch source, no
new opcode. `package.json` pins `github:1inch/swap-vm#v1.0.2` and
`github:1inch/aqua#v1.0.0`, each matched to its deployed runtime.

That pin is the production commit, and it is checkable rather than claimed. 1inch
have said on Discord that 1.0.2 is "the only version that is currently in
production" and the rest is undeployed; `git ls-remote` puts the
`release/1.0.2` branch head and the `v1.0.2` tag at the same commit,
`32c687c2b73101fc26549e48fa1ff8a4d73afbac`, which is exactly what `yarn.lock`
resolves.

**And Freeboard is on the AMM side of the router's opcode split.** 1inch separate
AMM opcodes from limit-order opcodes by the shape of the curve — non-linear for
AMMs, a linear exchange ratio for limit orders — and new opcodes are going into a
separate `LimitSwapRouter`, not into `AquaSwapVMRouter`. Freeboard's spread is
convex in the size of the fill: the marginal rate changes where a leg crosses its
target, and a larger fill never gets a better average price. That is the
non-linear shape `AquaSwapVMRouter` was built for, and it needs nothing above
opcode `0x21`.

> `testFuzz_Pricing_IsMonotoneInSize`,
> `test_AFillAcrossATarget_IsPricedPieceByPiece`,
> `test_Repo_ContainsZeroModifiedSwapVMSource`,
> `test_Router_HasThePinnedRuntimeSizeAndNamesThePinnedAqua`,
> `test_Aqua_RuntimeMatchesAquaTagV1_0_0`,
> `test_Program_IsOneExtructionInstruction`.

### Why one maker, rather than routing a swap across many Aqua positions?

**Because the price is personal.** A Freeboard basket is one borrower's risk
policy — the curve they signed, over their own Aave position. Two borrowers at
different health factors are quoting different prices for the same pair because
their solvency differs, which is the entire point. There is no common price to
aggregate and no shared spread to distribute.

### What does the health factor read cost?

Measured cold on a mainnet fork, one fill through the deployed router:

| | gas |
|---|---|
| `quote()` through the deployed router | 266,670 |
| `swap()` through the deployed router | 395,762 |
| `FreeboardExtruction.extruction()`, router's exact inputs | 244,778 |
| `Aave Pool.getUserAccountData(maker)`, 2 reserves | 117,479 |

The Aave read is 44.0% of `quote()` and 29.6% of `swap()`. It is the largest
single cost and there is no way around it that does not reintroduce a writer.

> `results/gas.txt`, emitted by `test_Gas_OneFillThroughTheDeployedRouter`. Every
> figure cold, measured after restoring a state snapshot.

---

## Where this is weakest

Three things that are honestly open. They are here because a section like this is
worth nothing if it only contains questions with good answers.

### There is no guarantee anyone fills

The curve makes the deleveraging direction cheap. It cannot make someone take it.
If no taker arrives, nothing happens: the basket stays as it is and Aave's
ordinary liquidation still exists behind it, exactly as it would without
Freeboard. **Freeboard is a cheaper path that opens earlier, not a replacement
for liquidation.** A borrower who assumes it is one has misunderstood it.

What makes a fill likely rather than guaranteed is that it is priced to compete,
not to beg — see below.

### The taker's incentive is a competitive price, not a bounty

Worth being precise, because "arbitrageurs pay you a spread" can be misread as
"takers get paid". They do not. A pure toward-target fill costs the taker **ten
basis points over the Aave oracle**; the away direction costs a hundred. The
taker's advantage is the ninety basis points a toward-target fill does *not* pay
— against their own alternative venue, ten basis points over oracle is simply a
good quote for someone who wanted the token anyway.

So the flow Freeboard is competing for is ordinary routed flow, not a rescue
mission. That is a strength — it does not depend on altruism — but it means the
fill rate is a market question, and this repo does not answer market questions.

### Everything runs on a mainnet fork

The strategy executes on the real deployed router at `0x111111338c…` with real
Aave positions and real ERC-20 transfers, but on a local fork of Ethereum
mainnet at block 25,900,000, not on live mainnet. That is explicitly permitted
("real on-chain token transfers must be demonstrated; forks acceptable") and it
is the only way to test against contracts that exist only on mainnet — a public
testnet would mean redeploying the world and would forfeit the strongest evidence
in the submission. `FreeboardExtruction` itself is cheap to deploy for real
(≈1.58M gas) and carries no key, owner or upgrade path.

---

## Running the evidence

```bash
forge test
```

Any single answer above:

```bash
forge test --match-test test_AWrongHealthFactor_CannotRestructureTheBasketInOneFill -vv
```
