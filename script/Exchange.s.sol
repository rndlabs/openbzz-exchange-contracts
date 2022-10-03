// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "../src/Exchange.sol";

contract ExchangeDeploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        new Exchange(vm.envAddress("OWNER_MAINNET"), vm.envAddress("BONDING_CURVE_MAINNET"), vm.envAddress("FOREIGN_BRIDGE"), vm.envUint("FEE"));

        vm.stopBroadcast();
    }
}