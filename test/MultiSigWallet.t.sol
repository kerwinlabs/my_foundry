// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MultiSigWallet} from "../src/MultiSigWallet.sol";

contract CallTarget {
    uint256 public value;

    function setValue(uint256 newValue) external {
        value = newValue;
    }

    function alwaysFail() external pure {
        revert("target failed");
    }
}

contract MultiSigWalletTest is Test {
    MultiSigWallet public wallet;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public outsider = makeAddr("outsider");
    address public recipient = makeAddr("recipient");

    function setUp() public {
        wallet = new MultiSigWallet([alice, bob, carol]);
        vm.deal(address(wallet), 10 ether);
        vm.deal(outsider, 1 ether);
    }

    // ---------------------------------------------------------------
    // 构造与初始化
    // ---------------------------------------------------------------

    function test_ConstructorSetsThreeOwnersAndTwoOfThreeThreshold() public view {
        assertEq(wallet.OWNER_COUNT(), 3);
        assertEq(wallet.THRESHOLD(), 2);

        assertEq(wallet.owners(0), alice);
        assertEq(wallet.owners(1), bob);
        assertEq(wallet.owners(2), carol);

        assertTrue(wallet.isOwner(alice));
        assertTrue(wallet.isOwner(bob));
        assertTrue(wallet.isOwner(carol));
        assertFalse(wallet.isOwner(outsider));
    }

    function test_ConstructorRevertsOnZeroOwner() public {
        vm.expectRevert(MultiSigWallet.ZeroAddress.selector);
        new MultiSigWallet([alice, bob, address(0)]);
    }

    function test_ConstructorRevertsOnDuplicateOwner() public {
        vm.expectRevert(MultiSigWallet.DuplicateOwner.selector);
        new MultiSigWallet([alice, bob, alice]);
    }

    // ---------------------------------------------------------------
    // proposal
    // ---------------------------------------------------------------

    function test_OwnerCanProposeAndProposerAutoConfirms() public {
        vm.prank(alice);
        uint256 txId = wallet.proposal(recipient, 1 ether, "");

        assertEq(txId, 0);
        assertEq(wallet.transactionCount(), 1);

        (address to, uint256 value, bytes memory data, bool executed, uint256 confirmations) = wallet.transactions(txId);
        assertEq(to, recipient);
        assertEq(value, 1 ether);
        assertEq(data, "");
        assertFalse(executed);
        assertEq(confirmations, 1);

        assertTrue(wallet.isConfirmed(txId, alice));
        assertFalse(wallet.isConfirmed(txId, bob));
        assertFalse(wallet.isConfirmed(txId, carol));
    }

    function test_NonOwnerCannotPropose() public {
        vm.prank(outsider);
        vm.expectRevert(MultiSigWallet.NotOwner.selector);
        wallet.proposal(recipient, 1 ether, "");
    }

    function test_ProposalToZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(MultiSigWallet.ZeroAddress.selector);
        wallet.proposal(address(0), 1 ether, "");
    }

    // ---------------------------------------------------------------
    // confirm
    // ---------------------------------------------------------------

    function test_NonOwnerCannotConfirm() public {
        vm.prank(alice);
        uint256 txId = wallet.proposal(recipient, 1 ether, "");

        vm.prank(outsider);
        vm.expectRevert(MultiSigWallet.NotOwner.selector);
        wallet.confirm(txId);
    }

    function test_ProposerCannotConfirmAgain() public {
        vm.prank(alice);
        uint256 txId = wallet.proposal(recipient, 1 ether, "");

        vm.prank(alice);
        vm.expectRevert(MultiSigWallet.AlreadyConfirmed.selector);
        wallet.confirm(txId);
    }

    function test_OwnerCannotConfirmTwice() public {
        vm.prank(alice);
        uint256 txId = wallet.proposal(recipient, 1 ether, "");

        vm.prank(bob);
        wallet.confirm(txId);

        vm.prank(bob);
        vm.expectRevert(MultiSigWallet.AlreadyConfirmed.selector);
        wallet.confirm(txId);
    }

    function test_ConfirmNonExistentTransactionReverts() public {
        vm.prank(bob);
        vm.expectRevert(MultiSigWallet.NotExistTransaction.selector);
        wallet.confirm(0);
    }

    // ---------------------------------------------------------------
    // execute
    // ---------------------------------------------------------------

    function test_ExecuteBeforeThresholdReverts() public {
        vm.prank(alice);
        uint256 txId = wallet.proposal(recipient, 1 ether, "");

        vm.prank(outsider);
        vm.expectRevert(MultiSigWallet.NotEnoughConfirmations.selector);
        wallet.execute(txId);
    }

    function test_AnyoneCanExecuteAfterTwoConfirmations() public {
        vm.prank(alice);
        uint256 txId = wallet.proposal(recipient, 1 ether, "");

        vm.prank(bob);
        wallet.confirm(txId);

        // 第三方也可以执行，执行结果不受调用者影响。
        vm.prank(outsider);
        wallet.execute(txId);

        assertEq(recipient.balance, 1 ether);
        assertEq(address(wallet).balance, 9 ether);

        (,,, bool executed,) = wallet.transactions(txId);
        assertTrue(executed);
    }

    function test_OwnerCanAlsoExecute() public {
        vm.prank(alice);
        uint256 txId = wallet.proposal(recipient, 1 ether, "");

        vm.prank(carol);
        wallet.confirm(txId);

        vm.prank(carol);
        wallet.execute(txId);

        assertEq(recipient.balance, 1 ether);
    }

    function test_CannotExecuteTwice() public {
        vm.prank(alice);
        uint256 txId = wallet.proposal(recipient, 1 ether, "");

        vm.prank(bob);
        wallet.confirm(txId);
        wallet.execute(txId);

        vm.expectRevert(MultiSigWallet.AlreadyExecuted.selector);
        wallet.execute(txId);
    }

    function test_CannotConfirmExecutedTransaction() public {
        vm.prank(alice);
        uint256 txId = wallet.proposal(recipient, 1 ether, "");

        vm.prank(bob);
        wallet.confirm(txId);
        wallet.execute(txId);

        // carol 还没确认，但交易已经执行完毕。
        vm.prank(carol);
        vm.expectRevert(MultiSigWallet.AlreadyExecuted.selector);
        wallet.confirm(txId);
    }

    function test_ExecuteContractCall() public {
        CallTarget target = new CallTarget();

        vm.prank(alice);
        uint256 txId = wallet.proposal(address(target), 0, abi.encodeCall(CallTarget.setValue, (42)));

        vm.prank(bob);
        wallet.confirm(txId);
        wallet.execute(txId);

        assertEq(target.value(), 42);
    }

    function test_ExecuteRevertsWhenTargetCallFails() public {
        CallTarget target = new CallTarget();

        vm.prank(alice);
        uint256 txId = wallet.proposal(address(target), 0, abi.encodeCall(CallTarget.alwaysFail, ()));

        vm.prank(bob);
        wallet.confirm(txId);

        vm.expectRevert(MultiSigWallet.CallFailed.selector);
        wallet.execute(txId);

        // execute 整体回滚，executed 仍为 false，可以再次尝试。
        (,,, bool executed,) = wallet.transactions(txId);
        assertFalse(executed);
    }

    function test_ExecuteRevertsWhenWalletBalanceIsInsufficient() public {
        vm.prank(alice);
        uint256 txId = wallet.proposal(recipient, 11 ether, "");

        vm.prank(bob);
        wallet.confirm(txId);
        vm.expectRevert(MultiSigWallet.CallFailed.selector);
        wallet.execute(txId);
    }

    // ---------------------------------------------------------------
    // 收款
    // ---------------------------------------------------------------

    function test_WalletCanReceiveEth() public {
        vm.deal(outsider, 2 ether);
        vm.prank(outsider);
        (bool success, ) = address(wallet).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(wallet).balance, 11 ether);
    }
}
