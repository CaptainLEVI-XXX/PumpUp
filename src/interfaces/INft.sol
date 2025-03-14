// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface INft {
    function tokenId(address) external view returns (uint256);
    function ownerOf(uint256) external view returns (address);
}
