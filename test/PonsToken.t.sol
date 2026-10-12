// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PonsToken} from "../src/PonsToken.sol";
import {DeployPonsToken} from "../script/DeployPonsToken.s.sol";

/// @dev Deploys the token from a contract so the "deployer" in these tests is a contract address,
/// as it is at launch (the factory), rather than the test contract itself.
contract DeployerProbe {
    PonsToken public token;

    function deploy() external returns (PonsToken) {
        token = new PonsToken();
        return token;
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function call(bytes calldata data) external returns (bool ok) {
        (ok,) = address(token).call(data);
    }
}

contract PonsTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    DeployerProbe deployer;
    PonsToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        deployer = new DeployerProbe();
        token = deployer.deploy();
    }

    // ── Metadata and supply ───────────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(token.name(), "Pons");
        assertEq(token.symbol(), "PONS");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.balanceOf(address(deployer)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new PonsToken();
    }

    function test_constructorTakesNoArgumentsAndCallsNoContract() public {
        // Deploying on a fresh address space with no other code around must succeed: the launch
        // runs the constructor on an empty chain.
        PonsToken fresh = new PonsToken();
        assertEq(fresh.balanceOf(address(this)), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_eachDeploymentIsIndependent() public {
        PonsToken second = new PonsToken();
        assertEq(second.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(deployer)), SUPPLY);
    }

    // ── Deploy script ─────────────────────────────────────────────────────────

    function test_deployScriptDeploysTokenToCaller() public {
        DeployPonsToken script = new DeployPonsToken();
        PonsToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
        assertEq(deployed.name(), "Pons");
        assertEq(deployed.symbol(), "PONS");
    }

    // ── transfer ──────────────────────────────────────────────────────────────

    function test_transferMovesExactAmount() public {
        uint256 amount = 123_456 ether;
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(deployer), alice, amount);
        assertTrue(deployer.send(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(deployer)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        assertTrue(deployer.send(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(deployer)), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        assertTrue(token.transfer(alice, 10 ether));
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_holderCanForwardWhatItReceived() public {
        deployer.send(alice, 5 ether);
        vm.prank(alice);
        token.transfer(bob, 5 ether);
        vm.prank(bob);
        token.transfer(carol, 2 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 3 ether);
        assertEq(token.balanceOf(carol), 2 ether);
    }

    function test_revert_transferInsufficientBalance() public {
        deployer.send(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PonsToken.ERC20InsufficientBalance.selector, alice, 1 ether, 1 ether + 1)
        );
        token.transfer(bob, 1 ether + 1);
    }

    function test_revert_transferFromEmptyAccount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_revert_transferToZeroAddress() public {
        deployer.send(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ── approve / allowance ───────────────────────────────────────────────────

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 7 ether);
        assertTrue(token.approve(bob, 7 ether));
        assertEq(token.allowance(alice, bob), 7 ether);
    }

    function test_approveOverwritesAllowance() public {
        vm.startPrank(alice);
        token.approve(bob, 7 ether);
        token.approve(bob, 2 ether);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 2 ether);
    }

    function test_approveDoesNotRequireBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, type(uint256).max));
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_revert_approveZeroSpender() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ── transferFrom ──────────────────────────────────────────────────────────

    function test_transferFromSpendsAllowance() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 6 ether);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 2 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, carol, 4 ether);
        assertTrue(token.transferFrom(alice, carol, 4 ether));

        assertEq(token.balanceOf(alice), 6 ether);
        assertEq(token.balanceOf(carol), 4 ether);
        assertEq(token.allowance(alice, bob), 2 ether);
    }

    function test_transferFromInfiniteAllowanceIsNotDecremented() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 10 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(carol), 10 ether);
    }

    function test_transferFromSelfStillNeedsAllowance() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_revert_transferFromInsufficientAllowance() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, bob, 1 ether, 2 ether));
        token.transferFrom(alice, carol, 2 ether);
    }

    function test_revert_transferFromWithoutAllowance() public {
        deployer.send(alice, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    function test_revert_transferFromInsufficientBalanceEvenWithAllowance() public {
        deployer.send(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientBalance.selector, alice, 1 ether, 5 ether));
        token.transferFrom(alice, carol, 5 ether);
    }

    function test_revert_transferFromToZeroAddress() public {
        deployer.send(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 1 ether);
    }

    function test_deployerCannotPullFromHolderWithoutAllowance() public {
        deployer.send(alice, 1 ether);
        bytes memory data = abi.encodeWithSelector(PonsToken.transferFrom.selector, alice, address(deployer), 1);
        assertFalse(deployer.call(data), "deployer pulled without allowance");
        assertEq(token.balanceOf(alice), 1 ether);
    }

    // ── No privileged surface ─────────────────────────────────────────────────

    function test_noMintOrAdminSelectorExists() public {
        address attacker = makeAddr("attacker");
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "owner()",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            // The deployer, the most plausibly trusted address, fares no better.
            assertFalse(deployer.call(data), signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noFreezeOrSeizeSelectorAffectsHolder() public {
        deployer.send(alice, 1 ether);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            assertFalse(deployer.call(abi.encodeWithSignature(signatures[i], alice, true)), signatures[i]);
        }
        assertEq(token.balanceOf(alice), 1 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0.5 ether));
        assertEq(token.balanceOf(bob), 0.5 ether);
    }

    function test_fallbackAndReceiveAbsent() public {
        (bool ok,) = address(token).call{value: 0}("");
        assertFalse(ok, "token accepted an empty call");
        vm.deal(address(this), 1 ether);
        (ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ── Launch-shaped flows ───────────────────────────────────────────────────

    /// @dev The factory's flows: 10% to the distributor, 88% to the pool, 2% to the requester.
    /// Every one must arrive whole and the supply must be unchanged afterwards.
    function test_launchSharesArriveWhole() public {
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address requester = makeAddr("requester");
        uint256 swarm = (SUPPLY * 1000) / 10_000;
        uint256 poolShare = (SUPPLY * 8800) / 10_000;
        uint256 remainder = SUPPLY - swarm - poolShare;

        assertTrue(deployer.send(distributor, swarm));
        assertTrue(deployer.send(pool, poolShare));
        assertTrue(deployer.send(requester, remainder));

        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(pool), poolShare);
        assertEq(token.balanceOf(requester), remainder);
        assertEq(token.balanceOf(address(deployer)), 0);
        assertEq(token.totalSupply(), SUPPLY);

        // A claim from the distributor arrives whole too.
        vm.prank(distributor);
        assertTrue(token.transfer(alice, swarm));
        assertEq(token.balanceOf(alice), swarm);
        assertEq(token.balanceOf(distributor), 0);
    }

    // ── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(deployer));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(deployer.send(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(deployer)), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(deployer)), token.totalSupply());
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        deployer.send(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientBalance.selector, alice, held, amount));
        token.transfer(bob, amount);
    }

    function testFuzz_transferFromWithinAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, allowed);
        deployer.send(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, amount));
        assertEq(token.balanceOf(carol), amount);
        assertEq(token.balanceOf(alice), SUPPLY - amount);
        assertEq(token.allowance(alice, bob), allowed - amount);
    }

    function testFuzz_transferFromAboveAllowanceReverts(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        amount = bound(amount, allowed + 1, SUPPLY);
        deployer.send(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, bob, allowed, amount));
        token.transferFrom(alice, carol, amount);
    }
}
