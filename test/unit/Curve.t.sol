// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Curve } from "../../src/libs/Curve.sol";

/// @dev The library reads `bytes calldata`, as the extruction will hand it; a test body holds
///      memory, so every call crosses an external boundary here.
contract CurveHarness {
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }

    function validate(bytes calldata curve) external pure {
        Curve.validate(curve);
    }

    function breakpoints(bytes calldata curve) external pure returns (uint256) {
        return Curve.breakpoints(curve);
    }

    function legs(bytes calldata curve) external pure returns (uint256) {
        return Curve.legs(curve);
    }

    function healthFactorAt(bytes calldata curve, uint256 row) external pure returns (uint256) {
        return Curve.healthFactorAt(curve, row);
    }

    function weightAt(bytes calldata curve, uint256 row, uint256 leg) external pure returns (uint256) {
        return Curve.weightAt(curve, row, leg);
    }
}

/// @title CurveTest — T11
/// @notice The HF -> weights curve: breakpoints, interpolation, clamping, the no-debt sentinel,
///         and the one property everything downstream leans on — weights sum to exactly `ONE`
///         at every health factor, interpolated or not.
contract CurveTest is Test {
    uint256 internal constant ONE = Curve.ONE;

    /// @dev The Freeboard basket order: WETH, WBTC, USDC (the debt asset, last).
    uint256 internal constant ETH = 0;
    uint256 internal constant BTC = 1;
    uint256 internal constant USD = 2;

    CurveHarness internal h;
    bytes internal freeboard;

    function setUp() public {
        h = new CurveHarness();
        freeboard = _freeboardCurve();
    }

    /// @dev The table from CLAUDE.md, top row first.
    ///        HF 2.00 -> 50 / 30 / 20
    ///        HF 1.60 -> 40 / 24 / 36
    ///        HF 1.30 -> 30 / 16 / 54
    ///        HF 1.15 -> 20 / 10 / 70
    function _freeboardCurve() internal pure returns (bytes memory) {
        uint256[] memory hf = new uint256[](4);
        hf[0] = 2.0e18;
        hf[1] = 1.6e18;
        hf[2] = 1.3e18;
        hf[3] = 1.15e18;

        uint256[][] memory w = new uint256[][](4);
        w[0] = _row(0.5e18, 0.3e18, 0.2e18);
        w[1] = _row(0.4e18, 0.24e18, 0.36e18);
        w[2] = _row(0.3e18, 0.16e18, 0.54e18);
        w[3] = _row(0.2e18, 0.1e18, 0.7e18);

        return Curve.encode(hf, w);
    }

    function _row(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _assertRow(uint256[] memory w, uint256 a, uint256 b, uint256 c, string memory where) internal pure {
        assertEq(w.length, 3, string.concat(where, ": leg count"));
        assertEq(w[ETH], a, string.concat(where, ": WETH weight"));
        assertEq(w[BTC], b, string.concat(where, ": WBTC weight"));
        assertEq(w[USD], c, string.concat(where, ": USDC weight"));
        assertEq(w[ETH] + w[BTC] + w[USD], ONE, string.concat(where, ": row does not sum to ONE"));
    }

    // -----------------------------------------------------------------------------------
    // 1. Layout
    // -----------------------------------------------------------------------------------

    /// @dev The size the natspec quotes, byte for byte: header, then 4 rows of
    ///      [uint64 hf][3 x uint64 weight], big-endian, no padding.
    function test_Layout_FreeboardCurveIs130Bytes() public view {
        assertEq(Curve.FREEBOARD_CURVE_SIZE, 130, "the quoted size");
        assertEq(Curve.size(4, 3), 130, "size(4, 3)");
        assertEq(freeboard.length, 130, "encoded length");

        assertEq(uint8(freeboard[0]), 4, "header: breakpoints");
        assertEq(uint8(freeboard[1]), 3, "header: legs");
        assertEq(h.breakpoints(freeboard), 4, "breakpoints()");
        assertEq(h.legs(freeboard), 3, "legs()");

        // Row 0 at offset 2: 2.00e18 then 0.50e18 / 0.30e18 / 0.20e18, each 8 bytes.
        bytes memory row0 = abi.encodePacked(uint64(2.0e18), uint64(0.5e18), uint64(0.3e18), uint64(0.2e18));
        for (uint256 i = 0; i < 32; ++i) {
            assertEq(uint8(freeboard[2 + i]), uint8(row0[i]), "row 0 bytes");
        }

        // The last row ends the curve: 1.15e18 then 0.20e18 / 0.10e18 / 0.70e18.
        bytes memory row3 = abi.encodePacked(uint64(1.15e18), uint64(0.2e18), uint64(0.1e18), uint64(0.7e18));
        for (uint256 i = 0; i < 32; ++i) {
            assertEq(uint8(freeboard[2 + 3 * 32 + i]), uint8(row3[i]), "row 3 bytes");
        }

        // A curve fits its slot: 20-byte target + curve leaves room for 3 tokens and a cap.
        assertLe(20 + freeboard.length + 3 * 20 + 2, 255, "args exceed the 255-byte instruction cap");
    }

    function test_Layout_DecodesWhatEncodeWrote() public view {
        h.validate(freeboard);

        assertEq(h.healthFactorAt(freeboard, 0), 2.0e18);
        assertEq(h.healthFactorAt(freeboard, 1), 1.6e18);
        assertEq(h.healthFactorAt(freeboard, 2), 1.3e18);
        assertEq(h.healthFactorAt(freeboard, 3), 1.15e18);

        assertEq(h.weightAt(freeboard, 0, USD), 0.2e18);
        assertEq(h.weightAt(freeboard, 1, BTC), 0.24e18);
        assertEq(h.weightAt(freeboard, 2, ETH), 0.3e18);
        assertEq(h.weightAt(freeboard, 3, USD), 0.7e18);
    }

    // -----------------------------------------------------------------------------------
    // 2. Every breakpoint, verbatim
    // -----------------------------------------------------------------------------------

    function test_Breakpoint_Hf2_00_Is50_30_20() public view {
        _assertRow(h.weightsAt(freeboard, 2.0e18), 0.5e18, 0.3e18, 0.2e18, "HF 2.00");
    }

    function test_Breakpoint_Hf1_60_Is40_24_36() public view {
        _assertRow(h.weightsAt(freeboard, 1.6e18), 0.4e18, 0.24e18, 0.36e18, "HF 1.60");
    }

    function test_Breakpoint_Hf1_30_Is30_16_54() public view {
        _assertRow(h.weightsAt(freeboard, 1.3e18), 0.3e18, 0.16e18, 0.54e18, "HF 1.30");
    }

    function test_Breakpoint_Hf1_15_Is20_10_70() public view {
        _assertRow(h.weightsAt(freeboard, 1.15e18), 0.2e18, 0.1e18, 0.7e18, "HF 1.15");
    }

    // -----------------------------------------------------------------------------------
    // 3. Interpolation
    // -----------------------------------------------------------------------------------

    /// @dev Halfway between 2.00 and 1.60: the midpoint of each leg, exactly.
    function test_Interpolated_Hf1_80_Is45_27_28() public view {
        _assertRow(h.weightsAt(freeboard, 1.8e18), 0.45e18, 0.27e18, 0.28e18, "HF 1.80");
    }

    /// @dev A third of the way up from 1.15 to 1.30, where the exact values are not on the
    ///      wei grid. WETH exact: 0.20 + 0.10/3 = 0.2333...; rounded DOWN to ...333. WBTC
    ///      exact: 0.10 + 0.06/3 = 0.12, on the grid. USDC is the remainder: exact
    ///      0.6466...666.67, returned as ...667, within a wei above exact, so the row sums to ONE.
    function test_Interpolated_Hf1_20_RoundsLegsDownAndRemainderToTheDebtAsset() public view {
        uint256[] memory w = h.weightsAt(freeboard, 1.2e18);
        _assertRow(w, 233_333_333_333_333_333, 0.12e18, 646_666_666_666_666_667, "HF 1.20");
    }

    /// @dev One wei off a breakpoint is not the breakpoint. Just above 1.15 the segment up to
    ///      1.30 is used and the collateral legs' one-wei rise floors to nothing; just below
    ///      1.30 the same segment is used from the other end and both collateral legs are one
    ///      wei short, so the debt asset takes two.
    function test_Interpolated_OneWeiOffABreakpointUsesTheSegmentBetween() public view {
        uint256[] memory above = h.weightsAt(freeboard, 1.15e18 + 1);
        _assertRow(above, 0.2e18, 0.1e18, 0.7e18, "HF 1.15 + 1 wei");

        uint256[] memory below = h.weightsAt(freeboard, 1.3e18 - 1);
        _assertRow(below, 0.3e18 - 1, 0.16e18 - 1, 0.54e18 + 2, "HF 1.30 - 1 wei");
    }

    // -----------------------------------------------------------------------------------
    // 4. Clamping and the no-debt sentinel
    // -----------------------------------------------------------------------------------

    function test_Clamp_AboveTheTopBreakpointIsTheTopRow() public view {
        _assertRow(h.weightsAt(freeboard, 2.0e18 + 1), 0.5e18, 0.3e18, 0.2e18, "HF 2.00 + 1 wei");
        _assertRow(h.weightsAt(freeboard, 3.5e18), 0.5e18, 0.3e18, 0.2e18, "HF 3.50");
        _assertRow(h.weightsAt(freeboard, 1000e18), 0.5e18, 0.3e18, 0.2e18, "HF 1000");
        _assertRow(h.weightsAt(freeboard, type(uint64).max), 0.5e18, 0.3e18, 0.2e18, "HF uint64.max");
    }

    function test_Clamp_BelowTheBottomBreakpointIsTheBottomRow() public view {
        _assertRow(h.weightsAt(freeboard, 1.15e18 - 1), 0.2e18, 0.1e18, 0.7e18, "HF 1.15 - 1 wei");
        _assertRow(h.weightsAt(freeboard, 1.0e18), 0.2e18, 0.1e18, 0.7e18, "HF 1.00");
        _assertRow(h.weightsAt(freeboard, 0.5e18), 0.2e18, 0.1e18, 0.7e18, "HF 0.50");
        _assertRow(h.weightsAt(freeboard, 0), 0.2e18, 0.1e18, 0.7e18, "HF 0");
    }

    /// @dev Aave returns `type(uint256).max` for a position with no debt, by two code paths
    ///      (`AaveHealthFactorForkTest.test_NoDebt_ReturnsMaxUint256_ByBothRoutes`). No debt, no
    ///      risk: the loosest target, with no arithmetic on the sentinel to overflow.
    function test_NoDebtSentinel_MaxUint256_ClampsToTheTop() public view {
        _assertRow(h.weightsAt(freeboard, type(uint256).max), 0.5e18, 0.3e18, 0.2e18, "no-debt sentinel");
    }

    // -----------------------------------------------------------------------------------
    // 5. Fuzz: the sum is exact everywhere, and the curve is monotone
    // -----------------------------------------------------------------------------------

    /// @dev Any health factor at all, including the sentinel and the wei around every
    ///      breakpoint: the three weights sum to exactly ONE and stay inside the curve's range.
    function testFuzz_Weights_SumExactlyToOne_OnTheFreeboardCurve(uint256 hf) public view {
        uint256[] memory w = h.weightsAt(freeboard, hf);

        assertEq(w.length, 3, "leg count");
        assertEq(w[ETH] + w[BTC] + w[USD], ONE, "weights do not sum to ONE");

        assertLe(w[ETH], 0.5e18, "WETH above the top row");
        assertGe(w[ETH], 0.2e18, "WETH below the bottom row");
        assertLe(w[BTC], 0.3e18, "WBTC above the top row");
        assertGe(w[BTC], 0.1e18, "WBTC below the bottom row");
        assertLe(w[USD], 0.7e18, "USDC above the bottom row");
        assertGe(w[USD], 0.2e18, "USDC below the top row");
    }

    /// @dev The continuity argument in one property: as HF falls, the collateral legs never
    ///      rise and the debt-asset leg never falls. No cliff, no reversal, at any pair of HFs.
    function testFuzz_Weights_AreMonotoneInHealthFactor(uint256 hfA, uint256 hfB) public view {
        (uint256 higher, uint256 lower) = hfA >= hfB ? (hfA, hfB) : (hfB, hfA);

        uint256[] memory atHigher = h.weightsAt(freeboard, higher);
        uint256[] memory atLower = h.weightsAt(freeboard, lower);

        assertGe(atHigher[ETH], atLower[ETH], "WETH rose as HF fell");
        assertGe(atHigher[BTC], atLower[BTC], "WBTC rose as HF fell");
        assertLe(atHigher[USD], atLower[USD], "USDC fell as HF fell");
    }

    /// @dev The exact-sum property is of the LIBRARY, not the Freeboard table: a random valid
    ///      curve of 1-6 breakpoints over 1-5 legs, random health factor. Also pins the rounding
    ///      bounds the natspec claims: each interpolated leg within one wei below exact, the
    ///      last leg within `n - 1` wei above exact.
    function testFuzz_Weights_SumExactlyToOne_OnAnyValidCurve(
        uint8 mSeed,
        uint8 nSeed,
        uint256 hf,
        bytes32 seed
    )
        public
        view
    {
        uint256 m = 1 + (uint256(mSeed) % 6);
        uint256 n = 1 + (uint256(nSeed) % 5);
        (uint256[] memory hfs, uint256[][] memory rows) = _randomCurve(m, n, seed);
        bytes memory curve = Curve.encode(hfs, rows);
        h.validate(curve);

        uint256[] memory w = h.weightsAt(curve, hf);
        assertEq(w.length, n, "leg count");

        uint256 sum;
        for (uint256 l = 0; l < n; ++l) {
            sum += w[l];
        }
        assertEq(sum, ONE, "weights do not sum to ONE");

        // Clamped: the committed row, verbatim.
        (uint256 lo, uint256 hi) = _segment(hfs, hf);
        if (lo == hi) {
            for (uint256 l = 0; l < n; ++l) {
                assertEq(w[l], rows[lo][l], "a clamped row is not verbatim");
            }
            return;
        }

        // Interpolated: compare against exact values scaled by `run` to stay in integers.
        uint256 rise = hf - hfs[lo];
        uint256 run = hfs[hi] - hfs[lo];

        for (uint256 l = 0; l < n; ++l) {
            // exact * run, to stay in integers: wLo * run + (wHi - wLo) * rise
            uint256 exactTimesRun = rows[hi][l] >= rows[lo][l]
                ? rows[lo][l] * run + (rows[hi][l] - rows[lo][l]) * rise
                : rows[lo][l] * run - (rows[lo][l] - rows[hi][l]) * rise;

            if (l + 1 < n) {
                assertLe(w[l] * run, exactTimesRun, "an interpolated leg exceeds its exact value");
                assertGt((w[l] + 1) * run, exactTimesRun, "an interpolated leg is more than a wei below exact");
            } else {
                assertGe(w[l] * run, exactTimesRun, "the last leg is below its exact value");
                assertLe(w[l] * run, exactTimesRun + (n - 1) * run, "the last leg is more than n-1 wei above exact");
            }
        }
    }

    /// @dev `m` strictly descending health factors in [0, uint64.max]; each row `n` weights
    ///      summing to ONE, the last leg the remainder (so it can be small, including zero — the
    ///      case the rounding rule has to survive).
    function _randomCurve(
        uint256 m,
        uint256 n,
        bytes32 seed
    )
        internal
        pure
        returns (uint256[] memory hfs, uint256[][] memory rows)
    {
        hfs = new uint256[](m);
        rows = new uint256[][](m);

        // Descending: draw m distinct values by giving each row a strictly smaller ceiling.
        uint256 ceiling = type(uint64).max;
        for (uint256 r = 0; r < m; ++r) {
            uint256 draw = uint256(keccak256(abi.encode(seed, "hf", r)));
            // In [m - r - 1, ceiling - 1]: strictly below the row above, with room for the rows below.
            hfs[r] = draw % (ceiling - (m - r - 1)) + (m - r - 1);
            ceiling = hfs[r];

            rows[r] = new uint256[](n);
            uint256 left = ONE;
            for (uint256 l = 0; l + 1 < n; ++l) {
                uint256 wDraw = uint256(keccak256(abi.encode(seed, "w", r, l)));
                // Half the time hand a leg almost everything, so remainders get tiny.
                rows[r][l] = wDraw % 2 == 0 ? (wDraw / 2) % (left + 1) : (left - (wDraw / 2) % (left / 1000 + 1));
                left -= rows[r][l];
            }
            rows[r][n - 1] = left;
        }
    }

    /// @dev The segment `weightsAt` uses: `hi` the last row strictly above `hf`, `lo = hi + 1`;
    ///      or the clamped row twice.
    function _segment(uint256[] memory hfs, uint256 hf) internal pure returns (uint256 lo, uint256 hi) {
        uint256 m = hfs.length;
        if (hf >= hfs[0]) {
            return (0, 0);
        }
        if (hf <= hfs[m - 1]) {
            return (m - 1, m - 1);
        }
        hi = 0;
        while (hfs[hi + 1] > hf) {
            ++hi;
        }
        lo = hi + 1;
    }

    // -----------------------------------------------------------------------------------
    // 6. Validation: what encode refuses and validate rejects
    // -----------------------------------------------------------------------------------

    function test_Validate_RejectsARowThatDoesNotSumToOne() public {
        bytes memory bad = freeboard;
        // Row 1's USDC weight lives at offset 2 + 32 + 8 + 16; bump its low byte by one.
        uint256 off = 2 + 32 + 8 + 16 + 7;
        bad[off] = bytes1(uint8(bad[off]) + 1);

        vm.expectRevert(abi.encodeWithSelector(Curve.CurveRowDoesNotSumToOne.selector, 1, ONE + 1));
        h.validate(bad);
    }

    function test_Validate_RejectsBreakpointsNotStrictlyDescending() public {
        uint256[] memory hf = new uint256[](2);
        hf[0] = 1.5e18;
        hf[1] = 1.5e18;
        uint256[][] memory w = new uint256[][](2);
        w[0] = _row(0.5e18, 0.3e18, 0.2e18);
        w[1] = _row(0.5e18, 0.3e18, 0.2e18);

        vm.expectRevert(abi.encodeWithSelector(Curve.CurveBreakpointsNotStrictlyDescending.selector, 1, 1.5e18, 1.5e18));
        this.encodeExternal(hf, w);
    }

    function test_Validate_RejectsTruncatedBytes() public {
        bytes memory cut = new bytes(freeboard.length - 1);
        for (uint256 i = 0; i < cut.length; ++i) {
            cut[i] = freeboard[i];
        }

        vm.expectRevert(abi.encodeWithSelector(Curve.CurveLengthMismatch.selector, 129, 130));
        h.validate(cut);

        vm.expectRevert(abi.encodeWithSelector(Curve.CurveLengthMismatch.selector, 129, 130));
        h.weightsAt(cut, 1.8e18);
    }

    function test_Validate_RejectsEmptyHeader() public {
        bytes memory noRows = abi.encodePacked(uint8(0), uint8(3));
        vm.expectRevert(Curve.CurveNeedsAtLeastOneBreakpoint.selector);
        h.validate(noRows);

        bytes memory noLegs = abi.encodePacked(uint8(1), uint8(0), uint64(1e18));
        vm.expectRevert(Curve.CurveNeedsAtLeastOneLeg.selector);
        h.validate(noLegs);
    }

    /// @dev A single breakpoint is a constant curve: every HF returns that row.
    function test_SingleBreakpoint_IsConstant() public view {
        uint256[] memory hf = new uint256[](1);
        hf[0] = 1.5e18;
        uint256[][] memory w = new uint256[][](1);
        w[0] = _row(0.6e18, 0.3e18, 0.1e18);
        bytes memory curve = Curve.encode(hf, w);

        _assertRow(h.weightsAt(curve, 0), 0.6e18, 0.3e18, 0.1e18, "below");
        _assertRow(h.weightsAt(curve, 1.5e18), 0.6e18, 0.3e18, 0.1e18, "at");
        _assertRow(h.weightsAt(curve, type(uint256).max), 0.6e18, 0.3e18, 0.1e18, "sentinel");
    }

    function encodeExternal(uint256[] memory hf, uint256[][] memory w) external pure returns (bytes memory) {
        return Curve.encode(hf, w);
    }
}
