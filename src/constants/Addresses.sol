// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Addresses — the mainnet addresses Freeboard settles against, pinned by bytecode
/// @notice One source of truth for every hard-coded address in this repo. Nothing here is a
///         well-known-address-from-memory: each entry was read from mainnet at
///         `FORK_BLOCK` and, for the two protocol contracts, matched to a published tag by
///         comparing the deployed runtime byte-for-byte against a local build of that tag.
///
/// @dev CHAIN. Ethereum mainnet, chain id 1 (`cast chain-id`, Sep 6). ONE chain; there is no
///      per-chain table here on purpose. The two protocol addresses below are deterministic
///      CREATE3 deployments and are the same on every supported chain, but this repo only
///      ever forks mainnet, so a multi-chain table would be untested surface.
///
/// @dev HOW THE TWO PROTOCOL CONTRACTS WERE MATCHED
///
///      AquaSwapVMRouter 0x111111338c… — settled Sep 5 (T3). CBOR metadata hash and
///      immutable-masked runtime both match a clean build of swap-vm tag v1.0.2
///      (commit 32c687c2b73101fc26549e48fa1ff8a4d73afbac). Runtime is 20,541 bytes.
///
///      Aqua 0x1111113CCf… — settled Sep 6 (T4), and the answer is NOT the tag swap-vm pins.
///      The deployed contract is `src/AquaRouter.sol:AquaRouter` at aqua tag **v1.0.0**
///      (commit 81c26e4619ce21556ab02b3284ee2685de21fb18), solc 0.8.30+commit.73712a01,
///      viaIR, optimizer enabled at 10,000,000 runs, evmVersion `prague`, bytecodeHash `ipfs`.
///      Evidence, in order of strength:
///        1. A local build of v1.0.0 produces a 5,619-byte runtime whose first 5,566 bytes —
///           everything ahead of the CBOR blob — are byte-for-byte identical to the deployed
///           runtime. See `AQUA_RUNTIME_BODY_HASH` below; `PinnedAddressesForkTest` asserts it.
///        2. The deployed CBOR metadata hash is reproduced EXACTLY. The local build differs
///           from the deployer's only in `settings.remappings`, which carried two extra
///           entries (`hardhat-deploy/`, `hardhat/`) from the deployer's node_modules.
///           Adding those two strings to the local `rawMetadata` and re-hashing it as IPFS
///           CIDv0 yields fa4e14c14d3dbf52a36c71d787546a8df451772aefd6b3bc1568fbf061a40687,
///           which is the digest embedded in the deployed bytecode. The metadata document
///           covers the keccak of every source file, so this is a source-exact match.
///           The two extra remappings are visible in Sourcify's verification record for this
///           address (`runtimeMatch: exact_match`, verified 2026-07-19), which also lists the
///           same 23 source paths and the same settings.
///        3. Selector evidence, independent of any build: the deployed dispatcher carries
///           `owner()`, `transferOwnership(address)`, `renounceOwnership()` and
///           `rescueFunds(address,uint256)` on top of Aqua's eight. Those come from the
///           `Rescuable` mixin, which v1.0.0's `AquaRouter` adds and 0.1.0's does not.
///
/// @dev THE package.json PIN IS `github:1inch/aqua#v1.0.0` — THE DEPLOYED TAG
///      swap-vm v1.0.2 declares `github:1inch/aqua#0.1.0`, so yarn keeps that copy nested
///      in swap-vm's own nested node_modules (the 1inch/aqua package) for swap-vm's use,
///      while `remappings.txt` sends every 1inch/aqua import — ours and swap-vm's — to the
///      top-level v1.0.0. That is safe because between tags 0.1.0 and v1.0.0 the ONLY changed
///      file under `src/` is `AquaRouter.sol` (`git diff --stat 0.1.0 v1.0.0 -- src/`: 1 file,
///      +9/-2). `Aqua.sol`, `interfaces/IAqua.sol`, `libs/Balance.sol` and `AquaApp.sol` are
///      byte-identical, swap-vm's `src/` imports nothing from aqua but `IAqua.sol`, and
///      nothing in this repo deploys `AquaRouter`, whose constructor is the one thing that
///      changed. The v1.0.0 delta is Ownable + `rescueFunds`; Aqua holds no tokens (it is
///      allowance-based — `ship()` moves nothing), so `rescueFunds` cannot touch a position.
///
///      One trap for anyone verifying by hand: the aqua repo did NOT bump `package.json`
///      `"version"` at v1.0.0 — it still reads `0.1.0`. Check the resolved commit in
///      `yarn.lock` (`81c26e46…`), or the presence of `Rescuable` in `src/AquaRouter.sol`.
///
/// @dev THREE ADDRESSES THAT ARE NOT THESE. Recorded so the confusion resolves once.
///        0x499943E74FB0cE105688beeE8Ef2ABec5D936d31 — 6,251 bytes. A DIFFERENT contract,
///          with `34fbda79`/`bbe8d44d` in its dispatcher and no ownership functions. The 17
///          prior fills against it prove it existed, not that it is current. The live router
///          does not point at it.
///        0x8fdd04dbf6111437b44bbca99c28882434e0958f — AquaSwapVMRouter "1.0.0", 22,640
///          bytes. Superseded.
///        0x3c4758979ec30ca45857cabc2462a70699ed790e — AquaSwapVMRouter v1.0.1, 20,379
///          bytes, EOA-owned, zero transactions. Do not use.
library Addresses {
    // ---------------------------------------------------------------------------------
    // Chain
    // ---------------------------------------------------------------------------------

    /// @dev Ethereum mainnet. Fork tests assert this so a mis-set RPC fails loudly.
    uint256 internal constant CHAIN_ID = 1;

    // ---------------------------------------------------------------------------------
    // 1inch protocol — the deployed contracts Freeboard executes on
    // ---------------------------------------------------------------------------------

    /// @dev AquaSwapVMRouter, swap-vm tag v1.0.2. Freeboard deploys no router; the opcode
    ///      table, the dispatch at 0x20 and the settlement are all this contract's.
    address internal constant AQUA_SWAP_VM_ROUTER = 0x111111338c5091E8440b67B168bAe16a668AC0De;

    /// @dev Aqua, aqua tag v1.0.0. This is what `AQUA_SWAP_VM_ROUTER.AQUA()` returns and what
    ///      Freeboard's strategies are shipped to and settled against.
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;

    // ---------------------------------------------------------------------------------
    // Bytecode identity — the T3/T4 match, expressed as numbers a test can assert
    // ---------------------------------------------------------------------------------

    /// @dev Runtime size of `AQUA_SWAP_VM_ROUTER`, re-read Sep 6.
    uint256 internal constant ROUTER_RUNTIME_SIZE = 20_541;

    /// @dev Runtime size of `AQUA`, re-read Sep 6.
    uint256 internal constant AQUA_RUNTIME_SIZE = 5_619;

    /// @dev Length of the trailing CBOR metadata blob on `AQUA`, including the two-byte
    ///      length suffix: 51 bytes of CBOR + 2 = 53.
    uint256 internal constant AQUA_METADATA_LENGTH = 53;

    /// @dev keccak256 of `AQUA`'s runtime with the CBOR blob removed — the 5,566 executable
    ///      bytes. Taken from a local build of aqua v1.0.0, not from the chain, so asserting
    ///      the chain against it is a real comparison and not a tautology.
    bytes32 internal constant AQUA_RUNTIME_BODY_HASH =
        0xd2f7b1534f3cb30468870510e62d046d8a8ef114c387588012030fdd60cd4669;

    /// @dev The exact 53-byte CBOR blob at the end of `AQUA`'s runtime:
    ///      `{"ipfs": <32-byte CIDv0 digest>, "solc": 0.8.30}` followed by its length.
    ///      Reproduced byte-for-byte from the v1.0.0 build's `rawMetadata` — see the header.
    bytes internal constant AQUA_METADATA =
        hex"a2646970667358221220fa4e14c14d3dbf52a36c71d787546a8df451772aefd6b3bc1568fbf061a4068764736f6c634300081e0033";

    // ---------------------------------------------------------------------------------
    // Fork block bounds
    // ---------------------------------------------------------------------------------

    /// @dev First mainnet block at which `AQUA` has code. Binary-searched over
    ///      `eth_getCode`, Sep 6; agrees with Sourcify's recorded deployment block for
    ///      tx 0xe37e4dd7e73302a57cbf8ef6cff2424a787df9bf462d69f2de6d149dca43fb1a.
    uint256 internal constant AQUA_DEPLOY_BLOCK = 25_567_141;

    /// @dev First mainnet block at which `AQUA_SWAP_VM_ROUTER` has code. Binary-searched
    ///      over `eth_getCode`, Sep 6. The router is the later of the two, so it sets the
    ///      floor for every fork test in this repo.
    uint256 internal constant ROUTER_DEPLOY_BLOCK = 25_618_917;

    /// @dev Earliest `FORK_BLOCK` at which both protocol contracts exist. Inclusive: the
    ///      router already has code AT this block, not one block later.
    uint256 internal constant MIN_FORK_BLOCK = ROUTER_DEPLOY_BLOCK;

    // ---------------------------------------------------------------------------------
    // Tokens — symbol() and decimals() read on the fork at FORK_BLOCK, Sep 6
    // ---------------------------------------------------------------------------------

    /// @dev "WETH", 18 decimals.
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev "WBTC", 8 decimals.
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    /// @dev "USDC", 6 decimals. The debt asset, and the basket's flight-to-safety leg.
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev "DAI", 18 decimals. Not a basket leg — the second token in T2's dispatch proof,
    ///      kept here so that test has no literals of its own.
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // ---------------------------------------------------------------------------------
    // Aave v3 — NOT YET VERIFIED. Named slot only.
    // ---------------------------------------------------------------------------------

    // The Pool that `FreeboardExtruction._healthWeightedTarget` staticcalls for
    // `getUserAccountData(query.maker)`. T8 verifies it: read the address off the mainnet
    // PoolAddressesProvider at FORK_BLOCK, confirm it answers `getUserAccountData` for a
    // real position on the fork, then uncomment this and fill it in. Left commented rather
    // than stubbed to `address(0)` so it cannot be silently consumed before T8 lands.
    //
    // address internal constant AAVE_V3_POOL = 0x...; // T8
}
