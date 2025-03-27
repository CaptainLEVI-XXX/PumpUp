// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestHelper} from "./TestHelper.t.sol";
import {Test} from "forge-std/Test.sol";
import {PoolStateManager} from "../src/PoolStateManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PumpUpHook} from "../src/PumpUpHook.sol";
import {IBondingCurveStrategy} from "../src/interfaces/IBondingCurveStrategy.sol";
import {BondingCurveSwap} from "../src/helpers/BondingCurveHandler.sol";

/**
 * @title PumpUpHookTest
 * @notice Comprehensive test suite for the PumpUpHook contract
 * @dev Tests liquidity provision functionality for pre-transition pools
 */
contract PumpUpHookTest is Test, TestHelper {
    using CurrencyLibrary for Currency;

    // Test accounts
    address public constant CREATOR = address(0x111);
    address public constant UNAUTHORIZED_USER = address(0x222);

    // Test constants
    uint256 public constant PREMINE_AMOUNT = 1 ether;
    uint256 public constant TOTAL_SUPPLY = 100 ether;
    uint256 public constant INITIAL_WETH_AMOUNT = 50 ether;
    uint256 public constant LP_WETH_AMOUNT = 10 ether;

    // Pool-related variables
    bytes32 public poolId;
    address public memecoin;
    uint256 public nftId;
    PoolKey public poolKey;

    // Pool configuration
    PoolStateManager.LaunchParams public launchParams;
    PoolStateManager.TransitionConfig public transitionConfig;

    // Token sorting
    bool public isWethCurrency0;

    /**
     * @notice Set up the test environment before each test
     */
    function setUp() public {
        // Deploy the protocol contracts
        deployProtocol();

        // Fund the creator
        vm.deal(CREATOR, 1 ether);

        // Configure launch parameters
        launchParams = PoolStateManager.LaunchParams({
            name: "DOGE",
            symbol: "DOGE",
            tokenUri: "tokenUri",
            initialSupply: TOTAL_SUPPLY,
            creator: CREATOR,
            premineAmount: PREMINE_AMOUNT
        });

        // Configure transition parameters
        transitionConfig = PoolStateManager.TransitionConfig({
            transitionType: PoolStateManager.TransitionType.Percentage,
            transitionData: 50
        });

        // Create and initialize the pool
        _createAndInitializePool();

        // Determine token ordering
        isWethCurrency0 = (Currency.unwrap(currency0) == wethAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           CORE FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test pool creation and initialization
     */
    function test_PoolCreationAndInitialization() public {
        // Verify token allocation
        assertEq(IERC20Minimal(memecoin).balanceOf(CREATOR), PREMINE_AMOUNT, "Creator should have premine amount");
        assertEq(
            IERC20Minimal(memecoin).balanceOf(address(manager)),
            TOTAL_SUPPLY - PREMINE_AMOUNT,
            "PoolStateManager should have remaining tokens"
        );

        // Verify NFT was created
        assertEq(pumpUp.tokenId(memecoin), nftId, "NFT ID should match");

        // Verify initial liquidity in the hook
        (uint256 wethClaimBalance, uint256 memecoinClaimBalance) = _getHookClaimBalances();

        assertEq(wethClaimBalance, INITIAL_WETH_AMOUNT, "Hook should have claim tokens for WETH");
        assertEq(memecoinClaimBalance, TOTAL_SUPPLY - PREMINE_AMOUNT, "Hook should have claim tokens for memecoin");
    }

    /**
     * @notice Test adding liquidity
     */
    function test_AddLiquidity() public {
        // Add liquidity
        _addLiquidity(LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        // Verify liquidity tracking
        uint256 lpWethLiquidity = _getUserWethLiquidity(LIQUIDITY_PROVIDER);
        assertEq(lpWethLiquidity, LP_WETH_AMOUNT, "LP's tracked liquidity should match added amount");

        // Verify claim tokens in the hook
        (uint256 wethClaimBalance, uint256 memecoinClaimBalance) = _getHookClaimBalances();

        assertEq(
            wethClaimBalance, INITIAL_WETH_AMOUNT + LP_WETH_AMOUNT, "Hook should have increased claim tokens for WETH"
        );
        assertEq(
            memecoinClaimBalance,
            TOTAL_SUPPLY - PREMINE_AMOUNT,
            "Hook's claim tokens for memecoin should remain unchanged"
        );
    }

    /**
     * @notice Test removing liquidity
     */
    function test_RemoveLiquidity() public {
        // Add liquidity first
        _addLiquidity(LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        // Record initial balances
        uint256 initialWethBalance = IERC20Minimal(wethAddress).balanceOf(LIQUIDITY_PROVIDER);

        // Remove liquidity
        _removeLiquidity(LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        // Verify liquidity tracking has been updated
        uint256 remainingLiquidity = _getUserWethLiquidity(LIQUIDITY_PROVIDER);
        assertEq(remainingLiquidity, 0, "LP should have no remaining liquidity");

        // Verify token balances have been updated
        uint256 finalWethBalance = IERC20Minimal(wethAddress).balanceOf(LIQUIDITY_PROVIDER);
        assertEq(finalWethBalance, initialWethBalance + LP_WETH_AMOUNT, "LP should have received back their WETH");

        // Verify claim tokens in the hook have decreased
        (uint256 wethClaimBalance,) = _getHookClaimBalances();
        assertEq(wethClaimBalance, INITIAL_WETH_AMOUNT, "Hook should have decreased claim tokens for WETH");
    }

    /**
     * @notice Test removing partial liquidity
     */
    function test_RemovePartialLiquidity() public {
        // Add liquidity first
        _addLiquidity(LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        // Record initial balances
        uint256 initialWethBalance = IERC20Minimal(wethAddress).balanceOf(LIQUIDITY_PROVIDER);

        // Remove half of the added liquidity
        uint256 partialAmount = LP_WETH_AMOUNT / 2;
        _removeLiquidity(LIQUIDITY_PROVIDER, partialAmount);

        // Verify liquidity tracking has been updated
        uint256 remainingLiquidity = _getUserWethLiquidity(LIQUIDITY_PROVIDER);
        assertEq(remainingLiquidity, partialAmount, "LP should have half of their original liquidity remaining");

        // Verify token balances have been updated
        uint256 finalWethBalance = IERC20Minimal(wethAddress).balanceOf(LIQUIDITY_PROVIDER);
        assertEq(
            finalWethBalance, initialWethBalance + partialAmount, "LP should have received back half of their WETH"
        );

        // Verify claim tokens in the hook have decreased proportionally
        (uint256 wethClaimBalance,) = _getHookClaimBalances();
        assertEq(
            wethClaimBalance,
            INITIAL_WETH_AMOUNT + partialAmount,
            "Hook should have partial claim tokens for WETH remaining"
        );
    }

    /*//////////////////////////////////////////////////////////////
                             EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test adding zero liquidity (should revert)
     */
    function test_AddLiquidity_ZeroAmounts() public {
        vm.startPrank(LIQUIDITY_PROVIDER);

        PumpUpHook.LiquidityParams memory liquidityParams =
            PumpUpHook.LiquidityParams({amount0: 0, amount1: 0, poolId: poolId});

        // Should revert with InvalidAmount
        vm.expectRevert(PumpUpHook.InvalidAmount.selector);
        pumpUpHook.addLiquidity(poolKey, liquidityParams, LIQUIDITY_PROVIDER);

        vm.stopPrank();
    }

    /**
     * @notice Test removing more liquidity than provided (should revert)
     */
    function test_RemoveLiquidity_InsufficientLiquidity() public {
        // Add liquidity first
        _addLiquidity(LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        vm.startPrank(LIQUIDITY_PROVIDER);

        // Try to remove more than provided
        PumpUpHook.LiquidityParams memory excessiveParams = PumpUpHook.LiquidityParams({
            amount0: isWethCurrency0 ? LP_WETH_AMOUNT * 2 : 0,
            amount1: isWethCurrency0 ? 0 : LP_WETH_AMOUNT * 2,
            poolId: poolId
        });

        // Should revert with InsufficientLiquidity
        vm.expectRevert(BondingCurveSwap.InsufficientLiquidity.selector);
        pumpUpHook.removeLiquidity(poolKey, excessiveParams);

        vm.stopPrank();
    }

    /**
     * @notice Test authorization when adding liquidity for others
     */
    function test_AddLiquidity_Authorization() public {
        deal(wethAddress, UNAUTHORIZED_USER, LP_WETH_AMOUNT);

        vm.startPrank(UNAUTHORIZED_USER);
        IERC20Minimal(wethAddress).approve(address(pumpUpHook), LP_WETH_AMOUNT);

        PumpUpHook.LiquidityParams memory liquidityParams = PumpUpHook.LiquidityParams({
            amount0: isWethCurrency0 ? LP_WETH_AMOUNT : 0,
            amount1: isWethCurrency0 ? 0 : LP_WETH_AMOUNT,
            poolId: poolId
        });

        // Should revert when trying to add liquidity for someone else
        vm.expectRevert(PumpUpHook.UnexpectedOperation.selector);
        pumpUpHook.addLiquidity(poolKey, liquidityParams, LIQUIDITY_PROVIDER);

        // Should work when adding liquidity for self
        pumpUpHook.addLiquidity(poolKey, liquidityParams, UNAUTHORIZED_USER);

        vm.stopPrank();

        // Verify liquidity was added correctly
        uint256 userLiquidity = _getUserWethLiquidity(UNAUTHORIZED_USER);
        assertEq(userLiquidity, LP_WETH_AMOUNT, "User should have their liquidity recorded");
    }

    /*//////////////////////////////////////////////////////////////
                            MULTI-USER TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test multiple liquidity providers
     */
    function test_MultipleLiquidityProviders() public {
        // Set up two liquidity providers
        address LP1 = LIQUIDITY_PROVIDER;
        address LP2 = UNAUTHORIZED_USER;

        uint256 LP1_AMOUNT = 10 ether;
        uint256 LP2_AMOUNT = 5 ether;

        // LP1 adds liquidity
        _addLiquidity(LP1, LP1_AMOUNT);

        // LP2 adds liquidity
        _addLiquidity(LP2, LP2_AMOUNT);

        // Verify liquidity tracking
        uint256 lp1Liquidity = _getUserWethLiquidity(LP1);
        uint256 lp2Liquidity = _getUserWethLiquidity(LP2);

        assertEq(lp1Liquidity, LP1_AMOUNT, "LP1's tracked liquidity should match added amount");
        assertEq(lp2Liquidity, LP2_AMOUNT, "LP2's tracked liquidity should match added amount");

        // Verify total claim tokens in hook
        (uint256 wethClaimBalance,) = _getHookClaimBalances();

        assertEq(
            wethClaimBalance,
            INITIAL_WETH_AMOUNT + LP1_AMOUNT + LP2_AMOUNT,
            "Hook should have increased claim tokens for both LPs"
        );

        // LP1 removes liquidity
        uint256 initialLP1Balance = IERC20Minimal(wethAddress).balanceOf(LP1);
        _removeLiquidity(LP1, LP1_AMOUNT);

        // Verify LP1's liquidity is gone but LP2's remains
        lp1Liquidity = _getUserWethLiquidity(LP1);
        lp2Liquidity = _getUserWethLiquidity(LP2);

        assertEq(lp1Liquidity, 0, "LP1's tracked liquidity should be zero");
        assertEq(lp2Liquidity, LP2_AMOUNT, "LP2's tracked liquidity should be unchanged");

        // Verify LP1 received their tokens
        uint256 finalLP1Balance = IERC20Minimal(wethAddress).balanceOf(LP1);
        assertEq(finalLP1Balance, initialLP1Balance + LP1_AMOUNT, "LP1 should have received back their WETH");

        // Verify hook's claim tokens decreased correctly
        (wethClaimBalance,) = _getHookClaimBalances();
        assertEq(
            wethClaimBalance, INITIAL_WETH_AMOUNT + LP2_AMOUNT, "Hook should have decreased claim tokens for LP1 only"
        );
    }

    /*//////////////////////////////////////////////////////////////
                          STATE UPDATE TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test bonding curve state updates
     */
    function test_BondingCurveStateUpdates() public {
        // Get initial pool state
        (uint256 initialCirculatingSupply, uint256 initialWethCollected, uint256 initialPrice) = _getPoolState();

        // Add liquidity
        _addLiquidity(LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        // Get updated pool state after adding liquidity
        (uint256 midCirculatingSupply, uint256 midWethCollected, uint256 midPrice) = _getPoolState();

        // Verify state updates after adding liquidity
        assertEq(
            midWethCollected, initialWethCollected + LP_WETH_AMOUNT, "WETH collected should increase by added amount"
        );
        assertEq(
            midCirculatingSupply,
            initialCirculatingSupply,
            "Circulating supply should remain unchanged when adding only WETH"
        );

        // Remove liquidity
        _removeLiquidity(LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        // Get final pool state
        (uint256 finalCirculatingSupply, uint256 finalWethCollected, uint256 finalPrice) = _getPoolState();

        // Verify state updates after removing liquidity
        assertEq(finalWethCollected, initialWethCollected, "WETH collected should return to initial value");
        assertEq(finalCirculatingSupply, initialCirculatingSupply, "Circulating supply should return to initial value");

        // Price might change based on the bonding curve algorithm
        // This just checks that we're calculating a new price
        assertTrue(initialPrice > 0 && finalPrice > 0, "Price should be calculated for both states");
    }

    /*//////////////////////////////////////////////////////////////
                              EVENT TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test event emission
     */
    function test_EventEmission() public {
        deal(wethAddress, LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        vm.startPrank(LIQUIDITY_PROVIDER);
        IERC20Minimal(wethAddress).approve(address(pumpUpHook), LP_WETH_AMOUNT);

        PumpUpHook.LiquidityParams memory liquidityParams = PumpUpHook.LiquidityParams({
            amount0: isWethCurrency0 ? LP_WETH_AMOUNT : 0,
            amount1: isWethCurrency0 ? 0 : LP_WETH_AMOUNT,
            poolId: poolId
        });

        // Expect event on add liquidity
        vm.expectEmit(true, true, false, true);
        emit PumpUpHook.LiquidityAdded(
            poolId, LIQUIDITY_PROVIDER, isWethCurrency0 ? LP_WETH_AMOUNT : 0, isWethCurrency0 ? 0 : LP_WETH_AMOUNT
        );
        pumpUpHook.addLiquidity(poolKey, liquidityParams, LIQUIDITY_PROVIDER);

        // Expect event on remove liquidity
        vm.expectEmit(true, true, false, true);
        emit PumpUpHook.LiquidityRemoved(
            poolId, LIQUIDITY_PROVIDER, isWethCurrency0 ? LP_WETH_AMOUNT : 0, isWethCurrency0 ? 0 : LP_WETH_AMOUNT
        );
        pumpUpHook.removeLiquidity(poolKey, liquidityParams);

        vm.stopPrank();
    }

    /**
     * @notice Test successful execution of unlockCallback when adding liquidity
     */
    function test_UnlockCallbackAddLiquidity() public {
        // Start with balances before
        uint256 initialWethLiquidity = _getUserWethLiquidity(LIQUIDITY_PROVIDER);
        (uint256 initialWethClaimBalance,) = _getHookClaimBalances();

        // Add liquidity
        _addLiquidity(LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        // Check state updates
        uint256 finalWethLiquidity = _getUserWethLiquidity(LIQUIDITY_PROVIDER);
        (uint256 finalWethClaimBalance,) = _getHookClaimBalances();

        // Verify the unlock callback correctly processed the transaction
        assertEq(finalWethLiquidity, initialWethLiquidity + LP_WETH_AMOUNT, "Liquidity tracking should be updated");
        assertEq(finalWethClaimBalance, initialWethClaimBalance + LP_WETH_AMOUNT, "Hook claim balance should increase");
    }

    /**
     * @notice Test successful execution of unlockCallback when removing liquidity
     */
    function test_UnlockCallbackRemoveLiquidity() public {
        // Add liquidity first
        _addLiquidity(LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        // Start with balances before
        uint256 initialWethLiquidity = _getUserWethLiquidity(LIQUIDITY_PROVIDER);
        (uint256 initialWethClaimBalance,) = _getHookClaimBalances();
        uint256 initialWethBalance = IERC20Minimal(wethAddress).balanceOf(LIQUIDITY_PROVIDER);

        // Remove liquidity
        _removeLiquidity(LIQUIDITY_PROVIDER, LP_WETH_AMOUNT);

        // Check state updates
        uint256 finalWethLiquidity = _getUserWethLiquidity(LIQUIDITY_PROVIDER);
        (uint256 finalWethClaimBalance,) = _getHookClaimBalances();
        uint256 finalWethBalance = IERC20Minimal(wethAddress).balanceOf(LIQUIDITY_PROVIDER);

        // Verify the unlock callback correctly processed the transaction
        assertEq(finalWethLiquidity, initialWethLiquidity - LP_WETH_AMOUNT, "Liquidity tracking should be updated");
        assertEq(finalWethClaimBalance, initialWethClaimBalance - LP_WETH_AMOUNT, "Hook claim balance should decrease");
        assertEq(finalWethBalance, initialWethBalance + LP_WETH_AMOUNT, "User should receive WETH tokens");
    }

    // Helper function

    /**
     * @notice Helper to create and initialize a pool
     */
    function _createAndInitializePool() internal {
        // Mint WETH to the creator
        deal(wethAddress, CREATOR, INITIAL_WETH_AMOUNT);

        // Create the PumpUp pool
        vm.startPrank(CREATOR);
        (poolId, memecoin, nftId) =
            poolStateManager.createPumpUp{value: POOL_CREATION_FEE}(launchParams, ecStrategyId, transitionConfig);

        // Initialize the pool with WETH
        IERC20Minimal(wethAddress).approve(address(poolStateManager), INITIAL_WETH_AMOUNT);
        (currency0, currency1) = poolStateManager.initializePool(INITIAL_WETH_AMOUNT, poolId);
        vm.stopPrank();

        // Create pool key for tests
        poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(pumpUpHook)});
    }

    /**
     * @notice Helper to add liquidity to the pool
     * @param provider The address providing liquidity
     * @param wethAmount The amount of WETH to add
     */
    function _addLiquidity(address provider, uint256 wethAmount) internal {
        // Mint WETH to the provider
        deal(wethAddress, provider, wethAmount);

        vm.startPrank(provider);

        // Approve WETH for the hook
        IERC20Minimal(wethAddress).approve(address(pumpUpHook), wethAmount);

        // Create liquidity parameters
        PumpUpHook.LiquidityParams memory liquidityParams = PumpUpHook.LiquidityParams({
            amount0: isWethCurrency0 ? wethAmount : 0,
            amount1: isWethCurrency0 ? 0 : wethAmount,
            poolId: poolId
        });

        // Add liquidity
        pumpUpHook.addLiquidity(poolKey, liquidityParams, provider);

        vm.stopPrank();
    }

    /**
     * @notice Helper to remove liquidity from the pool
     * @param provider The address removing liquidity
     * @param wethAmount The amount of WETH to remove
     */
    function _removeLiquidity(address provider, uint256 wethAmount) internal {
        vm.startPrank(provider);

        // Create liquidity parameters
        PumpUpHook.LiquidityParams memory liquidityParams = PumpUpHook.LiquidityParams({
            amount0: isWethCurrency0 ? wethAmount : 0,
            amount1: isWethCurrency0 ? 0 : wethAmount,
            poolId: poolId
        });

        // Remove liquidity
        pumpUpHook.removeLiquidity(poolKey, liquidityParams);

        vm.stopPrank();
    }

    /**
     * @notice Helper to get user's WETH liquidity
     * @param user The user address to check
     * @return The amount of WETH liquidity
     */
    function _getUserWethLiquidity(address user) internal view returns (uint256) {
        return pumpUpHook.getUserLiquidity(user, poolId, wethAddress);
    }

    /**
     * @notice Helper to get user's memecoin liquidity
     * @param user The user address to check
     * @return The amount of memecoin liquidity
     */
    function _getUserMemecoinLiquidity(address user) internal view returns (uint256) {
        return pumpUpHook.getUserLiquidity(user, poolId, memecoin);
    }

    /**
     * @notice Helper to get the current hook claim balances
     * @return wethClaimBalance The hook's WETH claim balance
     * @return memecoinClaimBalance The hook's memecoin claim balance
     */
    function _getHookClaimBalances() internal view returns (uint256 wethClaimBalance, uint256 memecoinClaimBalance) {
        if (isWethCurrency0) {
            wethClaimBalance = manager.balanceOf(address(pumpUpHook), currency0.toId());
            memecoinClaimBalance = manager.balanceOf(address(pumpUpHook), currency1.toId());
        } else {
            wethClaimBalance = manager.balanceOf(address(pumpUpHook), currency1.toId());
            memecoinClaimBalance = manager.balanceOf(address(pumpUpHook), currency0.toId());
        }
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
