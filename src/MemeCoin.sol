// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMemeCoin} from "./interfaces/IMemeCoin.sol";
import {INft} from "./interfaces/INft.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

contract MemeCoin is ERC20, IMemeCoin {
    using CustomRevert for bytes4;

    // Constants
    bytes32 private constant _VERSION_HASH = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    // State variables - immutable for gas efficiency
    address private immutable nftAddress_;
    string private name_;
    string private symbol_;

    /// @notice Token URI - Kept as non-immutable to allow potential updates
    string public tokenURI;

    constructor(string memory _name, string memory _symbol, string memory _tokenUri) {
        name_ = _name;
        symbol_ = _symbol;
        nftAddress_ = msg.sender;
        tokenURI = _tokenUri;
    }

    /**
     * @notice Mints tokens to a specified address
     * @param _to Recipient address
     * @param _amount Amount to mint
     */
    function mint(address _to, uint256 _amount) external onlyNft {
        if (_to == address(0)) {
            MintAddressIsZero.selector.revertWith();
        }
        _mint(_to, _amount);
    }

    modifier onlyNft() {
        if (msg.sender != nftAddress_) {
            UnauthorizedCaller.selector.revertWith();
        }
        _;
    }

    /**
     * @notice Burns tokens from the caller's balance
     * @param value Amount to burn
     */
    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }

    /**
     * @notice Burns tokens from an account with allowance
     * @param account The account to burn from
     * @param value Amount to burn
     */
    function burnFrom(address account, uint256 value) external {
        _spendAllowance(account, msg.sender, value);
        _burn(account, value);
    }

    /**
     * @notice Returns the creator (NFT owner) of this token
     * @return creator_ Creator address or zero if NFT is burned
     */
    function creator() external view override returns (address creator_) {
        INft nftInterface = INft(nftAddress_);
        uint256 tokenId = nftInterface.tokenId(address(this));

        // Handle case where the token has been burned
        if (tokenId != 0) {
            try nftInterface.ownerOf(tokenId) returns (address owner) {
                creator_ = owner;
            } catch {
                // NFT has been burned or doesn't exist - return zero address
            }
        }
    }

    function name() public view override(ERC20, IMemeCoin) returns (string memory) {
        return name_;
    }

    function symbol() public view override(ERC20, IMemeCoin) returns (string memory) {
        return symbol_;
    }

    function _versionHash() internal pure override(ERC20) returns (bytes32 result) {
        return result = _VERSION_HASH;
    }
}
