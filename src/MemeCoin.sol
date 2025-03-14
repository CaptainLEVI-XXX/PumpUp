// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMemeCoin} from "./interfaces/IMemeCoin.sol";
import {INft} from "./interfaces/INft.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

contract MemeCoin is ERC20, IMemeCoin {
    using CustomRevert for bytes4;

    bytes32 private constant _VERSION_HASH = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    address private nftAddress_;

    string private name_;

    string private symbol_;

    /// Token URI
    string public tokenURI;

    constructor(string memory _name, string memory _symbol, string memory _tokenUri) {
        name_ = _name;
        symbol_ = _symbol;
        nftAddress_ = msg.sender;
        tokenURI = _tokenUri;
    }

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
     * Destroys a `value` amount of tokens from the caller.
     *
     * See {ERC20-_burn}.
     */
    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }

    /**
     * Destroys a `value` amount of tokens from `account`, deducting from
     * the caller's allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     */
    function burnFrom(address account, uint256 value) external {
        _spendAllowance(account, msg.sender, value);
        _burn(account, value);
    }

    /**
     * Finds the "creator" of the memecoin, which equates to the owner of the {Flaunch} ERC721. This
     * means that if the NFT is traded, then the new holder would become the creator.
     *
     * @dev This also means that if the token is burned we can expect a zero-address response
     *
     * @return creator_ The "creator" of the memecoin
     */
    function creator() external view override returns (address creator_) {
        INft nftinterface = INft(nftAddress_);
        uint256 tokenId = nftinterface.tokenId(address(this));

        // Handle case where the token has been burned
        try nftinterface.ownerOf(tokenId) returns (address owner) {
            creator_ = owner;
        } catch {}
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
