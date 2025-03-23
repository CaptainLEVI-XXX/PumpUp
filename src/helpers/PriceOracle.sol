// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
// import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
// import {Initializable} from "@solady/utils/Initializable.sol";
// import {SuperAdmin2Step} from "./SuperAdmin2Step.sol";

// /**
//  * @title IWethPriceOracle
//  * @notice Interface for WETH price oracle
//  */
// interface IPriceOracle {
//     function getWethPrice() external view returns (uint256);
// }

// /**
//  * @title WethPriceOracle
//  * @notice Fetches the WETH price from Uniswap V4 pools
//  * @dev Implements a price oracle for WETH/USD or WETH/stablecoin pairs
//  */
// contract PriceOracle is IPriceOracle, Initializable, SuperAdmin2Step {
//     using CurrencyLibrary for Currency;
//     using PoolIdLibrary for PoolKey;

//     // Uniswap V4 Pool Manager
//     IPoolManager public poolManager;

//     // WETH/Stablecoin pool key components
//     Currency public wethCurrency;
//     Currency public stableCurrency;
//     uint24 public poolFee;

//     // Price update settings
//     uint256 public lastUpdateTimestamp;
//     uint256 public updateInterval;
//     uint256 public price;

//     // TWAP settings
//     uint256 public twapInterval;

//     // Emergency settings
//     bool public useBackupPrice;
//     uint256 public backupPrice;

//     event PriceUpdated(uint256 price, uint256 timestamp);
//     event BackupPriceSet(uint256 price);
//     event BackupPriceModeChanged(bool enabled);

//     error ZeroAddress();
//     error InvalidPool();
//     error InvalidInterval();
//     error UpdateTooFrequent();

//     /**
//      * @notice Initialize the oracle with the necessary parameters
//      * @param _poolManager Uniswap V4 Pool Manager address
//      * @param _wethCurrency WETH currency
//      * @param _stableCurrency Stablecoin currency (USDC, DAI, etc.)
//      * @param _poolFee Fee tier of the reference pool
//      * @param _updateInterval Minimum time between price updates
//      * @param _twapInterval Time window for TWAP calculation
//      * @param _initialPrice Initial price value
//      */
//     function initialize(
//         address _poolManager,
//         Currency _wethCurrency,
//         Currency _stableCurrency,
//         uint24 _poolFee,
//         uint256 _updateInterval,
//         uint256 _twapInterval,
//         uint256 _initialPrice
//     ) external initializer onlySuperAdmin {
//         if (_poolManager == address(0)) revert ZeroAddress();
//         if (_updateInterval == 0) revert InvalidInterval();
//         if (_twapInterval == 0) revert InvalidInterval();

//         poolManager = IPoolManager(_poolManager);
//         wethCurrency = _wethCurrency;
//         stableCurrency = _stableCurrency;
//         poolFee = _poolFee;
//         updateInterval = _updateInterval;
//         twapInterval = _twapInterval;

//         // Set initial price
//         price = _initialPrice;
//         backupPrice = _initialPrice;
//         lastUpdateTimestamp = block.timestamp;

//         emit PriceUpdated(_initialPrice, block.timestamp);
//     }

//     /**
//      * @notice Update the WETH price from the Uniswap V4 pool
//      * @dev Uses TWAP for price stability
//      */
//     function updatePrice() external {
//         // Check if enough time has passed since last update
//         if (block.timestamp < lastUpdateTimestamp + updateInterval) {
//             revert UpdateTooFrequent();
//         }

//         if (useBackupPrice) {
//             // If using backup price, just update timestamp
//             lastUpdateTimestamp = block.timestamp;
//             return;
//         }

//         // Create pool key for the WETH/Stablecoin pool
//         PoolKey memory poolKey = PoolKey({
//             currency0: wethCurrency,
//             currency1: stableCurrency,
//             fee: poolFee,
//             tickSpacing: 60, // Standard tick spacing for 0.3% fee tier
//             hooks: address(0) // No hooks for price oracle pool
//         });

//         // Get pool ID
//         PoolId poolId = poolKey.toId();

//         // Check if pool exists
//         bool poolExists = poolManager.isExistingPool(poolKey);
//         if (!poolExists) revert InvalidPool();

//         // Calculate TWAP price from pool
//         uint256 newPrice = _calculateTwapPrice(poolKey);

//         // Update state
//         price = newPrice;
//         lastUpdateTimestamp = block.timestamp;

//         emit PriceUpdated(newPrice, block.timestamp);
//     }

//     /**
//      * @notice Calculate TWAP price from Uniswap V4 pool
//      * @param poolKey The pool key for the WETH/Stablecoin pool
//      * @return twapPrice The time-weighted average price
//      */
//     function _calculateTwapPrice(PoolKey memory poolKey) internal view returns (uint256) {
//         // In a real implementation, this would use the V4 pool's TWAP mechanism
//         // For simplicity, we'll return a simulated value based on the current state

//         // This function would typically:
//         // 1. Fetch observations from the pool over the TWAP interval
//         // 2. Calculate the time-weighted average price
//         // 3. Apply any necessary scaling

//         // For this example, we'll use a placeholder calculation
//         // In a real implementation, use the pool's observations and proper TWAP logic

//         // Get the current spot price as a fallback
//         (uint160 sqrtPriceX96,,,,,,) = poolManager.getSlot0(poolKey.toId());

//         // Convert sqrtPriceX96 to price with 18 decimals
//         // price = (sqrtPriceX96 / 2^96)^2 * 10^18 (if WETH is token0)
//         // Simplified for this example:
//         uint256 spotPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) * 1e18 / (1 << 192);

//         // Add some simulated variance to represent a TWAP
//         uint256 randomVariance = uint256(keccak256(abi.encodePacked(block.timestamp))) % 100;
//         uint256 twapPrice = spotPrice * (1000 + randomVariance) / 1000;

//         return twapPrice;
//     }

//     /**
//      * @notice Set a backup price in case the oracle needs to be overridden
//      * @param _backupPrice The backup price to set
//      */
//     function setBackupPrice(uint256 _backupPrice) external onlySuperAdmin {
//         backupPrice = _backupPrice;
//         emit BackupPriceSet(_backupPrice);
//     }

//     /**
//      * @notice Enable or disable the use of backup price
//      * @param _useBackupPrice Whether to use the backup price
//      */
//     function setUseBackupPrice(bool _useBackupPrice) external onlySuperAdmin {
//         useBackupPrice = _useBackupPrice;
//         emit BackupPriceModeChanged(_useBackupPrice);
//     }

//     /**
//      * @notice Set the update interval
//      * @param _updateInterval New minimum time between updates
//      */
//     function setUpdateInterval(uint256 _updateInterval) external onlySuperAdmin {
//         if (_updateInterval == 0) revert InvalidInterval();
//         updateInterval = _updateInterval;
//     }

//     /**
//      * @notice Set the TWAP interval
//      * @param _twapInterval New time window for TWAP calculation
//      */
//     function setTwapInterval(uint256 _twapInterval) external onlySuperAdmin {
//         if (_twapInterval == 0) revert InvalidInterval();
//         twapInterval = _twapInterval;
//     }

//     /**
//      * @notice Get the current WETH price
//      * @return Current WETH price (backup price if enabled, otherwise latest fetched price)
//      */
//     function getWethPrice() external view override returns (uint256) {
//         return useBackupPrice ? backupPrice : price;
//     }
// }
