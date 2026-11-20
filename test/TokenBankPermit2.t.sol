// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CalledToken} from "../src/CalledToken.sol";
import {TokenBank} from "../src/TokenBank.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";

/// @notice 在 Sepolia fork 上测试 TokenBank.depositWithPermit2
///         （Uniswap Permit2 的 SignatureTransfer 离线签名存款）。
///         运行前确保 .env 里有 SEPOLIA_RPC_URL（对应 foundry.toml 的 rpc_endpoints.sepolia）：
///           forge test --match-contract TokenBankPermit2Test -vvv
contract TokenBankPermit2Test is Test {
    /// @dev Uniswap Permit2 的规范地址（CREATE2 部署，Sepolia 上也是这个地址）。
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Permit2 官方的类型哈希（见 Uniswap/permit2 仓库 src/libraries/PermitHash.sol）。
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");

    /// @dev 注意：链上结构体里没有 spender 字段，但签名类型字符串里有，
    ///      调用 Permit2 时 spender 取 msg.sender（即 TokenBank）。
    bytes32 internal constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant DEPOSIT_AMOUNT = 100e18;
    uint256 internal constant OWNER_BALANCE = 1_000e18;

    address internal owner;
    CalledToken internal token;
    TokenBank internal bank;

    function setUp() public {
        // 1. fork Sepolia：use canonical Permit2 deployment
        vm.createSelectFork(vm.rpcUrl("sepolia"));
        assertGt(PERMIT2.code.length, 0, "Permit2 not deployed at canonical address");

        owner = vm.addr(OWNER_PK);

        // 2. 在 fork 上部署测试代币和 TokenBank
        token = new CalledToken("Permit2 Test Token", "P2T", OWNER_BALANCE);
        token.transfer(owner, OWNER_BALANCE);
        bank = new TokenBank(token);

        // 3. owner 只需要对 Permit2 合约 approve 一次（不是对 Bank）
        vm.prank(owner);
        token.approve(PERMIT2, type(uint256).max);
    }

    /// @dev 构造 PermitTransferFrom（链上结构体，不含 spender）。
    function _permit(uint256 nonce, uint256 deadline)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({
                token: address(token),
                amount: DEPOSIT_AMOUNT
            }),
            nonce: nonce,
            deadline: deadline
        });
    }

    /// @dev 模拟 owner 离线签名 Permit2 的 PermitTransferFrom。
    ///      digest = keccak256("\x19\x01" || Permit2.DOMAIN_SEPARATOR || structHash)
    ///      domain 为 { name: "Permit2", chainId, verifyingContract }（没有 version）。
    ///      spender 取 address(bank)，因为真正调用 permitTransferFrom 的是 TokenBank。
    function _signPermit2(uint256 signerPk, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 tokenPermissionsHash = keccak256(
            abi.encode(TOKEN_PERMISSIONS_TYPEHASH, address(token), DEPOSIT_AMOUNT)
        );
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TRANSFER_FROM_TYPEHASH,
                tokenPermissionsHash,
                address(bank), // spender
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                ISignatureTransfer(PERMIT2).DOMAIN_SEPARATOR(),
                structHash
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_Permit2AddressIsCanonical() public view {
        assertEq(bank.PERMIT2(), PERMIT2);
    }

    function test_DepositWithPermit2() public {
        uint256 deadline = block.timestamp + 1 days;
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(0, deadline);
        bytes memory signature = _signPermit2(OWNER_PK, 0, deadline);

        // 任意地址（这里用 relayer）都可以提交，存款记到 owner 名下
        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        bank.depositWithPermit2(permit, owner, signature);

        assertEq(bank.deposits(owner), DEPOSIT_AMOUNT, "deposit not credited to owner");
        assertEq(bank.totalDeposits(), DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(owner), OWNER_BALANCE - DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(address(bank)), DEPOSIT_AMOUNT);
    }

    function test_DepositWithPermit2TwiceWithDifferentNonce() public {
        uint256 deadline = block.timestamp + 1 days;

        vm.startPrank(owner);
        bank.depositWithPermit2(_permit(0, deadline), owner, _signPermit2(OWNER_PK, 0, deadline));
        bank.depositWithPermit2(_permit(1, deadline), owner, _signPermit2(OWNER_PK, 1, deadline));
        vm.stopPrank();

        assertEq(bank.deposits(owner), DEPOSIT_AMOUNT * 2);
        assertEq(bank.totalDeposits(), DEPOSIT_AMOUNT * 2);
        assertEq(token.balanceOf(owner), OWNER_BALANCE - DEPOSIT_AMOUNT * 2);
    }

    function test_RevertsWhenSignatureIsNotFromOwner() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 otherPk = 0xB0B;
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(0, deadline);
        bytes memory signature = _signPermit2(otherPk, 0, deadline);

        vm.prank(owner);
        vm.expectRevert(); // Permit2: InvalidSignature
        bank.depositWithPermit2(permit, owner, signature);
    }

    function test_RevertsWhenTokenDoesNotMatch() public {
        uint256 deadline = block.timestamp + 1 days;
        CalledToken otherToken = new CalledToken("Other Token", "OTH", 1e18);

        ISignatureTransfer.PermitTransferFrom memory permit = _permit(0, deadline);
        permit.permitted.token = address(otherToken);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(TokenBank.IncorrectToken.selector, address(otherToken))
        );
        bank.depositWithPermit2(permit, owner, _signPermit2(OWNER_PK, 0, deadline));
    }

    function test_RevertsWhenExpired() public {
        uint256 deadline = block.timestamp - 1;
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(0, deadline);
        bytes memory signature = _signPermit2(OWNER_PK, 0, deadline);

        vm.prank(owner);
        vm.expectRevert(); // Permit2: SignatureExpired
        bank.depositWithPermit2(permit, owner, signature);
    }

    function test_RevertsWhenNonceIsReused() public {
        uint256 deadline = block.timestamp + 1 days;
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(0, deadline);
        bytes memory signature = _signPermit2(OWNER_PK, 0, deadline);

        vm.startPrank(owner);
        bank.depositWithPermit2(permit, owner, signature);

        // 同一个 (owner, nonce) 只能使用一次
        vm.expectRevert(); // Permit2: InvalidNonce
        bank.depositWithPermit2(permit, owner, signature);
        vm.stopPrank();
    }
}
