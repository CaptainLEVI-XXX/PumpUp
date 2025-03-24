// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SuperAdmin2Step} from "./helpers/SuperAdmin2Step.sol";
import {ReentrancyGuardTransient} from "@solady/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPumpUp} from "./interfaces/IPumpUp.sol";
import {IMemeCoin} from "./interfaces/IMemeCoin.sol";
import {IStrategyManager} from "./interfaces/IStrategyManager.sol";
import {Initializable} from "@solady/utils/Initializable.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/**
 * @title PoolStateManager
 * @author SWAPUMP
 * @notice Manages the state for all token pools and handles token creation
 * @dev No trading functionality - that belongs in the hooks contract
 */
contract PoolStateManager is SuperAdmin2Step, ReentrancyGuardTransient, Initializable {
    using CustomRevert for bytes4;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ============ Enums ============

    enum TransitionType {
        Percentage,
        Price,
        Time
    }

    // ============ Structs ============

    /**
     * @notice Parameters for launching a new memecoin
     */
    struct LaunchParams {
        string name;
        string symbol;
        string tokenUri;
        uint256 initialSupply;
        address creator;
        uint256 premineAmount;
        uint256 initialPrice;
    }

    /**
     * @notice Transition configuration
     */
    struct TransitionConfig {
        TransitionType transitionType;
        uint256 transitionData;
    }

    /**
     * @notice Pool state information with optimized layout to reduce storage slots
     */
    struct PoolState {
        // Slot 1
        address tokenAddress;
        bool isInitialized;
        bool isTransitioned;
        // Slot 2
        uint256 nftId;
        // Slot 3
        address creator;
        // Slot 4
        uint256 creationTimestamp;
        // Slot 5
        uint256 wethCollected;
        // Slot 6
        uint256 lastPrice;
        // Slot 7
        uint256 circulatingSupply;
        // Slot 8
        uint256 totalSupply;
        // Slot 9
        bytes32 bondingCurveStrategy;
        // Slot 10
        TransitionConfig transitionConfig;
        // Slot 11
        uint256 transitionPrice;
    }

    // ============ Events ============

    event PoolCreated(
        bytes32 indexed poolId, address indexed tokenAddress, address indexed creator, bytes32 bondingCurveStrategy
    );

    event PoolStateUpdated(bytes32 indexed poolId, uint256 circulatingSupply, uint256 wethCollected, uint256 lastPrice);

    event TransitionAvailable(bytes32 indexed poolId, uint256 timestamp);

    event PoolTransitioned(bytes32 indexed poolId, address indexed ammPoolAddress, uint256 transitionPrice);

    // ============ State Variables ============

    /// @notice Mapping from pool ID to pool state
    mapping(bytes32 => PoolState) public poolStates;

    /// @notice Mapping from token address to pool ID
    mapping(address _memecoin => bytes32 poolId) public tokenPoolIds;

    /// @notice Mapping from creator address to pool IDs they created
    mapping(address => bytes32[]) public creatorPools;

    /// @notice Mapping for strategy-specific data storage
    mapping(bytes32 => mapping(bytes32 => bytes)) public strategyData;

    /// Maps our IERC20 token addresses to their registered PoolKey
    mapping(address _memecoin => PoolKey _poolKey) internal _poolKeys;

    /// @notice Default WETH address
    address public immutable weth;

    /// @notice NFT contract for token ownership
    IPumpUp public nftContract;

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

    error PoolAlreadyExists();
    error PoolNotFound();
    error StrategyNotFound();
    error NotAuthorized();
    error InvalidAddress();
    error InsufficientPoolCreationFee();
    error InvalidTransitionParams();

    // ============ Modifiers ============

    /**
     * @notice Only authorized addresses can call function
     */
    modifier onlyAuthorized() {
        if (!authorizedAddresses[msg.sender] && msg.sender != superAdmin()) {
            revert NotAuthorized();
        }
        _;
    }

    /**
     * @notice Check if pool exists
     */
    modifier poolExists(bytes32 poolId) {
        if (!poolStates[poolId].isInitialized) {
            revert PoolNotFound();
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
    constructor(address _owner, address _weth, uint256 _poolCreationFee) {
        if (_weth == address(0)) InvalidAddress.selector.revertWith();
        weth = _weth;
        poolCreationFee = _poolCreationFee;
        _setSuperAdmin(_owner);
    }

    /**
     * @notice Initialize the contract (for proxy implementations)
     * @param _nftContract The NFT contract address
     * @param _strategyManager The strategy manager contract address
     * @param _hookContract The hook contract address
     * @param _avsContract The AVS contract address
     */
    function initialize(address _nftContract, address _strategyManager, address _hookContract, address _avsContract)
        external
        initializer
        onlySuperAdmin
    {
        if (_nftContract == address(0) || _strategyManager == address(0) || _hookContract == address(0)) {
            InvalidAddress.selector.revertWith();
        }

        nftContract = IPumpUp(_nftContract);
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
        if (msg.value < poolCreationFee) {
            InsufficientPoolCreationFee.selector.revertWith();
        }

        // Check if the bonding curve strategy exists
        address curveImplementation = strategyManager.getStrategyImplementation(bondingCurveStrategy);
        if (curveImplementation == address(0)) {
            StrategyNotFound.selector.revertWith();
        }

        // Validate launch parameters
        if (launchParams.initialSupply == 0) {
            InvalidTransitionParams.selector.revertWith();
        }

        // Validate transition config
        _validateTransitionConfig(transitionConfig);

        // Make sender the creator if not specified
        address creator = launchParams.creator == address(0) ? msg.sender : launchParams.creator;
        uint256 nftId;

        // Launch the memecoin via the NFT contract
        (tokenAddress, nftId) = nftContract.launchMemeCoin(launchParams);

        // Generate pool ID (hash of token address and NFT ID)
        poolId = keccak256(abi.encodePacked(tokenAddress, nftId));

        // Check if pool already exists
        if (tokenPoolIds[tokenAddress] != bytes32(0)) {
            PoolAlreadyExists.selector.revertWith();
        }

        // Initialize pool state
        _initializePoolState(
            poolId,
            tokenAddress,
            nftId,
            creator,
            launchParams.initialSupply,
            launchParams.initialPrice,
            bondingCurveStrategy,
            transitionConfig
        );

        // Store mappings
        tokenPoolIds[tokenAddress] = poolId;
        creatorPools[creator].push(poolId);

        // Increment strategy usage count
        strategyManager.incrementUsageCount(bondingCurveStrategy);

        _initializeV4Pool(tokenAddress);

        // Refund excess ETH
        if (msg.value > poolCreationFee) {
            (bool success,) = payable(msg.sender).call{value: msg.value - poolCreationFee}("");
            require(success, "Refund failed");
        }

        emit PoolCreated(poolId, tokenAddress, creator, bondingCurveStrategy);

        return (poolId, tokenAddress);
    }

    function _initializeV4Pool(address tokenAddress) internal {
        // Check if our pool currency is flipped
        bool currencyFlipped = weth >= tokenAddress;

        // Create our Uniswap pool and store the pool key for lookups
        PoolKey memory _poolKey = PoolKey({
            currency0: Currency.wrap(!currencyFlipped ? weth : tokenAddress),
            currency1: Currency.wrap(currencyFlipped ? weth : tokenAddress),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hookContract)
        });

        //storing the poolk key to tokenaAddress

        _poolKeys[tokenAddress] = _poolKey;

        // poolManager.initialize(_poolKey, Constants.SQRT_PRICE_1_1);

        ///@notice need to check whether the pool is initialized
    }

    /**
     * @notice Check if transition conditions are met and update state if they are
     * @param poolId The ID of the pool
     * @return Whether transition conditions are met
     */
    function checkTransitionConditions(bytes32 poolId) public poolExists(poolId) returns (bool) {
        PoolState storage state = poolStates[poolId];

        if (state.isTransitioned) {
            return state.isTransitioned;
        }

        bool conditionsMet = canTransition(poolId);

        if (conditionsMet) {
            emit TransitionAvailable(poolId, block.timestamp);
        }

        return conditionsMet;
    }

    function isPoolTransitioned(bytes32 poolId) public view poolExists(poolId) returns (bool) {
        PoolState storage state = poolStates[poolId];
        return state.isTransitioned;
    }

    /**
     * @notice Store custom data for a strategy (only callable by authorized addresses)
     * @param poolId The ID of the pool
     * @param strategyId The ID of the strategy
     * @param data Custom data to store
     */
    function setStrategyData(bytes32 poolId, bytes32 strategyId, bytes calldata data)
        external
        onlyAuthorized
        poolExists(poolId)
    {
        strategyData[poolId][strategyId] = data;
    }

    /**
     * @notice Update pool state (only callable by authorized addresses)
     * @param poolId The ID of the pool
     * @param circulatingSupply New circulating supply
     * @param wethCollected New amount of WETH collected
     * @param lastPrice New token price
     */
    function updatePoolState(bytes32 poolId, uint256 circulatingSupply, uint256 wethCollected, uint256 lastPrice)
        external
        onlyAuthorized
        poolExists(poolId)
    {
        PoolState storage state = poolStates[poolId];

        state.circulatingSupply = circulatingSupply;
        state.wethCollected = wethCollected;
        state.lastPrice = lastPrice;

        emit PoolStateUpdated(poolId, circulatingSupply, wethCollected, lastPrice);
    }

    /**
     * @notice Perform transition to AMM (only callable by authorized addresses)
     * @param poolId The ID of the pool
     * @param ammPoolAddress The address of the AMM pool
     * @param transitionPrice The price at transition
     */
    function setPoolTransitioned(bytes32 poolId, address ammPoolAddress, uint256 transitionPrice)
        external
        onlyAuthorized
        poolExists(poolId)
    {
        PoolState storage state = poolStates[poolId];

        if (state.isTransitioned) {
            revert("Already transitioned");
        }

        state.isTransitioned = true;
        state.transitionPrice = transitionPrice;

        emit PoolTransitioned(poolId, ammPoolAddress, transitionPrice);
    }

    // ============ View Functions ============

    /**
     * @notice Check if a pool can transition to AMM
     * @param poolId The ID of the pool
     * @return Whether transition conditions are met
     */
    function canTransition(bytes32 poolId) public view poolExists(poolId) returns (bool) {
        PoolState storage state = poolStates[poolId];

        if (state.isTransitioned) return false;

        TransitionConfig memory config = state.transitionConfig;

        if (config.transitionType == TransitionType.Percentage) {
            // Percentage of total supply that has been sold
            if (state.totalSupply == 0) return false;
            uint256 percentageSold = (state.circulatingSupply * 10000) / state.totalSupply;
            return percentageSold >= config.transitionData;
        } else if (config.transitionType == TransitionType.Price) {
            // Price-based transition - triggered when price reaches threshold
            return state.lastPrice >= config.transitionData;
        } else if (config.transitionType == TransitionType.Time) {
            // Time-based transition - triggered at specific timestamp
            return block.timestamp >= config.transitionData;
        }

        return false;
    }

    /**
     * @notice Get custom data for a strategy
     * @param poolId The ID of the pool
     * @param strategyId The ID of the strategy
     * @return The stored data
     */
    function getStrategyData(bytes32 poolId, bytes32 strategyId)
        external
        view
        poolExists(poolId)
        returns (bytes memory)
    {
        return strategyData[poolId][strategyId];
    }

    /**
     * @notice Get basic pool information
     * @param poolId The ID of the pool
     * @return tokenAddress The token address
     * @return creator The creator address
     * @return wethCollected WETH collected so far
     * @return lastPrice Last token price
     * @return isTransitioned Whether the pool has transitioned
     * @return bondingCurveStrategy The ID of the bonding curve strategy
     */
    function getPoolInfo(bytes32 poolId)
        external
        view
        poolExists(poolId)
        returns (
            address tokenAddress,
            address creator,
            uint256 wethCollected,
            uint256 lastPrice,
            bool isTransitioned,
            bytes32 bondingCurveStrategy
        )
    {
        PoolState storage state = poolStates[poolId];

        return (
            state.tokenAddress,
            state.creator,
            state.wethCollected,
            state.lastPrice,
            state.isTransitioned,
            state.bondingCurveStrategy
        );
    }

    /**
     * @notice Get extended pool information (to avoid stack too deep errors)
     * @param poolId The ID of the pool
     * @return nftId The NFT ID
     * @return creationTimestamp When the pool was created
     * @return circulatingSupply Current circulating supply
     * @return totalSupply Total token supply
     * @return transitionPrice Price at transition
     */
    function getExtendedPoolInfo(bytes32 poolId)
        external
        view
        poolExists(poolId)
        returns (
            uint256 nftId,
            uint256 creationTimestamp,
            uint256 circulatingSupply,
            uint256 totalSupply,
            uint256 transitionPrice
        )
    {
        PoolState storage state = poolStates[poolId];

        return (state.nftId, state.creationTimestamp, state.circulatingSupply, state.totalSupply, state.transitionPrice);
    }

    /**
     * @notice Get transition config for a pool
     * @param poolId The ID of the pool
     * @return transitionType Type of transition
     * @return transitionData Data for transition configuration
     */
    function getTransitionConfig(bytes32 poolId)
        external
        view
        poolExists(poolId)
        returns (TransitionType transitionType, uint256 transitionData)
    {
        TransitionConfig memory config = poolStates[poolId].transitionConfig;

        return (config.transitionType, config.transitionData);
    }

    /**
     * @notice Get transition information for a pool
     * @param poolId The ID of the pool
     * @return available Whether transition is available
     */
    function getTransitionInfo(bytes32 poolId) external view poolExists(poolId) returns (bool available) {
        return canTransition(poolId);
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
    function setPoolCreationFee(uint256 newFee) external onlySuperAdmin {
        poolCreationFee = newFee;
    }

    /**
     * @notice Authorize or deauthorize an address
     * @param addr The address to authorize/deauthorize
     * @param isAuthorized Whether the address should be authorized
     */
    function setAuthorizedAddress(address addr, bool isAuthorized) external onlySuperAdmin {
        if (addr == address(0)) {
            InvalidAddress.selector.revertWith();
        }
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
    ) external onlySuperAdmin {
        if (_nftContract != address(0)) {
            nftContract = IPumpUp(_nftContract);
        }

        if (_strategyManager != address(0)) {
            strategyManager = IStrategyManager(_strategyManager);
        }

        if (_hookContract != address(0)) {
            // Deauthorize old hook contract
            authorizedAddresses[hookContract] = false;

            // Update and authorize new hook contract
            hookContract = _hookContract;
            authorizedAddresses[_hookContract] = true;
        }

        if (_avsContract != address(0)) {
            avsContract = _avsContract;
        }
    }

    /**
     * @notice Withdraw ETH from the contract (only callable by owner)
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function withdrawETH(uint256 amount, address recipient) external onlySuperAdmin nonReentrant {
        if (recipient == address(0)) {
            InvalidAddress.selector.revertWith();
        }

        if (amount > address(this).balance) {
            amount = address(this).balance;
        }

        (bool success,) = recipient.call{value: amount}("");
        require(success, "Transfer failed");
    }

    // ============ Internal Functions ============

    /**
     * @notice Initialize a new pool state
     * @param poolId Pool ID
     * @param tokenAddress Token address
     * @param nftId NFT ID
     * @param creator Creator address
     * @param initialSupply Initial token supply
     * @param initialPrice Initial token price
     * @param bondingCurveStrategy Bonding curve strategy ID
     * @param transitionConfig Transition configuration
     */
    function _initializePoolState(
        bytes32 poolId,
        address tokenAddress,
        uint256 nftId,
        address creator,
        uint256 initialSupply,
        uint256 initialPrice,
        bytes32 bondingCurveStrategy,
        TransitionConfig memory transitionConfig
    ) internal {
        PoolState storage state = poolStates[poolId];

        state.tokenAddress = tokenAddress;
        state.nftId = nftId;
        state.creator = creator;
        state.isInitialized = true;
        state.isTransitioned = false;
        state.creationTimestamp = block.timestamp;
        state.wethCollected = 0;
        state.lastPrice = initialPrice;
        state.circulatingSupply = 0;
        state.totalSupply = initialSupply;
        state.bondingCurveStrategy = bondingCurveStrategy;
        state.transitionConfig = transitionConfig;
        state.transitionPrice = 0;
    }

    /**
     * @notice Validate transition configuration
     * @param config Transition configuration to validate
     */
    function _validateTransitionConfig(TransitionConfig memory config) internal view {
        // For percentage-based transition, check if within range
        if (config.transitionType == TransitionType.Percentage) {
            /// @notice didn't added check for  transitionData = 0 as this state represent it will not trasnitioned to v4-pools
            if (config.transitionData > 10000) {
                InvalidTransitionParams.selector.revertWith();
            }
        }
        // For time-based transition, ensure future time
        else if (config.transitionType == TransitionType.Time) {
            if (config.transitionData <= block.timestamp) {
                InvalidTransitionParams.selector.revertWith();
            }
        }
        // For price-based transition, ensure non-zero
        else if (config.transitionType == TransitionType.Price) {
            if (config.transitionData == 0) {
                InvalidTransitionParams.selector.revertWith();
            }
        } else {
            InvalidTransitionParams.selector.revertWith();
        }
    }
}
