// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Bank} from "../src/Bank.sol";

contract BankTest is Test {
    Bank public bank;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public dave = makeAddr("dave");

    // withdraw() 会把 ETH 转给 admin，而 setUp 中 admin 是本测试合约
    receive() external payable {}

    function setUp() public {
        bank = new Bank();

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dave, 100 ether);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        bank.deposit{value: amount}();
    }

    function _amounts(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256[3] memory amounts) {
        amounts = [a, b, c];
    }

    function _assertTopDepositors(
        address[3] memory accounts,
        uint256[3] memory amounts
    ) internal view {
        Bank.TopDepositor[3] memory top = bank.getTopDepositors();
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(top[i].account, accounts[i], "top account mismatch");
            assertEq(top[i].amount, amounts[i], "top amount mismatch");
        }
    }

    // ---------------------------------------------------------------
    // 每个地址的存款金额是否被正确记录
    // ---------------------------------------------------------------

    function test_DepositsRecordedPerAddress() public {
        _deposit(alice, 1 ether);
        _deposit(bob, 2 ether);
        _deposit(carol, 3 ether);

        assertEq(bank.deposits(alice), 1 ether);
        assertEq(bank.deposits(bob), 2 ether);
        assertEq(bank.deposits(carol), 3 ether);
        assertEq(bank.deposits(dave), 0);

        assertEq(bank.totalDeposits(), 6 ether);
        assertEq(address(bank).balance, 6 ether);
    }

    function test_DepositsAccumulateForSameAddress() public {
        _deposit(alice, 1 ether);
        _deposit(alice, 2 ether);
        _deposit(alice, 3 ether);

        assertEq(bank.deposits(alice), 6 ether);
        // 同一地址只占榜单一个位置
        assertEq(bank.totalDeposits(), 6 ether);
        _assertTopDepositors(
            [alice, address(0), address(0)],
            _amounts(6 ether, 0, 0)
        );
    }

    function test_DepositEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(bank));
        emit Bank.Deposited(alice, 2 ether, 2 ether);
        _deposit(alice, 2 ether);
    }

    function test_ZeroDepositReverts() public {
        vm.prank(alice);
        vm.expectRevert(Bank.ZeroDeposit.selector);
        bank.deposit{value: 0}();
    }

    // ---------------------------------------------------------------
    // 前三名榜单
    // ---------------------------------------------------------------

    function test_TopDepositorsInitiallyEmpty() public view {
        _assertTopDepositors(
            [address(0), address(0), address(0)],
            _amounts(0, 0, 0)
        );
    }

    function test_TopThreeSortedDescending() public {
        _deposit(dave, 1 ether);
        _deposit(carol, 3 ether);
        _deposit(bob, 2 ether);
        _deposit(alice, 4 ether);

        _assertTopDepositors(
            [alice, carol, bob],
            _amounts(4 ether, 3 ether, 2 ether)
        );
        // dave 存了 1 ether，被挤出前三
        assertEq(bank.deposits(dave), 1 ether);
    }

    function test_FewerThanThreeDepositors() public {
        _deposit(bob, 2 ether);
        _deposit(alice, 5 ether);

        _assertTopDepositors(
            [alice, bob, address(0)],
            _amounts(5 ether, 2 ether, 0)
        );
    }

    function test_ExistingDepositorMovesUpWhenDepositingAgain() public {
        _deposit(alice, 1 ether);
        _deposit(bob, 5 ether);
        _deposit(carol, 3 ether);

        _assertTopDepositors(
            [bob, carol, alice],
            _amounts(5 ether, 3 ether, 1 ether)
        );

        // alice 追加 5 ether，累计 6 ether，应跃升第一，且不产生重复名额
        _deposit(alice, 5 ether);

        _assertTopDepositors(
            [alice, bob, carol],
            _amounts(6 ether, 5 ether, 3 ether)
        );
        assertEq(bank.deposits(alice), 6 ether);
    }

    function test_ExistingThirdPlaceCannotBeForgotten() public {
        _deposit(alice, 3 ether);
        _deposit(bob, 2 ether);
        _deposit(carol, 1 ether);

        // carol 追加到 2.5 ether，应超过 bob 排第二
        _deposit(carol, 1.5 ether);

        _assertTopDepositors(
            [alice, carol, bob],
            _amounts(3 ether, 2.5 ether, 2 ether)
        );
    }

    function test_TieKeepsEarliestDepositorAhead() public {
        _deposit(alice, 3 ether);
        _deposit(bob, 3 ether);
        _deposit(carol, 1 ether);

        // 相同金额时不插队，先来者在前面
        _assertTopDepositors(
            [alice, bob, carol],
            _amounts(3 ether, 3 ether, 1 ether)
        );

        _deposit(dave, 3 ether);
        // dave 与 carol(1 ether) 竞争第三，金额更大，进入第三
        _assertTopDepositors(
            [alice, bob, dave],
            _amounts(3 ether, 3 ether, 3 ether)
        );
    }

    function test_OutsiderBelowThirdDoesNotEnter() public {
        _deposit(alice, 3 ether);
        _deposit(bob, 2 ether);
        _deposit(carol, 1 ether);

        _deposit(dave, 0.5 ether);

        _assertTopDepositors(
            [alice, bob, carol],
            _amounts(3 ether, 2 ether, 1 ether)
        );
        assertEq(bank.deposits(dave), 0.5 ether);
    }

    function test_TopDepositorsUpdatedEvent() public {
        _deposit(alice, 1 ether);

        // 第二次存款后榜单应为 [bob 2, alice 1, 空]
        vm.expectEmit(false, false, false, true, address(bank));
        emit Bank.TopDepositorsUpdated(
            [bob, alice, address(0)],
            _amounts(2 ether, 1 ether, 0)
        );
        _deposit(bob, 2 ether);
    }

    function testFuzz_TopThreeIsExactlyTheLargest(
        uint96 a,
        uint96 b,
        uint96 c,
        uint96 d
    ) public {
        // 0 金额会被 ZeroDeposit 拒绝，因此下界取 1
        uint256[4] memory amounts = [
            bound(uint256(a), 1, type(uint96).max),
            bound(uint256(b), 1, type(uint96).max),
            bound(uint256(c), 1, type(uint96).max),
            bound(uint256(d), 1, type(uint96).max)
        ];
        address[4] memory users = [alice, bob, carol, dave];

        for (uint256 i = 0; i < 4; ++i) {
            vm.deal(users[i], amounts[i]);
            vm.prank(users[i]);
            bank.deposit{value: amounts[i]}();
            assertEq(bank.deposits(users[i]), amounts[i]);
        }

        Bank.TopDepositor[3] memory top = bank.getTopDepositors();

        // 1) 榜单内部金额单调不增
        assertGe(top[0].amount, top[1].amount);
        assertGe(top[1].amount, top[2].amount);

        // 2) 上榜金额与 deposits 记录一致
        for (uint256 i = 0; i < 3; ++i) {
            if (top[i].account != address(0)) {
                assertEq(bank.deposits(top[i].account), top[i].amount);
            }
        }

        // 3) 不在榜上的存款人金额不可能大于第三名
        for (uint256 i = 0; i < 4; ++i) {
            if (
                users[i] != top[0].account &&
                users[i] != top[1].account &&
                users[i] != top[2].account
            ) {
                assertLe(bank.deposits(users[i]), top[2].amount);
            }
        }
    }

    // ---------------------------------------------------------------
    // 管理员提现
    // ---------------------------------------------------------------

    function test_AdminIsDeployer() public view {
        assertEq(bank.admin(), address(this));
    }

    function test_WithdrawByAdmin() public {
        _deposit(alice, 1 ether);
        _deposit(bob, 2 ether);

        uint256 adminBefore = address(this).balance;
        bank.withdraw();

        assertEq(address(bank).balance, 0);
        assertEq(address(this).balance, adminBefore + 3 ether);
        assertEq(bank.totalDeposits(), 3 ether);
        assertEq(bank.deposits(alice), 1 ether);
        assertEq(bank.deposits(bob), 2 ether);
    }

    function test_WithdrawRevertsWhenNoFunds() public {
        vm.expectRevert(Bank.NoFunds.selector);
        bank.withdraw();
    }

    function test_WithdrawRevertsForNonAdmin() public {
        _deposit(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(Bank.NotAdmin.selector);
        bank.withdraw();
    }

    function test_TransferAdmin() public {
        bank.transferAdmin(alice);
        assertEq(bank.admin(), alice);

        // 原管理员（本测试合约）已失去权限
        vm.expectRevert(Bank.NotAdmin.selector);
        bank.transferAdmin(bob);

        // 新管理员 alice 可以继续转移
        vm.prank(alice);
        bank.transferAdmin(bob);
        assertEq(bank.admin(), bob);
    }

    function test_TransferAdminValidation() public {
        vm.expectRevert(Bank.ZeroAddress.selector);
        bank.transferAdmin(address(0));

        vm.expectRevert(Bank.IdenticalAdmin.selector);
        bank.transferAdmin(address(this));

        vm.prank(alice);
        vm.expectRevert(Bank.NotAdmin.selector);
        bank.transferAdmin(alice);
    }
}
