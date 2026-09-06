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

## Toolchain

- Node 22 · yarn 1.22 · Foundry `forge 1.5.1-stable` · solc 0.8.30 (via foundry.toml)
- `yarn install --frozen-lockfile && forge build && forge test`
