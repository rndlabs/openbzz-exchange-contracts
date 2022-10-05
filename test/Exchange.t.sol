// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Exchange, ICurve, ForeignBridge, DaiPermit} from "../src/Exchange.sol";
import "solmate/tokens/ERC20.sol";

contract ExchangeTest is Test {
    struct TestAccount {
        address addr;
        uint256 key;
    }

    Exchange public exchange;
    SigUtils public sigUtils;

    // --- constants
    TestAccount alice;
    TestAccount owner;

    // --- main contracts
    ICurve bc;
    ForeignBridge bridge;

    // --- token contracts
    ERC20 dai;
    ERC20 bzz;

    function setUp() public {
        // setup test accounts
        (address alice_, uint256 key) = makeAddrAndKey("alice");
        alice = TestAccount(alice_, key);
        (address owner_, uint256 key_) = makeAddrAndKey("owner");
        owner = TestAccount(owner_, key_);

        // deploy exchange
        exchange = new Exchange(
            owner.addr,
            0x4F32Ab778e85C4aD0CEad54f8f82F5Ee74d46904,
            0x88ad09518695c6c3712AC10a214bE5109a655671, 
            100
        );

        // setup the bonding curve and bridge
        bc = ICurve(exchange.bc());
        bridge = ForeignBridge(exchange.bridge());

        // setup the tokens
        dai = ERC20(bc.collateralToken());
        bzz = ERC20(bc.bondedToken());

        // deploy sigutils
        sigUtils = new SigUtils(DaiPermit(address(dai)).DOMAIN_SEPARATOR());

        // give alice 10000 eth
        vm.deal(address(alice.addr), 10000 ether);
        deal(address(dai), address(exchange), 10000e18);
    }

    function testSetFee() public {
        vm.prank(alice.addr);
        vm.expectRevert("UNAUTHORIZED");
        exchange.setFee(50);

        vm.startPrank(owner.addr);

        // file a fee change
        exchange.setFee(50);
        assertEq(exchange.fee(), 50);

        // file a value that is too high
        vm.expectRevert(bytes("fee/too-high"));
        exchange.setFee(101);
        assertEq(exchange.fee(), 50);
    }

    function testSweep() public {
        vm.prank(alice.addr);
        vm.expectRevert("UNAUTHORIZED");
        exchange.sweep(dai, uint256(1000));

        vm.startPrank(owner.addr);

        // test sweeping erc20 tokens
        uint256 owner_balance = dai.balanceOf(owner.addr);
        uint256 exchange_balance = dai.balanceOf(address(exchange));
        exchange.sweep(dai, exchange_balance);

        assertEq(dai.balanceOf(owner.addr), owner_balance + exchange_balance);
        assertEq(dai.balanceOf(address(exchange)), 0);
    }

    function testRejectEth() public {
        vm.prank(alice.addr);
        vm.expectRevert();
        payable(address(exchange)).send(1 ether);
    }

    function testBuyNonPermit() public {
        vm.startPrank(alice.addr);

        // test balance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy(10 ether, 1000 ether, "", "");

        deal(address(dai), address(alice.addr), 10000e18);

        // test allowance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy(10 ether, 1000 ether, "", "");

        dai.approve(address(exchange), type(uint256).max);

        // test the buy
        uint256 pre_alice_balance = bzz.balanceOf(alice.addr);
        uint256 pre_exchange_balance = dai.balanceOf(address(exchange));

        exchange.buy(10 ether, 1000 ether, "", "");

        /// @dev assert that alice gets the net amount and the exchange gets the fees
        assertEq(bzz.balanceOf(alice.addr), pre_alice_balance + net(10 ether));
        assertGt(dai.balanceOf(address(exchange)), pre_exchange_balance);
    }

    function testBuyAndBridge() public {
        vm.startPrank(alice.addr);

        deal(address(dai), address(alice.addr), 10000 ether);
        dai.approve(address(exchange), type(uint256).max);

        exchange.buy(10 ether, 1000 ether, "", abi.encode(alice.addr));
    }

    function testBuyAndBridgeToBatch() public {
        vm.startPrank(alice.addr);

        deal(address(dai), address(alice.addr), 10000 ether);
        dai.approve(address(exchange), type(uint256).max);

        exchange.buy(10 ether, 1000 ether, "", abi.encode(alice.addr, abi.encode(bytes32("test"), uint256(1))));
    }

    function testBuyPermit() public {
        vm.startPrank(alice.addr);

        // test balance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy(10 ether, 1000 ether, "", "");

        deal(address(dai), address(alice.addr), 10000e18);

        // test allowance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy(10 ether, 1000 ether, "", "");

        uint256 pre_alice_balance = bzz.balanceOf(alice.addr);
        uint256 pre_exchange_balance = dai.balanceOf(address(exchange));

        SigUtils.Permit memory permit = SigUtils.Permit({
            holder: alice.addr,
            spender: address(exchange),
            nonce: 0,
            expiry: type(uint256).max,
            allowed: true
        });

        bytes32 digest = sigUtils.getTypedDataHash(permit);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, digest);

        vm.expectRevert(bytes("Dai/invalid-permit"));
        bytes memory permit_bytes = abi.encode(uint256(0), type(uint256).max, v, s, r);
        exchange.buy(10 ether, 1000 ether, permit_bytes, "");

        permit_bytes = abi.encode(uint256(0), type(uint256).max, v, r, s);
        exchange.buy(10 ether, 1000 ether, permit_bytes, "");

        assertEq(dai.allowance(alice.addr, address(exchange)), type(uint256).max);
        assertEq(DaiPermit(address(dai)).nonces(alice.addr), 1);

        /// @dev assert that alice gets the net amount and the exchange gets the fees
        assertEq(bzz.balanceOf(alice.addr), pre_alice_balance + net(10 ether));
        assertGt(dai.balanceOf(address(exchange)), pre_exchange_balance);
    }

    function testSell() public {
        // test approvals and balance checking
        vm.startPrank(alice.addr);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.sell(10 ether, 0 ether);

        deal(address(bzz), address(alice.addr), 1000 ether);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.sell(10 ether, 0 ether);

        bzz.approve(address(exchange), type(uint256).max);

        uint256 pre_alice_balance_dai = dai.balanceOf(alice.addr);
        uint256 pre_alice_balance_bzz = bzz.balanceOf(alice.addr);
        uint256 pre_exchange_balance = dai.balanceOf(address(exchange));

        exchange.sell(10 ether, 0 ether);

        /// @dev assert that alice gets the net amount and the exchange gets the fees
        assertGt(dai.balanceOf(alice.addr), pre_alice_balance_dai);
        assertLt(bzz.balanceOf(alice.addr), pre_alice_balance_bzz);
        assertGt(dai.balanceOf(address(exchange)), pre_exchange_balance);
    }

    function net(uint256 gross) internal view returns (uint256) {
        return (10000 - exchange.fee()) * gross / 10000;
    }

    function fee(uint256 gross) internal view returns (uint256) {
        return exchange.fee() * gross / 10000;
    }
}

contract SigUtils {
    bytes32 internal DOMAIN_SEPARATOR;

    constructor(bytes32 _DOMAIN_SEPARATOR) {
        DOMAIN_SEPARATOR = _DOMAIN_SEPARATOR;
    }

    // bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)");
    bytes32 public constant PERMIT_TYPEHASH = 0xea2aa0a1be11a07ed86d755c93467f4f82362b452371d1ba94d1715123511acb;

    struct Permit {
        address holder;
        address spender;
        uint256 nonce;
        uint256 expiry;
        bool allowed;
    }

    // computes the hash of a permit
    function getStructHash(Permit memory _permit) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(PERMIT_TYPEHASH, _permit.holder, _permit.spender, _permit.nonce, _permit.expiry, _permit.allowed)
        );
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getTypedDataHash(Permit memory _permit) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, getStructHash(_permit)));
    }
}
