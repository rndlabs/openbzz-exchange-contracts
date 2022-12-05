// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "../src/BzzRouter.sol";

import {IPostageStamp} from "../src/interfaces/IPostageStamp.sol";

contract BzzRouterDeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        new BzzRouter(
            vm.envAddress("OWNER_GNOSIS"),
            vm.envAddress("HOME_BRIDGE"),
            vm.envAddress("BZZ_TOKEN_GNOSIS"),
            IPostageStamp(vm.envAddress("POST_OFFICE"))
        );

        vm.stopBroadcast();
    }
}
