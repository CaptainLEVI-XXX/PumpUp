// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IBondingCurveStrategy} from "../interfaces/IBondingCurveStrategy.sol";
import {IPoolStateManager} from "../interfaces/IPoolStateManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

/**
 * @title AbstractBondingCurveSwap
 * @notice Abstract contract that handles swaps against bonding curves
 * @dev Supports both exact input and exact output swaps
 */
abstract contract BondingCurveSwap is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using CustomRevert for bytes4;

    // Errors
    error InsufficientLiquidity();
    error InvalidTokenPath();
    error SwapTooLarge();
    error ExactOutputNotSupported();

    // Events
    event TokensPurchased(
        bytes32 indexed poolId, address indexed user, uint256 wethAmount, uint256 tokenAmount, uint256 newPrice
    );
    event TokensSold(
        bytes32 indexed poolId, address indexed user, uint256 tokenAmount, uint256 wethAmount, uint256 newPrice
    );

    IPoolStateManager public poolStateManager;
    address public wethAddress;

    //need to put correct authentication

    function initializeBondingCurveSwap(IPoolStateManager _poolStateManager, address _wethAddress) internal {
        poolStateManager = _poolStateManager;
        wethAddress = _wethAddress;
    }

    /**
     * @notice Handle swaps against the bonding curve (pre-transition)
     * @dev Uses the extended bonding curve strategy for both exact input and exact output swaps
     */
    function handleBondingCurveSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes32 poolId,
        address sender
    ) internal returns (BeforeSwapDelta) {
        // Convert to positive amount for calculations
        uint256 amountSpecifiedPositive =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        // Get the pool info and bonding curve strategy
        (
            address tokenAddress,
            , // creator
            uint256 wethCollected,
            , // currentPrice
            , // isTransitioned
            bytes32 strategyId
        ) = poolStateManager.getPoolInfo(poolId);

        // Get extended pool info
        (,, uint256 circulatingSupply,,) = poolStateManager.getExtendedPoolInfo(poolId);

        // Cast the strategy ID to an address
        IBondingCurveStrategy strategy = IBondingCurveStrategy(address(bytes20(strategyId)));

        // Get token addresses
        address token0Address = Currency.unwrap(key.currency0);
        address token1Address = Currency.unwrap(key.currency1);

        // Determine which token is memecoin and which is WETH
        bool isToken0Memecoin = (token0Address == tokenAddress);

        // Verify correct token pairing
        if (
            !(isToken0Memecoin && token1Address == wethAddress)
                && !(token0Address == wethAddress && token1Address == tokenAddress)
        ) {
            revert InvalidTokenPath();
        }

        // Initialize variables for swap calculations
        uint256 outputAmount;
        uint256 inputAmount;
        uint256 newCirculatingSupply;
        uint256 newWethCollected;
        uint256 newPrice;
        bool isExactInput = params.amountSpecified < 0;
        bool isBuyingMemecoin;

        // Determine if this is a purchase of memecoin or sale of memecoin
        if (params.zeroForOne) {
            // Selling token0 for token1
            isBuyingMemecoin = !isToken0Memecoin; // If token0 is not memecoin, then buying memecoin
        } else {
            // Selling token1 for token0
            isBuyingMemecoin = isToken0Memecoin; // If token0 is memecoin, then buying memecoin
        }

        if (isExactInput) {
            // EXACT INPUT: User knows how much they're putting in
            inputAmount = amountSpecifiedPositive;

            if (isBuyingMemecoin) {
                // Buying memecoin with WETH
                (outputAmount, newPrice) = strategy.calculateBuy(poolId, inputAmount);

                newCirculatingSupply = circulatingSupply + outputAmount;
                newWethCollected = wethCollected + inputAmount;

                // Take WETH from user
                if (params.zeroForOne) {
                    key.currency0.take(poolManager, address(this), inputAmount, true);
                    // Return memecoin to user
                    key.currency1.settle(poolManager, sender, outputAmount, true);
                } else {
                    key.currency1.take(poolManager, address(this), inputAmount, true);
                    // Return memecoin to user
                    key.currency0.settle(poolManager, sender, outputAmount, true);
                }

                emit TokensPurchased(poolId, sender, inputAmount, outputAmount, newPrice);
            } else {
                // Selling memecoin for WETH
                (outputAmount, newPrice) = strategy.calculateSell(poolId, inputAmount);

                // Verify we have enough WETH liquidity
                if (outputAmount > wethCollected) {
                    revert InsufficientLiquidity();
                }

                newCirculatingSupply = circulatingSupply - inputAmount;
                newWethCollected = wethCollected - outputAmount;

                // Take memecoin from user
                if (params.zeroForOne) {
                    key.currency0.take(poolManager, address(this), inputAmount, true);
                    // Return WETH to user
                    key.currency1.settle(poolManager, sender, outputAmount, true);
                } else {
                    key.currency1.take(poolManager, address(this), inputAmount, true);
                    // Return WETH to user
                    key.currency0.settle(poolManager, sender, outputAmount, true);
                }

                emit TokensSold(poolId, sender, inputAmount, outputAmount, newPrice);
            }
        } else {
            // EXACT OUTPUT: User knows how much they want to receive
            outputAmount = amountSpecifiedPositive; // This is what the user specified

            // Check if the strategy supports the extended interface with exact output methods
            // Try to cast the strategy to access the exact output methods
            bytes4 wethForExactTokensSelector = bytes4(keccak256("calculateWethForExactTokens(bytes32,uint256)"));
            bytes4 tokensForExactWethSelector = bytes4(keccak256("calculateTokensForExactWeth(bytes32,uint256)"));

            if (isBuyingMemecoin) {
                // User wants exact output of memecoin
                // Try to call calculateWethForExactTokens
                (bool success, bytes memory returnData) =
                    address(strategy).call(abi.encodeWithSelector(wethForExactTokensSelector, poolId, outputAmount));

                if (!success) {
                    revert ExactOutputNotSupported();
                }

                // Decode the return data
                (inputAmount, newPrice) = abi.decode(returnData, (uint256, uint256));

                // Update pool state
                newCirculatingSupply = circulatingSupply + outputAmount;
                newWethCollected = wethCollected + inputAmount;

                // Take WETH from user
                if (params.zeroForOne) {
                    key.currency0.take(poolManager, address(this), inputAmount, true);
                    // Return exact memecoin to user
                    key.currency1.settle(poolManager, sender, outputAmount, true);
                } else {
                    key.currency1.take(poolManager, address(this), inputAmount, true);
                    // Return exact memecoin to user
                    key.currency0.settle(poolManager, sender, outputAmount, true);
                }

                emit TokensPurchased(poolId, sender, inputAmount, outputAmount, newPrice);
            } else {
                // User wants exact output of WETH
                // Try to call calculateTokensForExactWeth
                (bool success, bytes memory returnData) =
                    address(strategy).call(abi.encodeWithSelector(tokensForExactWethSelector, poolId, outputAmount));

                if (!success) {
                    revert ExactOutputNotSupported();
                }

                // Decode the return data
                (inputAmount, newPrice) = abi.decode(returnData, (uint256, uint256));

                // Verify we have enough WETH liquidity
                if (outputAmount > wethCollected) {
                    revert InsufficientLiquidity();
                }

                // Update pool state
                newCirculatingSupply = circulatingSupply - inputAmount;
                newWethCollected = wethCollected - outputAmount;

                // Take memecoin from user
                if (params.zeroForOne) {
                    key.currency0.take(poolManager, address(this), inputAmount, true);
                    // Return exact WETH to user
                    key.currency1.settle(poolManager, sender, outputAmount, true);
                } else {
                    key.currency1.take(poolManager, address(this), inputAmount, true);
                    // Return exact WETH to user
                    key.currency0.settle(poolManager, sender, outputAmount, true);
                }

                emit TokensSold(poolId, sender, inputAmount, outputAmount, newPrice);
            }
        }

        // Update the pool state in the manager
        poolStateManager.updatePoolState(poolId, newCirculatingSupply, newWethCollected, newPrice);

        // Return the delta based on the CSMM pattern
        // For exact input: delta is (-amountSpec, outputAmount)
        // For exact output: delta is (-inputAmount, amountSpec)
        if (isExactInput) {
            return toBeforeSwapDelta(
                int128(-params.amountSpecified), // Specified amount (what user sends)
                int128(int256(outputAmount)) // Output amount (what user receives)
            );
        } else {
            return toBeforeSwapDelta(
                int128(-int256(inputAmount)), // Input amount (what user sends)
                int128(params.amountSpecified) // Specified amount (what user receives)
            );
        }
    }
}
