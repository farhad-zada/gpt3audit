/*Strengths:

    The smart contract has implemented OpenZeppelin libraries which provide security and modularity.
    The contract implements a modifier for checking whether a user can stake or not.
    There are max and min limits for staking amounts per wallet and total pool size.
    The contract has the ability to pause and complete the staking model.
    The contract implements the safeTransferFrom and safeTransfer methods of the SafeERC20Upgradeable library for safe token transfers.
    The contract has a reward and penalty system to incentivize users to hold their staked tokens for a certain period.

Weaknesses:

    The smart contract doesn't have any restrictions for calling the stake function, which means anyone can call it and stake tokens.
    There are no checks on the amount of token that the contract is holding, which could cause problems if the amount exceeds the limit.
    The contract doesn't have a mechanism for emergency stop in case of a security issue.
    The smart contract allows users to make multiple stakes with the same amount, but it doesn't handle overlapping stakes, which could lead to a conflict in reward and penalty calculations.
    The smart contract uses block.timestamp for calculating the reward and penalty, which is not reliable and subject to manipulation in a 51% attack.

Security:

    The contract has implemented OpenZeppelin libraries that provide security features such as SafeERC20Upgradeable.
    The contract has implemented a modifier to prevent users from staking an amount less than the minimum or more than the maximum amount allowed.
    The contract uses safeTransferFrom and safeTransfer functions from the SafeERC20Upgradeable library to prevent unauthorized transfers.
    The contract has a pause and complete feature to stop staking if required.
    The contract uses an enum to keep track of the state of the staking model.
    The contract uses the OwnableUpgradeable contract to restrict access to specific functions to the contract owner.
    The contract checks the total staked amount to make sure it doesn't exceed the maximum pool size.
    The contract implements a reward and penalty system that incentivizes users to hold their tokens for a certain period.

Overall, the smart contract has implemented several security features and has used OpenZeppelin libraries to enhance its security. However, there are still some weaknesses that need to be addressed to ensure the contract's safety and reliability.
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IStakeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";


contract Staking is Initializable, IStakeable, OwnableUpgradeable {

    /** modifier check stake is available */
    modifier StakeAvailable(address _staker, uint256 _amount) {
        require(_amount >= MIN_STAKING_AMOUNT,  "staked amount must be great or equal to minimum staking amount");
        require(totalStaked +  _amount <= POOL_MAX_SIZE, "reached pool max size");
        require(_stakeStatus == StakeStatus.ACTIVE, "Staking is not active");
        require(userTotalStakedAmount(_staker) + _amount <=  MAX_STAKING_AMOUNT,  "reached max staking amount per wallet");
        _;
    }

    IERC20Upgradeable public token;

    enum StakeStatus {ACTIVE, PAUSED, COMPLETED}

    StakeStatus public _stakeStatus;
    uint256 public totalStaked; // keeps total staking amount
    uint constant CODE_NOT_FOUND = 9999999; // keeps code about not founded stake. 

    // FOR 3 months staking
    uint constant REWARD_PERCENTAGE  = 15; //reward percent
    uint constant PENALTY_PERCENTAGE  = 10; //penalty percent

    uint constant REWARD_DEADLINE_SECONDS = 3600 * 24 * 30 * 3; //stake time with seconds.

    uint constant POOL_MAX_SIZE = 20_000_000 * 10 ** 18; //keep maximum pool size
    uint constant MIN_STAKING_AMOUNT = 20_000 * 10 ** 18 ; //keep minimum staking amount per transaction
    uint constant MAX_STAKING_AMOUNT = 500_000 * 10 ** 18; //keep max staking amount per wallet
    uint constant PENALTY_DIVISION_STEP = 30 * 3;

    // wallet infos
    address constant TOKEN_CONTRACT_ADDRESS = 0x9d39eF3bbCA5927909dde44476656B81BBe4eE75; //Token contract address

    // keeps staker info
    struct Staker {
        uint256 amount;
        uint256 reward;
        uint stakedAt;
    }

    mapping(address => Staker []) public stakers; // keeps all stakers
    
    function initialize() public initializer {
        __Ownable_init();
        token = IERC20Upgradeable(TOKEN_CONTRACT_ADDRESS);
    }

    /** add new staker */
    function stake(uint256 _amount) external override StakeAvailable(msg.sender, _amount){        
        Staker memory st = Staker(_amount, 0, block.timestamp);
        st.reward = _calcReward(st);
        stakers[msg.sender].push(st);
        totalStaked += _amount;

        SafeERC20Upgradeable.safeTransferFrom(token, msg.sender, address(this), _amount);

        //check stake model hash enough sapce for new staking then set stake model as completed
        if (totalStaked >= POOL_MAX_SIZE || POOL_MAX_SIZE - totalStaked < MIN_STAKING_AMOUNT) {
            _setStakeStatus(StakeStatus.COMPLETED);
        }

        emit Stake(msg.sender, _amount);
    }

    /** retrieve user stakes 
    * it does not duplicate stakers. beacause stakers receive address,  uint256 and return single Staker model
    * myStakes returns array of Staker
    */
    function myStakes(address stakerAddr)
        external
        view
        returns (Staker [] memory)
    {        
        return stakers[stakerAddr];
    }
    
    /** find user total staked amount 
    * we do not prefer use external library. Also Solidity has not built in sum function.
    */
    function userTotalStakedAmount(address stakerAddr) public view returns(uint256) {
        uint256 total;
        Staker [] storage stakes = stakers[stakerAddr];
        for (uint i = 0; i < stakes.length; i++) {
            total += stakes[i].amount;
        }

        return total;
    }

    /** claim user token */
    function claim(uint _id) external override {
        require(_stakeStatus != StakeStatus.PAUSED, "Staking model PAUSED.");
        uint256 balance = token.balanceOf(address(this));

        (uint256 rewardedAmount, uint256 amount) = calculateTransferAmount(msg.sender, _id);

        require(balance > rewardedAmount, "insufficent funds.");
        totalStaked -= amount;
        _unstake(msg.sender, _id);
        SafeERC20Upgradeable.safeTransfer(token, msg.sender, rewardedAmount);
    }

    /** unstake remove user stake by given _id */
    function _unstake(address _staker, uint _id) internal {
        (, uint index) = getStakeById(_staker, _id);
        require (index < CODE_NOT_FOUND,  "can not find valid stake.");
        _remove(msg.sender, index);
        emit Claim(msg.sender);
    }

    /** caluclate staker claimable amount */
    function calculateTransferAmount(address _staker, uint _id) public view returns(uint256, uint256) {
        (Staker memory staker, uint index) = getStakeById(_staker, _id);

        if (index == CODE_NOT_FOUND) {
            return (0, 0);
        }

        uint256 currentTime = block.timestamp;

        uint256 secondsStaked = currentTime - staker.stakedAt;
        
        if (secondsStaked < REWARD_DEADLINE_SECONDS) {
            return (_calcPenalty(staker, secondsStaked), staker.amount);
        }


        return (_calcReward(staker), staker.amount);

    }

    /**
    * return staker by id
    */
    function getStakeById(address _staker, uint _id) internal view returns(Staker memory, uint) {

        Staker [] storage stakes = stakers[_staker];

        for (uint i = 0; i < stakes.length; i++) {
            if (stakes[i].stakedAt == _id) {
                return (stakes[i], i);
            }
        }

        //initalize empty Staker
        Staker memory st = Staker(0x0, 0, 0);
        return (st, CODE_NOT_FOUND);
    }

    /** remove user stake with given array index 
    * we do not prefer use external library. Also Solidity has not built in remove function.
    */
    function _remove(address _staker, uint _index) internal {
        require(_index < stakers[_staker].length, "index out of bound");

        for (uint i = _index; i < stakers[_staker].length - 1; i++) {
            stakers[_staker][i] = stakers[_staker][i + 1];
        }
        stakers[_staker].pop();
    }

    /** calculate staker reward */
    function _calcReward(Staker memory request) internal pure returns(uint) {
        return request.amount + (request.amount * REWARD_PERCENTAGE / 100);
    }

    /** calculate staker penalty */
    function _calcPenalty(Staker memory request, uint secondStaked) internal pure returns(uint) {
        uint chunkSize = REWARD_DEADLINE_SECONDS / PENALTY_DIVISION_STEP;
        uint chunkPercent = PENALTY_PERCENTAGE * 10 ** 10 / PENALTY_DIVISION_STEP;
        uint percent = PENALTY_PERCENTAGE * 10 ** 10 - (secondStaked / chunkSize * chunkPercent);

        return request.amount - ((request.amount * percent / 100) / 10 ** 10);
    }

    /** withdraw contract balance to staking_main_pool_wallet */
    function withdraw(address payable addr, uint amount) external onlyOwner {
        SafeERC20Upgradeable.safeTransfer(token, addr, amount);
    }

    /**
    * set current staking model as finished
     */
    function setStakeStatus(StakeStatus status) public onlyOwner {
        _stakeStatus = status;
    }
    /** set stake status internally */
    function _setStakeStatus(StakeStatus status) internal {
        _stakeStatus = status;
    }
    /** add new stake by contract owner manually */
    function addStake(address _staker, uint256 _amount, uint256 _time) public onlyOwner {
        Staker memory st = Staker(_amount, 0, _time);
        st.reward = _calcReward(st);
        stakers[_staker].push(st);
        totalStaked += _amount;
        emit Stake(_staker, _amount);
    }

    /** remove stake by contract owner manually*/
    function removeStake(address _staker, uint _id) public onlyOwner {
        (Staker memory st, uint index) = getStakeById(_staker, _id);
        require (index < CODE_NOT_FOUND,  "can not find valid stake.");
        _remove(_staker, index);
        totalStaked -= st.amount;
        emit Claim(msg.sender);
    }
    
}
