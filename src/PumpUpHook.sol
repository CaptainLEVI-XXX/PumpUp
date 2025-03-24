// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Initializable} from "@solady/utils/Initializable.sol";
import {IPoolStateManager} from "./interfaces/IPoolStateManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IBondingCurveStrategy} from "./interfaces/IBondingCurveStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BondingCurveSwap} from "./helpers/BondingCurveHandler.sol";

contract PumpUpHook is Initializable, BaseHook ,BondingCurveSwap{
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using CustomRevert for bytes4;
    using PoolIdLibrary for PoolKey;

    error PoolNotTransitioned();
    error PoolTransitioned();
    error InvalidAmount();

    error UnexpectedOperation();
    error ZeroAddress();


    // Track liquidity provided by each user for each pool
    mapping(address user => mapping(bytes32 poolId => uint256 amount)) public userLiquidity;

    // Track total liquidity for each pool
    mapping(bytes32 poolId => uint256 liquidity) public totalPoolLiquidity;


    // WETH price oracle contract
    IPriceOracle private wethPriceOracle;


    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
        bool isRemove;
        bytes32 poolId;
    }

    struct LiquidityParams {
        uint256 amountEach;
        bytes32 poolId;
    }

    // Events
    event LiquidityAdded(bytes32 indexed poolId, address indexed user, uint256 amount);
    event LiquidityRemoved(bytes32 indexed poolId, address indexed user, uint256 amount);

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function initialize(address _poolStateManager, address _wethPriceOracle, address _wethAddress)
        external
        initializer
    {
        if (_poolStateManager == address(0) || _wethPriceOracle == address(0) || _wethAddress == address(0)) {
            ZeroAddress.selector.revertWith();
        }
        wethPriceOracle = IPriceOracle(_wethPriceOracle);
        initializeBondingCurveSwap(poolStateManager,wethAddress);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // This handles direct V4 pool interactions for adding liquidity
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata data
    ) internal view override returns (bytes4) {
        bytes32 poolId = abi.decode(data, (bytes32));

        // Only allow adding liquidity through V4 pool if it has transitioned
        bool isTransitioned = poolStateManager.isPoolTransitioned(poolId);
        if (!isTransitioned) PoolNotTransitioned.selector.revertWith();

        return this.beforeAddLiquidity.selector;
    }

    // This handles direct V4 pool interactions for removing liquidity
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata data
    ) internal view override returns (bytes4) {
        bytes32 poolId = abi.decode(data, (bytes32));

        // Only allow removing liquidity through V4 pool if it has transitioned
        bool isTransitioned = poolStateManager.isPoolTransitioned(poolId);
        if (!isTransitioned) PoolNotTransitioned.selector.revertWith();

        return this.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Add liquidity to the bonding curve (pre-transition)
     * @param params Pool key
     * @param liquidityParams Parameters including amount and pool ID
     */
    function addLiquidity(PoolKey calldata params, LiquidityParams calldata liquidityParams) external {
        if (liquidityParams.amountEach == 0) InvalidAmount.selector.revertWith();

        // Only allow adding liquidity via this method if pool hasn't transitioned
        // After transition, liquidity should be added through regular Uniswap functions
        bool isTransitioned = poolStateManager.isPoolTransitioned(liquidityParams.poolId);
        if (isTransitioned) PoolTransitioned.selector.revertWith();

        // Update liquidity tracking
        unchecked {
            userLiquidity[msg.sender][liquidityParams.poolId] += liquidityParams.amountEach;
            totalPoolLiquidity[liquidityParams.poolId] += liquidityParams.amountEach;
        }

        // Call to unlock for token transfers
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    amountEach: liquidityParams.amountEach,
                    currency0: params.currency0,
                    currency1: params.currency1,
                    sender: msg.sender,
                    isRemove: false,
                    poolId: liquidityParams.poolId
                })
            )
        );

        emit LiquidityAdded(liquidityParams.poolId, msg.sender, liquidityParams.amountEach);
    }

    /**
     * @notice Remove liquidity from the bonding curve (pre-transition)
     * @param params Pool key
     * @param liquidityParams Parameters including amount and pool ID
     */
    function removeLiquidity(PoolKey calldata params, LiquidityParams calldata liquidityParams) external {
        if (liquidityParams.amountEach == 0) {
            InvalidAmount.selector.revertWith();
        }

        // Only allow removing liquidity via this method if pool hasn't transitioned
        bool isTransitioned = poolStateManager.isPoolTransitioned(liquidityParams.poolId);
        if (isTransitioned) PoolTransitioned.selector.revertWith();

        // Check if user has enough liquidity
        if (userLiquidity[msg.sender][liquidityParams.poolId] < liquidityParams.amountEach) {
            InsufficientLiquidity.selector.revertWith();
        }

        unchecked {
            // Update liquidity tracking
            userLiquidity[msg.sender][liquidityParams.poolId] -= liquidityParams.amountEach;
            totalPoolLiquidity[liquidityParams.poolId] -= liquidityParams.amountEach;
        }

        // Call to unlock for token transfers
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    amountEach: liquidityParams.amountEach,
                    currency0: params.currency0,
                    currency1: params.currency1,
                    sender: msg.sender,
                    isRemove: true,
                    poolId: liquidityParams.poolId
                })
            )
        );

        emit LiquidityRemoved(liquidityParams.poolId, msg.sender, liquidityParams.amountEach);
    }

    /**
     * @notice Handle token transfers during unlock
     * @param data Callback data
     * @return Empty bytes
     */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        if (callbackData.isRemove) {
            // For removing liquidity:
            // Take tokens from hook and settle to the user
            callbackData.currency0.settle(poolManager, callbackData.sender, callbackData.amountEach, true);
            callbackData.currency1.settle(poolManager, callbackData.sender, callbackData.amountEach, true);

            // Get current pool state
            (address tokenAddress,,,,, bytes32 bondingCurveStrategy) = poolStateManager.getPoolInfo(callbackData.poolId);
            (,, uint256 currentCirculatingSupply,,) = poolStateManager.getExtendedPoolInfo(callbackData.poolId);

            // Calculate new circulating supply
            uint256 newCirculatingSupply = currentCirculatingSupply - callbackData.amountEach;

            // Get the current WETH collected and price
            (,, uint256 currentWethCollected, uint256 currentPrice,,) =
                poolStateManager.getPoolInfo(callbackData.poolId);

            // Calculate new price using bonding curve strategy
            IBondingCurveStrategy strategy = IBondingCurveStrategy(address(bytes20(bondingCurveStrategy)));
            uint256 newPrice = strategy.getCurrentPrice(callbackData.poolId);

            // Update pool state in the PoolStateManager
            poolStateManager.updatePoolState(
                callbackData.poolId,
                newCirculatingSupply,
                currentWethCollected, // WETH collected doesn't change for removal
                newPrice
            );
        } else {
            // For adding liquidity:
            // Take tokens from user
            callbackData.currency0.settle(poolManager, callbackData.sender, callbackData.amountEach, false);
            callbackData.currency1.settle(poolManager, callbackData.sender, callbackData.amountEach, false);

            // Move tokens to hook
            callbackData.currency0.take(poolManager, address(this), callbackData.amountEach, true);
            callbackData.currency1.take(poolManager, address(this), callbackData.amountEach, true);

            // Get current pool state
            (address tokenAddress,,,,, bytes32 bondingCurveStrategy) = poolStateManager.getPoolInfo(callbackData.poolId);
            (,, uint256 currentCirculatingSupply,,) = poolStateManager.getExtendedPoolInfo(callbackData.poolId);

            // Calculate new circulating supply
            uint256 newCirculatingSupply = currentCirculatingSupply + callbackData.amountEach;

            // Get the current WETH collected
            (,, uint256 currentWethCollected,,,) = poolStateManager.getPoolInfo(callbackData.poolId);

            // Add the new WETH contributed
            uint256 newWethCollected = currentWethCollected + callbackData.amountEach;

            // Calculate new price using bonding curve strategy
            IBondingCurveStrategy strategy = IBondingCurveStrategy(address(bytes20(bondingCurveStrategy)));
            uint256 newPrice = strategy.getCurrentPrice(callbackData.poolId);

            // Update pool state in the PoolStateManager
            poolStateManager.updatePoolState(callbackData.poolId, newCirculatingSupply, newWethCollected, newPrice);
        }

        return "";
    }

    /**
     * @notice Handle swaps for bonding curve or V4 pool
     * @dev For pre-transition (bonding curve) swaps
     */
    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata data)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bytes32 poolId = abi.decode(data, (bytes32));

        // Check if pool has transitioned
        bool isTransitioned = poolStateManager.isPoolTransitioned(poolId);

        if (!isTransitioned) {
            // For bonding curve swaps
            BeforeSwapDelta beoforeSwapDelta = handleBondingCurveSwap(key, params, poolId,msg.sender);
            return (this.beforeSwap.selector, beoforeSwapDelta, 0);
        } else {
            // For V4 pool swaps, just return the selector to allow default V4 swap behavior
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
    }

    // /**
    //  * @notice Handle swaps against the bonding curve (pre-transition)
    //  * @dev Uses the bonding curve strategy to calculate token amounts
    //  */
    // function _handleBondingCurveSwap(PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes32 poolId)
    //     internal
    //     returns (bytes4, BeforeSwapDelta, uint24)
    // {
    //     uint256 amountInOutPositive =
    //         params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

    //     // Get the pool info and bonding curve strategy
    //     (
    //         address tokenAddress,
    //         address creator,
    //         uint256 wethCollected,
    //         uint256 currentPrice,
    //         bool isTransitioned,
    //         bytes32 strategyId
    //     ) = poolStateManager.getPoolInfo(poolId);

    //     // Get extended pool info
    //     (,, uint256 circulatingSupply, uint256 totalSupply,) = poolStateManager.getExtendedPoolInfo(poolId);

    //     // Cast the strategy ID to an address
    //     IBondingCurveStrategy strategy = IBondingCurveStrategy(address(bytes20(strategyId)));

    //     // Initialize variables for swap calculations
    //     uint256 outputAmount;
    //     uint256 newCirculatingSupply;
    //     uint256 newWethCollected;
    //     uint256 newPrice;

    //     // Get token addresses
    //     address token0Address = Currency.unwrap(key.currency0);
    //     address token1Address = Currency.unwrap(key.currency1);

    //     // Determine which token is which
    //     bool isToken0Memecoin = (token0Address == tokenAddress);
    //     bool isToken1WETH = (token1Address == wethAddress);

    //     // Verify correct token pairing
    //     if (!(isToken0Memecoin && isToken1WETH) && !(token0Address == wethAddress && token1Address == tokenAddress)) {
    //         revert InvalidTokenPath();
    //     }

    //     if (params.zeroForOne) {
    //         //this means the swap direction is from user-->token1,,, user<---token0
    //     }

    //     if (params.zeroForOne) {
    //         // User is selling token0 and buying token1
    //         key.currency0.take(poolManager, address(this), amountInOutPositive, true);

    //         if (isToken0Memecoin) {
    //             // Selling memecoin for WETH
    //             (outputAmount, newPrice) = strategy.calculateSell(poolId, amountInOutPositive);

    //             // Verify we have enough WETH liquidity
    //             if (outputAmount > wethCollected) {
    //                 revert InsufficientLiquidity();
    //             }

    //             // Update pool state
    //             newCirculatingSupply = circulatingSupply - amountInOutPositive;
    //             newWethCollected = wethCollected - outputAmount;

    //             // Return WETH to user
    //             key.currency1.settle(poolManager, msg.sender, outputAmount, true);

    //             // Emit event
    //             emit TokensSold(poolId, msg.sender, amountInOutPositive, outputAmount, newPrice);
    //         } else {
    //             // Selling WETH for memecoin
    //             (outputAmount, newPrice) = strategy.calculateBuy(poolId, amountInOutPositive);

    //             // Update pool state
    //             newCirculatingSupply = circulatingSupply + outputAmount;
    //             newWethCollected = wethCollected + amountInOutPositive;

    //             // Return memecoin to user
    //             key.currency1.settle(poolManager, msg.sender, outputAmount, true);

    //             // Emit event
    //             emit TokensPurchased(poolId, msg.sender, amountInOutPositive, outputAmount, newPrice);
    //         }
    //     } else {
    //         // User is selling token1 and buying token0
    //         key.currency1.take(poolManager, address(this), amountInOutPositive, true);

    //         if (isToken0Memecoin) {
    //             // Selling WETH for memecoin
    //             (outputAmount, newPrice) = strategy.calculateBuy(poolId, amountInOutPositive);

    //             // Update pool state
    //             newCirculatingSupply = circulatingSupply + outputAmount;
    //             newWethCollected = wethCollected + amountInOutPositive;

    //             // Return memecoin to user
    //             key.currency0.settle(poolManager, msg.sender, outputAmount, true);

    //             // Emit event
    //             emit TokensPurchased(poolId, msg.sender, amountInOutPositive, outputAmount, newPrice);
    //         } else {
    //             // Selling memecoin for WETH
    //             (outputAmount, newPrice) = strategy.calculateSell(poolId, amountInOutPositive);

    //             // Verify we have enough WETH liquidity
    //             if (outputAmount > wethCollected) {
    //                 revert InsufficientLiquidity();
    //             }

    //             // Update pool state
    //             newCirculatingSupply = circulatingSupply - amountInOutPositive;
    //             newWethCollected = wethCollected - outputAmount;

    //             // Return WETH to user
    //             key.currency0.settle(poolManager, msg.sender, outputAmount, true);

    //             // Emit event
    //             emit TokensSold(poolId, msg.sender, amountInOutPositive, outputAmount, newPrice);
    //         }
    //     }

    //     // Update the pool state in the manager
    //     poolStateManager.updatePoolState(poolId, newCirculatingSupply, newWethCollected, newPrice);

    //     // Calculate the appropriate delta
    //     // BeforeSwapDelta beforeSwapDelta;
    //     // if (params.zeroForOne) {
    //     //     beforeSwapDelta = toBeforeSwapDelta(int128), -int128(int256(outputAmount)));
    //     // } else {
    //     //     beforeSwapDelta = toBeforeSwapDelta(-int128(int256(outputAmount)), int128(int256(amountInOutPositive)));
    //     // }

    //     BeforeSwapDelta beforeSwapDelta =
    //         toBeforeSwapDelta(int128(-params.amountSpecified), int128(int256(outputAmount)));

    //     return (this.beforeSwap.selector, beforeSwapDelta, 0);
    // }

    /**
     * @notice Get the liquidity balance of a user in a specific pool
     * @param user User address
     * @param poolId Pool ID
     * @return User's liquidity amount
     */
    function getUserLiquidity(address user, bytes32 poolId) external view returns (uint256) {
        return userLiquidity[user][poolId];
    }

    /**
     * @notice Get the total liquidity in a specific pool
     * @param poolId Pool ID
     * @return Total pool liquidity
     */
    function getPoolLiquidity(bytes32 poolId) external view returns (uint256) {
        return totalPoolLiquidity[poolId];
    }

    /**
     * @notice Get the current WETH price in USD
     * @return Current WETH price from oracle
     */
    function getCurrentWethPrice() external view returns (uint256) {
        return wethPriceOracle.getWethPrice();
    }
}
