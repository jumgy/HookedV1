// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IMainToken {
    function increaseTransferAllowance(bytes32 poolId, uint256 amountAllowed) external;
}
