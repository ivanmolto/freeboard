// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraits } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { Addresses } from "../src/constants/Addresses.sol";
import { FreeboardExtruction } from "../src/FreeboardExtruction.sol";
import { IPoolAddressesProvider } from "../src/interfaces/IAaveV3.sol";
import { IAaveV3Oracle } from "../src/interfaces/IAaveV3Oracle.sol";

import { IAaveProtocolDataProvider, IAaveV3PoolFixture } from "../test/utils/AaveFixtures.sol";
import { Curves } from "../test/utils/Curves.sol";
import { FreeboardLens } from "../test/utils/FreeboardLens.sol";
import { IAaveOracle, IACLManager, WarpedPriceSource } from "../test/utils/OracleWarp.sol";
import { ProgramBuilder } from "../test/utils/ProgramBuilder.sol";

/// @title StageWorld — T23's world, staged on a running anvil fork for the keeper agent (T24b)
/// @notice `PricePathEngine` builds Alice's world with cheatcodes inside one EVM; the agent is a
///         separate process that needs the same world on a node it can send transactions to. This
///         script builds it with TRANSACTIONS — broadcast to anvil from its unlocked accounts —
///         and writes `agent/world.json`, the only thing the agent reads about the world.
///
///         Same numbers as T23: Alice supplies 100 WETH and 3 WBTC, borrows USDC to HF 2.00,
///         ships 10 WETH / 0.3 WBTC / 30,000 USDC under the Freeboard program with a 500 bps cap,
///         approves Aqua; the taker holds a float and approves the router; then the oracle is
///         warped so Alice lands on `STAGE_HF` (default 1.30) — the rung where the target has
///         moved well away from the shipped basket and a deleverage is on offer.
///
/// @dev Run through `agent/stage.sh`, which first funds the accounts over RPC
///      (`anvil_dealERC20`, `anvil_setBalance` — the transaction-world equivalents of `deal`) and
///      then runs this with `--broadcast --unlocked`. Every state change here is a transaction
///      from an account anvil impersonates (`--auto-impersonate`): the ACL admin's grant is a
///      real `addAssetListingAdmin`, the warp is a real `setAssetSources` to a real
///      `WarpedPriceSource` — Aave's own feed-migration path, as in `OracleWarp`.
///
/// @dev The accounts are anvil's default mnemonic accounts 0, 1, 2. Their keys are printed by
///      anvil at start-up; the taker's is what the agent signs fills with, and it reaches the
///      agent only through the Key Ring (`agent/README.md`).
contract StageWorld is Script {
    address internal constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant ALICE = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant TAKER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    address internal constant ROUTER = Addresses.AQUA_SWAP_VM_ROUTER;
    address internal constant AQUA = Addresses.AQUA;
    address internal constant WETH = Addresses.WETH;
    address internal constant WBTC = Addresses.WBTC;
    address internal constant USDC = Addresses.USDC;

    IAaveV3PoolFixture internal constant POOL = IAaveV3PoolFixture(Addresses.AAVE_V3_POOL);
    IPoolAddressesProvider internal constant PROVIDER =
        IPoolAddressesProvider(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER);
    IAaveOracle internal constant ORACLE = IAaveOracle(Addresses.AAVE_V3_ORACLE);
    IACLManager internal constant ACL = IACLManager(Addresses.AAVE_V3_ACL_MANAGER);

    uint256 internal constant ONE = 1e18;
    uint256 internal constant VARIABLE_RATE = 2;

    /// @dev T23's numbers, verbatim (`script/PricePath.s.sol`).
    uint256 internal constant AAVE_WETH_COLLATERAL = 100e18;
    uint256 internal constant AAVE_WBTC_COLLATERAL = 3e8;
    uint256 internal constant SHIPPED_WETH = 10 ether;
    uint256 internal constant SHIPPED_WBTC = 0.3e8;
    uint256 internal constant SHIPPED_USDC = 30_000e6;
    uint16 internal constant MAX_SHIFT_BPS = 500;
    uint256 internal constant TAKER_WETH = 100 ether;
    uint256 internal constant TAKER_WBTC = 10e8;
    uint256 internal constant TAKER_USDC = 1_000_000e6;
    bytes internal constant INSTRUCTIONS_ARGS = hex"c0ffee";

    function run() external {
        require(block.chainid == Addresses.CHAIN_ID, "not an Ethereum mainnet fork");
        require(ROUTER.code.length == Addresses.ROUTER_RUNTIME_SIZE, "deployed AquaSwapVMRouter runtime size");
        require(AQUA.code.length == Addresses.AQUA_RUNTIME_SIZE, "deployed Aqua runtime size");
        uint256 targetHf = vm.envOr("STAGE_HF", uint256(1.3e18));

        // agent/stage.sh dealt these over RPC before running the script.
        require(IERC20(WETH).balanceOf(ALICE) >= AAVE_WETH_COLLATERAL + SHIPPED_WETH, "stage.sh: deal WETH to alice");
        require(IERC20(WBTC).balanceOf(ALICE) >= AAVE_WBTC_COLLATERAL + SHIPPED_WBTC, "stage.sh: deal WBTC to alice");
        require(IERC20(WETH).balanceOf(TAKER) >= TAKER_WETH, "stage.sh: deal WETH to taker");
        require(IERC20(WBTC).balanceOf(TAKER) >= TAKER_WBTC, "stage.sh: deal WBTC to taker");
        require(IERC20(USDC).balanceOf(TAKER) >= TAKER_USDC, "stage.sh: deal USDC to taker");

        // 1. The pricing contract and the agent's read lens, from the deployer.
        vm.startBroadcast(DEPLOYER);
        FreeboardExtruction freeboard = new FreeboardExtruction();
        FreeboardLens lens = new FreeboardLens();
        vm.stopBroadcast();

        // 2. Alice's Aave position: supply both collaterals, borrow USDC to HF 2.00.
        IAaveProtocolDataProvider dataProvider = IAaveProtocolDataProvider(PROVIDER.getPoolDataProvider());
        (address aWeth,,) = dataProvider.getReserveTokensAddresses(WETH);
        (address aWbtc,,) = dataProvider.getReserveTokensAddresses(WBTC);

        vm.startBroadcast(ALICE);
        IERC20(WETH).approve(Addresses.AAVE_V3_POOL, AAVE_WETH_COLLATERAL);
        POOL.supply(WETH, AAVE_WETH_COLLATERAL, ALICE, 0);
        IERC20(WBTC).approve(Addresses.AAVE_V3_POOL, AAVE_WBTC_COLLATERAL);
        POOL.supply(WBTC, AAVE_WBTC_COLLATERAL, ALICE, 0);
        uint256 borrowed = _borrowAmount(aWeth, aWbtc, 2e18);
        POOL.borrow(USDC, borrowed, VARIABLE_RATE, 0, ALICE);
        require(borrowed >= SHIPPED_USDC, "borrow smaller than the USDC leg");

        // 3. Her Freeboard basket, shipped through the DEPLOYED Aqua, and the allowance that
        //    makes it fillable (VERIFIED FACTS: ship() succeeds with zero allowance).
        address[] memory tokens = Curves.freeboardTokens();
        ProgramBuilder.Position memory position = ProgramBuilder.freeboardPosition(
            ALICE, address(freeboard), Curves.freeboard(), tokens, MAX_SHIFT_BPS
        );
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = SHIPPED_WETH;
        amounts[1] = SHIPPED_WBTC;
        amounts[2] = SHIPPED_USDC;
        bytes32 shippedHash = IAqua(AQUA).ship(ROUTER, position.strategy, tokens, amounts);
        for (uint256 l = 0; l < tokens.length; ++l) {
            IERC20(tokens[l]).approve(AQUA, type(uint256).max);
        }
        vm.stopBroadcast();

        require(shippedHash == position.strategyHash, "ship() did not return keccak256(strategy)");
        require(ISwapVM(ROUTER).hash(position.order) == position.strategyHash, "router hash != strategy hash");

        // 4. The taker's float is already dealt; approve the router for every leg.
        vm.startBroadcast(TAKER);
        for (uint256 l = 0; l < tokens.length; ++l) {
            IERC20(tokens[l]).approve(ROUTER, type(uint256).max);
        }
        vm.stopBroadcast();

        // 5. Warp both collateral prices so Alice lands on the staged rung. Same maths as
        //    `PricePathEngine._warpTo`; the same transaction shape as `OracleWarp._install`.
        uint256 hf = _healthFactor(ALICE);
        uint256 wad = (targetHf * ONE) / hf;
        _warp(wad);
        uint256 stagedHf = _healthFactor(ALICE);
        console.log("staged: alice HF", stagedHf, "target", targetHf);

        // 6. world.json — everything the agent knows about the world, from these bytes.
        _writeWorld(address(freeboard), address(lens), tokens, position, stagedHf);
    }

    /// @dev `GenericLogic` inverted, as T8 and T23 do: `debtBase = SUM(collateral_i * lt_i) / HF`.
    function _borrowAmount(address aWeth, address aWbtc, uint256 targetHf) private view returns (uint256) {
        IAaveV3Oracle oracle = IAaveV3Oracle(PROVIDER.getPriceOracle());
        uint256 wethBase = (IERC20(aWeth).balanceOf(ALICE) * oracle.getAssetPrice(WETH)) / 1e18;
        uint256 wbtcBase = (IERC20(aWbtc).balanceOf(ALICE) * oracle.getAssetPrice(WBTC)) / 1e8;
        uint256 weighted = wethBase * Addresses.LT_WETH_BPS + wbtcBase * Addresses.LT_WBTC_BPS;
        uint256 debtBase = (weighted * 1e14) / targetHf;
        return (debtBase * 1e6) / oracle.getAssetPrice(USDC);
    }

    /// @dev The ACL admin grants the deployer `ASSET_LISTING_ADMIN_ROLE`; the deployer installs a
    ///      `WarpedPriceSource` per collateral at the scaled price through `setAssetSources`.
    function _warp(uint256 wad) private {
        bytes32 role = ACL.ASSET_LISTING_ADMIN_ROLE();
        require(ACL.getRoleAdmin(role) == bytes32(0), "role admin is no longer DEFAULT_ADMIN_ROLE");
        require(ACL.hasRole(bytes32(0), Addresses.AAVE_V3_ACL_ADMIN), "ACL admin lost DEFAULT_ADMIN_ROLE");

        vm.startBroadcast(Addresses.AAVE_V3_ACL_ADMIN);
        ACL.addAssetListingAdmin(DEPLOYER);
        vm.stopBroadcast();

        address[] memory assets = new address[](2);
        assets[0] = WETH;
        assets[1] = WBTC;
        address[] memory sources = new address[](2);

        vm.startBroadcast(DEPLOYER);
        for (uint256 i = 0; i < assets.length; ++i) {
            uint256 price = (ORACLE.getAssetPrice(assets[i]) * wad) / ONE;
            require(price > 0 && price <= uint256(type(int256).max), "warped price out of range");
            // forge-lint: disable-next-line(unsafe-typecast)
            sources[i] = address(new WarpedPriceSource(assets[i], ORACLE.getSourceOfAsset(assets[i]), int256(price)));
        }
        ORACLE.setAssetSources(assets, sources);
        vm.stopBroadcast();

        for (uint256 i = 0; i < assets.length; ++i) {
            require(ORACLE.getSourceOfAsset(assets[i]) == sources[i], "setAssetSources did not take");
        }
    }

    function _healthFactor(address who) private view returns (uint256 hf) {
        (,,,,, hf) = POOL.getUserAccountData(who);
    }

    function _takerTraitsAndData() private pure returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.taker = TAKER;
        args.isExactIn = true;
        args.useTransferFromAndAquaPush = true;
        args.instructionsArgs = INSTRUCTIONS_ARGS;
        return TakerTraitsLib.build(args);
    }

    function _writeWorld(
        address freeboard,
        address lens,
        address[] memory tokens,
        ProgramBuilder.Position memory position,
        uint256 stagedHf
    )
        private
    {
        string memory order = "order";
        vm.serializeAddress(order, "maker", position.order.maker);
        vm.serializeUint(order, "traits", MakerTraits.unwrap(position.order.traits));
        string memory orderJson = vm.serializeBytes(order, "data", position.order.data);

        string memory world = "world";
        vm.serializeUint(world, "chainId", block.chainid);
        vm.serializeUint(world, "forkBlock", block.number);
        vm.serializeAddress(world, "router", ROUTER);
        vm.serializeAddress(world, "aqua", AQUA);
        vm.serializeAddress(world, "pool", Addresses.AAVE_V3_POOL);
        vm.serializeAddress(world, "extruction", freeboard);
        vm.serializeAddress(world, "lens", lens);
        vm.serializeAddress(world, "maker", ALICE);
        vm.serializeAddress(world, "taker", TAKER);
        vm.serializeAddress(world, "tokens", tokens);
        string[] memory symbols = new string[](3);
        symbols[0] = "WETH";
        symbols[1] = "WBTC";
        symbols[2] = "USDC";
        vm.serializeString(world, "symbols", symbols);
        vm.serializeBytes32(world, "strategyHash", position.strategyHash);
        vm.serializeString(world, "order", orderJson);
        vm.serializeBytes(world, "takerTraitsAndData", _takerTraitsAndData());
        vm.serializeBytes(world, "curve", Curves.freeboard());
        vm.serializeUint(world, "maxShiftBps", MAX_SHIFT_BPS);
        string memory json = vm.serializeUint(world, "stagedHealthFactor", stagedHf);
        vm.writeJson(json, "agent/world.json");
        console.log("wrote agent/world.json");
    }
}
