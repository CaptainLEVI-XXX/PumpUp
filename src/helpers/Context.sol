// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

abstract contract Context {
    function _msgSender() internal view returns (address) {
        return msg.sender;
    }

    function _msgValue() internal view returns (uint256) {
        return msg.value;
    }

    function _msgData() internal pure returns (bytes calldata) {
        return msg.data;
    }
}
