// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ItpStakingV1 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    // Events
    event Deposit(
        address caller,
        uint256 tokenId,
        uint256 amount,
        uint256 rewards,
        uint256 lockTime,
        uint256 unlockTime
    );
    event Withdraw(address caller, uint256 amount);
    event EarlyWithdraw(address caller, uint256 amount, uint256 penaltyAmount);
    event ExtendLock(
        address caller,
        uint256 amount,
        uint256 rewards,
        uint256 lockTime,
        uint256 unlockTime
    );
    event DepositRewards(
        address caller,
        uint256 amount,
        uint256 totalRewards,
        uint256 rewardsLeft
    );
    event WithdrawRewards(
        address caller,
        uint256 amount,
        uint256 totalRewards,
        uint256 rewardsLeft
    );
    event WithdrawPenalty(address caller, uint256 amount, uint256 totalPenalty);
    event SetRewardsRatePerLockMultiplierBps(
        address caller,
        uint256[] rewardsRatePerLockMultiplierBps
    );
    event SetPenaltyRateBps(address caller, uint256 bps);
    event BurnPenalty(
        address caller,
        uint256 amount,
        uint256 totalPenalty,
        uint256 totalBurned
    );
    event ConvertPenaltyIntoRewards(
        address caller,
        uint256 amount,
        uint256 totalPenalty,
        uint256 rewardsLeft
    );

    // Errors
    error InvalidAmount(uint256 amount);
    error InvalidEarlyWithdraw(uint256 unlockTime);
    error InvalidLockExtension(uint256 lockDuration);
    error InvalidLockMultiplier(uint256 lockMultiplier);
    error InsufficientRewards(uint256 rewardsLeft);
    error InsufficientPenalty(uint256 penalty);
    error InvalidUnlockTime(
        uint256 tokenId,
        uint256 amount,
        uint256 unlockTime
    );
    error InvalidTokenId(uint256 tokenId);
    error InvalidBps(uint256 bps);
    error InvalidRewardsRatePerLockMultiplierBpsLength(uint256 length);
    error InvalidRewardsRatePerLockMultiplierBpsOrder(uint256[] rewardsBps);
    error InvalidLockDuration(uint256 maxDuration, uint256 duration);

    // Storage

    uint8 public constant MAX_LOCK_MULTIPLIER = 4;
    uint256 public constant MAX_BASE_LOCK_DURATION = 365 days;
    uint256 public constant MAX_PENALTY_RATE_BPS = 2000;
    uint256 public constant MAX_REWARDS_RATE_BPS = 10000;

    uint256 private _tokenId;

    IERC20 public immutable stakedToken;
    uint256 public immutable lockDuration;
    uint256 public immutable maxLockDuration;
    uint256 public immutable rewardsRatePerLockMultiplierBpsLength;
    uint256[] public rewardsRatePerLockMultiplierBps; // Each entry corresponds to the Bps to be applied for a lock multiplier
    uint256 public penaltyRateBps = 2000; //20%
    uint256 public rewardsLeft;
    uint256 public totalRewards;
    uint256 public totalStaked;
    uint256 public totalPenalty;
    uint256 public totalPenaltyBurned;

    // Mapping (user => tokenIds) to keep pool related information for each user and tokenIds
    mapping(address => EnumerableSet.UintSet) private _stakes;

    // Mapping (tokenId => StakeInfo) to keep pool related information for each tokenId
    mapping(uint256 => StakeInfo) private _stakeInfo;

    // Struct to represent a staked position
    struct StakeInfo {
        uint256 tokenId;
        uint256 depositAmount;
        uint256 rewardsAmount;
        uint256 lockTime;
        uint256 unlockTime;
    }

    /**
     * @dev Initializes the contract by setting the owner, staked token, lock duration, and rewards rates.
     * @param initialOwner Address of the initial owner.
     * @param token Address of the ERC20 token to be staked.
     * @param lockTimeDuration Base duration for the lock period.
     * @param initialRewardsRatePerLockMultiplierBps Initial rewards rates for lock multipliers.
     */
    constructor(
        address initialOwner,
        IERC20 token,
        uint256 lockTimeDuration,
        uint256[] memory initialRewardsRatePerLockMultiplierBps
    ) Ownable(initialOwner) {
        _validateLockDuration(lockTimeDuration);
        _validateRewardsRatePerLockMultiplierBps(
            initialRewardsRatePerLockMultiplierBps
        );

        stakedToken = token;
        lockDuration = lockTimeDuration;
        rewardsRatePerLockMultiplierBps = initialRewardsRatePerLockMultiplierBps;
        rewardsRatePerLockMultiplierBpsLength = initialRewardsRatePerLockMultiplierBps
            .length;
        maxLockDuration =
            rewardsRatePerLockMultiplierBpsLength *
            lockDuration;
    }

    /**
     * @dev Returns the total staked balance (including rewards) of a user.
     * @param account Address of the user.
     * @return Total staked balance (including rewards) of the user.
     */
    function stakedBalanceOf(address account) external view returns (uint256) {
        uint256 length = _stakes[account].length();
        uint256 totalBalance;

        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = _stakes[account].at(i);
            totalBalance += _stakeInfoBalanceOf(tokenId);
        }

        return totalBalance;
    }

    /**
     * @dev Returns the staking information of a user.
     * @param account Address of the user.
     * @return stakeInfo Array of StakeInfo representing the user's stakes.
     */
    function getStakeInfo(
        address account
    ) external view returns (StakeInfo[] memory stakeInfo) {
        uint256 length = _stakes[account].length();
        stakeInfo = new StakeInfo[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = _stakes[account].at(i);
            stakeInfo[i] = _stakeInfo[tokenId];
        }
    }

    /**
     * @dev Returns the vault information.
     */
    function getVaultInfo()
        external
        view
        returns (
            uint256 _totalStaked,
            uint256 _totalRewards,
            uint256 _totalRewardsLeft,
            uint256 _totalPenalty,
            uint256 _totalPenaltyBurned,
            uint256[] memory _rewardsRatePerLockMultiplierBps,
            uint256 _penaltyRateBps
        )
    {
        _totalStaked = totalStaked;
        _totalRewards = totalRewards;
        _totalRewardsLeft = rewardsLeft;
        _totalPenalty = totalPenalty;
        _totalPenaltyBurned = totalPenaltyBurned;
        _rewardsRatePerLockMultiplierBps = rewardsRatePerLockMultiplierBps;
        _penaltyRateBps = penaltyRateBps;
    }

    /**
     * @dev Returns the rewards rate per lock multiplier in basis points.
     * @return Array of rewards rate per lock multiplier in basis points.
     */
    function getRewardsRatePerLockMultiplierBps()
        external
        view
        returns (uint256[] memory)
    {
        return rewardsRatePerLockMultiplierBps;
    }

    /**
     * @dev Allows a user to deposit tokens and stake them for rewards.
     * @param amount Amount of tokens to be deposited.
     * @param lockMultiplier Multiplier for the lock duration.
     */
    function deposit(
        uint256 amount,
        uint256 lockMultiplier
    ) external nonReentrant {
        _validateAmount(amount);
        _validateLockMultiplier(lockMultiplier);

        uint256 rewardAmountToPay = _calculateRewards(amount, lockMultiplier);

        _validateRewards(rewardAmountToPay);

        stakedToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 tokenId = ++_tokenId;
        uint256 unlockTime = block.timestamp +
            _calculateLockDuration(lockMultiplier);

        _stakes[msg.sender].add(tokenId);
        _stakeInfo[tokenId] = StakeInfo(
            tokenId,
            amount,
            rewardAmountToPay,
            block.timestamp,
            unlockTime
        );

        rewardsLeft -= rewardAmountToPay;
        totalStaked += amount + rewardAmountToPay;

        emit Deposit(
            msg.sender,
            tokenId,
            amount,
            rewardAmountToPay,
            block.timestamp,
            unlockTime
        );
    }

    /**
     * @dev Allows a user to withdraw their staked tokens after the lock period.
     * @param tokenIds Array of token IDs to be withdrawn.
     */
    function withdraw(uint256[] memory tokenIds) external nonReentrant {
        uint256 length = tokenIds.length;
        uint256 totalAmount;

        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = tokenIds[i];

            _validateUserTokenId(msg.sender, tokenId);
            _validateUnlockTime(tokenId);

            totalAmount += _stakeInfoBalanceOf(tokenId);

            delete _stakeInfo[tokenId];
            _stakes[msg.sender].remove(tokenId);
        }

        totalStaked -= totalAmount;
        stakedToken.safeTransfer(msg.sender, totalAmount);

        emit Withdraw(msg.sender, totalAmount);
    }

    /**
     * @dev Allows early withdrawal of staked tokens with a penalty.
     * @param tokenId Token ID to be withdrawn early.
     */
    function earlyWithdraw(uint256 tokenId) external nonReentrant {
        _validateUserTokenId(msg.sender, tokenId);
        _validateEarlyWithdraw(tokenId);

        uint256 penaltyAmount = _calculatePenalty(
            _stakeInfo[tokenId].depositAmount,
            _stakeInfo[tokenId].lockTime,
            _stakeInfo[tokenId].unlockTime,
            block.timestamp
        );

        uint256 totalAmountToWithdraw = _stakeInfo[tokenId].depositAmount -
            penaltyAmount;

        totalPenalty += penaltyAmount;
        rewardsLeft += _stakeInfo[tokenId].rewardsAmount;
        totalStaked -= _stakeInfoBalanceOf(tokenId);

        delete _stakeInfo[tokenId];
        _stakes[msg.sender].remove(tokenId);

        stakedToken.safeTransfer(msg.sender, totalAmountToWithdraw);

        emit EarlyWithdraw(msg.sender, totalAmountToWithdraw, penaltyAmount);
    }

    /**
     * @dev Extends the lock period of a staked token and adds additional rewards.
     * @param tokenId Token ID to be extended.
     * @param lockMultiplier New lock multiplier.
     */
    function extendLock(uint256 tokenId, uint256 lockMultiplier) external {
        _validateUserTokenId(msg.sender, tokenId);
        _validateLockMultiplier(lockMultiplier);

        uint256 amount = _stakeInfoBalanceOf(tokenId);
        uint256 rewardAmountToPay = _calculateRewards(amount, lockMultiplier);

        _validateRewards(rewardAmountToPay);

        uint256 lockExtensionDuration = _calculateLockDuration(lockMultiplier);
        if (_stakeInfo[tokenId].unlockTime > block.timestamp) {
            _validateLockExtension(
                _stakeInfo[tokenId].unlockTime,
                lockExtensionDuration
            );
            _stakeInfo[tokenId].unlockTime += lockExtensionDuration;
        } else {
            // Reset the lockTime for unlocked stakes
            _stakeInfo[tokenId].lockTime = block.timestamp;
            _stakeInfo[tokenId].unlockTime =
                block.timestamp +
                lockExtensionDuration;
        }

        _stakeInfo[tokenId].rewardsAmount += rewardAmountToPay;

        rewardsLeft -= rewardAmountToPay;
        totalStaked += rewardAmountToPay;

        emit ExtendLock(
            msg.sender,
            amount,
            rewardAmountToPay,
            _stakeInfo[tokenId].lockTime,
            _stakeInfo[tokenId].unlockTime
        );
    }

    // onlyOwner
    function depositRewards(uint256 amount) external nonReentrant onlyOwner {
        _validateAmount(amount);

        stakedToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardsLeft += amount;
        totalRewards += amount;

        emit DepositRewards(msg.sender, amount, totalRewards, rewardsLeft);
    }

    function withdrawRewards(uint256 amount) external nonReentrant onlyOwner {
        _validateAmount(amount);
        _validateRewards(amount);

        stakedToken.safeTransfer(msg.sender, amount);
        rewardsLeft -= amount;
        totalRewards -= amount;

        emit WithdrawRewards(msg.sender, amount, totalRewards, rewardsLeft);
    }

    function withdrawPenalty(uint256 amount) external nonReentrant onlyOwner {
        _validateAmount(amount);
        _validatePenalty(amount);

        stakedToken.safeTransfer(msg.sender, amount);
        totalPenalty -= amount;

        emit WithdrawPenalty(msg.sender, amount, totalPenalty);
    }

    function setRewardsRatePerLockMultiplierBps(
        uint256[] memory _rewardsRatePerLockMultiplierBps
    ) external onlyOwner {
        _validateRewardsRatePerLockMultiplierBps(
            _rewardsRatePerLockMultiplierBps
        );

        rewardsRatePerLockMultiplierBps = _rewardsRatePerLockMultiplierBps;

        emit SetRewardsRatePerLockMultiplierBps(
            msg.sender,
            rewardsRatePerLockMultiplierBps
        );
    }

    function setPenaltyRateBps(uint256 bps) external onlyOwner {
        _validatePenaltyRateBps(bps);

        penaltyRateBps = bps;

        emit SetPenaltyRateBps(msg.sender, penaltyRateBps);
    }

    function burnPenalty(uint256 amount) external nonReentrant onlyOwner {
        _validateAmount(amount);
        _validatePenalty(amount);

        ERC20Burnable(address(stakedToken)).burn(amount);

        totalPenaltyBurned += amount;
        totalPenalty -= amount;

        emit BurnPenalty(msg.sender, amount, totalPenalty, totalPenaltyBurned);
    }

    /**
     * @dev Converts penalties collected from early withdrawals into rewards.
     * @param amount Amount of penalties to be converted into rewards.
     */
    function convertPenaltyIntoRewards(uint256 amount) external onlyOwner {
        _validateAmount(amount);
        _validatePenalty(amount);

        totalPenalty -= amount;
        rewardsLeft += amount;

        emit ConvertPenaltyIntoRewards(
            msg.sender,
            amount,
            totalPenalty,
            rewardsLeft
        );
    }

    // Helpers

    /**
     * @dev Returns the balance of a stake.
     * @param tokenId Token ID of the stake.
     * @return Balance of the stake including rewards.
     */
    function _stakeInfoBalanceOf(
        uint256 tokenId
    ) private view returns (uint256) {
        return
            _stakeInfo[tokenId].depositAmount +
            _stakeInfo[tokenId].rewardsAmount;
    }

    /**
     * @dev Calculates the lock duration for a given lock multiplier.
     * @param lockMultiplier Lock multiplier.
     * @return Calculated lock duration.
     */
    function _calculateLockDuration(
        uint256 lockMultiplier
    ) private view returns (uint256) {
        return lockMultiplier * lockDuration;
    }

    /**
     * @dev Calculates the linearly decreasing with time penalty for early withdrawal.
     * @param amount Amount of tokens.
     * @param lockTime Lock time.
     * @param unlockTime Unlock time.
     * @param currentTime Current time.
     * @return Calculated penalty amount.
     */
    function _calculatePenalty(
        uint256 amount,
        uint256 lockTime,
        uint256 unlockTime,
        uint256 currentTime
    ) private view returns (uint256) {
        if (currentTime >= unlockTime) {
            return 0;
        }

        if (lockTime >= unlockTime) {
            return 0;
        }

        if (penaltyRateBps == 0) {
            return 0;
        }

        uint256 numerator = unlockTime - currentTime;
        uint256 denominator = unlockTime - lockTime;
        uint256 unlockTimeDelta = (numerator * 10000) / denominator;
        uint256 penalty = (penaltyRateBps * unlockTimeDelta) / 10000;

        return (amount * penalty) / 10000;
    }

    /**
     * @dev Calculates the rewards for a given amount and lock multiplier.
     * @param amount Amount of tokens.
     * @param lockMultiplier Lock multiplier.
     * @notice lockMultiplier - 1 must be in rewardsRatePerLockMultiplierBps bounds
     * @return Calculated rewards.
     */
    function _calculateRewards(
        uint256 amount,
        uint256 lockMultiplier
    ) private view returns (uint256) {
        // Apply the rewards rate corresponding to the lock multiplier
        uint256 rewardsRateBps = rewardsRatePerLockMultiplierBps[
            lockMultiplier - 1
        ];

        // Compound rewards
        uint256 totalAmount = amount;
        uint256 currentRewards;
        uint256 totalCalculatedRewards;
        for (uint256 i = 0; i < lockMultiplier; i++) {
            currentRewards = (totalAmount * rewardsRateBps) / 10000;
            totalAmount += currentRewards;
            totalCalculatedRewards += currentRewards;
        }

        return totalCalculatedRewards;
    }

    // Validators
    function _validateAmount(uint256 amount) private pure {
        if (amount == 0) {
            revert InvalidAmount(amount);
        }
    }

    function _validatePenaltyRateBps(uint256 bps) private pure {
        if (bps > MAX_PENALTY_RATE_BPS) {
            revert InvalidBps(bps);
        }
    }

    function _validateRewardsRatePerLockMultiplierBps(
        uint256[] memory _rewardsRatePerLockMultiplierBps
    ) private view {
        uint256 inputLength = _rewardsRatePerLockMultiplierBps.length;

        // Once rewardsRatePerLockMultiplierBpsLength is set in constructor, subsequent bps updates must match the same length
        if (
            (inputLength == 0 ||
                inputLength >
                MAX_LOCK_MULTIPLIER) ||
            (rewardsRatePerLockMultiplierBpsLength != 0 &&
                inputLength !=
                rewardsRatePerLockMultiplierBpsLength)
        ) {
            revert InvalidRewardsRatePerLockMultiplierBpsLength(
                inputLength
            );
        }

        for (uint256 i = 0; i < inputLength; i++) {
            // Bps must be in ascending order
            if (
                i != 0 &&
                _rewardsRatePerLockMultiplierBps[i - 1] >=
                _rewardsRatePerLockMultiplierBps[i]
            ) {
                revert InvalidRewardsRatePerLockMultiplierBpsOrder(
                    _rewardsRatePerLockMultiplierBps
                );
            }

            _validateRewardsRateBps(_rewardsRatePerLockMultiplierBps[i]);
        }
    }

    function _validateRewardsRateBps(uint256 bps) private pure {
        if (bps > MAX_REWARDS_RATE_BPS) {
            revert InvalidBps(bps);
        }
    }

    function _validateEarlyWithdraw(uint256 tokenId) private view {
        if (_stakeInfo[tokenId].unlockTime <= block.timestamp) {
            revert InvalidEarlyWithdraw(_stakeInfo[tokenId].unlockTime);
        }
    }

    function _validateLockDuration(uint256 duration) private pure {
        if (duration > MAX_BASE_LOCK_DURATION) {
            revert InvalidLockDuration(MAX_BASE_LOCK_DURATION, duration);
        }
    }

    function _validateLockExtension(
        uint256 unlockTime,
        uint256 lockExtension
    ) private view {
        uint256 lockDurationLeft = unlockTime - block.timestamp;
        uint256 newLockDuration = lockDurationLeft + lockExtension;

        if (newLockDuration > maxLockDuration) {
            revert InvalidLockExtension(newLockDuration);
        }
    }

    function _validateLockMultiplier(uint256 lockMultiplier) private view {
        if (
            lockMultiplier < 1 ||
            lockMultiplier > rewardsRatePerLockMultiplierBpsLength
        ) {
            revert InvalidLockMultiplier(lockMultiplier);
        }
    }

    function _validateUserTokenId(address user, uint256 tokenId) private view {
        if (_stakes[user].contains(tokenId) == false) {
            revert InvalidTokenId(tokenId);
        }
    }

    function _validateRewards(uint256 amount) private view {
        if (amount > rewardsLeft) {
            revert InsufficientRewards(rewardsLeft);
        }
    }

    function _validatePenalty(uint256 amount) private view {
        if (amount > totalPenalty) {
            revert InsufficientPenalty(totalPenalty);
        }
    }

    function _validateUnlockTime(uint256 tokenId) private view {
        if (_stakeInfo[tokenId].unlockTime > block.timestamp) {
            revert InvalidUnlockTime(
                tokenId,
                _stakeInfo[tokenId].depositAmount,
                _stakeInfo[tokenId].unlockTime
            );
        }
    }
}
