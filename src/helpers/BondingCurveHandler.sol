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
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

/**
 * @title BondingCurveSwap
 * @notice Contract that handles swaps against bonding curves
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

    // Structs to avoid stack too deep errors
    struct SwapInfo {
        bool isToken0Memecoin;
        bool isExactInput;
        bool isBuyingMemecoin;
        Currency inputCurrency;
        Currency outputCurrency;
        uint256 amountSpecifiedPositive;
    }

    struct SwapResult {
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 newPrice;
        uint256 newCirculatingSupply;
        uint256 newWethCollected;
    }

    struct PoolInfo {
        address tokenAddress;
        address strategyAddress;
        uint256 circulatingSupply;
        uint256 wethCollected;
        uint256 currentPrice;
    }

    IPoolStateManager public poolStateManager;
    address public wethAddress;

    function initializeBondingCurveSwap(IPoolStateManager _poolStateManager, address _wethAddress) internal {
        poolStateManager = _poolStateManager;
        wethAddress = _wethAddress;
    }

    /**
     * @notice Main entry point for handling bonding curve swaps
     */
    function handleBondingCurveSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes32 poolId,
        address sender
    ) internal returns (BeforeSwapDelta) {
        // Get pool information
        PoolInfo memory pool = _getPoolInfo(poolId);
        
        // Determine swap parameters
        SwapInfo memory swap = _getSwapInfo(key, params, pool.tokenAddress);
        
        // Execute the swap
        SwapResult memory result = _executeSwap(poolId, swap, pool, sender);
        
        // Update pool state
        poolStateManager.updatePoolState(
            poolId, 
            result.newCirculatingSupply, 
            result.newWethCollected, 
            result.newPrice
        );
        
        // Return delta to make core swap a no-op
        return toBeforeSwapDelta(
            int128(int256(result.inputAmount)),
            int128(-int256(result.outputAmount))
        );
    }

    /**
     * @notice Get pool information
     */
    function _getPoolInfo(bytes32 poolId) private view returns (PoolInfo memory pool) {
        (
            pool.tokenAddress,
            pool.strategyAddress,
            pool.circulatingSupply,
            pool.wethCollected,
            pool.currentPrice
        ) = poolStateManager.getInfoForHook(poolId);
        
        return pool;
    }

    /**
     * @notice Determine swap parameters and validate token path
     */
    function _getSwapInfo(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        address tokenAddress
    ) private view returns (SwapInfo memory swap) {
        // Get token addresses
        address token0Address = Currency.unwrap(key.currency0);
        address token1Address = Currency.unwrap(key.currency1);
        
        // Determine token arrangement
        swap.isToken0Memecoin = (token0Address == tokenAddress);
        
        // Verify correct token pairing
        if (
            !(swap.isToken0Memecoin && token1Address == wethAddress) && 
            !(token0Address == wethAddress && token1Address == tokenAddress)
        ) {
            InvalidTokenPath.selector.revertWith();
        }
        
        // Set basic swap parameters
        swap.isExactInput = params.amountSpecified < 0;
        swap.amountSpecifiedPositive = swap.isExactInput 
            ? uint256(-params.amountSpecified) 
            : uint256(params.amountSpecified);
        
        // Determine if buying or selling memecoin
        swap.isBuyingMemecoin = swap.isExactInput 
            ? (params.zeroForOne != swap.isToken0Memecoin) 
            : (params.zeroForOne == swap.isToken0Memecoin);
        
        // Set currencies
        swap.inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        swap.outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        
        return swap;
    }

    /**
     * @notice Execute the swap based on parameters
     */
    function _executeSwap(
        bytes32 poolId,
        SwapInfo memory swap,
        PoolInfo memory pool,
        address sender
    ) private returns (SwapResult memory result) {
        IBondingCurveStrategy strategy = IBondingCurveStrategy(pool.strategyAddress);
        
        if (swap.isExactInput) {
            result = _handleExactInputSwap(poolId, swap, pool, strategy, sender);
        } else {
            result = _handleExactOutputSwap(poolId, swap, pool, strategy, sender);
        }
        
        return result;
    }

    /**
     * @notice Handle exact input swaps
     */
    function _handleExactInputSwap(
        bytes32 poolId,
        SwapInfo memory swap,
        PoolInfo memory pool,
        IBondingCurveStrategy strategy,
        address sender
    ) private returns (SwapResult memory result) {
        result.inputAmount = swap.amountSpecifiedPositive;
        
        if (swap.isBuyingMemecoin) {
            // Buy memecoin with WETH
            (result.outputAmount, result.newPrice) = strategy.calculateBuy(poolId, result.inputAmount);
            
            // When buying memecoin, tokens are removed from circulation
            result.newCirculatingSupply = pool.circulatingSupply - result.outputAmount;
            result.newWethCollected = pool.wethCollected + result.inputAmount;
            
            // Process token transfers
            swap.inputCurrency.take(poolManager, address(this), result.inputAmount, true);
            swap.outputCurrency.settle(poolManager, address(this), result.outputAmount, true);
            
            emit TokensPurchased(poolId, sender, result.inputAmount, result.outputAmount, result.newPrice);
        } else {
            // Sell memecoin for WETH
            (result.outputAmount, result.newPrice) = strategy.calculateSell(poolId, result.inputAmount);
            
            // Verify we have enough WETH liquidity
            if (result.outputAmount > pool.wethCollected) {
                InsufficientLiquidity.selector.revertWith();
            }
            
            // When selling memecoin, tokens are added back to circulation
            result.newCirculatingSupply = pool.circulatingSupply + result.inputAmount;
            result.newWethCollected = pool.wethCollected - result.outputAmount;
            
            // Process token transfers
            swap.inputCurrency.take(poolManager, address(this), result.inputAmount, true);
            swap.outputCurrency.settle(poolManager, address(this), result.outputAmount, true);
            
            emit TokensSold(poolId, sender, result.inputAmount, result.outputAmount, result.newPrice);
        }
        
        return result;
    }

    /**
     * @notice Handle exact output swaps
     */
    function _handleExactOutputSwap(
        bytes32 poolId,
        SwapInfo memory swap,
        PoolInfo memory pool,
        IBondingCurveStrategy strategy,
        address sender
    ) private returns (SwapResult memory result) {
        result.outputAmount = swap.amountSpecifiedPositive;
        
        if (swap.isBuyingMemecoin) {
            // Buy exact amount of memecoin with WETH
            bytes4 calculationSelector = bytes4(keccak256("calculateWethForExactTokens(bytes32,uint256)"));
            
            // Calculate WETH needed for exact token output
            (bool success, bytes memory returnData) = address(strategy).call(
                abi.encodeWithSelector(calculationSelector, poolId, result.outputAmount)
            );
            
            if (!success) {
                ExactOutputNotSupported.selector.revertWith();
            }
            
            (result.inputAmount, result.newPrice) = abi.decode(returnData, (uint256, uint256));
            
            // When buying memecoin, tokens are removed from circulation
            result.newCirculatingSupply = pool.circulatingSupply - result.outputAmount;
            result.newWethCollected = pool.wethCollected + result.inputAmount;
            
            // Process token transfers
            swap.inputCurrency.take(poolManager, address(this), result.inputAmount, true);
            swap.outputCurrency.settle(poolManager, address(this), result.outputAmount, true);
            
            emit TokensPurchased(poolId, sender, result.inputAmount, result.outputAmount, result.newPrice);
        } else {
            // Sell memecoin for exact WETH output
            bytes4 calculationSelector = bytes4(keccak256("calculateTokensForExactWeth(bytes32,uint256)"));
            
            // Calculate tokens needed for exact WETH output
            (bool success, bytes memory returnData) = address(strategy).call(
                abi.encodeWithSelector(calculationSelector, poolId, result.outputAmount)
            );
            
            if (!success) {
                ExactOutputNotSupported.selector.revertWith();
            }
            
            (result.inputAmount, result.newPrice) = abi.decode(returnData, (uint256, uint256));
            
            // Verify we have enough WETH liquidity
            if (result.outputAmount > pool.wethCollected) {
                InsufficientLiquidity.selector.revertWith();
            }
            
            // When selling memecoin, tokens are added back to circulation
            result.newCirculatingSupply = pool.circulatingSupply + result.inputAmount;
            result.newWethCollected = pool.wethCollected - result.outputAmount;
            
            // Process token transfers
            swap.inputCurrency.take(poolManager, address(this), result.inputAmount, true);
            swap.outputCurrency.settle(poolManager, address(this), result.outputAmount, true);
            
            emit TokensSold(poolId, sender, result.inputAmount, result.outputAmount, result.newPrice);
        }
        
        return result;
    }
}