# Freeboard

Freeboard is the distance from the waterline to the deck — the margin a vessel has before it takes water.

Freeboard is a collateral basket whose definition of balanced depends on how much debt is riding on it. A borrower's health factor is its freeboard: as it falls, the basket rebalances itself toward safety, and traders pay a spread to do it.

Built on 1inch Aqua and SwapVM. The strategy executes on the deployed `AquaSwapVMRouter` (`0x111111338c5091E8440b67B168bAe16a668AC0De`, tag `v1.0.2`) through its own `_extruction` instruction. No SwapVM source is modified.

## Deployed contracts

Ethereum mainnet, chain id 1. Nothing of Freeboard's is a router or a registry; these are the 1inch contracts the strategy runs on, each matched to its tag by comparing the deployed runtime against a clean build. Pinned in [`src/constants/Addresses.sol`](src/constants/Addresses.sol), asserted on the fork by `test/fork/PinnedAddresses.t.sol`.

| Contract | Address | Source | Deployed at block |
|---|---|---|---|
| `AquaSwapVMRouter` | `0x111111338c5091E8440b67B168bAe16a668AC0De` | [swap-vm `v1.0.2`](https://github.com/1inch/swap-vm/tree/v1.0.2) (`32c687c`) | 25,618,917 |
| Aqua (`AquaRouter`) | `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a` | [aqua `v1.0.0`](https://github.com/1inch/aqua/tree/v1.0.0) (`81c26e4`) | 25,567,141 |

Fork tests need `FORK_BLOCK >= 25618917`; this repo pins `25900000`. `package.json` pins both tags exactly as matched: `github:1inch/swap-vm#v1.0.2` and `github:1inch/aqua#v1.0.0`. swap-vm itself declares aqua `0.1.0`, which yarn keeps nested under it; between the two aqua tags only `AquaRouter.sol` changed (Ownable + `rescueFunds`), the interfaces are byte-identical, and nothing here deploys `AquaRouter`. Note the aqua repo did not bump `package.json`'s `"version"` at `v1.0.0` — verify by the resolved commit in `yarn.lock` (`81c26e46…`), not by the version string.

## Fail-safe: an unreadable health factor is a refused fill, not a price

`FreeboardExtruction` reads the maker's health factor from Aave v3's `getUserAccountData` inside the pricing path, on every quote and every swap. If that read fails — the pool reverts, answers the wrong shape, or has no code — the fill reverts with `FreeboardHealthFactorUnreadable(maker)`. There is no try/catch, no default, and no fallback row of the curve.

Refusing is free for the borrower. Aave's own `liquidationCall` reads the same oracle through the same `calculateUserAccountData`, so while the health factor is unreadable no liquidation is possible either: there is nothing to be late for. A price, on the other hand, computed from a number Aave would not stand behind is exactly the mispricing the basket exists to prevent.

This replaced "clamp to the most conservative target" (Rev 4). The clamp was a defence against an off-chain writer going quiet — when the health factor reached the strategy from a Chainlink CRE enclave, a stale conservative target was safer than no target. The extruction now reads Aave directly, in the same block as the fill, so there is no writer to go quiet; and a clamp would turn a broken oracle into a forced deleverage at the bottom of the curve, priced as if it were the right thing to do, in the one state where no liquidation threatens. See `docs/freeboard-v0.md` §3, "The safety work", for the argument in full.

Separately, Aave's no-debt sentinel (`type(uint256).max`) is an answer, not a failure. It prices at the **top** of the curve — the loosest target — because with no debt there is nothing to deleverage. `Curve.weightsAt` clamps it there with no special case.

Both are pinned by [`test/unit/FailSafe.t.sol`](test/unit/FailSafe.t.sol): `test_RevertWhen_HealthFactorUnreadable` against a reverting mock pool, in both revert shapes T8 found on mainnet, on both paths, on both sides, with nothing else read; and `test_NoDebt_PricesAtTopOfCurve`, to the wei, equal to HF 2.00 and everything above it and distinguishable from every leveraged row. `test/fork/HealthFactor.t.sol` shows the same refusal on the deployed router with real Aave positions.

## Toolchain

- Node 22 · yarn 1.22 · Foundry `forge 1.5.1-stable` · solc 0.8.30 (via foundry.toml)
- `yarn install --frozen-lockfile && forge build && forge test`
