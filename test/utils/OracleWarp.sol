// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";

import { Addresses } from "../../src/constants/Addresses.sol";

/// @notice `AaveOracle`, quoted from aave-dao/aave-v3-origin `src/contracts/misc/AaveOracle.sol`.
/// @dev The only method the oracle calls on a source is `latestAnswer()`:
///
///        function getAssetPrice(address asset) public view override returns (uint256) {
///          AggregatorInterface source = assetsSources[asset];
///          if (asset == BASE_CURRENCY) { return BASE_CURRENCY_UNIT; }
///          else if (address(source) == address(0)) { return _fallbackOracle.getAssetPrice(asset); }
///          else {
///            int256 price = source.latestAnswer();
///            if (price > 0) { return uint256(price); }
///            else { return _fallbackOracle.getAssetPrice(asset); }
///          }
///        }
///
///      `setAssetSources` is `onlyAssetListingOrPoolAdmins`.
interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
    function getSourceOfAsset(address asset) external view returns (address);
    function getFallbackOracle() external view returns (address);
    function setAssetSources(address[] calldata assets, address[] calldata sources) external;
    function BASE_CURRENCY() external view returns (address);
    function BASE_CURRENCY_UNIT() external view returns (uint256);
    function ADDRESSES_PROVIDER() external view returns (address);
}

/// @notice `ACLManager`, quoted from `src/contracts/interfaces/IACLManager.sol`.
interface IACLManager {
    function ASSET_LISTING_ADMIN_ROLE() external view returns (bytes32);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function addAssetListingAdmin(address admin) external;
    function isAssetListingAdmin(address admin) external view returns (bool);
}

