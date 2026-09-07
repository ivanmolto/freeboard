// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Curve — health factor to target weights, as breakpoints with piecewise-linear interpolation
/// @notice The rule Freeboard rebalances by. A curve is an ordered list of breakpoints, each a
///         health factor and the basket's target weights at that health factor. Between
///         breakpoints the weights are interpolated linearly; outside them they are clamped.
///         There is no cliff anywhere on it, which is the whole argument for the curve being
///         public (`docs/freeboard-v0.md` §7).
///
/// @dev FIXED-POINT CONVENTION. Everything is WAD (1e18), and there is one reason: Aave's
///      `getUserAccountData` returns the health factor as WAD (`test/fork/HealthFactor.t.sol`,
///      `test_ReturnShape_DecimalsAreBase1e8ForValues_Bps_AndWadForHealthFactor`), so the HF
///      the extruction reads is compared against the breakpoints WITHOUT conversion. Weights
///      are WAD too: a row sums to exactly `ONE`, and an interpolated row does as well (see
///      `weightsAt`). With weights at 1e18, the interpolation's rounding remainder is at most
///      `legs - 1` wei of a whole basket, an error 1e14 times below one basis point.
///
/// @dev PACKED BYTE LAYOUT. The curve is committed inside the `_extruction` instruction's args,
///      after the 20-byte target the router strips (`Extruction.sol:92`, `:101`, `:110`), so it
///      is defined as bytes, big-endian, no ABI padding:
///
///        offset 0        uint8   breakpoints (m), at least 1
///        offset 1        uint8   legs (n), at least 1
///        offset 2 + r*rowSize, for r in [0, m):
///          +0            uint64  healthFactor, WAD, STRICTLY DESCENDING by row
///          +8 + l*8      uint64  weight of leg l, WAD, for l in [0, n)
///
///        rowSize = 8 * (1 + n)
///        size    = 2 + m * rowSize
///
///      Row 0 is the TOP of the curve: the highest health factor and the loosest target. The
///      last row is the BOTTOM: the lowest health factor and the most conservative target. This
///      is the order the table is written in (`CLAUDE.md`: 2.00, 1.60, 1.30, 1.15).
///
///      `uint64` holds WAD values up to 18.44, which bounds a breakpoint's health factor (a
///      position above the top breakpoint clamps anyway) and comfortably holds a weight, whose
///      maximum is `ONE`. Aave's no-debt sentinel, `type(uint256).max`, is an INPUT to
///      `weightsAt`, never a breakpoint, and needs no special case: it is above row 0 and
///      clamps to the top, which is the right answer — no debt, no risk, no deleveraging.
///
///      SIZE. The Freeboard curve — 4 breakpoints, 3 legs — is 2 + 4 * 32 = 130 bytes
///      (`FREEBOARD_CURVE_SIZE`). The program's instruction has 255 bytes of args
///      (`docs/NOTES-instructions.md`, `[1 byte opcode][1 byte argsLength][args]`); 20 go to
///      the target, 130 to the curve, and 105 remain for the token list and `maxShiftPct`.
///
/// @dev The reads are over `bytes calldata`: inside the extruction the curve IS calldata, and
///      the library never copies it. Tests reach it through an external harness.
library Curve {
    /// @dev The weight scale. A row sums to exactly this.
    uint256 internal constant ONE = 1e18;

    /// @dev Layout constants — see the contract notes.
    uint256 internal constant HEADER_SIZE = 2;
    uint256 internal constant WORD_SIZE = 8;
    uint256 internal constant MAX_UINT64 = type(uint64).max;

    /// @dev The Freeboard position: 4 breakpoints over WETH / WBTC / USDC.
    uint256 internal constant FREEBOARD_CURVE_SIZE = HEADER_SIZE + 4 * (WORD_SIZE * (1 + 3));

    error CurveLengthMismatch(uint256 actual, uint256 expected);
    error CurveNeedsAtLeastOneBreakpoint();
    error CurveNeedsAtLeastOneLeg();
    error CurveBreakpointsNotStrictlyDescending(uint256 row, uint256 healthFactor, uint256 previous);
    error CurveRowDoesNotSumToOne(uint256 row, uint256 sum);
    error CurveValueExceedsUint64(uint256 value);
    error CurveRowHasWrongLegCount(uint256 row, uint256 actual, uint256 expected);
    error CurveDimensionExceedsUint8(uint256 value);

    // -----------------------------------------------------------------------------------
    // Shape
    // -----------------------------------------------------------------------------------

    /// @notice The number of breakpoints, `m`.
    function breakpoints(bytes calldata curve) internal pure returns (uint256) {
        require(curve.length >= HEADER_SIZE, CurveLengthMismatch(curve.length, HEADER_SIZE));
        return uint8(curve[0]);
    }

    /// @notice The number of legs, `n`.
    function legs(bytes calldata curve) internal pure returns (uint256) {
        require(curve.length >= HEADER_SIZE, CurveLengthMismatch(curve.length, HEADER_SIZE));
        return uint8(curve[1]);
    }

    /// @notice The packed size of a curve with `m` breakpoints over `n` legs.
    function size(uint256 m, uint256 n) internal pure returns (uint256) {
        return HEADER_SIZE + m * WORD_SIZE * (1 + n);
    }

    /// @notice The health factor of breakpoint `row`, WAD.
    function healthFactorAt(bytes calldata curve, uint256 row) internal pure returns (uint256) {
        return _u64(curve, _rowOffset(curve, row));
    }

    /// @notice The weight of `leg` at breakpoint `row`, WAD, exactly as committed.
    function weightAt(bytes calldata curve, uint256 row, uint256 leg) internal pure returns (uint256) {
        return _u64(curve, _rowOffset(curve, row) + WORD_SIZE * (1 + leg));
    }

    // -----------------------------------------------------------------------------------
    // Validation
    // -----------------------------------------------------------------------------------

    /// @notice Rejects every curve `weightsAt` cannot honour: wrong length, no breakpoints, no
    ///         legs, health factors not strictly descending, or a row that does not sum to `ONE`.
    /// @dev `weightsAt` checks only the length itself. A curve reaches the extruction through
    ///      `ship()`, committed by the maker, so semantic validation belongs where the bytes are
    ///      built and decoded (T14's `FreeboardArgs`), once, not on every fill.
    function validate(bytes calldata curve) internal pure {
        uint256 m = breakpoints(curve);
        uint256 n = legs(curve);
        require(m > 0, CurveNeedsAtLeastOneBreakpoint());
        require(n > 0, CurveNeedsAtLeastOneLeg());
        require(curve.length == size(m, n), CurveLengthMismatch(curve.length, size(m, n)));

        uint256 previous = type(uint256).max;
        for (uint256 r = 0; r < m; ++r) {
            uint256 hf = healthFactorAt(curve, r);
            require(hf < previous, CurveBreakpointsNotStrictlyDescending(r, hf, previous));
            previous = hf;

            uint256 sum;
            for (uint256 l = 0; l < n; ++l) {
                sum += weightAt(curve, r, l);
            }
            require(sum == ONE, CurveRowDoesNotSumToOne(r, sum));
        }
    }

    // -----------------------------------------------------------------------------------
    // The curve
    // -----------------------------------------------------------------------------------

    /// @notice Target weights at `healthFactor`, WAD, summing to exactly `ONE`.
    /// @dev CLAMPING. At or above the top breakpoint's health factor the top row is returned,
    ///      verbatim; at or below the bottom breakpoint's, the bottom row. `type(uint256).max`
    ///      — Aave's no-debt sentinel — is above every breakpoint and takes the top row.
    ///
    ///      INTERPOLATION. Strictly between two breakpoints, with `lo` the lower-HF row and
    ///      `hi` the higher-HF row, each leg is
    ///
    ///        w = w_lo + (w_hi - w_lo) * (hf - hf_lo) / (hf_hi - hf_lo)
    ///
    ///      in whichever direction the leg moves, ROUNDED DOWN to the exact value: the added
    ///      delta of a rising leg is floored, the subtracted delta of a falling leg is ceiled,
    ///      so each interpolated leg is within one wei BELOW its exact value, never above.
    ///      Products are at most 2^64 * 2^64 and cannot overflow.
    ///
    ///      EXACT SUM. Every leg but the last is interpolated; the last leg is `ONE` minus the
    ///      others. Because no interpolated leg exceeds its exact value, their sum does not
    ///      exceed `ONE` minus the last leg's exact value: the last leg is never below its own
    ///      exact value, never more than `n - 1` wei above it, and cannot underflow for a curve
    ///      that passes `validate`. At a breakpoint the multiplier is zero, so every leg is its
    ///      committed value and the last leg is the committed value too. In the Freeboard
    ///      basket the last leg is the debt asset, so the wei of rounding fall toward safety.
    ///
    ///      Requires the curve to pass `validate`; checks only the length here (see there).
    function weightsAt(bytes calldata curve, uint256 healthFactor) internal pure returns (uint256[] memory weights) {
        uint256 m = breakpoints(curve);
        uint256 n = legs(curve);
        require(curve.length == size(m, n), CurveLengthMismatch(curve.length, size(m, n)));

        weights = new uint256[](n);

        // Clamp above the top (row 0) and below the bottom (row m - 1).
        if (healthFactor >= healthFactorAt(curve, 0)) {
            return _row(curve, 0, n, weights);
        }
        if (healthFactor <= healthFactorAt(curve, m - 1)) {
            return _row(curve, m - 1, n, weights);
        }

        // Find hi = the last row whose HF is strictly above the input; lo = hi + 1 is then the
        // first row at or below it. Both exist: the clamps above excluded the ends.
        uint256 hi = 0;
        while (healthFactorAt(curve, hi + 1) > healthFactor) {
            ++hi;
        }
        uint256 lo = hi + 1;

        uint256 hfLo = healthFactorAt(curve, lo);
        uint256 rise = healthFactor - hfLo;
        uint256 run = healthFactorAt(curve, hi) - hfLo;

        uint256 sum;
        for (uint256 l = 0; l + 1 < n; ++l) {
            uint256 wLo = weightAt(curve, lo, l);
            uint256 wHi = weightAt(curve, hi, l);
            uint256 w = wHi >= wLo ? wLo + ((wHi - wLo) * rise) / run : wLo - Math.ceilDiv((wLo - wHi) * rise, run);
            weights[l] = w;
            sum += w;
        }
        weights[n - 1] = ONE - sum;
    }

    // -----------------------------------------------------------------------------------
    // Encoding — for tests, scripts and the program builder; never on the fill path
    // -----------------------------------------------------------------------------------

    /// @notice Packs breakpoints into the byte layout above. `weights[r]` is row `r`.
    /// @dev Enforces the same rules as `validate` on the way in, so an encoded curve always
    ///      decodes; the two are checked against each other in the tests.
    function encode(
        uint256[] memory healthFactors,
        uint256[][] memory weights
    )
        internal
        pure
        returns (bytes memory out)
    {
        uint256 m = healthFactors.length;
        require(m > 0, CurveNeedsAtLeastOneBreakpoint());
        require(m <= type(uint8).max, CurveDimensionExceedsUint8(m));
        require(weights.length == m, CurveRowHasWrongLegCount(0, weights.length, m));

        uint256 n = weights[0].length;
        require(n > 0, CurveNeedsAtLeastOneLeg());
        require(n <= type(uint8).max, CurveDimensionExceedsUint8(n));

        out = abi.encodePacked(uint8(m), uint8(n));

        uint256 previous = type(uint256).max;
        for (uint256 r = 0; r < m; ++r) {
            uint256 hf = healthFactors[r];
            require(hf <= MAX_UINT64, CurveValueExceedsUint64(hf));
            require(hf < previous, CurveBreakpointsNotStrictlyDescending(r, hf, previous));
            previous = hf;
            require(weights[r].length == n, CurveRowHasWrongLegCount(r, weights[r].length, n));

            out = bytes.concat(out, bytes8(uint64(hf)));

            uint256 sum;
            for (uint256 l = 0; l < n; ++l) {
                uint256 w = weights[r][l];
                require(w <= MAX_UINT64, CurveValueExceedsUint64(w));
                out = bytes.concat(out, bytes8(uint64(w)));
                sum += w;
            }
            require(sum == ONE, CurveRowDoesNotSumToOne(r, sum));
        }
    }

    // -----------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------

    function _rowOffset(bytes calldata curve, uint256 row) private pure returns (uint256) {
        return HEADER_SIZE + row * WORD_SIZE * (1 + legs(curve));
    }

    /// @dev Big-endian uint64 at `offset`. The slice conversion pads a short slice with zeros,
    ///      so the length is checked first rather than trusted.
    function _u64(bytes calldata curve, uint256 offset) private pure returns (uint256) {
        require(curve.length >= offset + WORD_SIZE, CurveLengthMismatch(curve.length, offset + WORD_SIZE));
        return uint64(bytes8(curve[offset:offset + WORD_SIZE]));
    }

    /// @dev A committed row, verbatim.
    function _row(
        bytes calldata curve,
        uint256 row,
        uint256 n,
        uint256[] memory weights
    )
        private
        pure
        returns (uint256[] memory)
    {
        for (uint256 l = 0; l < n; ++l) {
            weights[l] = weightAt(curve, row, l);
        }
        return weights;
    }
}
