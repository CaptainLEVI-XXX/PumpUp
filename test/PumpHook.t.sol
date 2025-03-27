// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestHelper} from "./TestHelper.t.sol";
import {Test} from "forge-std/Test.sol";
import {PoolStateManager} from "../src/PoolStateManager.sol";
import {console} from "forge-std/console.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PumpUpHook} from "../src/PumpUpHook.sol";

contract TestPumpHookUp is Test, TestHelper {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    address public CREATOR = makeAddr("CREATOR");
    PoolStateManager.LaunchParams launchParams;
    PoolStateManager.TransitionConfig transitionConfig;

    uint256 initialSupply;
    address creator;
    uint256 premineAmount;
    uint256 initialPrice;

    uint256 public PREMINE_AMOUNT = 1 ether;
    uint256 public TOTAL_SUPPLY = 100 ether;

    bytes32 poolId;
    address memecoin;
    uint256 nftId;

    function setUp() public {
        deployProtocol();
        vm.deal(CREATOR, 1 ether);
        launchParams = PoolStateManager.LaunchParams({
            name: "DOGE",
            symbol: "DOGE",
            tokenUri: "tokenUri",
            initialSupply: TOTAL_SUPPLY,
            creator: CREATOR,
            premineAmount: PREMINE_AMOUNT
        });

        transitionConfig = PoolStateManager.TransitionConfig({
            transitionType: PoolStateManager.TransitionType.Percentage,
            transitionData: 50
        });
    }

    function test_createPumpUp() public {
        vm.prank(CREATOR);
        (poolId, memecoin, nftId) =
            poolStateManager.createPumpUp{value: POOL_CREATION_FEE}(launchParams, ecStrategyId, transitionConfig);

        assertEq(IERC20Minimal(memecoin).balanceOf(CREATOR), PREMINE_AMOUNT, "Amount didn't matched");
        assertEq(
            IERC20Minimal(memecoin).balanceOf(address(poolStateManager)),
            TOTAL_SUPPLY - PREMINE_AMOUNT,
            "amount Didn't matched"
        );
        assertEq(pumpUp.tokenId(memecoin), nftId, "NFT ID doesnot matched");
    }

    function test_initializePool() public {
        weth.mint(CREATOR, 100 ether);
        assertEq(weth.balanceOf(CREATOR), 100 ether, "Balance Did not matched");
        vm.startPrank(CREATOR);
        (poolId, memecoin, nftId) =
            poolStateManager.createPumpUp{value: POOL_CREATION_FEE}(launchParams, ecStrategyId, transitionConfig);

        weth.approve(address(poolStateManager), 50 ether);
        (currency0, currency1) = poolStateManager.initializePool(50 ether, poolId);

        console.log(Currency.unwrap(currency0));
        console.log(Currency.unwrap(currency1));

        uint256 token0ClaimId = currency0.toId();
        uint256 token1ClaimId = currency1.toId();

        uint256 token0ClaimBalance = manager.balanceOf(address(pumpUpHook), token0ClaimId);
        uint256 token1ClaimBalance = manager.balanceOf(address(pumpUpHook), token1ClaimId);

        assertEq(token0ClaimBalance, 50 ether);
        assertEq(token1ClaimBalance, TOTAL_SUPPLY - PREMINE_AMOUNT);
        vm.stopPrank();
    }

    function test_addLiquidity() public {
        test_initializePool();
        weth.mint(LIQUIDITY_PROVIDER, 10 ether);

        vm.startPrank(LIQUIDITY_PROVIDER);

        weth.approve(address(pumpUpHook), 10 ether);

        // Create our Uniswap pool and store the pool key for lookups
        PoolKey memory _poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(pumpUpHook)});

        PumpUpHook.LiquidityParams memory liquidityParams =
            PumpUpHook.LiquidityParams({amount0: 10 ether, amount1: 0, poolId: poolId});
        pumpUpHook.addLiquidity(_poolKey, liquidityParams, LIQUIDITY_PROVIDER);

        uint256 amount = pumpUpHook.getUserLiquidity(LIQUIDITY_PROVIDER, poolId, wethAddress);
        uint256 amount0OfCreator = pumpUpHook.getUserLiquidity(CREATOR, poolId, wethAddress);
        uint256 amount1OfCreator = pumpUpHook.getUserLiquidity(CREATOR, poolId, memecoin);

        assertEq(amount, 10 ether, "Ampount mismatched");
        assertEq(amount0OfCreator, 50 ether);
        assertEq(amount1OfCreator, TOTAL_SUPPLY - PREMINE_AMOUNT);

        uint256 token0ClaimId = currency0.toId();
        uint256 token1ClaimId = currency1.toId();

        uint256 token0ClaimBalance = manager.balanceOf(address(pumpUpHook), token0ClaimId);
        uint256 token1ClaimBalance = manager.balanceOf(address(pumpUpHook), token1ClaimId);

        assertEq(token0ClaimBalance, 50 ether + 10 ether);
        assertEq(token1ClaimBalance, TOTAL_SUPPLY - PREMINE_AMOUNT);

        vm.stopPrank();
    }

    function test_removeLiquity() public {
        test_addLiquidity();
        vm.startPrank(LIQUIDITY_PROVIDER);

        PoolKey memory _poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(pumpUpHook)});

        PumpUpHook.LiquidityParams memory liquidityParams =
            PumpUpHook.LiquidityParams({amount0: 10 ether, amount1: 0, poolId: poolId});
        pumpUpHook.removeLiquidity(_poolKey, liquidityParams);

        uint256 amount = pumpUpHook.getUserLiquidity(LIQUIDITY_PROVIDER, poolId, wethAddress);

        assertEq(amount, 0, "Ampount mismatched");
    }
}
