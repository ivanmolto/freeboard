// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { FreeboardExtruction } from "../../src/FreeboardExtruction.sol";
import { IPoolAddressesProvider } from "../../src/interfaces/IAaveV3.sol";
import { IAaveV3Pool } from "../../src/interfaces/IAaveV3Pool.sol";

import { IAaveProtocolDataProvider, IAaveV3PoolFixture } from "../utils/AaveFixtures.sol";
import { IAaveOracle } from "../utils/OracleWarp.sol";
import { ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { ProgramLib } from "../utils/ProgramLib.sol";

/// @title HealthFactorForkTest — T13
/// @notice The health-factor read as `FreeboardExtruction` actually performs it: from inside
///         `extruction()`, on the DEPLOYED AquaSwapVMRouter, on real Aqua positions owned by
///         makers with real Aave v3 debt. T8 (`test/fork/AaveHF.t.sol`) established what
///         `getUserAccountData` returns; this file establishes WHOSE.
///
/// @dev THE PROPERTY. Freeboard reads HF for `query.maker` — the maker the router names in the
///      `SwapQuery` it builds from the order — and for nobody else. A strategy cannot point the
///      read at another position, because the address is not an input to the program: it is not
///      in the extruction args, not in taker data, and not chooseable through the Aave address
///      either, which is the compile-time constant `Addresses.AAVE_V3_POOL`.
///
///      Proving that from outside is the interesting part, because in this revision HF does not
///      yet move the price (T14 does that), so it cannot be observed through `amountOut`. It is
///      observed two ways instead, and they close each other's gap:
///        POSITIVELY — `vm.expectCall` with the complete ABI encoding pins the exact address
///          argument the pool is called with during a fill;
///        NEGATIVELY — the OTHER maker's read is mocked to revert. Since an unreadable HF
///          reverts the fill by construction, a fill that still succeeds is a fill that never
///          touched that position. Reversing the mock reverts the fill, and the named error
///          carries the address the read was for.
///
/// @dev Two makers, two positions, two Aqua strategies: one at HF ~2.00 (the top of the curve,
///      50/30/20) and one at HF ~1.30 (the 30/16/54 breakpoint, most of the way down toward
///      the 1.15 floor), built with real `supply`/`borrow`.
contract HealthFactorForkTest is Test {
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant WETH = Addresses.WETH;
    address internal constant USDC = Addresses.USDC;

    IAaveV3PoolFixture internal constant POOL = IAaveV3PoolFixture(Addresses.AAVE_V3_POOL);
    IPoolAddressesProvider internal constant PROVIDER =
        IPoolAddressesProvider(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER);
    IAaveOracle internal constant ORACLE = IAaveOracle(Addresses.AAVE_V3_ORACLE);

    /// @dev Aave v3.5 has one rate mode left: 2 = variable.
    uint256 internal constant VARIABLE_RATE = 2;

    /// @dev Aave collateral per maker, kept identical so the two health factors differ only by
    ///      how much each borrowed. ~$249.8k at FORK_BLOCK, far below the supply cap.
    uint256 internal constant AAVE_WETH_COLLATERAL = 100e18;

    uint256 internal constant HF_TOP = 2e18;
    uint256 internal constant HF_MID = 1.3e18;

    /// @dev 1e-6 HF; the real error is flooring on the 1e-8 USD price grid. See T8.
    uint256 internal constant HF_TOLERANCE = 1e12;

    /// @dev The shipped Aqua basket, per maker: 10 WETH and 30,000 USDC. Identical for both, so
    ///      the two positions are distinguishable ONLY by whose Aave debt they sit on.
    uint256 internal constant SHIPPED_WETH = 10 ether;
    uint256 internal constant SHIPPED_USDC = 30_000e6;

    /// @dev The taker sells 1 WETH, exact-in. `FreeboardExtruction._price` is still pass-through
    ///      at the shipped ratio (T9): 1e18 * 30_000e6 / 10e18 = 3_000e6.
    uint256 internal constant AMOUNT_IN = 1 ether;
    uint256 internal constant EXPECTED_AMOUNT_OUT = 3000e6;

    /// @dev `getUserAccountData(address)`. Pinned so a change to `IAaveV3Pool`'s declaration —
    ///      a renamed parameter type, an added argument — is a red test and not a silent miss
    ///      against the deployed dispatcher.
    bytes4 internal constant GET_USER_ACCOUNT_DATA = 0xbf92857c;

    bytes internal constant INSTRUCTIONS_ARGS = hex"c0ffee";
    bytes internal constant POOL_DOWN = hex"deadbeef";

    address internal makerTop; //  Aave HF ~2.00
    address internal makerMid; //  Aave HF ~1.30
    address internal taker;

    FreeboardExtruction internal freeboard;
    ProgramBuilder.Position internal positionTop;
    ProgramBuilder.Position internal positionMid;

    address internal aWeth;

    // -----------------------------------------------------------------------------------
    // Fixture
    // -----------------------------------------------------------------------------------

    function setUp() public {
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        require(forkBlock >= Addresses.MIN_FORK_BLOCK, "FORK_BLOCK is before the router exists");
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);

        assertEq(block.chainid, Addresses.CHAIN_ID, "not forking Ethereum mainnet");
        assertEq(ROUTER.code.length, Addresses.ROUTER_RUNTIME_SIZE, "deployed AquaSwapVMRouter runtime size");

        (aWeth,,) = IAaveProtocolDataProvider(PROVIDER.getPoolDataProvider()).getReserveTokensAddresses(Addresses.WETH);

        freeboard = new FreeboardExtruction();

        makerTop = makeAddr("freeboard-maker-hf-2.00");
        makerMid = makeAddr("freeboard-maker-hf-1.30");
        taker = makeAddr("freeboard-taker");

        // The extruction args carry no address: 20 bytes of the target are stripped by the
        // router, and what follows is the curve payload T14 defines. Distinct per maker so a
        // crossed strategy would be visible in the calldata, not just in the outcome.
        positionTop = _openPosition(makerTop, HF_TOP, hex"70");
        positionMid = _openPosition(makerMid, HF_MID, hex"b1");

        deal(WETH, taker, 10 * AMOUNT_IN);
        vm.prank(taker);
        IERC20(WETH).approve(ROUTER, type(uint256).max);

        vm.label(ROUTER, "AquaSwapVMRouter");
        vm.label(AQUA, "Aqua");
        vm.label(Addresses.AAVE_V3_POOL, "AaveV3Pool");
        vm.label(address(freeboard), "FreeboardExtruction");
        vm.label(makerTop, "makerTop");
        vm.label(makerMid, "makerMid");
    }

    /// @dev One maker: a real Aave position at `targetHf`, then a real Aqua strategy shipped to
    ///      the deployed router. The two are independent — Aave holds aWETH against USDC debt,
    ///      Aqua holds an allowance over the maker's wallet — and that is the point: the basket
    ///      being rebalanced and the debt whose health factor prices it are separate objects.
    function _openPosition(
        address maker,
        uint256 targetHf,
        bytes memory extructionArgs
    )
        internal
        returns (ProgramBuilder.Position memory position)
    {
        deal(WETH, maker, AAVE_WETH_COLLATERAL);
        vm.startPrank(maker);
        IERC20(WETH).approve(Addresses.AAVE_V3_POOL, AAVE_WETH_COLLATERAL);
        POOL.supply(WETH, AAVE_WETH_COLLATERAL, maker, 0);
        vm.stopPrank();

        // Inverts `GenericLogic`: HF = (SUM(collateral_i * lt_i) * 1e18 / debtBase) / 1e4, so
        // debtBase = L * 1e14 / HF. `L` is the unnormalised accumulator, 10 decimals.
        uint256 weightedCollateral =
            ((IERC20(aWeth).balanceOf(maker) * ORACLE.getAssetPrice(WETH)) / 1e18) * Addresses.LT_WETH_BPS;
        uint256 borrowAmount = ((weightedCollateral * 1e14) / targetHf) * 1e6 / ORACLE.getAssetPrice(USDC);

        vm.prank(maker);
        POOL.borrow(USDC, borrowAmount, VARIABLE_RATE, 0, maker);

        assertApproxEqAbs(_poolHealthFactor(maker), targetHf, HF_TOLERANCE, "fixture missed its target HF");

        // The Aqua basket. Dealt after the borrow, which also pays USDC into the wallet.
        deal(WETH, maker, SHIPPED_WETH);
        deal(USDC, maker, SHIPPED_USDC);

        position = ProgramBuilder.aquaPosition(maker, ProgramLib.extruction(address(freeboard), extructionArgs));

        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SHIPPED_WETH;
        amounts[1] = SHIPPED_USDC;

        vm.startPrank(maker);
        bytes32 shippedHash = IAqua(AQUA).ship(ROUTER, position.strategy, tokens, amounts);
        // The allowance, not the shipped amounts, is what makes a position fillable.
        IERC20(USDC).approve(AQUA, SHIPPED_USDC);
        vm.stopPrank();

        assertEq(shippedHash, position.strategyHash, "ship() did not return keccak256(strategy)");
        assertEq(ISwapVM(ROUTER).hash(position.order), position.strategyHash, "router hash != shipped strategy hash");
    }

    function _poolHealthFactor(address who) internal view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = POOL.getUserAccountData(who);
    }

    /// @dev The exact calldata `FreeboardExtruction._healthFactor` sends for a given maker.
    function _readOf(address maker) internal pure returns (bytes memory) {
        return abi.encodeCall(IAaveV3Pool.getUserAccountData, (maker));
    }

    function _takerTraitsAndData() internal view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.taker = taker;
        args.isExactIn = true;
        args.useTransferFromAndAquaPush = true;
        args.instructionsArgs = INSTRUCTIONS_ARGS;
        return TakerTraitsLib.build(args);
    }

    function _quote(ProgramBuilder.Position storage position) internal returns (uint256 amountOut) {
        vm.prank(taker);
        (, amountOut,) = ISwapVM(ROUTER).quote(position.order, WETH, USDC, AMOUNT_IN, _takerTraitsAndData());
    }

    function _swap(ProgramBuilder.Position storage position) internal returns (uint256 amountOut) {
        vm.prank(taker);
        (, amountOut,) = ISwapVM(ROUTER).swap(position.order, WETH, USDC, AMOUNT_IN, _takerTraitsAndData());
    }

    // -----------------------------------------------------------------------------------
    // THE DoD
    // -----------------------------------------------------------------------------------

    /// @notice Two makers, two positions, two strategies: each reads its own health factor.
    function test_HealthFactor_IsReadForQueryMaker() public {
        // -- 0. The two positions really are at different health factors. ------------------
        uint256 hfTop = _poolHealthFactor(makerTop);
        uint256 hfMid = _poolHealthFactor(makerMid);

        assertApproxEqAbs(hfTop, HF_TOP, HF_TOLERANCE, "makerTop is not at HF 2.00");
        assertApproxEqAbs(hfMid, HF_MID, HF_TOLERANCE, "makerMid is not at HF 1.30");
        assertGt(hfTop, hfMid, "the two makers must be distinguishable by health factor");
        assertGt(hfMid, 1e18, "both fixtures must stay above liquidation");

        emit log_named_decimal_uint("makerTop HF", hfTop, 18);
        emit log_named_decimal_uint("makerMid HF", hfMid, 18);

        // -- 1. Positively: the pool is called with query.maker, byte for byte. -------------
        //
        // expectCall matches on the complete ABI encoding, so this pins the address argument
        // and not merely the selector.
        vm.expectCall(Addresses.AAVE_V3_POOL, _readOf(makerTop));
        assertEq(_quote(positionTop), EXPECTED_AMOUNT_OUT, "makerTop quote");

        vm.expectCall(Addresses.AAVE_V3_POOL, _readOf(makerMid));
        assertEq(_quote(positionMid), EXPECTED_AMOUNT_OUT, "makerMid quote");

        // -- 2. Negatively: makerMid's read is broken; makerTop is untouched by it. ---------
        //
        // An unreadable HF reverts the fill, so a fill that still settles is a fill that never
        // read that position. This is the assertion `expectCall` cannot make: it can require a
        // call, not forbid one.
        vm.mockCallRevert(Addresses.AAVE_V3_POOL, _readOf(makerMid), POOL_DOWN);

        vm.expectCall(Addresses.AAVE_V3_POOL, _readOf(makerTop));
        assertEq(_quote(positionTop), EXPECTED_AMOUNT_OUT, "makerTop must not depend on makerMid's position");

        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardHealthFactorUnreadable.selector, makerMid));
        _quote(positionMid);

        // -- 3. And the mirror image, so neither direction is an accident. ------------------
        vm.clearMockedCalls();
        vm.mockCallRevert(Addresses.AAVE_V3_POOL, _readOf(makerTop), POOL_DOWN);

        vm.expectCall(Addresses.AAVE_V3_POOL, _readOf(makerMid));
        assertEq(_quote(positionMid), EXPECTED_AMOUNT_OUT, "makerMid must not depend on makerTop's position");

        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardHealthFactorUnreadable.selector, makerTop));
        _quote(positionTop);

        // -- 4. The same on the settlement path, with real tokens moving. -------------------
        vm.clearMockedCalls();

        uint256 takerUsdcBefore = IERC20(USDC).balanceOf(taker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(makerMid);

        vm.expectCall(Addresses.AAVE_V3_POOL, _readOf(makerMid));
        assertEq(_swap(positionMid), EXPECTED_AMOUNT_OUT, "makerMid swap");

        assertEq(IERC20(USDC).balanceOf(taker) - takerUsdcBefore, EXPECTED_AMOUNT_OUT, "taker received USDC");
        assertEq(makerUsdcBefore - IERC20(USDC).balanceOf(makerMid), EXPECTED_AMOUNT_OUT, "maker paid USDC");

        // The read is a read: settling did not change either Aave position.
        assertApproxEqAbs(_poolHealthFactor(makerMid), hfMid, HF_TOLERANCE, "the fill moved the maker's Aave debt");
        assertApproxEqAbs(_poolHealthFactor(makerTop), hfTop, HF_TOLERANCE, "the fill moved the other maker's debt");
    }

    // -----------------------------------------------------------------------------------
    // The address is not an input to the program
    // -----------------------------------------------------------------------------------

    /// @notice A strategy carrying another maker's address in its extruction args still reads
    ///         its own position. The args are not consulted for the subject of the read.
    /// @dev The strongest form of the claim the natspec makes. A third maker ships a program
    ///      whose args are exactly `makerMid`'s 20 bytes — the shape a redirect would take if
    ///      `_healthFactor` took its address from `args` instead of from `query.maker`. With
    ///      `makerMid`'s read mocked to revert, the fill settles anyway, and `expectCall` pins
    ///      the read to the shipper's own address.
    function test_ArgsCannotRedirectTheReadToAnotherPosition() public {
        address attacker = makeAddr("freeboard-maker-args-carry-another-address");
        ProgramBuilder.Position memory redirect = _openPosition(attacker, HF_TOP, abi.encodePacked(makerMid));

        assertEq(redirect.order.data.length, 2 + 20 + 20, "the program carries a second address after the target");

        vm.mockCallRevert(Addresses.AAVE_V3_POOL, _readOf(makerMid), POOL_DOWN);

        vm.expectCall(Addresses.AAVE_V3_POOL, _readOf(attacker));
        vm.prank(taker);
        (, uint256 amountOut,) = ISwapVM(ROUTER).quote(redirect.order, WETH, USDC, AMOUNT_IN, _takerTraitsAndData());

        assertEq(amountOut, EXPECTED_AMOUNT_OUT, "the read followed the args instead of query.maker");
    }

    // -----------------------------------------------------------------------------------
    // The pool-reverts case, against a mock pool
    // -----------------------------------------------------------------------------------

    /// @notice A reverting pool reverts the fill, on both the quote and the swap path, with the
    ///         maker named. No try/catch, no default health factor.
    function test_RevertWhen_ThePoolCallReverts() public {
        vm.mockCallRevert(Addresses.AAVE_V3_POOL, _readOf(makerTop), POOL_DOWN);

        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardHealthFactorUnreadable.selector, makerTop));
        _quote(positionTop);

        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardHealthFactorUnreadable.selector, makerTop));
        _swap(positionTop);

        // Nothing settled: the basket is exactly as shipped.
        (uint256 aquaWeth, uint256 aquaUsdc) =
            IAqua(AQUA).safeBalances(makerTop, ROUTER, positionTop.strategyHash, WETH, USDC);
        assertEq(aquaWeth, SHIPPED_WETH, "a refused fill must not have pushed WETH");
        assertEq(aquaUsdc, SHIPPED_USDC, "a refused fill must not have pulled USDC");
    }

    /// @notice A pool answering with fewer than six words is refused, not decoded.
    /// @dev Without the length check this path would still revert — `abi.decode` of a short
    ///      buffer does — but with EMPTY revert data, indistinguishable from a dozen other
    ///      failures. The check is what makes it a named refusal carrying the maker. It does
    ///      not, and cannot, vouch for the content of a six-word answer; only the pool address
    ///      being a compile-time constant does that.
    function test_RevertWhen_ThePoolReturnsTheWrongShape() public {
        vm.mockCall(Addresses.AAVE_V3_POOL, _readOf(makerTop), abi.encode(uint256(2e18)));

        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardHealthFactorUnreadable.selector, makerTop));
        _quote(positionTop);
    }

    /// @notice A pool with no code is refused. A STATICCALL to a codeless address SUCCEEDS and
    ///         returns nothing, so success alone would let an empty answer through.
    function test_RevertWhen_ThePoolHasNoCode() public {
        vm.etch(Addresses.AAVE_V3_POOL, "");
        assertEq(Addresses.AAVE_V3_POOL.code.length, 0, "the pool should have been emptied");

        vm.expectRevert(abi.encodeWithSelector(FreeboardExtruction.FreeboardHealthFactorUnreadable.selector, makerTop));
        _quote(positionTop);
    }

    // -----------------------------------------------------------------------------------
    // The interface, against the deployed dispatcher
    // -----------------------------------------------------------------------------------

    /// @notice `IAaveV3Pool` declares one function, and it is the one the deployed pool answers.
    /// @dev The selector is the whole contract between this repo and Aave's dispatcher: T8
    ///      verified the six return values, and this pins the four bytes that reach them, so a
    ///      later edit to the declaration cannot silently miss.
    function test_Interface_SelectorMatchesTheDeployedPool() public view {
        assertEq(IAaveV3Pool.getUserAccountData.selector, GET_USER_ACCOUNT_DATA, "selector drifted");

        (bool ok, bytes memory ret) = Addresses.AAVE_V3_POOL.staticcall(_readOf(makerMid));
        assertTrue(ok, "the deployed pool did not answer this selector");
        assertEq(ret.length, 6 * 32, "the deployed pool does not return six words");

        (,,,,, uint256 healthFactor) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256));
        assertEq(healthFactor, _poolHealthFactor(makerMid), "the typed and raw reads disagree");
    }

    /// @notice A maker with no Aave debt is read, not skipped: the sentinel comes back and the
    ///         fill proceeds.
    /// @dev No debt means no deleveraging, so the top of the curve is the correct target — T16
    ///      owns `test_NoDebt_PricesAtTopOfCurve` once the curve prices. What matters here is
    ///      that the read still happens and `type(uint256).max` is not mistaken for a failure.
    function test_NoDebt_ReadsTheSentinelAndFillsAnyway() public {
        address saver = makeAddr("freeboard-maker-no-aave-position");
        assertEq(_poolHealthFactor(saver), type(uint256).max, "an untouched account is not the no-debt sentinel");

        deal(WETH, saver, SHIPPED_WETH);
        deal(USDC, saver, SHIPPED_USDC);

        ProgramBuilder.Position memory position =
            ProgramBuilder.aquaPosition(saver, ProgramLib.extruction(address(freeboard), hex"00"));

        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SHIPPED_WETH;
        amounts[1] = SHIPPED_USDC;

        vm.startPrank(saver);
        IAqua(AQUA).ship(ROUTER, position.strategy, tokens, amounts);
        IERC20(USDC).approve(AQUA, SHIPPED_USDC);
        vm.stopPrank();

        vm.expectCall(Addresses.AAVE_V3_POOL, _readOf(saver));
        vm.prank(taker);
        (, uint256 amountOut,) = ISwapVM(ROUTER).swap(position.order, WETH, USDC, AMOUNT_IN, _takerTraitsAndData());

        assertEq(amountOut, EXPECTED_AMOUNT_OUT, "a no-debt maker's fill must settle");
    }
}
