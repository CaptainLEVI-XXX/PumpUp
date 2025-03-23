// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
// import {SuperAdmin2Step} from "../helpers/SuperAdmin2Step.sol";

// // Correct imports for PRBMath
// import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
// import {exp, intoUint256} from "@prb/math/src/UD60x18.sol";

// import {IPoolStateManager} from "../interfaces/IPoolStateManager.sol";
// import {IBondingCurveStrategy} from "../interfaces/IBondingCurveStrategy.sol";

// /**
//  * @title SigmoidBondingCurve
//  * @notice Implements a sigmoid bonding curve that respects user-defined initial price
//  * @dev Uses PRBMath library for fixed-point calculations
//  */
// contract SigmoidBondingCurve is IBondingCurveStrategy, SuperAdmin2Step {
//     using CustomRevert for bytes4;

//     // ============ Structs ============

//     struct CurveParameters {
//         UD60x18 initialPrice;   // Initial price when supply is near zero - set by user
//         UD60x18 maxPriceFactor; // How much higher the max price should be compared to initial (e.g., 10x)
//         UD60x18 steepness;      // Steepness of the curve
//         UD60x18 midpoint;       // Midpoint of the curve (percentage of supply)
//         uint256 totalSupply;    // Total token supply for reference
//     }

//     // ============ Constants ============

//     string public constant STRATEGY_TYPE = "BondingCurve";
//     string public constant STRATEGY_NAME = "Sigmoid";

//     // Default parameters (can be overridden during initialization)
//     uint256 public constant DEFAULT_MAX_PRICE_FACTOR = 10e18; // 10.0x initial price
//     uint256 public constant DEFAULT_STEEPNESS = 10e18;        // 10.0
//     uint256 public constant DEFAULT_MIDPOINT = 0.5e18;        // 0.5 (50% of supply)

//     // ============ State Variables ============

//     // The pool state manager contract
//     IPoolStateManager public poolStateManager;

//     // Curve parameters for each pool
//     mapping(bytes32 => CurveParameters) public curveParams;

//     // ============ Events ============

//     event StrategyInitialized(
//         bytes32 indexed poolId,
//         uint256 initialPrice,
//         uint256 maxPriceFactor,
//         uint256 steepness,
//         uint256 midpoint,
//         uint256 totalSupply
//     );
//     event TokensPurchased(bytes32 indexed poolId, uint256 wethAmount, uint256 tokenAmount, uint256 newPrice);
//     event TokensSold(bytes32 indexed poolId, uint256 tokenAmount, uint256 wethAmount, uint256 newPrice);

//     // ============ Errors ============

//     error InvalidPoolId();
//     error InvalidAmount();
//     error InvalidParameters();
//     error NotPoolStateManager();
//     error InsufficientLiquidity();

//     // ============ Constructor ============

//     constructor(address _poolStateManager, address _admin) {
//         poolStateManager = IPoolStateManager(_poolStateManager);
//         _setSuperAdmin(_admin);
//     }

//     // ============ External Functions ============

//     /**
//      * @notice Returns the strategy type identifier
//      * @return The strategy type as a string
//      */
//     function strategyType() external pure override returns (string memory) {
//         return STRATEGY_TYPE;
//     }

//     /**
//      * @notice Returns the strategy name
//      * @return The strategy name as a string
//      */
//     function name() external pure override returns (string memory) {
//         return STRATEGY_NAME;
//     }

//     /**
//      * @notice Initializes the strategy for a new pool
//      * @param poolId The ID of the pool
//      * @param params The initialization parameters
//      * @dev Expects encoded (initialPrice, maxPriceFactor, steepness, midpoint, totalSupply)
//      */
//     function initialize(bytes32 poolId, bytes calldata params) external override {
//         // Only the pool state manager can initialize
//         if (msg.sender != address(poolStateManager)) {
//             revert NotPoolStateManager();
//         }

//         // Decode parameters
//         (
//             uint256 initialPrice,
//             uint256 maxPriceFactor,
//             uint256 steepness,
//             uint256 midpoint,
//             uint256 totalSupply
//         ) = abi.decode(params, (uint256, uint256, uint256, uint256, uint256));

//         // Validate parameters
//         if (totalSupply == 0 || initialPrice == 0) {
//             revert InvalidParameters();
//         }

//         // Convert to UD60x18 format
//         UD60x18 initialPriceUD = ud(initialPrice);
//         UD60x18 maxPriceFactorUD = ud(maxPriceFactor == 0 ? DEFAULT_MAX_PRICE_FACTOR : maxPriceFactor);
//         UD60x18 steepnessUD = ud(steepness == 0 ? DEFAULT_STEEPNESS : steepness);
//         UD60x18 midpointUD = ud(midpoint == 0 ? DEFAULT_MIDPOINT : midpoint);

