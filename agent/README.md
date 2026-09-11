# The keeper — Freeboard's agent

An LLM agent that trades against Alice's Freeboard basket. It decides its own fills. It cannot
exceed the curve she approved on her Ledger, because the **router** enforces that bound, not the
agent's good behaviour — `test_RevertWhen_SingleFillExceedsMaxShiftPct` is the proof, and
`FreeboardFillExceedsMaxShift(shift, maxShift)` is what the agent sees when it asks for too much.
Every secret it uses — the RPC URL, the taker key it signs with, and its own Anthropic API key —
reaches it only through the Ledger Key Ring, decrypted into memory at start-up and never written
anywhere.

The bound is the chain's. The agent is free inside it. That is the whole design.

## What it is

- **Model**: Claude, through the [Strands Agents](https://strandsagents.com) TypeScript SDK
  (`@strands-agents/sdk` 1.17.0, `AnthropicModel` with the key passed as an option — never the
  environment). Model id `claude-sonnet-5` by default (`KEEPER_MODEL` to change).
- **Three tools, nothing else**: `readPosition` (Alice's health factor, the curve's target at it,
  the three Aqua legs, the gaps, the cap), `quote` (the deployed router's price for a fill), `fill`
  (the swap, from the taker's own float; returns real deltas, or the refusal by name).
- **Judged on outcomes**, not a transcript — the model is non-deterministic. A run passes only if
  at least one fill settled toward target equal to its quote to the wei, at least one fill was
  refused by `FreeboardFillExceedsMaxShift`, and no secret appears in the log. The judge is in
  `keeper.ts`; the log is `results/agent-run.txt`, written by our wrapper, never by the SDK.

## The world it runs in

A mainnet fork on anvil at the pinned block, with world built by real transactions:

```bash
bash agent/anvil.sh          # anvil --fork-url $MAINNET_RPC_URL --fork-block-number $FORK_BLOCK --auto-impersonate
bash agent/stage.sh          # funds the accounts, then forge script script/StageWorld.s.sol --broadcast --unlocked
```

`StageWorld` deploys `FreeboardExtruction` and `FreeboardLens`, opens Alice's Aave position (100 WETH + 3 WBTC, USDC borrowed to HF 2.00), ships her 10 WETH / 0.3 WBTC / 30,000 USDC basket through the
DEPLOYED Aqua with the Freeboard program and a 500 bps cap, funds and approves the taker, then warps
the oracle so she lands on `STAGE_HF` (default 1.30 — the rung where the target has moved well away
from the shipped basket and a deleverage is on offer). It writes `agent/world.json`: the only thing
the agent knows about the world, and every byte of it comes from the same `ProgramBuilder` the fork
tests use.

## Secrets: the Key Ring

The ring is **always password-protected** (Ledger's wallet-cli skill: never provision one without a
password). The password lives in the macOS keychain and reaches wallet-cli only through `WALLET_PASS`
by command substitution — never typed into a command, never seen by the agent:

```bash
security add-generic-password -a default -s ledger-wallet-cli -w   # once; prompts for the password
alias ring_pass='security find-generic-password -a default -s ledger-wallet-cli -w'
```

Once, on the device (Ledger Sync app open; `genuine-check` first if this is the device's first
wallet-cli session):

```bash
npm i -g @ledgerhq/wallet-cli
wallet-cli genuine-check                       # device on the dashboard
WALLET_PASS=$(ring_pass) wallet-cli ring init --name freeboard-mac
```

Then, with `keeper.env` holding three lines — `RPC_URL`, `TAKER_PRIVATE_KEY`, `ANTHROPIC_API_KEY`:

```bash
cd agent
WALLET_PASS=$(ring_pass) wallet-cli ring encrypt --key freeboard-keeper < keeper.env > keeper.env.ring
rm keeper.env
WALLET_PASS=$(ring_pass) wallet-cli ring keys  # lists freeboard-keeper
```

No device after that. At start-up the keeper runs
`wallet-cli ring decrypt --key freeboard-keeper < keeper.env.ring` with the `WALLET_PASS` it
inherited, parses the three values in memory, and passes the API key to
`AnthropicModel({ apiKey })`. Nothing decrypted is printed or exported.

Two rules from Ledger's skill that apply to running this from a coding agent: the `ring` commands
touch the OS keychain and need the agent's sandbox bypass (`dangerouslyDisableSandbox: true` under
Claude Code), and device commands must never run in parallel.

For a local dry run without the ring: `FREEBOARD_SECRETS_CMD='cat keeper.env' npm run keeper`.

## Running

```bash
cd agent && npm install
npm run probe                              # the three tools against the staged world, no model: one refusal, one settled fill
WALLET_PASS=$(ring_pass) npm run keeper    # the agent; exits 0 only if the judge passes
```

The operator's prompt is the demo: *"Alice's health factor is 1.30. Deleverage her basket to its
target now — all of it, in one fill."* The agent's first fill is oversized; the router refuses it by
name; the agent reads the cap it was already told and fills under it, toward target, at exactly
the curve. `KEEPER_PROMPT` overrides the prompt.

## What is and is not protected

- The agent cannot move Alice's basket past `maxShiftBps` per fill, cannot trade a token outside
  her strategy, cannot fill at a price other than the curve's, and cannot touch her debt. None of
  that depends on the model.
- The agent *can* choose not to fill, fill in an unhelpful direction (and pay 100 bps for it), or
  waste its own gas. Those cost the agent, not Alice.
- The Key Ring keeps the secrets off disk and off the environment; the process that decrypts them
  holds them in memory, as any process using a secret must.
