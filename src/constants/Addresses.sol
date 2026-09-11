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
    uint256 internal constant AQUA_RUNTIME_SIZE = 5619;

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
    // Freeboard on mainnet — deployed Sep 11 (T24a) for the Ledger-signed ship()
    // ---------------------------------------------------------------------------------

    /// @dev `FreeboardExtruction`, deployed by `script/DeployExtruction.s.sol` from
    ///      0x637e4569cFCaA4be5D97Fd35eB3A301296AB53F0 at nonce 0, in tx
    ///      0xfb4616b7d0e47a220b764bb52bd538daac8d0182ff0f0debfa424b632596c04d. No constructor
    ///      arguments, no owner, no storage, so the deployer's identity carries nothing. The
    ///      Ledger-signed `ship()` names this address as the program's `_extruction` target,
    ///      which is the only reason a mainnet copy exists: the fills stay on the fork.
    ///      `PinnedAddressesForkTest.test_MainnetExtruction_RuntimeMatchesTheLocalBuild` asserts
    ///      the deployed runtime equals `type(FreeboardExtruction).runtimeCode` — a two-sided
    ///      comparison, since the hash below was taken from the local build, not the chain.
    address internal constant MAINNET_EXTRUCTION = 0x8804F353252957bEd3B099dFbbe35B54AF280f41;

    /// @dev First mainnet block at which `MAINNET_EXTRUCTION` has code (the deploy tx's block).
    ///      AFTER `FORK_BLOCK`: the pinned fork predates it, so tests that need the mainnet
    ///      extruction fork at this block or later on their own; nothing else moves.
    uint256 internal constant MAINNET_EXTRUCTION_DEPLOY_BLOCK = 25_949_936;

    /// @dev Runtime size and keccak of the local build (`out/FreeboardExtruction.sol`), which
    ///      the deploy script asserted against the landed code and `cast code` re-read Sep 11.
    uint256 internal constant MAINNET_EXTRUCTION_RUNTIME_SIZE = 7052;
    bytes32 internal constant MAINNET_EXTRUCTION_RUNTIME_HASH =
        0xcc7c96e6c97d94bb231bd12e19c1b8ff55b96f5c58fea379ae10abb9129884fd;

    /// @dev The borrower's Ledger account (`wallet-cli` label `ethereum-2`, address verified on
    ///      the device screen), which signed the mainnet `ship()` below. Holds ETH for gas and
    ///      nothing else: no Aave position, no tokens, no allowance to Aqua — the position it
    ///      shipped is inert by construction and `test_TheDeviceShippedStrategy_FillsOnTheFork`
    ///      gives it a position and an allowance on a fork only.
    address internal constant MAINNET_MAKER = 0x380436a603325F81Ecd40BF26ceF602D46E5aC4c;

    /// @dev The device-signed `Aqua.ship(router, strategy, [WETH, WBTC, USDC], [10e18, 0.3e8,
    ///      30_000e6])`, tx 0xc13c55e18bc748b5f85ec680fa14d759b30682b7296bf7ba84c2bf43d91f70c4,
    ///      Sep 11. `strategy` is `ProgramBuilder.freeboardPosition(MAINNET_MAKER,
    ///      MAINNET_EXTRUCTION, Curves.freeboard(), tokens, 500).strategy` — the same bytes every
    ///      fork test ships — so the curve the borrower approved on the device is the curve
    ///      those tests price. `results/ledger-ship.txt` holds the full calldata;
    ///      `LedgerShipForkTest` reads the transaction back from mainnet and asserts it.
    uint256 internal constant MAINNET_SHIP_BLOCK = 25_950_014;
    bytes32 internal constant MAINNET_SHIP_TX = 0xc13c55e18bc748b5f85ec680fa14d759b30682b7296bf7ba84c2bf43d91f70c4;
    bytes32 internal constant MAINNET_STRATEGY_HASH =
        0xd8e168cdfee0697050bea8bc2c61ccbc2d03050740f65fac9bd68acf31bf3145;

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
    // Aave v3 — verified Sep 7 (T8) by a closed round trip on the fork
    // ---------------------------------------------------------------------------------

    /// @dev Only the provider is an input (bgd-labs/aave-address-book `AaveV3Ethereum.sol`);
    ///      everything else below is read from it on the fork. `AaveHealthFactorForkTest` asserts
    ///      `provider.getPool() == AAVE_V3_POOL`, `Pool.ADDRESSES_PROVIDER() == provider`, the
    ///      same round trip for the oracle, and that the aTokens for WETH/WBTC/USDC name this
    ///      Pool via `POOL()` and their underlyings via `UNDERLYING_ASSET_ADDRESS()`.
    ///      `POOL_REVISION()` is 11 at FORK_BLOCK.
    address internal constant AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    /// @dev The Pool proxy `FreeboardExtruction._healthWeightedTarget` staticcalls for
    ///      `getUserAccountData(query.maker)`. Always `query.maker`, never an address from args.
    address internal constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    /// @dev `AaveOracle`. NOT what the extruction reads from: `FreeboardExtruction` resolves the
    ///      oracle from the provider on every fill (`getPriceOracle()`), exactly as the Pool does
    ///      inside `getUserAccountData`, so a migration moves the health factor and the basket
    ///      valuation together. Named here because `test/utils/OracleWarp.sol` drives HF by
    ///      replacing a source on it, and asserted equal to the provider's answer at the pin.
    address internal constant AAVE_V3_ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;

    /// @dev `ACLManager` and the holder of its `DEFAULT_ADMIN_ROLE`. Test-fixture plumbing for
    ///      `OracleWarp`, which needs `ASSET_LISTING_ADMIN_ROLE` to call `setAssetSources`.
    address internal constant AAVE_V3_ACL_MANAGER = 0xc2aaCf6553D20d1e9d78E365AAba8032af9c85b0;
    address internal constant AAVE_V3_ACL_ADMIN = 0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A;

    /// @dev `AaveOracle.BASE_CURRENCY_UNIT()`. `BASE_CURRENCY()` is `address(0)` = USD, so
    ///      every `*Base` figure from `getUserAccountData` is USD at 1e8.
    uint256 internal constant AAVE_BASE_CURRENCY_UNIT = 1e8;

    /// @dev Liquidation thresholds in bps at FORK_BLOCK, so tests can predict HF from first
    ///      principles. A governance change to any of these is a red test.
    uint256 internal constant LT_WETH_BPS = 8300;
    uint256 internal constant LT_WBTC_BPS = 7800;
    uint256 internal constant LT_USDC_BPS = 7800;
}
