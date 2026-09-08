// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Addresses } from "../../src/constants/Addresses.sol";

/// @title Mocks — the four things the pricing core reads, as settable stand-ins for unit tests
/// @notice `FreeboardExtruction` reaches Aave, its oracle, the tokens and Aqua through
///         compile-time constant addresses. The unit tests `vm.etch` these contracts' runtime
///         code AT those addresses (no fork), so the extruction under test is byte-for-byte the
///         one the fork tests run — nothing is injected, and every read goes where it goes on
///         mainnet. Each mock answers exactly the selector the extruction calls and nothing else.

/// @dev `getUserAccountData(user)`: six words, the sixth the health factor. An account never
///      set answers Aave's no-debt sentinel, as the real pool does for an untouched account.
contract MockAaveV3Pool {
    mapping(address => uint256) private _healthFactor;

    function setHealthFactor(address user, uint256 healthFactor) external {
        _healthFactor[user] = healthFactor;
    }

    function getUserAccountData(address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256 healthFactor)
    {
        healthFactor = _healthFactor[user];
        if (healthFactor == 0) {
            healthFactor = type(uint256).max;
        }
        return (0, 0, 0, 0, 0, healthFactor);
    }
}

/// @dev A pool that CANNOT compute a health factor: `getUserAccountData` reverts, for every
///      account, with whatever data was set — empty by default. Empty is the shape T8 found on
///      mainnet (`test/fork/AaveHF.t.sol`, "The revert taxonomy" (a)/(b)): a zero price makes
///      `AaveOracle` fall through to its fallback oracle, which is `address(0)`, and the decode
///      of empty returndata reverts with no data at all. A reasoned revert is shape (c), a
///      price source that itself reverts and bubbles its reason through the oracle and the pool.
///      Etched over `MockAaveV3Pool` at the pool's address for T16 (`test/unit/FailSafe.t.sol`).
contract MockUnreadableAaveV3Pool {
    bytes private _revertData;

    function setRevertData(bytes calldata revertData) external {
        _revertData = revertData;
    }

    function getUserAccountData(address) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        bytes memory revertData = _revertData;
        assembly ("memory-safe") {
            revert(add(revertData, 32), mload(revertData))
        }
    }
}

/// @dev `getPriceOracle()`: names the oracle, as the real provider does for the real Pool.
contract MockPoolAddressesProvider {
    function getPriceOracle() external pure returns (address) {
        return Addresses.AAVE_V3_ORACLE;
    }
}

/// @dev `getAssetPrice(asset)`: 1e8 USD, settable. Unset is zero, which the extruction refuses.
contract MockAaveOracle {
    mapping(address => uint256) private _price;

    function setPrice(address asset, uint256 price) external {
        _price[asset] = price;
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return _price[asset];
    }
}

/// @dev `decimals()`, fixed at construction so that etching the runtime carries the value.
contract MockToken {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

/// @dev `rawBalances(maker, app, strategyHash, token)`: the packed `(uint248, uint8)` Aqua
///      answers, settable per key. Unset is `(0, 0)` — a token outside any strategy.
contract MockAqua {
    struct Entry {
        uint248 balance;
        uint8 tokensCount;
    }

    mapping(address => mapping(address => mapping(bytes32 => mapping(address => Entry)))) private _entries;

    function setRawBalance(
        address maker,
        address app,
        bytes32 strategyHash,
        address token,
        uint248 balance,
        uint8 tokensCount
    )
        external
    {
        _entries[maker][app][strategyHash][token] = Entry(balance, tokensCount);
    }

    function rawBalances(
        address maker,
        address app,
        bytes32 strategyHash,
        address token
    )
        external
        view
        returns (uint248 balance, uint8 tokensCount)
    {
        Entry storage e = _entries[maker][app][strategyHash][token];
        return (e.balance, e.tokensCount);
    }
}
