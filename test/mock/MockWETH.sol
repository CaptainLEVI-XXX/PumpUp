// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@solady/tokens/ERC20.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

contract MockWETH is ERC20 {
    using CustomRevert for bytes4;
    // State variables - immutable for gas efficiency

    address private immutable nftAddress_;
    string private name_;
    string private symbol_;

    /// @notice Token URI - Kept as non-immutable to allow potential updates
    string public tokenURI;

    error MintAddressIsZero();

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
    function mint(address _to, uint256 _amount) external {
        if (_to == address(0)) {
            MintAddressIsZero.selector.revertWith();
        }
        _mint(_to, _amount);
    }

    /**
     * @notice Burns tokens from the caller's balance
     * @param value Amount to burn
     */
    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }

    function name() public view override(ERC20) returns (string memory) {
        return name_;
    }

    function symbol() public view override(ERC20) returns (string memory) {
        return symbol_;
    }
}