//         // Store parameters
//         curveParams[poolId] = CurveParameters({
//             initialPrice: initialPriceUD,
//             maxPriceFactor: maxPriceFactorUD,
//             steepness: steepnessUD,
//             midpoint: midpointUD,
//             totalSupply: totalSupply
//         });

//         emit StrategyInitialized(
//             poolId,
//             initialPrice,
//             intoUint256(maxPriceFactorUD),
//             intoUint256(steepnessUD),
//             intoUint256(midpointUD),
//             totalSupply
//         );
//     }

//     /**
//      * @notice Calculates token amount to receive for a given WETH amount
//      * @param poolId The ID of the pool
//      * @param wethAmount Amount of WETH to spend
//      * @return tokenAmount Amount of tokens to receive
//      * @return newPrice New token price after the purchase
//      */
//     function calculateBuy(
//         bytes32 poolId,
//         uint256 wethAmount
//     ) external override returns (uint256 tokenAmount, uint256 newPrice) {
//         // Get pool state
//         (
//             address tokenAddress,
//             address creator,
//             uint256 wethCollected,
//             uint256 lastPrice,
//             bool isTransitioned,
//             bytes32 bondingCurveStrategy
//         ) = poolStateManager.getPoolInfo(poolId);

//         if (isTransitioned) {
//             revert("Pool has transitioned");
//         }

//         if (wethAmount == 0) {
//             revert InvalidAmount();
//         }

//         // Get curve parameters
//         CurveParameters memory params = curveParams[poolId];
//         if (params.totalSupply == 0) {
//             revert InvalidPoolId();
//         }

//         // Get current circulating supply
//         uint256 totalTokenSupply = IERC20(tokenAddress).totalSupply();
//         uint256 heldByManager = IERC20(tokenAddress).balanceOf(address(poolStateManager));
//         UD60x18 circulatingSupply = ud(totalTokenSupply - heldByManager);

//         // If no tokens have been sold yet, use a simpler calculation for the first buyer
//         if (intoUint256(circulatingSupply) == 0) {
//             // For the first buyer, use the initial price directly
//             tokenAmount = intoUint256(ud(wethAmount).div(params.initialPrice));
//             newPrice = intoUint256(params.initialPrice);

//             emit TokensPurchased(poolId, wethAmount, tokenAmount, newPrice);
//             return (tokenAmount, newPrice);
//         }

//         // Calculate current price based on circulating supply
//         UD60x18 currentPrice = calculateSigmoidPrice(circulatingSupply, params);

//         // Use binary search to find the right amount of tokens
//         tokenAmount = findTokenAmountForWeth(circulatingSupply, ud(wethAmount), params, false);

//         // Calculate the new price after purchase
//         UD60x18 newCirculatingSupply = circulatingSupply.add(ud(tokenAmount));
//         UD60x18 newPriceUD = calculateSigmoidPrice(newCirculatingSupply, params);
//         newPrice = intoUint256(newPriceUD);

//         emit TokensPurchased(poolId, wethAmount, tokenAmount, newPrice);

//         return (tokenAmount, newPrice);
//     }

//     /**
//      * @notice Calculates WETH amount to receive for a given token amount
//      * @param poolId The ID of the pool
//      * @param tokenAmount Amount of tokens to sell
//      * @return wethAmount Amount of WETH to receive
//      * @return newPrice New token price after the sale
//      */
//     function calculateSell(
//         bytes32 poolId,
//         uint256 tokenAmount
//     ) external override returns (uint256 wethAmount, uint256 newPrice) {
//         // Get pool state
//         (
//             address tokenAddress,
//             address creator,
//             uint256 wethCollected,
//             uint256 lastPrice,
//             bool isTransitioned,
//             bytes32 bondingCurveStrategy
//         ) = poolStateManager.getPoolInfo(poolId);

//         if (isTransitioned) {
//             revert("Pool has transitioned");
//         }

//         if (tokenAmount == 0) {
//             revert InvalidAmount();
//         }

//         // Get curve parameters
//         CurveParameters memory params = curveParams[poolId];
//         if (params.totalSupply == 0) {
//             revert InvalidPoolId();
//         }

//         // Get current circulating supply
//         uint256 totalTokenSupply = IERC20(tokenAddress).totalSupply();
//         uint256 heldByManager = IERC20(tokenAddress).balanceOf(address(poolStateManager));
//         UD60x18 circulatingSupply = ud(totalTokenSupply - heldByManager);

