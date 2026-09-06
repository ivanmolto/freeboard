# Freeboard

Freeboard is the distance from the waterline to the deck — the margin a vessel has before it takes water.

Freeboard is a collateral basket whose definition of balanced depends on how much debt is riding on it. A borrower's health factor is its freeboard: as it falls, the basket rebalances itself toward safety, and traders pay a spread to do it.

Built on 1inch Aqua and SwapVM. The strategy executes on the deployed `AquaSwapVMRouter` (`0x111111338c5091E8440b67B168bAe16a668AC0De`, tag `v1.0.2`) through its own `_extruction` instruction. No SwapVM source is modified.

## Toolchain

- Node 22 · yarn 1.22 · Foundry `forge 1.5.1-stable` · solc 0.8.30 (via foundry.toml)
- `yarn install --frozen-lockfile && forge build && forge test`
