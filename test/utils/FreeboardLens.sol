// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { Addresses } from "../../src/constants/Addresses.sol";
import { IPoolAddressesProvider } from "../../src/interfaces/IAaveV3.sol";
import { IAaveV3Oracle } from "../../src/interfaces/IAaveV3Oracle.sol";
import { IAaveV3Pool } from "../../src/interfaces/IAaveV3Pool.sol";
import { BasketDistance } from "../../src/libs/BasketDistance.sol";
import { Curve } from "../../src/libs/Curve.sol";

/// @title FreeboardLens — one read of a Freeboard position, for the keeper agent (T24b)
/// @notice Deployed on the anvil fork by `script/StageWorld.s.sol`. The agent's `readPosition`
///         tool is one `eth_call` here. The maths is the repo's own — `Curve.weightsAt`,
///         `BasketDistance.distance`, the value units `FreeboardExtruction._unit` defines — so
///         the agent reads the same target the extruction prices against, not a TypeScript
///         re-derivation that could drift from it.
/// @dev Test tooling, not product. Nothing under `src/` depends on it and the extruction does
///      not know it exists; it holds no state and moves no tokens.
contract FreeboardLens {
    /// @param healthFactor Aave's, WAD; `type(uint256).max` for a maker with no debt.
    /// @param prices `AaveOracle.getAssetPrice`, 1e8 USD, per leg.
    /// @param balances Aqua `rawBalances` under the strategy, token units, per leg.
    /// @param units Value units per wei: `price * 10 ** (18 - decimals)`, per leg.
    /// @param values `balance * unit`, per leg. One US dollar is 1e26 of them.
    /// @param total The basket's value, `sum(values)`.
    /// @param targets `curve(healthFactor)`, WAD shares summing to 1e18.
    /// @param distance Weighted L1 distance from `values` to `targets`, WAD.
    struct Position {
        uint256 healthFactor;
        uint256[] prices;
        uint256[] balances;
        uint256[] units;
        uint256[] values;
        uint256 total;
        uint256[] targets;
        uint256 distance;
    }

    IAaveV3Pool private constant POOL = IAaveV3Pool(Addresses.AAVE_V3_POOL);
    IPoolAddressesProvider private constant PROVIDER =
        IPoolAddressesProvider(Addresses.AAVE_V3_POOL_ADDRESSES_PROVIDER);

    /// @notice The position as the extruction would see it in this block.
    /// @param maker The borrower; her health factor and her Aqua balances are read.
    /// @param strategyHash The shipped strategy's hash — `keccak256(abi.encode(order))`.
    /// @param tokens The basket legs, in curve leg order.
    /// @param curve The curve bytes the program carries (`Curve.encode`).
    function read(
        address maker,
        bytes32 strategyHash,
        address[] calldata tokens,
        bytes calldata curve
    )
        external
        view
        returns (Position memory p)
    {
        (,,,,, p.healthFactor) = POOL.getUserAccountData(maker);
        IAaveV3Oracle oracle = IAaveV3Oracle(PROVIDER.getPriceOracle());

        uint256 n = tokens.length;
        p.prices = new uint256[](n);
        p.balances = new uint256[](n);
        p.units = new uint256[](n);
        p.values = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            p.prices[i] = oracle.getAssetPrice(tokens[i]);
            (uint248 balance,) =
                IAqua(Addresses.AQUA).rawBalances(maker, Addresses.AQUA_SWAP_VM_ROUTER, strategyHash, tokens[i]);
            p.balances[i] = balance;
            p.units[i] = p.prices[i] * 10 ** (18 - IERC20Metadata(tokens[i]).decimals());
            p.values[i] = p.balances[i] * p.units[i];
            p.total += p.values[i];
        }

        p.targets = Curve.weightsAt(curve, p.healthFactor);
        p.distance = BasketDistance.distance(p.values, p.targets);
    }
}
