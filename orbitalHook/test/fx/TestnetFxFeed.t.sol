// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {TestnetFxFeed} from "../../script/mocks/TestnetFxFeed.sol";

/// @notice The Arc testnet mirror of Chainlink EUR / USD. The hook trusts it
///         exactly as it trusts a Chainlink proxy, so it must never hold a
///         round a real feed could not: non-positive answers, unset or future
///         timestamps, or rounds that go backwards.
contract TestnetFxFeedTest is Test {
    address constant SOURCE = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;
    uint256 constant T0 = 1_789_000_000;

    // A real Ethereum mainnet round (2026-09-11).
    uint80 constant ROUND = 92233720368547762439;
    int256 constant ANSWER = 115_954_500;
    uint256 constant AT = 1_789_150_907;

    TestnetFxFeed feed;
    address owner = makeAddr("owner");

    function setUp() public {
        vm.warp(AT + 60);
        feed = new TestnetFxFeed(8, "EUR / USD", 1, SOURCE, owner);
    }

    function test_describes_itself_and_its_source() public view {
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "EUR / USD");
        assertEq(feed.sourceChainId(), 1);
        assertEq(feed.sourceFeed(), SOURCE);
        assertEq(feed.owner(), owner);
    }

    function test_reads_as_a_feed_with_no_rounds_before_the_first_push() public view {
        (uint80 r, int256 a, uint256 s, uint256 u, uint80 ar) = feed.latestRoundData();
        assertEq(r, 0);
        assertEq(a, 0);
        assertEq(s, 0);
        assertEq(u, 0);
        assertEq(ar, 0);
    }

    function test_mirrors_a_round_field_for_field() public {
        vm.expectEmit(true, false, false, true, address(feed));
        emit TestnetFxFeed.RoundMirrored(ROUND, ANSWER, AT);
        vm.prank(owner);
        feed.push(ROUND, ANSWER, AT - 17, AT);

        (uint80 r, int256 a, uint256 s, uint256 u, uint80 ar) = feed.latestRoundData();
        assertEq(r, ROUND, "round id");
        assertEq(a, ANSWER, "answer");
        assertEq(s, AT - 17, "startedAt");
        assertEq(u, AT, "updatedAt");
        assertEq(ar, ROUND, "answeredInRound");
    }

    function test_only_the_owner_can_push() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TestnetFxFeed.NotOwner.selector, stranger));
        feed.push(ROUND, ANSWER, AT, AT);
    }

    function test_rejects_a_non_positive_answer() public {
        int256[2] memory bad = [int256(0), -1];
        for (uint256 k; k < bad.length; ++k) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(TestnetFxFeed.InvalidAnswer.selector, bad[k]));
            feed.push(ROUND, bad[k], AT, AT);
        }
    }

    function test_rejects_impossible_timestamps() public {
        uint256 future = vm.getBlockTimestamp() + 1;
        uint256[3][3] memory bad = [
            [uint256(0), 0, 0], // unset
            [future, future, 0], // ahead of the chain
            [AT + 1, AT, 0] // started after it was updated
        ];
        for (uint256 k; k < bad.length; ++k) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(TestnetFxFeed.InvalidTimestamps.selector, bad[k][0], bad[k][1]));
            feed.push(ROUND, ANSWER, bad[k][0], bad[k][1]);
        }
    }

    /// @notice A replayed or older round would let the owner roll the price
    ///         back while keeping it "fresh"; both keys must move forward.
    function test_rounds_only_move_forward() public {
        vm.startPrank(owner);
        feed.push(ROUND, ANSWER, AT, AT);

        vm.expectRevert(abi.encodeWithSelector(TestnetFxFeed.RoundNotNewer.selector, ROUND, AT + 1));
        feed.push(ROUND, ANSWER, AT + 1, AT + 1); // same round id

        vm.expectRevert(abi.encodeWithSelector(TestnetFxFeed.RoundNotNewer.selector, ROUND + 1, AT));
        feed.push(ROUND + 1, ANSWER, AT, AT); // same timestamp

        feed.push(ROUND + 1, ANSWER + 1, AT + 1, AT + 1);
        vm.stopPrank();
        (, int256 a,,,) = feed.latestRoundData();
        assertEq(a, ANSWER + 1);
    }

    function test_ownership_transfers_to_a_syncing_key() public {
        address syncer = makeAddr("syncer");
        vm.prank(owner);
        feed.transferOwnership(syncer);
        assertEq(feed.owner(), syncer);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TestnetFxFeed.NotOwner.selector, owner));
        feed.push(ROUND, ANSWER, AT, AT);

        vm.prank(syncer);
        feed.push(ROUND, ANSWER, AT, AT);

        vm.prank(syncer);
        vm.expectRevert(TestnetFxFeed.ZeroOwner.selector);
        feed.transferOwnership(address(0));
    }

    function test_rejects_a_zero_owner() public {
        vm.expectRevert(TestnetFxFeed.ZeroOwner.selector);
        new TestnetFxFeed(8, "EUR / USD", 1, SOURCE, address(0));
    }
}
