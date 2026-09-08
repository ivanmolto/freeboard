// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PricingReference — the Freeboard spread, derived the OTHER way
/// @notice `FreeboardExtruction` prices a fill from the basket's distance before and after it
///         ("price by the delta"). This library prices the same fill by integrating the
///         marginal spread along the move: toward while both moving legs approach their
///         targets, mixed while one does, away while neither does, with the pieces cut where
///         each leg crosses its target. The two are the same function — the contract's natspec
///         proves it — and the fork tests assert they agree to the wei on the deployed router.
///         Nothing here is imported from `src/`; the schedule is restated, so a change to
///         either side is a red test.
library PricingReference {
    uint256 internal constant ONE = 1e18;

    /// @dev The schedule, restated: 10 / 55 / 100 bps.
    uint256 internal constant TOWARD = 0.001e18;
    uint256 internal constant MIXED = 0.0055e18;
    uint256 internal constant AWAY = 0.01e18;

    /// @notice The spread numerator `S * ONE * ONE` for moving `x` value units from the out leg
    ///         into the in leg, on a basket worth `total` whose two moving legs hold `vIn` and
    ///         `vOut` against WAD targets `wIn` and `wOut`.
    /// @dev In `x * ONE` space the crossings are integers: the in leg reaches its target after
    ///      `wIn * total - vIn * ONE` (if it starts below), the out leg after
    ///      `vOut * ONE - wOut * total` (if it starts above). Between crossings the rate is
    ///      constant, so the integral is a sum of at most three products.
    function spreadNumerator(
        uint256 vIn,
        uint256 vOut,
        uint256 wIn,
        uint256 wOut,
        uint256 total,
        uint256 x
    )
        internal
        pure
        returns (uint256 numerator)
    {
        uint256 end = x * ONE;
        uint256 kIn = vIn * ONE < wIn * total ? wIn * total - vIn * ONE : 0;
        uint256 kOut = vOut * ONE > wOut * total ? vOut * ONE - wOut * total : 0;
        (uint256 first, uint256 second) = kIn < kOut ? (kIn, kOut) : (kOut, kIn);

        // Both toward until the first crossing, one toward until the second, then neither.
        uint256 a = _min(first, end);
        uint256 b = _min(second, end);
        numerator = a * TOWARD + (b - a) * MIXED + (end - b) * AWAY;
    }

    /// @notice What the taker receives, in value units, for moving `x` in — exact-in.
    function outValue(
        uint256 vIn,
        uint256 vOut,
        uint256 wIn,
        uint256 wOut,
        uint256 total,
        uint256 x
    )
        internal
        pure
        returns (uint256)
    {
        return x - Math.ceilDiv(spreadNumerator(vIn, vOut, wIn, wOut, total, x), ONE * ONE);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
