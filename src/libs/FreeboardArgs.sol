// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Curve } from "./Curve.sol";

/// @title FreeboardArgs — the bytes that follow the router-stripped 20-byte extruction target
/// @notice The one definition of what a Freeboard program commits to. `ship()` hashes the
///         program, so these bytes ARE the strategy: a different curve, a different token list
///         or a different cap is a different strategy hash with no balances behind it, and a
///         fill against it reverts in Aqua before this library ever runs. That is why the
///         encoder and the decoder live in one file — a byte of drift between what
///         `ProgramBuilder` ships and what `FreeboardExtruction` parses would surface as Aqua's
///         cryptic "insufficient balance", and one layout read by both is what prevents it.
///
/// @dev LAYOUT, big-endian, no ABI padding, immediately after the target the router strips
///      (`Extruction.sol:92`, `:101`, `:110`):
///
///        offset 0                       curve      `Curve` packed layout, self-sized:
///                                                    curveSize = Curve.size(args[0], args[1])
///        offset curveSize + 20 * l      address    token of leg l, for l in [0, n), in the
///                                                    curve's leg order — leg l's weight is the
///                                                    target for THIS token
///        offset curveSize + 20 * n      uint16     maxShiftBps — the largest share of the
///                                                    basket's value one fill may move, in
///                                                    basis points (T15 enforces it); non-zero,
///                                                    see below
///
///        size = curveSize + 20 * n + 2
///
/// @dev A ZERO CAP IS REFUSED. `FreeboardExtruction` lets a fill through only if the value it
///      moves, rounded up to a basis point of the basket, is at most the cap; under a zero cap
///      only a fill of zero value passes, and the router accepts no such fill. A zero cap is
///      therefore a basket no taker can ever fill, and it has the shape of the allowance trap
///      (CLAUDE.md): shipped, every leg reported, HF readable, and silently unfillable.
///      Refusing it here, where the bytes are built and where the Ledger flow validates what
///      the borrower is about to sign, is what stops it from being signed. No ceiling: neither
///      side of a fill exceeds the out leg (plus a wei of the in token from rounding), so on
///      any basket that is not dust a cap of 10,001 bps or more never binds — the Ledger flow
///      should show such a cap as "no per-fill cap" — and a structural ceiling would refuse
///      nothing a reader cannot see for themselves;
///      a tighter one is a risk policy, which is the borrower's to sign, not this library's to
///      refuse.
///
///      The Freeboard position — 4 breakpoints over WETH / WBTC / USDC — is 130 + 60 + 2 = 192
///      bytes (`FREEBOARD_ARGS_SIZE`); with the 20-byte target that is 212 of the 255 bytes one
///      instruction may carry (`docs/NOTES-instructions.md`, `[opcode][argsLength][args]`).
///
/// @dev NO ADDRESS OF A POSITION, ANYWHERE. The only addresses in these bytes are tokens.
///      Whose health factor prices the basket is `query.maker`, which the router names from
///      the order; the program cannot name a subject (`IAaveV3Pool.sol`, `HealthFactorForkTest`).
///
/// @dev The reads are over `bytes calldata` because inside the extruction the args ARE calldata
///      and `Curve` reads calldata; the encoder is memory because a program is built in memory.
library FreeboardArgs {
    uint256 internal constant ADDRESS_SIZE = 20;
    uint256 internal constant CAP_SIZE = 2;

    /// @dev The Freeboard position: `Curve.FREEBOARD_CURVE_SIZE` + 3 tokens + the cap.
    uint256 internal constant FREEBOARD_ARGS_SIZE = Curve.FREEBOARD_CURVE_SIZE + 3 * ADDRESS_SIZE + CAP_SIZE;

    error FreeboardArgsLengthMismatch(uint256 actual, uint256 expected);
    error FreeboardArgsTokenCountMismatch(uint256 tokens, uint256 legs);
    error FreeboardArgsZeroToken(uint256 leg);
    error FreeboardArgsDuplicateToken(address token);
    error FreeboardArgsZeroCap();

    // -----------------------------------------------------------------------------------
    // Shape
    // -----------------------------------------------------------------------------------

    /// @notice The packed size of args for a curve of `m` breakpoints over `n` legs.
    function size(uint256 m, uint256 n) internal pure returns (uint256) {
        return Curve.size(m, n) + ADDRESS_SIZE * n + CAP_SIZE;
    }

    /// @notice The curve, as the slice `Curve` reads. Checks only that the bytes are long
    ///         enough to hold it; `validate` checks everything.
    function curve(bytes calldata args) internal pure returns (bytes calldata) {
        uint256 curveSize = _curveSize(args);
        return args[0:curveSize];
    }

    /// @notice The number of legs, `n` — the curve's, and therefore the token list's.
    function legs(bytes calldata args) internal pure returns (uint256) {
        return Curve.legs(args);
    }

    /// @notice The token of leg `l`.
    function tokenAt(bytes calldata args, uint256 l) internal pure returns (address) {
        uint256 offset = _curveSize(args) + ADDRESS_SIZE * l;
        require(args.length >= offset + ADDRESS_SIZE, FreeboardArgsLengthMismatch(args.length, offset + ADDRESS_SIZE));
        return address(bytes20(args[offset:offset + ADDRESS_SIZE]));
    }

    /// @notice Every token, in leg order.
    function tokens(bytes calldata args) internal pure returns (address[] memory list) {
        uint256 n = legs(args);
        list = new address[](n);
        for (uint256 l = 0; l < n; ++l) {
            list[l] = tokenAt(args, l);
        }
    }

    /// @notice The per-fill cap, in basis points of the basket's value.
    function maxShiftBps(bytes calldata args) internal pure returns (uint256) {
        uint256 offset = _curveSize(args) + ADDRESS_SIZE * legs(args);
        require(args.length >= offset + CAP_SIZE, FreeboardArgsLengthMismatch(args.length, offset + CAP_SIZE));
        return uint16(bytes2(args[offset:offset + CAP_SIZE]));
    }

    // -----------------------------------------------------------------------------------
    // Validation
    // -----------------------------------------------------------------------------------

    /// @notice Rejects every args blob the extruction cannot price: a curve `Curve.validate`
    ///         rejects, a length that is not exactly `size(m, n)`, a zero token, a token
    ///         listed twice — and the one blob it could price but never fill, a zero cap.
    /// @dev Where the bytes are built and decoded — once, not on every fill (`Curve.validate`).
    function validate(bytes calldata args) internal pure {
        bytes calldata c = curve(args);
        Curve.validate(c);

        uint256 n = Curve.legs(c);
        uint256 expected = size(Curve.breakpoints(c), n);
        require(args.length == expected, FreeboardArgsLengthMismatch(args.length, expected));

        for (uint256 l = 0; l < n; ++l) {
            address token = tokenAt(args, l);
            require(token != address(0), FreeboardArgsZeroToken(l));
            for (uint256 k = 0; k < l; ++k) {
                require(tokenAt(args, k) != token, FreeboardArgsDuplicateToken(token));
            }
        }
        require(maxShiftBps(args) != 0, FreeboardArgsZeroCap());
    }

    // -----------------------------------------------------------------------------------
    // Encoding — for the program builder, tests and scripts; never on the fill path
    // -----------------------------------------------------------------------------------

    /// @notice Packs a curve, its token list and the cap into the layout above.
    /// @param curveBytes A curve as `Curve.encode` produced it (so already validated).
    /// @param tokenList One token per curve leg, in leg order; non-zero and distinct.
    /// @param cap `maxShiftBps`, non-zero.
    /// @dev Enforces the same rules as `validate` on the way in, so an encoded blob always
    ///      decodes; the two are checked against each other in the tests.
    function encode(
        bytes memory curveBytes,
        address[] memory tokenList,
        uint16 cap
    )
        internal
        pure
        returns (bytes memory out)
    {
        require(
            curveBytes.length >= Curve.HEADER_SIZE, FreeboardArgsLengthMismatch(curveBytes.length, Curve.HEADER_SIZE)
        );
        uint256 m = uint8(curveBytes[0]);
        uint256 n = uint8(curveBytes[1]);
        require(curveBytes.length == Curve.size(m, n), FreeboardArgsLengthMismatch(curveBytes.length, Curve.size(m, n)));
        require(tokenList.length == n, FreeboardArgsTokenCountMismatch(tokenList.length, n));
        require(cap != 0, FreeboardArgsZeroCap());

        out = curveBytes;
        for (uint256 l = 0; l < n; ++l) {
            require(tokenList[l] != address(0), FreeboardArgsZeroToken(l));
            for (uint256 k = 0; k < l; ++k) {
                require(tokenList[k] != tokenList[l], FreeboardArgsDuplicateToken(tokenList[l]));
            }
            out = bytes.concat(out, bytes20(tokenList[l]));
        }
        out = bytes.concat(out, bytes2(cap));
    }

    // -----------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------

    /// @dev The curve's size from its own header, checked against the bytes on hand.
    function _curveSize(bytes calldata args) private pure returns (uint256 curveSize) {
        curveSize = Curve.size(Curve.breakpoints(args), Curve.legs(args));
        require(args.length >= curveSize, FreeboardArgsLengthMismatch(args.length, curveSize));
    }
}