//         if (tokenAmount > intoUint256(circulatingSupply)) {
//             revert InvalidAmount();
//         }

//         // Calculate weth to return based on area under the curve
//         UD60x18 tokenAmountUD = ud(tokenAmount);
//         UD60x18 wethToReturn = calculateWethForTokenAmount(circulatingSupply, tokenAmountUD, params, true);

//         // Check against available liquidity
//         if (intoUint256(wethToReturn) > wethCollected) {
//             revert InsufficientLiquidity();
//         }

//         // Calculate the new price after selling
//         UD60x18 newCirculatingSupply = circulatingSupply.sub(tokenAmountUD);
//         UD60x18 newPriceUD = calculateSigmoidPrice(newCirculatingSupply, params);

//         wethAmount = intoUint256(wethToReturn);
//         newPrice = intoUint256(newPriceUD);

//         emit TokensSold(poolId, tokenAmount, wethAmount, newPrice);

//         return (wethAmount, newPrice);
//     }

//     /**
//      * @notice Gets the current token price based on circulating supply
//      * @param poolId The ID of the pool
//      * @return Current price of the token
//      */
//     function getCurrentPrice(bytes32 poolId) external view override returns (uint256) {
//         (
//             address tokenAddress,
//             address creator,
//             uint256 wethCollected,
//             uint256 lastPrice,
//             bool isTransitioned,
//             bytes32 bondingCurveStrategy
//         ) = poolStateManager.getPoolInfo(poolId);

//         if (isTransitioned) {
//             return lastPrice;
//         }

//         CurveParameters memory params = curveParams[poolId];
//         if (params.totalSupply == 0) {
//             revert InvalidPoolId();
//         }

//         // Get current circulating supply
//         uint256 totalTokenSupply = IERC20(tokenAddress).totalSupply();
//         uint256 heldByManager = IERC20(tokenAddress).balanceOf(address(poolStateManager));
//         UD60x18 circulatingSupply = ud(totalTokenSupply - heldByManager);

//         // If no tokens have been sold yet, return the initial price
//         if (intoUint256(circulatingSupply) == 0) {
//             return intoUint256(params.initialPrice);
//         }

//         return intoUint256(calculateSigmoidPrice(circulatingSupply, params));
//     }

//     // ============ Internal Functions ============

//   /**
//      * @notice Calculate sigmoid price based on the user's initial price
//      * @param supply Current circulating supply
//      * @param params Curve parameters
//      * @return price Token price
//      */
//     function calculateSigmoidPrice(UD60x18 supply, CurveParameters memory params) internal pure returns (UD60x18) {
//         if (intoUint256(supply) == 0) {
//             return params.initialPrice;
//         }

//         // Calculate percentage sold (normalized to 0-1)
//         UD60x18 percentageSold = supply.div(ud(params.totalSupply));

//         // Calculate max price from initial price and factor
//         UD60x18 maxPrice = params.initialPrice.mul(params.maxPriceFactor);

//         // Apply sigmoid formula: initialPrice + (maxPrice-initialPrice)/(1+e^(-steepness*(percentageSold-midpoint)))
//         UD60x18 priceRange = maxPrice.sub(params.initialPrice);

//         // Calculate -steepness * (percentageSold - midpoint)
//         // Instead of using .neg(), restructure the calculation based on comparison
//         UD60x18 exponentTerm;
//         if (percentageSold.lt(params.midpoint)) {
//             // If percentageSold < midpoint, then (midpoint - percentageSold) is positive
//             // We want: -steepness * (percentageSold - midpoint) = steepness * (midpoint - percentageSold)
//             exponentTerm = params.steepness.mul(params.midpoint.sub(percentageSold));
//         } else {
//             // If percentageSold >= midpoint, then (percentageSold - midpoint) is positive or zero
//             // We need to invert this: -steepness * (percentageSold - midpoint)
//             // Since we can't use .neg(), we'll have to:
//             // 1. Calculate the magnitude: steepness * (percentageSold - midpoint)
//             // 2. Use exp(-x) = 1/exp(x) for the final sigmoid calculation
//             UD60x18 positiveExponent = params.steepness.mul(percentageSold.sub(params.midpoint));

//             // Calculate e^(positiveExponent)
//             UD60x18 expPositive = exp(positiveExponent);

//             // Calculate denominator: 1 + 1/e^(positiveExponent) = (expPositive + 1) / expPositive
//             UD60x18 denominator = expPositive.add(ud(1e18)).div(expPositive);

//             // Calculate final result directly and return
//             return params.initialPrice.add(priceRange.div(denominator));
//         }

