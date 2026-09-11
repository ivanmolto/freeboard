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
import { IAaveV3Oracle } from "../../src/interfaces/IAaveV3Oracle.sol";
import { Curve } from "../../src/libs/Curve.sol";

import { IAaveProtocolDataProvider, IAaveV3PoolFixture } from "../utils/AaveFixtures.sol";
import { Curves } from "../utils/Curves.sol";
import { PricingReference } from "../utils/PricingReference.sol";
import { ProgramBuilder } from "../utils/ProgramBuilder.sol";

/// @title EnvelopeForkTest — T25. The chain refuses anything the device did not approve
/// @notice The borrower approves a curve by signing `Aqua.ship()` (T24a). Nothing else records
///         that approval. There is no signature check, no allow-list, no registry of approved
///         curves, and the extruction verifies nothing about where its curve came from. The
///         guarantee is structural: Aqua keys a maker's balances by `keccak256(strategy)`
///         (aqua v1.0.0, `src/Aqua.sol:40-47`):
///
///           strategyHash = keccak256(strategy);
///           ...
///           Balance storage balance = _balances[msg.sender][app][strategyHash][tokens[i]];
///
///         The router reads the balances it trades under the order's own hash before the program
///         runs (swap-vm v1.0.2, `src/SwapVM.sol:193-194`, and `:147-148` for `quote`):
///
///           (ctx.swap.balanceIn, ctx.swap.balanceOut) = AQUA.safeBalances(order.maker, address(this), orderHash, tokenIn, tokenOut);
///
///         and `safeBalances` refuses any key the maker never shipped (`Aqua.sol:32`):
///
///           require(tokensCount0 > 0 && tokensCount0 != _DOCKED, SafeBalancesForTokenNotInActiveStrategy(maker, app, strategyHash, token0));
///
///         The curve is in the program, the program is in the order, and for an Aqua order the
///         hash is `keccak256(abi.encode(order))` (`SwapVM.sol:97-100`). So any change to the
///         curve, even one byte, gives a different hash, and a fill against it finds nothing.
///
/// @dev WHAT THIS TEST PINS, so a refactor cannot lose it:
///        1. The curve the borrower approves is inside the bytes `ship()` commits: found as a
///           substring of the shipped program, not assumed. If the curve ever moved out of
///           the program (into storage, into taker data, into a constructor), step 1 fails
///           and so does the property.
///        2. One byte of that curve, flipped in place, is a different strategy. Aqua holds
///           nothing under it, and the DEPLOYED router refuses the fill on both `quote` and
///           `swap` with Aqua's own error, naming the tampered hash. The refusal comes from the
///           preload, before any instruction runs, so the curve is never parsed and the
///           health factor is never read.
///        3. It is refused BECAUSE the maker did not ship it, and for no other reason. The
///           tampered curve is a valid curve that prices a real fill. Once the maker ships
///           those exact bytes, the same `swap` call that was just refused settles, priced by
///           the tampered curve to the wei of the reference. That price is better for the
///           taker than the approved curve would give, which is why a taker might want the
///           substitution and why it matters that the chain refuses it.
///
/// @dev THE BYTE. The top byte of the 1.60 breakpoint's health factor, `0x16` to `0x17`.
///      1.6e18 is `0x16345785d8a00000`, so the flip moves that breakpoint to
///      1,672,057,594,037,927,936 (1.672). The curve is still strictly descending (2.00, 1.672,
///      1.30, 1.15) and every row still sums to one, so it stays valid. At Alice's HF 1.60 the
///      targets become about 38 / 22.5 / 39.5 instead of 40 / 24 / 36. USDC at about 37.9% of
///      the basket goes from over its target to under it, so a USDC-in / WBTC-out fill that the
///      approved curve prices as MIXED is priced TOWARD on both legs by the tampered one.
///
/// @dev TWO MAKERS. `test_RevertWhen_CurveNotShippedByMaker` is the full story on T21's fixture:
///      Alice at HF 1.60 with 10 WETH / 0.3 WBTC / 30,000 USDC shipped at `FORK_BLOCK`, where a
///      real Aave position lets step 3 fill. `test_RevertWhen_CurveNotShippedByTheDevice` is the
///      refusal alone against the strategy the Ledger shipped on mainnet (T24a), at the ship
///      block, with nothing of ours deployed or shipped. The property is Aqua's hash indexing,
///      the same for any maker; the second test is the one to point a judge at.
contract EnvelopeForkTest is Test {
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant WETH = Addresses.WETH;
    address internal constant WBTC = Addresses.WBTC;
    address internal constant USDC = Addresses.USDC;

    IAaveV3PoolFixture internal constant POOL = IAaveV3PoolFixture(Addresses.AAVE_V3_POOL);
    IPoolAddressesProvider internal constant PROVIDER =
        IPoolAddressesProvider(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER);

    uint256 internal constant LEGS = 3;
    uint256 internal constant VARIABLE_RATE = 2;
    uint256 internal constant AAVE_WETH_COLLATERAL = 100e18;
    uint256 internal constant HF_TARGET = 1.6e18;
    uint256 internal constant HF_TOLERANCE = 1e12;

    uint256 internal constant SHIPPED_WETH = 10 ether;
    uint256 internal constant SHIPPED_WBTC = 0.3e8;
    uint256 internal constant SHIPPED_USDC = 30_000e6;
    uint16 internal constant MAX_SHIFT_BPS = 500;

    /// @dev About 1,000 USD in the extruction's value units: well under the 500 bps cap.
    uint256 internal constant FILL_VALUE = 1000 * 1e8 * 1e18;

    /// @dev The flipped byte's offset inside the packed curve: the header (2 bytes), then row 0
    ///      (`8 * (1 + 3)` = 32 bytes), then the first, most significant, byte of row 1's
    ///      health factor (`Curve.sol` layout).
    uint256 internal constant FLIP_OFFSET = Curve.HEADER_SIZE + Curve.WORD_SIZE * (1 + LEGS);
    bytes1 internal constant APPROVED_BYTE = 0x16;
    bytes1 internal constant TAMPERED_BYTE = 0x17;

    address internal alice;
    address internal taker;
    IAaveV3Oracle internal oracle;
    FreeboardExtruction internal freeboard;

    /// @dev What Alice shipped: THE Freeboard program, built by `ProgramBuilder`.
    ProgramBuilder.Position internal approved;

    function setUp() public {
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        require(forkBlock >= Addresses.MIN_FORK_BLOCK, "FORK_BLOCK is before the router exists");
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);

        assertEq(block.chainid, Addresses.CHAIN_ID, "not forking Ethereum mainnet");
        assertEq(ROUTER.code.length, Addresses.ROUTER_RUNTIME_SIZE, "deployed AquaSwapVMRouter runtime size");
        assertEq(AQUA.code.length, Addresses.AQUA_RUNTIME_SIZE, "deployed Aqua runtime size");

        oracle = IAaveV3Oracle(PROVIDER.getPriceOracle());
        freeboard = new FreeboardExtruction();
        alice = makeAddr("alice");
        taker = makeAddr("freeboard-taker");

        _openAavePosition(alice, HF_TARGET);
        approved = ProgramBuilder.freeboardPosition(
            alice, address(freeboard), Curves.freeboard(), Curves.freeboardTokens(), MAX_SHIFT_BPS
        );
        _ship(alice, approved);

        deal(USDC, taker, 1_000_000e6);
        vm.prank(taker);
        IERC20(USDC).approve(ROUTER, type(uint256).max);

        vm.label(ROUTER, "AquaSwapVMRouter");
        vm.label(AQUA, "Aqua");
        vm.label(Addresses.AAVE_V3_POOL, "AaveV3Pool");
        vm.label(address(freeboard), "FreeboardExtruction");
        vm.label(alice, "alice");
        vm.label(taker, "taker");
        vm.label(WETH, "WETH");
        vm.label(WBTC, "WBTC");
        vm.label(USDC, "USDC");
    }

    // -----------------------------------------------------------------------------------
    // THE DoD
    // -----------------------------------------------------------------------------------

    function test_RevertWhen_CurveNotShippedByMaker() public {
        bytes memory approvedCurve = Curves.freeboard();

        // -- 1. The approved curve is inside the committed bytes. ---------------------------
        uint256 at = _indexOf(approved.order.data, approvedCurve);
        assertEq(approved.order.data[at + FLIP_OFFSET], APPROVED_BYTE, "row 1's HF does not start 0x16");

        // -- 2. Flip one byte of it, in place, in the shipped program. ----------------------
        ISwapVM.Order memory tamperedOrder = ISwapVM.Order({
            maker: approved.order.maker, traits: approved.order.traits, data: _copy(approved.order.data)
        });
        tamperedOrder.data[at + FLIP_OFFSET] = TAMPERED_BYTE;
        bytes memory tamperedStrategy = abi.encode(tamperedOrder);
        bytes32 tamperedHash = keccak256(tamperedStrategy);

        // It is exactly "a program whose curve differs by one byte": the same bytes
        // `ProgramBuilder` builds from a curve with that one byte flipped...
        bytes memory tamperedCurve = _copy(approvedCurve);
        tamperedCurve[FLIP_OFFSET] = TAMPERED_BYTE;
        assertEq(
            tamperedOrder.data,
            ProgramBuilder.freeboardPosition(
                    alice, address(freeboard), tamperedCurve, Curves.freeboardTokens(), MAX_SHIFT_BPS
                ).order.data,
            "the flipped program is not the program of the flipped curve"
        );
        // ...one byte apart in the program, one byte apart in the strategy `ship()` hashes...
        assertEq(_bytesDiffering(approved.order.data, tamperedOrder.data), 1, "programs differ by one byte");
        assertEq(_bytesDiffering(approved.strategy, tamperedStrategy), 1, "strategies differ by one byte");
        // ...and a different strategy, by the router's own hash.
        assertNotEq(tamperedHash, approved.strategyHash, "one byte, same hash");
        assertEq(ISwapVM(ROUTER).hash(tamperedOrder), tamperedHash, "router hash of the tampered order");

        // Aqua holds nothing under it. Every leg is empty and has no token count, which is
        // the "never shipped" state `safeBalances` refuses.
        address[] memory tokens = Curves.freeboardTokens();
        for (uint256 l = 0; l < LEGS; ++l) {
            (uint248 held, uint8 count) = IAqua(AQUA).rawBalances(alice, ROUTER, tamperedHash, tokens[l]);
            assertEq(uint256(held), 0, "Aqua holds a leg under the tampered strategy");
            assertEq(count, 0, "the tampered strategy has a token count");
        }

        // -- The refusal. Same maker, same tokens, same pair, same amount, same taker. ------
        uint256 amountIn = FILL_VALUE / _unit(USDC);
        bytes memory traits = _takerTraitsAndData();
        uint256[3] memory takerBefore = _balancesOf(taker);
        uint256[3] memory aliceBefore = _balancesOf(alice);

        bytes memory refusal = abi.encodeWithSelector(
            IAqua.SafeBalancesForTokenNotInActiveStrategy.selector, alice, ROUTER, tamperedHash, USDC
        );
        vm.prank(taker);
        vm.expectRevert(refusal);
        ISwapVM(ROUTER).quote(tamperedOrder, USDC, WBTC, amountIn, traits);

        vm.prank(taker);
        vm.expectRevert(refusal);
        ISwapVM(ROUTER).swap(tamperedOrder, USDC, WBTC, amountIn, traits);

        _assertBalances(taker, takerBefore, "a refused fill moved the taker's tokens");
        _assertBalances(alice, aliceBefore, "a refused fill moved alice's tokens");
        _assertShipped(approved.strategyHash, "a refused fill moved the approved legs");

        // -- 3. Refused because the maker did not ship it, and for no other reason. ----------
        uint256 hf = _poolHealthFactor(alice);
        (uint256[] memory units, uint256[] memory values, uint256 total) = _basket(approved.strategyHash);

        // The approved curve prices this fill, and prices it MIXED.
        uint256[] memory wApproved = this.weightsAt(approvedCurve, hf);
        uint256 approvedOut = _reference(units, values, total, wApproved, amountIn);
        vm.prank(taker);
        (, uint256 approvedQuote,) = ISwapVM(ROUTER).quote(approved.order, USDC, WBTC, amountIn, traits);
        assertEq(approvedQuote, approvedOut, "approved curve: quote != reference");
        assertGt(values[2] * Curve.ONE, wApproved[2] * total, "approved curve: USDC is over target");

        // Alice ships the tampered bytes herself. Same legs, same amounts, same allowance.
        _ship(
            alice,
            ProgramBuilder.Position({
                order: tamperedOrder, strategy: tamperedStrategy, strategyHash: tamperedHash, extructionArgs: ""
            })
        );
        _assertShipped(tamperedHash, "the tampered strategy after alice ships it");

        // The tampered curve reads as a valid curve, and at this HF USDC is UNDER its target.
        uint256[] memory wTampered = this.weightsAt(tamperedCurve, hf);
        assertLt(values[2] * Curve.ONE, wTampered[2] * total, "tampered curve: USDC is under target");
        uint256 tamperedOut = _reference(units, values, total, wTampered, amountIn);
        assertGt(tamperedOut, approvedOut, "the tampered curve pays the taker more");

        // The exact swap that was refused above now settles, priced by the tampered curve.
        vm.prank(taker);
        (, uint256 tamperedQuote,) = ISwapVM(ROUTER).quote(tamperedOrder, USDC, WBTC, amountIn, traits);
        assertEq(tamperedQuote, tamperedOut, "tampered curve, once shipped: quote != reference");

        // Alice's wallet was topped up by the second ship; the fill's deltas start here.
        uint256[3] memory aliceBeforeFill = _balancesOf(alice);
        vm.prank(taker);
        (, uint256 amountOut,) = ISwapVM(ROUTER).swap(tamperedOrder, USDC, WBTC, amountIn, traits);
        assertEq(amountOut, tamperedQuote, "swap != quote");
        assertEq(takerBefore[2] - IERC20(USDC).balanceOf(taker), amountIn, "taker paid USDC");
        assertEq(IERC20(WBTC).balanceOf(taker) - takerBefore[1], amountOut, "taker got WBTC");
        assertEq(IERC20(USDC).balanceOf(alice) - aliceBeforeFill[2], amountIn, "alice got USDC");
        assertEq(aliceBeforeFill[1] - IERC20(WBTC).balanceOf(alice), amountOut, "alice paid WBTC");

        emit log_named_decimal_uint("WBTC out, approved curve", approvedOut, 8);
        emit log_named_decimal_uint("WBTC out, tampered curve, refused until alice shipped it", amountOut, 8);
    }

    // -----------------------------------------------------------------------------------
    // The same property against the strategy the Ledger shipped on mainnet
    // -----------------------------------------------------------------------------------

    /// @notice The curve the borrower signed on the device (T24a, block 25,950,014), one byte
    ///         off, is refused by the DEPLOYED router on a fork at the ship block. Literally
    ///         "what the device did not approve": the maker is the Ledger account, the
    ///         extruction is the mainnet one, and the strategy on this fork is the one the
    ///         device put there — nothing is shipped or deployed here.
    ///
    /// @dev This needs no Aave position, no allowance and no taker funds: the refusal is the
    ///      router's balance preload (`SwapVM.sol:147-148`), which runs before any instruction,
    ///      so the extruction is never reached. The control quote against the device's own bytes
    ///      prices — the maker has no debt on mainnet, so the HF is `type(uint256).max` and the
    ///      curve clamps to its top row (CLAUDE.md, "inert by construction").
    function test_RevertWhen_CurveNotShippedByTheDevice() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), Addresses.MAINNET_SHIP_BLOCK);
        require(block.chainid == Addresses.CHAIN_ID, "not forking Ethereum mainnet");

        ProgramBuilder.Position memory device = ProgramBuilder.freeboardPosition(
            Addresses.MAINNET_MAKER,
            Addresses.MAINNET_EXTRUCTION,
            Curves.freeboard(),
            Curves.freeboardTokens(),
            MAX_SHIFT_BPS
        );
        assertEq(
            device.strategyHash, Addresses.MAINNET_STRATEGY_HASH, "ProgramBuilder's hash != the device-shipped one"
        );

        // What the device signed is fillable in principle: the router prices it.
        uint256 amountIn = FILL_VALUE / _unit(USDC);
        bytes memory traits = _takerTraitsAndData();
        vm.prank(taker);
        (, uint256 approvedQuote,) = ISwapVM(ROUTER).quote(device.order, USDC, WBTC, amountIn, traits);
        assertGt(approvedQuote, 0, "the device-shipped strategy does not price");

        // One byte of the signed curve, flipped in the program the device committed.
        uint256 at = _indexOf(device.order.data, Curves.freeboard());
        assertEq(device.order.data[at + FLIP_OFFSET], APPROVED_BYTE, "row 1's HF does not start 0x16");
        ISwapVM.Order memory tamperedOrder =
            ISwapVM.Order({ maker: device.order.maker, traits: device.order.traits, data: _copy(device.order.data) });
        tamperedOrder.data[at + FLIP_OFFSET] = TAMPERED_BYTE;
        bytes32 tamperedHash = keccak256(abi.encode(tamperedOrder));

        assertEq(_bytesDiffering(device.order.data, tamperedOrder.data), 1, "programs differ by one byte");
        assertNotEq(tamperedHash, Addresses.MAINNET_STRATEGY_HASH, "one byte, same hash");
        assertEq(ISwapVM(ROUTER).hash(tamperedOrder), tamperedHash, "router hash of the tampered order");

        // The Ledger account never shipped it: nothing on mainnet under that hash.
        address[] memory tokens = Curves.freeboardTokens();
        for (uint256 l = 0; l < LEGS; ++l) {
            (uint248 held, uint8 count) =
                IAqua(AQUA).rawBalances(Addresses.MAINNET_MAKER, ROUTER, tamperedHash, tokens[l]);
            assertEq(uint256(held), 0, "mainnet Aqua holds a leg under the tampered strategy");
            assertEq(count, 0, "the tampered strategy has a token count on mainnet");
        }

        bytes memory refusal = abi.encodeWithSelector(
            IAqua.SafeBalancesForTokenNotInActiveStrategy.selector, Addresses.MAINNET_MAKER, ROUTER, tamperedHash, USDC
        );
        vm.prank(taker);
        vm.expectRevert(refusal);
        ISwapVM(ROUTER).quote(tamperedOrder, USDC, WBTC, amountIn, traits);

        vm.prank(taker);
        vm.expectRevert(refusal);
        ISwapVM(ROUTER).swap(tamperedOrder, USDC, WBTC, amountIn, traits);

        // And the device's own position is where the ship left it.
        for (uint256 l = 0; l < LEGS; ++l) {
            (uint248 held, uint8 count) =
                IAqua(AQUA).rawBalances(Addresses.MAINNET_MAKER, ROUTER, Addresses.MAINNET_STRATEGY_HASH, tokens[l]);
            assertEq(uint256(held), _shipped(l), "the device-shipped leg moved");
            assertEq(count, LEGS, "the device-shipped token count");
        }
    }

    // -----------------------------------------------------------------------------------
    // Fixture
    // -----------------------------------------------------------------------------------

    /// @dev A real Aave position at `targetHf`: WETH collateral, USDC variable debt (T14).
    function _openAavePosition(address maker, uint256 targetHf) internal {
        IAaveProtocolDataProvider dataProvider = IAaveProtocolDataProvider(PROVIDER.getPoolDataProvider());
        (address aWeth,,) = dataProvider.getReserveTokensAddresses(WETH);

        deal(WETH, maker, AAVE_WETH_COLLATERAL);
        vm.startPrank(maker);
        IERC20(WETH).approve(Addresses.AAVE_V3_POOL, AAVE_WETH_COLLATERAL);
        POOL.supply(WETH, AAVE_WETH_COLLATERAL, maker, 0);
        vm.stopPrank();

        uint256 weightedCollateral =
            ((IERC20(aWeth).balanceOf(maker) * oracle.getAssetPrice(WETH)) / 1e18) * Addresses.LT_WETH_BPS;
        uint256 borrowAmount = ((weightedCollateral * 1e14) / targetHf) * 1e6 / oracle.getAssetPrice(USDC);

        vm.prank(maker);
        POOL.borrow(USDC, borrowAmount, VARIABLE_RATE, 0, maker);

        assertApproxEqAbs(_poolHealthFactor(maker), targetHf, HF_TOLERANCE, "fixture missed its target HF");
    }

    /// @dev Ships the Freeboard basket under `pos` for `maker`, and approves Aqua for it. The
    ///      allowance, not the shipped amounts, is what makes a position fillable. The tokens
    ///      are dealt on top of what the maker holds, so a second ship does not undercut the
    ///      first, and the approval is unbounded, so two strategies can share one wallet.
    function _ship(address maker, ProgramBuilder.Position memory pos) internal {
        address[] memory tokens = Curves.freeboardTokens();
        uint256[] memory amounts = new uint256[](LEGS);
        for (uint256 l = 0; l < LEGS; ++l) {
            amounts[l] = _shipped(l);
            deal(tokens[l], maker, IERC20(tokens[l]).balanceOf(maker) + amounts[l]);
        }
        vm.startPrank(maker);
        bytes32 shippedHash = IAqua(AQUA).ship(ROUTER, pos.strategy, tokens, amounts);
        for (uint256 l = 0; l < LEGS; ++l) {
            IERC20(tokens[l]).approve(AQUA, type(uint256).max);
        }
        vm.stopPrank();

        assertEq(shippedHash, pos.strategyHash, "ship() did not return keccak256(strategy)");
        assertEq(ISwapVM(ROUTER).hash(pos.order), pos.strategyHash, "router hash != shipped strategy hash");
    }

    function _shipped(uint256 leg) internal pure returns (uint256) {
        return leg == 0 ? SHIPPED_WETH : leg == 1 ? SHIPPED_WBTC : SHIPPED_USDC;
    }

    function _poolHealthFactor(address who) internal view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = POOL.getUserAccountData(who);
    }

    function _takerTraitsAndData() internal view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.taker = taker;
        args.isExactIn = true;
        args.useTransferFromAndAquaPush = true;
        args.instructionsArgs = hex"c0ffee";
        return TakerTraitsLib.build(args);
    }

    // -----------------------------------------------------------------------------------
    // Reads
    // -----------------------------------------------------------------------------------

    /// @dev Value units per wei, as `FreeboardExtruction` defines them: price scaled to 18
    ///      decimals.
    function _unit(address token) internal view returns (uint256) {
        uint256 decimals = token == WETH ? 18 : token == WBTC ? 8 : 6;
        return oracle.getAssetPrice(token) * 10 ** (18 - decimals);
    }

    /// @dev The three legs Aqua holds under `strategyHash`, valued at the oracle.
    function _basket(bytes32 strategyHash)
        internal
        view
        returns (uint256[] memory units, uint256[] memory values, uint256 total)
    {
        address[] memory tokens = Curves.freeboardTokens();
        units = new uint256[](LEGS);
        values = new uint256[](LEGS);
        for (uint256 l = 0; l < LEGS; ++l) {
            units[l] = _unit(tokens[l]);
            (uint248 held,) = IAqua(AQUA).rawBalances(alice, ROUTER, strategyHash, tokens[l]);
            values[l] = uint256(held) * units[l];
            total += values[l];
        }
    }

    /// @dev The reference price of `amountIn` USDC for WBTC at targets `w`.
    function _reference(
        uint256[] memory units,
        uint256[] memory values,
        uint256 total,
        uint256[] memory w,
        uint256 amountIn
    )
        internal
        pure
        returns (uint256)
    {
        return PricingReference.outValue(values[2], values[1], w[2], w[1], total, amountIn * units[2]) / units[1];
    }

    /// @dev Aqua's three legs under `strategyHash` are the shipped amounts.
    function _assertShipped(bytes32 strategyHash, string memory why) internal view {
        address[] memory tokens = Curves.freeboardTokens();
        for (uint256 l = 0; l < LEGS; ++l) {
            (uint248 held, uint8 count) = IAqua(AQUA).rawBalances(alice, ROUTER, strategyHash, tokens[l]);
            assertEq(uint256(held), _shipped(l), why);
            assertEq(count, LEGS, why);
        }
    }

    function _balancesOf(address who) internal view returns (uint256[3] memory balances) {
        balances = [IERC20(WETH).balanceOf(who), IERC20(WBTC).balanceOf(who), IERC20(USDC).balanceOf(who)];
    }

    function _assertBalances(address who, uint256[3] memory expected, string memory why) internal view {
        uint256[3] memory actual = _balancesOf(who);
        for (uint256 l = 0; l < LEGS; ++l) {
            assertEq(actual[l], expected[l], why);
        }
    }

    /// @dev `Curve.weightsAt` reads calldata; this is the external hop that gives it some.
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }

    // -----------------------------------------------------------------------------------
    // Bytes
    // -----------------------------------------------------------------------------------

    /// @dev The one offset at which `needle` occurs in `haystack`. Reverts if it occurs nowhere
    ///      or more than once.
    function _indexOf(bytes memory haystack, bytes memory needle) internal pure returns (uint256 found) {
        uint256 hits;
        for (uint256 i = 0; i + needle.length <= haystack.length; ++i) {
            bool matches = true;
            for (uint256 k = 0; k < needle.length && matches; ++k) {
                matches = haystack[i + k] == needle[k];
            }
            if (matches) {
                found = i;
                ++hits;
            }
        }
        require(hits == 1, "the approved curve is not in the shipped program exactly once");
    }

    function _bytesDiffering(bytes memory a, bytes memory b) internal pure returns (uint256 differing) {
        require(a.length == b.length, "lengths differ");
        for (uint256 i = 0; i < a.length; ++i) {
            if (a[i] != b[i]) {
                ++differing;
            }
        }
    }

    function _copy(bytes memory b) internal pure returns (bytes memory c) {
        c = new bytes(b.length);
        for (uint256 i = 0; i < b.length; ++i) {
            c[i] = b[i];
        }
    }
}
