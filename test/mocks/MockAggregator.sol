// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockAggregator
 * @notice A Chainlink AggregatorV3 you can drive into every failure mode the
 *         money path has to survive.
 *
 * @dev `DECISIONS.md §1` picked option A — dollar prices converted at pay time
 *      through the BNB/USD feed. That makes the feed the single most dangerous
 *      external dependency in the whole contract set, so every one of these
 *      switches has a test:
 *        - `setAnswer(0)` / a negative answer     -> non-positive answer
 *        - `setAnsweredInRound(< roundId)`        -> incomplete round
 *        - `setUpdatedAt(0)`                      -> no timestamp
 *        - a stale `updatedAt`                    -> older than maxOracleAge
 *        - a huge / tiny answer                   -> outside the sanity band
 *      MintDrop must REVERT on every one. A clamp is a wrong price presented as
 *      a right one.
 */
contract MockAggregator {
    uint8 public decimals;
    string public description = "BNB / USD";
    uint256 public version = 4;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    bool public readReverts;

    constructor(uint8 d, int256 initialAnswer) {
        decimals = d;
        _roundId = 1;
        _answer = initialAnswer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = 1;
    }

    // ─── Drivers ──────────────────────────────────────────────────────────

    /// @notice Publish a fresh, healthy round at `a`.
    function setAnswer(int256 a) external {
        _roundId += 1;
        _answer = a;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
    }

    /// @notice Publish an arbitrary round, healthy or not.
    function setRound(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function setUpdatedAt(uint256 t) external {
        _updatedAt = t;
    }

    function setAnsweredInRound(uint80 r) external {
        _answeredInRound = r;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setReadReverts(bool b) external {
        readReverts = b;
    }

    // ─── AggregatorV3Interface ────────────────────────────────────────────

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        if (readReverts) revert("MockAggregator: feed down");
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        if (readReverts) revert("MockAggregator: feed down");
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
