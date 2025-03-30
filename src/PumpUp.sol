// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MemeCoin} from "./MemeCoin.sol";
import {SuperAdmin2Step} from "./helpers/SuperAdmin2Step.sol";
import {PoolStateManager} from "./PoolStateManager.sol";
import {LibString} from "./libraries/LibString.sol";
import {ERC721} from "@solady/tokens/ERC721.sol";
import {Initializable} from "@solady/utils/Initializable.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

contract PumpUp is Initializable, ERC721, SuperAdmin2Step {
    using CustomRevert for bytes4;

    string internal name_ = "PumpUp";
    string internal symbol_ = "PUp";

    string public baseURI;

    uint256 private nextTokenId = 1;

    uint256 public constant MAX_FAIR_LAUNCH_TOKENS = 40e27;

    mapping(uint256 => address) private tokenIdToAddress;
    address private poolStateManager;

    error InvalidInitialSupply(uint256 supply);
    error PremineExceedsInitialAmount(uint256 premine, uint256 initialAmount);
    error InvalidCall();

    constructor(string memory _baseUri, address owner) {
        _setSuperAdmin(owner);
        baseURI = _baseUri;
    }

    modifier onlyPoolStateManager() {
        if (msg.sender != address(poolStateManager)) InvalidCall.selector.revertWith();
        _;
    }

    function initialize(address _poolStateManager) external onlySuperAdmin initializer {
        poolStateManager = _poolStateManager;
    }

    /**
     * @notice Updates the base URI for the creator ERC721 tokens
     * @param _baseURI The new base URI
     */
    function setBaseURI(string memory _baseURI) external onlySuperAdmin {
        baseURI = _baseURI;
    }

    /**
     * @notice Returns the ERC721 name
     */
    function name() public view override returns (string memory) {
        return name_;
    }

    /**
     * @notice Returns the ERC721 symbol
     */
    function symbol() public view override returns (string memory) {
        return symbol_;
    }

    /**
     * @notice Launches a new memecoin and mints an NFT to the creator
     * @param params Launch parameters from PoolStateManager
     * @return _memecoin Address of the created memecoin
     * @return _tokenId ID of the minted NFT
     */
    function launchMemeCoin(PoolStateManager.LaunchParams calldata params)
        external
        onlyPoolStateManager
        returns (address _memecoin, uint256 _tokenId)
    {
        // Uncomment these validations for production

        if (params.initialSupply > MAX_FAIR_LAUNCH_TOKENS) InvalidInitialSupply.selector.revertWith();

        if (params.premineAmount > params.initialSupply) PremineExceedsInitialAmount.selector.revertWith();

        // Store the current token ID and increment
        _tokenId = nextTokenId;
        unchecked {
            nextTokenId++;
        }

        // Mint ownership token to the creator
        _mint(params.creator, _tokenId);

        // Deploy new memecoin with metadata
        MemeCoin memecoin = new MemeCoin(params.name, params.symbol, params.tokenUri);
        _memecoin = address(memecoin);

        // Store the token ID to memecoin mapping
        tokenIdToAddress[_tokenId] = _memecoin;

        // Mint initial supply to the PoolStateManager
        memecoin.mint(poolStateManager, params.initialSupply - params.premineAmount);
        memecoin.mint(params.creator, params.premineAmount);
    }

    /**
     * @notice Burns `tokenId` by sending it to `address(0)`
     * @param _tokenId The token ID to burn
     */
    function burn(uint256 _tokenId) public {
        _burn(msg.sender, _tokenId);
    }

    /**
     * @notice Returns the memecoin address for a given token ID
     * @param _tokenId The token ID to check
     * @return Memecoin contract address
     */
    function memecoin(uint256 _tokenId) public view returns (address) {
        return tokenIdToAddress[_tokenId];
    }

    /**
     * @notice For interface compliance - get token ID for a memecoin
     * @param _memecoin Address of the memecoin
     * @return token ID associated with the memecoin
     */
    function tokenId(address _memecoin) public view returns (uint256) {
        // This is inefficient - ideally you'd have a reverse mapping
        // For now, iterate through tokens (assuming a reasonable number)
        for (uint256 i = 1; i < nextTokenId; i++) {
            if (tokenIdToAddress[i] == _memecoin) {
                return i;
            }
        }
        return 0; // Return 0 if not found
    }

    /**
     * @notice Returns the token URI for a given token ID
     * @param _tokenId The token ID to get URI for
     * @return URI string
     */
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        // Check if the token exists
        if (_tokenId == 0 || _tokenId >= nextTokenId) {
            TokenDoesNotExist.selector.revertWith();
        }

        // If the base URI is empty, return the memecoin token URI
        if (bytes(baseURI).length == 0) {
            return MemeCoin(tokenIdToAddress[_tokenId]).tokenURI();
        }

        // Concatenate base URI and token ID
        return LibString.concat(baseURI, LibString.toString(_tokenId));
    }
}
