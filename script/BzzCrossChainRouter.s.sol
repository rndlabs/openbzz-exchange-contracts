// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "../src/BzzCrossChainRouter.sol";

contract BzzCrossChainRouterDeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        new BzzCrossChainRouter(vm.envAddress("OWNER_GNOSIS"), vm.envAddress("BZZ_TOKEN_GNOSIS"), PostageStamp(vm.envAddress("POST_OFFICE")));

        vm.stopBroadcast();
    }
}
