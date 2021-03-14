pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./LotteryNFT.sol";
import "./LotteryOwnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol"; 

// import "@nomiclabs/buidler/console.sol";
interface SlimeFriends {
    function setSlimeFriend(address farmer, address referrer) external;
    function getSlimeFriend(address farmer) external view returns (address);
}

 contract IRewardDistributionRecipient is LotteryOwnable {
    address public rewardReferral;
    address public rewardVote;
 

    function setRewardReferral(address _rewardReferral) external onlyOwner {
        rewardReferral = _rewardReferral;
    }
 
}
// 4 numbers
contract SlimeLottery is  IRewardDistributionRecipient  {
    using SafeMath for uint256;
    using SafeMath for uint8;
    using SafeERC20 for IERC20;

    uint8 constant keyLengthForEachBuy = 11;
    // Allocation for first/sencond/third reward
 
    uint8[3] public allocation;
    // The TOKEN to buy lottery
    IERC20 public slime;
    // The Lottery NFT for tickets
    LotteryNFT public lotteryNFT;
    // adminAddress
    address public adminAddress;
    // maxNumber
    uint8 public maxNumber;
    // minPrice, if decimal is not 18, please reset it
    uint256 public minPrice;
 
    // ================================= 
    // issueId => winningNumbers[numbers]
    mapping (uint256 => uint8[4]) public historyNumbers;
    // issueId => [tokenId]
    mapping (uint256 => uint256[]) public lotteryInfo;
    // issueId => [totalAmount, firstMatchAmount, secondMatchingAmount, thirdMatchingAmount]
    mapping (uint256 => uint256[]) public historyAmount;
    // issueId => trickyNumber => buyAmountSum
    mapping (uint256 => mapping(uint64 => uint256)) public userBuyAmountSum;
    // address => [tokenId]
    mapping (address => uint256[]) public userInfo;

    //
    mapping (uint256 => uint) public drawTimestamp;

    uint256 public issueIndex = 0;
    uint256 public totalAddresses = 0;
    uint256 public totalAmount = 0;
    uint256 public lastTimestamp;
 
    uint256 public burnfee = 10;

    uint256 public acumulatedRoundBurnfee = 10;
 
    // burn multiplier by number matches on rewards
    uint8[4] private burnMultiplier = [200, 150, 100,0];

    //0,4%
    uint256 public divreferralfee = 6; 
    //0,6%
    uint256 public divreferralBuyfee = 6; 
    //10%
    uint256 public treasuryFee = 100; 
 
    uint8[4] public winningNumbers;
  
    address public treasuryAddress = address(0x3b015df0f87A47B5B49B734a68E6b9d632EF5704);

    address public burnAddress = address(0xdead);

    // default false
    bool public drawingPhase;
 
    event Buy(address indexed user, uint256 tokenId);
    event Drawing(uint256 indexed issueIndex, uint8[4] winningNumbers);
    event Claim(address indexed user, uint256 tokenid, uint256 amount);
    event DevWithdraw(address indexed user, uint256 amount);
    event Reset(uint256 indexed issueIndex);
    event MultiClaim(address indexed user, uint256 amount);
    event MultiBuy(address indexed user, uint256 amount);
    event ReferralClaim(uint256 indexed issueIndex,address indexed user,address indexed userTo, uint256 reward);
    event ReferralBuyClaim(uint256 indexed issueIndex,address indexed user,address indexed userTo, uint256 reward);
    event TreasuryFeeClaim(uint256 indexed issueIndex, address indexed treasuryAddress, uint256 reward);
    event Burn(uint256 indexed issueIndex,address indexed user,uint256 amount);

    constructor(  
        
        IERC20 _slime, 
        uint256 _minPrice,
        uint8 _maxNumber,
        address _owner,
        address _adminAddress,
        string memory _ticketName,
        string memory _ticketTicker 
        ) public {

        if(bytes(_ticketName).length==0)
            _ticketName= "Slime Lottery Ticket";
        if(bytes(_ticketName).length==0)
             _ticketTicker= "SLT";

        slime = _slime;
        lotteryNFT = new LotteryNFT(_ticketName ,_ticketTicker);
        minPrice = _minPrice;
        maxNumber = _maxNumber;
        adminAddress = _adminAddress;
        lastTimestamp = block.timestamp;
        allocation = [64, 24, 12]; 
        initOwner(_owner);
    }
 
    uint8[4] private nullTicket = [0,0,0,0];

    modifier onlyAdmin() {
        require(msg.sender == adminAddress, "admin: wut?");
        _;
    }

    modifier inDrawingPhase() {
        require(!drawed(), 'drawed, can not buy now');
        require(!drawingPhase, 'drawing, can not buy now');
        _;
    }

    function drawed() public view returns(bool) {
        return winningNumbers[0] != 0;
    }

    function reset() external onlyAdmin {
        require(drawed(), "drawed?");
        lastTimestamp = block.timestamp;
        totalAddresses = 0;
      
        totalAmount = 0;
        winningNumbers[0]=0;
        winningNumbers[1]=0;
        winningNumbers[2]=0;
        winningNumbers[3]=0;
        drawingPhase = false;
        uint256 preindex = issueIndex;
        issueIndex = issueIndex +1;

        uint256 accumulationForNext = 0;
        if(getMatchingRewardAmount(preindex, 4) == 0) {
          accumulationForNext= accumulationForNext.add(getTotalRewards(preindex).mul(allocation[0]).div(100));
    
        }
        if(getMatchingRewardAmount(preindex, 3) == 0) {
            accumulationForNext= accumulationForNext.add(getTotalRewards(preindex).mul(allocation[1]).div(100));
    
        } 
        if(getMatchingRewardAmount(preindex, 2) == 0) {
            accumulationForNext= accumulationForNext.add(getTotalRewards(preindex).mul(allocation[2]).div(100));
    
        } 
        // a share of the accumulated for next round is automatically burned
        if(acumulatedRoundBurnfee>0 )
        { 
            uint256 toBurn = accumulationForNext.mul(acumulatedRoundBurnfee).div(100);
            accumulationForNext = accumulationForNext.sub(toBurn);
            //burn!
            slime.safeTransfer(burnAddress,toBurn);
        }

        if(accumulationForNext > 0) { 
                  internalBuy(accumulationForNext, nullTicket);
        }
        emit Reset(issueIndex);
    }
 
    function enterDrawingPhase() external onlyAdmin {
        require(!drawed(), 'drawed');
        drawingPhase = true;
    }

    // add externalRandomNumber to prevent node validators exploiting
    function drawing(uint256 _externalRandomNumber) external onlyAdmin {
        require(!drawed(), "reset?");
        require(drawingPhase, "enter drawing phase first");
        bytes32 _structHash;
        uint256 _randomNumber;
        uint8 _maxNumber = maxNumber;
        bytes32 _blockhash = blockhash(block.number-1);

        // waste some gas fee here
        for (uint i = 0; i < 10; i++) {
            getTotalRewards(issueIndex);
        }
        uint256 gasleft = gasleft();

        // 1
        _structHash = keccak256(
            abi.encode(
                _blockhash,
                totalAddresses,
                gasleft,
                _externalRandomNumber
            )
        );
        _randomNumber  = uint256(_structHash);
        assembly {_randomNumber := add(mod(_randomNumber, _maxNumber),1)}
        winningNumbers[0]=uint8(_randomNumber);

        // 2
        _structHash = keccak256(
            abi.encode(
                _blockhash,
                totalAmount,
                gasleft,
                _externalRandomNumber
            )
        );
        _randomNumber  = uint256(_structHash);
        assembly {_randomNumber := add(mod(_randomNumber, _maxNumber),1)}
        winningNumbers[1]=uint8(_randomNumber);

        // 3
        _structHash = keccak256(
            abi.encode(
                _blockhash,
                lastTimestamp,
                gasleft,
                _externalRandomNumber
            )
        );
        _randomNumber  = uint256(_structHash);
        assembly {_randomNumber := add(mod(_randomNumber, _maxNumber),1)}
        winningNumbers[2]=uint8(_randomNumber);

        // 4
        _structHash = keccak256(
            abi.encode(
                _blockhash,
                gasleft,
                _externalRandomNumber
            )
        );
        _randomNumber  = uint256(_structHash);
        assembly {_randomNumber := add(mod(_randomNumber, _maxNumber),1)}
        winningNumbers[3]=uint8(_randomNumber);
        historyNumbers[issueIndex] = winningNumbers;
        historyAmount[issueIndex] = calculateMatchingRewardAmount();
        drawTimestamp[issueIndex] = block.timestamp;
        drawingPhase = false;
        emit Drawing(issueIndex, winningNumbers);
    }

    function internalBuy(uint256 _price, uint8[4] memory _numbers) internal {
        require (!drawed(), 'drawed, can not buy now');
        for (uint i = 0; i < 4; i++) {
            require (_numbers[i] <= maxNumber, 'exceed the maximum');
        }
        uint256 tokenId = lotteryNFT.newLotteryItem(address(this), _numbers, _price, issueIndex);
        lotteryInfo[issueIndex].push(tokenId);
        totalAmount = totalAmount.add(_price);
        lastTimestamp = block.timestamp;
        emit Buy(address(this), tokenId);

    }

    function buy(uint256 _price, uint8[4] memory _numbers,address referrer) external inDrawingPhase {
        require (_price >= minPrice, 'price must above minPrice');
        for (uint i = 0; i < 4; i++) {
            require (_numbers[i] <= maxNumber, 'exceed number scope');
        }
         bool refFeeEnabled = (divreferralfee>0 && referrer != address(0)); 
        uint256 tmpfinalprice =_price;
        if(treasuryFee>0)
        {
             uint256  tmptreasuryreward = _price.mul(treasuryFee).div(1000);    
              tmpfinalprice = _price.sub(tmptreasuryreward);
        }
       
        uint256 tokenId = lotteryNFT.newLotteryItem(msg.sender, _numbers, tmpfinalprice, issueIndex);
        lotteryInfo[issueIndex].push(tokenId);
        if (userInfo[msg.sender].length == 0) {
            totalAddresses = totalAddresses + 1;
        }
        userInfo[msg.sender].push(tokenId);
      
        lastTimestamp = block.timestamp;
        uint64[keyLengthForEachBuy] memory userNumberIndex = generateNumberIndexKey(_numbers);
        for (uint i = 0; i < keyLengthForEachBuy; i++) {
            userBuyAmountSum[issueIndex][userNumberIndex[i]]=userBuyAmountSum[issueIndex][userNumberIndex[i]].add(tmpfinalprice);
        }
        slime.safeTransferFrom(address(msg.sender), address(this), _price);

        //Add referral to ref contract, check if new or already got referrer
        if (rewardReferral != address(0) && refFeeEnabled) {
            SlimeFriends(rewardReferral).setSlimeFriend (msg.sender, referrer);
        }
          if(treasuryFee>0)
        {
            uint256 referralReward = 0;
            address Inreferrer = address(0); 
           // treasury fee , substract referrer fee
             uint256 treasuryFeeAmmount= _price.mul(treasuryFee).div(1000);  
            uint256 treasuryReward =treasuryFeeAmmount;  

          if (refFeeEnabled) { 
                 Inreferrer  = SlimeFriends(rewardReferral).getSlimeFriend (msg.sender); 
                 // got referrer
                if (Inreferrer != address(0)) {
                  referralReward = _price.mul(divreferralBuyfee).div(1000);
                  treasuryReward= treasuryReward.sub(referralReward);
                  slime.safeTransfer(Inreferrer,referralReward);
                 emit ReferralBuyClaim(issueIndex,msg.sender,Inreferrer,referralReward);   
                }    
            } 

            _price= _price.sub(treasuryFeeAmmount);
            totalAmount = totalAmount.add(_price); 
            slime.safeTransfer(treasuryAddress,treasuryReward); 
            emit TreasuryFeeClaim(issueIndex,treasuryAddress,treasuryReward);
         
        }else{
             totalAmount = totalAmount.add(_price); 
        }
 
        emit Buy(msg.sender, tokenId);
    }

    function  multiBuy(uint256 _price, uint8[4][] memory _numbers,address referrer) external inDrawingPhase {
        require (_price >= minPrice, 'price must above minPrice');
        uint256 totalPrice  = 0;
        for (uint i = 0; i < _numbers.length; i++) {
            for (uint j = 0; j < 4; j++) {
                require (_numbers[i][j] <= maxNumber && _numbers[i][j] > 0, 'exceed number scope');
            }

              uint256 tmpfinalprice =_price;
                if(treasuryFee>0)
                {
                    uint256  tmptreasuryreward = _price.mul(treasuryFee).div(1000);    
                    tmpfinalprice = _price.sub(tmptreasuryreward);
                }

            uint256 tokenId = lotteryNFT.newLotteryItem(msg.sender, _numbers[i], tmpfinalprice, issueIndex);
            lotteryInfo[issueIndex].push(tokenId);
            if (userInfo[msg.sender].length == 0) {
                totalAddresses = totalAddresses + 1;
            }
            userInfo[msg.sender].push(tokenId);
            
            lastTimestamp = block.timestamp;
            totalPrice = totalPrice.add(_price);
            uint64[keyLengthForEachBuy] memory numberIndexKey = generateNumberIndexKey(_numbers[i]);
            for (uint k = 0; k < keyLengthForEachBuy; k++) {
                userBuyAmountSum[issueIndex][numberIndexKey[k]]=userBuyAmountSum[issueIndex][numberIndexKey[k]].add(tmpfinalprice);
            }
        }
        slime.safeTransferFrom(address(msg.sender), address(this), totalPrice);
          //Add referral to ref contract, check if new or already got referrer
        if (rewardReferral != address(0) && referrer != address(0)) {
            SlimeFriends(rewardReferral).setSlimeFriend (msg.sender, referrer);
        }
        // get referrer
        //we get referrers fee from treasury
 
        if(treasuryFee>0)
        {
            uint256 referralReward = 0;
            address Inreferrer = address(0); 
           // treasury fee , substract referrer fee
             uint256 treasuryFeeAmmount= totalPrice.mul(treasuryFee).div(1000);  
            uint256 treasuryReward =treasuryFeeAmmount;  

          if (rewardReferral != address(0)) { 
                 Inreferrer  = SlimeFriends(rewardReferral).getSlimeFriend (msg.sender); 
                 // got referrer
                if (Inreferrer != address(0)) {
                  referralReward = totalPrice.mul(divreferralBuyfee).div(1000);
                  treasuryReward= treasuryReward.sub(referralReward);
                 slime.safeTransfer(Inreferrer,referralReward);
                emit ReferralBuyClaim(issueIndex,msg.sender,Inreferrer,referralReward);   
                }    
            } 

            totalPrice= totalPrice.sub(treasuryFeeAmmount);
            totalAmount = totalAmount.add(totalPrice); 
            slime.safeTransfer(treasuryAddress,treasuryReward); 
            emit TreasuryFeeClaim(issueIndex,treasuryAddress,treasuryReward);
         
        }else{
             totalAmount = totalAmount.add(totalPrice); 
        }
      
        emit MultiBuy(msg.sender, totalPrice);
    }
  
    function claimReward(uint256 _tokenId) external {
        require(msg.sender == lotteryNFT.ownerOf(_tokenId), "not from owner");
        require (!lotteryNFT.getClaimStatus(_tokenId), "claimed");
         (uint256 reward,uint256 matching_number)= getRewardView(_tokenId);

        lotteryNFT.claimReward(_tokenId);
        if(reward>0) { 
            uint256 toBurn = reward.mul(burnfee).mul(burnMultiplier[(4-matching_number)]).div(10000); 
            uint256 toReferral=0;
          
            //total - fees
            reward = reward.sub(toBurn); 
            address referrer = address(0);

            if (rewardReferral != address(0)) {
                referrer = SlimeFriends(rewardReferral).getSlimeFriend(msg.sender);
               
            }
            
            if (divreferralfee>0 && referrer != address(0)) {  
                 toReferral =reward.mul(divreferralfee).div(1000); 
                //referral earning are from burn ammount, ref fee must be lower to burn always at start 10% burn - 0,4% referrer, so if referrer 9.6% to burn
                toBurn=toBurn.sub(toReferral);
                slime.safeTransfer(referrer, toReferral);
                emit ReferralClaim(issueIndex,msg.sender, referrer,toReferral);
                
                slime.safeTransfer(address(0xdead),toBurn);
                emit Burn(issueIndex,msg.sender,toBurn);
                
            } else { 
           
               slime.safeTransfer(address(0xdead),toBurn);
               emit Burn(issueIndex,msg.sender,toBurn);
            }
             
             slime.safeTransfer(address(msg.sender), reward);
        }
        emit Claim(msg.sender, _tokenId, reward);
    }

    function  multiClaim(uint256[] memory _tickets) external {
        uint256 totalReward = 0;
        uint256 totalToBurn = 0; 
        uint256 totalToReferrer =0; 
        address referrer = address(0);
         
         if (rewardReferral != address(0)) {
              referrer = SlimeFriends(rewardReferral).getSlimeFriend(msg.sender); 
          }
 

        for (uint i = 0; i < _tickets.length; i++) {
            require (msg.sender == lotteryNFT.ownerOf(_tickets[i]), "not from owner");
            require (!lotteryNFT.getClaimStatus(_tickets[i]), "claimed");
          
            (uint256 reward,uint256 matching_number) = getRewardView(_tickets[i]);
            if(reward>0) {
              
                uint256 ticketBurnAmount = 0; 
                //to check how much reduce from burn to pay referrer 
                if(burnfee>0)
                {
                    ticketBurnAmount = reward.mul(burnfee).mul(burnMultiplier[(4-matching_number)]).div(10000); 
                    uint256 toBurn = ticketBurnAmount; 

                     if (divreferralfee>0 && referrer != address(0)) { 
                      uint256  toReferral =reward.mul(divreferralfee).div(1000);

                        totalToReferrer=totalToReferrer.add(toReferral);   
                        toBurn=toBurn.sub(toReferral);
                     }else{
                         toBurn = ticketBurnAmount;
                     } 
                    totalToBurn=totalToBurn.add(toBurn);  
                    //total - burn fee
                    reward = reward.sub(ticketBurnAmount); 
                }
                    
               totalReward = totalReward.add(reward);
            }
        }
        lotteryNFT.multiClaimReward(_tickets);
        if(totalReward>0) {
        
        
            if (referrer!= address(0)) {   
                 if(totalToReferrer>0)
                 {
                    slime.safeTransfer(referrer, totalToReferrer);
                    emit ReferralClaim(issueIndex,msg.sender, referrer,totalToReferrer);
                 }  
                 if(totalToBurn>0)
                 {
                    slime.safeTransfer(address(0xdead),totalToBurn);
                    emit Burn(issueIndex,msg.sender,totalToBurn);
                 }
               
            } else {  
               if(totalToBurn>0)
                 {
                    slime.safeTransfer(address(0xdead),totalToBurn);
                    emit Burn(issueIndex,msg.sender,totalToBurn);
                 } 
            }
             
             slime.safeTransfer(address(msg.sender), totalReward);
 
        }
        emit MultiClaim(msg.sender, totalReward);
    }

    function generateNumberIndexKey(uint8[4] memory number) public pure returns (uint64[keyLengthForEachBuy] memory) {
        uint64[4] memory tempNumber;
        tempNumber[0]=uint64(number[0]);
        tempNumber[1]=uint64(number[1]);
        tempNumber[2]=uint64(number[2]);
        tempNumber[3]=uint64(number[3]);

        uint64[keyLengthForEachBuy] memory result;
        result[0] = tempNumber[0]*256*256*256*256*256*256 + 1*256*256*256*256*256 + tempNumber[1]*256*256*256*256 + 2*256*256*256 + tempNumber[2]*256*256 + 3*256 + tempNumber[3];

        result[1] = tempNumber[0]*256*256*256*256 + 1*256*256*256 + tempNumber[1]*256*256 + 2*256+ tempNumber[2];
        result[2] = tempNumber[0]*256*256*256*256 + 1*256*256*256 + tempNumber[1]*256*256 + 3*256+ tempNumber[3];
        result[3] = tempNumber[0]*256*256*256*256 + 2*256*256*256 + tempNumber[2]*256*256 + 3*256 + tempNumber[3];
        result[4] = 1*256*256*256*256*256 + tempNumber[1]*256*256*256*256 + 2*256*256*256 + tempNumber[2]*256*256 + 3*256 + tempNumber[3];

        result[5] = tempNumber[0]*256*256 + 1*256+ tempNumber[1];
        result[6] = tempNumber[0]*256*256 + 2*256+ tempNumber[2];
        result[7] = tempNumber[0]*256*256 + 3*256+ tempNumber[3];
        result[8] = 1*256*256*256 + tempNumber[1]*256*256 + 2*256 + tempNumber[2];
        result[9] = 1*256*256*256 + tempNumber[1]*256*256 + 3*256 + tempNumber[3];
        result[10] = 2*256*256*256 + tempNumber[2]*256*256 + 3*256 + tempNumber[3];

        return result;
    }

    function calculateMatchingRewardAmount() internal view returns (uint256[4] memory) {
        uint64[keyLengthForEachBuy] memory numberIndexKey = generateNumberIndexKey(winningNumbers);

        uint256 totalAmout1 = userBuyAmountSum[issueIndex][numberIndexKey[0]];

        uint256 sumForTotalAmout2 = userBuyAmountSum[issueIndex][numberIndexKey[1]];
        sumForTotalAmout2 = sumForTotalAmout2.add(userBuyAmountSum[issueIndex][numberIndexKey[2]]);
        sumForTotalAmout2 = sumForTotalAmout2.add(userBuyAmountSum[issueIndex][numberIndexKey[3]]);
        sumForTotalAmout2 = sumForTotalAmout2.add(userBuyAmountSum[issueIndex][numberIndexKey[4]]);

        uint256 totalAmout2 = sumForTotalAmout2.sub(totalAmout1.mul(4));

        uint256 sumForTotalAmout3 = userBuyAmountSum[issueIndex][numberIndexKey[5]];
        sumForTotalAmout3 = sumForTotalAmout3.add(userBuyAmountSum[issueIndex][numberIndexKey[6]]);
        sumForTotalAmout3 = sumForTotalAmout3.add(userBuyAmountSum[issueIndex][numberIndexKey[7]]);
        sumForTotalAmout3 = sumForTotalAmout3.add(userBuyAmountSum[issueIndex][numberIndexKey[8]]);
        sumForTotalAmout3 = sumForTotalAmout3.add(userBuyAmountSum[issueIndex][numberIndexKey[9]]);
        sumForTotalAmout3 = sumForTotalAmout3.add(userBuyAmountSum[issueIndex][numberIndexKey[10]]);

        uint256 totalAmout3 = sumForTotalAmout3.add(totalAmout1.mul(6)).sub(sumForTotalAmout2.mul(3));

        return [totalAmount, totalAmout1, totalAmout2, totalAmout3];
    }

    function getMatchingRewardAmount(uint256 _issueIndex, uint256 _matchingNumber) public view returns (uint256) {
        return historyAmount[_issueIndex][5 - _matchingNumber];
    }

    function getTotalRewards(uint256 _issueIndex) public view returns(uint256) {
        require (_issueIndex <= issueIndex, '_issueIndex <= issueIndex');

        if(!drawed() && _issueIndex == issueIndex) {
            return totalAmount;
        }
        return historyAmount[_issueIndex][0];
    }

    function getRewardView(uint256 _tokenId) public view returns(uint256,uint256) {
        uint256 _issueIndex = lotteryNFT.getLotteryIssueIndex(_tokenId);
        uint8[4] memory lotteryNumbers = lotteryNFT.getLotteryNumbers(_tokenId);
        uint8[4] memory _winningNumbers = historyNumbers[_issueIndex];
        require(_winningNumbers[0] != 0, "not drawed");

        uint256 matchingNumber = 0;
        for (uint i = 0; i < lotteryNumbers.length; i++) {
            if (_winningNumbers[i] == lotteryNumbers[i]) {
                matchingNumber= matchingNumber +1;
            }
        }
        uint256 reward = 0;
        if (matchingNumber > 1) {
            uint256 amount = lotteryNFT.getLotteryAmount(_tokenId);
            uint256 poolAmount = getTotalRewards(_issueIndex).mul(allocation[4-matchingNumber]).div(100);
            reward = amount.mul(1e12).div(getMatchingRewardAmount(_issueIndex, matchingNumber)).mul(poolAmount);
        }
        return  (reward.div(1e12),matchingNumber);
    }


    // Update admin address by the previous dev.
    function setAdmin(address _adminAddress) public onlyOwner {
        adminAddress = _adminAddress;
    }

      // Update admin address by the previous dev.
    function setTreasuryAddress(address _treasuryAddress) public onlyOwner {
        treasuryAddress = _treasuryAddress;
    }

    function setBurnAddress(address _burnAddress) public onlyOwner {
        burnAddress = _burnAddress;
    }
    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function adminWithdraw(uint256 _amount) public onlyAdmin {
        slime.safeTransfer(address(msg.sender), _amount);
        emit DevWithdraw(msg.sender, _amount);
    }

    // Set the minimum price for one ticket
    function setMinPrice(uint256 _price) external onlyAdmin {
        minPrice = _price;
    }

    // Set the minimum price for one ticket
    function setMaxNumber(uint8 _maxNumber) external onlyAdmin {
        maxNumber = _maxNumber;
    }

    // Set the allocation for one reward
    function setAllocation(uint8 _allcation1, uint8 _allcation2, uint8 _allcation3) external onlyAdmin {
        require (_allcation1 + _allcation2 + _allcation3 < 100, 'exceed 100');
        allocation = [_allcation1, _allcation2, _allcation3];
      

    }

    // =================================
    function updateBurnMultipliers(uint8[4] memory _burnMultiplier) external onlyAdmin {
        burnMultiplier = _burnMultiplier;
    }
    function updateReferralFee(uint256 _divreferralfee) external onlyAdmin {
        divreferralfee = _divreferralfee;
    }
    function updateBurnfee(uint256 _burnfee) external onlyAdmin {
        burnfee = _burnfee;
    }

    function updateRoundBurnfee(uint256 _acumulatedRoundBurnfee) external onlyAdmin {
        acumulatedRoundBurnfee = _acumulatedRoundBurnfee;
    }
     function updateTreasuryFee(uint256 _treasuryFee) external onlyAdmin {
        treasuryFee = _treasuryFee;
    }
}