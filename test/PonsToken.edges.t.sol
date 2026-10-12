// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PonsToken} from "../src/PonsToken.sol";

/// @dev Deploys arbitrary creation code through CREATE2, the way the launch factory deploys the token.
contract Create2Probe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "create2 failed");
    }
}

/// @title Edge cases and properties the main suite does not pin
/// @notice Inputs the implementation might not have considered: zero values on every path, the zero
/// address as a sender, the finite/infinite allowance boundary, cumulative allowance spending,
/// round trips, undeclared selectors, and deployment through CREATE2 as the factory performs it.
/// forge-config: default.fuzz.runs = 1000
contract PonsTokenEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant MAX = type(uint256).max;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    PonsToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        // The test contract deploys, so it holds the supply and hands it out as the factory would.
        token = new PonsToken();
    }

    // ── Deployment as the factory performs it ────────────────────────────────

    function test_create2DeploymentMintsToTheCreatingContract() public {
        Create2Probe factory = new Create2Probe();
        bytes memory code = type(PonsToken).creationCode;
        bytes32 salt = bytes32(uint256(7));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );

        vm.expectEmit(true, true, true, true, predicted);
        emit Transfer(address(0), address(factory), SUPPLY);
        address deployed = factory.deploy(code, salt);

        assertEq(deployed, predicted, "CREATE2 address differs from the prediction");
        PonsToken launched = PonsToken(deployed);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY, "the factory does not hold the whole supply");
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.decimals(), 18);
    }

    function test_creationCodeTakesNoConstructorArguments() public {
        // Appending arguments the constructor does not declare must not change what is minted or
        // to whom: the manifest declares `constructorArgs: []`.
        Create2Probe factory = new Create2Probe();
        bytes memory bare = type(PonsToken).creationCode;
        bytes memory withArgs = abi.encodePacked(bare, abi.encode(alice, uint256(5)));
        address plain = factory.deploy(bare, bytes32(0));
        address decorated = factory.deploy(withArgs, bytes32(0));
        assertEq(PonsToken(plain).balanceOf(address(factory)), SUPPLY);
        assertEq(PonsToken(decorated).balanceOf(address(factory)), SUPPLY);
        assertEq(PonsToken(decorated).balanceOf(alice), 0, "an appended argument was read as a recipient");
        assertEq(plain.code, decorated.code, "runtime depends on bytes the constructor should ignore");
    }

    function test_supplyEqualsOneBillionTimesTenToTheDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
    }

    // ── Zero values on every path ─────────────────────────────────────────────

    function test_transferZeroFromEmptyAccountEmits() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 0);
        assertTrue(token.transfer(bob, 0));
    }

    function test_transferZeroToZeroAddressStillReverts() public {
        // The receiver check runs before the amount matters: even 0 to the zero address is refused.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_transferFromZeroWithNoAllowanceSucceeds() public {
        // Spending 0 of a 0 allowance is within the allowance; ERC-20 permits a zero-value transfer.
        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 0);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, carol, 0);
        assertTrue(token.transferFrom(alice, carol, 0));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(carol), 0);
    }

    function test_approveZeroResetsAllowanceAndEmits() public {
        vm.startPrank(alice);
        token.approve(bob, 5 ether);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 0);
        assertTrue(token.approve(bob, 0));
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    function test_approveZeroSpenderWithZeroValueStillReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
    }

    // ── The zero address as a sender ──────────────────────────────────────────

    function test_transferFromZeroAddressWithZeroValueRevertsInvalidSender() public {
        // The zero address can never hold an allowance above 0, so only a zero-value pull reaches
        // the sender check; it must still be refused.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
    }

    function test_transferFromZeroAddressWithValueRevertsOnAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), alice, 1);
        assertEq(token.balanceOf(address(0)), 0);
    }

    // ── Allowance boundary: finite just below max, infinite at max ────────────

    function test_allowanceOfMaxMinusOneIsFiniteAndDecremented() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, MAX - 1);
        vm.prank(bob);
        token.transferFrom(alice, carol, 3 ether);
        assertEq(token.allowance(alice, bob), MAX - 1 - 3 ether, "max-1 was treated as infinite");
    }

    function test_infiniteAllowanceEmitsNoApprovalOnSpend() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, MAX);

        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(alice, carol, 4 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "expected only the Transfer event");
        assertEq(logs[0].topics[0], Transfer.selector);
        assertEq(token.allowance(alice, bob), MAX);
    }

    function test_infiniteAllowanceDoesNotBypassBalance() public {
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, MAX);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PonsToken.ERC20InsufficientBalance.selector, alice, 1 ether, 1 ether + 1)
        );
        token.transferFrom(alice, carol, 1 ether + 1);
    }

    function test_infiniteAllowanceCanBeRevoked() public {
        token.transfer(alice, 1 ether);
        vm.startPrank(alice);
        token.approve(bob, MAX);
        token.approve(bob, 0);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    // ── Cumulative allowance accounting ───────────────────────────────────────

    function test_exactAllowanceSpendLeavesZeroThenOneWeiReverts() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 4 ether);
        vm.startPrank(bob);
        token.transferFrom(alice, carol, 4 ether);
        assertEq(token.allowance(alice, bob), 0);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(carol), 4 ether);
    }

    function testFuzz_allowanceIsSpentCumulatively(uint256 allowed, uint256 first, uint256 second, uint256 excess)
        public
    {
        allowed = bound(allowed, 0, SUPPLY - 1);
        first = bound(first, 0, allowed);
        second = bound(second, 0, allowed - first);
        uint256 remaining = allowed - first - second;
        excess = bound(excess, remaining + 1, SUPPLY);

        token.transfer(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowed);

        vm.startPrank(bob);
        token.transferFrom(alice, carol, first);
        token.transferFrom(alice, carol, second);
        assertEq(token.allowance(alice, bob), remaining);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, bob, remaining, excess));
        token.transferFrom(alice, carol, excess);
        vm.stopPrank();

        assertEq(token.balanceOf(carol), first + second);
        assertEq(token.balanceOf(alice), SUPPLY - first - second);
    }

    function test_selfApprovalLetsOwnerTransferFromItself() public {
        token.transfer(alice, 10 ether);
        vm.startPrank(alice);
        token.approve(alice, 6 ether);
        assertTrue(token.transferFrom(alice, bob, 6 ether));
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 6 ether);
        assertEq(token.allowance(alice, alice), 0);
    }

    function test_allowanceSurvivesOwnerSpendingItsBalance() public {
        token.transfer(alice, 2 ether);
        vm.startPrank(alice);
        token.approve(bob, 2 ether);
        token.transfer(carol, 2 ether);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 2 ether, "allowance should not depend on balance");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    function test_allowanceIsPerSpender() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        assertEq(token.allowance(alice, carol), 0);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, carol, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    // ── The deployer has no special power once it has paid out ───────────────

    function test_deployerIsAnOrdinaryHolderAfterPayingOut() public {
        token.transfer(alice, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.transfer(bob, 1);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_transferOfMaxUintRevertsWithExactValues() public {
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, MAX));
        token.transfer(alice, MAX);
    }

    // ── Tokens sent to the token contract itself ──────────────────────────────

    /// @dev A plain ERC-20 accepts its own address as a receiver and has no path to move the tokens
    /// out again. That is standard behaviour and the README documents the absence of a recovery
    /// path; what this pins is that the supply still adds up and nobody else is affected.
    function test_transferToTokenContractIsAcceptedAndCounted() public {
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(address(token)), SUPPLY);
        // Nothing lets a third party pull them out.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, alice, 0, 1 ether));
        token.transferFrom(address(token), alice, 1 ether);
    }

    // ── Undeclared selectors and ether ────────────────────────────────────────

    function testFuzz_undeclaredSelectorRevertsAndChangesNothing(bytes4 selector, bytes calldata args, uint256 seed)
        public
    {
        while (_isDeclared(selector)) {
            selector = bytes4(uint32(selector) + 1);
        }
        token.transfer(alice, 1 ether);
        address caller = seed % 2 == 0 ? alice : address(this);
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok, "undeclared selector was accepted");
        assertEq(ret.length, 0, "an undeclared selector returned data");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1 ether);
    }

    function testFuzz_declaredMutatorsRejectEther(uint96 value, uint8 which) public {
        value = uint96(bound(value, 1, type(uint96).max));
        vm.deal(address(this), value);
        bytes memory data;
        which = uint8(bound(which, 0, 2));
        if (which == 0) data = abi.encodeCall(PonsToken.transfer, (alice, 0));
        else if (which == 1) data = abi.encodeCall(PonsToken.approve, (alice, 0));
        else data = abi.encodeCall(PonsToken.transferFrom, (address(this), alice, 0));
        (bool ok,) = address(token).call{value: value}(data);
        assertFalse(ok, "a non-payable function accepted ether");
        assertEq(address(token).balance, 0);
    }

    // ── Properties ────────────────────────────────────────────────────────────

    function testFuzz_unknownAccountsHoldNothingAndAllowNothing(address a, address b) public view {
        vm.assume(a != address(this));
        assertEq(token.balanceOf(a), 0);
        assertEq(token.allowance(a, b), 0);
        assertEq(token.allowance(b, a), 0);
    }

    function testFuzz_transferRoundTripRestoresBalances(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        token.transfer(alice, held);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    function testFuzz_transferIsAdditive(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        token.transfer(alice, a);
        token.transfer(alice, b);
        assertEq(token.balanceOf(alice), a + b);
        assertEq(token.balanceOf(address(this)), SUPPLY - a - b);
    }

    function testFuzz_approveIsIdempotentAndLastWriteWins(uint256 first, uint256 second) public {
        vm.startPrank(alice);
        token.approve(bob, first);
        token.approve(bob, first);
        assertEq(token.allowance(alice, bob), first);
        token.approve(bob, second);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), second);
    }

    function testFuzz_approveNeverMovesBalances(uint256 amount, address spender) public {
        vm.assume(spender != address(0));
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        token.approve(spender, amount);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1 ether);
        uint256 expected = spender == alice ? 1 ether : spender == address(this) ? SUPPLY - 1 ether : 0;
        assertEq(token.balanceOf(spender), expected);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferNeverTouchesAllowances(uint256 allowed, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowed);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(carol, amount);
        assertEq(token.allowance(alice, bob), allowed);
    }

    function testFuzz_infiniteAllowanceStaysInfiniteAcrossSpends(uint256 n, uint256 each) public {
        n = bound(n, 1, 20);
        each = bound(each, 0, SUPPLY / n);
        token.transfer(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, MAX);
        for (uint256 i; i < n; ++i) {
            vm.prank(bob);
            token.transferFrom(alice, carol, each);
        }
        assertEq(token.allowance(alice, bob), MAX);
        assertEq(token.balanceOf(carol), n * each);
    }

    function testFuzz_selfTransferOfAnyHeldAmountIsNoOp(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        token.transfer(alice, held);
        vm.prank(alice);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), held);
    }

    function testFuzz_selfTransferAboveBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, MAX);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientBalance.selector, alice, held, amount));
        token.transfer(alice, amount);
    }

    function _isDeclared(bytes4 selector) private pure returns (bool) {
        return selector == bytes4(keccak256("name()")) || selector == bytes4(keccak256("symbol()"))
            || selector == bytes4(keccak256("decimals()")) || selector == bytes4(keccak256("TOTAL_SUPPLY()"))
            || selector == PonsToken.totalSupply.selector || selector == PonsToken.balanceOf.selector
            || selector == PonsToken.allowance.selector || selector == PonsToken.transfer.selector
            || selector == PonsToken.approve.selector || selector == PonsToken.transferFrom.selector;
    }
}
