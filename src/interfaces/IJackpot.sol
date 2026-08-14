// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice USDG jackpot attribution from a buy (after Main→USDG convert) or a sell.
struct JackpotRecord {
    uint256 listingId;
    uint256 buyId; // 0 on sell
    bool isBuy;
    address mainToken;
    uint256 usdgAmount;
    uint256 mainAmountConverted; // 0 on sell
    uint64 timestamp;
    uint64 blockNumber;
}

interface IJackpot {
    /// @dev USDG share is transferred to this contract before the call.
    function receiveJackpotFee(JackpotRecord calldata record) external;
}
