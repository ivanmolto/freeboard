// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { Addresses } from "../../src/constants/Addresses.sol";

/// @dev `SwapVM` exposes its Aqua as a public immutable (`src/SwapVM.sol:74`):
///        IAqua public immutable AQUA;
///      Read as `address` here purely as an identity check on the deployed router.
interface IRouterAqua {
    function AQUA() external view returns (address);
}

/// @dev `AquaRouter` at aqua v1.0.0 is `Aqua, Simulator, Multicall, Rescuable`. `Rescuable`
///      is Ownable, so the deployed contract answers `owner()`. Tag 0.1.0's `AquaRouter` is
///      `Aqua, Simulator, Multicall` and does NOT. One call separates the two tags without
///      building anything.
interface IOwnable {
    function owner() external view returns (address);
}

/// @title PinnedAddressesForkTest — T4
/// @notice Turns "we matched the deployed contracts to a tag" from a claim in a comment into
///         an assertion that runs against mainnet on every `yarn test:fork`.
///
/// @dev The load-bearing test is `test_Aqua_RuntimeMatchesAquaTagV1_0_0`. `AQUA_RUNTIME_BODY_HASH`
///      and `AQUA_METADATA` in `Addresses.sol` were both taken from a LOCAL build of aqua tag
///      v1.0.0 (commit 81c26e4), never from the chain, so comparing the chain against them is
///      a genuine two-sided comparison. Reproduce the build with:
///
///        git clone https://github.com/1inch/aqua && cd aqua && git checkout v1.0.0
///        yarn install && forge build
///        jq -r '.deployedBytecode.object' out/AquaRouter.sol/AquaRouter.json
contract PinnedAddressesForkTest is Test {
    function setUp() public {
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        require(forkBlock >= Addresses.MIN_FORK_BLOCK, "FORK_BLOCK is before the router exists");
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);
    }

    function test_Chain_IsMainnet() public view {
        assertEq(block.chainid, Addresses.CHAIN_ID, "fork is not Ethereum mainnet");
    }

    function test_ForkBlock_IsAtOrAfterBothDeployments() public view {
        assertGe(block.number, Addresses.ROUTER_DEPLOY_BLOCK, "fork block precedes the router deployment");
        assertGe(block.number, Addresses.AQUA_DEPLOY_BLOCK, "fork block precedes the Aqua deployment");
        assertGt(Addresses.ROUTER_DEPLOY_BLOCK, Addresses.AQUA_DEPLOY_BLOCK, "Aqua must predate the router");
    }

    // -------------------------------------------------------------------------------------
    // The router: size, and the fact that it is the one that names our Aqua
    // -------------------------------------------------------------------------------------

    function test_Router_HasThePinnedRuntimeSizeAndNamesThePinnedAqua() public view {
        assertEq(
            Addresses.AQUA_SWAP_VM_ROUTER.code.length,
            Addresses.ROUTER_RUNTIME_SIZE,
            "router runtime size drifted from the v1.0.2 build matched in T3"
        );
        assertEq(
            IRouterAqua(Addresses.AQUA_SWAP_VM_ROUTER).AQUA(),
            Addresses.AQUA,
            "router.AQUA() is not the pinned Aqua"
        );
    }

    // -------------------------------------------------------------------------------------
    // The Aqua match — the DoD of T4
    // -------------------------------------------------------------------------------------

    /// @dev Splits the deployed runtime at the CBOR boundary and checks both halves against
    ///      values derived from the v1.0.0 build:
    ///        - the 5,566 executable bytes, by keccak;
    ///        - the 53-byte metadata blob, byte-for-byte. Its 32-byte IPFS digest is the hash
    ///          of the metadata document, which itself commits to the keccak of every source
    ///          file, so matching it is a source-exact match and not merely a code match.
    function test_Aqua_RuntimeMatchesAquaTagV1_0_0() public view {
        bytes memory runtime = Addresses.AQUA.code;
        assertEq(runtime.length, Addresses.AQUA_RUNTIME_SIZE, "Aqua runtime size is not v1.0.0's 5,619 bytes");

        // The last two bytes of a solc runtime are the big-endian length of the CBOR blob.
        uint256 cborLength = (uint256(uint8(runtime[runtime.length - 2])) << 8) | uint8(runtime[runtime.length - 1]);
        assertEq(cborLength + 2, Addresses.AQUA_METADATA_LENGTH, "CBOR length suffix is not v1.0.0's");

        uint256 bodyLength = runtime.length - Addresses.AQUA_METADATA_LENGTH;

        bytes memory body = new bytes(bodyLength);
        for (uint256 i = 0; i < bodyLength; i++) {
            body[i] = runtime[i];
        }
        assertEq(
            keccak256(body),
            Addresses.AQUA_RUNTIME_BODY_HASH,
            "Aqua's executable bytes are not a build of aqua v1.0.0 (81c26e4)"
        );

        bytes memory metadata = new bytes(Addresses.AQUA_METADATA_LENGTH);
        for (uint256 i = 0; i < Addresses.AQUA_METADATA_LENGTH; i++) {
            metadata[i] = runtime[bodyLength + i];
        }
        assertEq(metadata, Addresses.AQUA_METADATA, "Aqua's CBOR metadata is not the one v1.0.0's sources produce");
    }

    /// @dev Independent of any build: only v1.0.0's `AquaRouter` mixes in `Rescuable`, so only
    ///      v1.0.0 answers `owner()`. Under 0.1.0 this call hits the fallback and reverts.
    function test_Aqua_AnswersOwner_WhichOnlyTagV1_0_0Does() public view {
        assertTrue(IOwnable(Addresses.AQUA).owner() != address(0), "owner() must be set on the v1.0.0 AquaRouter");
    }

    // -------------------------------------------------------------------------------------
    // Tokens
    // -------------------------------------------------------------------------------------

    function test_Tokens_HaveTheDocumentedSymbolsAndDecimals() public view {
        _assertToken(Addresses.WETH, "WETH", 18);
        _assertToken(Addresses.WBTC, "WBTC", 8);
        _assertToken(Addresses.USDC, "USDC", 6);
        _assertToken(Addresses.DAI, "DAI", 18);
    }

    function _assertToken(address token, string memory symbol, uint8 decimals) internal view {
        assertEq(IERC20Metadata(token).symbol(), symbol, "token symbol");
        assertEq(IERC20Metadata(token).decimals(), decimals, "token decimals");
    }
}
