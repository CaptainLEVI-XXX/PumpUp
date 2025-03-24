// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IBondingCurveStrategy
 * @notice Interface for bonding curve strategies with both exact input and exact output functionality
 */
interface IBondingCurveStrategy {
    /**
     * @notice Returns the strategy type
     * @return The type of the strategy
     */
    function strategyType() external view returns (string memory);

    /**
     * @notice Returns the strategy name
     * @return The name of the strategy
     */
    function name() external view returns (string memory);

    /**
     * @notice Initializes the strategy for a pool
     * @param poolId The ID of the pool
     * @param params Initialization parameters specific to the strategy
     */
    function initialize(bytes32 poolId, bytes calldata params) external;

    /**
     * @notice Calculates the amount of tokens to receive for a given amount of WETH
     * @param poolId The ID of the pool
     * @param wethAmount The amount of WETH to spend
     * @return tokenAmount The amount of tokens to receive
     * @return newPrice The new price after the swap
     */
    function calculateBuy(bytes32 poolId, uint256 wethAmount)
        external
        returns (uint256 tokenAmount, uint256 newPrice);

    /**
     * @notice Calculates the amount of WETH to receive for a given amount of tokens
     * @param poolId The ID of the pool
     * @param tokenAmount The amount of tokens to sell
     * @return wethAmount The amount of WETH to receive
     * @return newPrice The new price after the swap
     */
    function calculateSell(bytes32 poolId, uint256 tokenAmount)
        external
        returns (uint256 wethAmount, uint256 newPrice);

    /**
     * @notice Gets the current price of tokens
     * @param poolId The ID of the pool
     * @return The current price of tokens
     */
    function getCurrentPrice(bytes32 poolId) external view returns (uint256);

    /**
     * @notice Calculates the amount of WETH needed for an exact amount of tokens
     * @param poolId The ID of the pool
     * @param exactTokenAmount The exact amount of tokens wanted
     * @return wethAmount The amount of WETH needed
     * @return newPrice The new price after the swap
     */
    function calculateWethForExactTokens(bytes32 poolId, uint256 exactTokenAmount)
        external
        returns (uint256 wethAmount, uint256 newPrice);

    /**
     * @notice Calculates the amount of tokens needed for an exact amount of WETH
     * @param poolId The ID of the pool
     * @param exactWethAmount The exact amount of WETH wanted
     * @return tokenAmount The amount of tokens needed
     * @return newPrice The new price after the swap
     */
    function calculateTokensForExactWeth(bytes32 poolId, uint256 exactWethAmount)
        external
        returns (uint256 tokenAmount, uint256 newPrice);
}
