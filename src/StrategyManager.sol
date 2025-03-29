// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SuperAdmin2Step} from "./helpers/SuperAdmin2Step.sol";
import {ReentrancyGuardTransient} from "@solady/utils/ReentrancyGuardTransient.sol";
import {IBondingCurveStrategy} from "./interfaces/IBondingCurveStrategy.sol";
import {Initializable} from "@solady/utils/Initializable.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/**
 * @title StrategyManager
 * @author PUMPUP
 * @notice Contract for managing bonding curve strategies
 * @dev Allows curators to register and manage different bonding curve strategies
 */
contract StrategyManager is SuperAdmin2Step, ReentrancyGuardTransient, Initializable {
    using CustomRevert for bytes4;
    // ============ Structs ============

    /**
     * @notice Information about a registered strategy
     * @param implementation The address of the strategy contract
     * @param curator The address of the curator who created the strategy
     * @param name The human-readable name of the strategy
     * @param description A brief description of the strategy
     * @param enabled Whether the strategy is enabled
     * @param registrationTime When the strategy was registered
     * @param usageCount How many times the strategy has been used
     * @param curatorFee Fee in basis points (e.g., 50 = 0.5%)
     */
    struct StrategyInfo {
        address implementation;
        address curator;
        string name;
        string description;
        bool enabled;
        uint256 registrationTime;
        uint256 usageCount;
        uint256 curatorFee; // Fee in basis points
    }

    /**
     * @notice Information about a curator
     * @param name The curator's name
     * @param registrationTime When the curator registered
     * @param reputationScore The curator's reputation score
     * @param verified Whether the curator is verified
     */
    struct CuratorInfo {
        string name;
        uint256 registrationTime;
        uint256 reputationScore;
        bool verified;
    }

    // ============ Events ============

    /**
     * @notice Emitted when a strategy is registered
     * @param strategyId The ID of the registered strategy
     * @param implementation The address of the strategy contract
     * @param curator The address of the curator
     */
    event StrategyRegistered(bytes32 indexed strategyId, address indexed implementation, address indexed curator);

    /**
     * @notice Emitted when a strategy is enabled
     * @param strategyId The ID of the strategy
     */
    event StrategyEnabled(bytes32 indexed strategyId);

    /**
     * @notice Emitted when a strategy is disabled
     * @param strategyId The ID of the strategy
     */
    event StrategyDisabled(bytes32 indexed strategyId);

    /**
     * @notice Emitted when a curator is registered
     * @param curator The address of the curator
     * @param name The curator's name
     */
    event CuratorRegistered(address indexed curator, string name);

    /**
     * @notice Emitted when a curator's fee is updated
     * @param curator The address of the curator
     * @param strategyId The ID of the strategy
     * @param fee The new fee in basis points
     */
    event CuratorFeeUpdated(address indexed curator, bytes32 indexed strategyId, uint256 fee);

    // ============ State Variables ============

    /// @notice Mapping from strategy ID to strategy information
    mapping(bytes32 => StrategyInfo) public strategies;

    /// @notice Mapping from curator address to curator information
    mapping(address => CuratorInfo) public curators;

    /// @notice Mapping from curator address to their strategies
    mapping(address => bytes32[]) public curatorStrategies;

    /// @notice Mapping from strategy type to strategy IDs
    mapping(string => bytes32[]) public strategyTypes;

    /// @notice Platform fee in basis points
    uint256 public platformFee;

    /// @notice Address to receive platform fees
    address public platformFeeRecipient;

    /// @notice Minimum deposit required to become a curator
    uint256 public minCuratorDeposit;

    /// @notice The pool state manager contract
    address public poolStateManager;

    // ============ Errors ============

    /// @notice Thrown when a curator is already registered
    error AlreadyRegistered();

    /// @notice Thrown when curator deposit is insufficient
    error InsufficientDeposit();

    /// @notice Thrown when an address is not a registered curator
    error NotCurator();

    /// @notice Thrown when a strategy already exists
    error StrategyAlreadyExists();

    /// @notice Thrown when a fee is set too high
    error FeeTooHigh();

    /// @notice Thrown when a strategy doesn't exist
    error StrategyNotFound();

    /// @notice Thrown when the caller is not the strategy curator
    error NotStrategyCurator();

    /// @notice Thrown when a pool is not initialized
    error PoolNotInitialized();

    /// @notice Thrown when an address is invalid (zero)
    error InvalidAddress();

    // ============ Constructor & Initializer ============

    /**
     * @notice Constructor
     * @param _owner The owner of the contract
     * @param _platformFee Initial platform fee in basis points
     * @param _platformFeeRecipient Address to receive platform fees
     * @param _minCuratorDeposit Minimum deposit required to become a curator
     */
    constructor(address _owner, uint256 _platformFee, address _platformFeeRecipient, uint256 _minCuratorDeposit) {
        if (_platformFee > 1000) FeeTooHigh.selector.revertWith();
        if (_platformFeeRecipient == address(0)) InvalidAddress.selector.revertWith();

        platformFee = _platformFee;
        platformFeeRecipient = _platformFeeRecipient;
        minCuratorDeposit = _minCuratorDeposit;
        _setSuperAdmin(_owner);
    }

    /**
     * @notice Initialize the contract (for proxy implementations)
     * @param _poolStateManager Address of the pool state manager
     */
    function initialize(address _poolStateManager) external initializer onlySuperAdmin {
        if (_poolStateManager == address(0)) InvalidAddress.selector.revertWith();
        poolStateManager = _poolStateManager;
    }

    // ============ External Functions ============

    /**
     * @notice Register as a curator
     * @param name A human-readable name for the curator
     */
    function registerCurator(string calldata name) external payable nonReentrant {
        if (bytes(curators[msg.sender].name).length > 0) AlreadyRegistered.selector.revertWith();
        if (msg.value < minCuratorDeposit) InsufficientDeposit.selector.revertWith();

        curators[msg.sender] =
            CuratorInfo({name: name, registrationTime: block.timestamp, reputationScore: 0, verified: false});

        emit CuratorRegistered(msg.sender, name);
    }

    /**
     * @notice Register a new strategy
     * @param implementation Address of the strategy implementation
     * @param name Human-readable name for the strategy
     * @param description Brief description of the strategy
     * @param curatorFee Fee in basis points for using this strategy
     * @return strategyId The ID of the registered strategy
     */
    function registerStrategy(
        address implementation,
        string calldata name,
        string calldata description,
        uint256 curatorFee
    ) external nonReentrant returns (bytes32 strategyId) {
        // Check if the caller is a registered curator
        if (bytes(curators[msg.sender].name).length == 0) NotCurator.selector.revertWith();

        // Check implementation and fee
        if (implementation == address(0)) InvalidAddress.selector.revertWith();
        if (curatorFee > 1000) FeeTooHigh.selector.revertWith();

        // Get strategy type from implementation
        string memory strategyType = IBondingCurveStrategy(implementation).strategyType();

        // Generate unique ID
        strategyId = keccak256(abi.encodePacked(strategyType, name, implementation, msg.sender));

        // Check if strategy already exists
        if (strategies[strategyId].implementation != address(0)) StrategyAlreadyExists.selector.revertWith();

        // Register strategy
        strategies[strategyId] = StrategyInfo({
            implementation: implementation,
            curator: msg.sender,
            name: name,
            description: description,
            enabled: true,
            registrationTime: block.timestamp,
            usageCount: 0,
            curatorFee: curatorFee
        });

        // Add to curator's strategies
        curatorStrategies[msg.sender].push(strategyId);

        // Add to strategy type registry
        strategyTypes[strategyType].push(strategyId);

        emit StrategyRegistered(strategyId, implementation, msg.sender);

        return strategyId;
    }

    /**
     * @notice Get the implementation address for a strategy
     * @param strategyId The ID of the strategy
     * @return The implementation address
     */
    function getStrategyImplementation(bytes32 strategyId) external view returns (address) {
        if (strategies[strategyId].implementation == address(0)) StrategyNotFound.selector.revertWith();
        return strategies[strategyId].implementation;
    }

    /**
     * @notice Get detailed information about a strategy
     * @param strategyId The ID of the strategy
     * @return implementation The strategy implementation address
     * @return curator The curator address
     * @return name The strategy name
     * @return description The strategy description
     * @return enabled Whether the strategy is enabled
     * @return usageCount How many times the strategy has been used
     * @return curatorFee The curator's fee in basis points
     */
    function getStrategyInfo(bytes32 strategyId)
        external
        view
        returns (
            address implementation,
            address curator,
            string memory name,
            string memory description,
            bool enabled,
            uint256 usageCount,
            uint256 curatorFee
        )
    {
        StrategyInfo storage info = strategies[strategyId];
        if (info.implementation == address(0)) StrategyNotFound.selector.revertWith();

        return (
            info.implementation,
            info.curator,
            info.name,
            info.description,
            info.enabled,
            info.usageCount,
            info.curatorFee
        );
    }

    /**
     * @notice Get strategies by type
     * @param strategyType The type of strategies to retrieve
     * @return Array of strategy IDs of the specified type
     */
    function getStrategiesByType(string calldata strategyType) external view returns (bytes32[] memory) {
        return strategyTypes[strategyType];
    }

    /**
     * @notice Get all strategies created by a curator
     * @param curator The curator address
     * @return Array of strategy IDs
     */
    function getCuratorStrategies(address curator) external view returns (bytes32[] memory) {
        return curatorStrategies[curator];
    }

    /**
     * @notice Enable a strategy
     * @param strategyId ID of the strategy to enable
     */
    function enableStrategy(bytes32 strategyId) external {
        StrategyInfo storage info = strategies[strategyId];
        if (info.implementation == address(0)) StrategyNotFound.selector.revertWith();
        if (info.curator != msg.sender && superAdmin() != msg.sender) NotStrategyCurator.selector.revertWith();

        info.enabled = true;
        emit StrategyEnabled(strategyId);
    }

    /**
     * @notice Disable a strategy
     * @param strategyId ID of the strategy to disable
     */
    function disableStrategy(bytes32 strategyId) external {
        StrategyInfo storage info = strategies[strategyId];
        if (info.implementation == address(0)) StrategyNotFound.selector.revertWith();
        if (info.curator != msg.sender && superAdmin() != msg.sender) NotStrategyCurator.selector.revertWith();

        info.enabled = false;
        emit StrategyDisabled(strategyId);
    }

    /**
     * @notice Increment the usage count for a strategy (only callable by PoolStateManager)
     * @param strategyId ID of the strategy
     */
    function incrementUsageCount(bytes32 strategyId) external {
        // Only the PoolStateManager can call this
        if (msg.sender != poolStateManager) PoolNotInitialized.selector.revertWith();
        if (strategies[strategyId].implementation == address(0)) StrategyNotFound.selector.revertWith();

        strategies[strategyId].usageCount++;
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the platform fee
     * @param newFee New platform fee in basis points
     */
    function setPlatformFee(uint256 newFee) external onlySuperAdmin {
        if (newFee > 1000) FeeTooHigh.selector.revertWith();
        platformFee = newFee;
    }

    /**
     * @notice Set the platform fee recipient
     * @param newRecipient New address to receive platform fees
     */
    function setPlatformFeeRecipient(address newRecipient) external onlySuperAdmin {
        if (newRecipient == address(0)) InvalidAddress.selector.revertWith();
        platformFeeRecipient = newRecipient;
    }

    /**
     * @notice Set minimum curator deposit
     * @param newMinDeposit New minimum deposit amount
     */
    function setMinCuratorDeposit(uint256 newMinDeposit) external onlySuperAdmin {
        minCuratorDeposit = newMinDeposit;
    }

    /**
     * @notice Update the pool state manager address
     * @param newPoolStateManager New pool state manager address
     */
    function setPoolStateManager(address newPoolStateManager) external onlySuperAdmin {
        if (newPoolStateManager == address(0)) InvalidAddress.selector.revertWith();
        poolStateManager = newPoolStateManager;
    }

    /**
     * @notice Verify a curator (only callable by owner)
     * @param curator Address of the curator to verify
     * @param verified New verification status
     */
    function setCuratorVerification(address curator, bool verified) external onlySuperAdmin {
        if (bytes(curators[curator].name).length == 0) NotCurator.selector.revertWith();
        curators[curator].verified = verified;
    }

    /**
     * @notice Update a curator's reputation score (only callable by owner)
     * @param curator Address of the curator
     * @param newScore New reputation score
     */
    function updateCuratorReputation(address curator, uint256 newScore) external onlySuperAdmin {
        if (bytes(curators[curator].name).length == 0) NotCurator.selector.revertWith();
        curators[curator].reputationScore = newScore;
    }

    /**
     * @notice Withdraw ETH from the contract (only callable by owner)
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function withdrawETH(uint256 amount, address recipient) external onlySuperAdmin {
        if (recipient == address(0)) InvalidAddress.selector.revertWith();
        if (amount > address(this).balance) {
            amount = address(this).balance;
        }
        (bool success,) = recipient.call{value: amount}("");
        require(success, "Transfer failed");
    }
}