//         // For the percentageSold < midpoint case, continue with original calculation
//         // Calculate 1 + e^(exponentTerm)
//         UD60x18 denominator = ud(1e18).add(exp(exponentTerm));

//         // Calculate sigmoid component and add to initial price
//         return params.initialPrice.add(priceRange.div(denominator));
//     }

//     /**
//      * @notice Calculate WETH amount for a given token amount change
//      * @param currentSupply Current circulating supply
//      * @param tokenAmount Token amount (positive value)
//      * @param params Curve parameters
//      * @param isSelling Whether this is a sell operation
//      * @return wethAmount WETH amount
//      */
//     function calculateWethForTokenAmount(
//         UD60x18 currentSupply,
//         UD60x18 tokenAmount,
//         CurveParameters memory params,
//         bool isSelling
//     ) internal pure returns (UD60x18) {
//         // Calculate new supply based on operation type
//         UD60x18 newSupply;
//         if (isSelling) {
//             newSupply = currentSupply.sub(tokenAmount);
//         } else {
//             newSupply = currentSupply.add(tokenAmount);
//         }

//         // Calculate prices at endpoints
//         UD60x18 startPrice = calculateSigmoidPrice(currentSupply, params);
//         UD60x18 endPrice = calculateSigmoidPrice(newSupply, params);

//         // Use trapezoid rule for area: (p1 + p2) * quantity / 2
//         return startPrice.add(endPrice).mul(tokenAmount).div(ud(2e18));
//     }

//     /**
//      * @notice Find token amount for a given WETH amount using binary search
//      * @param currentSupply Current circulating supply
//      * @param wethAmount WETH amount
//      * @param params Curve parameters
//      * @param isSelling Whether this is a sell operation
//      * @return tokenAmount Token amount
//      */
//  /**
//  * @notice Find token amount for a given WETH amount using binary search
//  * @param currentSupply Current circulating supply
//  * @param wethAmount WETH amount
//  * @param params Curve parameters
//  * @param isSelling Whether this is a sell operation
//  * @return tokenAmount Token amount
//  */
// function findTokenAmountForWeth(
//     UD60x18 currentSupply,
//     UD60x18 wethAmount,
//     CurveParameters memory params,
//     bool isSelling
// ) internal pure returns (uint256) {
//     // Use binary search to find the right amount of tokens
//     UD60x18 minTokens = ud(0);
//     UD60x18 maxTokens;

//     if (isSelling) {
//         maxTokens = currentSupply; // Can't sell more than circulating supply
//     } else {
//         maxTokens = ud(params.totalSupply).sub(currentSupply); // Can't buy more than remaining supply
//     }

//     // Set tolerance for comparison
//     UD60x18 tolerance = ud(1e15); // 0.001 in 18 decimal format

//     // Limit iterations to prevent infinite loops
//     for (uint i = 0; i < 100; i++) {
//         UD60x18 midTokens = minTokens.add(maxTokens.sub(minTokens).div(ud(2e18)));

//         // Calculate WETH for this many tokens
//         UD60x18 wethNeeded = calculateWethForTokenAmount(currentSupply, midTokens, params, isSelling);

//         // Check if we're close enough by comparing the difference with tolerance
//         // Instead of using abs(), handle the comparison directly with if/else
//         if (wethNeeded.gte(wethAmount)) {
//             // wethNeeded >= wethAmount, so difference is wethNeeded - wethAmount
//             if (wethNeeded.sub(wethAmount) <= tolerance) {
//                 return intoUint256(midTokens);
//             }
//         } else {
//             // wethNeeded < wethAmount, so difference is wethAmount - wethNeeded
//             if (wethAmount.sub(wethNeeded) <= tolerance) {
//                 return intoUint256(midTokens);
//             }
//         }

//         // Adjust our search range
//         if (wethNeeded.lt(wethAmount)) {
//             minTokens = midTokens;
//         } else {
//             maxTokens = midTokens;
//         }
//     }

//     // Return the best approximation after max iterations
//     return intoUint256(minTokens);
// }

//     /**
//      * @notice Update the pool state manager address (only admin)
//      * @param _poolStateManager New pool state manager address
//      */
//     function setPoolStateManager(address _poolStateManager) external onlySuperAdmin {
//         poolStateManager = IPoolStateManager(_poolStateManager);
//     }

//     /**
//      * @notice Helper function to get absolute difference between two UD60x18 values
//      * @param a First value
//      * @param b Second value
//      * @return The absolute difference
//      */
//     function abs(UD60x18 a, UD60x18 b) internal pure returns (UD60x18) {
//         return a.gte(b) ? a.sub(b) : b.sub(a);
//     }
// }
