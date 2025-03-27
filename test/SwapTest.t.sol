// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestHelper} from "./TestHelper.t.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IBondingCurveStrategy} from "../src/interfaces/IBondingCurveStrategy.sol";
import {PumpUpHook} from "../src/PumpUpHook.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolStateManager} from "../src/PoolStateManager.sol";

/**
 * @title BondingCurveSwapTest
 * @notice Comprehensive test suite for swap functionality in the bonding curve
 * @dev Tests buying/selling with exact input/output and various edge cases
 */
contract SwapTest is TestHelper {
    using CurrencyLibrary for Currency;

    // Pool configuration
    bytes32 public poolId;
    address public memecoin;
    uint256 public nftId;
    PoolKey public poolKey;
    bool public isWethCurrency0;

    // Test constants
    uint256 private constant TOTAL_SUPPLY = 100 ether;
    uint256 private constant PREMINE_AMOUNT = 1 ether;
    uint256 private constant INITIAL_WETH_AMOUNT = 50 ether;
    uint256 private constant LP_WETH_AMOUNT = 10 ether;
    uint256 private constant SWAP_WETH_AMOUNT = 2 ether;
    uint256 private constant SWAP_MEMECOIN_AMOUNT = 0.5 ether;
    uint256 private constant EXACT_OUTPUT_AMOUNT = 0.1 ether;

    // Struct to capture state before and after swaps
    struct SwapState {
        uint256 userWethBalance;
        uint256 userMemecoinBalance;
        uint256 circulatingSupply;
        uint256 wethCollected;
        uint256 price;
    }

    /**
     * @notice Set up test environment
     */
    function setUp() public {
        // Deploy protocol contracts
        deployProtocol();

        // Create and initialize pool
        _createAndInitializePool();

        // Determine token ordering
        isWethCurrency0 = (Currency.unwrap(poolKey.currency0) == wethAddress);

        // Add liquidity for swap tests
        _addLiquidity(LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        // Set up trader for swap tests
        _setupTrader();
    }

    /*//////////////////////////////////////////////////////////////
                               BUY TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test buying memecoin with exact WETH input
     */
    function test_BuyExactInput() public {
        SwapState memory initialState = _captureSwapState();
        uint256 inputAmount = SWAP_WETH_AMOUNT;

        vm.startPrank(TRADER);

        // Execute buy
        _executeSwap(
            isWethCurrency0, // zeroForOne - depends on token ordering
            -int256(inputAmount), // amountSpecified - negative for exact input
            false // isExactOutput - false for exact input
        );

        vm.stopPrank();

        SwapState memory finalState = _captureSwapState();

        // Verify user balances
        assertEq(
            finalState.userWethBalance,
            initialState.userWethBalance - inputAmount,
            "User's WETH balance should decrease by input amount"
        );

        assertTrue(
            finalState.userMemecoinBalance > initialState.userMemecoinBalance, "User should receive memecoin tokens"
        );

        uint256 tokensReceived = finalState.userMemecoinBalance - initialState.userMemecoinBalance;

        // Verify pool state
        assertEq(
            finalState.wethCollected,
            initialState.wethCollected + inputAmount,
            "WETH collected should increase by input amount"
        );

        assertEq(
            finalState.circulatingSupply,
            initialState.circulatingSupply - tokensReceived,
            "Circulating supply should decrease by tokens received"
        );

        assertTrue(finalState.price > initialState.price, "Price should increase after buying");

        emit log_named_uint("WETH spent", inputAmount);
        emit log_named_uint("Memecoin received", tokensReceived);
        emit log_named_uint("Price impact", finalState.price - initialState.price);
    }

    /**
     * @notice Test buying exact amount of memecoin with WETH
     */
    function test_BuyExactOutput() public {
        // Skip test if exact output not supported by the strategy
        IBondingCurveStrategy strategy = IBondingCurveStrategy(strategyManager.getStrategyImplementation(ecStrategyId));
        try strategy.calculateWethForExactTokens(poolId, 1) returns (uint256, uint256) {
            // Test is supported
        } catch {
            emit log("Exact output not supported by strategy - skipping test");
            return;
        }

        SwapState memory initialState = _captureSwapState();
        uint256 outputAmount = EXACT_OUTPUT_AMOUNT;

        vm.startPrank(TRADER);

        // Execute buy with exact output
        _executeSwap(
            isWethCurrency0, // zeroForOne - depends on token ordering
            int256(outputAmount), // amountSpecified - positive for exact output
            true // isExactOutput - true for exact output
        );

        vm.stopPrank();

        SwapState memory finalState = _captureSwapState();

        // Verify user balances
        assertTrue(finalState.userWethBalance < initialState.userWethBalance, "User's WETH balance should decrease");

        uint256 wethSpent = initialState.userWethBalance - finalState.userWethBalance;

        assertEq(
            finalState.userMemecoinBalance,
            initialState.userMemecoinBalance + outputAmount,
            "User should receive exact memecoin amount requested"
        );

        // Verify pool state
        assertEq(
            finalState.wethCollected,
            initialState.wethCollected + wethSpent,
            "WETH collected should increase by amount spent"
        );

        assertEq(
            finalState.circulatingSupply,
            initialState.circulatingSupply - outputAmount,
            "Circulating supply should decrease by exact output amount"
        );

        assertTrue(finalState.price > initialState.price, "Price should increase after buying");

        emit log_named_uint("WETH spent", wethSpent);
        emit log_named_uint("Memecoin received", outputAmount);
    }

    /*//////////////////////////////////////////////////////////////
                               SELL TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test selling memecoin for WETH with exact input
     */
    function test_SellExactInput() public {
        // Ensure trader has memecoin to sell
        vm.prank(CURATOR);
        IERC20Minimal(memecoin).transfer(TRADER, SWAP_MEMECOIN_AMOUNT);

        SwapState memory initialState = _captureSwapState();
        uint256 inputAmount = SWAP_MEMECOIN_AMOUNT;

        vm.startPrank(TRADER);

        // Approve memecoin spending
        IERC20Minimal(memecoin).approve(address(swapRouter), inputAmount);

        // Execute sell
        _executeSwap(
            !isWethCurrency0, // zeroForOne - opposite of buy direction
            -int256(inputAmount), // amountSpecified - negative for exact input
            false // isExactOutput - false for exact input
        );

        vm.stopPrank();

        SwapState memory finalState = _captureSwapState();

        // Verify user balances
        assertTrue(finalState.userWethBalance > initialState.userWethBalance, "User's WETH balance should increase");

        uint256 wethReceived = finalState.userWethBalance - initialState.userWethBalance;

        assertEq(
            finalState.userMemecoinBalance,
            initialState.userMemecoinBalance - inputAmount,
            "User's memecoin balance should decrease by input amount"
        );

        // Verify pool state
        assertEq(
            finalState.wethCollected,
            initialState.wethCollected - wethReceived,
            "WETH collected should decrease by amount received by user"
        );

        assertEq(
            finalState.circulatingSupply,
            initialState.circulatingSupply + inputAmount,
            "Circulating supply should increase by amount sold"
        );

        assertTrue(finalState.price < initialState.price, "Price should decrease after selling");

        emit log_named_uint("Memecoin sold", inputAmount);
        emit log_named_uint("WETH received", wethReceived);
        emit log_named_uint("Price impact", initialState.price - finalState.price);
    }

    /**
     * @notice Test selling memecoin for exact WETH output
     */
    function test_SellExactOutput() public {
        // Skip test if exact output not supported by the strategy
        IBondingCurveStrategy strategy = IBondingCurveStrategy(strategyManager.getStrategyImplementation(ecStrategyId));
        try strategy.calculateTokensForExactWeth(poolId, 1) returns (uint256, uint256) {
            // Test is supported
        } catch {
            emit log("Exact output not supported by strategy - skipping test");
            return;
        }

        // Ensure trader has sufficient memecoin to sell
        vm.prank(CURATOR);
        IERC20Minimal(memecoin).transfer(TRADER, 1 ether); // More than enough for the test

        SwapState memory initialState = _captureSwapState();
        uint256 outputAmount = EXACT_OUTPUT_AMOUNT;

        vm.startPrank(TRADER);

        // Approve memecoin spending
        IERC20Minimal(memecoin).approve(address(swapRouter), type(uint256).max);

        // Execute sell with exact output
        _executeSwap(
            !isWethCurrency0, // zeroForOne - opposite of buy direction
            int256(outputAmount), // amountSpecified - positive for exact output
            true // isExactOutput - true for exact output
        );

        vm.stopPrank();

        SwapState memory finalState = _captureSwapState();

        // Verify user balances
        assertEq(
            finalState.userWethBalance,
            initialState.userWethBalance + outputAmount,
            "User should receive exact WETH amount requested"
        );

        assertTrue(
            finalState.userMemecoinBalance < initialState.userMemecoinBalance, "User's memecoin balance should decrease"
        );

        uint256 memecoinSold = initialState.userMemecoinBalance - finalState.userMemecoinBalance;

        // Verify pool state
        assertEq(
            finalState.wethCollected,
            initialState.wethCollected - outputAmount,
            "WETH collected should decrease by exact output amount"
        );

        assertEq(
            finalState.circulatingSupply,
            initialState.circulatingSupply + memecoinSold,
            "Circulating supply should increase by amount sold"
        );

        assertTrue(finalState.price < initialState.price, "Price should decrease after selling");

        emit log_named_uint("Memecoin sold", memecoinSold);
        emit log_named_uint("WETH received", outputAmount);
    }

    /*//////////////////////////////////////////////////////////////
                          EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test swapping with very small amounts
     */
    function test_SwapWithSmallAmounts() public {
        uint256 tinyAmount = 0.0001 ether;

        // Test small buy
        vm.startPrank(TRADER);

        SwapState memory preBuyState = _captureSwapState();

        _executeSwap(isWethCurrency0, -int256(tinyAmount), false);

        SwapState memory postBuyState = _captureSwapState();

        assertTrue(
            postBuyState.userMemecoinBalance > preBuyState.userMemecoinBalance,
            "User should receive memecoin even with tiny WETH input"
        );

        // Test small sell if user received tokens
        uint256 receivedTokens = postBuyState.userMemecoinBalance - preBuyState.userMemecoinBalance;
        if (receivedTokens > 0) {
            IERC20Minimal(memecoin).approve(address(swapRouter), receivedTokens);

            SwapState memory preSellState = _captureSwapState();

            _executeSwap(!isWethCurrency0, -int256(receivedTokens), false);

            SwapState memory postSellState = _captureSwapState();

            assertTrue(
                postSellState.userWethBalance > preSellState.userWethBalance,
                "User should receive WETH even with tiny memecoin input"
            );
        }

        vm.stopPrank();
    }

    /**
     * @notice Test buying with large amounts (approaching available liquidity)
     */
    function test_LargeBuy() public {
        // Get current pool state
        (uint256 circulatingSupply, uint256 wethCollected,) = _getPoolState();

        // Calculate a large but valid amount that's 90% of available WETH
        uint256 largeAmount = wethCollected * 9 / 10;

        vm.startPrank(TRADER);
        weth.mint(TRADER, largeAmount);
        weth.approve(address(swapRouter), largeAmount);

        SwapState memory initialState = _captureSwapState();

        // Execute large buy
        _executeSwap(isWethCurrency0, -int256(largeAmount), false);

        SwapState memory finalState = _captureSwapState();

        // Verify the buy was successful
        assertTrue(
            finalState.userMemecoinBalance > initialState.userMemecoinBalance,
            "User should receive memecoin for large WETH input"
        );

        // Verify significant price impact
        assertTrue(finalState.price > initialState.price, "Large buy should have significant price impact");

        vm.stopPrank();
    }

    /**
     * @notice Test behavior when attempting to exceed available liquidity
     */
    function test_ExceedingAvailableLiquidity() public {
        // Get current pool state
        (uint256 circulatingSupply, uint256 wethCollected,) = _getPoolState();

        // Attempt to buy with more than available WETH
        uint256 excessiveAmount = wethCollected * 2;

        vm.startPrank(TRADER);
        weth.mint(TRADER, excessiveAmount);
        weth.approve(address(swapRouter), excessiveAmount);

        // This should either revert or return very small number of tokens
        try this.executeSwapAsExternal(isWethCurrency0, -int256(excessiveAmount), false) {
            // If it doesn't revert, we should check token received is reasonable
            SwapState memory state = _captureSwapState();
            assertTrue(state.circulatingSupply > 0, "Swap should not drain all circulating supply");
        } catch {
            // Expected revert for insufficient liquidity is acceptable
        }

        vm.stopPrank();
    }

    /**
     * @notice Test buying and selling in quick succession
     */
    function test_BuySellRoundtrip() public {
        uint256 buyAmount = 1 ether;

        vm.startPrank(TRADER);
        weth.mint(TRADER, buyAmount);
        weth.approve(address(swapRouter), buyAmount);

        SwapState memory initialState = _captureSwapState();

        // Execute buy
        _executeSwap(isWethCurrency0, -int256(buyAmount), false);

        SwapState memory postBuyState = _captureSwapState();
        uint256 tokensReceived = postBuyState.userMemecoinBalance - initialState.userMemecoinBalance;

        // Now sell all received tokens
        IERC20Minimal(memecoin).approve(address(swapRouter), tokensReceived);

        _executeSwap(!isWethCurrency0, -int256(tokensReceived), false);

        SwapState memory finalState = _captureSwapState();

        // Due to slippage, final WETH should be less than initial
        assertTrue(
            finalState.userWethBalance < initialState.userWethBalance,
            "User should have less WETH after roundtrip due to slippage"
        );

        // Calculate slippage percentage
        uint256 slippageAmount = initialState.userWethBalance - finalState.userWethBalance;
        uint256 slippagePercentage = slippageAmount * 100 / buyAmount;

        emit log_named_uint("Buy-sell roundtrip slippage percentage", slippagePercentage);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute a swap operation
     * @param zeroForOne Whether the swap is selling token0 for token1
     * @param amountSpecified The amount specified for the swap (negative for exact input, positive for exact output)
     * @param isExactOutput Whether the swap is exact output
     */
    function _executeSwap(bool zeroForOne, int256 amountSpecified, bool isExactOutput) internal {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        bytes memory data = abi.encode(poolId);

        uint160 sqrtPriceLimitX96;
        if (isExactOutput) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        } else {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            settings,
            data
        );
    }

    /**
     * @notice External wrapper to allow try/catch on swap execution
     */
    function executeSwapAsExternal(bool zeroForOne, int256 amountSpecified, bool isExactOutput) external {
        _executeSwap(zeroForOne, amountSpecified, isExactOutput);
    }

    /**
     * @notice Helper to create and initialize a pool
     */
    function _createAndInitializePool() internal {
        // Define launch parameters
        PoolStateManager.LaunchParams memory launchParams = PoolStateManager.LaunchParams({
            name: "TEST",
            symbol: "TEST",
            tokenUri: "TEST",
            initialSupply: TOTAL_SUPPLY,
            creator: CURATOR,
            premineAmount: PREMINE_AMOUNT
        });

        // Define transition parameters
        PoolStateManager.TransitionConfig memory transitionConfig = PoolStateManager.TransitionConfig({
            transitionType: PoolStateManager.TransitionType.Percentage,
            transitionData: 50
        });

        // Fund creator for initialization
        deal(wethAddress, CURATOR, INITIAL_WETH_AMOUNT);

        // Create and initialize the pool
        vm.startPrank(CURATOR);
        (poolId, memecoin, nftId) =
            poolStateManager.createPumpUp{value: POOL_CREATION_FEE}(launchParams, ecStrategyId, transitionConfig);

        // Initialize the pool with WETH
        IERC20Minimal(wethAddress).approve(address(poolStateManager), INITIAL_WETH_AMOUNT);
        (Currency currency0, Currency currency1) = poolStateManager.initializePool(INITIAL_WETH_AMOUNT, poolId);
        vm.stopPrank();

        // Create pool key for tests
        poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: pumpUpHook});
    }

    /**
     * @notice Helper to add liquidity to the pool
     * @param provider The address providing liquidity
     * @param wethAmount The amount of WETH to add
     */
    function _addLiquidity(address provider, uint256 wethAmount) internal {
        // Fund the provider
        deal(wethAddress, provider, wethAmount);

        vm.startPrank(provider);

        // Approve WETH for the hook
        IERC20Minimal(wethAddress).approve(address(pumpUpHook), wethAmount);

        // Add liquidity
        PumpUpHook.LiquidityParams memory liquidityParams = PumpUpHook.LiquidityParams({
            amount0: isWethCurrency0 ? wethAmount : 0,
            amount1: isWethCurrency0 ? 0 : wethAmount,
            poolId: poolId
        });

        pumpUpHook.addLiquidity(poolKey, liquidityParams, provider);

        vm.stopPrank();
    }

    /**
     * @notice Setup the trader for swap tests
     */
    function _setupTrader() internal {
        // Initial WETH for trader
        deal(wethAddress, TRADER, 10 ether);

        // Approvals
        vm.startPrank(TRADER);
        IERC20Minimal(wethAddress).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /**
     * @notice Helper to get user token balances and pool state before/after swaps
     * @return state Struct containing relevant balances and pool state
     */
    function _captureSwapState() internal view returns (SwapState memory state) {
        state.userWethBalance = IERC20Minimal(wethAddress).balanceOf(TRADER);
        state.userMemecoinBalance = IERC20Minimal(memecoin).balanceOf(TRADER);
        (state.circulatingSupply, state.wethCollected, state.price) = _getPoolState();
        return state;
    }

    /**
     * @notice Helper to get the current pool state
     * @return circulatingSupply The current circulating supply
     * @return wethCollected The current WETH collected
     * @return price The current price
     */
    function _getPoolState() internal view returns (uint256 circulatingSupply, uint256 wethCollected, uint256 price) {
        (,, circulatingSupply, wethCollected, price) = poolStateManager.getInfoForHook(poolId);
    }
}
