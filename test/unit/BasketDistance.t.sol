// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { BasketDistance } from "../../src/libs/BasketDistance.sol";
import { Curve } from "../../src/libs/Curve.sol";

/// @dev `Curve.weightsAt` reads `bytes calldata`; the one test that feeds curve targets into
///      the distance crosses this boundary to get them.
contract CurveHarness {
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }
}

/// @title BasketDistanceTest — T12
/// @notice Weighted L1 distance from the basket's current composition to its target: the
///         normal case, every degenerate case by name — zero balance in one leg, already at
///         target, single-token basket, zero total value — and the properties pricing leans on.
contract BasketDistanceTest is Test {
    uint256 internal constant ONE = BasketDistance.ONE;

    /// @dev The Freeboard basket order: WETH, WBTC, USDC (the debt asset, last).
    uint256 internal constant ETH = 0;
    uint256 internal constant BTC = 1;
    uint256 internal constant USD = 2;

    /// @dev The top row of the Freeboard curve, HF 2.00: 50 / 30 / 20.
    uint256[] internal target;

    function setUp() public {
        target = _vec(0.5e18, 0.3e18, 0.2e18);
    }

    // -----------------------------------------------------------------------------------
    // 1. The normal case
    // -----------------------------------------------------------------------------------

    /// @dev A basket worth 100 in some common unit, held 60 / 20 / 20 against a 50 / 30 / 20
    ///      target: WETH is 10 points over, WBTC 10 under, USDC on target. L1 = 0.10 + 0.10 + 0.
    function test_Normal_60_20_20_Against50_30_20_Is0_20() public view {
        uint256 d = BasketDistance.distance(_vec(60, 20, 20), target);
        assertEq(d, 0.2e18, "L1 distance");
    }

    /// @dev The unit does not matter, only the proportions: the same basket in 1e8-scaled USD
    ///      (Aave's base-currency unit) and in wei-scale values gives the same distance, to the wei.
    function test_Normal_IsIndependentOfTheValueUnit() public view {
        uint256 d1 = BasketDistance.distance(_vec(60, 20, 20), target);
        uint256 d8 = BasketDistance.distance(_vec(60e8, 20e8, 20e8), target);
        uint256 d18 = BasketDistance.distance(_vec(60e18, 20e18, 20e18), target);
        assertEq(d8, d1, "1e8 unit");
        assertEq(d18, d1, "1e18 unit");
    }

    /// @dev The Freeboard story in one number. A basket sitting exactly at the HF 2.00 target
    ///      does not move when HF falls to 1.60, but its target does — to 40 / 24 / 36 — so the
    ///      unchanged basket is now 0.10 + 0.06 + 0.16 = 0.32 away, and a taker is paid to close it.
    function test_Normal_AnUnchangedBasketDriftsFromTargetAsHealthFactorFalls() public {
        CurveHarness h = new CurveHarness();
        bytes memory curve = _freeboardCurve();

        uint256[] memory held = _vec(50, 30, 20);
        assertEq(BasketDistance.distance(held, h.weightsAt(curve, 2.0e18)), 0, "at HF 2.00 the basket is on target");
        assertEq(BasketDistance.distance(held, h.weightsAt(curve, 1.6e18)), 0.32e18, "at HF 1.60 it is 0.32 away");
        assertEq(BasketDistance.distance(held, h.weightsAt(curve, 1.15e18)), 1.0e18, "at HF 1.15 it is 1.00 away");
    }

    /// @dev Off the wei grid, against thirds that cannot be exact in WAD (…333 / …333 / …334).
    ///      Three equal legs: the exact distance is 4/3 wei, floored once to 1. A 2 / 2 / 3
    ///      basket: the exact distance is 1333333333333333324 / 7 = 190476190476190474.857…
    ///      wei, floored once to …474 — whereas flooring each leg's share first and summing the
    ///      differences would give …475, ABOVE the true distance. One division at the end is
    ///      never above exact and less than a wei below it.
    function test_Rounding_FloorsOnceAtTheEnd() public pure {
        uint256[] memory thirds = _vec(333_333_333_333_333_333, 333_333_333_333_333_333, 333_333_333_333_333_334);
        assertEq(BasketDistance.distance(_vec(1, 1, 1), thirds), 1, "4/3 wei floors to 1");
        assertEq(BasketDistance.distance(_vec(2, 2, 3), thirds), 190_476_190_476_190_474, "floor of the exact distance");
        // Nine times the row itself (…333 * 9 = 3e18 - 3, …334 * 9 = 3e18 + 6, total 9e18):
        // exactly proportional, exactly zero.
        assertEq(
            BasketDistance.distance(_vec(3e18 - 3, 3e18 - 3, 3e18 + 6), thirds), 0, "an exact multiple is on target"
        );
    }

    // -----------------------------------------------------------------------------------
    // 2. Degenerate cases, by name
    // -----------------------------------------------------------------------------------

    /// @dev ZERO BALANCE IN ONE LEG. The leg exists in the strategy (a missing leg is Aqua's
    ///      `rawBalances` revert, upstream of this) and has been sold out entirely. Its share is
    ///      zero, the other legs carry everything: 0 / 0.6 / 0.4 against 0.5 / 0.3 / 0.2 is
    ///      0.5 + 0.3 + 0.2 = 1.00. Finite, no special case, no division by that leg.
    function test_ZeroBalanceInOneLeg_CountsTheWholeTargetOfThatLeg() public view {
        assertEq(BasketDistance.distance(_vec(0, 30, 20), target), 1.0e18, "WETH sold out");
        assertEq(
            BasketDistance.distance(_vec(50, 0, 20), target), 0.6e18, "WBTC sold out: 0.3 + (5/7 - 0.5) + (2/7 - 0.2)"
        );
        assertEq(
            BasketDistance.distance(_vec(50, 30, 0), target), 0.4e18, "USDC sold out: 0.2 + (5/8 - 0.5) + (3/8 - 0.3)"
        );
    }

    /// @dev Two legs at zero: everything is in one leg, and the distance is the full L1 to a
    ///      target that wants half of it elsewhere.
    function test_ZeroBalanceInTwoLegs_IsTheDistanceFromAOneLegBasket() public view {
        // 1 / 0 / 0 against 0.5 / 0.3 / 0.2: 0.5 + 0.3 + 0.2.
        assertEq(BasketDistance.distance(_vec(100, 0, 0), target), 1.0e18, "all WETH");
        // 0 / 0 / 1 against 0.5 / 0.3 / 0.2: 0.5 + 0.3 + 0.8.
        assertEq(BasketDistance.distance(_vec(0, 0, 100), target), 1.6e18, "all USDC");
    }

    /// @dev ALREADY AT TARGET. Exactly proportional values give exactly zero, at any scale and
    ///      at every breakpoint of the Freeboard curve.
    function test_AlreadyAtTarget_IsExactlyZero() public view {
        assertEq(BasketDistance.distance(_vec(50, 30, 20), target), 0, "50 / 30 / 20");
        assertEq(BasketDistance.distance(_vec(5e8, 3e8, 2e8), target), 0, "in 1e8 USD");
        assertEq(
            BasketDistance.distance(_vec(0.4e18, 0.24e18, 0.36e18), _vec(0.4e18, 0.24e18, 0.36e18)), 0, "HF 1.60 row"
        );
        assertEq(BasketDistance.distance(_vec(20, 10, 70), _vec(0.2e18, 0.1e18, 0.7e18)), 0, "HF 1.15 row");
    }

    /// @dev SINGLE-TOKEN BASKET. One leg, so its only valid target is `ONE`, and any positive
    ///      value is the whole basket: the distance is zero. A single-token basket has nothing
    ///      to rebalance.
    function test_SingleTokenBasket_IsAlwaysAtTarget() public pure {
        uint256[] memory whole = new uint256[](1);
        whole[0] = ONE;

        uint256[] memory v = new uint256[](1);
        v[0] = 1;
        assertEq(BasketDistance.distance(v, whole), 0, "value 1");
        v[0] = 123_456_789e8;
        assertEq(BasketDistance.distance(v, whole), 0, "value 123456789e8");
        v[0] = BasketDistance.MAX_TOTAL_VALUE;
        assertEq(BasketDistance.distance(v, whole), 0, "value at the cap");
    }

    /// @dev A single leg whose target is not `ONE` is not a valid target, whatever the value.
    function test_SingleTokenBasket_RejectsATargetThatIsNotOne() public {
        uint256[] memory v = new uint256[](1);
        v[0] = 100;
        uint256[] memory half = new uint256[](1);
        half[0] = 0.5e18;

        vm.expectRevert(abi.encodeWithSelector(BasketDistance.BasketTargetsDoNotSumToOne.selector, 0.5e18));
        this.distanceExternal(v, half);
    }

    /// @dev ZERO TOTAL VALUE. Every leg at zero: the composition is 0 / 0 and the distance is
    ///      undefined. That is a revert with a named error, not a number — a basket with
    ///      nothing in it cannot be priced toward or away from anything, and the extruction
    ///      refuses to trade rather than trade on a made-up value.
    function test_RevertWhen_TotalValueIsZero() public {
        vm.expectRevert(BasketDistance.BasketHasNoValue.selector);
        this.distanceExternal(_vec(0, 0, 0), target);

        // A single-token basket at zero is the same case.
        uint256[] memory v = new uint256[](1);
        uint256[] memory whole = new uint256[](1);
        whole[0] = ONE;
        vm.expectRevert(BasketDistance.BasketHasNoValue.selector);
        this.distanceExternal(v, whole);
    }

    // -----------------------------------------------------------------------------------
    // 3. Shape: what the library refuses
    // -----------------------------------------------------------------------------------

    function test_RevertWhen_LegCountsDiffer() public {
        uint256[] memory two = new uint256[](2);
        two[0] = 50;
        two[1] = 50;

        vm.expectRevert(abi.encodeWithSelector(BasketDistance.BasketLegCountMismatch.selector, 2, 3));
        this.distanceExternal(two, target);
    }

    function test_RevertWhen_BasketHasNoLegs() public {
        uint256[] memory none = new uint256[](0);
        vm.expectRevert(BasketDistance.BasketNeedsAtLeastOneLeg.selector);
        this.distanceExternal(none, none);
    }

    function test_RevertWhen_TargetsDoNotSumToOne() public {
        vm.expectRevert(abi.encodeWithSelector(BasketDistance.BasketTargetsDoNotSumToOne.selector, ONE + 1));
        this.distanceExternal(_vec(50, 30, 20), _vec(0.5e18, 0.3e18, 0.2e18 + 1));

        vm.expectRevert(abi.encodeWithSelector(BasketDistance.BasketTargetsDoNotSumToOne.selector, ONE - 1));
        this.distanceExternal(_vec(50, 30, 20), _vec(0.5e18, 0.3e18, 0.2e18 - 1));
    }

    /// @dev The overflow guard: one wei over the cap reverts by name, the cap itself computes.
    function test_RevertWhen_TotalValueExceedsTheCap() public {
        uint256 cap = BasketDistance.MAX_TOTAL_VALUE;
        assertEq(cap, type(uint256).max / (2 * ONE), "the cap the natspec quotes");

        vm.expectRevert(abi.encodeWithSelector(BasketDistance.BasketTotalValueTooLarge.selector, cap + 1));
        this.distanceExternal(_vec(cap - 1, 1, 1), target);

        // At the cap, the worst-case basket (all of it in the leg with the smallest target)
        // computes and lands on the exact answer: 0.5 + 0.3 + (1 - 0.2) = 1.6.
        assertEq(this.distanceExternal(_vec(0, 0, cap), target), 1.6e18, "at the cap");
    }

    // -----------------------------------------------------------------------------------
    // 4. Range: the maximum is two, and it needs a zero-weight target leg
    // -----------------------------------------------------------------------------------

    /// @dev Everything in a leg the target wants none of: 1 + 1 = 2, the L1 maximum between
    ///      two distributions. No row of the Freeboard curve has a zero weight, so this is the
    ///      library's bound, not a state the Freeboard basket can reach.
    function test_MaxDistance_IsTwo_WhenAllValueIsInAZeroWeightLeg() public pure {
        assertEq(BasketDistance.MAX_DISTANCE, 2 * ONE, "the quoted maximum");
        uint256[] memory allOut = new uint256[](2);
        allOut[0] = 0;
        allOut[1] = ONE;
        uint256[] memory v = new uint256[](2);
        v[0] = 100;
        assertEq(BasketDistance.distance(v, allOut), 2 * ONE, "everything in the leg with zero target");
    }

    // -----------------------------------------------------------------------------------
    // 5. Fuzz: bounds, exactness at target, unit independence
    // -----------------------------------------------------------------------------------

    /// @dev Any basket with any value in it, against the Freeboard top row: the distance is in
    ///      [0, 2 * ONE], and because every target weight is positive it is strictly below 2.
    function testFuzz_Distance_IsBoundedByTwo(uint256 a, uint256 b, uint256 c) public view {
        uint256 cap = BasketDistance.MAX_TOTAL_VALUE / 3;
        uint256[] memory v = _vec(a % (cap + 1), b % (cap + 1), c % (cap + 1));
        vm.assume(v[ETH] + v[BTC] + v[USD] > 0);

        uint256 d = BasketDistance.distance(v, target);
        assertLe(d, BasketDistance.MAX_DISTANCE, "above the L1 maximum");
        assertLt(d, 2 * ONE, "reached 2 against an all-positive target");
    }

    /// @dev Exactly proportional to the target at any positive scale is exactly zero: values
    ///      `k * w_l` have shares `w_l` with no rounding anywhere.
    function testFuzz_Distance_IsZero_ForAnyExactMultipleOfTheTarget(uint256 k) public view {
        k = 1 + (k % (BasketDistance.MAX_TOTAL_VALUE / ONE));
        uint256[] memory v = _vec(k * target[ETH], k * target[BTC], k * target[USD]);
        assertEq(BasketDistance.distance(v, target), 0, "an exact multiple of the target is not at zero");
    }

    /// @dev Scaling every leg by the same factor changes nothing, to the wei: the numerator
    ///      and the denominator scale together and the one floor sees the same quotient.
    function testFuzz_Distance_IsInvariantUnderScalingAllLegs(uint64 a, uint64 b, uint64 c, uint32 k) public view {
        vm.assume(uint256(a) + b + c > 0);
        uint256 scale = 1 + uint256(k);

        uint256 unscaled = BasketDistance.distance(_vec(a, b, c), target);
        uint256 scaled = BasketDistance.distance(_vec(scale * a, scale * b, scale * c), target);
        assertEq(scaled, unscaled, "scaling the basket moved the distance");
    }

    /// @dev Against ANY valid target of 1-5 legs, and any values: bounded by two, and the
    ///      distance from a target to itself (values equal to the weights) is zero.
    function testFuzz_Distance_OnAnyValidTarget(uint8 nSeed, bytes32 seed) public pure {
        uint256 n = 1 + (uint256(nSeed) % 5);
        uint256[] memory t = new uint256[](n);
        uint256[] memory v = new uint256[](n);
        uint256 left = ONE;
        uint256 total;
        for (uint256 l = 0; l + 1 < n; ++l) {
            t[l] = uint256(keccak256(abi.encode(seed, "t", l))) % (left + 1);
            left -= t[l];
        }
        t[n - 1] = left;
        for (uint256 l = 0; l < n; ++l) {
            v[l] = uint256(keccak256(abi.encode(seed, "v", l))) % 1e30;
            total += v[l];
        }
        vm.assume(total > 0);

        assertLe(BasketDistance.distance(v, t), BasketDistance.MAX_DISTANCE, "above the L1 maximum");
        assertEq(BasketDistance.distance(t, t), 0, "a target is not at zero distance from itself");
    }

    // -----------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------

    /// @dev An external hop so `vm.expectRevert` has a call frame to catch.
    function distanceExternal(uint256[] memory values, uint256[] memory targets) external pure returns (uint256) {
        return BasketDistance.distance(values, targets);
    }

    function _vec(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    /// @dev The table from CLAUDE.md, top row first — the same bytes `CurveTest` builds.
    function _freeboardCurve() internal pure returns (bytes memory) {
        uint256[] memory hf = new uint256[](4);
        hf[0] = 2.0e18;
        hf[1] = 1.6e18;
        hf[2] = 1.3e18;
        hf[3] = 1.15e18;

        uint256[][] memory w = new uint256[][](4);
        w[0] = _vec(0.5e18, 0.3e18, 0.2e18);
        w[1] = _vec(0.4e18, 0.24e18, 0.36e18);
        w[2] = _vec(0.3e18, 0.16e18, 0.54e18);
        w[3] = _vec(0.2e18, 0.1e18, 0.7e18);

        return Curve.encode(hf, w);
    }
}
