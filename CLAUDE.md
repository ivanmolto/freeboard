## §A Shared context

```
PROJECT: Freeboard — a basket beside an Aave loan that rebalances itself toward
safety as health factor falls, and gets paid a spread to do it. Freeboard is the
distance from the waterline to the deck: the margin before a vessel takes
water. A borrower's health factor is freeboard.

THE INSIGHT
A rebalance and a deleverage are the same operation at different urgency. Both
are "sell some of X for Y according to a rule." The index rule is move toward
target weights. The guard rule is move toward solvency. So the target weights
are A FUNCTION OF HEALTH FACTOR.

  HF 2.00  ->  50% ETH / 30% WBTC / 20% USDC
  HF 1.60  ->  40% / 24% / 36%
  HF 1.30  ->  30% / 16% / 54%
  HF 1.15  ->  20% / 10% / 70%   (USDC is the debt asset)

Trades that move the basket TOWARD target price attractively; trades AWAY price
expensively. Arbitrageurs rebalance the borrower and pay a spread for it.

Why this beats a trigger: a conventional liquidation guard is binary — nothing,
nothing, then a fire sale at the worst moment into the thinnest book. A sliding
target has no cliff. Deleveraging starts gently at HF 1.8 and intensifies
continuously, paid for the whole way down.

ARCHITECTURE (two sponsors, one chain, nothing off-chain in the loop)

  Ledger device                     On-chain (mainnet fork)
  borrower reviews the     -sig->   ship() commits the program:
  curve on device and               [stock opcodes][_extruction 0x20]
  signs ship()                        [FreeboardExtruction][curve · maxShiftPct]
                                              |  strategy hash binds the curve
                                              v
                                    DEPLOYED AquaSwapVMRouter 0x111111338c…
                                              |  _extruction (0x20)
                                              v
                                    FreeboardExtruction  (immutable, view)
                                      _healthWeightedTarget
                                        staticcall Aave getUserAccountData(query.maker)
                                        curve(HF) -> target weights
                                        Aqua rawBalances -> the other basket legs
                                        basket distance before/after -> price
                                        revert if fill moves basket > maxShiftPct
                                        revert if HF unreadable
                                              |
                                              v
                                       Aqua settlement

  Human approves. Chain enforces.

WHY THE CURVE IS PUBLIC (Rev 4 — this replaced a Chainlink CRE enclave)
A public HF->weights curve looks front-runnable. For a CONTINUOUS curve it is
not: there is no cliff to wait for; HF cannot be pushed (Aave oracle + the
borrower's own debt, neither flash-loanable); front-running another taker's
fill hurts that taker, not the borrower; no fill beats the oracle, so there
is no price below fair to drain at; and a wrong HF moves the basket by at
most maxShiftPct PER FILL, on-chain (per fill, not per block: the view
extruction keeps no count, a sequence is bounded per fill and re-priced
along the same path, and a per-block budget would need state on the swap
path and would ration the deleveraging the basket exists to do). A public
curve means MORE takers
compete for the discount, which is what protects the borrower. Full argument:
docs/hard-questions.md, "The curve is public". Do not reintroduce off-chain
components to hide it.

WHY THE HF READ IS SAFE INSIDE THE PRICING PATH
Aave's getUserAccountData is a view over the pool's own state and its oracle:
deterministic within a block. extruction() is view. So quote() and swap() in
the same block see the same HF — the quote/swap consistency 1inch warns
external calls break holds because the dependency is deterministic. If Aave
cannot compute HF, the fill REVERTS: Aave's liquidationCall reads the same
oracle, so no liquidation is possible while HF is unreadable, and refusing to
trade costs the borrower nothing.

THE PRICING CORE (one, and only one) — delivered as an EXTRUCTION
_healthWeightedTarget, inside FreeboardExtruction.extruction():
  1. staticcall Aave v3 Pool.getUserAccountData(query.maker) -> HF. Always
     query.maker — never an address from args — so a strategy cannot point
     at somebody else's position
  2. curve(HF) -> target weights; the curve is decoded from args (after the
     router-stripped 20-byte target). Clamp above the top breakpoint and
     below the bottom; HF == type(uint256).max (no debt) clamps to the top
  3. read the non-swapped basket legs from Aqua rawBalances (uint248; reverts
     for a token outside the strategy — a missing leg is a revert, not zero);
     compute basket distance from target before and after the proposed trade
  4. price by the delta — set updatedSwap.amountOut (exact-in) / amountIn
  5. revert trades moving the basket more than maxShiftPct in one fill
  6. revert if the HF read fails
  return nextPC unchanged, choppedLength = 0, the re-priced SwapRegisters
Called by the DEPLOYED AquaSwapVMRouter (0x111111338c…) through its own
_extruction instruction, opcode 0x20 — PROVEN Sep 6 (T2) on both quote and
swap paths with exact calldata. No router redeploy. extruction() is declared
VIEW so one function satisfies both IStaticExtruction and IExtruction and
cannot write state. Runs on the multi-token XD path. The program is stock
opcodes + one _extruction, LAST in the byte stream, with NO fee opcode
(NOTES-instructions.md §3.4: fee opcodes nest what follows them and re-price
after it).

WHAT FREEBOARD NEVER DOES
Never touches the debt, and never touches the Aave position. No supply, borrow
or repay. It only changes what the basket beside the loan is made of. Do not
scope-creep into lending flows.

REPOS
- github.com/1inch/swap-vm — pinned to tag v1.0.2 (commit 32c687c). This is
  the commit live on 15 chains, proven byte-for-byte. NOT release/1.1 (merged
  into main on Apr 22, deployed nowhere) and NOT main (130 src commits past
  production, Fee.sol deleted, IProtocolFeeProvider signature changed).
- github.com/1inch/aqua — WE pin github:1inch/aqua#v1.0.0 (commit 81c26e4),
  the tag that is DEPLOYED (see VERIFIED FACTS). swap-vm v1.0.2 declares
  aqua#0.1.0; yarn nests that copy under swap-vm and remappings.txt routes
  every @1inch/aqua/ import to the top-level v1.0.0. Safe because between the
  two tags only src/AquaRouter.sol changed (Rescuable: Ownable + rescueFunds,
  constructor gains an owner arg); Aqua.sol, IAqua.sol, Balance.sol and
  AquaApp.sol are byte-identical; swap-vm src imports only IAqua.sol; nothing
  of ours deploys AquaRouter. TRAP: aqua's package.json "version" was NOT
  bumped at v1.0.0 — it still says 0.1.0. Verify by yarn.lock's resolved
  commit (81c26e46…), never by the version string.
- NEITHER is on npm (404). Depend via package.json git refs exactly as swap-vm
  does for aqua:  "@1inch/swap-vm": "github:1inch/swap-vm#v1.0.2"
  Freeboard is a STANDALONE repo that imports interfaces from it — not a fork.

VERIFIED FACTS — use these, they cost a week to gather
- Canonical Aqua FOR THE LIVE ROUTER is 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a
  (5,619 bytes) — read on Sep 5 from AquaSwapVMRouter(0x111111338c…).AQUA(),
  re-asserted by T2's setUp on the fork. 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31
  is a DIFFERENT contract (6,251 bytes). MATCHED Sep 6 (T4): it is
  src/AquaRouter.sol:AquaRouter at aqua tag v1.0.0 (commit 81c26e4), solc
  0.8.30, viaIR, 10M runs, prague. The 5,566 executable bytes ahead of the
  CBOR blob match a clean build byte-for-byte, and the deployed IPFS metadata
  digest (fa4e14c1…a40687) is reproduced exactly once the deployer's two extra
  remappings (hardhat/, hardhat-deploy/) are added — a source-exact match.
  Sourcify: runtimeMatch exact_match. Deployed at block 25,567,141; the router
  at 25,618,917, which is the inclusive fork-block floor. Pinned in
  src/constants/Addresses.sol; asserted by test/fork/PinnedAddresses.t.sol.
  Aqua holds no tokens (allowance-based), so v1.0.0's rescueFunds cannot
  touch a Freeboard position.
- Aqua.ship() SUCCEEDS with ZERO allowance. Valid strategy hash, non-zero
  balances, because shipping moves no tokens; the allowance is consumed only
  when a taker fills. A position missing its approval looks healthy by every
  observable measure and is silently never fillable. Gate end-to-end tests on
  ALLOWANCE, not safeBalances().
- SETTLED Sep 5 for the router: the live AquaSwapVMRouter IS tag v1.0.2
  (32c687c) — CBOR metadata hash and immutable-masked runtime both match a
  clean build. Its runtime is 20,541 bytes (re-read Sep 6). Read the DEPLOYED
  contract; a tag is a claim until bytecode agrees.
- The deployed table is 34 dense entries, 0x00-0x21: 0x00-0x09 Debug
  (reserved, no-op), 0x0a-0x10 Controls, 0x11 _xycSwapXD, 0x12
  _xycConcentrateGrowLiquidity2D, 0x13 _decayXD, 0x14 _salt, 0x15
  _flatFeeAmountInXD, 0x16-0x1a reserved holes, 0x1b-0x1e the four
  protocol-fee variants, 0x1f _peggedSwapGrowPriceRange2D, 0x20 _extruction,
  0x21 _onlyTxOriginTokenBalanceNonZero. Opcode >= 0x22 is an out-of-bounds
  panic. No 0x90-0xaf bank. The array literal declares 35 and dispatches 34:
  every opcode is literal position MINUS ONE (NOTES-instructions.md §1.1).
- There is NO balances instruction on AquaSwapVMRouter. balanceIn/balanceOut
  are preloaded by the router from AQUA.safeBalances before the program runs.
  PROGRAMS.md's examples open with _staticBalancesXD — they are for the full
  Opcodes set, not ours. Never copy one.
- Aqua is MakerTraits bit 254, useAquaInsteadOfSignature. AquaSwapVMRouter
  dispatches a REDUCED instruction set.
- Program wire format: [1 byte opcode][1 byte argsLength][args]. 255-byte cap
  per instruction. The nextPC handed to an instruction is already the offset
  of the NEXT instruction. test/utils/ProgramLib.sol encodes it.
- _extruction reads args.target from the first 20 bytes and hands
  args.slice(20) to the target. The router overwrites ctx.swap WHOLESALE with
  updatedSwap — copy every register forward or it is zeroed.
- Aqua indexes strategies by hash: ONE BYTE of drift between ship() calldata
  and the executed order surfaces as a cryptic "insufficient balance." Derive
  both from a single source of truth; make the ship->execute round trip your
  first test.
- TakerTraits are NOT a normal ABI struct: packed layout, 20-byte slice table,
  two bytes of flags, variable tail. Passing empty 0x as "no options" REVERTS
  because the parser still expects the first 22 bytes. Build them with
  TakerTraitsLib.build (internal pure, usable from tests); orders with
  MakerTraitsLib.build. TakerTraitsLib.validate requires amountOut > 0 and,
  exact-in, takerAmount == amountIn.
- EIP-170: the deployed router has 4,035 bytes of headroom under 24,576. MOOT
  under Route B. The number matters only for the T35 stretch.

BOUNTY RULES (1inch)
- Official Aqua/SwapVM contracts must be used. RELAXED by the sponsor on
  Discord: Aqua and AquaSwapVMRouter "don't have any important Ownable functions, so it doesn't matter whether you use your
  own deployment of these contracts or the ones that are already deployed."
  A thread in the sponsor Discord quoted the same two addresses for Arc and
  Robinhood mainnet, so the deployment is address-deterministic across chains. Route B stays the
  default because it is already PROVEN: the Freeboard strategy EXECUTES ON
  THE DEPLOYED ROUTER (0x111111338c…) via its own _extruction instruction.
  A redeploy of unmodified contracts is now plainly allowed; modifying router
  SOURCE was not addressed and stays under the next bullet. Evidence is
  test_QuoteAndSwapPaths_ReturnIdenticalRegisters on the deployed router, plus
  package.json pinning github:1inch/swap-vm#v1.0.2 — no fork, no modified
  SwapVM source in the repo.
- "You may modify SwapVM opcodes and define your own instructions" — permitted,
  not rewarded; scoring is on the POSITION. Confirmed on Discord: they 
  called an app where "swaps respect maker signed limits" "quite general" —
  lead the submission with the HF->weights curve, not the router plumbing.
  The inlined form is the T35 stretch; after the Sep 5 relaxation it carries
  only an effort cost, no compliance risk.
- Real on-chain token transfers must be demonstrated. Forks acceptable.
- Genuine commit history. No single-commit final-day entries. This is a
  QUALIFICATION gate: one commit per DoD, test name in the message, from Sep 5.

LEDGER: developers.ledger.com/ethonline, via the official @ledgerhq/wallet-cli
(Rev 5 — spiked Sep 9 against its source; docs/ledger-spike.md). The
borrower approves the HF->weights CURVE on device — a risk policy, not a key.
The curve is in the program; the program is what ship() commits to; so the
device signing ship() IS the approval, and the strategy hash carries it. The
CLI signs it as a TRANSACTION: `wallet-cli send --to <Aqua> --amount '0 ETH'
--data <ship calldata>` (send.ts:134-145; zero value is allowed when calldata
is present, coin-evm validateIntent.js:34-40). There is NO sign-only mode and
Ethereum goes through Ledger's explorer, not an RPC, so the device-signed
ship() lands on REAL MAINNET — inert: zero allowance, no Aave debt at that
address (HF = uint256.max, curve clamped to the top), against a
FreeboardExtruction deployed on mainnet for it. The fills stay on the fork.
No EIP-712, no custom DMK signer: the CLI exposes neither. `ring` does NOT
sign anything — it is LKRP encryption (AES-256-GCM under keys derived from
the device), the agent's secret store: one `ring init` on device with the
Ledger Sync app, no device afterwards. Ledger's own skills are installed at
.claude/skills/{wallet-cli,dmk} — command forms come from there
(`account discover ethereum`, `send ethereum-1 --to … --amount '0 ETH'`,
ring text mode `< in > out`), and their rules bind: the ring is ALWAYS
password-protected, the password is never a literal — keychain plus
`WALLET_PASS=$(security find-generic-password -a default -s ledger-wallet-cli -w)`
— the agent never handles it; device and `ring` commands need
dangerouslyDisableSandbox: true; never two device commands in parallel;
decrypted output is never printed; genuine-check on a device's first
wallet-cli session. The skill does not list `send --data`; the source does
(send.ts:134-145) — confirm with `send --help` before signing. Readable rows on the device need an
ERC-7730 descriptor published to Ledger's CAL — stretch; until then the
screen is a blind-signed contract call (Ethereum app: enable blind signing)
and the README says so. Human signs ship() (T24a); the agent below (T24b).

THE AGENT (Rev 5, Sep 9 — DECIDED: an LLM agent; no rule-based bot fallback)
The keeper-taker is an LLM agent, not a script. Ledger's track is "AI Agents
x Ledger"; a deterministic keeper answers "where is the AI?" with "nowhere".
Built on the Strands Agents TypeScript SDK — @strands-agents/sdk 1.17.0 on
npm Sep 9, Node >= 22 (machine: v22.17.1), peer @anthropic-ai/sdk — with the
Anthropic provider: class AnthropicModel (strands-ts/src/models/anthropic.ts:87),
options { apiKey?, modelId } (:81-96); the key is passed as an OPTION so it
never touches the environment. Tools: tool({ name, description, inputSchema:
<zod object>, callback }); the agent runs with agent.invoke(prompt). Model
claude-sonnet-5 (claude-opus-5 if its decisions are poor in the dry run).
Exactly three tools: readPosition (HF from the Pool, curve targets, the three
Aqua legs, distance), quote (deployed router, pair, amount), fill (swap on
anvil from the taker key). Every secret — RPC URL, taker key,
ANTHROPIC_API_KEY — is `wallet-cli ring decrypt`ed at start-up and held in
memory only. The agent DECIDES what to fill; the ROUTER decides what settles:
a fill past the cap reverts FreeboardFillExceedsMaxShift(shift, maxShift)
(FreeboardExtruction.sol:212, T15) and that refusal IS the demo beat — the
agent asked for too much, the chain said no, its next fill priced at exactly
the curve. That is Ledger's sentence "make autonomous behavior safer instead
of bypassing user intent": the human approved the curve on device; nothing
the agent decides can exceed it. Before writing agent code, QUOTE the SDK's
README and src/models/anthropic.ts at the installed version — the facts
above are from Sep 9 and the SDK moves fast. The LLM is non-deterministic:
the DoD asserts outcomes (fills toward target equal to their quotes; at
least one router refusal), never a transcript.

STACK: Foundry + Solidity; TypeScript for the UI, the Ledger flow and the
keeper agent (Strands Agents TS SDK + Anthropic, Node 22); mainnet-fork
tests at FORK_BLOCK=25900000 (.env), Aave v3. ONE chain.
SOLO, Sep 5-13 2026 (event started Sep 4; day one is gone).
```

---

## §B Guardrails

```
HOW I NEED YOU TO WORK

1. READ BEFORE WRITING. SwapVM, Aqua and the Ledger Key Ring CLI are all
   recent and thinly documented. Your training data on them is probably absent
   or wrong. Before any code touching them, open the real files or docs and
   QUOTE the actual signatures and fields you rely on. If you cannot find
   something, say so instead of inventing it.

2. NO INVENTED APIs. Unsure whether a function, opcode, event, handler or field
   exists? Grep or fetch the docs and show me the result.

3. NO STUBS OR TODOs unless I ask. If something can't be finished, stop and say
   why rather than leaving a placeholder I won't notice.

4. TESTS ARE THE DELIVERABLE. Each task's DoD is a passing test or runnable
   artifact. Write the test, show it failing, make it pass. Show real command
   output, not a description of it.

5. SMALL DIFFS. One task per session. Don't refactor adjacent code or improve
   files I didn't ask about.

6. ASK BEFORE DEVIATING. If my design can't work against the real source, stop
   and explain the conflict. Never silently substitute a different design.

7. NO NEW DEPENDENCIES without telling me what and why.

8. Finish with: files changed, the command proving the DoD, its output.

9. Never do a commit or push. These will done by a human (Ivan Molto)
```

---

