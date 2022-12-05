// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

struct Batch {
    // Owner of this batch (0 if not valid).
    address owner;
    // Current depth of this batch.
    uint8 depth;
    // Whether this batch is immutable
    bool immutableFlag;
    // Normalised balance per chunk.
    uint256 normalisedBalance;
}

interface IPostageStamp {
    function paused() external view returns (bool);
    function pause() external;
    function batches(bytes32 batchId) external view returns (Batch memory);
    function lastPrice() external view returns (uint256);
    function remainingBalance(bytes32 _batchId) external view returns (uint256);

    function createBatch(
        address _owner,
        uint256 _initialBalancePerChunk,
        uint8 _depth,
        uint8 _bucketDepth,
        bytes32 _nonce,
        bool _immutable
    ) external;
    function topUp(bytes32 batchId, uint256 topupAmountPerChunk) external;
}