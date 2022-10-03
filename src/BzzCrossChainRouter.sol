// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface PostageStamp {
    function topUp(bytes32 _batchId, uint256 _topupAmountPerChunk) external;
}

interface ERC677Callback {
    function onTokenTransfer(address _from, uint256 _value, bytes calldata _data) external returns (bool);
}

interface IERC20Receiver {
    function onTokenBridged(address token, uint256 value, bytes calldata data) external;
}

/// @title router for bzz being sent from foreign bridge to home bridge
contract BzzCrossChainRouter is Ownable, ERC677Callback, IERC20Receiver {
    // token address of bzz
    IERC20 private bzz;

    PostageStamp private postOffice;

    constructor(address _owner, address _bzz, PostageStamp _postOffice) {
        _transferOwnership(_owner);

        // token configuration
        bzz = IERC20(_bzz);
        bzz.approve(address(_postOffice), type(uint256).max);

        // other contracts for the relay
        postOffice = _postOffice;
    }

    /// ERC677 transfer callback function for use with honeyswap or similar
    /// @dev ERC677 transfer and call function
    /// @param data the data to be used for determining which batch to topUp
    function onTokenTransfer(address, uint256, bytes memory data) external returns (bool) {
        if (msg.sender != address(bzz)) {
            return true;
        }

        if (data.length == 0) {
            return false;
        }
        
        _topUp(data);

        return true;
    }

    /// Function for automatically topping up stamp batch with bridged BZZ
    /// @param token the token address that has been sent
    /// @param data used to determine which batch is to be topped up and how
    function onTokenBridged(address token, uint256, bytes calldata data) external {
        if (data.length != 0 && token == address(bzz)) {
            _topUp(data);
        }
    }

    /// Top up a stamp batch
    /// @dev intentionally use an internal function here instead of duplicating in callbacks
    ///      knowingly that this will incur additional JUMP costs, but in most cases, these
    ///      costs will be paid for by bridge validators.
    /// @param data abi encoded calldata from the callback with batch id (bytes32) and amountPerChunk (uint256)
    function _topUp(bytes memory data) internal {
        (bytes32 batchId, uint256 topupAmountPerChunk) = abi.decode(data, (bytes32, uint256));
        postOffice.topUp(batchId, topupAmountPerChunk);
    }

    /// Sweeper function for any tokens or eth accidentally sent to the contract
    /// @notice this function will send the tokens / eth only to the owner of the contract
    /// @param selfOrToken the address of the token to sweep, or the address of this contract in the event of eth
    /// @param idOrAmount the id of the token (EIP721) or the amount of token/eth to sweep
    function sweep(address selfOrToken, uint256 idOrAmount) external onlyOwner {
        if (selfOrToken == address(this)) {
            Address.sendValue(payable(owner()), idOrAmount);
        } else {
            (bool success, bytes memory result) =
                selfOrToken.call(abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IERC721).interfaceId));
            if (success && abi.decode(result, (bool))) {
                IERC721(selfOrToken).safeTransferFrom(address(this), owner(), idOrAmount);
            } else {
                IERC20(selfOrToken).transfer(owner(), idOrAmount);
            }
        }
    }
}
