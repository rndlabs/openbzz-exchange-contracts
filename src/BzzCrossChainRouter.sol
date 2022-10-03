// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "solmate/auth/Owned.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/tokens/ERC721.sol";
import "solmate/tokens/ERC1155.sol";
import "solmate/utils/SafeTransferLib.sol";

import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC1155.sol";
import "@openzeppelin/contracts/interfaces/IERC165.sol";

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
contract BzzCrossChainRouter is
    Owned,
    IERC165,
    ERC677Callback,
    IERC20Receiver,
    ERC721TokenReceiver,
    ERC1155TokenReceiver
{
    // token address of bzz
    ERC20 private bzz;

    PostageStamp private postOffice;

    constructor(address _owner, address _bzz, PostageStamp _postOffice) Owned(_owner) {
        // token configuration
        bzz = ERC20(_bzz);
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
    /// @param token the address of the token to sweep
    /// @param cd calldata relative to the type of sweep operation
    function sweep(address token, bytes calldata cd) external onlyOwner {
        // 1. check if it is an ERC721 sweep request
        (bool success, bytes memory result) =
            token.call(abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IERC721).interfaceId));

        if (success && abi.decode(result, (bool))) {
            IERC721(token).safeTransferFrom(address(this), owner, abi.decode(cd, (uint256)));
            return;
        }

        // 2. check if it is an ERC1155 sweep request
        (success, result) =
            token.call(abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IERC1155).interfaceId));

        if (success && abi.decode(result, (bool))) {
            (uint256 id, uint256 amount, bytes memory data) = abi.decode(cd, (uint256, uint256, bytes));
            IERC1155(token).safeTransferFrom(address(this), owner, id, amount, data);
            return;
        }

        // 3. fallback to sweeping ERC20
        ERC20(token).transfer(owner, abi.decode(cd, (uint256)));
    }

    /// fallback function for automatically sweeping native tokens to the owner
    fallback() external payable {
        SafeTransferLib.safeTransferETH(payable(owner), msg.value);
    }

    /// IERC165 (introspection) support
    /// @param interfaceID the interface to check if this contract supports or not
    /// @return bool true if the respective interface is supported, false if not
    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == 0x01ffc9a7 // ERC-165 support (i.e. `bytes4(keccak256('supportsInterface(bytes4)'))`).
            || interfaceID == 0x150b7a02 // ERC-721 support (i.e. `bytes4(keccak256('onERC721Received(address,address,uint256,bytes)'))`).
            || interfaceID == 0x4e2312e0; // ERC-1155 `ERC1155TokenReceiver` support (i.e. `bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)")) ^ bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))`).
    }
}
