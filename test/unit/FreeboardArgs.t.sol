// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { Curve } from "../../src/libs/Curve.sol";
import { FreeboardArgs } from "../../src/libs/FreeboardArgs.sol";

import { Curves } from "../utils/Curves.sol";

/// @dev The decoders read `bytes calldata`, as the extruction hands them.
contract ArgsHarness {
    function curve(bytes calldata args) external pure returns (bytes memory) {
        return FreeboardArgs.curve(args);
    }

    function legs(bytes calldata args) external pure returns (uint256) {
        return FreeboardArgs.legs(args);
    }

    function tokenAt(bytes calldata args, uint256 l) external pure returns (address) {
        return FreeboardArgs.tokenAt(args, l);
    }

    function tokens(bytes calldata args) external pure returns (address[] memory) {
        return FreeboardArgs.tokens(args);
    }

    function maxShiftBps(bytes calldata args) external pure returns (uint256) {
        return FreeboardArgs.maxShiftBps(args);
    }

    function validate(bytes calldata args) external pure {
        FreeboardArgs.validate(args);
    }
}

/// @title FreeboardArgsTest — T14
/// @notice The one layout, encoded and decoded: `[curve][n x token][uint16 maxShiftBps]`,
///         192 bytes for the Freeboard position, with every malformed blob refused by name.
contract FreeboardArgsTest is Test {
    ArgsHarness internal h;
    bytes internal curve;
    address[] internal tokens;
    bytes internal args;

    uint16 internal constant CAP = 500;

    function setUp() public {
        h = new ArgsHarness();
        curve = Curves.freeboard();
        tokens = Curves.freeboardTokens();
        args = FreeboardArgs.encode(curve, tokens, CAP);
    }

    function test_Layout_FreeboardArgsAre192Bytes() public view {
        assertEq(FreeboardArgs.FREEBOARD_ARGS_SIZE, 192, "the quoted size");
        assertEq(FreeboardArgs.size(4, 3), 192, "size(4, 3)");
        assertEq(args.length, 192, "encoded length");
        assertLe(20 + args.length, 255, "with the target, inside one instruction's 255-byte args");

        // The curve is first, verbatim.
        for (uint256 i = 0; i < curve.length; ++i) {
            assertEq(args[i], curve[i], "curve bytes");
        }
        // Then the three tokens, 20 bytes each, in leg order.
        assertEq(address(bytes20(_slice(args, 130, 20))), Addresses.WETH, "leg 0 token");
        assertEq(address(bytes20(_slice(args, 150, 20))), Addresses.WBTC, "leg 1 token");
        assertEq(address(bytes20(_slice(args, 170, 20))), Addresses.USDC, "leg 2 token");
        // Then the cap, big-endian.
        assertEq(uint16(bytes2(_slice(args, 190, 2))), CAP, "cap bytes");
    }

    function test_Layout_DecodesWhatEncodeWrote() public view {
        h.validate(args);
        assertEq(h.curve(args), curve, "curve()");
        assertEq(h.legs(args), 3, "legs()");
        assertEq(h.tokenAt(args, 0), Addresses.WETH, "tokenAt(0)");
        assertEq(h.tokenAt(args, 1), Addresses.WBTC, "tokenAt(1)");
        assertEq(h.tokenAt(args, 2), Addresses.USDC, "tokenAt(2)");
        assertEq(h.tokens(args), tokens, "tokens()");
        assertEq(h.maxShiftBps(args), CAP, "maxShiftBps()");
    }

    function test_Layout_TwoLegArgsDecodeToo() public view {
        bytes memory two = FreeboardArgs.encode(Curves.twoLeg(), Curves.twoLegTokens(), 1);
        assertEq(two.length, Curve.size(4, 2) + 40 + 2, "two-leg size");
        h.validate(two);
        assertEq(h.legs(two), 2);
        assertEq(h.tokenAt(two, 1), Addresses.USDC);
        assertEq(h.maxShiftBps(two), 1);
    }

    function test_RevertWhen_TokenCountDiffersFromLegs() public {
        address[] memory twoTokens = Curves.twoLegTokens();
        vm.expectRevert(abi.encodeWithSelector(FreeboardArgs.FreeboardArgsTokenCountMismatch.selector, 2, 3));
        this.encodeExternal(curve, twoTokens, CAP);
    }

    function test_RevertWhen_ATokenIsZeroOrRepeated() public {
        address[] memory zero = Curves.freeboardTokens();
        zero[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(FreeboardArgs.FreeboardArgsZeroToken.selector, 1));
        this.encodeExternal(curve, zero, CAP);

        address[] memory twice = Curves.freeboardTokens();
        twice[2] = Addresses.WETH;
        vm.expectRevert(abi.encodeWithSelector(FreeboardArgs.FreeboardArgsDuplicateToken.selector, Addresses.WETH));
        this.encodeExternal(curve, twice, CAP);

        // And the decoder refuses the same blobs.
        bytes memory zeroBlob = _patchToken(args, 1, address(0));
        vm.expectRevert(abi.encodeWithSelector(FreeboardArgs.FreeboardArgsZeroToken.selector, 1));
        h.validate(zeroBlob);

        bytes memory twiceBlob = _patchToken(args, 2, Addresses.WETH);
        vm.expectRevert(abi.encodeWithSelector(FreeboardArgs.FreeboardArgsDuplicateToken.selector, Addresses.WETH));
        h.validate(twiceBlob);
    }

    function test_RevertWhen_TheBytesAreNotExactlyTheLayout() public {
        bytes memory cut = _slice(args, 0, args.length - 1);
        vm.expectRevert(abi.encodeWithSelector(FreeboardArgs.FreeboardArgsLengthMismatch.selector, 191, 192));
        h.validate(cut);
        vm.expectRevert(abi.encodeWithSelector(FreeboardArgs.FreeboardArgsLengthMismatch.selector, 191, 192));
        h.maxShiftBps(cut);

        bytes memory padded = bytes.concat(args, hex"00");
        vm.expectRevert(abi.encodeWithSelector(FreeboardArgs.FreeboardArgsLengthMismatch.selector, 193, 192));
        h.validate(padded);

        // Only the curve: the token of leg 0 is past the end.
        vm.expectRevert(abi.encodeWithSelector(FreeboardArgs.FreeboardArgsLengthMismatch.selector, 130, 150));
        h.tokenAt(curve, 0);

        // Not even a curve header: refused by the curve layer, before the args layer.
        vm.expectRevert(abi.encodeWithSelector(Curve.CurveLengthMismatch.selector, 1, 2));
        h.curve(hex"04");

        // A header claiming a curve the bytes do not hold.
        vm.expectRevert(abi.encodeWithSelector(FreeboardArgs.FreeboardArgsLengthMismatch.selector, 2, 130));
        h.curve(hex"0403");
    }

    function test_RevertWhen_TheCurveInsideIsInvalid() public {
        bytes memory bad = args;
        // Row 1's USDC weight lives at offset 2 + 32 + 8 + 16; bump its low byte by one.
        uint256 off = 2 + 32 + 8 + 16 + 7;
        bad[off] = bytes1(uint8(bad[off]) + 1);
        vm.expectRevert(abi.encodeWithSelector(Curve.CurveRowDoesNotSumToOne.selector, 1, 1e18 + 1));
        h.validate(bad);
    }

    // -----------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------

    function encodeExternal(bytes memory c, address[] memory t, uint16 cap) external pure returns (bytes memory) {
        return FreeboardArgs.encode(c, t, cap);
    }

    function _slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            out[i] = data[start + i];
        }
    }

    function _patchToken(bytes memory blob, uint256 leg, address token) internal pure returns (bytes memory out) {
        out = blob;
        bytes20 t = bytes20(token);
        for (uint256 i = 0; i < 20; ++i) {
            out[130 + 20 * leg + i] = t[i];
        }
    }
}
