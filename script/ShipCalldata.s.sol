// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { Addresses } from "../src/constants/Addresses.sol";
import { Curves } from "../test/utils/Curves.sol";
import { ProgramBuilder } from "../test/utils/ProgramBuilder.sol";

/// @title ShipCalldata — the bytes the Ledger signs (T24a)
/// @notice Prints the calldata of the `ship()` the borrower approves on the device:
///
///           Aqua.ship(app, strategy, tokens, amounts)      (aqua v1.0.0, src/Aqua.sol:40)
///
///         with `app` the DEPLOYED router, `strategy` the Freeboard program built by the SAME
///         `ProgramBuilder` every fork test ships through — one `_extruction` to the mainnet
///         `FreeboardExtruction`, carrying the curve, the token list and the cap — and T23's
///         basket amounts. The curve is inside `strategy`; signing this calldata IS approving
///         the curve, and `keccak256(strategy)` is the hash Aqua keys the position by.
///
/// @dev One source of bytes, on purpose. The strategy hash is `keccak256(abi.encode(order))`
///      on both sides (VERIFIED FACTS: one byte of drift is a silently unfillable position),
///      so this script does not encode anything itself — it asks `ProgramBuilder` for the
///      position and prints what falls out. `test_DeviceSignedShip_CarriesTheProgramBytes`
///      later decodes the mainnet transaction and asserts it equals this, built again.
///
///      Run, then hand the hex to wallet-cli:
///        MAKER=<the Ledger account> forge script script/ShipCalldata.s.sol
///        wallet-cli send <label> --to 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a --amount '0 ETH' --data 0x…
///      Nothing here touches a chain or a key; it is pure computation plus a file write.
contract ShipCalldata is Script {
    /// @dev T23's basket and cap (`script/PricePath.s.sol`): 10 WETH / 0.3 WBTC / 30,000 USDC,
    ///      500 bps per fill. Declared amounts only — Aqua.ship() moves nothing, and with no
    ///      allowance from the maker nothing can ever be pulled: the mainnet position is inert.
    uint256 internal constant SHIPPED_WETH = 10 ether;
    uint256 internal constant SHIPPED_WBTC = 0.3e8;
    uint256 internal constant SHIPPED_USDC = 30_000e6;
    uint16 internal constant MAX_SHIFT_BPS = 500;

    function run() external {
        address maker = vm.envAddress("MAKER");
        require(maker != address(0), "MAKER is the Ledger account that will sign");

        address[] memory tokens = Curves.freeboardTokens();
        ProgramBuilder.Position memory position = ProgramBuilder.freeboardPosition(
            maker, Addresses.MAINNET_EXTRUCTION, Curves.freeboard(), tokens, MAX_SHIFT_BPS
        );

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = SHIPPED_WETH;
        amounts[1] = SHIPPED_WBTC;
        amounts[2] = SHIPPED_USDC;

        bytes memory data = abi.encodeCall(IAqua.ship, (Addresses.AQUA_SWAP_VM_ROUTER, position.strategy, tokens, amounts));

        console.log("maker        ", maker);
        console.log("app (router) ", Addresses.AQUA_SWAP_VM_ROUTER);
        console.log("extruction   ", Addresses.MAINNET_EXTRUCTION);
        console.log("to (Aqua)    ", Addresses.AQUA);
        console.log("strategy len ", position.strategy.length);
        console.log("calldata len ", data.length);
        console.log("strategy hash");
        console.logBytes32(position.strategyHash);
        console.log("calldata");
        console.logBytes(data);

        string memory out = string.concat(
            "# ship() calldata for the Ledger (T24a) - built by script/ShipCalldata.s.sol\n",
            "maker        ", vm.toString(maker), "\n",
            "app          ", vm.toString(Addresses.AQUA_SWAP_VM_ROUTER), "\n",
            "extruction   ", vm.toString(Addresses.MAINNET_EXTRUCTION), "\n",
            "to           ", vm.toString(Addresses.AQUA), "\n",
            "strategyHash ", vm.toString(position.strategyHash), "\n",
            "calldata     ", vm.toString(data), "\n"
        );
        vm.writeFile("results/ledger-ship-calldata.txt", out);
        console.log("wrote results/ledger-ship-calldata.txt");
    }
}
