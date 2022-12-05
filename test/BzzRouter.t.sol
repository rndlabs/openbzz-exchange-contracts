// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";

import {Test} from "../lib/forge-std/src/Test.sol";
import {BzzRouter, Operation} from "../src/BzzRouter.sol";
import {IPostageStamp} from "../src/interfaces/IPostageStamp.sol";

interface IERC677 {
    function transferAndCall(address _to, uint256 _value, bytes calldata _data) external returns (bool);
}

contract BzzRouterTest is Test {
    using SafeTransferLib for ERC20;

    struct TestAccount {
        address addr;
        uint256 key;
    }

    BzzRouter public router;

    // --- constants
    TestAccount alice;
    TestAccount bob;
    TestAccount owner;

    address swarmDeployer = 0x647942035bb69C8e4d7EB17C8313EBC50b0bABFA;

    // --- main contracts
    address bridge;
    IPostageStamp postOffice;
    
    // --- token contracts
    ERC20 bzz;
    ERC20 usdc;

    function setUp() public {
        // setup test accounts
        (address alice_, uint256 key) = makeAddrAndKey("alice");
        alice = TestAccount(alice_, key);
        (address bob_, uint256 bobkey) = makeAddrAndKey("bob");
        bob = TestAccount(bob_, bobkey);
        (address owner_, uint256 key_) = makeAddrAndKey("owner");
        owner = TestAccount(owner_, key_);

        // setup the contracts
        bridge = 0xf6A78083ca3e2a662D6dd1703c939c8aCE2e268d;
        bzz = ERC20(0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da);
        usdc = ERC20(0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83);
        postOffice = IPostageStamp(0xa9c84e9ccC0A0bC9B8C8E948F24E024bC2607c9A);

        // deploy router
        router = new BzzRouter(
            owner.addr,
            bridge,
            address(bzz),
            postOffice
        );

        // give 10 XDAI to the router for gifts
        vm.deal(address(router), 10 ether);
    }

    // --- bridging
    function testBridgeAuth() public {
        vm.prank(alice.addr);
        vm.expectRevert("router/caller-not-bridge");
        router.onTokenBridged(address(0), 1 ether, "");
    }

    function testTransferAndCallReversion() public {
        deal(address(bzz), alice.addr, 10 ether);
        deal(address(usdc), alice.addr, 10 ether);

        vm.startPrank(alice.addr);
        vm.expectRevert();
        IERC677(address(usdc)).transferAndCall(address(router), 10 ether, "cd");
        vm.expectRevert();
        IERC677(address(bzz)).transferAndCall(address(router), 10 ether, "");
    }

    function testTransferAndCallDistributor() public {
        // create the recipients array
        address[] memory recipients = new address[](2);
        recipients[0] = alice.addr;
        recipients[1] = bob.addr;

        // create the calldata
        bytes memory cd = abi.encode(Operation.Bridge, abi.encode(recipients));

        deal(address(bzz), owner.addr, 10 ether);

        // test using transferAndCall
        vm.prank(owner.addr);
        IERC677(address(bzz)).transferAndCall(address(router), 10 ether, cd);

        assertEq(bzz.balanceOf(alice.addr), 5 ether);
        assertEq(bzz.balanceOf(bob.addr), 5 ether);
    }

    function testBridgeDistributor() public {
        // create the recipients array
        address[] memory recipients = new address[](2);
        recipients[0] = alice.addr;
        recipients[1] = bob.addr;

        // create the calldata
        bytes memory cd = abi.encode(Operation.Bridge, abi.encode(recipients));

        uint256 testBzzAmount = 1 ether; // 100 BZZ as BZZ is 16 decimals
        deal(address(bzz), address(router), testBzzAmount);

        // simulate the bridge
        vm.prank(bridge);
        router.onTokenBridged(address(bzz), testBzzAmount, cd);

        // check that the BZZ was evenly distributed
        assertEq(bzz.balanceOf(alice.addr), 0.5 ether);
        assertEq(bzz.balanceOf(bob.addr), 0.5 ether);

        // check the gift
        assertEq(address(alice.addr).balance, router.gift());
        assertEq(address(bob.addr).balance, router.gift());
    }

    function testBridgeBatchTopUp() public {
        // create the array for batch topups
        bytes32[] memory batches = new bytes32[](1);

        // first batch
        batches[0] = 0x0e8366a6fdac185b6f0327dc89af99e67d9d3b3f2af22432542dc5971065c1df;

        // create the calldata
        bytes memory cd = abi.encode(Operation.TopUp, abi.encode(batches));
        
        // "bridge" the tokens
        deal(address(bzz), address(router), 1 ether);

        // test with paused postage stamp contract
        uint256 snapshotId = vm.snapshot();
        uint256 router_balance = bzz.balanceOf(address(router));
        vm.prank(swarmDeployer);
        postOffice.pause();
        vm.prank(bridge);
        router.onTokenBridged(address(bzz), 0, cd); // this should not revert
        assertEq(router_balance, bzz.balanceOf(address(router))); // should be no change to balance

        // revert to previous snapshot
        vm.revertTo(snapshotId);

        // do the batch topup
        vm.prank(bridge);
        router.onTokenBridged(address(bzz), 1 ether, cd);
        assertApproxEqAbs(router_balance - bzz.balanceOf(address(router)), 1 ether, 1_000_000_000);
    }

    // --- owner function tests (all must test auth)
    function testPostOffice() public {
        vm.prank(alice.addr);
        vm.expectRevert("UNAUTHORIZED");
        router.setPostOffice(IPostageStamp(address(0)));

        vm.startPrank(owner.addr);
        vm.expectRevert("admin/invalid-contract");
        router.setPostOffice(IPostageStamp(address(0)));

        router.setPostOffice(IPostageStamp(address(0x1337)));
    }

    function testSetGift() public {
        vm.prank(alice.addr);
        vm.expectRevert("UNAUTHORIZED");
        router.setGift(1 ether);

        vm.startPrank(owner.addr);

        // test setting too generous a gift
        vm.expectRevert("admin/too-generous");
        router.setGift(100 ether);

        // test correctly setting a gift
        router.setGift(1 ether);
        assertEq(router.gift(), 1 ether);

        router.setGift(1 wei);
        assertEq(router.gift(), 1 wei);
    }

    function testSweep() public {
        vm.prank(alice.addr);
        vm.expectRevert("UNAUTHORIZED");
        router.sweep(bzz, 1 ether);

        deal(address(bzz), address(router), 1 ether);

        vm.startPrank(owner.addr);

        // test sweeping erc20 tokens
        uint256 owner_balance = bzz.balanceOf(owner.addr);
        uint256 router_balance = bzz.balanceOf(address(router));

        router.sweep(bzz, router_balance);

        assertEq(bzz.balanceOf(owner.addr), owner_balance + router_balance);
        assertEq(bzz.balanceOf(address(router)), 0);

        // test sweeping ether
        owner_balance = address(owner.addr).balance;
        router_balance = address(router).balance;

        router.sweep(ERC20(address(0)), 0);

        assertEq(address(owner.addr).balance, owner_balance + router_balance);
        assertEq(address(router).balance, 0);
    }

    function testReceiveEth() public {
        vm.deal(alice.addr, 10 ether);
        vm.prank(alice.addr);
        payable(address(router)).transfer(1 ether);
    }
}