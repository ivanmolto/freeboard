// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Addresses } from "../../src/constants/Addresses.sol";
import { Curve } from "../../src/libs/Curve.sol";

/// @title Curves — the curve tables the tests ship, built once
/// @notice The Freeboard table from CLAUDE.md, and a two-leg WETH/USDC table for the fork
///         fixtures that ship a two-token basket. Leg order is the token order: the debt
///         asset, USDC, is last in both.
library Curves {
    /// @dev The Freeboard curve, top row first:
    ///        HF 2.00 -> 50 / 30 / 20
    ///        HF 1.60 -> 40 / 24 / 36
    ///        HF 1.30 -> 30 / 16 / 54
    ///        HF 1.15 -> 20 / 10 / 70
    function freeboard() internal pure returns (bytes memory) {
        uint256[] memory hf = _hfs();
        uint256[][] memory w = new uint256[][](4);
        w[0] = _row3(0.5e18, 0.3e18, 0.2e18);
        w[1] = _row3(0.4e18, 0.24e18, 0.36e18);
        w[2] = _row3(0.3e18, 0.16e18, 0.54e18);
        w[3] = _row3(0.2e18, 0.1e18, 0.7e18);
        return Curve.encode(hf, w);
    }

    /// @dev WETH, WBTC, USDC — the Freeboard basket, in curve leg order.
    function freeboardTokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = Addresses.WETH;
        tokens[1] = Addresses.WBTC;
        tokens[2] = Addresses.USDC;
    }

    /// @dev A two-leg curve over WETH / USDC with the same breakpoints and the same shape —
    ///      collateral leg falling, debt asset rising, as HF falls:
    ///        HF 2.00 -> 50 / 50
    ///        HF 1.60 -> 40 / 60
    ///        HF 1.30 -> 30 / 70
    ///        HF 1.15 -> 20 / 80
    function twoLeg() internal pure returns (bytes memory) {
        uint256[] memory hf = _hfs();
        uint256[][] memory w = new uint256[][](4);
        w[0] = _row2(0.5e18, 0.5e18);
        w[1] = _row2(0.4e18, 0.6e18);
        w[2] = _row2(0.3e18, 0.7e18);
        w[3] = _row2(0.2e18, 0.8e18);
        return Curve.encode(hf, w);
    }

    function twoLegTokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = Addresses.WETH;
        tokens[1] = Addresses.USDC;
    }

    function _hfs() private pure returns (uint256[] memory hf) {
        hf = new uint256[](4);
        hf[0] = 2.0e18;
        hf[1] = 1.6e18;
        hf[2] = 1.3e18;
        hf[3] = 1.15e18;
    }

    function _row3(uint256 a, uint256 b, uint256 c) private pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _row2(uint256 a, uint256 b) private pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }
}
