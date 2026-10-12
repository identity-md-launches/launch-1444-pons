// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PonsToken} from "../src/PonsToken.sol";

/// @title Handler that drives PonsToken with random, bounded call sequences
/// @notice The handler deploys the token itself, so it is the "deployer" that receives the supply,
/// exactly as the factory does at launch. It is also one of the actors, so the supply can leave it.
/// Every mutating entry point of the token is reachable both through a clamped handler (inputs
/// shaped so the call succeeds) and through a raw handler (inputs unrestricted, the outcome checked
/// against an ERC-20 model). Ghost variables mirror what the token should hold after every call.
contract PonsHandler is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    PonsToken public token;

    // ── Actors ────────────────────────────────────────────────────────────────

    address[] public actors;
    address[] public sinks;
    /// @dev Every address that has ever held a balance or appeared in an allowance pair.
    address[] public touched;
    mapping(address => bool) private _isTouched;

    // ── Ghost state ───────────────────────────────────────────────────────────

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    /// @dev Running totals, so a reviewer can see which paths a campaign exercised.
    uint256 public countTransfer;
    uint256 public countTransferReverted;
    uint256 public countApprove;
    uint256 public countTransferFrom;
    uint256 public countTransferFromReverted;
    uint256 public countUnknownSelector;
    uint256 public countEtherRejected;

    constructor() {
        token = new PonsToken();

        actors.push(address(this)); // the deployer, holding the whole supply at the start
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));

        // Recipients that never send: the token itself (a plain ERC-20 lets anyone send to it, and
        // nothing can move it out again) and a few addresses that only ever receive or get approved.
        sinks.push(address(token));
        sinks.push(makeAddr("sink-1"));
        sinks.push(makeAddr("sink-2"));
        sinks.push(makeAddr("sink-3"));

        _touch(address(this));
        ghostBalance[address(this)] = SUPPLY;
    }

    // ── Views for the invariants ──────────────────────────────────────────────

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    // ── Clamped handlers: inputs shaped so the call must succeed ──────────────

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        _transfer(from, to, amount);
    }

    /// @dev Full-amount stress variant: the sender's entire balance leaves in one call.
    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _holder(toSeed), ghostBalance[from]);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    /// @dev Boundary stress variant: the unlimited allowance and the values beside it.
    function approveNearMax(uint256 ownerSeed, uint256 spenderSeed, uint256 below) external {
        below = bound(below, 0, 2);
        _approve(_actor(ownerSeed), _actor(spenderSeed), type(uint256).max - below);
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 cap = ghostBalance[owner];
        if (allowed != type(uint256).max && allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        _transferFrom(spender, owner, _holder(toSeed), amount);
    }

    /// @dev Full-amount stress variant: spend the whole allowance or the whole balance, whichever is smaller.
    function transferFromAll(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 amount = ghostBalance[owner];
        if (allowed != type(uint256).max && allowed < amount) amount = allowed;
        _transferFrom(spender, owner, _holder(toSeed), amount);
    }

    // ── Raw handlers: unrestricted inputs, outcome checked against the model ──

    function transferRaw(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        _transfer(_actor(fromSeed), _recipient(toSeed), amount);
    }

    function transferFromRaw(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        _transferFrom(_actor(spenderSeed), _actor(ownerSeed), _recipient(toSeed), amount);
    }

    function approveRaw(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        _approve(_actor(ownerSeed), _recipient(spenderSeed), amount);
    }

    /// @dev Adversarial: any selector the ABI does not declare must revert and change nothing.
    function callUnknownSelector(uint256 callerSeed, bytes4 selector, bytes calldata args) external {
        while (_isKnownSelector(selector)) {
            selector = bytes4(uint32(selector) + 1);
        }
        vm.prank(_actor(callerSeed));
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok, "token accepted an undeclared selector");
        countUnknownSelector++;
    }

    /// @dev Adversarial: the token must not accept ether through any path.
    function sendEther(uint256 callerSeed, uint256 amount, bool withData) external {
        amount = bound(amount, 1, 100 ether);
        address caller = _actor(callerSeed);
        vm.deal(caller, amount);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: amount}(withData ? abi.encodeWithSignature("deposit()") : bytes(""));
        assertFalse(ok, "token accepted ether");
        countEtherRejected++;
    }

    // ── Model ─────────────────────────────────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) private {
        bytes memory expectedError;
        if (to == address(0)) {
            expectedError = abi.encodeWithSelector(PonsToken.ERC20InvalidReceiver.selector, address(0));
        } else if (ghostBalance[from] < amount) {
            expectedError =
                abi.encodeWithSelector(PonsToken.ERC20InsufficientBalance.selector, from, ghostBalance[from], amount);
        }

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(PonsToken.transfer, (to, amount)));

        if (expectedError.length == 0) {
            assertTrue(ok, "transfer the model accepts reverted");
            assertTrue(abi.decode(ret, (bool)), "transfer returned false");
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            _touch(to);
            countTransfer++;
        } else {
            assertFalse(ok, "transfer the model rejects succeeded");
            assertEq(ret, expectedError, "transfer reverted with the wrong error");
            countTransferReverted++;
        }
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(PonsToken.approve, (spender, amount)));
        if (spender == address(0)) {
            assertFalse(ok, "approve of the zero spender succeeded");
            assertEq(ret, abi.encodeWithSelector(PonsToken.ERC20InvalidSpender.selector, address(0)));
            return;
        }
        assertTrue(ok, "approve reverted");
        assertTrue(abi.decode(ret, (bool)), "approve returned false");
        ghostAllowance[owner][spender] = amount;
        _touch(owner);
        _touch(spender);
        countApprove++;
    }

    function _transferFrom(address spender, address owner, address to, uint256 amount) private {
        uint256 allowed = ghostAllowance[owner][spender];
        bytes memory expectedError;
        if (allowed != type(uint256).max && allowed < amount) {
            expectedError =
                abi.encodeWithSelector(PonsToken.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        } else if (to == address(0)) {
            expectedError = abi.encodeWithSelector(PonsToken.ERC20InvalidReceiver.selector, address(0));
        } else if (ghostBalance[owner] < amount) {
            expectedError =
                abi.encodeWithSelector(PonsToken.ERC20InsufficientBalance.selector, owner, ghostBalance[owner], amount);
        }

        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(PonsToken.transferFrom, (owner, to, amount)));

        if (expectedError.length == 0) {
            assertTrue(ok, "transferFrom the model accepts reverted");
            assertTrue(abi.decode(ret, (bool)), "transferFrom returned false");
            if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
            _touch(to);
            countTransferFrom++;
        } else {
            assertFalse(ok, "transferFrom the model rejects succeeded");
            assertEq(ret, expectedError, "transferFrom reverted with the wrong error");
            countTransferFromReverted++;
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev An actor or a sink: any address that may legitimately receive.
    function _holder(uint256 seed) private view returns (address) {
        uint256 pick = seed % (actors.length + sinks.length);
        return pick < actors.length ? actors[pick] : sinks[pick - actors.length];
    }

    /// @dev A holder or the zero address, so the raw handlers reach the zero-address rejections.
    function _recipient(uint256 seed) private view returns (address) {
        uint256 pick = seed % (actors.length + sinks.length + 1);
        if (pick == actors.length + sinks.length) return address(0);
        return _holder(pick);
    }

    function _touch(address account) private {
        if (!_isTouched[account]) {
            _isTouched[account] = true;
            touched.push(account);
        }
    }

    function _isKnownSelector(bytes4 selector) private pure returns (bool) {
        return selector == bytes4(keccak256("name()")) || selector == bytes4(keccak256("symbol()"))
            || selector == bytes4(keccak256("decimals()")) || selector == bytes4(keccak256("TOTAL_SUPPLY()"))
            || selector == PonsToken.totalSupply.selector || selector == PonsToken.balanceOf.selector
            || selector == PonsToken.allowance.selector || selector == PonsToken.transfer.selector
            || selector == PonsToken.approve.selector || selector == PonsToken.transferFrom.selector;
    }
}

/// @title Invariants of Pons over random call sequences
/// @dev Every handler either succeeds and updates the ghosts, or is expected to revert and asserts
/// the exact error. `fail-on-revert` is on, so a handler that reverts for any other reason fails
/// the run rather than being skipped silently.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 32
/// forge-config: default.invariant.fail-on-revert = true
contract PonsTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    PonsHandler handler;
    PonsToken token;

    function setUp() public {
        handler = new PonsHandler();
        token = handler.token();
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = PonsHandler.transfer.selector;
        selectors[1] = PonsHandler.transferAll.selector;
        selectors[2] = PonsHandler.approve.selector;
        selectors[3] = PonsHandler.approveNearMax.selector;
        selectors[4] = PonsHandler.transferFrom.selector;
        selectors[5] = PonsHandler.transferFromAll.selector;
        selectors[6] = PonsHandler.transferRaw.selector;
        selectors[7] = PonsHandler.transferFromRaw.selector;
        selectors[8] = PonsHandler.approveRaw.selector;
        selectors[9] = PonsHandler.callUnknownSelector.selector;
        selectors[10] = PonsHandler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice The supply is fixed: no sequence of calls mints or burns.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// @notice Conservation: what every holder has adds up to exactly the supply.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.touched(i));
        }
        assertEq(sum, SUPPLY, "sum of balances drifted from the supply");
    }

    /// @notice Every balance is exactly what the sequence of accepted transfers says it should be.
    function invariant_balancesMatchGhosts() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            address account = handler.touched(i);
            assertEq(token.balanceOf(account), handler.ghostBalance(account), "balance differs from ghost");
        }
    }

    /// @notice Every allowance is exactly what the approvals and spends say, and max stays max.
    function invariant_allowancesMatchGhosts() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.touched(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.touched(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance differs from ghost"
                );
            }
        }
    }

    /// @notice Nothing is ever credited to the zero address.
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @notice The token cannot be made to hold ether.
    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0);
    }

    /// @notice No holder can hold more than exists, whatever the sequence.
    function invariant_noBalanceExceedsSupply() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            assertLe(token.balanceOf(handler.touched(i)), SUPPLY);
        }
    }

    /// @notice The metadata is immutable: no call sequence can change it.
    function invariant_metadataIsConstant() public view {
        assertEq(token.name(), "Pons");
        assertEq(token.symbol(), "PONS");
        assertEq(token.decimals(), 18);
    }
}
