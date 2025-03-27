// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PumpUpHook} from "../src/PumpUpHook.sol";
import {PoolStateManager} from "../src/PoolStateManager.sol";
import {StrategyManager} from "../src/StrategyManager.sol";
import {IPumpUp} from "../src/interfaces/IPumpUp.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ExponentialBondingCurve} from "../src/bondingCurve/ExponentialBC.sol";
import {PumpUp} from "../src/PumpUp.sol";
import {ExponentialBondingCurve} from "../src/bondingCurve/ExponentialBC.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {MockWETH} from "./mock/MockWETH.sol";

contract TestHelper is Test, Deployers {
    using CurrencyLibrary for Currency;

    address public constant AVS = address(0x12);
    address public constant PROTOCOL_OWNER = address(123);
    string public constant NAME = "WETH";
    string public constant SYMBOL = "WETH";
    address public wethAddress;
    uint256 public constant POOL_CREATION_FEE = 0.0001 ether;
    string public constant BASE_URI = "pumpUp Nft";
    uint256 public constant PLATFORM_FEE_CURATOR = 0;
    uint256 public constant MIN_CURATOR_DEPSOIT = 0.0001 ether;
    address public WETH_ORACLE = address(0x233);
    address public CURATOR = address(0x3232323);

    address public LIQUIDITY_PROVIDER = makeAddr("LiquidityProvider");
    address public TRADER = makeAddr("TRADER");

    PoolStateManager internal poolStateManager;
    PumpUp internal pumpUp;
    StrategyManager internal strategyManager;
    ExponentialBondingCurve internal exponentialBC;
    PumpUpHook internal pumpUpHook;
    MockWETH internal weth;

    bytes32 internal ecStrategyId;

    function deployProtocol() public {
        deployFreshManagerAndRouters();

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            )
        );
        deployCodeTo("PumpUpHook.sol", abi.encode(manager), hookAddress);
        // deployed the hook contract
        pumpUpHook = PumpUpHook(hookAddress);

        //deploying the weth token
        deployMockWETH();
        //deploying pool state manager
        deployPoolStateManager();
        //deploy the NFT contract
        deployPumpUpNft();
        //deploy the strategy Manager
        depoyStrategyManager();

        deployBondingCurve();
        initializeProtocol();
        setUpCuratorAndCurveConfig();
    }

    function deployPoolStateManager() internal {
        poolStateManager = new PoolStateManager(PROTOCOL_OWNER, wethAddress, POOL_CREATION_FEE);
    }

    function deployPumpUpNft() internal {
        pumpUp = new PumpUp(BASE_URI, PROTOCOL_OWNER);
    }

    function depoyStrategyManager() internal {
        strategyManager = new StrategyManager(PROTOCOL_OWNER, PLATFORM_FEE_CURATOR, PROTOCOL_OWNER, MIN_CURATOR_DEPSOIT);
    }

    function deployMockWETH() internal {
        weth = new MockWETH(NAME, SYMBOL, "");
        wethAddress = address(weth);
    }

    function initializeProtocol() internal {
        vm.startPrank(PROTOCOL_OWNER);
        //intialize the pool state manager
        poolStateManager.initialize(address(pumpUp), address(strategyManager), address(pumpUpHook), AVS);
        //initialize the strategy manager
        strategyManager.initialize(address(poolStateManager));
        //initialize nft contract
        pumpUp.initialize(address(poolStateManager));
        //initialize the hook contract
        pumpUpHook.initialize(address(poolStateManager), WETH_ORACLE, wethAddress);
        vm.stopPrank();
    }

    function deployBondingCurve() internal {
        exponentialBC = new ExponentialBondingCurve(address(poolStateManager), CURATOR);
    }

    function setUpCuratorAndCurveConfig() internal {
        vm.deal(CURATOR, 5 ether);
        vm.startPrank(CURATOR);

        strategyManager.registerCurator{value: 1 ether}("SAURABH");

        ecStrategyId =
            strategyManager.registerStrategy(address(exponentialBC), "ExponentialCurve", "ExponentialCurve", 0);
        vm.stopPrank();
        vm.prank(PROTOCOL_OWNER);
        strategyManager.enableStrategy(ecStrategyId);
    }

    function test_InitializationData() public {
        deployProtocol();
        assertEq(strategyManager.getStrategyImplementation(ecStrategyId), address(exponentialBC), "Failed");
    }

    function wrapTokenToCurrency(address token) internal pure returns (Currency) {
        return Currency.wrap(address(token));
    }
}
