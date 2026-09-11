// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Addresses } from "../src/constants/Addresses.sol";
import { FreeboardLens } from "../test/utils/FreeboardLens.sol";
import { IAaveOracle, IACLManager, OracleWarp, WarpedPriceSource } from "../test/utils/OracleWarp.sol";
import { PricePathEngine } from "./PricePath.s.sol";

/// @title LivePricePathWalker — T23's walk, as transactions on a running anvil fork (T29)
/// @notice The SAME engine as `script/PricePath.s.sol` — the same rungs, the same taker rule, the
///         same fill, the same recording — with its three chain primitives overridden so that
///         every write is a transaction broadcast to the node instead of a cheatcode: `_as` is
///         `vm.startBroadcast` instead of `vm.startPrank`, `_deal` checks a balance the shell
///         dealt over RPC instead of setting it, and `_warpTo` installs the `WarpedPriceSource`s
///         through `setAssetSources` from an account the ACL admin granted, as `OracleWarp` does
///         under a prank. Nothing about the path is restated here; the walk is the engine's.
///
/// @dev THE WALK REPRODUCES THE COMMITTED ARTIFACT. The extruction is deployed from the engine's
///      fixed deployer at nonce 0, so it lands on the same address as in the tests and the
///      strategy hash is `results/price-path.txt`'s; Alice and the taker are the engine's
///      `makeAddr` labels, funded by `ui/walk.sh`; the fork block, the shipped amounts, the
///      rungs and the fill rule are the engine's. So the report this walk writes must equal
///      `results/price-path.txt` line for line, and the chain must end holding the artifact's
///      final basket — `ui/walk.sh` checks both after the broadcast, against the node, not the
///      simulation.
///
/// @dev PACED FOR A PAGE TO WATCH. Run with `--slow` against an anvil started with
///      `--block-time`, each transaction waits for its own block, so a page polling the node sees
///      the health factor fall and the target slide rung by rung rather than in one jump.
contract LivePricePathWalker is PricePathEngine {
    IAaveOracle internal constant ORACLE = IAaveOracle(Addresses.AAVE_V3_ORACLE);
    IACLManager internal constant ACL = IACLManager(Addresses.AAVE_V3_ACL_MANAGER);

    FreeboardLens internal lens;

    // -----------------------------------------------------------------------------------
    // The three primitives, as transactions
    // -----------------------------------------------------------------------------------

    function _as(address who) internal override {
        vm.startBroadcast(who);
    }

    function _done() internal override {
        vm.stopBroadcast();
    }

    /// @dev The engine's `deal` SETS a balance; here the shell dealt beforehand, so the check is
    ///      "at least": Alice's wallet holds her collateral plus her shipped legs before she
    ///      supplies, and the taker its whole float.
    function _deal(address token, address who, uint256 amount) internal view override {
        require(
            IERC20(token).balanceOf(who) >= amount,
            string.concat("ui/walk.sh must deal ", vm.toString(amount), " of ", vm.toString(token), " to ", vm.toString(who))
        );
    }

    /// @dev `OracleWarp.scalePriceWad` as transactions, the same arithmetic in the same order:
    ///      per collateral, `newPrice = priceOf(asset) * wad / 1e18` read through `AaveOracle`
    ///      before anything is installed, then a `WarpedPriceSource` at that price on the first
    ///      rung and `set` on every later one. The grant goes to the deployer rather than to
    ///      `address(this)`, which is a simulation-only contract with no code on the node.
    function _warpTo(uint256 targetHf) internal override {
        uint256 wad = (targetHf * ONE) / healthFactorOf(alice);
        address[] memory assets = new address[](2);
        assets[0] = WETH;
        assets[1] = WBTC;

        if (!OracleWarp.isWarped(WETH)) {
            bytes32 role = ACL.ASSET_LISTING_ADMIN_ROLE();
            require(ACL.getRoleAdmin(role) == bytes32(0), "role admin is no longer DEFAULT_ADMIN_ROLE");
            require(ACL.hasRole(bytes32(0), Addresses.AAVE_V3_ACL_ADMIN), "ACL admin lost DEFAULT_ADMIN_ROLE");
            _as(Addresses.AAVE_V3_ACL_ADMIN);
            ACL.addAssetListingAdmin(deployer());
            _done();

            address[] memory sources = new address[](2);
            _as(deployer());
            for (uint256 i = 0; i < assets.length; ++i) {
                uint256 price = (ORACLE.getAssetPrice(assets[i]) * wad) / ONE;
                require(price > 0 && price <= uint256(type(int256).max), "warped price out of range");
                // forge-lint: disable-next-line(unsafe-typecast)
                sources[i] = address(new WarpedPriceSource(assets[i], ORACLE.getSourceOfAsset(assets[i]), int256(price)));
            }
            ORACLE.setAssetSources(assets, sources);
            _done();
            for (uint256 i = 0; i < assets.length; ++i) {
                require(ORACLE.getSourceOfAsset(assets[i]) == sources[i], "setAssetSources did not take");
            }
            return;
        }

        _as(deployer());
        for (uint256 i = 0; i < assets.length; ++i) {
            uint256 price = (ORACLE.getAssetPrice(assets[i]) * wad) / ONE;
            require(price > 0 && price <= uint256(type(int256).max), "warped price out of range");
            // forge-lint: disable-next-line(unsafe-typecast)
            OracleWarp.sourceOf(assets[i]).set(int256(price));
        }
        _done();
    }

    // -----------------------------------------------------------------------------------
    // The walk
    // -----------------------------------------------------------------------------------

    /// @notice Deploy the extruction (nonce 0) and the lens (nonce 1) from the fixed deployer,
    ///         then walk. Returns the report and the JSON, both from the engine.
    function walkLive() external returns (string memory report_, string memory json_) {
        deployExtruction();
        _as(deployer());
        lens = new FreeboardLens();
        _done();
        require(address(lens) == lensAddress(), "the lens did not land on lensAddress(): deployer nonce is not 1");

        Run memory run = walk();
        return (report(run), json(run));
    }
}

/// @title LivePricePath — `forge script script/LivePricePath.s.sol --rpc-url <anvil> --broadcast --unlocked --slow`
/// @notice Run through `ui/walk.sh`, which funds the engine's accounts over RPC first and checks
///         the chain against the committed artifact afterwards. Refuses anything but a mainnet
///         fork with the deployed router and Aqua on it.
contract LivePricePath is Script {
    function run() external {
        require(block.chainid == Addresses.CHAIN_ID, "not an Ethereum mainnet fork");
        require(
            Addresses.AQUA_SWAP_VM_ROUTER.code.length == Addresses.ROUTER_RUNTIME_SIZE,
            "deployed AquaSwapVMRouter runtime size"
        );
        require(Addresses.AQUA.code.length == Addresses.AQUA_RUNTIME_SIZE, "deployed Aqua runtime size");

        (string memory report_, string memory data) = new LivePricePathWalker().walkLive();
        vm.writeFile("results/live-path.txt", report_);
        vm.writeFile("results/live-path.json", data);
        console.log(report_);
    }
}
