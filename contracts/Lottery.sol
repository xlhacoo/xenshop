// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Import OpenZeppelin contracts and interfaces for ERC20, security, and access control.
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title XenNero Token Contract
/// @notice ERC20 token representing XenNero, minted exclusively by the Lottery contract.
contract XenNeroToken is ERC20, Ownable {
    // Address of the Lottery contract that is allowed to mint tokens.
    address public immutable lotteryContract;
    // Maximum total supply of XenNero tokens.
    uint256 public constant MAX_SUPPLY = 21_000_000 * 1e18;

    /// @notice Constructor that sets the token name, symbol, and the Lottery contract address.
    /// @param _lotteryContract The address of the Lottery contract.
    constructor(address _lotteryContract) ERC20("XenNero Token", "XNT") {
        require(_lotteryContract != address(0), "Invalid lottery contract address");
        lotteryContract = _lotteryContract;
    }

    /// @dev Modifier to restrict functions only to the Lottery contract.
    modifier onlyLottery() {
        require(msg.sender == lotteryContract, "Only lottery contract can mint");
        _;
    }

    /// @notice Mints new XenNero tokens.
    /// @param to The recipient address.
    /// @param amount The number of tokens to mint.
    function mint(address to, uint256 amount) external onlyLottery {
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        _mint(to, amount);
    }
}

