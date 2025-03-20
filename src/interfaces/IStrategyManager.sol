// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IStrategyManager
 * @author SWAPUMP
 * @notice Interface for the StrategyManager contract
 * @dev Defines the external functions for managing bonding curve strategies
 */
interface IStrategyManager {
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

    // ============ External Functions ============

    /**
     * @notice Initialize the contract (for proxy implementations)
     * @param _poolStateManager Address of the pool state manager
     */
    function initialize(address _poolStateManager) external;

    /**
     * @notice Register as a curator
     * @param name A human-readable name for the curator
     */
    function registerCurator(string calldata name) external payable;

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
    ) external returns (bytes32 strategyId);

    /**
     * @notice Get the implementation address for a strategy
     * @param strategyId The ID of the strategy
     * @return The implementation address
     */
    function getStrategyImplementation(bytes32 strategyId) external view returns (address);

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
        );

    /**
     * @notice Get strategies by type
     * @param strategyType The type of strategies to retrieve
     * @return Array of strategy IDs of the specified type
     */
    function getStrategiesByType(string calldata strategyType) external view returns (bytes32[] memory);

    /**
     * @notice Get all strategies created by a curator
     * @param curator The curator address
     * @return Array of strategy IDs
     */
    function getCuratorStrategies(address curator) external view returns (bytes32[] memory);

    /**
     * @notice Enable a strategy
     * @param strategyId ID of the strategy to enable
     */
    function enableStrategy(bytes32 strategyId) external;

    /**
     * @notice Disable a strategy
     * @param strategyId ID of the strategy to disable
     */
    function disableStrategy(bytes32 strategyId) external;

    /**
     * @notice Increment the usage count for a strategy (only callable by PoolStateManager)
     * @param strategyId ID of the strategy
     */
    function incrementUsageCount(bytes32 strategyId) external;

    /**
     * @notice Set the platform fee
     * @param newFee New platform fee in basis points
     */
    function setPlatformFee(uint256 newFee) external;

    /**
     * @notice Set the platform fee recipient
     * @param newRecipient New address to receive platform fees
     */
    function setPlatformFeeRecipient(address newRecipient) external;

    /**
     * @notice Set minimum curator deposit
     * @param newMinDeposit New minimum deposit amount
     */
    function setMinCuratorDeposit(uint256 newMinDeposit) external;

    /**
     * @notice Update the pool state manager address
     * @param newPoolStateManager New pool state manager address
     */
    function setPoolStateManager(address newPoolStateManager) external;

    /**
     * @notice Verify a curator (only callable by owner)
     * @param curator Address of the curator to verify
     * @param verified New verification status
     */
    function setCuratorVerification(address curator, bool verified) external;

    /**
     * @notice Update a curator's reputation score (only callable by owner)
     * @param curator Address of the curator
     * @param newScore New reputation score
     */
    function updateCuratorReputation(address curator, uint256 newScore) external;

    /**
     * @notice Withdraw ETH from the contract (only callable by owner)
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function withdrawETH(uint256 amount, address recipient) external;

    // ============ View Functions ============

    /**
     * @notice Get the current platform fee in basis points
     * @return Platform fee in basis points
     */
    function platformFee() external view returns (uint256);

    /**
     * @notice Get the platform fee recipient address
     * @return Platform fee recipient address
     */
    function platformFeeRecipient() external view returns (address);

    /**
     * @notice Get the minimum curator deposit
     * @return Minimum deposit required to become a curator
     */
    function minCuratorDeposit() external view returns (uint256);

    /**
     * @notice Get the pool state manager address
     * @return Pool state manager address
     */
    function poolStateManager() external view returns (address);

    /**
     * @notice Get curator information
     * @param curator The curator address
     * @return Curator information
     */
    function curators(address curator) external view returns (CuratorInfo memory);

    /**
     * @notice Get strategy information
     * @param strategyId The strategy ID
     * @return Strategy information
     */
    function strategies(bytes32 strategyId) external view returns (StrategyInfo memory);

    /**
     * @notice Get a curator's strategy at a specific index
     * @param curator The curator address
     * @param index The index in the curator's strategies array
     * @return The strategy ID
     */
    function curatorStrategies(address curator, uint256 index) external view returns (bytes32);

    /**
     * @notice Get a strategy ID of a specific type at a given index
     * @param strategyType The strategy type
     * @param index The index in the strategy type array
     * @return The strategy ID
     */
    function strategyTypes(string calldata strategyType, uint256 index) external view returns (bytes32);
}
