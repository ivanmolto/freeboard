// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title BasketDistance — weighted L1 distance from the basket's composition to its target
/// @notice How far the basket is from where the curve says it should be. The composition is
///         the basket's VALUE-weighted shares — each leg's value over the total — and the
///         distance is the L1 norm between that share vector and the target weight vector
///         `Curve.weightsAt` returns:
///
///           distance = sum over legs of | value_l / total  -  target_l |
///
///         The pricing core (T14) computes this before and after a proposed fill and prices by
///         the delta: a fill that shrinks it is toward target and cheap, a fill that grows it is
///         away from target and expensive. The per-fill cap (T15) is on the VALUE a fill moves,
///         which bounds how much of this one fill may close: a moving leg's share changes by
///         the value moved over the total, so a fill moving `c` of the basket changes the
///         distance by at most `2c`.
///
/// @dev THE VALUE UNIT. `values[l]` is leg `l`'s balance expressed in one unit common to every
///      leg. Which unit is the caller's choice and the library never learns it: only the
///      proportions matter, and the distance is exactly invariant under scaling every leg by
///      the same factor (the test pins this to the wei). The extruction will use the Aave
///      oracle's base currency, so composition and health factor agree on prices.
///
/// @dev FIXED POINT. Targets are WAD, summing to exactly `ONE`, as `Curve` guarantees. The
///      distance is WAD too, in `[0, MAX_DISTANCE]` = `[0, 2e18]`: two distributions can differ
///      by at most 2, and reach it only when all the value sits in a leg the target weights at
///      zero. No row of the Freeboard curve has a zero weight, so its basket stays strictly
///      below 2 (at most `2 * (ONE - min target)` = 1.6 against the top row).
///
/// @dev ONE DIVISION, AT THE END. Per-leg shares would each floor a wei, and a basket exactly
///      at target could read as `legs` wei away. Instead the sum is formed over the total:
///
///           distance = ( sum over legs of | value_l * ONE  -  target_l * total | ) / total
///
///      which is the same number with the division moved outside, so a basket whose values are
///      exactly proportional to the target is exactly zero, and every other basket is floored
///      once, less than one wei below its exact distance. Both products are bounded by
///      `total * ONE` (a value is at most the total; a target is at most `ONE`), and the sum by
///      `2 * total * ONE`, so with `total <= MAX_TOTAL_VALUE = uint256.max / (2 * ONE)` nothing
///      overflows. A larger total is refused by name rather than left to a panic; at 1e8-scaled
///      USD that cap is a basket worth 1e51 dollars.
///
/// @dev THE DEGENERATE CASES, BY NAME.
///        - Zero balance in one leg: a leg that is in the strategy and sold out. Its share is
///          zero and it contributes its whole target weight to the distance. Nothing divides by
///          a leg, so nothing special happens. (A leg MISSING from the strategy is a different
///          thing: Aqua's `rawBalances` reverts for it upstream — CLAUDE.md, "a missing leg is
///          a revert, not zero" — and this library never sees it.)
///        - Already at target: exactly zero, see above.
///        - Single-token basket: one leg, whose only valid target is `ONE`; any positive value
///          is the whole basket, so the distance is zero. There is nothing to rebalance.
///        - Zero total value: the composition is 0 / 0 and the distance is undefined. That is a
///          revert, `BasketHasNoValue`, not a number: the extruction must refuse to trade
///          rather than price against a made-up composition, and refusing costs the borrower
///          nothing (the same stance as the unreadable-HF fail-safe).
library BasketDistance {
    /// @dev The weight scale, shared with `Curve.ONE`.
    uint256 internal constant ONE = 1e18;

    /// @dev The L1 maximum between two distributions.
    uint256 internal constant MAX_DISTANCE = 2 * ONE;

    /// @dev The largest total the scaled sum can hold without overflow; see the contract notes.
    uint256 internal constant MAX_TOTAL_VALUE = type(uint256).max / MAX_DISTANCE;

    error BasketNeedsAtLeastOneLeg();
    error BasketLegCountMismatch(uint256 values, uint256 targets);
    error BasketTargetsDoNotSumToOne(uint256 sum);
    error BasketHasNoValue();
    error BasketTotalValueTooLarge(uint256 total);

    /// @notice The L1 distance, WAD, from the composition `values` describes to `targets`.
    /// @param values Each leg's value in one common unit; see the contract notes.
    /// @param targets Each leg's target weight, WAD, summing to exactly `ONE`.
    /// @dev `scaledDistance` and its one division.
    function distance(uint256[] memory values, uint256[] memory targets) internal pure returns (uint256) {
        (uint256 scaled, uint256 total) = scaledDistance(values, targets);
        return scaled / total;
    }

    /// @notice The distance BEFORE its one division: the numerator `scaled` and the
    ///         denominator `total`, with `distance == scaled / total`.
    /// @dev For the pricing core (T14). A fill valued at the oracle moves value from one leg to
    ///      another and leaves `total` unchanged, so the distance before and after the fill
    ///      share a denominator, and their DIFFERENCE is exact in the numerators alone:
    ///      `scaledAfter - scaledBefore` is `total * (distanceAfter - distanceBefore)` with no
    ///      floor anywhere. `distance` would floor each side once and hand the caller a
    ///      difference off by up to a wei of WAD, which is a wei of `total` in value; the
    ///      numerators hand it the exact quantity, and the exact-out inverse is exact only
    ///      because of it.
    ///
    ///      Checks, in order: at least one leg; equal leg counts; targets summing to `ONE`;
    ///      a non-zero total; the total within `MAX_TOTAL_VALUE`. Then one pass over the legs.
    function scaledDistance(
        uint256[] memory values,
        uint256[] memory targets
    )
        internal
        pure
        returns (uint256 scaled, uint256 total)
    {
        uint256 n = values.length;
        require(n > 0, BasketNeedsAtLeastOneLeg());
        require(targets.length == n, BasketLegCountMismatch(n, targets.length));

        uint256 targetSum;
        for (uint256 l = 0; l < n; ++l) {
            targetSum += targets[l];
            total += values[l];
        }
        require(targetSum == ONE, BasketTargetsDoNotSumToOne(targetSum));
        require(total > 0, BasketHasNoValue());
        require(total <= MAX_TOTAL_VALUE, BasketTotalValueTooLarge(total));

        for (uint256 l = 0; l < n; ++l) {
            uint256 held = values[l] * ONE;
            uint256 wanted = targets[l] * total;
            scaled += held > wanted ? held - wanted : wanted - held;
        }
    }
}
