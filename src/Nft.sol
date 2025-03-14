// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MemeCoin} from "./MemeCoin.sol";
import {SuperAdmin2Step} from "./helpers/SuperAdmin2Step.sol";
import {IPoolStateManager} from "./interfaces/IPoolStateManager.sol";
import {LibString} from "./libraries/LibString.sol";
import {ERC721} from "@solady/tokens/ERC721.sol";
import {Initializable} from "@solady/utils/Initializable.sol";

contract Nft is Initializable, ERC721, SuperAdmin2Step {
    string internal name_ = "Capstone Project Nft";
    string internal symbol_ = "CPnft";

    string public baseURI;

    uint256 nextTokenId = 1;

    uint256 public constant MAX_FAIR_LAUNCH_TOKENS = 40e27;

    mapping(uint256 => address) tokenIdToAddress;
    address poolStateManager;

    constructor(string memory _baseUri) {
        _setSuperAdmin(msg.sender);
        baseURI = _baseUri;
    }

    function initialize(address _poolStateManager) external onlySuperAdmin initializer {
        poolStateManager = _poolStateManager;
    }

    /**
     * Allows a contract owner to update the base URI for the creator ERC721 tokens.
     *
     * @param _baseURI The new base URI
     */
    function setBaseURI(string memory _baseURI) external onlySuperAdmin {
        baseURI = _baseURI;
    }

    /**
     * Returns the ERC721 name.
     */
    function name() public view override returns (string memory) {
        return name_;
    }

    /**
     * Returns the ERC721 symbol.
     */
    function symbol() public view override returns (string memory) {
        return symbol_;
    }

    function launchMemeCoin(IPoolStateManager.LaunchParams calldata params)
        external
        returns (address _memecoin, uint256 _tokenId)
    {
        // Ensure that the initial supply falls within an accepted range
        // if (_params.initialTokenFairLaunch > MAX_FAIR_LAUNCH_TOKENS) revert
        // InvalidInitialSupply(_params.initialTokenFairLaunch);

        // // Check that user isn't trying to premine too many tokens
        // if (_params.premineAmount > _params.initialTokenFairLaunch) revert
        // PremineExceedsInitialAmount(_params.premineAmount, _params.initialTokenFairLaunch);

        // Store the current token ID and increment the next token ID
        _tokenId = nextTokenId;
        unchecked {
            nextTokenId++;
        }

        // Mint ownership token to the creator
        _mint(params.creator, _tokenId);

        // Initialize the memecoin with the metadata
        MemeCoin memecoin = new MemeCoin(params.name, params.symbol, params.tokenUri);
        // _memecoin.initialize(_params.name, _params.symbol, _params.tokenUri);

        _memecoin = address(memecoin);

        // Store the token ID
        tokenIdToAddress[_tokenId] = _memecoin;

        // Mint our initial supply to the {PositionManager}
        memecoin.mint(poolStateManager, params.initialSupply);
    }

    /**
     * Burns `tokenId` by sending it to `address(0)`.
     *
     * @dev The caller must own `tokenId` or be an approved operator.
     *
     * @param _tokenId The token ID to check
     */
    function burn(uint256 _tokenId) public {
        _burn(msg.sender, _tokenId);
    }

    function memecoin(uint256 _tokenId) public view returns (address) {
        return tokenIdToAddress[_tokenId];
    }

    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        // If we are ahead of our tracked tokenIds, then revert
        if (_tokenId == 0 || _tokenId >= nextTokenId) {
            revert TokenDoesNotExist();
        }

        // If the base URI is empty, return the memecoin token URI
        if (bytes(baseURI).length == 0) {
            return MemeCoin(tokenIdToAddress[_tokenId]).tokenURI();
        }

        // Otherwise, concatenate the base URI and the token ID
        return LibString.concat(baseURI, LibString.toString(_tokenId));
    }
}
