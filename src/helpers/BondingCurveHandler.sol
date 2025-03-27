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
import {console} from "forge-std/console.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

/**
 * @title BondingCurveSwap
 * @notice contract that handles swaps against bonding curves
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

    struct TransitParams{
        Currency currency0;
        Currency currency1;
        uint256 amount0;
        uint256 amount1;
    }

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
     * @dev Optimized implementation with corrected supply calculations
     */
    function handleBondingCurveSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes32 poolId,
        address sender
    ) internal returns (BeforeSwapDelta) {
        // Get the pool info and bonding curve strategy
        (
            address tokenAddress,
            address bondingCurveImplementation,
            uint256 circulatingSupply,
            uint256 wethCollected,
            uint256 currentPrice
        ) = poolStateManager.getInfoForHook(poolId);

        // Cast the strategy ID to an address
        IBondingCurveStrategy strategy = IBondingCurveStrategy(bondingCurveImplementation);

        // Validate and determine token arrangement
        address token0Address = Currency.unwrap(key.currency0);
        address token1Address = Currency.unwrap(key.currency1);
        bool isToken0Memecoin = (token0Address == tokenAddress);

        // Verify correct token pairing
        if (
            !(isToken0Memecoin && token1Address == wethAddress)
                && !(token0Address == wethAddress && token1Address == tokenAddress)
        ) {
            revert InvalidTokenPath();
        }

        // Determine swap type and currencies
        bool isExactInput = params.amountSpecified < 0;
        bool isBuyingMemecoin =
            isExactInput ? (params.zeroForOne != isToken0Memecoin) : (params.zeroForOne == isToken0Memecoin);

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        // Convert specified amount to positive for calculations
        uint256 amountSpecifiedPositive =
            isExactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // Variables for swap calculations
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 newPrice;
        uint256 newCirculatingSupply;
        uint256 newWethCollected;

        if (isExactInput) {
            // EXACT INPUT
            inputAmount = amountSpecifiedPositive;

            if (isBuyingMemecoin) {
                // Buying memecoin with WETH
                (outputAmount, newPrice) = strategy.calculateBuy(poolId, inputAmount);

                // When buying memecoin, tokens are removed from circulation
                newCirculatingSupply = circulatingSupply - outputAmount;
                newWethCollected = wethCollected + inputAmount;

                // Process token transfers
                inputCurrency.take(poolManager, address(this), inputAmount, true);
                outputCurrency.settle(poolManager, address(this), outputAmount, true);

                emit TokensPurchased(poolId, sender, inputAmount, outputAmount, newPrice);
            } else {
                // Selling memecoin for WETH
                (outputAmount, newPrice) = strategy.calculateSell(poolId, inputAmount);

                // Verify we have enough WETH liquidity
                if (outputAmount > wethCollected) {
                    revert InsufficientLiquidity();
                }

                // When selling memecoin, tokens are added back to circulation
                newCirculatingSupply = circulatingSupply + inputAmount;
                newWethCollected = wethCollected - outputAmount;

                // Process token transfers
                inputCurrency.take(poolManager, address(this), inputAmount, true);
                outputCurrency.settle(poolManager, address(this), outputAmount, true);

                emit TokensSold(poolId, sender, inputAmount, outputAmount, newPrice);
            }
        } else {
            // EXACT OUTPUT
            outputAmount = amountSpecifiedPositive;

            if (isBuyingMemecoin) {
                // User wants exact output of memecoin
                bytes4 calculationSelector = bytes4(keccak256("calculateWethForExactTokens(bytes32,uint256)"));

                // Calculate WETH needed for exact token output
                (bool success, bytes memory returnData) =
                    address(strategy).call(abi.encodeWithSelector(calculationSelector, poolId, outputAmount));

                if (!success) {
                    revert ExactOutputNotSupported();
                }

                (inputAmount, newPrice) = abi.decode(returnData, (uint256, uint256));

                // When buying memecoin, tokens are removed from circulation
                newCirculatingSupply = circulatingSupply - outputAmount;
                newWethCollected = wethCollected + inputAmount;

                // Process token transfers
                inputCurrency.take(poolManager, address(this), inputAmount, true);
                outputCurrency.settle(poolManager, address(this), outputAmount, true);

                emit TokensPurchased(poolId, sender, inputAmount, outputAmount, newPrice);
            } else {
                // User wants exact output of WETH
                bytes4 calculationSelector = bytes4(keccak256("calculateTokensForExactWeth(bytes32,uint256)"));

                // Calculate tokens needed for exact WETH output
                (bool success, bytes memory returnData) =
                    address(strategy).call(abi.encodeWithSelector(calculationSelector, poolId, outputAmount));

                if (!success) {
                    revert ExactOutputNotSupported();
                }

                (inputAmount, newPrice) = abi.decode(returnData, (uint256, uint256));

                // Verify we have enough WETH liquidity
                if (outputAmount > wethCollected) {
                    revert InsufficientLiquidity();
                }

                // When selling memecoin, tokens are added back to circulation
                newCirculatingSupply = circulatingSupply + inputAmount;
                newWethCollected = wethCollected - outputAmount;

                // Process token transfers
                inputCurrency.take(poolManager, address(this), inputAmount, true);
                outputCurrency.settle(poolManager, address(this), outputAmount, true);

                emit TokensSold(poolId, sender, inputAmount, outputAmount, newPrice);
            }
        }

        // Update the pool state
        poolStateManager.updatePoolState(poolId, newCirculatingSupply, newWethCollected, newPrice);

        // Return delta to make core swap a no-op
        return toBeforeSwapDelta(
            int128(int256(inputAmount)), // We've already handled this input amount
            int128(-int256(outputAmount)) // We've already provided this output amount
        );
    }



    // function _transitPoolToV4(TransitParams calldata params) internal {
    //      // Burn claim tokens first (give up our claim to tokens in the PoolManager)
    //     params.currency0.settle(poolManager, address(this), params.amount0, true);

    //     // Then transfer the actual tokens from the PoolManager to the Hook
    //     poolManager.take(params.currency0,address(this) , params.amount0);

    //       // Burn claim tokens first (give up our claim to tokens in the PoolManager)
    //     params.currency1.settle(poolManager, address(this), params.amount1, true);

    //     // Then transfer the actual tokens from the PoolManager to the Hook
    //     poolManager.take(params.currency1,address(this) , params.amount1);


    //     ModifyLiquidityParams
    // }
}
