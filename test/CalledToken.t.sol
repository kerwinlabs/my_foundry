// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CalledToken, ITokensReceiver} from "../src/CalledToken.sol";

/// @dev 正常实现回调的接收方。
contract MockReceiver is ITokensReceiver {
    address public operator;
    address public from;
    uint256 public amount;
    bytes public data;

    bool public shouldRevert;
    bytes4 public returnSelector = ITokensReceiver.onTokensReceived.selector;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setReturnSelector(bytes4 value) external {
        returnSelector = value;
    }

    function onTokensReceived(
        address _operator,
        address _from,
        uint256 _amount,
        bytes calldata _data
    ) external override returns (bytes4) {
        if (shouldRevert) revert();

        operator = _operator;
        from = _from;
        amount = _amount;
        data = _data;

        return returnSelector;
    }
}

/// @dev 有 fallback 但没有实现 onTokensReceived 的合约：
///      底层 call 会“成功”，但返回数据为空。
contract NoCallbackReceiver {
    fallback() external {}
}

contract CalledTokenTest is Test {
    CalledToken public token;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 internal constant AMOUNT = 100e18;
    uint256 internal constant ALICE_BALANCE = 1_000e18;

    function setUp() public {
        token = new CalledToken("Called Token", "CALL", 1_000_000e18);
        token.transfer(alice, ALICE_BALANCE);
    }

    function test_ConstructorMintsInitialSupply() public view {
        assertEq(token.totalSupply(), 1_000_000e18);
    }

    // ---------------------------------------------------------------
    // 成功的回调
    // ---------------------------------------------------------------

    function test_TransferAndCallCallsReceiver() public {
        MockReceiver receiver = new MockReceiver();

        vm.prank(alice);
        token.transferAndCall(address(receiver), AMOUNT, "hello");

        // 转账成功
        assertEq(token.balanceOf(alice), ALICE_BALANCE - AMOUNT);
        assertEq(token.balanceOf(address(receiver)), AMOUNT);

        // 回调参数正确
        assertEq(receiver.operator(), alice);
        assertEq(receiver.from(), alice);
        assertEq(receiver.amount(), AMOUNT);
        assertEq(keccak256(receiver.data()), keccak256(bytes("hello")));
    }

    // ---------------------------------------------------------------
    // 回调失败的几种情况：整笔交易都应回滚
    // ---------------------------------------------------------------

    function test_TransferAndCallToEOAReverts() public {
        vm.prank(alice);
        vm.expectRevert(CalledToken.TokensReceiptRejected.selector);
        // bob 是 EOA，call 会“成功”但没有返回数据
        token.transferAndCall(bob, AMOUNT, "");

        assertEq(token.balanceOf(alice), ALICE_BALANCE);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferAndCallToContractWithoutHookReverts() public {
        NoCallbackReceiver receiver = new NoCallbackReceiver();

        vm.prank(alice);
        vm.expectRevert(CalledToken.TokensReceiptRejected.selector);
        token.transferAndCall(address(receiver), AMOUNT, "");

        assertEq(token.balanceOf(alice), ALICE_BALANCE);
        assertEq(token.balanceOf(address(receiver)), 0);
    }

    function test_TransferAndCallRevertsWhenReceiverReverts() public {
        MockReceiver receiver = new MockReceiver();
        receiver.setShouldRevert(true);

        vm.prank(alice);
        vm.expectRevert(CalledToken.TokensReceiptRejected.selector);
        token.transferAndCall(address(receiver), AMOUNT, "");

        assertEq(token.balanceOf(alice), ALICE_BALANCE);
        assertEq(token.balanceOf(address(receiver)), 0);
    }

    function test_TransferAndCallRevertsOnWrongSelector() public {
        MockReceiver receiver = new MockReceiver();
        receiver.setReturnSelector(bytes4(0xdeadbeef));

        vm.prank(alice);
        vm.expectRevert(CalledToken.TokensReceiptRejected.selector);
        token.transferAndCall(address(receiver), AMOUNT, "");

        assertEq(token.balanceOf(alice), ALICE_BALANCE);
    }

    function test_TransferAndCallRevertsOnInsufficientBalance() public {
        MockReceiver receiver = new MockReceiver();

        vm.prank(bob); // bob 余额为 0
        vm.expectRevert(); // OZ ERC20: ERC20InsufficientBalance
        token.transferAndCall(address(receiver), AMOUNT, "");
    }
}
