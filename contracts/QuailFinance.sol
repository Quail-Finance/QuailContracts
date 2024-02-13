// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IERC20Rebasing.sol";
import "./IBlast.sol";

contract QuailFinance{
    uint256 private nextPotId = 1; // Start pot IDs at 1
    IBlast public constant BLAST = IBlast(0x4300000000000000000000000000000000000002);
    uint256 public totalRevenue;
    IERC20 public usdbToken; // USDC token interface
    mapping(uint256 => Pot) public pots;
    // Additional mapping to track earned yield per user
    mapping(address => uint256) private userYield;
    /*
    * Represents the structure of a pot within Quail Finance.
    * Each pot allows participants to deposit USDB tokens, which are then rotated or distributed based on the pot's configuration.
    * 
    * Fields:
    * - amount: The fixed amount of USDB tokens required from each participant to join the pot. This ensures uniform contributions from all participants.
    * - rotationCycleInSeconds: The duration in seconds between each rotation.
    * - lastRotationTime: Timestamp of the last rotation, used to calculate the next eligible rotation time.
    * - interestNumerator and interestDenominator: Parts of the fractional interest rate for risk calculations. 
    *   The actual interest rate is derived from interestNumerator / interestDenominator.
    * - numParticipants: The total number of participants allowed in the pot. This limit is set at pot creation.
    * - currentRound: Tracks the current round of the pot, incrementing after each rotation. It represents the progression through the pot's lifecycle.
    * - potCreator: The address of the user who created the pot, who may have special privileges, such as initiating rotations.
    * - participants: A dynamic array of addresses representing participants who have joined the pot.
    * - contributions: A mapping from participant address to the amount of USDB they have contributed. This mapping prevents multiple deposits from the same address and verifies that each participant has deposited the required amount.
    *
    * The `rotationCycleInSeconds` determines the frequency of rotations, enabling dynamic adjustment of the pot's rotation schedule. The `currentRound` is incremented after each rotation, serving as a counter for the total number of rotations, which is essential for calculating and distributing the pot's funds, including the handling of the risk pool towards the end of the pot's lifecycle.
    */
    struct Pot {
        uint256 amount;
        uint256 rotationCycleInSeconds;
        uint256 lastRotationTime;
        uint256 interestNumerator;
        uint256 interestDenominator;
        uint256 numParticipants;
        uint256 currentRound;
        address potCreator;
        address[] participants;
        mapping(address => uint256) contributions;
    }

    // Events
    event PotCreated(uint256 potId, address creator, uint256 amount, uint256 rotationCycleInSeconds, uint256 _interestDenominator, uint256 _interestNumerator, uint256 _numParticipants);
    event ParticipantJoined(uint256 potId, address participant);
    event RotationCompleted(uint256 potId, address winner, uint256 round);

    IERC20Rebasing public constant USDB = IERC20Rebasing(0x4200000000000000000000000000000000000022);

    constructor() {
        USDB.configure(YieldMode.CLAIMABLE); //configure claimable yield for USDB
        usdbToken = IERC20(0x4200000000000000000000000000000000000022);
        BLAST.configureClaimableGas();
	}
    // Create a new Quail Pot
    function createPot(uint256 _rotationCycleInSeconds, uint256 _interestDenominator, uint256 _interestNumerator, uint256 _numParticipants, uint256 _amount) public{
        require(_rotationCycleInSeconds > 0, "Rotation cycle must be positive");
        require(_interestDenominator > 0, "Interest denominator must be positive");
        require(_interestNumerator <= _interestDenominator, "Numerator must be less than or equal to denominator");
        uint256 potId = nextPotId++;
        address[] memory participants;
        uint256 amountAfterRevenue = deductRevenue(_amount);
        require(usdbToken.transferFrom(msg.sender, address(this), amountAfterRevenue), "Creator should deposit the initial amount");
        // Assign values individually
        Pot storage newPot = pots[potId];
        newPot.amount = _amount;
        newPot.potCreator = msg.sender;
        newPot.rotationCycleInSeconds = _rotationCycleInSeconds;
        newPot.interestNumerator = _interestNumerator;
        newPot.interestDenominator = _interestDenominator;
        newPot.lastRotationTime = block.timestamp;
        newPot.numParticipants = _numParticipants;
        newPot.currentRound = 0;
        newPot.participants = participants;

        emit PotCreated(potId, msg.sender, _amount, _rotationCycleInSeconds, _interestNumerator, _interestDenominator,_numParticipants);
    }

    // Join a Quail Pot
    // To-do take 1% quail finacne fee in deposits 
    function joinPot(uint256 _potId) external payable {
        Pot storage pot = pots[_potId];
        require(pot.participants.length < pot.numParticipants, "Pot is full");
        require(pot.currentRound < 1, "Rotating pots cannot be joined");
        require(pot.contributions[msg.sender] == 0, "Already joined");
        
        // Transfer usdb to the contract
        uint256 amountAfterRevenue = deductRevenue(pot.amount);
        require(usdbToken.transferFrom(msg.sender, address(this), amountAfterRevenue), "Transfer failed");
        pot.contributions[msg.sender] = amountAfterRevenue;
        pot.participants.push(msg.sender);
        
        emit ParticipantJoined(_potId, msg.sender);
    }

    // Rotate liquidity turn-by-turn
    // To-do when all participants wins, there will no longer be more rotation's 
    // To-do users should be able to claim their yield
    function rotateLiquidity(uint256 _potId) public {
        require(pots[_potId].potCreator == msg.sender, "Only the pot creator can reveal the winner");
        Pot storage pot = pots[_potId];
        require(block.timestamp >= pot.lastRotationTime + pot.rotationCycleInSeconds, "Next rotation not yet due");
        uint256 winnerIndex = (pot.currentRound % pot.numParticipants);

        // To-do generate winner randomly
        address winner = pot.participants[winnerIndex];

        // Transfer usdb to the winner. This will deduct the risk percentage amount set by the creator
        uint256 totalPotAmount = pot.participants.length * pot.amount;
        uint256 totalPotAmountInterest = calculateInterest(_potId,totalPotAmount);
        require(usdbToken.transfer(msg.sender, totalPotAmount-totalPotAmountInterest), "Yield transfer failed");
        pot.lastRotationTime = block.timestamp;
        emit RotationCompleted(_potId, winner, pot.currentRound);

        // Increment round for the next rotation
        pot.currentRound++;
    }

    // Update user yield
    function updateUserYield(address user, uint256 amount) internal {
        userYield[user] += amount; // Accumulate yield for the user
    }

    // Function to calculate interest for a given amount
    function calculateInterest(uint256 _potId, uint256 _amount) public view returns (uint256) {
        Pot storage pot = pots[_potId];
        return _amount * pot.interestNumerator / pot.interestDenominator;
    }

    function deductRevenue(uint256 _amount) private returns (uint256 netAmount) {
        uint256 revenue = _amount / 100;
        netAmount = _amount - revenue;
        totalRevenue += revenue;
        return (netAmount);
    }

    // Function to claim gas
    // To-do either give gas fees to users or let admin withdraw it 
    function claimMyContractsGas() external {
        BLAST.claimAllGas(address(this), msg.sender);
    }
}
