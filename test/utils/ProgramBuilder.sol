// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";

/// @title ProgramBuilder
/// @notice Builds an Aqua-path position — the `ship()` calldata and the executed order — from
///         ONE set of bytes, so the two cannot drift apart.
///
/// @dev WHY THIS FILE EXISTS. On the Aqua path there are two hashes that MUST be the same
///      number, derived by two different contracts from two different inputs:
///
///      1. `Aqua.ship` keys the maker's balances by the hash of the raw strategy blob
///         (aqua v1.0.0, `src/Aqua.sol:40-41`):
///
///           function ship(address app, bytes calldata strategy, address[] calldata tokens, uint256[] calldata amounts) external returns(bytes32 strategyHash) {
///               strategyHash = keccak256(strategy);
///
///         and stores into `_balances[msg.sender][app][strategyHash][tokens[i]]`
///         (`Aqua.sol:47`), i.e. keyed by (maker, app, strategyHash, token).
///
///      2. `SwapVM.hash` derives the order hash, and for an Aqua order it is NOT the EIP-712
///         digest but a plain ABI hash (swap-vm v1.0.2, `src/SwapVM.sol:97-100`):
///
///           function hash(ISwapVM.Order calldata order) public view returns (bytes32) {
///               if (order.traits.useAquaInsteadOfSignature()) {
///                   return keccak256(abi.encode(order));
///               }
///
///      The router then looks the maker's balances up under that order hash, with itself as
///      the app (`SwapVM.sol:193-194`):
///
///           if (order.traits.useAquaInsteadOfSignature()) {
///               (ctx.swap.balanceIn, ctx.swap.balanceOut) = AQUA.safeBalances(order.maker, address(this), orderHash, tokenIn, tokenOut);
///
///      So the blob handed to `ship()` must be, byte for byte, `abi.encode(order)`, and the
///      `app` argument must be the router. One byte of drift and `safeBalances` reverts
///      `SafeBalancesForTokenNotInActiveStrategy` — the cryptic "insufficient balance" —
///      because it is reading a strategy that was never shipped.
///
///      This library therefore derives `strategy` FROM the built order rather than encoding
///      the same fields twice. The equality with the router's own `hash(order)` is not
///      assumed here; `AquaPathForkTest` asserts it on-chain as its first assertion.
library ProgramBuilder {
    /// @notice One Aqua position: the order a taker executes, and the exact bytes that
    ///         commit it.
    /// @param order The maker's order. `traits` has bit 254 (`useAquaInsteadOfSignature`) set.
    /// @param strategy `abi.encode(order)` — the `strategy` argument to `Aqua.ship`.
    /// @param strategyHash `keccak256(strategy)`, which is what `ship()` returns and what
    ///        `SwapVM.hash(order)` must equal.
    struct Position {
        ISwapVM.Order order;
        bytes strategy;
        bytes32 strategyHash;
    }

    /// @notice Build an Aqua-path position around a program.
    /// @dev Everything but `maker`, the Aqua flag and the program is left at its zero value:
    ///      no hooks, no custom receiver, no unwrap, `allowZeroAmountIn` false.
    ///
    ///      Two of those zeros are load-bearing on the Aqua path, because `_transferIn`
    ///      rejects them outright (`SwapVM.sol:230-232`):
    ///
    ///        if (order.traits.useAquaInsteadOfSignature()) {
    ///            require(!order.traits.shouldUnwrapWeth(), MakerTraitsUnwrapIsIncompatibleWithAqua());
    ///            require(order.maker == order.traits.receiver(order.maker), MakerTraitsCustomReceiverIsIncompatibleWithAqua());
    ///
    ///      A zero `receiver` resolves back to the maker (`MakerTraits.sol:192-195`), so
    ///      leaving it unset satisfies the second require.
    /// @param maker The liquidity provider. Must be the address that calls `Aqua.ship`, since
    ///        `ship` keys balances by `msg.sender`.
    /// @param program SwapVM program bytes, encoded with `ProgramLib`.
    function aquaPosition(address maker, bytes memory program) internal pure returns (Position memory position) {
        MakerTraitsLib.Args memory args;
        args.maker = maker;
        args.useAquaInsteadOfSignature = true;
        args.program = program;

        position.order = MakerTraitsLib.build(args);
        position.strategy = abi.encode(position.order);
        position.strategyHash = keccak256(position.strategy);
    }
}
