// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Buy attribution payload delivered by HookedV1 with the collector's MainToken fee share.
struct BuyRecord {
    uint256 listingId;
    uint256 buyId;
    address quoteToken;
    address mainToken;
    uint256 quoteAmountIn;
    uint256 mainAmountOut;
    /// @dev Gross buy fee taken in MainToken before currency conversion.
    uint256 feeMainTaken;
    uint256 feeMainToCollector;
    uint256 feeQuoteToJackpot;
    uint256 feeQuoteToOps;
    uint64 timestamp;
    uint64 blockNumber;
}

interface IFeeCollector {
    /// @dev Collector's MainToken share is transferred to this contract before the call.
    function receiveBuyFee(BuyRecord calldata record) external;
}
