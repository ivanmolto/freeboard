// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { IPoolAddressesProvider } from "../../src/interfaces/IAaveV3.sol";
import { IAaveV3Oracle } from "../../src/interfaces/IAaveV3Oracle.sol";
import { Curve } from "../../src/libs/Curve.sol";

import { IAaveProtocolDataProvider, IAaveV3PoolFixture } from "../utils/AaveFixtures.sol";
import { Curves } from "../utils/Curves.sol";
import { PricingReference } from "../utils/PricingReference.sol";
import { ProgramBuilder } from "../utils/ProgramBuilder.sol";

/// @title LedgerShipForkTest — T24a. The curve the borrower approved on her Ledger, read back
///        from Ethereum mainnet and filled against on a fork
/// @notice On Sep 11 the borrower signed `Aqua.ship()` on a Ledger through the official
///         wallet-cli and it landed in block 25,950,014 (`results/ledger-ship.txt`). Two things
///         have to be true of that transaction for it to mean anything:
///
///         1. Its calldata IS the Freeboard program. Not "a" program: the bytes `ProgramBuilder`
///            produces for this maker, this extruction, this curve and this cap — the same bytes
///            every fork test in the repo ships — decoded from the mainnet transaction and
///            compared field by field. One byte of drift and it is a different strategy
///            (VERIFIED FACTS), so equality here is what makes the device's approval the
///            approval of THIS curve.
///         2. What it committed is fillable. The mainnet position is inert on purpose (no
///            allowance, no debt), so a fork after the ship block gives the same maker a real
///            Aave position and an allowance, and a taker fills against the strategy the device
///            shipped — on the DEPLOYED router, through the mainnet extruction, priced by the
///            curve the borrower signed, to the wei of the reference.
///
/// @dev Forks at `MAINNET_SHIP_BLOCK`, after `FORK_BLOCK`; nothing pinned elsewhere moves.
contract LedgerShipForkTest is Test {
    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant MAKER = Addresses.MAINNET_MAKER;
    address internal constant WETH = Addresses.WETH;
    address internal constant WBTC = Addresses.WBTC;
    address internal constant USDC = Addresses.USDC;

    IAaveV3PoolFixture internal constant POOL = IAaveV3PoolFixture(Addresses.AAVE_V3_POOL);
    IPoolAddressesProvider internal constant PROVIDER =
        IPoolAddressesProvider(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER);

    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant LEGS = 3;

    /// @dev What `script/ShipCalldata.s.sol` declared — T23's basket and cap.
    uint256 internal constant SHIPPED_WETH = 10 ether;
    uint256 internal constant SHIPPED_WBTC = 0.3e8;
    uint256 internal constant SHIPPED_USDC = 30_000e6;
    uint16 internal constant MAX_SHIFT_BPS = 500;

    ProgramBuilder.Position internal position;
    address internal taker;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), Addresses.MAINNET_SHIP_BLOCK);
        require(block.chainid == Addresses.CHAIN_ID, "not forking Ethereum mainnet");
        position = ProgramBuilder.freeboardPosition(
            MAKER, Addresses.MAINNET_EXTRUCTION, Curves.freeboard(), Curves.freeboardTokens(), MAX_SHIFT_BPS
        );
        taker = makeAddr("freeboard-taker");
        vm.label(MAKER, "ledger-maker");
        vm.label(Addresses.MAINNET_EXTRUCTION, "FreeboardExtruction(mainnet)");
    }

    // -------------------------------------------------------------------------------------
    // 1. The transaction the device signed is the program, byte for byte
    // -------------------------------------------------------------------------------------

    /// @dev The proof is the chain's own indexing, not a transcript. Aqua keys a position by
    ///      `(msg.sender, app, keccak256(strategy), token)` (aqua v1.0.0, `src/Aqua.sol:40-47`),
    ///      so balances found under `(MAINNET_MAKER, router, keccak256(position.strategy))` at
    ///      the ship block — and none one block earlier — mean the Ledger account executed a
    ///      `ship()` whose `strategy` argument hashes to exactly these bytes, in exactly that
    ///      block: a keccak preimage is not forgeable, and `msg.sender` is the signer. The
    ///      calldata recorded in `results/ledger-ship.txt` is then decoded and compared field by
    ///      field, so the artifact a judge reads is the transaction the chain executed.
    function test_DeviceSignedShip_CarriesTheProgramBytes() public {
        address[] memory expectedTokens = Curves.freeboardTokens();
        uint256[3] memory expectedAmounts = [SHIPPED_WETH, SHIPPED_WBTC, SHIPPED_USDC];

        assertEq(position.strategyHash, Addresses.MAINNET_STRATEGY_HASH, "ProgramBuilder's hash != the pinned one");
        assertEq(ISwapVM(ROUTER).hash(position.order), Addresses.MAINNET_STRATEGY_HASH, "router.hash(order) != the shipped hash");

        // One block before the ship: nothing under the hash.
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), Addresses.MAINNET_SHIP_BLOCK - 1);
        for (uint256 l = 0; l < LEGS; ++l) {
            (uint248 held,) = IAqua(AQUA).rawBalances(MAKER, ROUTER, Addresses.MAINNET_STRATEGY_HASH, expectedTokens[l]);
            assertEq(uint256(held), 0, "the strategy had balances before the ship block");
        }

        // At the ship block: the declared legs, under this maker, this app, this hash.
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), Addresses.MAINNET_SHIP_BLOCK);
        for (uint256 l = 0; l < LEGS; ++l) {
            (uint248 held, uint8 count) =
                IAqua(AQUA).rawBalances(MAKER, ROUTER, Addresses.MAINNET_STRATEGY_HASH, expectedTokens[l]);
            assertEq(uint256(held), expectedAmounts[l], "Aqua does not hold the declared leg under the shipped strategy");
            assertEq(count, LEGS, "Aqua's token count for the strategy");
            assertEq(IERC20(expectedTokens[l]).allowance(MAKER, AQUA), 0, "the mainnet position must be inert: zero allowance");
        }

        // The recorded calldata decodes to the same program.
        bytes memory input = _artifactCalldata();
        assertEq(bytes4(input), IAqua.ship.selector, "calldata is not Aqua.ship");

        bytes memory args = new bytes(input.length - 4);
        for (uint256 i = 0; i < args.length; ++i) {
            args[i] = input[i + 4];
        }
        (address app, bytes memory strategy, address[] memory tokens, uint256[] memory amounts) =
            abi.decode(args, (address, bytes, address[], uint256[]));

        assertEq(app, ROUTER, "app is not the DEPLOYED AquaSwapVMRouter");
        assertEq(strategy, position.strategy, "recorded strategy != the bytes ProgramBuilder ships");
        assertEq(keccak256(strategy), Addresses.MAINNET_STRATEGY_HASH, "recorded strategy hash != the pinned one");
        assertEq(tokens.length, LEGS, "token count");
        assertEq(amounts.length, LEGS, "amount count");
        for (uint256 l = 0; l < LEGS; ++l) {
            assertEq(tokens[l], expectedTokens[l], "token order");
            assertEq(amounts[l], expectedAmounts[l], "shipped amount");
        }
    }

    /// @dev The `calldata` line of `results/ledger-ship.txt`, as bytes.
    function _artifactCalldata() internal view returns (bytes memory) {
        string[] memory lines = vm.split(vm.readFile("results/ledger-ship.txt"), "\n");
        for (uint256 i = 0; i < lines.length; ++i) {
            bytes memory line = bytes(lines[i]);
            if (line.length < 8 || line[0] != "c" || line[1] != "a" || line[2] != "l" || line[3] != "l") {
                continue;
            }
            uint256 start;
            while (start + 1 < line.length && !(line[start] == "0" && line[start + 1] == "x")) {
                ++start;
            }
            uint256 end = line.length;
            while (end > start && (line[end - 1] == " " || line[end - 1] == "\r")) {
                --end;
            }
            bytes memory hexText = new bytes(end - start);
            for (uint256 k = 0; k < hexText.length; ++k) {
                hexText[k] = line[start + k];
            }
            return vm.parseBytes(string(hexText));
        }
        revert("results/ledger-ship.txt has no calldata line");
    }

    // -------------------------------------------------------------------------------------
    // 2. The strategy the device shipped fills, on a fork, through the mainnet extruction
    // -------------------------------------------------------------------------------------

    /// @dev The maker is pranked into T23's position — 100 WETH + 3 WBTC supplied, USDC borrowed
    ///      to HF 2.00 — given the shipped tokens and an allowance; the taker takes the fill T23's
    ///      rule would take (pay in the leg furthest under target, take out the leg furthest
    ///      over, under the cap). Nothing is shipped here: the strategy on this fork is the one
    ///      the Ledger put there.
    function test_TheDeviceShippedStrategy_FillsOnTheFork() public {
        _openAavePosition();
        deal(WETH, MAKER, SHIPPED_WETH);
        deal(WBTC, MAKER, SHIPPED_WBTC);
        vm.startPrank(MAKER);
        IERC20(WETH).approve(AQUA, type(uint256).max);
        IERC20(WBTC).approve(AQUA, type(uint256).max);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        vm.stopPrank();

        deal(WETH, taker, 100 ether);
        deal(WBTC, taker, 10e8);
        deal(USDC, taker, 1_000_000e6);
        vm.startPrank(taker);
        IERC20(WETH).approve(ROUTER, type(uint256).max);
        IERC20(WBTC).approve(ROUTER, type(uint256).max);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.stopPrank();

        (,,,,, uint256 hf) = POOL.getUserAccountData(MAKER);
        assertGt(hf, 1e18, "the maker's forked position is not healthy");
        uint256[] memory targets = this.weightsAt(Curves.freeboard(), hf);

        (uint256[] memory units, uint256[] memory values, uint256 total) = _basket();
        (uint256 legIn, uint256 legOut, uint256 amountIn) = _towardFill(units, values, total, targets);
        address[] memory tokens = Curves.freeboardTokens();
        address tokenIn = tokens[legIn];
        address tokenOut = tokens[legOut];

        bytes memory traits = _takerTraitsAndData();
        vm.prank(taker);
        (, uint256 quoted,) = ISwapVM(ROUTER).quote(position.order, tokenIn, tokenOut, amountIn, traits);
        uint256 valueIn = amountIn * units[legIn];
        uint256 referenceOut =
            PricingReference.outValue(values[legIn], values[legOut], targets[legIn], targets[legOut], total, valueIn) / units[legOut];
        assertEq(quoted, referenceOut, "the deployed router's quote != PricingReference at the shipped curve");
        assertGt(quoted, 0, "quote");

        uint256 takerIn = IERC20(tokenIn).balanceOf(taker);
        uint256 takerOut = IERC20(tokenOut).balanceOf(taker);
        uint256 makerIn = IERC20(tokenIn).balanceOf(MAKER);
        uint256 makerOut = IERC20(tokenOut).balanceOf(MAKER);

        vm.prank(taker);
        (, uint256 amountOut,) = ISwapVM(ROUTER).swap(position.order, tokenIn, tokenOut, amountIn, traits);

        assertEq(amountOut, quoted, "swap != quote");
        assertEq(takerIn - IERC20(tokenIn).balanceOf(taker), amountIn, "taker paid");
        assertEq(IERC20(tokenOut).balanceOf(taker) - takerOut, amountOut, "taker got");
        assertEq(IERC20(tokenIn).balanceOf(MAKER) - makerIn, amountIn, "maker got");
        assertEq(makerOut - IERC20(tokenOut).balanceOf(MAKER), amountOut, "maker paid");

        (uint248 heldIn,) = IAqua(AQUA).rawBalances(MAKER, ROUTER, Addresses.MAINNET_STRATEGY_HASH, tokenIn);
        (uint248 heldOut,) = IAqua(AQUA).rawBalances(MAKER, ROUTER, Addresses.MAINNET_STRATEGY_HASH, tokenOut);
        assertEq(uint256(heldIn), _shipped(legIn) + amountIn, "Aqua's in leg after the fill");
        assertEq(uint256(heldOut), _shipped(legOut) - amountOut, "Aqua's out leg after the fill");
    }

    // -------------------------------------------------------------------------------------
    // Fixture
    // -------------------------------------------------------------------------------------

    /// @dev T23's position for this maker: `PricePathEngine._openAavePosition` and
    ///      `_borrowToHealthFactor`, inlined.
    function _openAavePosition() internal {
        IAaveProtocolDataProvider dataProvider = IAaveProtocolDataProvider(PROVIDER.getPoolDataProvider());
        (address aWeth,,) = dataProvider.getReserveTokensAddresses(WETH);
        (address aWbtc,,) = dataProvider.getReserveTokensAddresses(WBTC);

        _supply(WETH, 100e18);
        _supply(WBTC, 3e8);

        IAaveV3Oracle oracle = IAaveV3Oracle(PROVIDER.getPriceOracle());
        uint256 wethBase = (IERC20(aWeth).balanceOf(MAKER) * oracle.getAssetPrice(WETH)) / 1e18;
        uint256 wbtcBase = (IERC20(aWbtc).balanceOf(MAKER) * oracle.getAssetPrice(WBTC)) / 1e8;
        uint256 weighted = wethBase * Addresses.LT_WETH_BPS + wbtcBase * Addresses.LT_WBTC_BPS;
        uint256 debtBase = (weighted * 1e14) / 2e18;
        uint256 amount = (debtBase * 1e6) / oracle.getAssetPrice(USDC);

        vm.prank(MAKER);
        POOL.borrow(USDC, amount, 2, 0, MAKER);
        assertGe(amount, SHIPPED_USDC, "the borrow must cover the USDC leg");
    }

    function _supply(address asset, uint256 amount) internal {
        deal(asset, MAKER, amount);
        vm.startPrank(MAKER);
        IERC20(asset).approve(Addresses.AAVE_V3_POOL, amount);
        POOL.supply(asset, amount, MAKER, 0);
        vm.stopPrank();
    }

    function _shipped(uint256 leg) internal pure returns (uint256) {
        return leg == 0 ? SHIPPED_WETH : leg == 1 ? SHIPPED_WBTC : SHIPPED_USDC;
    }

    /// @dev Value units per wei as `FreeboardExtruction._unit` defines them, the legs Aqua holds,
    ///      and the basket total.
    function _basket() internal view returns (uint256[] memory units, uint256[] memory values, uint256 total) {
        IAaveV3Oracle oracle = IAaveV3Oracle(PROVIDER.getPriceOracle());
        address[] memory tokens = Curves.freeboardTokens();
        uint8[3] memory decimals = [18, 8, 6];
        units = new uint256[](LEGS);
        values = new uint256[](LEGS);
        for (uint256 l = 0; l < LEGS; ++l) {
            units[l] = oracle.getAssetPrice(tokens[l]) * 10 ** (18 - decimals[l]);
            (uint248 held,) = IAqua(AQUA).rawBalances(MAKER, ROUTER, Addresses.MAINNET_STRATEGY_HASH, tokens[l]);
            values[l] = uint256(held) * units[l];
            total += values[l];
        }
    }

    /// @dev T23's rule (`PricePathEngine.nextFill`): pay in the leg furthest under target, take
    ///      out the leg furthest over, sized to the smaller gap, the cap, and the out leg.
    function _towardFill(
        uint256[] memory units,
        uint256[] memory values,
        uint256 total,
        uint256[] memory targets
    )
        internal
        pure
        returns (uint256 legIn, uint256 legOut, uint256 amountIn)
    {
        uint256 under;
        uint256 over;
        for (uint256 l = 0; l < LEGS; ++l) {
            uint256 have = values[l] * ONE;
            uint256 want = targets[l] * total;
            if (have < want && (want - have) / ONE > under) {
                under = (want - have) / ONE;
                legIn = l;
            }
            if (have > want && (have - want) / ONE > over) {
                over = (have - want) / ONE;
                legOut = l;
            }
        }
        require(under > 0 && over > 0 && legIn != legOut, "no toward-target fill at this health factor");
        uint256 x = Math.min(Math.min(under, over), Math.min((MAX_SHIFT_BPS * total) / BPS, values[legOut]));
        amountIn = x / units[legIn];
        require(amountIn > 0, "fill rounds to zero");
    }

    function _takerTraitsAndData() internal view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.taker = taker;
        args.isExactIn = true;
        args.useTransferFromAndAquaPush = true;
        args.instructionsArgs = hex"c0ffee";
        return TakerTraitsLib.build(args);
    }

    /// @dev `Curve.weightsAt` reads calldata; this is the external hop that gives it some.
    function weightsAt(bytes calldata curve, uint256 hf) external pure returns (uint256[] memory) {
        return Curve.weightsAt(curve, hf);
    }
}
