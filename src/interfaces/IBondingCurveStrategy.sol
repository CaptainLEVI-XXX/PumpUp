// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IBondingCurveStrategy
 * @author SWAPUMP
 * @notice Interface for bonding curve strategy implementations
 * @dev Must be implemented by all bonding curve strategies
 */
interface IBondingCurveStrategy {
    /**
     * @notice Returns the strategy type
     * @return A string indicating the strategy type ("BondingCurve")
     */
    function strategyType() external view returns (string memory);
    
    /**
     * @notice Returns the strategy name
     * @return A human-readable name for the strategy
     */
    function name() external view returns (string memory);
    
    /**
     * @notice Initializes the strategy for a pool
     * @param poolId The ID of the pool
     * @param params Additional parameters specific to the strategy
     */
    function initialize(bytes32 poolId, bytes calldata params) external;
    
    /**
     * @notice Calculates the amount of tokens to receive for a given amount of WETH
     * @param poolId The ID of the pool
     * @param wethAmount Amount of WETH to spend
     * @return tokenAmount Amount of tokens to receive
     * @return newPrice New token price after the purchase
     */
    function calculateBuy(
        bytes32 poolId,
        uint256 wethAmount
    ) external returns (uint256 tokenAmount, uint256 newPrice);
    
    /**
     * @notice Calculates the amount of WETH to receive for a given amount of tokens
     * @param poolId The ID of the pool
     * @param tokenAmount Amount of tokens to sell
     * @return wethAmount Amount of WETH to receive
     * @return newPrice New token price after the sale
     */
    function calculateSell(
        bytes32 poolId,
        uint256 tokenAmount
    ) external returns (uint256 wethAmount, uint256 newPrice);
    
    /**
     * @notice Returns the current token price
     * @param poolId The ID of the pool
     * @return Current price of the token
     */
    function getCurrentPrice(bytes32 poolId) external view returns (uint256);
}