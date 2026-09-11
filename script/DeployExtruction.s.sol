// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { Addresses } from "../src/constants/Addresses.sol";
import { FreeboardExtruction } from "../src/FreeboardExtruction.sol";

/// @title DeployExtruction — the one-time mainnet deploy of FreeboardExtruction (T24a)
/// @notice The Ledger-signed `ship()` names the extruction's address inside the program bytes,
///         so a mainnet ship needs a mainnet extruction. This deploys it: no constructor
///         arguments, no owner, no storage — the deployer's identity is irrelevant after the
///         transaction, which is why a throwaway key pays for it and the Ledger does not
///         (`wallet-cli send` requires a `--to`; it cannot create a contract).
///
/// @dev Simulate first, then broadcast — from the repo root:
///        forge script script/DeployExtruction.s.sol --rpc-url $MAINNET_RPC_URL
///        forge script script/DeployExtruction.s.sol --rpc-url $MAINNET_RPC_URL --broadcast
///      Every run asserts it is on mainnet with both protocol contracts at their pinned sizes,
///      and that the code that landed is byte-for-byte the local build. The address goes into
///      `Addresses.MAINNET_EXTRUCTION` by hand, and `PinnedAddressesForkTest` keeps asserting
///      the runtime equality from then on.
contract DeployExtruction is Script {
    function run() external {
        require(block.chainid == Addresses.CHAIN_ID, "not Ethereum mainnet");
        require(
            Addresses.AQUA_SWAP_VM_ROUTER.code.length == Addresses.ROUTER_RUNTIME_SIZE,
            "deployed AquaSwapVMRouter runtime size"
        );
        require(Addresses.AQUA.code.length == Addresses.AQUA_RUNTIME_SIZE, "deployed Aqua runtime size");

        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(key);
        console.log("deployer", deployer);
        console.log("deployer nonce", vm.getNonce(deployer));
        console.log("deployer balance (wei)", deployer.balance);
        console.log("block", block.number);

        vm.startBroadcast(key);
        FreeboardExtruction freeboard = new FreeboardExtruction();
        vm.stopBroadcast();

        bytes memory landed = address(freeboard).code;
        require(landed.length > 0, "no code at the deployed address");
        require(
            keccak256(landed) == keccak256(type(FreeboardExtruction).runtimeCode),
            "deployed runtime differs from the local build"
        );

        console.log("FreeboardExtruction", address(freeboard));
        console.log("runtime bytes", landed.length);
        console.logBytes32(keccak256(landed));
    }
}
