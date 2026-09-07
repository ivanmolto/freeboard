// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { IPoolAddressesProvider } from "../../src/interfaces/IAaveV3.sol";
import { IAaveV3Pool } from "../../src/interfaces/IAaveV3Pool.sol";

import { IAaveProtocolDataProvider, IAToken, IAaveV3PoolFixture } from "../utils/AaveFixtures.sol";
import { IAaveOracle, OracleWarp, WarpedPriceSource } from "../utils/OracleWarp.sol";

/// @notice The shape `FreeboardExtruction._healthFactor` has (T13): a `view` function on a
///         foreign contract that low-level staticcalls the Pool, so a failure surfaces as
///         `ok == false` rather than bubbling up. The difference is what each does with
///         `false`: this spike reports it, the extruction reverts on it by name.
contract StaticHfReader {
    function readHealthFactor(address pool, address user) external view returns (bool ok, uint256 healthFactor) {
        bytes memory ret;
        (ok, ret) = pool.staticcall(abi.encodeWithSelector(IAaveV3Pool.getUserAccountData.selector, user));
        if (!ok || ret.length != 6 * 32) {
            return (false, 0);
        }
        (,,,,, healthFactor) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256));
    }

    function readHealthFactorWithGas(
        address pool,
        address user,
        uint256 gasCeiling
    )
        external
        view
        returns (bool ok, uint256 healthFactor)
    {
        bytes memory ret;
        (ok, ret) =
            pool.staticcall{ gas: gasCeiling }(abi.encodeWithSelector(IAaveV3Pool.getUserAccountData.selector, user));
        if (!ok || ret.length != 6 * 32) {
            return (false, 0);
        }
        (,,,,, healthFactor) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256));
    }
}

