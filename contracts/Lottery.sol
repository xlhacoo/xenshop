// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Import required OpenZeppelin contracts and interfaces
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";  // Safe transfer functions for ERC20 tokens
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";            // Interface for ERC20 tokens
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";             // Implementation of the ERC20 standard
import "@openzeppelin/contracts/security/Pausable.sol";             // Adds pausable functionality
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";      // Protects against reentrancy attacks
import "@openzeppelin/contracts/access/Ownable.sol";                // Provides basic access control mechanism

// Import Chainlink VRF contracts
import { VRFConsumerBaseV2Plus } from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";  // Base contract for VRF consumer
import { VRFV2PlusClient } from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";    // VRF request and response structures
import { VRFCoordinatorV2_5 } from "@chainlink/contracts/src/v0.8/vrf/dev/VRFCoordinatorV2_5.sol";         // VRF coordinator interface

/// @title XenNero Token Contract
/// @dev ERC20 token representing XenNero, minted by the Lottery contract
contract XenNeroToken is ERC20, Ownable {
    address public immutable lotteryContract;  // Address of the Lottery contract
    uint256 public constant MAX_SUPPLY = 21_000_000 * 1e18;  // Maximum total supply of 21 million tokens

    /// @notice Constructor sets token name, symbol, and the Lottery contract address
    /// @param _lotteryContract Address of the Lottery contract
    constructor(address _lotteryContract) ERC20("XenNero Token", "XNT") {
        require(_lotteryContract != address(0), "Invalid lottery contract address");
        lotteryContract = _lotteryContract;
    }

    /// @notice Modifier to restrict functions to be called only by the Lottery contract
    modifier onlyLottery() {
        require(msg.sender == lotteryContract, "Only lottery contract can mint");
        _;
    }

    /// @notice Mints new XenNero tokens
    /// @param to Address receiving the tokens
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external onlyLottery {
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        _mint(to, amount);
    }
}

