// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {BYOSTrampoline} from "../../src/contracts/BYOSTrampoline.sol";
import {Test} from "forge-std/Test.sol";

contract Target {
    uint256 public value;

    function setValue(uint256 newValue) external payable {
        value = newValue;
    }
}

contract BYOSTrampolineTest is Test {
    BYOSTrampoline trampoline;
    Target target;
    address owner;
    address user;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        vm.prank(owner);
        trampoline = new BYOSTrampoline();
        target = new Target();
    }

    function test_should_set_owner_on_deploy() public view {
        assertEq(trampoline.owner(), owner);
    }

    function test_should_execute_call() public {
        bytes memory data = abi.encodeCall(Target.setValue, (42));
        vm.prank(owner);
        trampoline.execute(address(target), 0, data);
        assertEq(target.value(), 42);
    }

    function test_should_forward_value() public {
        vm.deal(address(trampoline), 1 ether);
        bytes memory data = abi.encodeCall(Target.setValue, (42));
        vm.prank(owner);
        trampoline.execute(address(target), 1 ether, data);
        assertEq(address(target).balance, 1 ether);
    }

    function test_revert_if_non_owner_executes() public {
        bytes memory data = abi.encodeCall(Target.setValue, (42));
        vm.prank(user);
        vm.expectRevert(BYOSTrampoline.OnlyOwner.selector);
        trampoline.execute(address(target), 0, data);
    }

    function test_should_accept_eth() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool success,) = address(trampoline).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(trampoline).balance, 1 ether);
    }
}
