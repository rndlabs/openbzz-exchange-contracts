// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "solmate/auth/Owned.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";

import {IPostageStamp, Batch} from "../src/interfaces/IPostageStamp.sol";

interface ERC677Callback {
    function onTokenTransfer(address _from, uint256 _value, bytes calldata _data) external returns (bool);
}

interface IERC20Receiver {
    function onTokenBridged(address token, uint256 value, bytes calldata data) external;
}

enum Operation {
    Bridge,
    TopUp
}

/// @title router for bridging bzz tokens from foreign bridge to home bridge
contract BzzRouter is Owned, ERC677Callback, IERC20Receiver {
    using SafeTransferLib for ERC20;

    // bridge addresses
    address private immutable homeBridge;

    // token addresses and postoffice
    ERC20 private immutable bzz;

    // configurable admin options
    IPostageStamp private postOffice;
    uint256 public gift = 1e16;    // set to standard $0.01

    constructor(address _owner, address _homeBridge, address _bzz, IPostageStamp _postOffice) payable Owned(_owner) {
        // bridge configuration
        homeBridge = _homeBridge;

        // token configuration
        bzz = ERC20(_bzz);
        bzz.approve(address(_postOffice), type(uint256).max);

        // other contracts for the relay
        postOffice = _postOffice;
    }

    /// ERC677 transfer callback function for use with honeyswap or similar
    /// @dev ERC677 transfer and call function
    /// @param amount the amount of bzz tokens that were sent to be evenly distributed
    /// @param data the data to be used for determining which batch to topUp
    function onTokenTransfer(address, uint256 amount, bytes memory data) external returns (bool) {
        // should only be able to call this from the erc677 contract
        require(msg.sender == address(bzz) && data.length != 0, "erc677/invalid-tx");
        execute(amount, data);

        return true;
    }

    /// Function for routing execution path to multiple batch topup or bridging to multiple nodes
    /// @param token the token address that has been sent
    /// @param amount the amount of bzz tokens that were bridged to be evenly distributed
    /// @param data used to determine which batch is to be topped up and how
    function onTokenBridged(address token, uint256 amount, bytes memory data) external {
        require(msg.sender == homeBridge, "router/caller-not-bridge");
        if (data.length != 0 && token == address(bzz)) {
            execute(amount, data);
        }
    }

    /// Internally route the execution logic based on the operation type
    /// @param amount of bzz tokens that were bridged
    /// @param data calldata to be decoded based on operation type
    function execute(uint256 amount, bytes memory data) internal {
        (Operation op, bytes memory cd) = abi.decode(data, (Operation, bytes));
        if (op == Operation.TopUp && !postOffice.paused()) {
            multiTopUp(amount, abi.decode(cd, (bytes32[])));
        } else if (op == Operation.Bridge) {
            multiBridge(amount, abi.decode(cd, (address[])));
        }
    }

    /// Top up multiple stamp batches at once
    /// @param amount the total amount of bzz to be distributed between the stamps
    /// @param topUps the topUps to be performed
    function multiTopUp(uint256 amount, bytes32[] memory topUps) internal {
        // calculate the total number of chunks across all batches
        uint256 numChunks;
        for (uint256 i = 0; i < topUps.length; i++) {
            Batch memory batch = postOffice.batches(topUps[i]);
            numChunks += (1 << batch.depth);
        }

        // split the bzz across all the chunks
        uint256 topupAmountPerChunk = amount / numChunks;

        // top up all the batches
        for (uint256 i = 0; i < topUps.length; i++) {
            postOffice.topUp(topUps[i], topupAmountPerChunk);
        }
    }

    /// Distributes BZZ to multiple nodes
    /// @param amount the total amount of bzz to be distributed between the recipients
    /// @param to an array of addresses to be sprinkled with bzz
    function multiBridge(uint256 amount, address[] memory to) internal {
        // check to make sure the contract has sufficient balance to gift
        (uint256 wadXdai, uint256 wadBzz) = (
            (address(this).balance >= gift * to.length && msg.sender == homeBridge) ?  gift : 0,
            amount / to.length
        );
        
        for (uint256 i = 0; i < to.length; i++) {
            // only gift gas to those that do not have any xdai
            if (to[i].balance == 0 && wadXdai != 0) {
                payable(to[i]).transfer(wadXdai);
            }

            // send the bzz specified to the address
            bzz.safeTransfer(to[i], wadBzz);
        }
    }

    // --- admin functions

    // Set the postage office that is used for topping up stamps 
    function setPostOffice(IPostageStamp _postOffice) external onlyOwner {
        require(address(_postOffice) != address(0), "admin/invalid-contract");
        postOffice = _postOffice;
    }

    /// Set the amount that will be gifted to new nodes that have no existing xDai
    /// @param _gift the amount of xdai, in wei to gift to new nodes
    function setGift(uint256 _gift) external onlyOwner {
        require(_gift <= 1 ether, "admin/too-generous");
        gift = _gift;
    }

    /// Sweeper function for any ERC20 tokens accidentally sent to the contract
    /// @notice this function will send the ERC20 tokens to the owner of the contract
    /// @param token the address of the token to sweep
    /// @param wad amount of ERC20 tokens to send to owner
    function sweep(ERC20 token, uint256 wad) external onlyOwner {
        if (address(token) == address(0)) {
            payable(owner).transfer(address(this).balance);
        } else {
            token.safeTransfer(owner, wad);
        }
    }

    receive() external payable {}
}
