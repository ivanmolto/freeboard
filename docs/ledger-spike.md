# Ledger spike — what `wallet-cli` can sign, and what Freeboard signs with it

Sep 9 2026. Everything here is quoted from `@ledgerhq/wallet-cli@2.1.0`
(npm tarball: prebuilt binaries, README, CHANGELOG) and its source in
`LedgerHQ/ledger-live` at `apps/wallet-cli` on branch `develop`, plus
`@ledgerhq/coin-evm@5.3.1` (npm) and `libs/live-signer-evm`. Nothing was
installed into the repo. Where a claim rests on a file, the path and line are
given so it can be re-checked; the binary is closed, the source is not.

## 1. The CLI is two unrelated tools behind one binary

`send` is a signer. `ring` is a secrets manager. The Key Ring does not sign
anything; the signer does not use the Key Ring.

### `send` signs arbitrary EVM calldata on the device

`apps/wallet-cli/src/commands/send.ts:134-145`:

```ts
data: option(
  z.string().regex(/^0x([0-9a-fA-F]{2})*$/, "data must be 0x-prefixed hex ...").optional(),
  { description: "EVM calldata as 0x-prefixed hex (e.g. 0xd0e30db0)" },
),
```

`send.ts:53-58` builds the EVM intent as `{ family: "evm", recipient, amount, data }`.
Added in ledger-live PR #16435 ("add `--data` option for EVM calldata") and
#16386 (`data` on `EvmTransactionIntentSchema`, "enabling arbitrary EVM
contract interactions").

A zero-value call is accepted when calldata is present.
`@ledgerhq/coin-evm` `lib-es/logic/validateIntent.js:34-40`:

```js
if (!amount) {
    if (intentStakingMode === 'claimReward' || intentStakingMode === 'compoundReward') { ... }
    else if (!isSmartContractInteraction) {
        return { errors: { amount: new AmountRequired() }, warnings: {} };
    }
}
```

and `:325` passes `!!intent.data?.value?.length` as `isSmartContractInteraction`.

So the ship() command is:

```
wallet-cli send \
  --account ethereum-1 \
  --to 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a \
  --amount '0 ETH' \
  --data 0x<abi.encodeCall(IAqua.ship, (app, strategy, tokens, amounts))>
```

where `Aqua.ship(address app, bytes calldata strategy, address[] calldata tokens,
uint256[] calldata amounts)` (`@1inch/aqua/src/Aqua.sol:40`) and `strategy` is
the program bytes — the curve is inside the calldata the device signs.

### There is no typed-data or message signing in the CLI

None in the 463-line CHANGELOG, none in `src/commands/`. It exists one layer
down and is not exposed: `libs/live-signer-evm/src/DmkSignerEth.ts` has
`signPersonalMessage` (:126), `signTransaction` (:184) and `signEIP712Message`
→ DMK `signer.signTypedData` (:240-246); `libs/ledger-live-common/src/families/evm/signerMessage.ts`
wraps both (EIP-191 / EIP-712). Reaching them means writing our own DMK client.

### There is no sign-without-broadcast, and Ethereum goes through Ledger's explorer

`src/wallet/sign-and-broadcast.ts`: `signAndBroadcastIntent` opens the device
session, signs, and `bridge.broadcast` (`src/wallet/compatibility/bridge.ts:272`).
`--dry-run` "Prepare and validate transaction but do not sign or broadcast"
(`send.ts:147`) — it never touches the device. The signed raw transaction is
never printed.

`libs/ledger-live-common/src/families/evm/config.ts`, `config_currency_ethereum`:

```ts
gasTracker: { type: "ledger", explorerId: "eth" },
node:       { type: "ledger", explorerId: "eth" },
explorer:   { type: "ledger", explorerId: "eth" },
```

Nonce, gas, sync and broadcast go to Ledger's explorer backend, overridable
only by the `EXPLORER` env (`envBasedLedgerConfiguration`). **`wallet-cli send`
cannot target an anvil fork.** A device-signed ship() through the CLI lands on
mainnet or nowhere.

### `ring` is LKRP encryption

README, commands table: `ring init` — "One-time provisioning of your Ledger
Key Ring (LKRP) via the device"; `ring encrypt` / `ring decrypt` — "AES-256-GCM
encrypt/decrypt of files (`-i`/`-o`) or text (stdin/stdout) under a named key
(`--key`). **No device** after `init`; requires network to restore the
trustchain."; `ring keys` / `ring destroy`. CHANGELOG 2.0.0: "Keys are
AES-256-GCM, derived per-name with HKDF-SHA256 from the LKRP-shared root key;
the ring is recoverable from your Ledger."

`src/commands/ring/init.ts:83-88` — the device must have the **Ledger Sync**
app: `"Connect device, open Ledger Sync app — provisioning your Ledger Key Ring…"`,
then `sdk.getOrCreateTrustchain(WALLET_CLI_DMK_DEVICE_ID, memberCredentials)`.
The member's private key goes to the OS keychain, password-wrapped unless
`--unsecure-no-password`. Password via `WALLET_PASS` env, never on the command line.

