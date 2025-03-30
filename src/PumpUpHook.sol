// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks, IHooks} from "v4-core/libraries/Hooks.sol";
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
import {console} from "forge-std/console.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {MemeGuardAVS} from "./helpers/MemeGuardAVS.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

contract PumpUpHook is Initializable, BaseHook, BondingCurveSwap, MemeGuardAVS {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using CustomRevert for bytes4;
    using PoolIdLibrary for PoolKey;

    error PoolNotTransitioned();
    error PoolTransitioned();
    error InvalidAmount();
    // Add these error types to your contract
    error TransitionConditionsNotMet();

    error UnexpectedOperation();
    error ZeroAddress();

    // Track liquidity provided by each user for each pool
    mapping(address user => mapping(bytes32 poolId => mapping(address token => uint256 amount))) public userLiquidity;

    // // Track total liquidity for each pool
    // mapping(bytes32 poolId => uint256 liquidity) public totalPoolLiquidity;

    // WETH price oracle contract
    IPriceOracle private wethPriceOracle;

    PoolModifyLiquidityTest private modifyLiquidityRouter;

    struct CallbackData {
        uint256 amount0;
        uint256 amount1;
        Currency currency0;
        Currency currency1;
        address sender;
        bool isRemove;
        bytes32 poolId;
    }

    struct LiquidityParams {
        uint256 amount0;
        uint256 amount1;
        bytes32 poolId;
    }

    // Add this event to your contract
    event PoolTransitionedToV4(
        bytes32 indexed poolId, uint256 memecoinLiquidity, uint256 wethLiquidity, uint256 price, uint256 timestamp
    );
    // Events
    event LiquidityAdded(bytes32 indexed poolId, address indexed user, uint256 amount0, uint256 amount1);
    event LiquidityRemoved(bytes32 indexed poolId, address indexed user, uint256 amount0, uint256 amount1);

    constructor(IPoolManager _manager, address _avsContract) BaseHook(_manager) MemeGuardAVS(_avsContract) {}

    function initialize(address _poolStateManager, address _wethPriceOracle, address _wethAddress, address _lprouter)
        external
        initializer
    {
        if (_poolStateManager == address(0) || _wethPriceOracle == address(0) || _wethAddress == address(0)) {
            ZeroAddress.selector.revertWith();
        }
        wethPriceOracle = IPriceOracle(_wethPriceOracle);
        modifyLiquidityRouter = PoolModifyLiquidityTest(_lprouter);
        initializeBondingCurveSwap(IPoolStateManager(_poolStateManager), _wethAddress);
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
    function addLiquidity(PoolKey calldata params, LiquidityParams calldata liquidityParams, address caller) external {
        if (liquidityParams.amount0 == 0 && liquidityParams.amount1 == 0) InvalidAmount.selector.revertWith();
        if (caller == msg.sender || msg.sender == address(poolStateManager)) {
            // Only allow adding liquidity via this method if pool hasn't transitioned
            // After transition, liquidity should be added through regular Uniswap functions
            bool isTransitioned = poolStateManager.isPoolTransitioned(liquidityParams.poolId);
            if (isTransitioned) PoolTransitioned.selector.revertWith();

            // Check strategy risk if AVS is enabled
            (bool allowed,,,) = checkTokenRisk(liquidityParams.poolId);
            if (!allowed) HealthFactorNotPassed.selector.revertWith();

            // Get token addresses
            address token0Address = Currency.unwrap(params.currency0);
            address token1Address = Currency.unwrap(params.currency1);

            // Update liquidity tracking
            unchecked {
                userLiquidity[caller][liquidityParams.poolId][token0Address] += liquidityParams.amount0;
                userLiquidity[caller][liquidityParams.poolId][token1Address] += liquidityParams.amount1;
            }

            // Call to unlock for token transfers
            poolManager.unlock(
                abi.encode(
                    CallbackData({
                        amount0: liquidityParams.amount0,
                        amount1: liquidityParams.amount1,
                        currency0: params.currency0,
                        currency1: params.currency1,
                        sender: msg.sender,
                        isRemove: false,
                        poolId: liquidityParams.poolId
                    })
                )
            );

            emit LiquidityAdded(liquidityParams.poolId, caller, liquidityParams.amount0, liquidityParams.amount1);
        } else {
            UnexpectedOperation.selector.revertWith();
        }
    }

    /**
     * @notice Remove liquidity from the bonding curve (pre-transition)
     * @param params Pool key
     * @param liquidityParams Parameters including amount and pool ID
     */
    function removeLiquidity(PoolKey calldata params, LiquidityParams calldata liquidityParams) external {
        if (liquidityParams.amount0 == 0 && liquidityParams.amount1 == 0) InvalidAmount.selector.revertWith();

        // Only allow removing liquidity via this method if pool hasn't transitioned
        bool isTransitioned = poolStateManager.isPoolTransitioned(liquidityParams.poolId);
        if (isTransitioned) PoolTransitioned.selector.revertWith();

        // Check strategy risk if AVS is enabled
        (bool allowed,,,) = checkTokenRisk(liquidityParams.poolId);
        if (!allowed) HealthFactorNotPassed.selector.revertWith();

        // Get token addresses
        address token0Address = Currency.unwrap(params.currency0);
        address token1Address = Currency.unwrap(params.currency1);

        // address memecoin = poolStateManager.memecoinId(liquidityParams.poolId);

        // bool isMemecoinCurrency0 = memecoin == token0Address ? true:false;

        // Check if user has enough liquidity
        if (
            userLiquidity[msg.sender][liquidityParams.poolId][token0Address] < liquidityParams.amount0
                || userLiquidity[msg.sender][liquidityParams.poolId][token1Address] < liquidityParams.amount1
        ) {
            InsufficientLiquidity.selector.revertWith();
        }

        // console.log("Unchecked Start");

        unchecked {
            // Update liquidity tracking
            userLiquidity[msg.sender][liquidityParams.poolId][token0Address] -= liquidityParams.amount0;
            userLiquidity[msg.sender][liquidityParams.poolId][token1Address] -= liquidityParams.amount1;
        }

        // console.log("Unchecked Finish");

        // Call to unlock for token transfers
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    amount0: liquidityParams.amount0,
                    amount1: liquidityParams.amount1,
                    currency0: params.currency0,
                    currency1: params.currency1,
                    sender: msg.sender,
                    isRemove: true,
                    poolId: liquidityParams.poolId
                })
            )
        );

        emit LiquidityRemoved(liquidityParams.poolId, msg.sender, liquidityParams.amount0, liquidityParams.amount1);
    }

    // /**
    //  * @notice Handle token transfers during unlock
    //  * @param data Callback data
    //  * @return Empty bytes
    //  */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        (
            address tokenAddress,
            address bondingCurveImplementation,
            uint256 currentCirculatingSupply,
            uint256 currentWethCollected,
            uint256 currentPrice
        ) = poolStateManager.getInfoForHook(callbackData.poolId);

        // Get token addresses
        address token0Address = Currency.unwrap(callbackData.currency0);

        bool isMemecoinCurrency0 = tokenAddress == token0Address ? true : false;
        uint256 newCirculatingSupply;
        uint256 newWethCollected;

        // console.log("I'm here at unclock Step 1");

        if (callbackData.isRemove) {
            // For removing liquidity:
            // 1. Burn our claim tokens (settle with burn=true)
            // 2. Transfer actual tokens to the user (take with claims=false)

            // For currency0, burn claim tokens and transfer actual tokens to the user
            if (callbackData.amount0 > 0) {
                // Burn claim tokens first (give up our claim to tokens in the PoolManager)
                callbackData.currency0.settle(poolManager, address(this), callbackData.amount0, true);

                // Then transfer the actual tokens from the PoolManager to the user
                poolManager.take(callbackData.currency0, callbackData.sender, callbackData.amount0);
            }

            // For currency1, burn claim tokens and transfer actual tokens to the user
            if (callbackData.amount1 > 0) {
                // Burn claim tokens first (give up our claim to tokens in the PoolManager)
                callbackData.currency1.settle(poolManager, address(this), callbackData.amount1, true);

                // Then transfer the actual tokens from the PoolManager to the user
                poolManager.take(callbackData.currency1, callbackData.sender, callbackData.amount1);
            }

            if (isMemecoinCurrency0) {
                // Calculate new circulating supply
                // console.log("I'm here at the first block");
                newCirculatingSupply = currentCirculatingSupply - callbackData.amount0;
                newWethCollected = currentWethCollected - callbackData.amount1;
            } else {
                // console.log("I'm here at the second block");
                newCirculatingSupply = currentCirculatingSupply - callbackData.amount1;
                newWethCollected = currentWethCollected - callbackData.amount0;
            }
        } else {
            // For adding liquidity:
            // Take tokens from user
            callbackData.currency0.settle(poolManager, callbackData.sender, callbackData.amount0, false);
            callbackData.currency1.settle(poolManager, callbackData.sender, callbackData.amount1, false);

            // Move tokens to hook
            callbackData.currency0.take(poolManager, address(this), callbackData.amount0, true);
            callbackData.currency1.take(poolManager, address(this), callbackData.amount1, true);

            if (isMemecoinCurrency0) {
                // Calculate new circulating supply
                newCirculatingSupply = currentCirculatingSupply + callbackData.amount0;
                newWethCollected = currentWethCollected + callbackData.amount1;
            } else {
                newCirculatingSupply = currentCirculatingSupply + callbackData.amount1;
                newWethCollected = currentWethCollected + callbackData.amount0;
            }
        }

        // Calculate new price using bonding curve strategy
        IBondingCurveStrategy strategy = IBondingCurveStrategy(bondingCurveImplementation);
        uint256 newPrice = strategy.getCurrentPrice(callbackData.poolId);

        // Update pool state in the PoolStateManager
        poolStateManager.updatePoolState(callbackData.poolId, newCirculatingSupply, newWethCollected, newPrice);

        (bool canTransition, bool isSafe) = poolStateManager.checkTransitionConditions_With_AVS(callbackData.poolId);

        // check if the pool transition can take place after the
        if (canTransition && isSafe) {
            transitionToV4Pool(callbackData.currency0, callbackData.currency1, callbackData.poolId);
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
        // console.log("assadad");

        if (!isTransitioned) {
            // console.log("Pre Transition phase");
            // Check strategy risk if AVS is enabled
            (bool allowed,,,) = checkTokenRisk(poolId);
            if (!allowed) HealthFactorNotPassed.selector.revertWith();
            // For bonding curve swaps
            BeforeSwapDelta beoforeSwapDelta = handleBondingCurveSwap(key, params, poolId, msg.sender);
            return (this.beforeSwap.selector, beoforeSwapDelta, 0);
        } else {
            // For V4 pool swaps, just return the selector to allow default V4 swap behavior
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
    }

    /**
     * @notice Get the liquidity balance of a user in a specific pool
     * @param user User address
     * @param poolId Pool ID
     * @return User's liquidity amount
     */
    function getUserLiquidity(address user, bytes32 poolId, address token) external view returns (uint256) {
        return userLiquidity[user][poolId][token];
    }

    /**
     * @notice Get the current WETH price in USD
     * @return Current WETH price from oracle
     */
    function getCurrentWethPrice() external view returns (uint256) {
        return wethPriceOracle.getWethPrice();
    }

    /**
     * @notice Abstract function to enable/disable risk assessment
     */
    function toggleRiskAssessmentEnabled() external onlyPoolStateManager {
        riskAssessmentEnabled = !riskAssessmentEnabled;
    }

    /**
     * @notice Abstract function to set risk thresholds
     * @param _strategyRiskThreshold Maximum allowed strategy risk score
     * @param _tokenRiskThreshold Maximum allowed token risk score
     * @param _transitionRiskThreshold Maximum allowed transition risk score
     */
    function setRiskThresholds(uint8 _strategyRiskThreshold, uint8 _tokenRiskThreshold, uint8 _transitionRiskThreshold)
        public
        virtual
        override(MemeGuardAVS)
        onlyPoolStateManager
    {
        super.setRiskThresholds(_strategyRiskThreshold, _tokenRiskThreshold, _transitionRiskThreshold);
    }

    /**
     * @notice Transition liquidity from bonding curve to V4 pool
     * @param currency0 Pool key for the V4 pool
     * @param currency1 Currency 1
     * @param poolId Identifier for the pool
     * @dev This function moves all liquidity from the bonding curve mechanism to a standard V4 pool
     */
    function transitionToV4Pool(Currency currency0, Currency currency1, bytes32 poolId) internal {
        // 2. Check if pool has already transitioned
        bool isTransitioned = poolStateManager.isPoolTransitioned(poolId);
        if (isTransitioned) PoolTransitioned.selector.revertWith();

        // 4. Get token addresses and current pool state
        address token0Address = Currency.unwrap(currency0);
        address token1Address = Currency.unwrap(currency1);

        (address memecoinAddress,, uint256 currentCirculatingSupply, uint256 currentWethCollected, uint256 currentPrice)
        = poolStateManager.getInfoForHook(poolId);

        // 5. Determine which token is the memecoin
        bool isMemecoinCurrency0 = (memecoinAddress == token0Address);

        IERC20 token0Dispatcher = IERC20(token0Address);
        IERC20 token1Dispatcher = IERC20(token1Address);
        // 6. Calculate initial liquidity for V4 pool based on bonding curve state
        uint256 memecoinLiquidity = currentCirculatingSupply;
        uint256 wethLiquidity = currentWethCollected;

        uint160 sqrtPriceX96 = calculateSqrtPriceX96(currentPrice, isMemecoinCurrency0);

        uint128 liq;

        PoolKey memory poolKey = PoolKey(currency0, currency1, 0, 60, IHooks(address(this)));

        // This will set the initial price of the pool
        poolManager.initialize(poolKey, sqrtPriceX96);

        int24 MIN_TICK = -887272;
        int24 MAX_TICK = 887272;

        if (isMemecoinCurrency0) {
            // Burn claim tokens first (give up our claim to tokens in the PoolManager)
            currency0.settle(poolManager, address(this), memecoinLiquidity, true);

            // Then transfer the actual tokens from the PoolManager to the user
            poolManager.take(currency0, address(this), memecoinLiquidity);

            // Burn claim tokens first (give up our claim to tokens in the PoolManager)
            currency1.settle(poolManager, address(this), wethLiquidity, true);

            // Then transfer the actual tokens from the PoolManager to the user
            poolManager.take(currency1, address(this), wethLiquidity);

            liq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(MIN_TICK),
                TickMath.getSqrtPriceAtTick(MAX_TICK),
                wethLiquidity,
                token0Dispatcher.balanceOf(address(this))
            );
        } else {
            // Burn claim tokens first (give up our claim to tokens in the PoolManager)
            currency0.settle(poolManager, address(this), wethLiquidity, true);

            // Then transfer the actual tokens from the PoolManager to the Hook
            poolManager.take(currency1, address(this), wethLiquidity);
            // Burn claim tokens first (give up our claim to tokens in the PoolManager)
            currency1.settle(poolManager, address(this), memecoinLiquidity, true);

            // Then transfer the actual tokens from the PoolManager to the Hook
            poolManager.take(currency0, address(this), memecoinLiquidity);

            liq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(MIN_TICK),
                TickMath.getSqrtPriceAtTick(MAX_TICK),
                wethLiquidity,
                token1Dispatcher.balanceOf(address(this))
            );
        }
        token0Dispatcher.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1Dispatcher.approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(int128(liq)), 0
            ),
            new bytes(0)
        );

        // 11. Mark the pool as transitioned in the pool state manager
        poolStateManager.setPoolTransitioned(poolId, true);

        // 12. Emit event for the transition
        emit PoolTransitionedToV4(poolId, memecoinLiquidity, wethLiquidity, currentPrice, block.timestamp);
    }

    /**
     * @notice Calculate the square root price for V4 pool initialization
     * @param price Current price from bonding curve
     * @param isMemecoinCurrency0 Whether the memecoin is currency0
     * @return sqrtPriceX96 Square root price in Q64.96 format
     */
    function calculateSqrtPriceX96(uint256 price, bool isMemecoinCurrency0) internal pure returns (uint160) {
        // If the memecoin is currency0, we need to invert the price
        uint256 adjustedPrice = isMemecoinCurrency0 ? 1e18 / price : price;

        // Calculate sqrt(price) * 2^96
        uint256 sqrtPrice = sqrt(adjustedPrice * 1e18); // Scale by 10^18 for precision
        uint256 sqrtPriceX96Value = (sqrtPrice * (1 << 96)) / 1e9; // Convert to Q64.96

        return uint160(sqrtPriceX96Value);
    }

    /**
     * @notice Simple implementation of square root function
     * @param x Value to take the square root of
     * @return y The square root of x
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;

        // Initial estimate
        uint256 z = (x + 1) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /**
     * @notice Simple implementation of log base 2
     * @param x Value to take the log of
     * @return y The log base 2 of x
     */
    function log2(uint256 x) internal pure returns (uint256 y) {
        // This is a simplified binary search approach
        // In production, use a proper logarithm implementation

        uint256 n = 0;

        if (x >= 2 ** 128) {
            x >>= 128;
            n += 128;
        }
        if (x >= 2 ** 64) {
            x >>= 64;
            n += 64;
        }
        if (x >= 2 ** 32) {
            x >>= 32;
            n += 32;
        }
        if (x >= 2 ** 16) {
            x >>= 16;
            n += 16;
        }
        if (x >= 2 ** 8) {
            x >>= 8;
            n += 8;
        }
        if (x >= 2 ** 4) {
            x >>= 4;
            n += 4;
        }
        if (x >= 2 ** 2) {
            x >>= 2;
            n += 2;
        }
        if (x >= 2 ** 1) n += 1;

        // Return scaled by 1e18 for precision
        return n * 1e18;
    }
}