/// @title WarpedPriceSource — a settable price source that `OracleWarp` installs on `AaveOracle`
/// @dev A real contract, not a `vm.mockCall` shim, so it behaves identically under STATICCALL
///      and at any call depth — which is where Freeboard reads HF from. Answers are 8-decimal USD.
contract WarpedPriceSource {
    /// @dev The feed this replaced, so `OracleWarp.release` can put it back.
    address public immutable ORIGINAL_SOURCE;
    address public immutable ASSET;

    /// @dev `AaveOracle` never calls this; it is here so a trace reads correctly.
    uint8 public constant decimals = 8;

    /// @dev Marker `OracleWarp.isWarped` looks for.
    bytes32 public constant FREEBOARD_ORACLE_WARP = keccak256("freeboard.oracle-warp.v1");

    int256 private _answer;

    constructor(address asset, address originalSource, int256 initialAnswer) {
        ASSET = asset;
        ORIGINAL_SOURCE = originalSource;
        _answer = initialAnswer;
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    /// @dev Any int256 on purpose: `0` and negatives are how `AaveOracle` is made to fall
    ///      through to its fallback oracle, which is `address(0)` on mainnet — see `breakPrice`.
    function set(int256 newAnswer) external {
        _answer = newAnswer;
    }
}

/// @title OracleWarp — the ONE way anything in this repo moves an Aave price
/// @notice Every price-path test drives health factor through here. A price change propagates
///         through the real `AaveOracle`, the real `Pool` and the real `GenericLogic`.
///
/// @dev Installs a fresh `WarpedPriceSource` via `AaveOracle.setAssetSources` — Aave's own path
///      for a feed migration — rather than `vm.mockCall` (a shim in the path Freeboard staticcalls,
///      and it hides that a zero price is a revert) or `vm.etch` over the live aggregator (keeps
///      the victim's dirty storage).
///
///      `setAssetSources` needs `ASSET_LISTING_ADMIN_ROLE`. `_authorize` pranks the ACL admin
///      (`provider.getACLAdmin()`, holder of `DEFAULT_ADMIN_ROLE`) to grant it to the caller,
///      asserting both preconditions first so an Aave governance change fails loudly.
///
///      All prices are `AaveOracle` base-currency units: 1e8 USD.
library OracleWarp {
    /// @dev The forge-std cheatcode address; a library cannot inherit `Test`.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    IAaveOracle private constant ORACLE = IAaveOracle(Addresses.AAVE_V3_ORACLE);
    IACLManager private constant ACL = IACLManager(Addresses.AAVE_V3_ACL_MANAGER);

    // -----------------------------------------------------------------------------------
    // Reading
    // -----------------------------------------------------------------------------------

    /// @notice The price Aave uses for `asset` right now, 1e8 USD. Reflects a warp and a live
    ///         feed identically because it goes through `AaveOracle`.
    function priceOf(address asset) internal view returns (uint256) {
        return ORACLE.getAssetPrice(asset);
    }

    /// @notice True once a `WarpedPriceSource` is installed for `asset`.
    function isWarped(address asset) internal view returns (bool) {
        address source = ORACLE.getSourceOfAsset(asset);
        if (source.code.length == 0) {
            return false;
        }
        try WarpedPriceSource(source).FREEBOARD_ORACLE_WARP() returns (bytes32 marker) {
            return marker == keccak256("freeboard.oracle-warp.v1");
        } catch {
            return false;
        }
    }

    /// @notice The installed `WarpedPriceSource` for `asset`; reverts if there is none.
    function sourceOf(address asset) internal view returns (WarpedPriceSource) {
        require(isWarped(asset), "OracleWarp: asset not seized");
        return WarpedPriceSource(ORACLE.getSourceOfAsset(asset));
    }

    // -----------------------------------------------------------------------------------
    // Writing
    // -----------------------------------------------------------------------------------

    /// @notice Take over `asset`'s feed WITHOUT changing its price. Idempotent.
    function seize(address asset) internal returns (WarpedPriceSource) {
        if (isWarped(asset)) {
            return WarpedPriceSource(ORACLE.getSourceOfAsset(asset));
        }

        address original = ORACLE.getSourceOfAsset(asset);
        uint256 livePrice = ORACLE.getAssetPrice(asset);
        require(livePrice > 0 && livePrice <= uint256(type(int256).max), "OracleWarp: bad live price");

        // forge-lint: disable-next-line(unsafe-typecast)
        WarpedPriceSource warped = new WarpedPriceSource(asset, original, int256(livePrice));
        vm.label(address(warped), "OracleWarp:source");
        _install(asset, address(warped));
        return warped;
    }

    /// @notice Set `asset`'s price to `price` (1e8 USD). Seizes first if needed.
    function setPrice(address asset, uint256 price) internal {
        require(price <= uint256(type(int256).max), "OracleWarp: price overflows int256");
        // forge-lint: disable-next-line(unsafe-typecast)
        seize(asset).set(int256(price));
    }

    /// @notice Multiply `asset`'s current price by `wad / 1e18`.
    /// @dev WAD, not bps, is the primitive: HF targets are WADs, and rounding `target / current`
    ///      to whole bps injects up to 1e-4 relative error — far above the 1e-12 of the price grid.
    ///      Scaling every collateral leg by the same factor (debt untouched) scales HF by exactly
    ///      that factor, which is what lets the T8 walk land on its targets.
    function scalePriceWad(address asset, uint256 wad) internal returns (uint256 newPrice) {
        newPrice = (priceOf(asset) * wad) / 1e18;
        setPrice(asset, newPrice);
    }

    function scalePriceWad(address[] memory assets, uint256 wad) internal {
        for (uint256 i = 0; i < assets.length; ++i) {
            scalePriceWad(assets[i], wad);
        }
    }

    /// @notice `scalePriceWad` for factors that are exact in bps.
    function scalePriceBps(address asset, uint256 bps) internal returns (uint256 newPrice) {
        return scalePriceWad(asset, bps * 1e14);
    }

    function scalePriceBps(address[] memory assets, uint256 bps) internal {
        scalePriceWad(assets, bps * 1e14);
    }

    /// @notice Make `asset`'s price unreadable the way Aave defines it: `latestAnswer() == 0`.
    /// @dev `AaveOracle` then calls `_fallbackOracle.getAssetPrice`, which is `address(0)` on
    ///      mainnet (asserted in `test_Revert_WhenACollateralPriceIsZero`), so the decode reverts.
    ///      Every reader of that reserve reverts with it — `getUserAccountData` and
    ///      `liquidationCall` alike, which is why Freeboard may safely revert on an unreadable HF.
    function breakPrice(address asset) internal {
        seize(asset).set(0);
    }

    /// @notice Put `asset`'s original feed back.
    function release(address asset) internal {
        WarpedPriceSource warped = sourceOf(asset);
        require(warped.ASSET() == asset, "OracleWarp: source/asset mismatch");
        _install(asset, warped.ORIGINAL_SOURCE());
    }

    // -----------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------

    function _install(address asset, address source) private {
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = asset;
        sources[0] = source;

        _authorize();
        ORACLE.setAssetSources(assets, sources);

        require(ORACLE.getSourceOfAsset(asset) == source, "OracleWarp: setAssetSources did not take");
    }

    /// @dev Grants `ASSET_LISTING_ADMIN_ROLE` to the caller, once.
    function _authorize() private {
        if (ACL.isAssetListingAdmin(address(this))) {
            return;
        }

        bytes32 role = ACL.ASSET_LISTING_ADMIN_ROLE();
        require(ACL.getRoleAdmin(role) == bytes32(0), "OracleWarp: role admin is no longer DEFAULT_ADMIN_ROLE");
        require(ACL.hasRole(bytes32(0), Addresses.AAVE_V3_ACL_ADMIN), "OracleWarp: ACL admin lost DEFAULT_ADMIN_ROLE");

        vm.prank(Addresses.AAVE_V3_ACL_ADMIN);
        ACL.addAssetListingAdmin(address(this));

        require(ACL.isAssetListingAdmin(address(this)), "OracleWarp: grant did not take");
    }
}
