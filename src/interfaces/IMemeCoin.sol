// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IMemeCoin {
    error MintAddressIsZero();
    error UnauthorizedCaller();

    function mint(address _to, uint256 _amount) external;

    function burn(uint256 value) external;

    function burnFrom(address account, uint256 value) external;

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function tokenURI() external view returns (string memory);

    function creator() external view returns (address);
}
