// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PumpUpHook} from "../src/PumpUpHook.sol";
import {PoolStateManager} from "../src/PoolStateManager.sol";
import {StrategyManager} from "../src/StrategyManager.sol";
import {PumpUp} from "../src/PumpUp.sol";
import {IPumpUp} from "../src/interfaces/IPumpUp.sol";
import {ExponentialBondingCurve} from "../src/bondingCurve/ExponentialBC.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {MockWETH} from "./mock/MockWETH.sol";

/**
 * @title TestHelper
 * @notice Base contract for protocol tests that handles deployment and initialization
 * @dev Provides standard configuration and setup for testing PumpUp contracts
 */
contract TestHelper is Test, Deployers {
    using CurrencyLibrary for Currency;

    // Protocol addresses
    address public constant AVS = address(0x12);
    address public constant PROTOCOL_OWNER = address(0x123);
    address public constant WETH_ORACLE = address(0x233);
    address public constant CURATOR = address(0x3232323);
    address public constant LIQUIDITY_PROVIDER = address(0x456);
    address public constant TRADER = address(0x789);

    // WETH configuration
    string public constant NAME = "WETH";
    string public constant SYMBOL = "WETH";
    address public wethAddress;

    // Protocol constants
    uint256 public constant POOL_CREATION_FEE = 0.0001 ether;
    string public constant BASE_URI = "pumpUp Nft";
    uint256 public constant PLATFORM_FEE_CURATOR = 0;
    uint256 public constant MIN_CURATOR_DEPOSIT = 0.0001 ether;

    // Protocol contracts
    PoolStateManager public poolStateManager;
    PumpUp public pumpUp;
    StrategyManager public strategyManager;
    ExponentialBondingCurve public exponentialBC;
    PumpUpHook public pumpUpHook;
    MockWETH public weth;

    // Strategy identifier
    bytes32 public ecStrategyId;

    /**
     * @notice Deploy all protocol contracts
     */
    function deployProtocol() public {
        // Deploy Uniswap V4 core contracts
        deployFreshManagerAndRouters();

        // Deploy the hook contract with required permissions
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            )
        );
        deployCodeTo("PumpUpHook.sol", abi.encode(manager), hookAddress);
        pumpUpHook = PumpUpHook(hookAddress);

        // Deploy protocol contracts
        _deployMockWETH();
        _deployPoolStateManager();
        _deployPumpUpNft();
        _deployStrategyManager();
        _deployBondingCurve();

        // Initialize contracts and setup curator
        _initializeProtocol();
        _setupCuratorAndCurveConfig();
    }

    /**
     * @notice Deploy the PoolStateManager contract
     */
    function _deployPoolStateManager() internal {
        poolStateManager = new PoolStateManager(PROTOCOL_OWNER, wethAddress, POOL_CREATION_FEE);
    }

    /**
     * @notice Deploy the PumpUp NFT contract
     */
    function _deployPumpUpNft() internal {
        pumpUp = new PumpUp(BASE_URI, PROTOCOL_OWNER);
    }

    /**
     * @notice Deploy the StrategyManager contract
     */
    function _deployStrategyManager() internal {
        strategyManager = new StrategyManager(PROTOCOL_OWNER, PLATFORM_FEE_CURATOR, PROTOCOL_OWNER, MIN_CURATOR_DEPOSIT);
    }

    /**
     * @notice Deploy the MockWETH contract
     */
    function _deployMockWETH() internal {
        weth = new MockWETH(NAME, SYMBOL, "");
        wethAddress = address(weth);
    }

    /**
     * @notice Initialize all protocol contracts
     */
    function _initializeProtocol() internal {
        vm.startPrank(PROTOCOL_OWNER);

        // Initialize the pool state manager
        poolStateManager.initialize(address(pumpUp), address(strategyManager), address(pumpUpHook), AVS);

        // Initialize the strategy manager
        strategyManager.initialize(address(poolStateManager));

        // Initialize the NFT contract
        pumpUp.initialize(address(poolStateManager));

        // Initialize the hook contract
        pumpUpHook.initialize(address(poolStateManager), WETH_ORACLE, wethAddress);

        vm.stopPrank();
    }

    /**
     * @notice Deploy the ExponentialBondingCurve contract
     */
    function _deployBondingCurve() internal {
        exponentialBC = new ExponentialBondingCurve(address(poolStateManager), CURATOR);
    }

    /**
     * @notice Set up curator and register bonding curve strategy
     */
    function _setupCuratorAndCurveConfig() internal {
        // Fund the curator
        vm.deal(CURATOR, 5 ether);

        vm.startPrank(CURATOR);

        // Register as curator
        strategyManager.registerCurator{value: 1 ether}("SAURABH");

        // Register the exponential bonding curve strategy
        ecStrategyId =
            strategyManager.registerStrategy(address(exponentialBC), "ExponentialCurve", "ExponentialCurve", 0);

        vm.stopPrank();

        // Enable the strategy
        vm.prank(PROTOCOL_OWNER);
        strategyManager.enableStrategy(ecStrategyId);
    }

    /**
     * @notice Helper to convert token address to Currency
     * @param token The token address
     * @return The Currency wrapper
     */
    function wrapTokenToCurrency(address token) internal pure returns (Currency) {
        return Currency.wrap(token);
    }
}
