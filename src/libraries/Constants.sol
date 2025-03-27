// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Constants {
    /// @dev All sqrtPrice calculations are calculated as
    /// sqrtPriceX96 = floor(sqrt(A / B) * 2 ** 96) where A and B are the currency reserves
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint256 constant MAX_UINT256 = type(uint256).max;

    uint24 constant FEE_LOW = 500;
    uint24 constant FEE_MEDIUM = 3000;
    uint24 constant FEE_HIGH = 10000;

    bytes constant ZERO_BYTES = new bytes(0);
}
