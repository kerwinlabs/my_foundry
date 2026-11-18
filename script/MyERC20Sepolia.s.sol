// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {MyERC20} from "../src/MyERC20.sol";

/// @notice 在 Sepolia 测试网部署 MyERC20
/// @dev 不继承 BaseScript，部署账号由命令行手动指定。
/// 用法:
///   forge script script/MyERC20Sepolia.s.sol:MyERC20SepoliaScript \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
/// 也可以改用 keystore 账号（会交互式输入密码）:
///   forge script script/MyERC20Sepolia.s.sol:MyERC20SepoliaScript \
///     --rpc-url $SEPOLIA_RPC_URL --account <account-name> --broadcast --verify
contract MyERC20SepoliaScript is Script {
    function run() public returns (MyERC20 token) {
        // 部署账号由 --private-key / --account 指定；
        // 不传参数时 forge 使用命令行给出的默认 sender 广播。
        console.log("chainId : %s", block.chainid);

        vm.startBroadcast();
        token = new MyERC20("MyToken", "MTK");
        vm.stopBroadcast();

        console.log("MyERC20 deployed at %s", address(token));

        // 保存合约地址到 deployments/MyERC20_<chainId>.json
        _saveContract("MyERC20", address(token));
    }

    /// @notice 把合约地址写入 deployments/<name>_<chainId>.json
    function _saveContract(string memory name, address addr) private {
        string memory finalJson = vm.serializeAddress("key", "address", addr);
        vm.writeJson(
            finalJson,
            string.concat("deployments/", name, "_", vm.toString(block.chainid), ".json")
        );
    }
}
