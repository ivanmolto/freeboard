// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { SwapQuery, SwapRegisters } from "@1inch/swap-vm/src/libs/VM.sol";
import { IExtruction, IStaticExtruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

/// @dev Compiles against the pinned swap-vm v1.0.2 and asserts the register shape the
///      extruction receives. If this fails, the pin or the remappings are wrong.
contract PinTest is Test {
    function test_PinnedSwapVM_RegistersHaveFiveWords() public pure {
        SwapRegisters memory swap;
        assertEq(abi.encode(swap).length, 5 * 32, "SwapRegisters must be 5 words at v1.0.2");
    }

    function test_PinnedSwapVM_QueryHasSixFields() public pure {
        SwapQuery memory query;
        assertEq(abi.encode(query).length, 6 * 32, "SwapQuery must be 6 words at v1.0.2");
    }

    function test_PinnedSwapVM_ExtructionSelectorsAgree() public pure {
        assertEq(IExtruction.extruction.selector, IStaticExtruction.extruction.selector, "one view function must satisfy both");
    }

    function test_PinnedAqua_RawBalancesSignature() public pure {
        assertEq(IAqua.rawBalances.selector, bytes4(0x6d58b4cc), "rawBalances(address,address,bytes32,address)");
    }
}