/// @title Lottery Contract
/// @notice This contract allows users to place bets, with the chance to win prizes and earn XenNero tokens
contract Lottery is Pausable, ReentrancyGuard, VRFConsumerBaseV2Plus {
    using SafeERC20 for IERC20;  // Use SafeERC20 library for IERC20 tokens

    IERC20 public immutable xenToken;            // XEN token contract
    XenNeroToken public immutable xenNeroToken;  // XenNero token contract
    address public platformWallet;               // Platform wallet address

    // Configuration parameters
    uint256 public constant betCost = 10_000_000 * 1e18;               // // Cost XEN per bet number per multiplier (10 XNT)
    uint256 public prizePerBet = 5200 * 1e18;        // Initial Prize per winning bet number per multiplier (5200 XNT)
    uint256 public consolationPrizePerBet = 20 * 1e18;// Initial consolation prize amount (20 XNT)
    uint8 public constant maxMultiplier = 99;                          // Maximum allowed multiplier
    uint8 public constant maxNumbersPerBet = 100;                      // Maximum numbers a user can choose per bet

    /// @notice Percentage (in parts per thousand) of sales to add to the prize pool (e.g., 799 means 79.9%)
    uint16 public constant rolloverDepositPrizePoolRatio = 899;        // Parts per thousand for prize pool rollover
    uint256 public constant initialXenNeroReward = 100 * 1e18;         // Initial XenNero reward per bet
    uint256 public constant halvingPeriod = 105_000;                   // Halving XenNero reward every 105,000 bets
    uint256 public constant maxXenNeroSupply = 21_000_000 * 1e18;   // Maximum total supply of XenNero tokens (21 million)
    uint256 public constant EXCHANGE_RATE = 1_000_000 * 1e18; // 1 XNT = 1,000,000 XEN

    uint256 public totalBets;          // Total number of bets placed
    uint256 public totalXenNeroMinted; // Total XenNero tokens minted so far
    uint256 public prizePool;          // Current prize pool amount in XNT
    uint32 public currentPeriod = 1;  // Current betting period

    uint256 public storedXenTokens;    // XEN tokens stored in the contract (from bets and unclaimed prizes)

    /// @notice Structure representing a user's bet
    struct Bet {
        uint32 period;          // Betting period
        uint8 multiplier;       // Multiplier applied to this bet
        uint8 flags;            // Flags for reward claims using bit masking
        uint16[] numbers;       // Chosen numbers for this bet
    }

    /// @notice Structure representing information about a betting period
    struct PeriodInfo {
        uint128 totalSales;     // Total sales in this period
        uint16 winningNumber;   // Winning number for this period
        bool isDrawn;           // Indicates if the winning number has been drawn
    }

    // Mapping from period to period information
    mapping(uint256 => PeriodInfo) public periods;
    // Mapping from period to user to bets
    mapping(uint256 => mapping(address => Bet[])) public betsByPeriod;

    // Chainlink VRF variables
    VRFCoordinatorV2_5 public immutable COORDINATOR;      // VRF Coordinator
    uint256 public s_subscriptionId;     // Subscription ID for Chainlink VRF
    bytes32 keyHash;                     // Key hash for the Chainlink VRF
    uint32 callbackGasLimit = 100000;    // Callback gas limit for VRF response
    uint16 requestConfirmations = 3;     // Number of confirmations before fulfilling the request
    uint32 numWords = 1;                 // Number of random words requested

    // Mapping from VRF request ID to betting period
    mapping(uint256 => uint256) public vrfRequestIdToPeriod;

    // Constants for bit flags (used in Bet.flags)
    uint8 constant FLAG_PRIZE_CLAIMED = 1 << 1;    // Bit 1: Prize claimed

    // Events for transparency and debuggability
    event BetPlaced(address indexed user, uint256 period, uint16[] numbers, uint8 multiplier);
    event WinningNumberDrawn(uint256 period, uint16 winningNumber);
    event PrizeClaimed(address indexed user, uint256 period, uint256 amount);
    event XNTExchangedForXEN(address indexed user, uint256 xntAmount, uint256 xenAmount);
    event PeriodChanged(uint256 newPeriod);
    event PlatformWalletChanged(address indexed oldWallet, address indexed newWallet);
    event PrizePoolDonated(address indexed donor, uint256 amount);
    event RandomNumberFulfilled(uint256 requestId, uint16 winningNumber);
    event XENDonated(address indexed donor, uint256 amount);

    /// @notice Constructor initializes the Lottery contract
    /// @param _xenTokenAddress Address of the XEN token contract
    /// @param _platformWallet Platform wallet address
    /// @param _vrfCoordinator Address of the VRF Coordinator
    /// @param _keyHash Key hash for the Chainlink VRF
    /// @param _subscriptionId Subscription ID for Chainlink VRF
    constructor(
        address _xenTokenAddress,
        address _platformWallet,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint256 _subscriptionId
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        require(_xenTokenAddress != address(0), "Invalid XEN token address");
        require(_platformWallet != address(0), "Invalid platform wallet address");
        require(_vrfCoordinator != address(0), "Invalid VRF coordinator address");

        xenToken = IERC20(_xenTokenAddress);
        xenNeroToken = new XenNeroToken(address(this));
        platformWallet = _platformWallet;

        COORDINATOR = VRFCoordinatorV2_5(_vrfCoordinator);
        keyHash = _keyHash;
        s_subscriptionId = _subscriptionId;
    }

    /// @notice Modifier to restrict functions to the contract's owner or platform wallet
    modifier onlyAdmin() {
        require(isAdmin(msg.sender), "Not admin");
        _;
    }

    /// @notice Determines if an address is an admin (owner or platform wallet)
    /// @param account Address to check
    /// @return True if the address is an admin, false otherwise
    function isAdmin(address account) public view returns (bool) {
        return account == owner() || account == platformWallet;
    }

    /// @notice Calculates the current XenNero reward per bet
    /// @return Current XenNero reward amount
    function calculateXenNeroReward() internal view returns (uint256) {
        if (totalXenNeroMinted >= maxXenNeroSupply) {
            return 0;
        }

        uint256 halvings = totalBets / halvingPeriod;
        uint256 currentReward = initialXenNeroReward >> halvings; // Halving the reward by shifting bits

        uint256 remainingXNT = maxXenNeroSupply - totalXenNeroMinted;
        return currentReward > remainingXNT ? remainingXNT : currentReward;
    }

    /// @notice Allows users to donate XNT tokens to the prize pool
    /// @param amount Amount of XNT tokens to donate
    function donateToPrizePool(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        xenNeroToken.transferFrom(msg.sender, address(this), amount);
        prizePool += amount;

        emit PrizePoolDonated(msg.sender, amount);
    }

    // Add this function to the Lottery contract
    /// @notice Allows users to donate XEN tokens to the contract
    /// @param amount Amount of XEN tokens to donate
    function donateXEN(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        xenToken.safeTransferFrom(msg.sender, address(this), amount);
        storedXenTokens += amount;

        emit XENDonated(msg.sender, amount);
    }

    /// @notice User places a bet with specified numbers and multiplier
    /// @param numbers List of chosen numbers (each between 0 and 999 inclusive)
    /// @param multiplier Multiplier for the bet (between 1 and maxMultiplier inclusive)
    function placeBet(uint16[] calldata numbers, uint8 multiplier) external whenNotPaused {
        uint256 numNumbers = numbers.length;
        require(numNumbers > 0, "At least one number required");
        require(numNumbers <= maxNumbersPerBet, "Too many numbers");
        require(multiplier > 0 && multiplier <= maxMultiplier, "Invalid multiplier");

        for (uint256 i = 0; i < numNumbers; i++) {
            require(numbers[i] <= 999, "Numbers must be between 0 and 999");
        }

        uint256 totalCost = numNumbers * betCost * multiplier;
        // 将资金从用户转移到合约
        xenToken.safeTransferFrom(msg.sender, address(this), totalCost);

        // 更新当前期的销售额
        PeriodInfo storage periodInfo = periods[currentPeriod];
        periodInfo.totalSales += uint128(totalCost);

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

        betsByPeriod[currentPeriod][msg.sender].push(Bet({
            period: uint32(currentPeriod),
            numbers: numbers,
            multiplier: multiplier,
            flags: 0
        }));

        emit BetPlaced(msg.sender, currentPeriod, numbers, multiplier);
    }

    /// @notice Checks if a number is a jackpot (triple digit identical number or zero)
    /// @param number Number to check
    /// @return True if it's a jackpot number, false otherwise
    function isJackpot(uint16 number) internal pure returns (bool) {
        return number == 0 ||
        number == 111 ||
        number == 222 ||
        number == 333 ||
        number == 444 ||
        number == 555 ||
        number == 666 ||
        number == 777 ||
        number == 888 ||
            number == 999;
    }

    /// @notice Requests randomness from Chainlink VRF to draw the winning number
    function drawWinningNumber() external onlyAdmin whenNotPaused {
        PeriodInfo storage periodInfo = periods[currentPeriod];
        require(!periodInfo.isDrawn, "Winning number already drawn for this period");

        VRFV2PlusClient.RandomWordsRequest memory req = VRFV2PlusClient.RandomWordsRequest({
            keyHash: keyHash,
            subId: s_subscriptionId,
            requestConfirmations: requestConfirmations,
            callbackGasLimit: callbackGasLimit,
            numWords: numWords,
            extraArgs: ""
        });

        uint256 requestId = COORDINATOR.requestRandomWords(req);
        vrfRequestIdToPeriod[requestId] = currentPeriod;
    }

    /// @notice Callback function used by Chainlink VRF Coordinator to provide randomness
    /// @param requestId ID of the randomness request
    /// @param randomWords Array of random words provided by VRF
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        uint256 period = vrfRequestIdToPeriod[requestId];
        PeriodInfo storage periodInfo = periods[period];
        require(!periodInfo.isDrawn, "Winning number already drawn for this period");

        uint256 randomWord = randomWords[0];
        uint16 winningNumber = uint16(randomWord % 1000); // Generate a number between 0 and 999

        periodInfo.winningNumber = winningNumber;
        periodInfo.isDrawn = true;

        uint256 totalSales = periodInfo.totalSales;
        uint256 prizeAddition = (totalSales * rolloverDepositPrizePoolRatio) / 1000;
        uint256 adminAmount = totalSales - prizeAddition;
        storedXenTokens += prizeAddition;
        xenToken.safeTransfer(platformWallet, adminAmount);

        emit WinningNumberDrawn(period, winningNumber);

        unchecked {
            currentPeriod += 1;
        }
        emit PeriodChanged(currentPeriod);
    }

    /// @notice Extracts the digits of a 3-digit number, considering leading zeros
    /// @param number The 3-digit number
    /// @return digits An array containing the digits
    function getDigits(uint16 number) internal pure returns (uint8[3] memory digits) {
        unchecked {
            digits[0] = uint8((number / 100) % 10);
            digits[1] = uint8((number / 10) % 10);
            digits[2] = uint8(number % 10);
        }
    }

    /// @notice Determines the number of unique digits in a number
    /// @param digits An array containing the digits
    /// @return The number of unique digits (1, 2, or 3)
    function numUniqueDigits(uint8[3] memory digits) internal pure returns (uint8) {
        if (digits[0] == digits[1] && digits[1] == digits[2]) {
            return 1; // All digits are the same
        } else if (digits[0] == digits[1] || digits[1] == digits[2] || digits[0] == digits[2]) {
            return 2; // Two digits are the same
        } else {
            return 3; // All digits are different
        }
    }

    /// @notice Checks if two numbers are permutations of each other
    /// @param digits1 The digits of the first number
    /// @param digits2 The digits of the second number
    /// @return True if they are permutations, false otherwise
    function arePermutations(uint8[3] memory digits1, uint8[3] memory digits2) internal pure returns (bool) {
        uint8[10] memory counts;
        unchecked {
            counts[digits1[0]]++;
            counts[digits1[1]]++;
            counts[digits1[2]]++;

            counts[digits2[0]]--;
            counts[digits2[1]]--;
            counts[digits2[2]]--;

            for (uint8 i = 0; i < 10; ) {
                if (counts[i] != 0) {
                    return false;
                }
                i++;
            }

        }
        return true;
    }

    /// @notice Claims winnings for a specific period, including consolation prizes
    /// @dev Users can claim their winnings after the winning number is drawn
    /// @param period Period to claim winnings for
    function claimWinnings(uint256 period) external nonReentrant {
        PeriodInfo storage periodInfo = periods[period];
        require(periodInfo.isDrawn, "Winning number not drawn yet for this period");

        uint16 winningNumber = periodInfo.winningNumber;
        uint256 winnings = 0;
        Bet[] storage userBets = betsByPeriod[period][msg.sender];
        uint256 numBets = userBets.length;
        uint8[3] memory winningDigits = getDigits(winningNumber);
        uint8 numWinningUniqueDigits = numUniqueDigits(winningDigits);

        for(uint256 i = 0; i < numBets; ) {
            Bet storage bet = userBets[i];
            if ((bet.flags & FLAG_PRIZE_CLAIMED) == 0) {
                uint256 numNumbers = bet.numbers.length;
                for (uint256 j = 0; j < numNumbers; ) {
                    uint16 userNumber = bet.numbers[j];
                    if (userNumber == winningNumber) {
                        uint256 winningAmount = prizePerBet * uint256(bet.multiplier);
                        if (isJackpot(winningNumber)) {
                            winningAmount *= 2;
                        }
                        winnings += winningAmount;
                    } else {
                        uint8[3] memory userDigits = getDigits(userNumber);
                        if (arePermutations(winningDigits, userDigits)) {
                            if (numWinningUniqueDigits == 3 || numWinningUniqueDigits == 2) {
                                winnings += consolationPrizePerBet * uint256(bet.multiplier);
                            }
                        }
                    }
                    unchecked{
                        j++;
                    }
                }
                bet.flags |= FLAG_PRIZE_CLAIMED;
            }
            unchecked {
                i++;
            }
        }

        require(winnings > 0, "No winnings to claim for this period");

        require(winnings <= prizePool, "Not enough XNT in prize pool");

        prizePool -= winnings;
        xenNeroToken.transfer(msg.sender, winnings);

        emit PrizeClaimed(msg.sender, period, winnings);
    }

    /// @notice Allows users to exchange XNT for XEN at a fixed rate
    /// @param xntAmount Amount of XNT to exchange
    function exchangeXNTForXEN(uint256 xntAmount) external nonReentrant {
        require(xntAmount > 0, "Amount must be greater than zero");

        uint256 xenAmount = (xntAmount * EXCHANGE_RATE) / 1e18;

        require(storedXenTokens >= xenAmount, "Not enough XEN tokens in contract");

        xenNeroToken.transferFrom(msg.sender, address(this), xntAmount);

        prizePool += xntAmount;

        storedXenTokens -= xenAmount;
        xenToken.safeTransfer(msg.sender, xenAmount);

        emit XNTExchangedForXEN(msg.sender, xntAmount, xenAmount);
    }

    /// @notice Sets the platform wallet address
    /// @dev Only the contract owner can change the platform wallet for added security
    /// @param _platformWallet New platform wallet address
    function setPlatformWallet(address _platformWallet) external onlyOwner {
        require(_platformWallet != address(0), "Invalid platform wallet address");
        emit PlatformWalletChanged(platformWallet, _platformWallet);
        platformWallet = _platformWallet;
    }

    /// @notice Gets contract status information
    /// @return _totalBets Total number of bets
    /// @return _prizePool Current prize pool in XNT tokens
    /// @return _storedXenTokens Amount of XEN tokens stored in the contract
    function getContractStatus() external view returns (
        uint256 _totalBets,
        uint256 _prizePool,
        uint256 _storedXenTokens
    ) {
        return (
            totalBets,
            prizePool,
            storedXenTokens
        );
    }

    /// @notice Retrieves all bet information for a specific lottery period and user
    /// @dev Returns comprehensive bet details as separate arrays for efficient data access
    /// @param period The lottery period number to retrieve bets from
    /// @param user The wallet address of the user whose bets are being queried
    /// @return betPeriods Array of period numbers corresponding to each bet
    /// @return numbers Two-dimensional array containing the number selections for each bet
    /// @return multipliers Array of multiplier values for each bet
    /// @return flags Array of status flags for each bet (bit1: prize claimed)
    function getBetsByPeriodAndUser(uint256 period, address user) external view returns (
        uint256[] memory betPeriods,
        uint16[][] memory numbers,
        uint8[] memory multipliers,
        uint8[] memory flags
    ) {
        // Get the array of bets for the specified period and user from storage
        Bet[] storage bets = betsByPeriod[period][user];
        uint256 numBets = bets.length;
        // Initialize return arrays with the same length as the number of bets
        betPeriods = new uint256[](numBets);
        numbers = new uint16[][](numBets);
        multipliers = new uint8[](numBets);
        flags = new uint8[](numBets);
        // Iterate through all bets and copy each bet's information to the corresponding return arrays
        for (uint256 i = 0; i < numBets; ) {
            betPeriods[i] = bets[i].period;
            numbers[i] = bets[i].numbers;
            multipliers[i] = bets[i].multiplier;
            flags[i] = bets[i].flags;
            unchecked{
                i++;
            }
        }
        return (betPeriods, numbers, multipliers, flags);
    }

    /// @notice Pauses the contract (stops betting)
    /// @dev Only the contract owner can pause the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract (resumes betting)
    /// @dev Only the contract owner can unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }
}