/// @title Lottery Contract
/// @notice This contract enables users to place bets, win prizes, and earn XenNero tokens.
/// @dev The drawWinningNumber function uses on-chain randomness. Note that on-chain randomness
/// is not secure and it is recommended to use a randomness oracle (e.g. Chainlink VRF) in production.
contract Lottery is Pausable, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // External token interfaces.
    IERC20 public immutable xenToken;          // XEN token interface.
    XenNeroToken public immutable xenNeroToken;  // XenNero token instance.

    // Wallet designated for platform fees.
    address public platformWallet;

    // Configuration constants.
    uint256 public constant betCost = 10_000_000 * 1e18;      // Base cost per bet.
    uint256 public prizePerBet = 5200 * 1e18;                   // Prize amount for a winning bet.
    uint256 public consolationPrizePerBet = 20 * 1e18;          // Consolation prize for a near win.
    uint8 public constant maxMultiplier = 99;                 // Maximum betting multiplier.
    uint8 public constant maxNumbersPerBet = 100;              // Maximum numbers allowed per bet.
    uint16 public constant rolloverDepositPrizePoolRatio = 899; // Parts per thousand of sales returned to prize pool.
    uint256 public constant initialXenNeroReward = 100 * 1e18;  // Initial XenNero reward per bet.
    uint256 public constant halvingPeriod = 105_000;           // Period after which reward halves.
    uint256 public constant maxXenNeroSupply = 21_000_000 * 1e18; // Maximum XenNero token supply.
    uint256 public constant EXCHANGE_RATE = 1_000_000 * 1e18;   // Fixed exchange rate between XNT and XEN.

    // Lottery operational state variables.
    uint256 public totalBets;            // Total number of bets placed.
    uint256 public totalXenNeroMinted;   // Total XenNero tokens minted so far.
    uint256 public prizePool;            // Accumulated prize pool (in XenNero tokens).
    uint32 public currentPeriod = 1;     // Current betting period.

    uint256 public storedXenTokens;      // XEN tokens donated and held in contract.
    uint256 adminFeeXenTokens;           // Accumulated admin fees in XEN tokens.

    /// @notice Structure representing an individual bet placed by a user.
    /// @dev Bet records are stored per period in mappings.
    struct Bet {
        uint8 multiplier;     // The bet multiplier.
        uint8 flags;          // Bit flags (e.g. to indicate if the prize has been claimed).
        uint16[] numbers;     // Array of chosen numbers (each between 0 and 999 inclusive).
    }

    /// @notice Structure holding information for a lottery period.
    struct PeriodInfo {
        uint128 totalSales;   // Total sales (in XEN token value) for the period.
        uint16 winningNumber; // The drawn winning number.
        bool isDrawn;         // Indicates whether the winning number has been drawn.
    }

    /// @notice Structure tracking the progress of prize claims within a period, per user.
    struct PeriodProgress {
        uint64 processedIndex; // Index of bets that have been processed for claims.
        uint64 lastUpdate;     // Timestamp of the last claim update.
    }

    // Mappings for user bets and claim progress.
    mapping(address => mapping(uint256 => PeriodProgress)) private userPeriodProgress;
    mapping(uint256 => PeriodInfo) public periods;
    mapping(uint256 => mapping(address => Bet[])) public betsByPeriod;

    // Bit flag constant to indicate that a bet's prize has already been claimed.
    uint8 constant FLAG_PRIZE_CLAIMED = 1 << 1;

    // ============================
    // ======== Events ============
    // ============================
    event BetPlaced(address indexed user, uint256 indexed period, uint8 multiplier);
    event WinningNumberDrawn(uint256 period, uint16 winningNumber);
    event XNTExchangedForXEN(address indexed user, uint256 xntAmount, uint256 xenAmount);
    event PeriodChanged(uint256 newPeriod);
    event PlatformWalletChanged(address indexed oldWallet, address indexed newWallet);
    event PrizePoolDonated(address indexed donor, uint256 amount);
    event XENDonated(address indexed donor, uint256 amount);
    event PrizeClaimed(
        address indexed user,
        uint256 indexed period,
        uint256 amount,
        uint256 startIndex,
        uint256 endIndex,
        bool isCompleted
    );

    // ============================
    // ===== Constructor ==========
    // ============================
    /// @notice Initializes the Lottery contract.
    /// @param _xenTokenAddress Address of the XEN token contract.
    /// @param _platformWallet Address of the platform wallet.
    constructor(
        address _xenTokenAddress,
        address _platformWallet
    ) {
        require(_xenTokenAddress != address(0), "Invalid XEN token address");
        require(_platformWallet != address(0), "Invalid platform wallet address");

        xenToken = IERC20(_xenTokenAddress);
        xenNeroToken = new XenNeroToken(address(this));
        platformWallet = _platformWallet;
    }

    // ============================
    // ======= Modifiers ==========
    // ============================
    /// @notice Modifier to restrict function calls to either the contract owner or the platform wallet.
    modifier onlyAdmin() {
        require(isAdmin(msg.sender), "Not admin");
        _;
    }

    // ============================
    // ===== Administration =======
    // ============================
    /// @notice Checks whether an account is an administrator.
    /// @param account The address to check.
    /// @return True if the account is the owner or the platform wallet, false otherwise.
    function isAdmin(address account) public view returns (bool) {
        return account == owner() || account == platformWallet;
    }

    /// @notice Calculates the current XenNero reward per bet after applying any halvings.
    /// @return The current reward in XenNero tokens.
    function calculateXenNeroReward() internal view returns (uint256) {
        if (totalXenNeroMinted >= maxXenNeroSupply) {
            return 0;
        }
        uint256 halvings = totalBets / halvingPeriod;
        uint256 currentReward = initialXenNeroReward >> halvings; // Equivalent to dividing by 2^halvings.
        uint256 remainingXNT = maxXenNeroSupply - totalXenNeroMinted;
        return currentReward > remainingXNT ? remainingXNT : currentReward;
    }

    // ============================
    // ===== Token Donations ======
    // ============================
    /// @notice Allows users to donate XNT tokens to increase the prize pool.
    /// @param amount The amount of XNT tokens to donate.
    function donateToPrizePool(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        // Use SafeERC20 for safe transfer from the user.
        IERC20(address(xenNeroToken)).safeTransferFrom(msg.sender, address(this), amount);
        prizePool += amount;
        emit PrizePoolDonated(msg.sender, amount);
    }

    /// @notice Allows users to donate XEN tokens to the contract.
    /// @param amount The amount of XEN tokens to donate.
    function donateXEN(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        xenToken.safeTransferFrom(msg.sender, address(this), amount);
        storedXenTokens += amount;
        emit XENDonated(msg.sender, amount);
    }

    // ============================
    // ======= Betting Logic ======
    // ============================
    /// @notice Places a bet by selecting numbers and a multiplier.
    /// @param numbers Array of chosen numbers (each must be between 0 and 999 inclusive).
    /// @param multiplier The multiplier for the bet (must be between 1 and maxMultiplier inclusive).
    function placeBet(uint16[] calldata numbers, uint8 multiplier) external whenNotPaused {
        uint256 numNumbers = numbers.length;
        require(numNumbers > 0, "At least one number required");
        require(numNumbers <= maxNumbersPerBet, "Too many numbers");
        require(multiplier > 0 && multiplier <= maxMultiplier, "Invalid multiplier");

        // Ensure each number is within the valid range.
        for (uint256 i = 0; i < numNumbers; i++) {
            require(numbers[i] <= 999, "Numbers must be between 0 and 999");
        }

        // Calculate the total cost of the bet.
        uint256 totalCost = numNumbers * betCost * multiplier;
        xenToken.safeTransferFrom(msg.sender, address(this), totalCost);

        // Update period sales.
        PeriodInfo storage periodInfo = periods[currentPeriod];
        periodInfo.totalSales += uint128(totalCost);

        // Calculate and mint XenNero rewards.
        uint256 currentXenNeroReward = calculateXenNeroReward();
        uint256 totalReward = currentXenNeroReward * numNumbers * multiplier;
        if (totalXenNeroMinted + totalReward > maxXenNeroSupply) {
            totalReward = maxXenNeroSupply - totalXenNeroMinted;
        }
        if (totalReward > 0) {
            xenNeroToken.mint(address(this), totalReward);
            prizePool += totalReward;
            totalXenNeroMinted += totalReward;
        }
        unchecked {
            totalBets += numNumbers * multiplier;
        }

        // Record the bet.
        betsByPeriod[currentPeriod][msg.sender].push(
            Bet({
                multiplier: multiplier,
                flags: 0,
                numbers: numbers
            })
        );
        emit BetPlaced(msg.sender, currentPeriod, multiplier);
    }

    /// @notice Checks if a given three-digit number is a jackpot (i.e. all digits are identical).
    /// @param number The number to check.
    /// @return True if the number is a jackpot (e.g., 0, 111, 222, …, 999), otherwise false.
    function isJackpot(uint16 number) internal pure returns (bool) {
        // A jackpot number has all three identical digits and is divisible by 111.
        return number <= 999 && number % 111 == 0;
    }

    // ============================
    // ===== Winning Number Draw ========
    // ============================
    /// @notice Draws the winning number for the current period using on-chain randomness.
    /// @dev NOTE: On-chain randomness using block data.
    function drawWinningNumber() external onlyAdmin whenNotPaused {
        PeriodInfo storage periodInfo = periods[currentPeriod];
        require(!periodInfo.isDrawn, "Winning number already drawn");

        // Generate a pseudo-random number using the previous block hash, current timestamp, contract address,
        // current period, and caller. (This method is insecure for critical randomness.)
        uint256 randomHash = uint256(
            keccak256(
                abi.encodePacked(
                    blockhash(block.number - 1),
                    block.timestamp,
                    address(this),
                    currentPeriod,
                    msg.sender
                )
            )
        );

        uint16 winningNumber = uint16(randomHash % 1000);

        uint256 drawnPeriod = currentPeriod;
        periodInfo.winningNumber = winningNumber;
        periodInfo.isDrawn = true;

        uint256 totalSales = periodInfo.totalSales;
        uint256 prizeAddition = (totalSales * rolloverDepositPrizePoolRatio) / 1000;
        adminFeeXenTokens += totalSales - prizeAddition;
        storedXenTokens += prizeAddition;

        emit WinningNumberDrawn(drawnPeriod, winningNumber);
        unchecked {
            currentPeriod += 1;
        }
        emit PeriodChanged(currentPeriod);
    }

    /// @notice Allows the owner to withdraw accumulated fees in XEN tokens.
    function withdrawAdminFees() external onlyOwner nonReentrant {
        uint256 amount = adminFeeXenTokens;
        require(amount > 0, "No admin fees to withdraw");
        adminFeeXenTokens = 0;
        xenToken.safeTransfer(platformWallet, amount);
    }

    // ============================
    // ===== Prize Claiming =======
    // ============================
    /// @notice Allows a user to claim their winnings (both prizes and consolation rewards) for a specific period.
    /// @param period The lottery period to claim winnings for.
    /// @param batchSize The number of bet records to process in one batch.
    function claimWinnings(uint256 period, uint256 batchSize) external nonReentrant {
        require(batchSize > 0 && batchSize <= 100, "Invalid batch size");

        PeriodInfo storage periodInfo = periods[period];
        require(periodInfo.isDrawn, "Winning number not drawn yet");

        Bet[] storage userBets = betsByPeriod[period][msg.sender];
        uint256 userTotalBets = userBets.length;
        require(userTotalBets > 0, "No bets in this period");

        PeriodProgress storage progress = userPeriodProgress[msg.sender][period];
        uint256 startIndex = progress.processedIndex;
        require(startIndex < userTotalBets, "All bets processed");

        uint256 endIndex = startIndex + batchSize;
        if (endIndex > userTotalBets) {
            endIndex = userTotalBets;
        }

        // Cache state variables locally to reduce SLOAD operations.
        uint256 localPrizePerBet = prizePerBet;
        uint256 localConsolationPrizePerBet = consolationPrizePerBet;

        (uint256 totalWinnings, uint256 newProcessedIndex) = _processBatch(
            userBets,
            periodInfo.winningNumber,
            startIndex,
            endIndex,
            localPrizePerBet,
            localConsolationPrizePerBet
        );

        if (newProcessedIndex > startIndex) {
            progress.processedIndex = uint64(newProcessedIndex);
            progress.lastUpdate = uint64(block.timestamp);
        }
        require(prizePool >= totalWinnings, "Not enough prize pool");
        if (totalWinnings > 0) {
            prizePool -= totalWinnings;
            IERC20(address(xenNeroToken)).safeTransfer(msg.sender, totalWinnings);
        }

        emit PrizeClaimed(
            msg.sender,
            period,
            totalWinnings,
            startIndex,
            newProcessedIndex,
            newProcessedIndex >= userTotalBets
        );
    }

    /**
     * @notice Processes a batch of bets and calculates the total winnings for that batch.
     * @param userBets Array of bets of the user for a specific period.
     * @param winningNumber The winning number drawn for the period.
     * @param startIndex The starting index of bets to process.
     * @param endIndex The ending index (non-inclusive) of bets to process.
     * @param localPrizePerBet Locally cached winning prize amount per bet.
     * @param localConsolationPrizePerBet Locally cached consolation prize amount per bet.
     * @return totalWinnings The total winnings calculated for the processed bets.
     * @return newProcessedIndex The new index up to which bets have been processed.
     */
    function _processBatch(
        Bet[] storage userBets,
        uint16 winningNumber,
        uint256 startIndex,
        uint256 endIndex,
        uint256 localPrizePerBet,
        uint256 localConsolationPrizePerBet
    ) private returns (uint256 totalWinnings, uint256 newProcessedIndex) {
        // Obtain the individual digits and the count of unique digits in the winning number.
        uint8[3] memory winningDigits = _getDigits(winningNumber);
        uint8 numWinningUniqueDigits = _calcUniqueDigits(winningDigits);

        newProcessedIndex = startIndex;
        for (uint256 i = startIndex; i < endIndex; ) {
            Bet storage betStorage = userBets[i];
            // Skip bets that have already been processed.
            if ((betStorage.flags & FLAG_PRIZE_CLAIMED) != 0) {
                unchecked {
                    i++;
                    newProcessedIndex++;
                }
                continue;
            }
            // Calculate the winnings for the individual bet.
            uint256 betWinnings = _calcBetWinnings(
                betStorage,
                winningNumber,
                winningDigits,
                numWinningUniqueDigits,
                localPrizePerBet,
                localConsolationPrizePerBet
            );
            totalWinnings += betWinnings;
            betStorage.flags |= FLAG_PRIZE_CLAIMED;
            unchecked {
                i++;
                newProcessedIndex++;
            }
        }
        return (totalWinnings, newProcessedIndex);
    }

    /**
     * @notice Calculates the winnings for an individual bet.
     * @dev Loads the bet's numbers into memory to reduce redundant SLOAD operations.
     * @param betStorage The storage reference for the bet.
     * @param winningNumber The drawn winning number for the period.
     * @param winningDigits The individual digits of the winning number.
     * @param numWinningUniqueDigits The count of unique digits in the winning number.
     * @param localPrizePerBet Cached prize amount per bet.
     * @param localConsolationPrizePerBet Cached consolation prize amount per bet.
     * @return winnings The total winnings for the bet.
     */
    function _calcBetWinnings(
        Bet storage betStorage,
        uint16 winningNumber,
        uint8[3] memory winningDigits,
        uint8 numWinningUniqueDigits,
        uint256 localPrizePerBet,
        uint256 localConsolationPrizePerBet
    ) internal view returns (uint256 winnings) {
        uint8 multiplier = betStorage.multiplier;
        uint16[] memory numbers = betStorage.numbers;
        uint256 numCount = numbers.length;
        for (uint256 j = 0; j < numCount; j++) {
            uint16 userNumber = numbers[j];
            // If the user's number exactly matches the winning number, add the main prize.
            if (userNumber == winningNumber) {
                uint256 winAmt = localPrizePerBet * multiplier;
                // If the winning number is a jackpot, double the win amount.
                if (isJackpot(winningNumber)) {
                    winAmt *= 2;
                }
                winnings += winAmt;
            } else {
                // Otherwise, calculate and add any applicable consolation prize.
                winnings += _calcConsolationPrize(
                    userNumber,
                    winningDigits,
                    numWinningUniqueDigits,
                    multiplier,
                    localConsolationPrizePerBet
                );
            }
        }
        return winnings;
    }

    /**
     * @notice Calculates the consolation prize for a given user number.
     * @dev Checks if the user's number is an anagram (any order) of the winning number.
     * @param userNumber The user's chosen number.
     * @param winningDigits The individual digits of the winning number.
     * @param numWinningUniqueDigits The number of unique digits in the winning number.
     * @param multiplier The bet multiplier.
     * @param localConsolationPrizePerBet Cached consolation prize per bet.
     * @return The consolation prize amount if conditions are met, otherwise 0.
     */
    function _calcConsolationPrize(
        uint16 userNumber,
        uint8[3] memory winningDigits,
        uint8 numWinningUniqueDigits,
        uint8 multiplier,
        uint256 localConsolationPrizePerBet
    ) internal pure returns (uint256) {
        // Extract each digit from the user's number.
        uint8 a = uint8((userNumber / 100) % 10);
        uint8 b = uint8((userNumber / 10) % 10);
        uint8 c = uint8(userNumber % 10);

        // Compare frequency counts of each digit between the winning number and the user number.
        uint8[10] memory counts;
        unchecked {
            counts[winningDigits[0]]++;
            counts[winningDigits[1]]++;
            counts[winningDigits[2]]++;
            counts[a]--;
            counts[b]--;
            counts[c]--;
            for (uint8 k = 0; k < 10; k++) {
                if (counts[k] != 0) {
                    return 0;
                }
            }
        }
        // Award a consolation prize if the winning number has two or three unique digits.
        if (numWinningUniqueDigits == 3 || numWinningUniqueDigits == 2) {
            return localConsolationPrizePerBet * multiplier;
        }
        return 0;
    }

    /**
     * @notice Splits a three-digit number into its individual digits.
     * @param number The number to split.
     * @return An array containing the hundreds, tens, and ones digits.
     */
    function _getDigits(uint16 number) internal pure returns (uint8[3] memory) {
        return [
            uint8((number / 100) % 10),
            uint8((number / 10) % 10),
            uint8(number % 10)
            ];
    }

    /**
     * @notice Determines the number of unique digits within a three-digit number.
     * @param digits An array holding the three digits.
     * @return 1 if all digits are identical, 2 if two digits are identical, or 3 if all digits are unique.
     */
    function _calcUniqueDigits(uint8[3] memory digits) internal pure returns (uint8) {
        if (digits[0] == digits[1] && digits[1] == digits[2]) {
            return 1;
        } else if (digits[0] == digits[1] || digits[1] == digits[2] || digits[0] == digits[2]) {
            return 2;
        } else {
            return 3;
        }
    }

    /// @notice Retrieves the claim progress for a user in a given lottery period.
    /// @param user The user's address.
    /// @param period The lottery period.
    /// @return processed The number of bets already processed.
    /// @return total The total number of bets placed.
    /// @return isCompleted True if all bets have been processed, false otherwise.
    function getClaimProgress(address user, uint256 period) external view returns (uint256 processed, uint256 total, bool isCompleted) {
        total = betsByPeriod[period][user].length;
        processed = userPeriodProgress[user][period].processedIndex;
        isCompleted = processed >= total;
    }

    // ============================
    // ===== Token Exchange =======
    // ============================
    /// @notice Allows users to exchange XNT tokens for XEN tokens at a fixed exchange rate.
    /// @param xntAmount The amount of XNT tokens to exchange.
    function exchangeXNTForXEN(uint256 xntAmount) external nonReentrant {
        require(xntAmount > 0, "Amount must be greater than zero");
        uint256 xenAmount = (xntAmount * EXCHANGE_RATE) / 1e18;
        require(storedXenTokens >= xenAmount, "Not enough XEN tokens in contract");
        IERC20(address(xenNeroToken)).safeTransferFrom(msg.sender, address(this), xntAmount);
        prizePool += xntAmount;
        storedXenTokens -= xenAmount;
        xenToken.safeTransfer(msg.sender, xenAmount);
        emit XNTExchangedForXEN(msg.sender, xntAmount, xenAmount);
    }

    /// @notice Sets a new platform wallet address.
    /// @param _platformWallet The new wallet address.
    function setPlatformWallet(address _platformWallet) external onlyOwner {
        require(_platformWallet != address(0), "Invalid platform wallet address");
        emit PlatformWalletChanged(platformWallet, _platformWallet);
        platformWallet = _platformWallet;
    }

    /// @notice Retrieves current status information of the lottery contract.
    /// @return _totalBets Total bets placed.
    /// @return _prizePool Current prize pool balance.
    /// @return _storedXenTokens Amount of stored XEN tokens.
    function getContractStatus() external view returns (uint256 _totalBets, uint256 _prizePool, uint256 _storedXenTokens) {
        return (totalBets, prizePool, storedXenTokens);
    }

    /// @notice Retrieves detailed bet information for a specific period and user.
    /// @param period The lottery period.
    /// @param user The user's address.
    /// @return numbers A 2D array of bet numbers.
    /// @return multipliers Array of bet multipliers.
    /// @return flags Array of bet flags indicating claim status.
    function getBetsByPeriodAndUser(uint256 period, address user) external view returns (uint16[][] memory numbers, uint8[] memory multipliers, uint8[] memory flags) {
        Bet[] storage bets = betsByPeriod[period][user];
        uint256 numBets = bets.length;
        numbers = new uint16[][](numBets);
        multipliers = new uint8[](numBets);
        flags = new uint8[](numBets);
        for (uint256 i = 0; i < numBets; ) {
            numbers[i] = bets[i].numbers;
            multipliers[i] = bets[i].multiplier;
            flags[i] = bets[i].flags;
            unchecked { i++; }
        }
        return (numbers, multipliers, flags);
    }

    // ============================
    // =========== Pausing ========
    // ============================
    /// @notice Pauses the contract, temporarily disabling betting and certain functions.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, re-enabling betting.
    function unpause() external onlyOwner {
        _unpause();
    }
}