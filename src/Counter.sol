// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract Counter {
    uint256 public number1;
    function setNumber(uint256 newNumber) public {
        number1 = newNumber;
    }
    function increment() public {
        number1++;
    }
    function addNumber(uint256 number) public {
        number1 = number1 + number;
    }
}