This is Ledger's "agents that use secrets they cannot leak" item: the site
pitches it as replacing `.env`, `sops`, `age`; "headless operation for CI
pipelines and agents".

### Transport: one, USB. No Speculos.

`src/device/register-dmk-transport.ts:28` — `const MODULE_ID = "wallet-cli-dmk-webusb"`;
DMK over node WebUSB, one session per process. Nothing in `src/` mentions
Speculos. `src/apdu-proxy.ts` is an HTTP/WebSocket APDU proxy over the same
stack (Ledger's route for "hosts with no USB port") — a bun script, not a
registered command; not our track item.

### Clear signing

`DmkSignerEth` builds a CAL `ContextModule` (`setCalConfig({ url: `${calUrl}/v1`,
mode: calMode, branch: "main" })`, `calMode = "test"` when `CAL_SERVICE_URL`
contains `ledger-test` or `.stg.`). Calldata with no descriptor is blind-signed;
the app refuses unless enabled — error `6a80` → `"Please enable Blind signing or
Contract data in the Ethereum app Settings"` (`DmkSignerEth.ts:92-95`). The
screen shows the contract address and a hash of the data, not fields. Readable
rows need an ERC-7730 descriptor published to Ledger's CAL; the docs page
covers what a descriptor is and not the test/publication path. **Four readable
rows stays stretch.**

## 2. Decision: the artifact signed is the `ship()` transaction

Not EIP-712. Reasons:

1. `send --data` does it with zero custom code — the stack as shipped.
2. The EIP-712 path is not in the CLI; it would mean a bespoke DMK client, the
   "Ring CLI but using something else" shape the sponsor warned against (Oscar,
   Discord Sep 7), plus an `ecrecover` in the extruction for nothing: the Aqua
   strategy hash already carries the approval, and T25 proves a one-byte
   change to the curve is a different, empty strategy.
3. Signing ship() IS approving the curve. There is no second artifact.

## 3. The fork constraint and the mainnet broadcast

Because the CLI always broadcasts, and only to mainnet, the choice is:

**A. Ship on mainnet from the device, inert.** Zero allowance: VERIFIED FACTS —
"Aqua.ship() SUCCEEDS with ZERO allowance… the allowance is consumed only when
a taker fills." Aqua holds no tokens. The maker (the Ledger address) has no
Aave debt on mainnet, so `getUserAccountData` returns HF `type(uint256).max`
and the curve clamps to its top. Nobody can fill; nothing can move. Cost: one
transaction's gas (three Aqua balance writes) and the gas to deploy
`FreeboardExtruction` — 7,078 initcode bytes, no constructor args, no owner,
no storage — because the program names the extruction's address and a
mainnet ship must name a mainnet contract. Deployment is from any key
(`send` requires `--to`, so not from the CLI). Measure both with
`forge test --gas-report` before the run day.

**B. Keep everything on the fork** by signing with DMK directly and
`eth_sendRawTransaction` to anvil. Abandons the CLI.

A is recommended; §4 says why.

## 4. What mainnet buys the demo

The device-signed ship() becomes a real Etherscan transaction: `from` is the
Ledger address, `to` is the deployed Aqua, the input decodes to
`ship(app, strategy, tokens, amounts)` with the curve bytes visible. That is the single most legible proof that a human approved the
curve on hardware, and it is evidence for both juries — 1inch ("real on-chain
token transfers must be demonstrated. Forks acceptable": the fills are on the
fork, the shipping is real) and Ledger (the approval is on the real chain,
signed with the official CLI, no emulator, no custom signer).

The fork then does what only a fork can: a new test forks at a block **after**
the ship, pranks the Ledger address into an Aave position (deal, supply,
borrow, approve Aqua), and fills against the strategy the device shipped —
the same bytes, the same maker, HF now real. Existing tests stay pinned at
`FORK_BLOCK=25900000`; this test picks its own block with
`vm.createSelectFork`. DoD unchanged: the calldata the device signed decodes
to the program bytes `ProgramLib` builds, and that is asserted, not eyeballed.

What it does not do: the mainnet position is never fillable and never
deleverages anyone. Say so. The story is "the human's act is real, the
agent's acts are on a fork because the rules allow it", not "we ran Freeboard
on mainnet".

## 5. The agent

Ledger's brief has an agent in every line. Freeboard's is the keeper-taker.
The two halves of the CLI map onto the two roles:

- **Human**: `wallet-cli send --data <ship>` on the device — approves the curve.
- **Agent**: its RPC credentials and taker key live under `ring encrypt`,
  `ring decrypt`ed at runtime with no device; it cannot exceed the curve
  because the router enforces it, not its good behaviour.

One `ring init` on the device (Ledger Sync app) covers the agent side.

## 6. Prerequisites for the run day

- Ethereum app installed; **blind signing enabled** in its settings.
- Ledger Sync app installed (for `ring init`).
- ETH for gas on the account `account discover` labels `ethereum-1`.
- `npm i -g @ledgerhq/wallet-cli` — prebuilt `darwin-arm64`, no Bun needed.
- A deployer key with ETH for `FreeboardExtruction`.

