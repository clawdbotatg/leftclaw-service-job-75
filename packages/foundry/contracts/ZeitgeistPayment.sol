// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal Chainlink AggregatorV3Interface (defined inline to avoid extra dependency).
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

/**
 * @title ZeitgeistPayment
 * @notice Accepts payment in ETH or CLAWD to query a zeitgeist AI analysis of a cultural group.
 *         ETH price is set via Chainlink ETH/USD oracle so the user always pays the equivalent of
 *         a fixed USD amount ($0.25). CLAWD price is owner-configurable (no oracle).
 * @dev Owner is set at deployment via Ownable2Step; ownership transfer is two-step.
 */
contract ZeitgeistPayment is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Target USD price per query, scaled to 18 decimals: $0.25 == 25 * 10**16.
    uint256 public constant USD_PRICE_18 = 25 * 1e16;

    /// @notice Maximum allowed staleness of the Chainlink price feed.
    /// @dev Base ETH/USD heartbeat is ~20 minutes; 25 minutes gives a small buffer.
    uint256 public constant MAX_PRICE_STALENESS = 25 minutes;

    /// @notice L2 sequencer grace period after restart before price feeds are trusted again.
    uint256 public constant GRACE_PERIOD = 1 hours;

    /// @notice Minimum allowed ETH/USD answer ($100, 8 decimals). Any price at or below this is
    ///         treated as a malfunctioning feed (ETH has never been below $100).
    int256 public constant MIN_ANSWER = 100e8;

    /// @notice Maximum allowed ETH/USD answer ($1,000,000, 8 decimals). Any price at or above this
    ///         is treated as a malfunctioning feed (very generous upper bound).
    int256 public constant MAX_ANSWER = 1_000_000e8;

    // ---------------------------------------------------------------------
    // Immutable state
    // ---------------------------------------------------------------------

    /// @notice Chainlink ETH/USD price feed.
    AggregatorV3Interface public immutable priceFeed;

    /// @notice Chainlink L2 sequencer uptime feed (Base).
    AggregatorV3Interface public immutable sequencerFeed;

    /// @notice CLAWD token contract.
    IERC20 public immutable clawd;

    // ---------------------------------------------------------------------
    // Mutable state
    // ---------------------------------------------------------------------

    /// @notice Owner-configurable CLAWD token amount required per query.
    uint256 public queryPriceCLAWD;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /**
     * @notice Emitted when a user successfully pays for a zeitgeist query.
     * @param user The address that paid for the query.
     * @param groupName The cultural group name being queried.
     * @param amount Amount paid (wei for ETH queries, CLAWD base units for CLAWD queries).
     * @param isClawd True if paid in CLAWD, false if paid in ETH.
     */
    event QueryPaid(address indexed user, string groupName, uint256 amount, bool isClawd);

    /// @notice Emitted when the owner updates the CLAWD per-query price.
    event QueryPriceCLAWDUpdated(uint256 oldPrice, uint256 newPrice);

    /// @notice Emitted when accumulated ETH is withdrawn by the owner.
    event WithdrawnETH(address indexed to, uint256 amount);

    /// @notice Emitted when accumulated CLAWD is withdrawn by the owner.
    event WithdrawnCLAWD(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error InvalidPriceFeed();
    error InvalidSequencerFeed();
    error InvalidClawdToken();
    error InvalidPrice();
    error StalePrice(uint256 updatedAt, uint256 nowAt);
    error SequencerDown();
    error SequencerGracePeriod(uint256 availableAt);
    error InsufficientETH(uint256 sent, uint256 required);
    error InsufficientCLAWD(uint256 sent, uint256 required);
    error RefundFailed();
    error WithdrawFailed();
    error NothingToWithdraw();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /**
     * @param _priceFeed Chainlink ETH/USD aggregator address.
     * @param _sequencerFeed Chainlink L2 sequencer uptime feed address (Base).
     * @param _clawd CLAWD ERC20 token address.
     * @param _initialOwner Address that will own the contract (passed to Ownable).
     * @param _initialQueryPriceCLAWD Initial CLAWD price per query (in CLAWD base units).
     */
    constructor(
        address _priceFeed,
        address _sequencerFeed,
        address _clawd,
        address _initialOwner,
        uint256 _initialQueryPriceCLAWD
    ) Ownable(_initialOwner) {
        if (_priceFeed == address(0)) revert InvalidPriceFeed();
        if (_sequencerFeed == address(0)) revert InvalidSequencerFeed();
        if (_clawd == address(0)) revert InvalidClawdToken();
        if (_initialQueryPriceCLAWD == 0) revert InvalidPrice();

        priceFeed = AggregatorV3Interface(_priceFeed);
        sequencerFeed = AggregatorV3Interface(_sequencerFeed);
        clawd = IERC20(_clawd);
        queryPriceCLAWD = _initialQueryPriceCLAWD;

        emit QueryPriceCLAWDUpdated(0, _initialQueryPriceCLAWD);
    }

    // ---------------------------------------------------------------------
    // External / public — user-facing query payment
    // ---------------------------------------------------------------------

    /**
     * @notice Pay in ETH for a zeitgeist query. ETH amount required is computed live from
     *         Chainlink ETH/USD so the user always pays the equivalent of `USD_PRICE_18`.
     *         Overpayment is refunded to the caller.
     * @param groupName The cultural group name being queried (emitted in the event).
     */
    function queryETH(string calldata groupName) external payable nonReentrant {
        uint256 required = ethRequired();
        if (msg.value < required) revert InsufficientETH(msg.value, required);

        uint256 refund = msg.value - required;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{ value: refund }("");
            if (!ok) revert RefundFailed();
        }

        emit QueryPaid(msg.sender, groupName, required, false);
    }

    /**
     * @notice Pay in CLAWD for a zeitgeist query. Caller must have approved this contract
     *         for at least `amount` CLAWD beforehand.
     * @param groupName The cultural group name being queried (emitted in the event).
     * @param amount Amount of CLAWD (base units) the user wishes to pay; must be at least
     *               `queryPriceCLAWD`. The full `amount` is transferred from the user.
     */
    function queryCLAWD(string calldata groupName, uint256 amount) external {
        uint256 required = queryPriceCLAWD;
        if (amount < required) revert InsufficientCLAWD(amount, required);

        clawd.safeTransferFrom(msg.sender, address(this), amount);

        emit QueryPaid(msg.sender, groupName, amount, true);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /**
     * @notice Computes the ETH amount (in wei) currently required for one query, equal to
     *         `USD_PRICE_18` worth of ETH at the latest Chainlink price.
     * @dev Reverts if the L2 sequencer is down or within its grace period, if the price is
     *      non-positive, stale, out of bounds, or from an incomplete round.
     */
    function ethRequired() public view returns (uint256) {
        // L2 sequencer uptime check (Base is OP-stack L2).
        // sequencerAnswer: 0 = sequencer up, 1 = sequencer down.
        (, int256 sequencerAnswer, uint256 sequencerStartedAt, , ) = sequencerFeed.latestRoundData();
        if (sequencerAnswer != 0) revert SequencerDown();
        if (block.timestamp - sequencerStartedAt < GRACE_PERIOD) {
            revert SequencerGracePeriod(sequencerStartedAt + GRACE_PERIOD);
        }

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (answer <= MIN_ANSWER || answer >= MAX_ANSWER) revert InvalidPriceFeed();
        if (answeredInRound < roundId) revert StalePrice(updatedAt, block.timestamp);
        if (updatedAt == 0 || block.timestamp - updatedAt > MAX_PRICE_STALENESS) {
            revert StalePrice(updatedAt, block.timestamp);
        }

        // Chainlink ETH/USD has 8 decimals on Base.
        // priceUsd_18 = answer * 10^(18 - feedDecimals)
        uint8 feedDecimals = priceFeed.decimals();
        uint256 priceUsd18;
        if (feedDecimals <= 18) {
            priceUsd18 = uint256(answer) * (10 ** (18 - feedDecimals));
        } else {
            priceUsd18 = uint256(answer) / (10 ** (feedDecimals - 18));
        }

        // wei needed = USD_PRICE_18 * 1e18 / priceUsd18
        return (USD_PRICE_18 * 1e18) / priceUsd18;
    }

    // ---------------------------------------------------------------------
    // Owner — configuration & withdrawals
    // ---------------------------------------------------------------------

    /**
     * @notice Owner sets the CLAWD price required per query.
     * @param newPrice New CLAWD amount (base units). Must be non-zero.
     */
    function setQueryPriceCLAWD(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert InvalidPrice();
        uint256 old = queryPriceCLAWD;
        queryPriceCLAWD = newPrice;
        emit QueryPriceCLAWDUpdated(old, newPrice);
    }

    /**
     * @notice Withdraw all accumulated ETH and CLAWD to the owner.
     */
    function withdraw() external onlyOwner nonReentrant {
        _withdrawETH();
        _withdrawCLAWD();
    }

    /// @notice Withdraw all accumulated ETH to the owner.
    function withdrawETH() external onlyOwner nonReentrant {
        _withdrawETH();
    }

    /// @notice Withdraw all accumulated CLAWD to the owner.
    function withdrawCLAWD() external onlyOwner nonReentrant {
        _withdrawCLAWD();
    }

    // ---------------------------------------------------------------------
    // Internal — withdrawal helpers
    // ---------------------------------------------------------------------

    function _withdrawETH() internal {
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        address to = owner();
        (bool ok, ) = to.call{ value: bal }("");
        if (!ok) revert WithdrawFailed();
        emit WithdrawnETH(to, bal);
    }

    function _withdrawCLAWD() internal {
        uint256 bal = clawd.balanceOf(address(this));
        if (bal == 0) return;
        address to = owner();
        clawd.safeTransfer(to, bal);
        emit WithdrawnCLAWD(to, bal);
    }
}
