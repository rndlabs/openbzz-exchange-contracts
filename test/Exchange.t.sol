// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "makerdao/dss/DaiAbstract.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";

import {Test} from "../lib/forge-std/src/Test.sol";
import {Exchange, BuyParams, SellParams, Stablecoin, LiquidityProvider} from "../src/Exchange.sol";
import {IForeignBridge} from "../src/interfaces/IForeignBridge.sol";
import {IBondingCurve} from "../src/interfaces/IBondingCurve.sol";

contract ExchangeTest is Test {
    using SafeTransferLib for ERC20;

    struct TestAccount {
        address addr;
        uint256 key;
    }

    Exchange public exchange;
    SigUtilsDAI public sigUtilsDai;
    SigUtilsEIP2612 public sigUtilsEip2612;

    // --- constants
    TestAccount alice;
    TestAccount owner;

    // --- main contracts
    IBondingCurve bc;
    IForeignBridge bridge;

    // --- token contracts
    ERC20 dai;
    ERC20 usdc;
    ERC20 usdt;
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
            0x4F32Ab778e85C4aD0CEad54f8f82F5Ee74d46904, // bonding curve
            0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7, // lp curve fi
            0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168, // lp uni3 dai usdc
            0x48DA0965ab2d2cbf1C17C09cFB5Cbe67Ad5B1406, // lp uni3 dai usdt
            0x89B78CfA322F6C5dE0aBcEecab66Aee45393cC5A, // lp dai psm
            0x88ad09518695c6c3712AC10a214bE5109a655671, // bridge
            100 // max fee
        );

        // setup the bonding curve and bridge
        bc = IBondingCurve(exchange.bc());
        bridge = IForeignBridge(exchange.bridge());

        // setup the tokens
        dai = ERC20(bc.collateralToken());
        bzz = ERC20(bc.bondedToken());
        usdc = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        usdt = ERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);

        // deploy sigutils
        sigUtilsDai = new SigUtilsDAI(DaiAbstract(address(dai)).DOMAIN_SEPARATOR());
        sigUtilsUsdc = new SigUtilsEIP2612(usdc.DOMAIN_SEPARATOR());

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
        exchange.buy1(10 ether, 1000 ether, "", "");

        deal(address(dai), address(alice.addr), 10000e18);

        // test allowance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy1(10 ether, 1000 ether, "", "");

        dai.approve(address(exchange), type(uint256).max);

        // test the buy
        uint256 pre_alice_balance = bzz.balanceOf(alice.addr);
        uint256 pre_exchange_balance = dai.balanceOf(address(exchange));

        exchange.buy1(10 ether, 1000 ether, "", "");

        /// @dev assert that alice gets the net amount and the exchange gets the fees
        assertEq(bzz.balanceOf(alice.addr), pre_alice_balance + net(10 ether));
        assertGt(dai.balanceOf(address(exchange)), pre_exchange_balance);
    }

    function testBuyAndBridge() public {
        vm.startPrank(alice.addr);

        deal(address(dai), address(alice.addr), 10000 ether);
        dai.approve(address(exchange), type(uint256).max);

        exchange.buy1(10 ether, 1000 ether, "", abi.encode(alice.addr));
    }

    function testBuyAndBridgeToBatch() public {
        vm.startPrank(alice.addr);

        deal(address(dai), address(alice.addr), 10000 ether);
        dai.approve(address(exchange), type(uint256).max);

        exchange.buy1(10 ether, 1000 ether, "", abi.encode(alice.addr, abi.encode(bytes32("test"), uint256(1))));
    }

    function testBuyPermit() public {
        vm.startPrank(alice.addr);

        // test balance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy1(10 ether, 1000 ether, "", "");

        deal(address(dai), address(alice.addr), 10000e18);

        // test allowance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy1(10 ether, 1000 ether, "", "");

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
        exchange.buy1(10 ether, 1000 ether, permit_bytes, "");

        permit_bytes = abi.encode(uint256(0), type(uint256).max, v, r, s);
        exchange.buy1(10 ether, 1000 ether, permit_bytes, "");

        assertEq(dai.allowance(alice.addr, address(exchange)), type(uint256).max);
        assertEq(DaiAbstract(address(dai)).nonces(alice.addr), 1);

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

contract SigUtilsEIP2612 {
    bytes32 internal DOMAIN_SEPARATOR;

    constructor(bytes32 _DOMAIN_SEPARATOR) {
        DOMAIN_SEPARATOR = _DOMAIN_SEPARATOR;
    }

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    struct Permit {
        address owner;
        address spender;
        uint256 value;
        uint256 nonce;
        uint256 deadline;
    }

    // computes the hash of a permit
    function getStructHash(Permit memory _permit)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    PERMIT_TYPEHASH,
                    _permit.owner,
                    _permit.spender,
                    _permit.value,
                    _permit.nonce,
                    _permit.deadline
                )
            );
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getTypedDataHash(Permit memory _permit)
        public
        view
        returns (bytes32)
    {
        return
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR,
                    getStructHash(_permit)
                )
            );
    }
}

contract SigUtilsDAI {
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
