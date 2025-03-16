// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@solady/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INft} from "./interfaces/INft.sol";
import {IMemeCoin} from "./interfaces/IMemeCoin.sol";
import {IStrategyManager} from "./interfaces/IStrategyManager.sol";
import {Initializable} from "@solady/utils/Initializable.sol";

/**
 * @title PoolStateManager
 * @author SWAPUMP
 * @notice Manages the state for all token pools and handles token creation
 * @dev No trading functionality - that belongs in the hooks contract
 */
contract PoolStateManager is Ownable, ReentrancyGuard, Initializable {
    // ============ Structs ============

    /**
     * @notice Parameters for launching a new memecoin
     * @param name Token name
     * @param symbol Token symbol
     * @param tokenUri Token URI for metadata
     * @param initialSupply Initial token supply
     * @param creator Creator address
     * @param premineAmount Amount to premine for creator
     */
    struct LaunchParams {
        string name;
        string symbol;
        string tokenUri;
        uint256 initialSupply;
        address creator;
        uint256 premineAmount;
    }

    /**
     * @notice Transition configuration
     * @param transitionType Type of transition (1=percentage, 2=amount, 3=time)
     * @param thresholdPercentage For percentage-based transition (in basis points)
     * @param thresholdAmount For amount-based transition
     * @param timeThreshold For time-based transition
     * @param minWethLiquidity Minimum WETH liquidity required
     * @param liquidityPercentage Percentage of WETH to use as liquidity (basis points)
     * @param uniswapFeeType Fee type for Uniswap pool
     * @param burnLpTokens Whether to burn LP tokens after transition
     */
    struct TransitionConfig {
        uint8 transitionType;
        uint256 thresholdPercentage;
        uint256 thresholdAmount;
        uint256 timeThreshold;
        uint256 minWethLiquidity;
        uint256 liquidityPercentage;
        uint24 uniswapFeeType;
        bool burnLpTokens;
    }

    /**
     * @notice Pool state information
     * @param tokenAddress The memecoin token address
     * @param nftId The NFT ID representing ownership
     * @param wethAddress The WETH address used for this pool
     * @param creator The creator of the pool
     * @param isInitialized Whether the pool has been initialized
     * @param isTransitioned Whether the pool has transitioned to AMM
     * @param creationTimestamp When the pool was created
     * @param totalSupply Total supply of the token
     * @param circulatingSupply Amount of tokens in circulation
     * @param wethCollected Amount of WETH collected from sales
     * @param lastPrice Last calculated price (in WETH per token)
     * @param bondingCurveStrategy ID of the bonding curve strategy
     * @param transitionConfig Configuration for transition
     * @param transitionAvailable Whether transition conditions are met
     * @param ammPoolAddress Address of the AMM pool after transition
     * @param transitionTimestamp When the transition occurred
     * @param transitionPrice Price at transition
     */
    struct PoolState {
        address tokenAddress;
        uint256 nftId;
        address wethAddress;
        address creator;
        bool isInitialized;
        bool isTransitioned;
        uint256 creationTimestamp;
        
        uint256 totalSupply;
        uint256 circulatingSupply;
        uint256 wethCollected;
        uint256 lastPrice;
        
        bytes32 bondingCurveStrategy;
        TransitionConfig transitionConfig;
        bool transitionAvailable;
        
        address ammPoolAddress;
        uint256 transitionTimestamp;
        uint256 transitionPrice;
    }

    // ============ Events ============

    /**
     * @notice Emitted when a new pool is created
     * @param poolId The ID of the pool
     * @param tokenAddress The address of the memecoin token
     * @param creator The address of the creator
     * @param bondingCurveStrategy The ID of the bonding curve strategy
     */
    event PoolCreated(
        bytes32 indexed poolId,
        address indexed tokenAddress,
        address indexed creator,
        bytes32 bondingCurveStrategy
    );
    
    /**
     * @notice Emitted when a pool state is updated
     * @param poolId The ID of the pool
     * @param circulatingSupply New circulating supply
     * @param wethCollected New amount of WETH collected
     * @param lastPrice New token price
     */
    event PoolStateUpdated(
        bytes32 indexed poolId,
        uint256 circulatingSupply,
        uint256 wethCollected,
        uint256 lastPrice
    );
    
    /**
     * @notice Emitted when transition becomes available
     * @param poolId The ID of the pool
     * @param timestamp The timestamp when transition became available
     */
    event TransitionAvailable(
        bytes32 indexed poolId,
        uint256 timestamp
    );
    
    /**
     * @notice Emitted when a pool transitions to AMM
     * @param poolId The ID of the pool
     * @param ammPoolAddress The address of the new AMM pool
     * @param transitionPrice The price at transition
     */
    event PoolTransitioned(
        bytes32 indexed poolId,
        address indexed ammPoolAddress,
        uint256 transitionPrice
    );

    // ============ State Variables ============

    /// @notice Mapping from pool ID to pool state
    mapping(bytes32 => PoolState) public poolStates;
    
    /// @notice Mapping from token address to pool ID
    mapping(address => bytes32) public tokenPoolIds;
    
    /// @notice Mapping from creator address to pool IDs they created
    mapping(address => bytes32[]) public creatorPools;
    
    /// @notice Mapping for strategy-specific data storage
    mapping(bytes32 => mapping(bytes32 => bytes)) public strategyData;
    
    /// @notice Default WETH address
    address public weth;
    
    /// @notice NFT contract for token ownership
    INft public nftContract;
    
    /// @notice Strategy manager contract
    IStrategyManager public strategyManager;
    
    /// @notice Pool creation fee
    uint256 public poolCreationFee;
    
    /// @notice Hook contract address (for trading)
    address public hookContract;
    
    /// @notice AVS contract for risk management
    address public avsContract;
    
    /// @notice Authorized addresses that can update pool state
    mapping(address => bool) public authorizedAddresses;

    // ============ Errors ============

    /// @notice Thrown when a pool already exists
    error PoolAlreadyExists();
    
    /// @notice Thrown when a pool is not found
    error PoolNotFound();
    
    /// @notice Thrown when a strategy is not found
    error StrategyNotFound();
    
    /// @notice Thrown when caller is not authorized
    error NotAuthorized();
    
    /// @notice Thrown when an address is invalid (zero)
    error InvalidAddress();
    
    /// @notice Thrown when pool creation fee is insufficient
    error InsufficientPoolCreationFee();

    // ============ Modifiers ============
    
    /**
     * @notice Only authorized addresses can call function
     */
    modifier onlyAuthorized() {
        if (!authorizedAddresses[msg.sender] && msg.sender != owner()) {
            revert NotAuthorized();
        }
        _;
    }

    // ============ Constructor & Initializer ============

    /**
     * @notice Constructor
     * @param _owner The owner of the contract
     * @param _weth The WETH address
     * @param _poolCreationFee Fee for creating a pool
     */
    constructor(
        address _owner,
        address _weth,
        uint256 _poolCreationFee
    ) Ownable(_owner) {
        if (_weth == address(0)) revert InvalidAddress();
        weth = _weth;
        poolCreationFee = _poolCreationFee;
    }
    
    /**
     * @notice Initialize the contract (for proxy implementations)
     * @param _nftContract The NFT contract address
     * @param _strategyManager The strategy manager contract address
     * @param _hookContract The hook contract address
     * @param _avsContract The AVS contract address
     */
    function initialize(
        address _nftContract,
        address _strategyManager,
        address _hookContract,
        address _avsContract
    ) external initializer onlyOwner {
        if (_nftContract == address(0) || 
            _strategyManager == address(0) || 
            _hookContract == address(0)) revert InvalidAddress();
        
        nftContract = INft(_nftContract);
        strategyManager = IStrategyManager(_strategyManager);
        hookContract = _hookContract;
        avsContract = _avsContract;
        
        // Authorize the hook contract to update pool state
        authorizedAddresses[_hookContract] = true;
    }

    // ============ External Functions ============

    /**
     * @notice Create a new memecoin and initialize its pool
     * @param launchParams Memecoin launch parameters
     * @param bondingCurveStrategy ID of the bonding curve strategy to use
     * @param transitionConfig Configuration for the transition
     * @return poolId The ID of the new pool
     * @return tokenAddress The address of the new memecoin
     */
    function createMemePool(
        LaunchParams calldata launchParams,
        bytes32 bondingCurveStrategy,
        TransitionConfig calldata transitionConfig
    ) external payable nonReentrant returns (bytes32 poolId, address tokenAddress) {
        // Check if payment is sufficient
        if (msg.value < poolCreationFee) revert InsufficientPoolCreationFee();
        
        // Check if the bonding curve strategy exists
        address curveImplementation = strategyManager.getStrategyImplementation(bondingCurveStrategy);
        if (curveImplementation == address(0)) revert StrategyNotFound();
        
        // Make sender the creator if not specified
        address creator = launchParams.creator == address(0) ? msg.sender : launchParams.creator;
        
        // Launch the memecoin via the NFT contract
        (tokenAddress, uint256 nftId) = nftContract.launchMemeCoin(launchParams);
        
        // Generate pool ID (hash of token address)
        poolId = keccak256(abi.encodePacked(tokenAddress));
        
        // Check if pool already exists
        if (tokenPoolIds[tokenAddress] != bytes32(0)) revert PoolAlreadyExists();
        
        // Initialize pool state
        PoolState storage state = poolStates[poolId];
        state.tokenAddress = tokenAddress;
        state.nftId = nftId;
        state.wethAddress = weth;
        state.creator = creator;
        state.isInitialized = true;
        state.isTransitioned = false;
        state.creationTimestamp = block.timestamp;
        state.totalSupply = launchParams.initialSupply;
        state.circulatingSupply = launchParams.premineAmount;
        state.wethCollected = 0;
        state.lastPrice = 0; // Will be set by the hook
        state.bondingCurveStrategy = bondingCurveStrategy;
        state.transitionConfig = transitionConfig;
        state.transitionAvailable = false;
        
        // Store mappings
        tokenPoolIds[tokenAddress] = poolId;
        creatorPools[creator].push(poolId);
        
        // Increment strategy usage count
        strategyManager.incrementUsageCount(bondingCurveStrategy);
        
        // Refund excess ETH
        if (msg.value > poolCreationFee) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - poolCreationFee}("");
            require(success, "Refund failed");
        }
        
        emit PoolCreated(poolId, tokenAddress, creator, bondingCurveStrategy);
        
        return (poolId, tokenAddress);
    }
    
    /**
     * @notice Update pool state after a token purchase or sale (only callable by authorized addresses)
     * @param poolId The ID of the pool
     * @param circulatingSupplyDelta Change in circulating supply (positive for buys, negative for sells)
     * @param wethCollectedDelta Change in WETH collected (positive for buys, negative for sells)
     * @param newPrice New token price
     */
    function updatePoolState(
        bytes32 poolId,
        int256 circulatingSupplyDelta,
        int256 wethCollectedDelta,
        uint256 newPrice
    ) external onlyAuthorized {
        PoolState storage state = poolStates[poolId];
        if (!state.isInitialized) revert PoolNotFound();
        
        // Update state based on deltas
        if (circulatingSupplyDelta > 0) {
            state.circulatingSupply += uint256(circulatingSupplyDelta);
        } else {
            state.circulatingSupply -= uint256(-circulatingSupplyDelta);
        }
        
        if (wethCollectedDelta > 0) {
            state.wethCollected += uint256(wethCollectedDelta);
        } else {
            state.wethCollected -= uint256(-wethCollectedDelta);
        }
        
        state.lastPrice = newPrice;
        
        emit PoolStateUpdated(
            poolId, 
            state.circulatingSupply, 
            state.wethCollected, 
            newPrice
        );
        
        // Check if transition conditions are met
        checkTransitionConditions(poolId);
    }
    
    /**
     * @notice Set a pool as transitioned to AMM (only callable by authorized addresses)
     * @param poolId The ID of the pool
     * @param ammPoolAddress The address of the new AMM pool
     */
    function setPoolTransitioned(
        bytes32 poolId,
        address ammPoolAddress
    ) external onlyAuthorized {
        PoolState storage state = poolStates[poolId];
        if (!state.isInitialized) revert PoolNotFound();
        
        state.isTransitioned = true;
        state.ammPoolAddress = ammPoolAddress;
        state.transitionTimestamp = block.timestamp;
        state.transitionPrice = state.lastPrice;
        
        emit PoolTransitioned(poolId, ammPoolAddress, state.lastPrice);
    }
    
    /**
     * @notice Check if transition conditions are met and update state if they are
     * @param poolId The ID of the pool
     * @return Whether transition conditions are met
     */
    function checkTransitionConditions(bytes32 poolId) public returns (bool) {
        PoolState storage state = poolStates[poolId];
        if (!state.isInitialized) revert PoolNotFound();
        
        if (state.isTransitioned || state.transitionAvailable) {
            return state.transitionAvailable;
        }
        
        bool conditionsMet = canTransition(poolId);
        
        if (conditionsMet && !state.transitionAvailable) {
            state.transitionAvailable = true;
            emit TransitionAvailable(poolId, block.timestamp);
        }
        
        return conditionsMet;
    }
    
    /**
     * @notice Store custom data for a strategy (only callable by authorized addresses)
     * @param poolId The ID of the pool
     * @param strategyId The ID of the strategy
     * @param data Custom data to store
     */
    function setStrategyData(
        bytes32 poolId,
        bytes32 strategyId,
        bytes calldata data
    ) external onlyAuthorized {
        strategyData[poolId][strategyId] = data;
    }
    
    /**
     * @notice Check if a pool can transition to AMM
     * @param poolId The ID of the pool
     * @return Whether transition conditions are met
     */
    function canTransition(bytes32 poolId) public view returns (bool) {
        PoolState storage state = poolStates[poolId];
        if (!state.isInitialized) revert PoolNotFound();
        if (state.isTransitioned) return false;
        
        TransitionConfig memory config = state.transitionConfig;
        
        bool conditionsMet = false;
        
        // Check percentage-based condition
        if (config.transitionType == 1) {
            uint256 percentageSold = (state.circulatingSupply * 10000) / state.totalSupply;
            conditionsMet = percentageSold >= config.thresholdPercentage;
        }
        // Check amount-based condition
        else if (config.transitionType == 2) {
            conditionsMet = state.circulatingSupply >= config.thresholdAmount;
        }
        // Check time-based condition
        else if (config.transitionType == 3) {
            conditionsMet = block.timestamp >= state.creationTimestamp + config.timeThreshold;
        }
        
        // Check minimum WETH liquidity
        if (conditionsMet && config.minWethLiquidity > 0) {
            conditionsMet = state.wethCollected >= config.minWethLiquidity;
        }
        
        return conditionsMet;
    }
    
    /**
     * @notice Get custom data for a strategy
     * @param poolId The ID of the pool
     * @param strategyId The ID of the strategy
     * @return The stored data
     */
    function getStrategyData(bytes32 poolId, bytes32 strategyId) external view returns (bytes memory) {
        return strategyData[poolId][strategyId];
    }
    
    /**
     * @notice Get basic pool information
     * @param poolId The ID of the pool
     * @return tokenAddress The token address
     * @return wethAddress The WETH address
     * @return creator The creator address
     * @return circulatingSupply Current circulating supply
     * @return wethCollected WETH collected so far
     * @return lastPrice Last token price
     * @return isTransitioned Whether the pool has transitioned
     * @return bondingCurveStrategy The ID of the bonding curve strategy
     */
    function getPoolInfo(bytes32 poolId) external view returns (
        address tokenAddress,
        address wethAddress,
        address creator,
        uint256 circulatingSupply,
        uint256 wethCollected,
        uint256 lastPrice,
        bool isTransitioned,
        bytes32 bondingCurveStrategy
    ) {
        PoolState storage state = poolStates[poolId];
        if (!state.isInitialized) revert PoolNotFound();
        
        return (
            state.tokenAddress,
            state.wethAddress,
            state.creator,
            state.circulatingSupply,
            state.wethCollected,
            state.lastPrice,
            state.isTransitioned,
            state.bondingCurveStrategy
        );
    }
    
    /**
     * @notice Get transition information for a pool
     * @param poolId The ID of the pool
     * @return available Whether transition is available
     * @return config The transition configuration
     */
    function getTransitionInfo(bytes32 poolId) external view returns (
        bool available,
        TransitionConfig memory config
    ) {
        PoolState storage state = poolStates[poolId];
        if (!state.isInitialized) revert PoolNotFound();
        
        return (state.transitionAvailable, state.transitionConfig);
    }
    
    /**
     * @notice Get pool ID for a token
     * @param tokenAddress The token address
     * @return The pool ID
     */
    function getPoolIdForToken(address tokenAddress) external view returns (bytes32) {
        return tokenPoolIds[tokenAddress];
    }
    
    /**
     * @notice Get all pools created by an address
     * @param creator The creator address
     * @return Array of pool IDs
     */
    function getCreatorPools(address creator) external view returns (bytes32[] memory) {
        return creatorPools[creator];
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Set the pool creation fee
     * @param newFee New pool creation fee
     */
    function setPoolCreationFee(uint256 newFee) external onlyOwner {
        poolCreationFee = newFee;
    }
    
    /**
     * @notice Authorize or deauthorize an address
     * @param addr The address to authorize/deauthorize
     * @param isAuthorized Whether the address should be authorized
     */
    function setAuthorizedAddress(address addr, bool isAuthorized) external onlyOwner {
        authorizedAddresses[addr] = isAuthorized;
    }
    
    /**
     * @notice Update contract references
     * @param _nftContract New NFT contract address
     * @param _strategyManager New strategy manager address
     * @param _hookContract New hook contract address
     * @param _avsContract New AVS contract address
     */
    function updateContractReferences(
        address _nftContract,
        address _strategyManager,
        address _hookContract,
        address _avsContract
    ) external onlyOwner {
        if (_nftContract != address(0)) nftContract = INft(_nftContract);
        if (_strategyManager != address(0)) strategyManager = IStrategyManager(_strategyManager);
        if (_hookContract != address(0)) {
            // Deauthorize old hook contract
            authorizedAddresses[hookContract] = false;
            
            // Update and authorize new hook contract
            hookContract = _hookContract;
            authorizedAddresses[_hookContract] = true;
        }
        if (_avsContract != address(0)) avsContract = _avsContract;
    }
    
    /**
     * @notice Withdraw ETH from the contract (only callable by owner)
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function withdrawETH(uint256 amount, address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidAddress();
        if (amount > address(this).balance) {
            amount = address(this).balance;
        }
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Transfer failed");
    }
}