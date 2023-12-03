// SPDX-License-Identifier: proprietary
pragma solidity ^0.8.7;

import "forge-std/Test.sol";
import "./TokenRewardsTreasury_FOR_TEST.sol";

contract TokenRewardsTreasuryTest is Test {
    TokenRewardsTreasury_UNSAFE_FOR_TESTING private treasury;

    receive() payable external {}

    function setUp() public {
        treasury = new TokenRewardsTreasury_UNSAFE_FOR_TESTING();
        treasury.initialize(address(this));
    }

    function test_valid() external {
        uint256 initial = 200000000000000000;

        treasury.send{value: initial}();
        assertEq(address(treasury).balance, initial);
        assertEq(treasury.available(address(0)), initial);
        assertEq(treasury.totalPendingPayment(address(this), address(0)), initial);

        treasury.addPayee(vm.addr(2), 490);
    }
}