// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.6.2 <0.9.0;
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

//WITHOUT 3RD PARTY LIQUIDITY;
contract CoBiCo is ERC721("Collateralize,Bid & Collect", "CBC"), IERC721Receiver {
   
    address stablecoin_addr = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address collateral_addr = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;
    IERC20 stablecoin = IERC20(stablecoin_addr);

    IERC20 collateral = IERC20(collateral_addr);
address stablecoin_agg_addr= 0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7;
address collateral_agg_addr= 0xDE31F8bFBD8c84b5360CFACCa3539B938dd78ae6;
    struct Storage {
        uint256[] members;
        uint256 currentMembers;
        PartStorage ps;
        BidData[] bd;
    }
    mapping(address => bool) consentTracker;
    AggregatorV3Interface acollateral =
        AggregatorV3Interface(collateral_agg_addr);
    AggregatorV3Interface stablecoin_agg =
        AggregatorV3Interface(stablecoin_agg_addr);

    //8decimals
    struct Members {
        bool hasCollateralWithDrawn;
        bool hasReceivedLumpSum;
        bool[] payStatus;
        uint256 btcCollateral;
    }

    struct BidData {
        address currentBidder;
        uint256 uid;
        uint256 bidPlacedValue;
        uint256 collectedValue;
    }

    mapping(uint256 => Members) financeMembers;
    mapping(uint128 => Storage) financeDB;
    event EBid(uint128 indexed hash, uint256 bidVal);
    event ENCon(address indexed addr, uint128 indexed hash, PartStorage psto);
    event ECMem(uint128 indexed hash, uint256 indexed uid, uint256 val);

    address promoter;
    address maker;

    constructor() {
        maker = msg.sender;
    }

    struct PartStorage {
        uint256 minMembers;
        uint256 interval;
        uint256 minSumAssured;
        uint256 maxSumAssured;
        uint256 collectTime;
        uint256 bidTime;
        uint256 collateralValue;
        uint256 startTime;
    }

    //step-1 promoter creates a contract;
    function createCnt(
        uint256 minMembers,
        uint256 interval,
        uint256 minSumAssured,
        uint256 maxSumAssured,
        uint256 btcCollateral,
        uint256 collectTime,
        uint256 bidTime,
        bool isPrivate
    ) public returns (uint128) {
        uint128 hash = ++hashCntr;

        financeDB[hash].ps = PartStorage(
            minMembers,
            interval,
            minSumAssured,
            maxSumAssured,
            collectTime,
            bidTime,
            btcCollateral,
            0
        );
        promoter = msg.sender;
        if (!isPrivate) emit ENCon(address(this), hash, financeDB[hash].ps);
        return hash;
    }

    //step-2 members join by paying collateral;
    function join(uint128 hash) public {
        uint256 uid = ++uidCntr;
        Storage storage s = financeDB[hash];
        PartStorage storage ps = s.ps;

        require(ps.startTime == 0, "already started");
        require(ps.minSumAssured > 0, "id doesnt exist");
        collateral.transferFrom(msg.sender, address(this), ps.collateralValue);

        financeMembers[uid].btcCollateral = ps.collateralValue;
        s.currentMembers += 1;
        s.bd.push(BidData(address(0), uid, ps.maxSumAssured + 1, 0));
        s.members.push(uid);
        _mint(msg.sender, uid);
        emit ECMem(hash, uid, s.currentMembers);
    }

    //step-3 someone initiates a bid and others compete ;
    function bid(
        uint128 hash,
        uint256 uid,
        uint256 value
    ) public {
        Storage storage s = financeDB[hash];

        PartStorage storage ps = s.ps;

        if (ps.startTime == 0) {
            ps.startTime = block.timestamp * 1 seconds;
        }
        require(ownerOf(uid) == msg.sender, "youre not the owner");

        require(ps.minMembers <= s.currentMembers);
        for (uint256 i = 0; i <= getIdx(hash); i++) {
            require(
                !(s.bd[i].currentBidder == msg.sender && s.bd[i].uid == uid),
                "you've an active bid"
            );
        }
        require(
            (getTimeUnits() - ps.startTime) <
                getIdx(hash) * ps.interval + ps.bidTime,
            "bid time hasnt started"
        );
        require(
            value <= ps.maxSumAssured && value >= ps.minSumAssured,
            "value doesn't fall between min or max"
        );
        require(
            s.bd[getIdx(hash)].bidPlacedValue > value,
            "bid value is higher than previous bid"
        );

        s.bd[getIdx(hash)].currentBidder = msg.sender;
        s.bd[getIdx(hash)].uid = uid;
        s.bd[getIdx(hash)].bidPlacedValue = value;

        emit EBid(hash, value);
    }

    //step-4: rest of the members pay bid;
    function payInstalment(uint128 hash, uint256 uid) public {
        Storage storage s = financeDB[hash];

        PartStorage storage ps = s.ps;

        require(
            (getTimeUnits() - ps.startTime) >
                getIdx(hash) * ps.interval + ps.bidTime,
            "bidding hasn't ended"
        );

        require(
            !(s.bd[getIdx(hash)].currentBidder == msg.sender &&
                s.bd[getIdx(hash)].uid == uid),
            "you're the bidder!"
        );
        require(ownerOf(uid) == msg.sender);
        uint256 uid2 = s.bd[getIdx(hash)].uid;
        require(
            !financeMembers[uid2].hasCollateralWithDrawn,
            "sorry bidder has withdrawn"
        );
        if (financeMembers[uid].payStatus.length != s.currentMembers) {
            for (uint256 i = 0; i < s.currentMembers; i++) {
                financeMembers[uid].payStatus.push(false);
            }
        }
        require(!financeMembers[uid].payStatus[getIdx(hash)], "already paid");
        uint256 tvalue = s.bd[getIdx(hash)].bidPlacedValue /
            (s.currentMembers - 1);
        stablecoin.transferFrom(msg.sender, payable(address(this)), tvalue);
        financeMembers[uid].payStatus[getIdx(hash)] = true;

        s.bd[getIdx(hash)].collectedValue += tvalue;
        emit ECMem(hash, uid, s.bd[getIdx(hash)].collectedValue);
    }

    
    // partOf step-5
    function defaultfn(
        uint128 hash,
        uint256 k,
        address to,
        uint256 uid
    ) private {
        uint256 price = getBTCPrice();
        uint256 curr;
        uint256 pay = 0;
        Storage storage s = financeDB[hash];

        Members storage res;
        uint256 dft;
        for (uint256 j = 0; j < s.currentMembers; j++) {
            res = financeMembers[s.members[j]];

            if (
                res.btcCollateral != 0 &&
                (res.payStatus.length == 0 || !res.payStatus[k])
            ) {
                curr = (res.btcCollateral) / (s.currentMembers - getIdx(hash));
                dft =
                    (s.bd[k].bidPlacedValue *acollateral_decimals) /
                    ((s.currentMembers - 1)*price);

               
                if (s.bd[j].uid != uid) {
                    if (curr > dft) {
                        pay += dft;
                        res.btcCollateral -= dft;
                    } else {
                        pay += curr;
                        res.btcCollateral -= curr;
                    }
                }
            }
        }

        collateral.transfer(to, (99 * pay) / 100);
        collateral.transfer(maker, pay / 100);
    }

    //step-5: bidder collects bid value;
    function collectBidValue(uint128 hash, uint256 uid) public {
        uint256 val = 0;
        uint256 fidx = getIdx(hash);
       
        Storage storage s = financeDB[hash];

        PartStorage storage ps = s.ps;

        require(!financeMembers[uid].hasReceivedLumpSum, "already collected");
        require(ownerOf(uid) == msg.sender, "youre not the owner");

        if (msg.sender == s.bd[fidx].currentBidder && uid == s.bd[fidx].uid) {
            require(
                (getTimeUnits() - ps.startTime) >
                    getIdx(hash) * ps.interval + ps.collectTime ||
                    (s.bd[fidx].collectedValue == s.bd[fidx].bidPlacedValue),
                "your time hasnt come"
            );
            val = s.bd[fidx].collectedValue;
            if (val != s.bd[fidx].bidPlacedValue) {
                
                defaultfn(hash, getIdx(hash), msg.sender, uid);
            }
        } else {
            for (uint256 i = 0; i < fidx; i++) {
                if (s.bd[i].currentBidder == msg.sender && uid == s.bd[i].uid) {
                    val = s.bd[i].collectedValue;
                    if (s.bd[i].collectedValue != s.bd[i].bidPlacedValue) {
                        defaultfn(hash, i, msg.sender, uid);
                       
                    }
                    break;
                }
            }
        }

        stablecoin.transfer(msg.sender, (197 * val) / 200);

        stablecoin.transfer(promoter, (3 * val) / 200);
        financeMembers[uid].hasReceivedLumpSum = true;
    }

    uint256 uidCntr;
    uint128 hashCntr;

    // cycle ends}

    //last-step: everyone collects collateral at the end of the cycle by transferring tokenId;
    function _transfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override {
        require(to == address(this), "you can only transfer to this contract");
        super._transfer(from, to, tokenId);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        bytes16 hash;
        for (uint256 i = 0; i < 16; i++) {
            hash = hash | (bytes16((data[i] & 0xff)) >> (i * 8));
        }

        

        if (financeDB[uint128(hash)].ps.startTime == 0) {
            exitContract(uint128(hash), tokenId, from);
            _burn(tokenId);
        } else {
            collectCollateral(uint128(hash), tokenId, from);
            _burn(tokenId);
        }
        return IERC721Receiver(address(this)).onERC721Received.selector;
    }

    // before bid starts
    function exitContract(
        uint128 hash,
        uint256 uid,
        address user
    ) private {
        bool check = false;

        Storage storage s = financeDB[hash];

        for (uint256 i = 0; i < s.currentMembers; i++) {
            if (s.members[i] == uid) {
                check = true;
                for (uint256 j = i; j < s.currentMembers - 1; j++) {
                    s.members[j] = s.members[j + 1];
                }
                s.members.pop();

                break;
            }
        }

        require(check);

        collateral.transfer(user, financeMembers[uid].btcCollateral);
        financeMembers[uid].btcCollateral = 0;
        s.currentMembers -= 1;
        emit ECMem(hash, uid, s.currentMembers);
    }

    // after bid ends
    function collectCollateral(
        uint128 hash,
        uint256 uid,
        address user
    ) private {
        Storage storage s = financeDB[hash];

        PartStorage storage ps = s.ps;

        require(
            getTimeUnits() > ps.startTime + ps.interval * s.currentMembers,
            "duration isnt completed"
        );

        (
            financeMembers[uid].hasReceivedLumpSum,
            "collect issued tokens first!"
        );
        collateral.transfer(user, financeMembers[uid].btcCollateral);

        financeMembers[uid].btcCollateral = 0;
    }

    function getTokenBalance(uint256 uid) public view returns (uint256) {
        return financeMembers[uid].btcCollateral;
    }

    function getTimeUnits() private view returns (uint256) {
        return block.timestamp * 1 seconds;
    }

    //idx setter;
    function getIdx(uint128 hash) private view returns (uint256) {
        Storage storage s = financeDB[hash];

        PartStorage storage ps = s.ps;

     
        if ((getTimeUnits() - ps.startTime) <= ps.interval * s.currentMembers) {
            return (getTimeUnits() - ps.startTime) / ps.interval;
        } else {
            return s.currentMembers - 1;
        }
    }
uint256 acollateral_decimals= 10**acollateral.decimals();
uint256 stablecoin_agg_decimals= 10**stablecoin_agg.decimals();
  
    function getBTCPrice() public view returns (uint256) {

        (,int price,,,)= acollateral.latestRoundData();
        (,int price2,,,)=stablecoin_agg.latestRoundData();
        return uint((price*int(stablecoin_agg_decimals**2/acollateral_decimals))/(price2));
 
    }
}
