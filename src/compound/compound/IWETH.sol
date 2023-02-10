// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.14;
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}