/// @title AaveHealthFactorForkTest — T8
/// @notice The health-factor read, spiked against real Aave v3 on a mainnet fork. HF is on the
///         pricing path, so its return shape, gas, revert set, no-debt sentinel and staticcall
///         safety are properties of Freeboard's pricing.
/// @dev Nothing here mocks Aave: positions are real `supply`/`borrow` calls, price moves go
///      through `AaveOracle.setAssetSources` (see `test/utils/OracleWarp.sol`). Gas methodology
///      is in `docs/NOTES-gas.md`.
/// @dev T13's own test — the read as `FreeboardExtruction` performs it, through the deployed
///      router — is `test/fork/HealthFactor.t.sol`. This file is the protocol spike underneath it.
contract AaveHealthFactorForkTest is Test {
    /// @dev The fixture type: `IAaveV3Pool` plus the writes that build a position. The pricing
    ///      path holds only the one-function `IAaveV3Pool`.
    IAaveV3PoolFixture internal constant POOL = IAaveV3PoolFixture(Addresses.AAVE_V3_POOL);
    IPoolAddressesProvider internal constant PROVIDER =
        IPoolAddressesProvider(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER);
    IAaveOracle internal constant ORACLE = IAaveOracle(Addresses.AAVE_V3_ORACLE);

    /// @dev Aave v3.5 has one rate mode left: 2 = variable. 1 (stable) is rejected.
    uint256 internal constant VARIABLE_RATE = 2;

    /// @dev ~$249.8k of ETH and ~$242.7k of BTC at FORK_BLOCK, far below both supply caps.
    uint256 internal constant WETH_COLLATERAL = 100e18;
    uint256 internal constant WBTC_COLLATERAL = 3e8;

    /// @dev 1e-6 HF. The real error is flooring on the 1e-8 USD price grid, measured at 1.5e-11
    ///      HF on the fixture with the tolerance set to 1 wei; this is ~67x that.
    uint256 internal constant HF_TOLERANCE = 1e12;

    /// @dev Measured at FORK_BLOCK; see `docs/NOTES-gas.md` for how "cold" is obtained.
    uint256 internal constant GAS_COLD_3RESERVE = 180_707;
    uint256 internal constant GAS_WARM_3RESERVE = 35_207;
    uint256 internal constant GAS_COLD_2RESERVE = 117_479;
    uint256 internal constant GAS_WARM_2RESERVE = 22_979;
    uint256 internal constant GAS_COLD_EMPTY = 20_151;
    uint256 internal constant GAS_WARM_EMPTY = 4651;
    uint256 internal constant GAS_COLD_FLOOR = 131_452;

    address internal borrower3; // WETH + WBTC collateral, USDC debt  -> 3 reserves
    address internal borrower2; // WETH collateral, USDC debt         -> 2 reserves
    address internal saver; //     WETH collateral, no debt
    address internal stranger; //  never touched Aave                 -> empty user config

    StaticHfReader internal reader;
    IAaveProtocolDataProvider internal dataProvider;

    address internal aWeth;
    address internal aWbtc;
    address internal vUsdc;

    // -----------------------------------------------------------------------------------
    // Fixture
    // -----------------------------------------------------------------------------------

    function setUp() public {
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        require(forkBlock >= Addresses.MIN_FORK_BLOCK, "FORK_BLOCK is before the router exists");
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);

        reader = new StaticHfReader();
        dataProvider = IAaveProtocolDataProvider(PROVIDER.getPoolDataProvider());

        (aWeth,,) = dataProvider.getReserveTokensAddresses(Addresses.WETH);
        (aWbtc,,) = dataProvider.getReserveTokensAddresses(Addresses.WBTC);
        (,, vUsdc) = dataProvider.getReserveTokensAddresses(Addresses.USDC);

        borrower3 = makeAddr("freeboard-borrower-3reserve");
        borrower2 = makeAddr("freeboard-borrower-2reserve");
        saver = makeAddr("freeboard-saver-nodebt");
        stranger = makeAddr("freeboard-stranger-noposition");

        // The Freeboard basket shape, at the top of the curve.
        _supply(borrower3, Addresses.WETH, WETH_COLLATERAL);
        _supply(borrower3, Addresses.WBTC, WBTC_COLLATERAL);
        _borrowToHealthFactor(borrower3, 2e18);

        _supply(borrower2, Addresses.WETH, WETH_COLLATERAL);
        _borrowToHealthFactor(borrower2, 2e18);

        _supply(saver, Addresses.WETH, 1e18);
    }

    /// @dev `supply` auto-enables collateral on a user's first deposit into a reserve with LTV > 0.
    function _supply(address who, address asset, uint256 amount) internal {
        deal(asset, who, amount);
        vm.startPrank(who);
        IERC20(asset).approve(Addresses.AAVE_V3_POOL, amount);
        POOL.supply(asset, amount, who, 0);
        vm.stopPrank();
    }

    /// @dev SUM(collateral_base_i * lt_i), 10 decimals, floored per leg the way
    ///      `_getUserBalanceInBaseCurrency` floors it. NOT recoverable from the read as
    ///      `totalCollateralBase * currentLiquidationThreshold`: the returned threshold is
    ///      truncated to whole bps, which misses an HF target by ~1.4e14 wei on this position.
    function _weightedCollateral(address who) internal view returns (uint256) {
        uint256 wethBase = (IERC20(aWeth).balanceOf(who) * ORACLE.getAssetPrice(Addresses.WETH)) / 1e18;
        uint256 wbtcBase = (IERC20(aWbtc).balanceOf(who) * ORACLE.getAssetPrice(Addresses.WBTC)) / 1e8;
        return wethBase * Addresses.LT_WETH_BPS + wbtcBase * Addresses.LT_WBTC_BPS;
    }

    /// @dev Inverts `GenericLogic`: HF = (L * 1e18 / debtBase) / 1e4  =>  debtBase = L * 1e14 / HF.
    function _borrowToHealthFactor(address who, uint256 targetHf) internal {
        (uint256 collateralBase,,,,,) = POOL.getUserAccountData(who);
        require(collateralBase > 0, "fixture: no collateral was registered");

        uint256 debtBase = (_weightedCollateral(who) * 1e14) / targetHf; // 8 decimals
        uint256 amount = (debtBase * 1e6) / ORACLE.getAssetPrice(Addresses.USDC);

        vm.prank(who);
        POOL.borrow(Addresses.USDC, amount, VARIABLE_RATE, 0, who);
    }

    function _hf(address who) internal view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = POOL.getUserAccountData(who);
    }

    // -----------------------------------------------------------------------------------
    // 1. The Pool address, resolved from the provider rather than pasted
    // -----------------------------------------------------------------------------------

    /// @dev Closes the loop provider <-> Pool <-> oracle, then anchors the Pool to the three
    ///      already-pinned tokens via the aTokens' `UNDERLYING_ASSET_ADDRESS()` / `POOL()`.
    function test_AaveAddresses_ResolveFromTheProviderAndRoundTrip() public view {
        assertEq(PROVIDER.getMarketId(), "Aave Ethereum Market", "not the Ethereum market");

        assertEq(PROVIDER.getPool(), Addresses.AAVE_V3_POOL, "provider names a different Pool");
        assertEq(
            POOL.ADDRESSES_PROVIDER(), Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER, "Pool names a different provider"
        );

        assertEq(PROVIDER.getPriceOracle(), Addresses.AAVE_V3_ORACLE, "provider names a different oracle");
        assertEq(
            ORACLE.ADDRESSES_PROVIDER(), Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER, "oracle names a different provider"
        );

        assertEq(PROVIDER.getACLManager(), Addresses.AAVE_V3_ACL_MANAGER, "ACL manager moved");
        assertEq(PROVIDER.getACLAdmin(), Addresses.AAVE_V3_ACL_ADMIN, "ACL admin moved");

        assertGt(Addresses.AAVE_V3_POOL.code.length, 0, "Pool has no code at FORK_BLOCK");

        address[3] memory assets = [Addresses.WETH, Addresses.WBTC, Addresses.USDC];
        address[3] memory aTokens = [aWeth, aWbtc, address(0)];
        (aTokens[2],,) = dataProvider.getReserveTokensAddresses(Addresses.USDC);

        for (uint256 i = 0; i < 3; ++i) {
            assertEq(IAToken(aTokens[i]).UNDERLYING_ASSET_ADDRESS(), assets[i], "aToken underlying mismatch");
            assertEq(IAToken(aTokens[i]).POOL(), Addresses.AAVE_V3_POOL, "aToken belongs to another Pool");
        }
    }

    /// @dev Pinned so a governance change to an LT is a red test, not a quietly different curve.
    function test_Oracle_BaseCurrencyIsUsdAt1e8_AndThresholdsAreThePinnedOnes() public view {
        assertEq(ORACLE.BASE_CURRENCY(), address(0), "BASE_CURRENCY is no longer the USD marker");
        assertEq(ORACLE.BASE_CURRENCY_UNIT(), Addresses.AAVE_BASE_CURRENCY_UNIT, "base currency unit changed");

        (,, uint256 ltWeth,,,,,,,) = dataProvider.getReserveConfigurationData(Addresses.WETH);
        (,, uint256 ltWbtc,,,,,,,) = dataProvider.getReserveConfigurationData(Addresses.WBTC);
        (,, uint256 ltUsdc,,,,,,,) = dataProvider.getReserveConfigurationData(Addresses.USDC);

        assertEq(ltWeth, Addresses.LT_WETH_BPS, "WETH liquidation threshold changed");
        assertEq(ltWbtc, Addresses.LT_WBTC_BPS, "WBTC liquidation threshold changed");
        assertEq(ltUsdc, Addresses.LT_USDC_BPS, "USDC liquidation threshold changed");
    }

    // -----------------------------------------------------------------------------------
    // 2. The return shape and its decimals — checked against a hand computation
    // -----------------------------------------------------------------------------------

    /// @dev Rebuilds every return value from prices, balances and LTs. If `healthFactor` were
    ///      bps or `totalCollateralBase` were 1e18, this would miss by orders of magnitude.
    function test_ReturnShape_DecimalsAreBase1e8ForValues_Bps_AndWadForHealthFactor() public view {
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) = POOL.getUserAccountData(borrower3);

        assertGt(ltv, 0, "ltv is zero");
        assertLe(currentLiquidationThreshold, 10_000, "LT is not in bps");
        assertGe(currentLiquidationThreshold, ltv, "LT below LTV is impossible");

        uint256 wethBase = (IERC20(aWeth).balanceOf(borrower3) * ORACLE.getAssetPrice(Addresses.WETH)) / 1e18;
        uint256 wbtcBase = (IERC20(aWbtc).balanceOf(borrower3) * ORACLE.getAssetPrice(Addresses.WBTC)) / 1e8;
        assertApproxEqAbs(totalCollateralBase, wethBase + wbtcBase, 2, "collateral is not USD at 1e8");

        uint256 usdcBase = (IERC20(vUsdc).balanceOf(borrower3) * ORACLE.getAssetPrice(Addresses.USDC)) / 1e6;
        assertApproxEqAbs(totalDebtBase, usdcBase, 2, "debt is not USD at 1e8");

        assertGt(totalCollateralBase, 400_000e8, "collateral reads too small to be USD at 1e8");
        assertLt(totalCollateralBase, 600_000e8, "collateral reads too large to be USD at 1e8");

        assertApproxEqAbs(
            availableBorrowsBase,
            (totalCollateralBase * ltv) / 10_000 - totalDebtBase,
            2,
            "availableBorrowsBase is not the LTV headroom"
        );

        // healthFactor = (SUM(collateral_i * lt_i) * 1e18 / debt) / 1e4
        uint256 expected =
            (((wethBase * Addresses.LT_WETH_BPS + wbtcBase * Addresses.LT_WBTC_BPS) * 1e18) / totalDebtBase) / 10_000;
        assertApproxEqAbs(healthFactor, expected, HF_TOLERANCE, "health factor is not the WAD GenericLogic computes");
        assertApproxEqAbs(healthFactor, 2e18, HF_TOLERANCE, "fixture did not land on HF 2.00");
    }

    // -----------------------------------------------------------------------------------
    // 3. THE DoD: drive HF from ~2.00 to ~1.10 by moving the oracle
    // -----------------------------------------------------------------------------------

    /// @dev Cuts both collateral prices, leaves USDC alone. No time passes, no debt or
    ///      collateral changes. HF is linear in a uniform collateral price scale, so each step's
    ///      factor is `target / current` and the landing point is exact to HF_TOLERANCE.
    function test_HealthFactor_WalksFrom2_00To1_10OnOracleMovesAlone() public {
        address[] memory collateral = new address[](2);
        collateral[0] = Addresses.WETH;
        collateral[1] = Addresses.WBTC;

        uint256 startPriceWeth = OracleWarp.priceOf(Addresses.WETH);
        uint256 startPriceWbtc = OracleWarp.priceOf(Addresses.WBTC);
        uint256 startUsdc = OracleWarp.priceOf(Addresses.USDC);

        uint256 hf = _hf(borrower3);
        assertApproxEqAbs(hf, 2e18, HF_TOLERANCE, "did not start at HF 2.00");
        emit log_named_decimal_uint("HF start", hf, 18);

        // The curve breakpoints from CLAUDE.md, plus the 1.10 the DoD asks for.
        uint256[5] memory targets = [uint256(1.8e18), 1.6e18, 1.3e18, 1.15e18, 1.1e18];

        for (uint256 i = 0; i < targets.length; ++i) {
            OracleWarp.scalePriceWad(collateral, (targets[i] * 1e18) / hf);

            uint256 next = _hf(borrower3);
            assertApproxEqAbs(next, targets[i], HF_TOLERANCE, "oracle move did not land on the target HF");
            assertLt(next, hf, "health factor did not fall");
            hf = next;

            emit log_named_decimal_uint("HF after collateral cut", hf, 18);
            emit log_named_decimal_uint("  WETH price (USD)", OracleWarp.priceOf(Addresses.WETH), 8);
            emit log_named_decimal_uint("  WBTC price (USD)", OracleWarp.priceOf(Addresses.WBTC), 8);
        }

        assertApproxEqAbs(hf, 1.1e18, HF_TOLERANCE, "did not land on HF 1.10");
        assertGt(hf, 1e18, "walked past the liquidation threshold");
        assertEq(OracleWarp.priceOf(Addresses.USDC), startUsdc, "the debt asset's price moved");

        // Both legs took the same cumulative cut of 1.10/2.00. Approximate: each leg floors onto
        // the 1e-8 USD grid independently at every step, drifting ~1.2e-11 apart by the end.
        uint256 wethRatio = (OracleWarp.priceOf(Addresses.WETH) * 1e18) / startPriceWeth;
        uint256 wbtcRatio = (OracleWarp.priceOf(Addresses.WBTC) * 1e18) / startPriceWbtc;
        assertApproxEqAbs(wethRatio, wbtcRatio, 1e10, "collateral legs were not scaled uniformly");
        assertApproxEqAbs(wethRatio, 0.55e18, 1e10, "the cumulative cut is not 1.10 / 2.00");
    }

    /// @dev The public-curve argument (CLAUDE.md) needs a continuous input. 40 one-percent cuts,
    ///      each of which must move HF down by 0.95–1.05% of itself: no cliff, no plateau.
    function test_HealthFactor_IsContinuousAndMonotoneInCollateralPrice() public {
        address[] memory collateral = new address[](2);
        collateral[0] = Addresses.WETH;
        collateral[1] = Addresses.WBTC;

        uint256 previous = _hf(borrower3);
        for (uint256 i = 0; i < 40; ++i) {
            OracleWarp.scalePriceBps(collateral, 9900);
            uint256 next = _hf(borrower3);

            assertLt(next, previous, "a 1% collateral cut did not lower HF");
            assertLe(previous - next, (previous * 105) / 10_000, "HF jumped: the input is not continuous");
            assertGe(previous - next, (previous * 95) / 10_000, "HF stalled: the input is not continuous");
            previous = next;
        }
        assertLt(previous, 1.4e18, "40 cuts of 1% should land near HF 1.34");
        assertGt(previous, 1.3e18, "40 cuts of 1% should land near HF 1.34");
    }

    // -----------------------------------------------------------------------------------
    // 4. No debt
    // -----------------------------------------------------------------------------------

    /// @dev Two code paths. `stranger` has an empty user config: `calculateUserAccountData`
    ///      returns `(0, 0, 0, 0, type(uint256).max, false)` from its first line, before any
    ///      oracle call. `saver` has collateral and no debt: the loop runs and the sentinel
    ///      comes from the `totalDebtInBaseCurrency == 0` ternary. `curve(HF)` must accept
    ///      `type(uint256).max` without overflow.
    function test_NoDebt_ReturnsMaxUint256_ByBothRoutes() public view {
        (uint256 c0, uint256 d0,,,, uint256 hfEmpty) = POOL.getUserAccountData(stranger);
        assertEq(c0, 0, "stranger has collateral");
        assertEq(d0, 0, "stranger has debt");
        assertEq(hfEmpty, type(uint256).max, "empty user config did not return the max sentinel");

        (uint256 c1, uint256 d1,, uint256 lt1,, uint256 hfSaver) = POOL.getUserAccountData(saver);
        assertGt(c1, 0, "saver has no collateral");
        assertEq(d1, 0, "saver has debt");
        assertEq(lt1, Addresses.LT_WETH_BPS, "saver's only collateral is WETH");
        assertEq(hfSaver, type(uint256).max, "zero-debt position did not return the max sentinel");
    }

    /// @dev The empty-config early return cannot be made to revert by a broken feed — the common
    ///      case for a Freeboard basket with no leverage.
    function test_NoDebt_EmptyConfigStillReadsWhenTheOracleIsBroken() public {
        OracleWarp.breakPrice(Addresses.WETH);

        vm.expectRevert();
        POOL.getUserAccountData(borrower3);
        vm.expectRevert();
        POOL.getUserAccountData(saver);

        (,,,,, uint256 hf) = POOL.getUserAccountData(stranger);
        assertEq(hf, type(uint256).max, "empty config should not touch the oracle");
    }

    // -----------------------------------------------------------------------------------
    // 5. Staticcall safety
    // -----------------------------------------------------------------------------------

    /// @dev Three routes of increasing strictness, the last being the nesting the router
    ///      produces on `quote()`: a low-level staticcall into a `view` function that itself
    ///      staticcalls the Pool.
    function test_StaticCall_ReadsIdenticallyAtEveryDepth() public view {
        uint256 direct = _hf(borrower3);

        (bool ok, bytes memory ret) = Addresses.AAVE_V3_POOL
        .staticcall(abi.encodeWithSelector(IAaveV3Pool.getUserAccountData.selector, borrower3));
        assertTrue(ok, "direct staticcall to the Pool failed");
        (,,,,, uint256 lowLevel) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256));
        assertEq(lowLevel, direct, "low-level staticcall disagrees");

        (bool okTyped, uint256 nested) = reader.readHealthFactor(Addresses.AAVE_V3_POOL, borrower3);
        assertTrue(okTyped, "staticcall from inside a view function failed");
        assertEq(nested, direct, "nested staticcall disagrees");

        (bool okOuter, bytes memory retOuter) = address(reader)
            .staticcall(
                abi.encodeWithSelector(StaticHfReader.readHealthFactor.selector, Addresses.AAVE_V3_POOL, borrower3)
            );
        assertTrue(okOuter, "staticcall into the view reader failed");
        (bool okInner, uint256 doubleNested) = abi.decode(retOuter, (bool, uint256));
        assertTrue(okInner, "inner staticcall failed under an enforced static context");
        assertEq(doubleNested, direct, "double-nested staticcall disagrees");
    }

    /// @dev The quote/swap consistency property: STATICCALL (`quote()`) and CALL (`swap()`) in
    ///      the same block return identical bytes, because the read is deterministic within a block.
    function test_StaticCall_AndCall_AgreeWithinTheSameBlock() public {
        (bool okStatic, bytes memory retStatic) = Addresses.AAVE_V3_POOL
        .staticcall(abi.encodeWithSelector(IAaveV3Pool.getUserAccountData.selector, borrower3));
        (bool okCall, bytes memory retCall) =
            Addresses.AAVE_V3_POOL.call(abi.encodeWithSelector(IAaveV3Pool.getUserAccountData.selector, borrower3));

        assertTrue(okStatic && okCall, "one of the two call shapes failed");
        assertEq(keccak256(retStatic), keccak256(retCall), "STATICCALL and CALL returned different bytes");
    }

    // -----------------------------------------------------------------------------------
    // 6. The revert taxonomy
    // -----------------------------------------------------------------------------------

    /// @dev (a) A source answering <= 0. `AaveOracle` falls through to the fallback oracle, which
    ///      is `address(0)` on mainnet, so the `uint256` decode of empty returndata reverts.
    function test_Revert_WhenACollateralPriceIsZero() public {
        assertEq(ORACLE.getFallbackOracle(), address(0), "mainnet fallback oracle is no longer unset");

        OracleWarp.breakPrice(Addresses.WETH);

        vm.expectRevert();
        POOL.getUserAccountData(borrower3);

        (bool ok,) = reader.readHealthFactor(Addresses.AAVE_V3_POOL, borrower3);
        assertFalse(ok, "a zero price should have made the read fail");
    }

    /// @dev (b) The debt asset's feed is equally fatal: one price per reserve touched, borrowed or not.
    function test_Revert_WhenTheDebtAssetPriceIsZero() public {
        OracleWarp.breakPrice(Addresses.USDC);

        vm.expectRevert();
        POOL.getUserAccountData(borrower3);

        // Per-user, not global: the saver holds no USDC reserve.
        (,,,,, uint256 hf) = POOL.getUserAccountData(saver);
        assertEq(hf, type(uint256).max, "the saver should not be affected by the USDC feed");
    }

    /// @dev (c) A source that reverts. `AaveOracle` has no try/catch. `mockCallRevert` rather than
    ///      `OracleWarp` because this is an aggregator fault, not a price.
    function test_Revert_WhenAPriceSourceItselfReverts() public {
        WarpedPriceSource source = OracleWarp.seize(Addresses.WBTC);
        vm.mockCallRevert(address(source), abi.encodeWithSelector(WarpedPriceSource.latestAnswer.selector), "feed down");

        vm.expectRevert();
        POOL.getUserAccountData(borrower3);

        assertApproxEqAbs(_hf(borrower2), 2e18, HF_TOLERANCE, "borrower2 should be unaffected by the WBTC feed");
    }

    /// @dev (d) Gas starvation, which the 63/64 rule makes relevant several frames deep.
    function test_Revert_WhenTooLittleGasIsForwarded() public view {
        (bool starved,) = reader.readHealthFactorWithGas(Addresses.AAVE_V3_POOL, borrower3, 20_000);
        assertFalse(starved, "20k gas should not be enough to read HF");

        (bool ok, uint256 hf) = reader.readHealthFactorWithGas(Addresses.AAVE_V3_POOL, borrower3, 400_000);
        assertTrue(ok, "400k gas should be plenty");
        assertApproxEqAbs(hf, 2e18, HF_TOLERANCE, "gas-limited read returned a different number");
    }

    /// @dev (e) NOT a revert. Frozen/paused/capped reserves, `reservesList` holes and a paused
    ///      Pool all leave the read working: it is a plain view with no validation. Only the
    ///      oracle and gas can stop it. Shown for the one case a test can produce cheaply.
    function test_NoRevert_WhenAPriceIsAbsurdButPositive() public {
        OracleWarp.setPrice(Addresses.WETH, 1); // $0.00000001
        assertLt(_hf(borrower3), 1e18, "a one-wei ETH price should have crushed HF below 1");

        OracleWarp.setPrice(Addresses.WETH, 1e18); // $10,000,000,000
        assertGt(_hf(borrower3), 1000e18, "an absurd ETH price should have inflated HF");
    }

    // -----------------------------------------------------------------------------------
    // 7. Gas — see docs/NOTES-gas.md
    // -----------------------------------------------------------------------------------

    // Each cold figure is the FIRST statement of its own test: `vm.cool` is inert here, and
    // Foundry only resets access lists at the setUp/test-body boundary. Hence one test per
    // measurement and comparisons against pinned constants rather than a second read.

    /// @dev What the cold surcharge is made of: proxy + impl, oracle, cap adapters and the
    ///      Chainlink proxies and aggregators behind them, aTokens and the debt token.
    function test_Gas_ColdReadTouchesTwentyAccounts() public {
        vm.startStateDiffRecording();
        POOL.getUserAccountData(borrower3);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        address[] memory unique = new address[](accesses.length);
        uint256 n;
        for (uint256 i = 0; i < accesses.length; ++i) {
            bool seen;
            for (uint256 j = 0; j < n; ++j) {
                if (unique[j] == accesses[i].account) {
                    seen = true;
                }
            }
            if (!seen) {
                unique[n++] = accesses[i].account;
            }
        }

        emit log_named_uint("accounts touched by a 3-reserve HF read", n);
        emit log_named_uint("account accesses", accesses.length);

        assertEq(n, 20, "the set of accounts the HF read walks has changed");
        assertEq(accesses.length, 33, "the number of account accesses has changed");
    }

    function test_Gas_ThreeReservePosition() public {
        uint256 cold = _read(borrower3);
        uint256 warm = _read(borrower3);

        emit log_named_uint("gas: 3-reserve, cold", cold);
        emit log_named_uint("gas: 3-reserve, warm", warm);

        assertEq(cold, GAS_COLD_3RESERVE, "the cold 3-reserve read moved");
        assertEq(warm, GAS_WARM_3RESERVE, "the warm 3-reserve read moved");
    }

    function test_Gas_TwoReservePosition() public {
        uint256 cold = _read(borrower2);
        uint256 warm = _read(borrower2);

        emit log_named_uint("gas: 2-reserve, cold", cold);
        emit log_named_uint("gas: 2-reserve, warm", warm);

        assertEq(cold, GAS_COLD_2RESERVE, "the cold 2-reserve read moved");
        assertEq(warm, GAS_WARM_2RESERVE, "the warm 2-reserve read moved");
    }

    /// @dev A maker who has never used Aave: a proxy hop plus one storage slot.
    function test_Gas_EmptyUserConfig() public {
        uint256 cold = _read(stranger);
        uint256 warm = _read(stranger);

        emit log_named_uint("gas: empty user config, cold", cold);
        emit log_named_uint("gas: empty user config, warm", warm);

        assertEq(cold, GAS_COLD_EMPTY, "the cold empty-config read moved");
        assertEq(warm, GAS_WARM_EMPTY, "the warm empty-config read moved");
    }

    /// @dev The data any HF computation must read: one price and one scaled balance per leg.
    ///      Aave's overhead above this is what a lens could skip, and it is the minority.
    function test_Gas_IrreducibleFloorOfAnyHealthFactorRead() public {
        uint256 g0 = gasleft();
        ORACLE.getAssetPrice(Addresses.WETH);
        ORACLE.getAssetPrice(Addresses.WBTC);
        ORACLE.getAssetPrice(Addresses.USDC);
        IAToken(aWeth).scaledBalanceOf(borrower3);
        IAToken(aWbtc).scaledBalanceOf(borrower3);
        IAToken(vUsdc).scaledBalanceOf(borrower3);
        uint256 floor = g0 - gasleft();

        emit log_named_uint("gas: irreducible reads (3 prices + 3 scaled balances), cold", floor);
        emit log_named_uint("gas: Pool.getUserAccountData, 3-reserve, cold (pinned)", GAS_COLD_3RESERVE);
        emit log_named_uint("gas: Aave's overhead above the floor", GAS_COLD_3RESERVE - floor);

        assertApproxEqAbs(floor, GAS_COLD_FLOOR, 1000, "the irreducible floor moved");
        assertLt(GAS_COLD_3RESERVE - floor, floor, "Aave's overhead now exceeds the data it reads");
    }

    function test_Gas_ColdReadFitsAnExtructionBudget() public view {
        assertLt(_read(borrower3), 200_000, "the HF read no longer fits a sane extruction gas budget");
    }

    /// @dev `lastCallGas().gasTotalUsed`: the callee-perspective cost, which is what an
    ///      extruction's gas budget has to cover.
    function _read(address user) internal view returns (uint256) {
        (bool ok,) =
            Addresses.AAVE_V3_POOL.staticcall(abi.encodeWithSelector(IAaveV3Pool.getUserAccountData.selector, user));
        require(ok, "gas measurement: the read failed");
        return vm.lastCallGas().gasTotalUsed;
    }

    // -----------------------------------------------------------------------------------
    // 8. OracleWarp's own contract
    // -----------------------------------------------------------------------------------

    /// @dev Seizing must be invisible, or every later test starts from a different market than
    ///      the fork block it claims.
    function test_Seize_DoesNotMoveThePrice() public {
        uint256 priceBefore = OracleWarp.priceOf(Addresses.WETH);
        uint256 hfBefore = _hf(borrower3);
        address originalSource = ORACLE.getSourceOfAsset(Addresses.WETH);
        assertFalse(OracleWarp.isWarped(Addresses.WETH), "WETH is already warped in setUp");

        WarpedPriceSource source = OracleWarp.seize(Addresses.WETH);

        assertTrue(OracleWarp.isWarped(Addresses.WETH), "seize did not install the source");
        assertEq(OracleWarp.priceOf(Addresses.WETH), priceBefore, "seize moved the price");
        assertEq(_hf(borrower3), hfBefore, "seize moved the health factor");
        assertEq(source.ORIGINAL_SOURCE(), originalSource, "seize lost the original feed");
        assertEq(source.decimals(), 8, "warped source claims the wrong scale");

        // Idempotent: a second seize must not stack a warp on a warp.
        assertEq(address(OracleWarp.seize(Addresses.WETH)), address(source), "second seize replaced the source");

        OracleWarp.release(Addresses.WETH);
        assertEq(ORACLE.getSourceOfAsset(Addresses.WETH), originalSource, "release did not restore the feed");
        assertEq(OracleWarp.priceOf(Addresses.WETH), priceBefore, "release moved the price");
    }
}
