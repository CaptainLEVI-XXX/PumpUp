// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IWethPriceOracle
 * @notice Interface for WETH price oracle
 */
interface IPriceOracle {
    function getWethPrice() external view returns (uint256);
}
