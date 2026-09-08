# NOTES-gas.md — T8

How gas is measured in this repo's fork tests, and what the HF read costs.
Source of every number: `test/fork/AaveHF.t.sol` (`AaveHealthFactorForkTest`) at `FORK_BLOCK=25900000`.

---

## 1. `vm.cool` does not produce a cold read here

Probed directly (forge 1.5.1, forge-std v1.11.0, mainnet fork):

| step | `Pool.getUserAccountData(empty user)` |
|---|---|
| first read in a test body | 20,151 |
| repeated | 4,651 |
| after `vm.cool(POOL)` | 4,651 |
| after `vm.cool` on all 5 accounts a state-diff recording showed the read touched | 4,651 |

It restores neither the cold-account nor the cold-SLOAD surcharge. A first
attempt at the gas section relied on it and reported two different "cold"
figures for the same 3-reserve read (122,207 and 170,207) depending on which
test ran the measurement — the tell that the number was cold-on-top-of-warm.

## 2. What does work: the `setUp` / test-body boundary

Foundry resets access lists between `setUp` and the test function:

| step | gas |
|---|---|
| read inside `setUp` | 20,151 |
| same read as the FIRST statement of the test body | 20,151 |
| repeated in the test body | 4,651 |

So a genuinely cold figure is obtained by making the read the first statement
of its own test function. That is why the gas section has one test per
measurement instead of one test with a table, and why cross-measurement
comparisons are against pinned constants, not a second measurement in the same
frame (which would be warm).

Cold is the number that matters: inside a swap, the extruction's STATICCALL
into Aave is the transaction's first touch of everything the read walks.

## 3. What the read walks

A 3-reserve read (WETH + WBTC collateral, USDC debt) touches **20 distinct
accounts in 33 accesses**: the Pool proxy and its implementation, the
`PoolAddressesProvider`, `AaveOracle`, three price sources — the WETH and WBTC
sources are cap adapters that each call a Chainlink aggregator proxy which
calls the aggregator behind it — two aTokens and one variable-debt token.
Most are two hops past anything `Addresses.sol` names, which is why a
hand-written cooling list could never have worked. Asserted by
`test_Gas_ColdReadTouchesTwentyAccounts`.

## 4. Measured cost of `Pool.getUserAccountData`

`vm.lastCallGas().gasTotalUsed` — the callee-perspective cost of the
STATICCALL, i.e. what an extruction's gas budget must cover.

| position | reserves touched | cold | warm |
|---|---|---|---|
| WETH + WBTC collateral, USDC debt | 3 | **180,707** | 35,207 |
| WETH collateral, USDC debt | 2 | **117,479** | 22,979 |
| never used Aave (empty user config) | 0 | 20,151 | 4,651 |

Marginal cost of the WBTC leg: 63,228 cold, 12,228 warm.

Reserve indices at FORK_BLOCK are WETH=0, WBTC=2, USDC=3.
`GenericLogic.calculateUserAccountData` walks the user's config bitmap up to
the highest set bit, so USDC at index 3 caps every Freeboard basket at four
iterations regardless of how many legs it holds.

## 5. Would a lens be cheaper?

The irreducible floor — three `getAssetPrice` + three `scaledBalanceOf`, cold,
measured as a `gasleft()` delta — is **131,452**. Aave's overhead above it is
**49,255** (27% of the read). That is the most a purpose-built lens could
save, at the cost of re-implementing Aave's rounding (`mulDivCeil` on debt,
floor on collateral), eMode, and per-reserve LT lookups — and a lens hardcoded
to the basket is blind to collateral the borrower adds outside it.

Aave ships nothing cheaper: `AaveProtocolDataProvider` has no health-factor
function (its dispatcher carries neither `getUserAccountData` nor any
`*HealthFactor` selector), and `UiPoolDataProvider.getUserReservesData` walks
all 67 reserves — **2,282,135 gas** for an empty user.

Decision: STATICCALL the Pool directly. `test_Gas_ColdReadFitsAnExtructionBudget`
asserts the cold read stays under 200,000.

## 6. `vm.snapshotState` / `vm.revertToState` DOES restore cold state (T14)

`vm.cool` does not (§1), but reverting to a state snapshot does. Probed on
the fork (forge 1.5.1), `Pool.getUserAccountData` on an empty user:

| step | gas |
|---|---|
| first statement of the test body | 25,362 |
| repeated | 5,362 |
| after `vm.revertToState` to a snapshot taken as the first statement | 25,360 |

The revert restores the journaled state the fork backend keeps, and the
warm-address and warm-slot marks live in it. So one test can take a snapshot
as its first statement and produce several independent COLD measurements by
reverting between them — which is how `test/fork/Pricing.t.sol` emits every
figure in `results/gas.txt` from a single test function, instead of §2's
one-test-per-measurement.

## 7. One fill through the deployed router (T14)

`results/gas.txt` is emitted by `PricingForkTest.test_Gas_OneFillThroughTheDeployedRouter`:
the Freeboard program on the deployed `AquaSwapVMRouter`, three-leg basket, maker
at HF 1.60 with a 2-reserve Aave position, taker sells 1 WETH for USDC. Read the
file for the numbers; they are not retyped here. The Aave read is the 2-reserve
cold figure from §4 exactly (117,479), which is the check that the snapshot
method above measures the same thing §2's method did.

